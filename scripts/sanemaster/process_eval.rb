# frozen_string_literal: true

require 'json'
require 'csv'
require 'time'

module SaneMasterModules
  module ProcessEval
    DEFAULT_PROCESS_EVAL_FIXTURE = File.expand_path('../process_eval_fixtures.json', __dir__)

    def process_eval(args = [])
      options = parse_process_eval_options(args)
      result = build_process_eval(options)
      record_process_metric(
        'process_eval',
        success: result[:passed],
        traces: result.dig(:trace_eval, :trace_count),
        failed: result.dig(:trace_eval, :failed_count),
        sop_warnings: result.dig(:sop_review, :warnings)&.length.to_i
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
      sop_result = build_sop_review(read_process_metric_events)
      {
        generated_at: Time.now.utc.iso8601,
        fixture: trace_result[:fixture],
        passed: trace_result[:passed] && sop_result[:blockers].empty?,
        trace_eval: trace_result,
        sop_review: sop_result
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
      sessions = events.select { |event| event['type'] == 'session_end' }
      verify = events.select { |event| event['type'] == 'verify' }
      csv_scores = read_sop_rating_csv
      scores = sessions.map { |event| event['sop_score'].to_f }.reject(&:zero?)
      scores = csv_scores.map { |row| row[:score].to_f }.reject(&:zero?) if scores.empty?
      warnings = []
      blockers = []
      actions = []

      warnings << 'no session_end metrics found; SOP history cannot explain recent self-assessments' if sessions.empty?
      warnings << 'outputs/sop_ratings.csv is missing or empty; sanestop score history is thin' if csv_scores.empty?
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
      receipt_fields = %w[
        session_id client base_score block_count verify_attempts verify_failures
        verify_zero_test_failures final_verify_success final_verify_tests_run
        final_verify_evidence_strength final_verify_timestamp
      ]
      recent_receipt_samples = sessions.last(10)
      missing_receipt_fields = receipt_fields.each_with_object({}) do |field, memo|
        missing = recent_receipt_samples.count { |event| event[field].nil? }
        memo[field] = missing if missing.positive?
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

      if unrecovered_failures.positive?
        warnings << "#{unrecovered_failures} edited session(s) ended without green verification"
        actions << 'keep GREEN MEANS GO as a hard gate before final status'
      end

      actions << 'expand SOP receipts with session_id, block counts, cap_reason, verification status, and client'
      actions << 'run process_eval after changing hooks, SaneMaster routing, support, release, UI verification, or session-end policy'

      {
        metrics_path: respond_to?(:process_metrics_path) ? process_metrics_path : nil,
        sop_csv_path: sop_rating_csv_path,
        sessions: {
          total: sessions.length,
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
          last_score: csv_scores.last && csv_scores.last[:score],
          last_note: csv_scores.last && csv_scores.last[:note]
        },
        blockers: blockers.uniq,
        warnings: warnings.uniq,
        recommended_actions: actions.uniq
      }
    end

    private

    def parse_process_eval_options(args)
      options = { json: false }
      rest = args.dup
      until rest.empty?
        token = rest.shift
        case token
        when '--json'
          options[:json] = true
        when '--fixture'
          value = rest.shift
          raise ArgumentError, '--fixture requires a path' if value.to_s.empty?

          options[:fixture] = File.expand_path(value)
        end
      end
      options
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

        {
          date: row['date'],
          score: score.to_f,
          note: row['notes_json'] || row['notes'],
          session_id: row['session_id'],
          cap_reason: row['cap_reason']
        }
      end.compact
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
  end
end
