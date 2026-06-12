# frozen_string_literal: true

require 'json'
require 'csv'
require 'time'

module SaneMasterModules
  module ProcessEval
    DEFAULT_PROCESS_EVAL_FIXTURE = File.expand_path('../process_eval_fixtures.json', __dir__)
    DEFAULT_ABTEST_RECEIPT_DIR = File.expand_path('../../outputs/process-abtest', __dir__)
    LIVE_TELEMETRY_TYPES = %w[
      workflow_receipt verify agent_eval skill_lint process_eval trace_eval
      gate_review hook_block trajectory_event proof_plan session_end session_receipt visual_smoke
    ].freeze
    BOOKKEEPING_WORKFLOW_PATTERNS = [
      /mcp_watchdog/i
    ].freeze
    META_TELEMETRY_TYPES = %w[
      agent_eval agent_env_review gate_review process_eval skill_lint trace_eval
    ].freeze
    META_WORKFLOW_PATTERNS = [
      /agent[_-]env[_-]review/i,
      /agent[_-]eval/i,
      /gate[_-]review/i,
      /process[_-]eval/i,
      /skill[_-]lint/i,
      /trace[_-]eval/i
    ].freeze
    UI_PROOF_WORKFLOW_PATTERNS = [
      /customer[_-]ui[_-](sweep|contract)/i,
      /visual[_-]smoke/i
    ].freeze
    REQUIRED_ABTEST_RECEIPT_FIELDS = %w[
      schema_version id completed_at task source protocol_path scoring_path
      arms judge scores costs completion verification_strategy validation_delta
      decisive_mechanisms pending_actions
    ].freeze
    REQUIRED_SESSION_RECEIPT_FIELDS = %w[
      schema_version receipt_id session_id client_name client_kind host git_root
      git_head source_fingerprint started_at completed_at duration_ms edits
      unique_files changed_file_count block_count verify_attempts verify_failures
      final_verify_success final_verify_tests_run final_verify_evidence_strength
      final_verify_timestamp sop_score base_score scorer_version success
    ].freeze

    def process_eval(args = [])
      options = parse_process_eval_options(args)
      result = build_process_eval(options)
      record_process_metric(
        'process_eval',
        success: result[:passed],
        traces: result.dig(:trace_eval, :trace_count),
        failed: result.dig(:trace_eval, :failed_count),
        abtests: result.dig(:abtest_review, :receipt_count),
        abtest_blockers: result.dig(:abtest_review, :blockers)&.length.to_i,
        sop_warnings: result.dig(:sop_review, :warnings)&.length.to_i,
        trajectory_warnings: result.dig(:trajectory_efficiency, :warnings)&.length.to_i
      ) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_process_eval(result)
      end

      result[:passed]
    end

    def trace_eval(args = [])
      options = parse_process_eval_options(args)
      result = run_trace_eval_fixture(options.fetch(:fixture, DEFAULT_PROCESS_EVAL_FIXTURE))
      record_process_metric('trace_eval', success: result[:passed], traces: result[:trace_count], failed: result[:failed_count]) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_trace_eval(result)
      end

      result[:passed]
    end

    def sop_review(args = [])
      options = parse_process_eval_options(args)
      result = build_sop_review(read_process_metric_events)
      record_process_metric('sop_review', success: result[:blockers].empty?, warnings: result[:warnings].length, blockers: result[:blockers].length) if respond_to?(:record_process_metric)

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_sop_review(result)
      end

      result
    end

    def build_process_eval(options = {})
      trace_result = run_trace_eval_fixture(options.fetch(:fixture, DEFAULT_PROCESS_EVAL_FIXTURE))
      events = read_process_metric_events
      sop_result = build_sop_review(events)
      live_result = build_live_telemetry_review(events, require_ui_proof: options[:require_ui_proof])
      abtest_result = build_abtest_review(options.fetch(:abtest_dir, DEFAULT_ABTEST_RECEIPT_DIR))
      trajectory_result = build_trajectory_efficiency_review(events)
      {
        generated_at: Time.now.utc.iso8601,
        fixture: trace_result[:fixture],
        passed: trace_result[:passed] && sop_result[:blockers].empty? && live_result[:blockers].empty? && abtest_result[:blockers].empty? && trajectory_result[:blockers].empty?,
        trace_eval: trace_result,
        sop_review: sop_result,
        live_telemetry: live_result,
        abtest_review: abtest_result,
        trajectory_efficiency: trajectory_result
      }
    end

    def run_trace_eval_fixture(fixture_path)
      fixture = JSON.parse(File.read(fixture_path))
      traces = Array(fixture.fetch('traces'))
      results = traces.map { |trace| evaluate_trace_case(trace) }
      failed = results.reject { |entry| entry[:passed] }
      {
        fixture: fixture_path,
        trace_count: results.length,
        passed_count: results.length - failed.length,
        failed_count: failed.length,
        passed: failed.empty?,
        traces: results
      }
    end

    def build_abtest_review(receipt_dir = DEFAULT_ABTEST_RECEIPT_DIR)
      receipts = read_abtest_receipts(receipt_dir)
      blockers = []
      warnings = []
      actions = []
      total_correct = 0
      total_wrong = 0
      total_sessions = 0
      total_wait_stalls = 0
      total_orchestrator_nudges = 0
      total_known_unrelated_red_gates = 0

      if receipts.empty?
        warnings << 'no process A/B receipts found; slimming decisions should wait for real comparative runs'
        actions << 'record real A/B runs as outputs/process-abtest/*.json before changing the process surface'
      end

      receipt_results = receipts.map do |entry|
        issues = validate_abtest_receipt(entry[:receipt])
        delta = entry[:receipt]['validation_delta'] || {}
        correct = delta['blocks_that_were_correct'].to_i
        wrong = delta['blocks_that_were_wrong'].to_i
        total_correct += correct
        total_wrong += wrong
        completion = abtest_completion_summary(entry[:receipt])
        total_sessions += completion[:sessions_to_complete]
        total_wait_stalls += completion[:wait_state_stalls]
        total_orchestrator_nudges += completion[:orchestrator_nudges]
        total_known_unrelated_red_gates += completion[:known_unrelated_red_gates]

        blockers.concat(issues.map { |issue| "#{entry[:path]}: #{issue}" })
        {
          path: entry[:path],
          id: entry[:receipt]['id'],
          task: entry[:receipt].dig('task', 'name') || entry[:receipt]['task'],
          passed: issues.empty?,
          issues: issues,
          validation_delta: {
            blocks_that_were_correct: correct,
            blocks_that_were_wrong: wrong
          },
          completion: completion
        }
      end

      actions << 'protect mechanisms with positive A/B validation deltas; cut or rewrite gates with repeated wrong/theater tags'
      actions << 'compare sessions-to-complete and wait-state stalls before expanding heavyweight verification flows'

      {
        receipt_dir: receipt_dir,
        receipt_count: receipts.length,
        passed_count: receipt_results.count { |entry| entry[:passed] },
        failed_count: receipt_results.count { |entry| !entry[:passed] },
        validation_delta: {
          blocks_that_were_correct: total_correct,
          blocks_that_were_wrong: total_wrong
        },
        completion: {
          sessions_to_complete: total_sessions,
          wait_state_stalls: total_wait_stalls,
          orchestrator_nudges: total_orchestrator_nudges,
          known_unrelated_red_gates: total_known_unrelated_red_gates
        },
        receipts: receipt_results,
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    def evaluate_trace_case(trace)
      events = Array(trace.fetch('events'))
      expected = trace.fetch('expect', {})
      issues = []

      Array(expected['required_events']).each do |pattern|
        issues << "missing required event #{pattern}" unless events.any? { |event| trace_event_matches?(event, pattern) }
      end

      Array(expected['ordered_events']).each_cons(2) do |first, second|
        first_index = trace_event_index(events, first)
        second_index = trace_event_index(events, second)
        if first_index.nil? || second_index.nil?
          issues << "cannot validate order #{first} before #{second}"
        elsif first_index >= second_index
          issues << "event #{first} must occur before #{second}"
        end
      end

      Array(expected['forbidden_events']).each do |pattern|
        matched = events.find { |event| trace_event_matches?(event, pattern) }
        issues << "forbidden event #{pattern} present as #{trace_event_label(matched)}" if matched
      end

      Hash(expected['min_counts'] || {}).each do |type, count|
        actual = events.count { |event| event['type'].to_s == type.to_s }
        issues << "expected at least #{count} #{type} events, got #{actual}" if actual < count.to_i
      end

      {
        id: trace.fetch('id'),
        description: trace['description'],
        passed: issues.empty?,
        issues: issues,
        event_count: events.length
      }
    end

    def build_sop_review(events)
      session_receipts = events.select { |event| event['type'] == 'session_receipt' }
      sessions = session_receipts.any? ? session_receipts : events.select { |event| event['type'] == 'session_end' }
      verify = events.select { |event| event['type'] == 'verify' }
      csv_scores = read_sop_rating_csv
      trusted_csv_scores = csv_scores.select { |row| row[:trusted] }
      legacy_csv_scores = csv_scores.reject { |row| row[:trusted] }
      no_work_sessions = sessions.select { |event| no_work_session_metric?(event) }
      score_sessions = sessions - no_work_sessions
      trusted_work_csv_scores = trusted_csv_scores.reject { |row| row[:no_work] }
      scores = score_sessions.map { |event| event['sop_score'].to_f }.reject(&:zero?)
      scores = trusted_work_csv_scores.map { |row| row[:score].to_f }.reject(&:zero?) if scores.empty?
      warnings = []
      blockers = []
      actions = []

      warnings << 'no session_end metrics found; SOP history cannot explain recent self-assessments' if sessions.empty?
      if csv_scores.empty? && sessions.empty?
        warnings << 'outputs/sop_ratings.csv is missing or empty; sanestop score history is thin'
      end
      if legacy_csv_scores.any?
        warnings << "ignored #{legacy_csv_scores.length} legacy SOP CSV row(s) without receipt proof; active SOP review requires structured receipts"
        actions << 'retire legacy clean-session SOP CSV rows from active review windows after structured receipts accumulate'
      end
      if no_work_sessions.any?
        warnings << "excluded #{no_work_sessions.length} no-work session metric(s) from SOP score trends"
        actions << 'keep no-work sessions visible, but score process quality from edited, verified, or blocked work'
      end
      warnings << 'fewer than 30 session_end metrics; SOP trend confidence is weak' if sessions.length.positive? && sessions.length < 30

      verify_attempts = verify.length
      verify_passes = verify.count { |event| event['success'] == true }
      verify_pass_rate = verify_attempts.positive? ? ((verify_passes.to_f / verify_attempts) * 100).round(1) : nil
      recovered_green = sessions.count { |event| event['success'] == true && event['verify_failures'].to_i.positive? }
      unrecovered_failures = sessions.count { |event| event['success'] != true && event['edits'].to_i.positive? }
      cap_mismatches = sessions.select do |event|
        event['success'] == true &&
          event['verify_failures'].to_i.positive? &&
          event['sop_score'].to_f > 8.0
      end
      cap_mismatches += sessions.select do |event|
        event['success'] != true &&
          event['edits'].to_i.positive? &&
          event['sop_score'].to_f > 6.0
      end
      cap_mismatches += sessions.select do |event|
        event['success'] == true &&
          ((event.key?('final_verify_tests_run') && event['final_verify_tests_run'].to_i.zero?) ||
            event['final_verify_evidence_strength'].to_s == 'build_only') &&
          event['verify_attempts'].to_i.positive? &&
          event['sop_score'].to_f > 8.0
      end
      receipt_fields = session_receipts.any? ? REQUIRED_SESSION_RECEIPT_FIELDS : %w[
        session_id client base_score block_count verify_attempts verify_failures
        verify_zero_test_failures final_verify_success final_verify_tests_run
        final_verify_evidence_strength final_verify_timestamp
      ]
      recent_receipt_samples = session_receipts.any? ? session_receipts.last(10) : sessions.last(10)
      missing_receipt_fields = receipt_fields.each_with_object({}) do |field, memo|
        missing = recent_receipt_samples.count { |event| event[field].nil? }
        memo[field] = missing if missing.positive?
      end
      high_score_missing_receipts = recent_receipt_samples.select do |event|
        (event['type'] == 'session_receipt' || event['schema_version'].to_i >= 2) &&
          event['sop_score'].to_f >= 9.0 &&
          receipt_fields.any? { |field| event[field].nil? }
      end

      score_average = scores.empty? ? nil : (scores.sum / scores.length).round(2)
      score_stddev = score_standard_deviation(scores)
      recent_scores = scores.last(10)
      recent_average = recent_scores.empty? ? nil : (recent_scores.sum / recent_scores.length).round(2)
      recent_stddev = score_standard_deviation(recent_scores)

      if scores.length >= 5 && score_average && score_average >= 9.5 && score_stddev && score_stddev < 0.5
        warnings << "SOP scores are very high with low variance (avg #{score_average}, stddev #{score_stddev}); inspect for score inflation"
        actions << 'require evidence notes and cap reasons beside manual SOP ratings'
      end

      if recent_scores.length >= 5 && recent_average && recent_average >= 9.5 && recent_stddev && recent_stddev < 0.5
        warnings << "recent SOP scores are very high with low variance (avg #{recent_average}, stddev #{recent_stddev}); inspect the last #{recent_scores.length} ratings"
        actions << 'sample recent high ratings against verification, Mini proof, context, handoff, and memory evidence'
      end

      if cap_mismatches.any?
        blockers << "#{cap_mismatches.length} session_end score(s) exceed objective verification cap"
        actions << 'route SOP score calculation through one shared scorer before writing ratings'
      end

      if recent_receipt_samples.any? && missing_receipt_fields.any?
        warnings << "recent session_end metrics are missing receipt fields: #{missing_receipt_fields.map { |field, count| "#{field}=#{count}" }.join(', ')}"
        actions << 'let new sanestop session_end metrics accumulate, then retire old thin SOP rows from active review windows'
      end

      if high_score_missing_receipts.any?
        blockers << "#{high_score_missing_receipts.length} high-score session receipt(s) are missing required proof fields"
        actions << 'do not rate SOP 9+ without complete client-neutral session_receipt fields'
      end

      if unrecovered_failures.positive?
        warnings << "#{unrecovered_failures} edited session(s) ended without green verification"
        actions << 'keep GREEN MEANS GO as a hard gate before final status'
      end

      if sessions.empty? || missing_receipt_fields.any? || high_score_missing_receipts.any?
        actions << 'expand SOP receipts with session_id, block counts, cap_reason, verification status, and client'
      end
      actions << 'run process_eval after changing hooks, SaneMaster routing, support, release, UI verification, or session-end policy'

      {
        metrics_path: respond_to?(:process_metrics_path) ? process_metrics_path : nil,
        sop_csv_path: sop_rating_csv_path,
        sessions: {
          total: sessions.length,
          scored_total: score_sessions.length,
          no_work_excluded: no_work_sessions.length,
          recovered_green: recovered_green,
          unrecovered_failures: unrecovered_failures,
          average_sop_score: score_average,
          score_stddev: score_stddev,
          recent_average_sop_score: recent_average,
          recent_score_stddev: recent_stddev,
          cap_mismatches: cap_mismatches.length,
          receipt_field_gaps: missing_receipt_fields
        },
        verify: {
          attempts: verify_attempts,
          passes: verify_passes,
          pass_rate: verify_pass_rate,
          zero_test_failures: verify.count { |event| event['success'] != true && event['tests_run'].to_i.zero? },
          zero_test_successes: verify.count { |event| event['success'] == true && event.key?('tests_run') && event['tests_run'].to_i.zero? }
        },
        sop_csv: {
          rows: csv_scores.length,
          trusted_rows: trusted_csv_scores.length,
          trusted_work_rows: trusted_work_csv_scores.length,
          legacy_rows_ignored: legacy_csv_scores.length,
          last_score: trusted_csv_scores.last && trusted_csv_scores.last[:score],
          last_note: trusted_csv_scores.last && trusted_csv_scores.last[:note]
        },
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    def build_live_telemetry_review(events, options = {})
      require_ui_proof = options[:require_ui_proof] == true
      relevant = events.select { |event| LIVE_TELEMETRY_TYPES.include?(event['type'].to_s) }
      task_relevant = relevant.reject { |event| bookkeeping_workflow_event?(event) }
      recent = relevant.last(100)
      recent_task = task_relevant.last(100)
      blockers = []
      warnings = []
      actions = []

      blockers << 'no live process telemetry found; process_eval is relying only on fixture traces' if recent_task.empty?

      runner_backed = recent_task.select { |event| outcome_telemetry_event?(event) }
      blockers << 'no recent runner-backed telemetry found for process_eval; session summaries alone are not proof' if recent_task.any? && runner_backed.empty?

      recent_task.select { |event| event['type'] == 'workflow_receipt' }.each do |event|
        label = event['workflow'] || event['command'] || event['timestamp'] || 'unknown workflow_receipt'
        blockers << "workflow_receipt missing workflow: #{label}" if event['workflow'].to_s.strip.empty?
        blockers << "workflow_receipt missing command: #{label}" if event['command'].to_s.strip.empty?
        blockers << "workflow_receipt missing success boolean: #{label}" unless event.key?('success') && [true, false].include?(event['success'])
        if event['schema_version'].to_i >= 2
          %w[started_at completed_at duration_ms exit_status host command_sha256].each do |field|
            blockers << "workflow_receipt v2 missing #{field}: #{label}" if event[field].nil? || event[field].to_s.strip.empty?
          end
        end
      end
      recent_task.select { |event| event['type'] == 'session_receipt' }.each do |event|
        label = event['receipt_id'] || event['session_id'] || event['timestamp'] || 'session_receipt'
        blockers << "session_receipt missing schema_version: #{label}" if event['schema_version'].to_i < 2
        REQUIRED_SESSION_RECEIPT_FIELDS.each do |field|
          blockers << "session_receipt v2 missing #{field}: #{label}" if event[field].nil? || event[field].to_s.strip.empty?
        end
      end

      recent_task.select { |event| event['type'] == 'process_eval' }.each do |event|
        label = event['timestamp'] || 'process_eval'
        blockers << "process_eval metric missing trace count: #{label}" unless event.key?('traces')
        blockers << "process_eval metric missing failed count: #{label}" unless event.key?('failed')
      end

      recent_task.select { |event| event['type'] == 'agent_eval' }.each do |event|
        label = event['timestamp'] || 'agent_eval'
        blockers << "agent_eval metric missing case count: #{label}" unless event.key?('cases')
        blockers << "agent_eval metric missing failed count: #{label}" unless event.key?('failed')
      end

      workflow_receipts = recent_task.select { |event| event['type'] == 'workflow_receipt' }
      successful_receipts = workflow_receipts.select { |event| event['success'] == true }
      enriched_receipts = workflow_receipts.select { |event| event['schema_version'].to_i >= 2 }
      thin_receipts = workflow_receipts - enriched_receipts
      warnings << 'no successful live workflow_receipt events found in recent telemetry' if workflow_receipts.any? && successful_receipts.empty?
      warnings << "#{thin_receipts.length} legacy workflow_receipt event(s) lack v2 audit fields" if thin_receipts.any?
      warnings << 'no enriched workflow_receipt v2 events found in recent telemetry' if workflow_receipts.any? && enriched_receipts.empty?

      visual_smoke = recent.select { |event| event['type'] == 'visual_smoke' && event['dry_run'] != true && event['status'].to_s != 'planned' }
      successful_visual_smoke = visual_smoke.select { |event| event['success'] == true }
      mini_visual_smoke = successful_visual_smoke.select { |event| event['host'].to_s.downcase.include?('mini') }
      failed_visual_smoke = visual_smoke.reject { |event| event['success'] == true }
      ui_proof = recent_task.select { |event| ui_proof_event?(event) }
      successful_ui_proof = ui_proof.select { |event| event['success'] == true }
      mini_ui_proof = successful_ui_proof.select { |event| event['host'].to_s.downcase.include?('mini') }
      failed_ui_proof = ui_proof.reject { |event| event['success'] == true }
      if ui_proof.empty?
        message = 'no recent live UI-proof metrics; UI runtime receipt remains fixture-only'
        require_ui_proof ? blockers << message : warnings << message
      elsif successful_ui_proof.any? && mini_ui_proof.empty?
        message = 'recent UI-proof success is not Mini-host proof; do not treat it as canonical SaneApps UI evidence'
        require_ui_proof ? blockers << message : warnings << message
      elsif require_ui_proof && mini_ui_proof.empty?
        blockers << 'required UI-proof metrics have no successful Mini-host receipt'
      end
      if failed_visual_smoke.any?
        sample = failed_visual_smoke.last
        warnings << "recent visual_smoke failure exists for #{sample['app'] || 'unknown app'}: #{sample['status'] || 'failed'} #{sample['reason']}".strip
      end
      if failed_ui_proof.any? && failed_visual_smoke.empty?
        sample = failed_ui_proof.last
        warnings << "recent UI-proof failure exists for #{sample['workflow'] || sample['app'] || 'unknown app'}: #{sample['status'] || sample['exit_status'] || 'failed'}".strip
      end

      actions << 'run runner-backed workflows through SaneMaster so workflow_receipt metrics capture success, command, and workflow'
      actions << 'keep fixture traces for expectations, but inspect live_telemetry before treating process_eval as runtime proof'

      {
        metrics_path: respond_to?(:process_metrics_path) ? process_metrics_path : nil,
        event_count: recent_task.length,
        ignored_bookkeeping_events: relevant.length - task_relevant.length,
        by_type: recent_task.group_by { |event| event['type'].to_s }.transform_values(&:length).sort.to_h,
        workflow_receipts: {
          total: workflow_receipts.length,
          successful: successful_receipts.length,
          enriched: enriched_receipts.length,
          thin: thin_receipts.length
        },
        visual_smoke: {
          total: visual_smoke.length,
          successful: successful_visual_smoke.length,
          mini_successful: mini_visual_smoke.length,
          failed: failed_visual_smoke.length
        },
        ui_proof: {
          total: ui_proof.length,
          successful: successful_ui_proof.length,
          mini_successful: mini_ui_proof.length,
          failed: failed_ui_proof.length,
          required: require_ui_proof
        },
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    def build_trajectory_efficiency_review(events)
      relevant = events.select { |event| LIVE_TELEMETRY_TYPES.include?(event['type'].to_s) }.last(250)
      workflow_receipts = relevant.select { |event| event['type'].to_s == 'workflow_receipt' }
      proof_plans = relevant.select { |event| event['type'].to_s == 'proof_plan' }
      block_events = relevant.select do |event|
        event['type'].to_s == 'hook_block' ||
          (event['type'].to_s == 'trajectory_event' && event['blocked'] == true)
      end
      warnings = []
      blockers = []
      actions = []

      repeated_blocks = repeated_trajectory_blocks(block_events)
      repeated_blocks.each do |entry|
        warnings << "same block repeated #{entry[:count]}x: #{entry[:rule]} / #{entry[:reason]}"
      end

      broad_after_focused = workflow_receipts.select do |event|
        event['proof_scope_planned'].to_s == 'focused_mini' &&
          event['proof_scope_actual'].to_s == 'full_canonical'
      end
      if broad_after_focused.any?
        warnings << "#{broad_after_focused.length} scoped task receipt(s) ran full canonical proof before/with focused proof"
        actions << 'inspect proof_plan timing and prefer focused Mini proof before broad verify for scoped behavior work'
      end

      if proof_plans.any? && workflow_receipts.any?
        first_plan_time = metric_time(proof_plans.first)
        first_workflow_time = metric_time(workflow_receipts.first)
        if first_plan_time && first_workflow_time && first_plan_time > first_workflow_time
          warnings << 'proof_plan occurred after workflow execution in the recent trajectory'
          actions << 'run proof_plan before expensive or proof-sensitive workflows'
        end
      end

      diagnostic_successes = workflow_receipts.select do |event|
        event['success'] == true && event['outcome_strength'].to_s == 'diagnostic'
      end
      authoritative_or_scoped = workflow_receipts.select do |event|
        event['success'] == true && %w[authoritative scoped].include?(event['outcome_strength'].to_s)
      end
      if diagnostic_successes.any? && authoritative_or_scoped.empty?
        warnings << "#{diagnostic_successes.length} diagnostic-only workflow success(es) with no authoritative/scoped outcome in the recent trajectory"
        actions << 'do not treat diagnostic-only success as customer-facing or release proof'
      end

      if repeated_blocks.any?
        actions << 'turn repeated hook-block families into preflight guidance, auto-satisfy paths, or eval fixtures'
      end

      {
        event_count: relevant.length,
        proof_plan_count: proof_plans.length,
        workflow_receipt_count: workflow_receipts.length,
        repeated_block_count: repeated_blocks.length,
        planned_focused_ran_broad_count: broad_after_focused.length,
        diagnostic_only_success_count: diagnostic_successes.length,
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    def repeated_trajectory_blocks(block_events)
      block_events.group_by { |event| [event['rule'].to_s.empty? ? 'unknown' : event['rule'].to_s, normalized_block_reason(event['reason'])] }
                  .map do |(rule, reason), group|
        next if group.length < 3

        { rule: rule, reason: reason, count: group.length }
      end.compact
    end

    def normalized_block_reason(reason)
      reason.to_s.gsub(/\s+\[\d+\/\d+\s+read\]\z/i, '').strip
    end

    def metric_time(event)
      Time.parse(event['timestamp'].to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def bookkeeping_workflow_event?(event)
      return false unless event['type'].to_s == 'workflow_receipt'

      label = [event['workflow'], event['command']].compact.join(' ')
      BOOKKEEPING_WORKFLOW_PATTERNS.any? { |pattern| label.match?(pattern) }
    end

    def outcome_telemetry_event?(event)
      type = event['type'].to_s
      return SaneProcessMetrics.authoritative_verify_event?(event) if type == 'verify'
      return true if type == 'visual_smoke' && event['dry_run'] != true && event['status'].to_s != 'planned'
      return false if META_TELEMETRY_TYPES.include?(type)
      return false if %w[session_end session_receipt hook_block trajectory_event].include?(type)
      return outcome_workflow_receipt?(event) if type == 'workflow_receipt'

      true
    end

    def outcome_workflow_receipt?(event)
      label = [event['workflow'], event['command']].compact.join(' ')
      return false if label.empty?

      !META_WORKFLOW_PATTERNS.any? { |pattern| label.match?(pattern) }
    end

    def ui_proof_event?(event)
      return true if event['type'].to_s == 'visual_smoke' && event['dry_run'] != true && event['status'].to_s != 'planned'
      return false unless event['type'].to_s == 'workflow_receipt'

      label = [event['workflow'], event['command']].compact.join(' ')
      UI_PROOF_WORKFLOW_PATTERNS.any? { |pattern| label.match?(pattern) }
    end

    private

    def parse_process_eval_options(args)
      options = { json: false, require_ui_proof: false }
      rest = args.dup
      until rest.empty?
        token = rest.shift
        case token
        when '--json'
          options[:json] = true
        when '--require-ui-proof'
          options[:require_ui_proof] = true
        when '--fixture'
          value = rest.shift
          raise ArgumentError, '--fixture requires a path' if value.to_s.empty?

          options[:fixture] = File.expand_path(value)
        when '--abtest-dir'
          value = rest.shift
          raise ArgumentError, '--abtest-dir requires a path' if value.to_s.empty?

          options[:abtest_dir] = File.expand_path(value)
        end
      end
      options
    end

    def read_abtest_receipts(receipt_dir)
      return [] unless Dir.exist?(receipt_dir)

      Dir.glob(File.join(receipt_dir, '*.json')).sort.map do |path|
        JSON.parse(File.read(path)).then { |receipt| { path: path, receipt: receipt } }
      rescue JSON::ParserError => e
        { path: path, receipt: { 'id' => File.basename(path), '_parse_error' => e.message } }
      end.compact
    end

    def validate_abtest_receipt(receipt)
      issues = []
      if receipt['_parse_error']
        return ["invalid JSON: #{receipt['_parse_error']}"]
      end

      REQUIRED_ABTEST_RECEIPT_FIELDS.each do |field|
        value = receipt[field]
        issues << "missing #{field}" if value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      issues << 'schema_version must be 1 or 2' unless [1, 2].include?(receipt['schema_version'].to_i)
      task = receipt['task'].is_a?(Hash) ? receipt['task'] : {}
      issues << 'task must name a real repo or app' if task['repo'].to_s.strip.empty? && task['app'].to_s.strip.empty?
      issues << 'task must describe a real customer/tooling failure' if task['failure'].to_s.strip.empty?

      arms = receipt['arms'].is_a?(Hash) ? receipt['arms'] : {}
      %w[vanilla harness].each do |arm|
        arm_data = arms[arm].is_a?(Hash) ? arms[arm] : {}
        issues << "arm #{arm} missing checkout" if arm_data['checkout'].to_s.strip.empty?
        issues << "arm #{arm} missing outcome" if arm_data['outcome'].to_s.strip.empty?
        verification = arm_data['verification'].is_a?(Hash) ? arm_data['verification'] : {}
        issues << "arm #{arm} missing endpoint verification command" if verification['command'].to_s.strip.empty?
        issues << "arm #{arm} missing verification host" if verification['host'].to_s.strip.empty?
        issues << "arm #{arm} missing verification result" if verification['result'].to_s.strip.empty?
      end

      judge = receipt['judge'].is_a?(Hash) ? receipt['judge'] : {}
      issues << 'judge must be blind' unless judge['blind'] == true
      issues << 'judge must name a winner' if judge['winner'].to_s.strip.empty?

      scores = receipt['scores'].is_a?(Hash) ? receipt['scores'] : {}
      %w[vanilla harness].each do |arm|
        issues << "scores missing #{arm}" unless scores[arm].is_a?(Numeric)
      end

      costs = receipt['costs'].is_a?(Hash) ? receipt['costs'] : {}
      %w[vanilla harness].each do |arm|
        arm_cost = costs[arm].is_a?(Hash) ? costs[arm] : {}
        issues << "costs missing #{arm} tokens" unless arm_cost['tokens'].to_i.positive?
        unless arm_cost['duration_minutes'].to_f.positive? || !arm_cost['duration_note'].to_s.strip.empty?
          issues << "costs missing #{arm} duration_minutes or duration_note"
        end
      end

      completion = receipt['completion'].is_a?(Hash) ? receipt['completion'] : {}
      %w[vanilla harness].each do |arm|
        arm_completion = completion[arm].is_a?(Hash) ? completion[arm] : {}
        issues << "completion missing #{arm} sessions_to_complete" unless arm_completion['sessions_to_complete'].to_i.positive?
        %w[wait_state_stalls orchestrator_nudges].each do |field|
          value = arm_completion[field]
          issues << "completion missing #{arm} #{field}" unless nonnegative_number_value?(value)
        end
      end

      strategy = receipt['verification_strategy'].is_a?(Hash) ? receipt['verification_strategy'] : {}
      %w[vanilla harness].each do |arm|
        arm_strategy = strategy[arm].is_a?(Hash) ? strategy[arm] : {}
        issues << "verification_strategy missing #{arm} proof_scope_selected" if arm_strategy['proof_scope_selected'].to_s.strip.empty?
        issues << "verification_strategy missing #{arm} proof_result" if arm_strategy['proof_result'].to_s.strip.empty?
      end

      delta = receipt['validation_delta'].is_a?(Hash) ? receipt['validation_delta'] : {}
      if delta['blocks_that_were_correct'].to_i.zero? && delta['blocks_that_were_wrong'].to_i.zero?
        issues << 'validation_delta must record at least one block classification'
      end

      mechanisms = Array(receipt['decisive_mechanisms'])
      issues << 'decisive_mechanisms must name concrete workflow mechanisms' if mechanisms.empty?
      mechanisms.each do |mechanism|
        if mechanism.is_a?(Hash)
          issues << 'decisive mechanism missing name' if mechanism['name'].to_s.strip.empty?
          issues << 'decisive mechanism missing evidence' if mechanism['evidence'].to_s.strip.empty?
        else
          issues << 'decisive_mechanisms entries must be objects with name/evidence'
        end
      end

      issues << 'pending_actions must include concrete follow-up work' if Array(receipt['pending_actions']).empty?
      issues
    end

    def abtest_completion_summary(receipt)
      completion = receipt['completion'].is_a?(Hash) ? receipt['completion'] : {}
      strategy = receipt['verification_strategy'].is_a?(Hash) ? receipt['verification_strategy'] : {}
      arms = %w[vanilla harness]
      {
        sessions_to_complete: arms.sum { |arm| completion.dig(arm, 'sessions_to_complete').to_i },
        wait_state_stalls: arms.sum { |arm| completion.dig(arm, 'wait_state_stalls').to_i },
        orchestrator_nudges: arms.sum { |arm| completion.dig(arm, 'orchestrator_nudges').to_i },
        known_unrelated_red_gates: arms.sum { |arm| abtest_known_unrelated_red_count(strategy.dig(arm, 'known_unrelated_red_gates')) }
      }
    end

    def abtest_known_unrelated_red_count(value)
      return value.length if value.is_a?(Array)
      return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

      value.to_s.strip.empty? ? 0 : 1
    end

    def nonnegative_number_value?(value)
      return true if value.is_a?(Numeric) && value >= 0

      value.to_s.match?(/\A\d+(?:\.\d+)?\z/)
    end

    def trace_event_index(events, pattern)
      events.index { |event| trace_event_matches?(event, pattern) }
    end

    def trace_event_matches?(event, pattern)
      haystack = trace_event_label(event).downcase
      needle = pattern.to_s.downcase
      return haystack.include?(needle) unless needle.start_with?('/') && needle.end_with?('/')

      haystack.match?(Regexp.new(needle[1...-1]))
    end

    def trace_event_label(event)
      return '' unless event

      [
        event['type'],
        event['name'],
        event['command'],
        event['tool'],
        event['rule'],
        event['detail']
      ].compact.join(' ')
    end

    def read_sop_rating_csv
      path = sop_rating_csv_path
      return [] unless File.exist?(path)

      rows = CSV.read(path, headers: true)
      rows.map do |row|
        score = row['sop_score']
        next if score.to_s.empty?

        notes = row['notes_json'] || row['notes']
        {
          date: row['date'],
          score: score.to_f,
          note: notes,
          session_id: row['session_id'],
          cap_reason: row['cap_reason'],
          trusted: !row['session_id'].to_s.empty? && !row['notes_json'].to_s.empty?,
          no_work: sop_csv_no_work?(row, notes)
        }
      end.compact
    end

    def no_work_session_metric?(event)
      return false unless explicit_metric_value?(event, 'edits') &&
        explicit_metric_value?(event, 'verify_attempts') &&
        explicit_metric_value?(event, 'block_count')

      event['edits'].to_i.zero? &&
        event['verify_attempts'].to_i.zero? &&
        event['block_count'].to_i.zero? &&
        metric_changed_file_count(event).zero?
    end

    def metric_changed_file_count(event)
      return event['changed_file_count'].to_i if explicit_metric_value?(event, 'changed_file_count')
      return Array(event['unique_files']).length if event.key?('unique_files') && event['unique_files'].is_a?(Array)

      0
    end

    def explicit_metric_value?(event, key)
      event.key?(key) && !event[key].nil?
    end

    def sop_csv_no_work?(row, notes)
      edits = row['edits']
      verify_attempts = row['verify_attempts']
      block_count = row['block_count']
      unique_files = row['unique_files']
      notes_json = parse_sop_notes_json(notes)
      return false if [edits, verify_attempts, block_count].any? { |value| value.nil? || value.to_s.empty? }

      edits.to_i.zero? &&
        verify_attempts.to_i.zero? &&
        block_count.to_i.zero? &&
        unique_files.to_i.zero? &&
        !notes_json.fetch('violations', []).any?
    end

    def parse_sop_notes_json(notes)
      return {} if notes.to_s.strip.empty?

      parsed = JSON.parse(notes)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def sop_rating_csv_path
      File.join(Dir.pwd, 'outputs', 'sop_ratings.csv')
    end

    def score_standard_deviation(scores)
      return nil if scores.empty?

      average = scores.sum / scores.length
      variance = scores.map { |score| (score - average)**2 }.sum / scores.length
      Math.sqrt(variance).round(2)
    end

    def print_process_eval(result)
      puts 'SaneProcess Eval'
      puts '=' * 16
      print_trace_eval(result[:trace_eval])
      puts
      print_sop_review(result[:sop_review])
      puts
      print_live_telemetry_review(result[:live_telemetry])
      puts
      print_abtest_review(result[:abtest_review])
      puts
      print_trajectory_efficiency_review(result[:trajectory_efficiency])
      puts
      puts result[:passed] ? 'process_eval passed' : 'process_eval found issues'
    end

    def print_trace_eval(result)
      puts 'Trace Eval'
      puts '=' * 10
      puts "Fixture: #{result[:fixture]}"
      puts "Passed: #{result[:passed_count]}/#{result[:trace_count]}"
      result[:traces].reject { |entry| entry[:passed] }.each do |entry|
        puts "  FAIL #{entry[:id]}: #{entry[:issues].join('; ')}"
      end
    end

    def print_sop_review(result)
      puts 'SOP Review'
      puts '=' * 10
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Session events: #{result.dig(:sessions, :total)}"
      puts "Average SOP score: #{result.dig(:sessions, :average_sop_score) || 'N/A'}"
      puts "Score stddev: #{result.dig(:sessions, :score_stddev) || 'N/A'}"
      puts "Cap mismatches: #{result.dig(:sessions, :cap_mismatches)}"
      puts "Verify pass rate: #{result.dig(:verify, :pass_rate) || 'N/A'}%"
      result[:blockers].each { |item| puts "  BLOCKER #{item}" }
      result[:warnings].each { |item| puts "  WARNING #{item}" }
      puts 'Recommended actions:'
      result[:recommended_actions].each { |item| puts "  - #{item}" }
    end

    def print_abtest_review(result)
      puts 'A/B Evidence'
      puts '=' * 12
      puts "Receipt dir: #{result[:receipt_dir]}"
      puts "Receipts: #{result[:passed_count]}/#{result[:receipt_count]} valid"
      puts "Validation delta: +#{result.dig(:validation_delta, :blocks_that_were_correct)} correct, +#{result.dig(:validation_delta, :blocks_that_were_wrong)} wrong"
      puts "Completion friction: #{result.dig(:completion, :sessions_to_complete)} sessions, #{result.dig(:completion, :wait_state_stalls)} wait-state stalls, #{result.dig(:completion, :known_unrelated_red_gates)} known-unrelated red gate(s)"
      result[:blockers].each { |item| puts "  BLOCKER #{item}" }
      result[:warnings].each { |item| puts "  WARNING #{item}" }
      puts 'Recommended actions:'
      result[:recommended_actions].each { |item| puts "  - #{item}" }
    end

    def print_live_telemetry_review(result)
      puts 'Live Telemetry Review'
      puts '=' * 20
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Recent process events: #{result[:event_count]}"
      puts "By type: #{result[:by_type].map { |type, count| "#{type}=#{count}" }.join(', ')}"
      result[:blockers].each { |item| puts "  BLOCKER #{item}" }
      result[:warnings].each { |item| puts "  WARNING #{item}" }
      puts 'Recommended actions:'
      result[:recommended_actions].each { |item| puts "  - #{item}" }
    end

    def print_trajectory_efficiency_review(result)
      puts 'Trajectory Efficiency'
      puts '=' * 21
      puts "Recent process events: #{result[:event_count]}"
      puts "Proof plans: #{result[:proof_plan_count]}"
      puts "Workflow receipts: #{result[:workflow_receipt_count]}"
      puts "Repeated block families: #{result[:repeated_block_count]}"
      puts "Focused plans that ran broad proof: #{result[:planned_focused_ran_broad_count]}"
      puts "Diagnostic-only successes: #{result[:diagnostic_only_success_count]}"
      result[:blockers].each { |item| puts "  BLOCKER #{item}" }
      result[:warnings].each { |item| puts "  WARNING #{item}" }
      puts 'Recommended actions:'
      result[:recommended_actions].each { |item| puts "  - #{item}" }
    end
  end
end
