# frozen_string_literal: true

require 'json'
require 'time'

module SaneMasterModules
  module CommandRegistry
    COMMAND_REGISTRY_ALIASES = {
      'tm' => 'test_mode',
      'crash_report' => 'crashes',
      'check-inbox' => 'check_inbox',
      'inbox' => 'check_inbox',
      'sync-mini' => 'sync_mini',
      'sync-grok' => 'sync_grok',
      'runtime_snapshot' => 'runtime_evidence',
      'runtime-evidence' => 'runtime_evidence',
      'lldb_snapshot' => 'runtime_evidence',
      'visual-smoke' => 'visual_smoke',
      'resource-soak' => 'resource_soak',
      'customer-ui-sweep' => 'customer_ui_sweep',
      'release-readiness' => 'release_readiness',
      'route-cost-review' => 'route_cost_review',
      'rcr' => 'route_cost_review',
      'near-miss-review' => 'near_miss_review',
      'nmr' => 'near_miss_review',
      'verify-failure-review' => 'verify_failure_review',
      'vfr' => 'verify_failure_review',
      'process-eval' => 'process_eval',
      'trace-eval' => 'trace_eval',
      'sop-review' => 'sop_review',
      'proof-plan' => 'proof_plan',
      'context-bundle' => 'context_bundle',
      'agent-eval' => 'agent_eval',
      'skill-lint' => 'skill_lint',
      'tool_receipt' => 'tool_discovery',
      'tool-receipt' => 'tool_discovery',
      'registry-review' => 'registry_review'
    }.freeze

    GATE_REGISTRY = {
      startup_gate: {
        owner: 'scripts/hooks/sanetools_startup.rb',
        timing: 'pre_tool',
        protected_failure: 'missing startup context before risky mutation',
        cost_class: 'high',
        treatment: 'context_sensitive_preflight',
        fixtures: ['startup_gate_failed_validation_report_does_not_open']
      },
      session_docs: {
        owner: 'scripts/hooks/session_docs_test.rb',
        timing: 'pre_tool',
        protected_failure: 'stale session context and rediscovery loops',
        cost_class: 'high',
        treatment: 'split_by_task_risk',
        fixtures: ['session_docs_unrelated_same_basename_read_does_not_satisfy']
      },
      tool_discovery: {
        owner: 'scripts/hooks/sanetrack_proofs.rb',
        timing: 'first_use',
        protected_failure: 'invented tools and repeated workaround folklore',
        cost_class: 'medium',
        treatment: 'hard_for_gap_claims_only',
        fixtures: ['tool_discovery_proof_accepts_semantic_query_match_but_only_for_gap_claims']
      },
      mcp_actions_pending: {
        owner: 'scripts/hooks/sanetools_research.rb',
        timing: 'session_end_or_memory_work',
        protected_failure: 'lost durable memory or handoff learnings',
        cost_class: 'medium',
        treatment: 'ttl_then_advisory_for_unrelated_work',
        fixtures: ['memory_staging_stale_file_degrades_to_advisory_before_edit']
      },
      visual_proof: {
        owner: 'scripts/hooks/task_completed_gate.rb',
        timing: 'task_completed',
        protected_failure: 'false UI verified claims',
        cost_class: 'medium',
        treatment: 'hard_for_customer_visible_changes',
        fixtures: ['visual_proof_required_only_for_customer_visible_ui_change']
      },
      task_completed_verify: {
        owner: 'scripts/hooks/task_completed_gate.rb',
        timing: 'task_completed',
        protected_failure: 'done claim without current tested source fingerprint',
        cost_class: 'medium',
        treatment: 'keep_hard',
        fixtures: ['diagnostic_only_success_cannot_satisfy_customer_facing_claim']
      }
    }.freeze

    LARGE_OWNER_REGISTRY = {
      'scripts/SaneMaster.rb' => {
        owner: 'sanemaster_command_router',
        line_budget: 500,
        hard_limit: 800,
        split_target: 'keep dispatch/help only; move command implementations into scripts/sanemaster modules',
        next_slice: 'extract remaining release/support/process command branches behind module methods'
      },
      'scripts/sanemaster/customer_ui_contract.rb' => {
        owner: 'customer_ui_runtime_contract',
        line_budget: 500,
        hard_limit: 800,
        split_target: 'split capture, contract evaluation, and report rendering into owned modules',
        next_slice: 'move report/render helpers out of runtime capture flow'
      },
      'scripts/sanemaster/process_metrics.rb' => {
        owner: 'process_metrics_and_route_cost',
        line_budget: 500,
        hard_limit: 800,
        split_target: 'split metric IO/export, route-cost review, and workflow metadata helpers',
        next_slice: 'extract route-cost taxonomy/review helpers behind a dedicated module'
      },
      'scripts/sanemaster/verify.rb' => {
        owner: 'verify_orchestration',
        line_budget: 500,
        hard_limit: 800,
        split_target: 'keep public verify flow small; move parsing/reporting helpers to verify_support',
        next_slice: 'move remaining report text and result normalization helpers'
      },
      'scripts/sanemaster/base.rb' => {
        owner: 'sanemaster_shared_base',
        line_budget: 500,
        hard_limit: 800,
        split_target: 'keep shared shell/env helpers small; move app/domain-specific behavior to modules',
        next_slice: 'extract project/app discovery helpers from generic command execution'
      }
    }.freeze

    def registry_review(args = [])
      json = args.include?('--json')
      result = build_registry_review

      if json
        puts JSON.pretty_generate(result)
      else
        print_registry_review(result)
      end

      result
    end

    def build_registry_review
      commands = command_registry_entries
      gates = GATE_REGISTRY.transform_values(&:dup)
      large_owners = large_owner_entries
      warnings = command_registry_warnings(large_owners)
      {
        generated_at: Time.now.utc.iso8601,
        commands: commands,
        gates: gates,
        large_owners: large_owners,
        summary: {
          command_count: commands.length,
          alias_count: COMMAND_REGISTRY_ALIASES.length,
          detailed_help_count: commands.count { |_name, entry| entry[:has_detailed_help] },
          route_metadata_count: commands.count { |_name, entry| entry[:route_guard] != 'unknown' },
          gate_count: gates.length,
          large_owner_count: large_owners.length,
          oversized_owner_count: large_owners.count { |_path, entry| entry[:status] != 'ok' },
          must_split_owner_count: large_owners.count { |_path, entry| entry[:status] == 'must_split' }
        },
        issues: command_registry_issues(commands, gates, large_owners),
        warnings: warnings
      }
    end

    def command_registry_entries
      entries = {}
      self.class::COMMANDS.each do |category, data|
        data[:commands].each do |name, info|
          workflow = "sanemaster:#{name}"
          entries[name] = {
            command: name,
            category: category.to_s,
            args: info[:args],
            desc: info[:desc],
            aliases: command_aliases_for(name),
            route_guard: respond_to?(:route_cost_guard, true) ? route_cost_guard(workflow) : 'unknown',
            task_family: respond_to?(:workflow_task_family, true) ? workflow_task_family(workflow) : 'unknown',
            proof_scope_actual: respond_to?(:workflow_proof_scope_actual, true) ? workflow_proof_scope_actual(workflow) : 'unknown',
            outcome_strength: respond_to?(:workflow_outcome_strength, true) ? workflow_outcome_strength(workflow, nil) : 'unknown',
            has_detailed_help: self.class::COMMAND_DETAILS.key?(name)
          }
        end
      end
      entries
    end

    def command_aliases_for(command)
      COMMAND_REGISTRY_ALIASES.select { |_alias_name, target| target == command }.keys.sort
    end

    def canonical_command_name(command)
      COMMAND_REGISTRY_ALIASES.fetch(command, command)
    end

    def large_owner_entries
      LARGE_OWNER_REGISTRY.each_with_object({}) do |(path, entry), memo|
        absolute = File.expand_path(File.join(__dir__, '..', '..', path))
        line_count = File.exist?(absolute) ? File.readlines(absolute).length : 0
        status = if line_count >= entry[:hard_limit].to_i
                   'must_split'
                 elsif line_count > entry[:line_budget].to_i
                   'oversized'
                 else
                   'ok'
                 end
        memo[path] = entry.merge(
          path: path,
          absolute_path: absolute,
          line_count: line_count,
          status: status
        )
      end
    end

    def command_registry_issues(commands, gates, large_owners)
      issues = []
      COMMAND_REGISTRY_ALIASES.each do |alias_name, target|
        issues << "alias #{alias_name} targets missing command #{target}" unless commands.key?(target)
      end

      commands.each do |name, entry|
        issues << "command #{name} missing route metadata" if entry[:route_guard].to_s == 'unknown'
      end

      gates.each do |name, gate|
        %i[owner timing protected_failure cost_class treatment fixtures].each do |field|
          value = gate[field]
          issues << "gate #{name} missing #{field}" if value.nil? || value.respond_to?(:empty?) && value.empty?
        end
      end
      large_owners.each do |path, entry|
        issues << "large owner #{path} missing tracked file" if entry[:line_count].to_i.zero?
        %i[owner line_budget hard_limit split_target next_slice].each do |field|
          value = entry[field]
          issues << "large owner #{path} missing #{field}" if value.nil? || value.respond_to?(:empty?) && value.empty?
        end
      end
      issues
    end

    def command_registry_warnings(large_owners)
      large_owners.map do |path, entry|
        next if entry[:status] == 'ok'

        "#{path} is #{entry[:status]} at #{entry[:line_count]} lines; next split: #{entry[:next_slice]}"
      end.compact
    end

    def print_registry_review(result)
      puts 'SaneMaster Registry Review'
      puts '=' * 26
      puts "Commands: #{result.dig(:summary, :command_count)}"
      puts "Aliases: #{result.dig(:summary, :alias_count)}"
      puts "Detailed help entries: #{result.dig(:summary, :detailed_help_count)}"
      puts "Route metadata entries: #{result.dig(:summary, :route_metadata_count)}"
      puts "Gates: #{result.dig(:summary, :gate_count)}"
      puts "Large owners: #{result.dig(:summary, :large_owner_count)} (#{result.dig(:summary, :must_split_owner_count)} must split)"
      puts
      if result[:issues].empty?
        puts 'Issues: none'
      else
        puts 'Issues:'
        result[:issues].each { |issue| puts "  - #{issue}" }
      end
      if result[:warnings].any?
        puts 'Warnings:'
        result[:warnings].each { |warning| puts "  - #{warning}" }
      end
    end
  end
end
