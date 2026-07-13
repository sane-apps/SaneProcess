# frozen_string_literal: true

require 'json'
require 'time'

module SaneMasterModules
  module NearMissReview
    NEAR_MISS_RECEIPT_FIELDS = %w[
      session_id client base_score block_count verify_attempts verify_failures
      final_verify_success
    ].freeze

    def near_miss_review(args = [])
      options = parse_near_miss_options(args)
      events = options[:metrics_path] ? read_near_miss_events_from_path(options[:metrics_path]) : read_process_metric_events
      review_events = options[:include_test_events] ? events : reject_near_miss_test_events(events)
      window = options[:limit] ? review_events.last(options[:limit]) : review_events
      result = build_near_miss_review(window, options: options.merge(total_events: events.length, ignored_events: events.length - review_events.length))

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_near_miss_review(result)
      end

      result
    end

    def build_near_miss_review(events, options: {})
      min_count = options.fetch(:min_count, 2).to_i
      min_count = 1 if min_count < 1
      candidates = []
      candidates.concat(near_miss_hook_candidates(events, min_count))
      candidates.concat(near_miss_verify_candidates(events, min_count))
      candidates.concat(near_miss_session_candidates(events, min_count))
      candidates.concat(near_miss_support_candidates(events, min_count))
      candidates.concat(near_miss_workflow_candidates(events, min_count))
      candidates = candidates.sort_by { |candidate| [near_miss_severity_rank(candidate[:severity]), -candidate[:evidence_count].to_i, candidate[:id]] }

      {
        generated_at: Time.now.utc.iso8601,
        metrics_path: respond_to?(:process_metrics_path) ? process_metrics_path : nil,
        total_events: options[:total_events] || events.length,
        ignored_test_events: options[:ignored_events] || 0,
        lookback_events: events.length,
        min_count: min_count,
        summary: {
          candidate_count: candidates.length,
          high_count: candidates.count { |candidate| candidate[:severity] == 'high' },
          by_category: candidates.group_by { |candidate| candidate[:category] }.transform_values(&:length).sort.to_h
        },
        candidates: candidates
      }
    end

    private

    def parse_near_miss_options(args)
      options = { json: false, limit: 250, min_count: 2, include_test_events: false }
      rest = args.dup
      until rest.empty?
        token = rest.shift
        case token
        when '--json'
          options[:json] = true
        when '--limit'
          value = rest.shift
          raise ArgumentError, '--limit requires a positive integer' unless value.to_s.match?(/\A\d+\z/)

          options[:limit] = value.to_i
        when '--all'
          options[:limit] = nil
        when '--min-count'
          value = rest.shift
          raise ArgumentError, '--min-count requires a positive integer' unless value.to_s.match?(/\A\d+\z/)

          options[:min_count] = value.to_i
        when '--metrics'
          value = rest.shift
          raise ArgumentError, '--metrics requires a path' if value.to_s.empty?

          options[:metrics_path] = File.expand_path(value)
        when '--include-test-events'
          options[:include_test_events] = true
        else
          raise ArgumentError, "unknown near_miss_review option: #{token}"
        end
      end
      options
    end

    def read_near_miss_events_from_path(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def reject_near_miss_test_events(events)
      events.reject { |event| near_miss_test_event?(event) }
    end

    def near_miss_test_event?(event)
      project = event['project'].to_s.downcase
      cwd = event['cwd'].to_s.downcase
      return true if project.match?(/saneprocess-tier-tests|process-metrics-|near-miss-|trace-eval-|sop-review-|setapp_guard_project/)
      return true if cwd.match?(/\/tmp\/|saneprocess-tier-tests|near-miss-|process-metrics-|trace-eval-/)

      false
    end

    def near_miss_hook_candidates(events, min_count)
      hook_blocks = events.select { |event| event['type'] == 'hook_block' }
      hook_blocks.group_by { |event| near_miss_hook_family(event) }.map do |family, group|
        next if group.length < min_count

        rule = family[:rule]
        reason = family[:reason]
        tools = group.map { |event| near_miss_value(event['tool']) }.uniq.sort
        tool = tools.length == 1 ? tools.first : "#{tools.length} tools: #{tools.join(', ')}"
        severe = [rule, reason].join(' ').match?(/deploy|release|email|appcast|pages|keychain|blocked path/i)
        near_miss_candidate(
          id: "hook_block_recurrence:#{near_miss_slug(rule)}:#{near_miss_slug(reason)}",
          category: 'hook_block_recurrence',
          severity: severe ? 'high' : 'medium',
          confidence: 'high',
          title: "Recurring hook block: #{rule} / #{tool} / #{reason}",
          evidence: group,
          why: 'A hook repeatedly prevented the same unsafe path. Repetition means this should be converted into an eval fixture or clearer preflight guidance.',
          action: 'Promote the blocked pattern into agent_eval, trace_eval, or gate_review before the next similar workflow.',
          test: "Add a fixture that blocks #{near_miss_clip(reason, 48)} while allowing the safe canonical command."
        )
      end.compact
    end

    def near_miss_hook_family(event)
      {
        rule: near_miss_value(event['rule']),
        reason: near_miss_normalized_hook_reason(event['reason'])
      }
    end

    def near_miss_normalized_hook_reason(reason)
      near_miss_value(reason)
        .gsub(/\s+\[\d+\/\d+\s+read\]\z/i, '')
        .strip
    end

    def near_miss_verify_candidates(events, min_count)
      verify = events.select { |event| event['type'] == 'verify' }
      zero_test = verify.select { |event| event['success'] != true && event['tests_run'].to_i.zero? }
      candidates = zero_test.group_by { |event| near_miss_value(event['project']) }.map do |project, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "verify_zero_tests:#{near_miss_slug(project)}",
          category: 'weak_verification',
          severity: group.length >= 3 ? 'high' : 'medium',
          confidence: 'high',
          title: "#{project} has #{group.length} verify failures with zero tests run",
          evidence: group,
          why: 'Zero-test failures are high-signal because they usually mean the verifier, build routing, or test discovery failed before useful coverage ran.',
          action: 'Backtest the verify parser and add a specific regression fixture for the failure shape.',
          test: 'Add a verify_guard_test log fixture that proves this failure cannot be reported as tested or green.'
        )
      end.compact

      weak_success = verify.select { |event| event['success'] == true && event.key?('tests_run') && event['tests_run'].to_i.zero? }
      candidates.concat(weak_success.group_by { |event| near_miss_value(event['project']) }.map do |project, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "weak_test_evidence:#{near_miss_slug(project)}",
          category: 'weak_test_evidence',
          severity: 'medium',
          confidence: 'high',
          title: "#{project} has #{group.length} successful verify run(s) with zero tests counted",
          evidence: group,
          why: 'A green command with zero counted tests is weak evidence. It may be valid for syntax-only work, but it should not support a broad tested/done claim.',
          action: 'Rerun verification with countable test evidence or explicitly label the result as syntax/build-only.',
          test: 'Add a verify parser fixture where success=true and tests_run=0 cannot satisfy a tested customer-facing claim.'
        )
      end.compact)

      local_runtime = verify.select do |event|
        event['success'] == true && event.key?('host') && !near_miss_mini_host?(event['host'])
      end
      candidates.concat(local_runtime.group_by { |event| near_miss_value(event['project']) }.map do |project, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "missing_mini_proof:#{near_miss_slug(project)}",
          category: 'missing_mini_proof',
          severity: 'medium',
          confidence: 'high',
          title: "#{project} has #{group.length} successful verify run(s) without Mini proof",
          evidence: group,
          why: 'For SaneApps work, local success is not canonical proof. Mini routing keeps build/runtime evidence on the machine where urgent verification usually happens.',
          action: 'Rerun via SaneMaster Mini routing or mark the result as local-only evidence.',
          test: 'Backtest host fields so host=mini passes and host=local/MacBook-Air is reported.'
        )
      end.compact)

      recovered = recovered_verify_sequences(verify)
      candidates.concat(recovered.group_by { |entry| near_miss_value(entry[:project]) }.map do |project, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "verify_recovered:#{near_miss_slug(project)}",
          category: 'recovered_failure',
          severity: 'medium',
          confidence: 'medium',
          title: "#{project} recovered from #{group.length} failed verify run(s)",
          evidence: group.map { |entry| entry[:failure] },
          why: 'Recovered failures are useful training data: they show what the system eventually fixed and which earlier signal could have shortened the loop.',
          action: 'Sample these sessions and convert the repeated root cause into a pre-mortem fixture.',
          test: 'Add a trace_eval case requiring failure analysis before retry after two similar verify failures.'
        )
      end.compact)
      candidates
    end

    def near_miss_session_candidates(events, min_count)
      sessions = events.select { |event| event['type'] == 'session_end' }
      candidates = []

      unverified_edits = sessions.select { |event| event['edits'].to_i.positive? && event['verify_attempts'].to_i.zero? }
      if unverified_edits.length >= min_count
        candidates << near_miss_candidate(
          id: 'session_unverified_edits',
          category: 'compliance_theater',
          severity: 'high',
          confidence: 'high',
          title: "#{unverified_edits.length} edited session(s) ended with no verify attempt",
          evidence: unverified_edits,
          why: 'This is the exact failure mode where a session can cite process discipline while leaving no verification evidence.',
          action: 'Keep final status capped and add a claim/evidence lint before session close.',
          test: 'Add a process_eval fixture where edits plus zero verify attempts must produce a warning.'
        )
      end

      high_score_no_proof = sessions.select do |event|
        event['sop_score'].to_f >= 9.0 &&
          (event['verify_attempts'].nil? || event['final_verify_success'].nil?) &&
          event['edits'].to_i.positive?
      end
      if high_score_no_proof.length >= min_count
        candidates << near_miss_candidate(
          id: 'session_high_score_missing_receipts',
          category: 'compliance_theater',
          severity: 'medium',
          confidence: 'medium',
          title: "#{high_score_no_proof.length} high SOP session(s) have incomplete verification receipts",
          evidence: high_score_no_proof,
          why: 'High self-ratings are only useful when they cite objective evidence. Missing fields make later review weak.',
          action: 'Require evidence fields before high SOP scores count in trend analysis.',
          test: 'Extend sop_review tests so high ratings without receipt fields stay visible as review warnings.'
        )
      end

      missing_receipts = sessions.select { |event| NEAR_MISS_RECEIPT_FIELDS.any? { |field| event[field].nil? } }
      if missing_receipts.length >= [min_count, 3].max
        candidates << near_miss_candidate(
          id: 'session_receipt_field_gaps',
          category: 'evidence_quality',
          severity: 'medium',
          confidence: 'high',
          title: "#{missing_receipts.length} session receipt(s) are missing required fields",
          evidence: missing_receipts,
          why: 'Thin receipts make backtesting and SOP score audits depend on prose instead of facts.',
          action: 'Keep enriched sanestop receipts as the canonical shape and age out thin rows from active review windows.',
          test: 'Backtest recent session_end rows and assert missing receipt fields are reported with counts.'
        )
      end

      candidates
    end

    def near_miss_support_candidates(events, min_count)
      support = events.select { |event| event['type'] == 'support_send' }
      candidates = []

      failed = support.select do |event|
        event['success'] != true || event['delivery_event'].to_s.match?(/bounce|unconfirmed|failed/i)
      end
      candidates.concat(failed.group_by { |event| near_miss_value(event['channel']) }.map do |channel, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "support_delivery:#{near_miss_slug(channel)}",
          category: 'support_delivery',
          severity: 'high',
          confidence: 'high',
          title: "#{group.length} support #{channel} send(s) lacked delivery proof",
          evidence: group,
          why: 'Provider acceptance is not customer delivery. Failed or unconfirmed sends should stay actionable.',
          action: 'Add a delivery regression fixture and keep bounced/unconfirmed sends in the active inbox.',
          test: 'Backtest support_send metrics where accepted-but-unconfirmed must not count as resolved.'
        )
      end.compact)

      replies = support.select { |event| event['channel'].to_s == 'reply' }
      promise_events = events.select { |event| %w[support_promise promise_ledger].include?(event['type'].to_s) }
      if replies.length >= min_count && promise_events.empty?
        candidates << near_miss_candidate(
          id: 'support_reply_without_promise_ledger',
          category: 'promise_traceability',
          severity: 'medium',
          confidence: 'low',
          title: "#{replies.length} support replies found, but no structured promise ledger events",
          evidence: replies,
          why: 'Release prep should reconcile customer promises from structured state, not rediscover them from prose.',
          action: 'Instrument promise records for replies that contain fix, next-release, workaround, or known-edge-case language.',
          test: 'Add a support workflow fixture proving promise-like replies create a promise ledger entry.'
        )
      end

      candidates
    end

    def near_miss_workflow_candidates(events, min_count)
      review_types = %w[
        agent_eval process_eval trace_eval skill_lint gate_review visual_smoke
        customer_ui_contract customer_ui_sweep agent_env_review
      ]
      failed = events.select { |event| review_types.include?(event['type'].to_s) && event['success'] == false }
      candidates = failed.group_by { |event| event['type'].to_s }.map do |type, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "workflow_churn:#{near_miss_slug(type)}",
          category: 'workflow_churn',
          severity: type.match?(/visual|customer|process|trace/) ? 'high' : 'medium',
          confidence: 'medium',
          title: "#{type} failed #{group.length} time(s) in the review window",
          evidence: group,
          why: 'Repeated workflow check failures are candidates for clearer fixtures, better defaults, or earlier routing.',
          action: 'Inspect the failed cases and promote the root cause into the relevant fixture set.',
          test: "Add a regression case to #{type} coverage before changing adjacent workflow rules."
        )
      end.compact
      local_ui = events.select do |event|
        %w[visual_smoke customer_ui_contract customer_ui_sweep].include?(event['type'].to_s) &&
          event['success'] == true &&
          event.key?('host') &&
          !near_miss_mini_host?(event['host'])
      end
      candidates.concat(local_ui.group_by { |event| event['type'].to_s }.map do |type, group|
        next if group.length < min_count

        near_miss_candidate(
          id: "missing_mini_proof:#{near_miss_slug(type)}",
          category: 'missing_mini_proof',
          severity: 'high',
          confidence: 'high',
          title: "#{type} has #{group.length} successful UI proof event(s) from non-Mini hosts",
          evidence: group,
          why: 'Customer-visible runtime proof must be captured on the Mini unless the user explicitly approves a local fallback.',
          action: 'Re-run visual_smoke, customer_ui_contract, or customer_ui_sweep through Mini-first SaneMaster routing.',
          test: 'Add a paired backtest: local UI proof is flagged, Mini UI proof is accepted.'
        )
      end.compact)
      candidates
    end

    def recovered_verify_sequences(verify_events)
      verify_events.group_by { |event| near_miss_value(event['project']) }.flat_map do |project, group|
        sorted = group.sort_by { |event| near_miss_time(event) }
        pending_failures = []
        sorted.each_with_object([]) do |event, memo|
          if event['success'] == true
            pending_failures.each { |failure| memo << { project: project, failure: failure, recovery: event } }
            pending_failures.clear
          else
            pending_failures << event
          end
        end
      end
    end

    def near_miss_candidate(id:, category:, severity:, confidence:, title:, evidence:, why:, action:, test:)
      {
        id: id,
        category: category,
        severity: severity,
        confidence: confidence,
        title: title,
        evidence_count: evidence.length,
        evidence_examples: evidence.last(3).map { |event| near_miss_example(event) },
        why_it_matters: why,
        proposed_action: action,
        proposed_test: test
      }
    end

    def near_miss_example(event)
      {
        timestamp: event['timestamp'],
        project: event['project'],
        type: event['type'],
        detail: near_miss_detail(event)
      }.compact
    end

    def near_miss_detail(event)
      keys = %w[rule tool reason success tests_run evidence_strength failure_bucket failure_hint host verify_attempts verify_failures channel delivery_event failed]
      keys.map { |key| "#{key}=#{event[key]}" if event.key?(key) }.compact.join(' ')
    end

    def near_miss_value(value)
      value.to_s.empty? ? 'unknown' : value.to_s
    end

    def near_miss_slug(value)
      near_miss_value(value).downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-+\z/, '')[0, 64]
    end

    def near_miss_clip(value, max)
      text = near_miss_value(value).gsub(/\s+/, ' ').strip
      text.length > max ? "#{text[0, max - 3]}..." : text
    end

    def near_miss_time(event)
      Time.parse(event['timestamp'].to_s)
    rescue ArgumentError, TypeError
      Time.at(0)
    end

    def near_miss_mini_host?(host)
      host.to_s.downcase.include?('mini')
    end

    def near_miss_severity_rank(severity)
      { 'high' => 0, 'medium' => 1, 'low' => 2 }.fetch(severity.to_s, 3)
    end

    def print_near_miss_review(result)
      puts 'Near-Miss Review'
      puts '=' * 16
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Events reviewed: #{result[:lookback_events]} of #{result[:total_events]} (ignored test events: #{result[:ignored_test_events]})"
      puts "Candidates: #{result.dig(:summary, :candidate_count)} (high: #{result.dig(:summary, :high_count)})"
      puts
      result[:candidates].each do |candidate|
        puts "[#{candidate[:severity].upcase}] #{candidate[:title]}"
        puts "  Category: #{candidate[:category]} | confidence: #{candidate[:confidence]} | evidence: #{candidate[:evidence_count]}"
        puts "  Why: #{candidate[:why_it_matters]}"
        puts "  Action: #{candidate[:proposed_action]}"
        puts "  Test: #{candidate[:proposed_test]}"
        candidate[:evidence_examples].each do |example|
          puts "    - #{example[:timestamp]} #{example[:project]} #{example[:detail]}"
        end
      end
      puts 'No near-miss candidates found in this window.' if result[:candidates].empty?
    end
  end
end
