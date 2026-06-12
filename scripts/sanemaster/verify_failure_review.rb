# frozen_string_literal: true

require 'json'
require 'time'

module SaneMasterModules
  module VerifyFailureReview
    def verify_failure_review(args = [])
      options = parse_verify_failure_review_options(args)
      events = options[:metrics_path] ? read_verify_failure_events_from_path(options[:metrics_path]) : read_process_metric_events
      events = reject_verify_failure_test_events(events) unless options[:include_test_events]
      window = options[:limit] ? events.last(options[:limit]) : events
      result = build_verify_failure_review(window, total_events: events.length, min_count: options[:min_count])
      result[:metrics_path] = options[:metrics_path] if options[:metrics_path]

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_verify_failure_review(result)
      end

      result
    end

    def build_verify_failure_review(events, total_events: nil, min_count: 1)
      verify_events = events.select { |event| event['type'] == 'verify' }
      zero_test_events = verify_events.select { |event| event.key?('tests_run') && event['tests_run'].to_i.zero? }
      failure_events = zero_test_events.select { |event| event['success'] != true }
      weak_green_events = zero_test_events.select { |event| event['success'] == true }

      buckets = failure_events.group_by { |event| verify_failure_bucket_for_event(event) }
                              .map { |bucket, group| verify_failure_bucket_summary(bucket, group) }
                              .sort_by { |entry| [-entry[:count], entry[:bucket]] }
      projects = failure_events.group_by { |event| verify_failure_value(event['project']) }
                               .map { |project, group| verify_failure_project_summary(project, group) }
                               .sort_by { |entry| [-entry[:zero_test_failures], entry[:project]] }
      hotspots = verify_failure_hotspots(failure_events)
      actionable = buckets.select { |bucket| bucket[:count] >= min_count.to_i }

      {
        generated_at: Time.now.utc.iso8601,
        metrics_path: respond_to?(:process_metrics_path) ? process_metrics_path : nil,
        total_events: total_events || events.length,
        verify_attempts: verify_events.length,
        zero_test_failures: failure_events.length,
        weak_green_successes: weak_green_events.length,
        buckets: buckets,
        projects: projects,
        hotspots: hotspots,
        recommended_actions: verify_failure_recommended_actions(actionable, weak_green_events, hotspots)
      }
    end

    private

    def parse_verify_failure_review_options(args)
      options = { json: false, limit: 500, min_count: 2, include_test_events: false }
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
          raise ArgumentError, "unknown verify_failure_review option: #{token}"
        end
      end
      options
    end

    def read_verify_failure_events_from_path(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def reject_verify_failure_test_events(events)
      events.reject do |event|
        project = event['project'].to_s.downcase
        cwd = event['cwd'].to_s.downcase
        project.match?(/saneprocess-tier-tests|process-metrics-|near-miss-|verify-failure-|trace-eval-|sop-review-/) ||
          cwd.match?(/\/tmp\/|saneprocess-tier-tests|near-miss-|verify-failure-|process-metrics-|trace-eval-/)
      end
    end

    def verify_failure_bucket_for_event(event)
      explicit = event['failure_bucket'].to_s
      return explicit unless explicit.empty?

      text = [
        event['reason'],
        event['failure_hint'],
        event['detail'],
        event['message']
      ].compact.join(' ').downcase

      return 'timeout' if text.include?('timeout')
      return 'permission_prompt' if text.match?(/permission|tcc|system settings|manual grant/)
      return 'runner_no_output' if text.match?(/no output|empty/)
      return 'build_failure' if text.match?(/build failed|compile|swiftcompile|linker|error:/)
      return 'test_discovery_or_counting' if text.match?(/no tests|0 tests|test discovery|count/)

      'legacy_unknown_zero_test_failure'
    end

    def verify_failure_bucket_summary(bucket, group)
      {
        bucket: bucket,
        count: group.length,
        projects: group.group_by { |event| verify_failure_value(event['project']) }
                       .transform_values(&:length)
                       .sort_by { |project, count| [-count, project] }
                       .to_h,
        examples: group.last(3).map { |event| verify_failure_example(event) },
        next_step: verify_failure_bucket_next_step(bucket)
      }
    end

    def verify_failure_project_summary(project, group)
      {
        project: project,
        zero_test_failures: group.length,
        buckets: group.group_by { |event| verify_failure_bucket_for_event(event) }
                      .transform_values(&:length)
                      .sort_by { |bucket, count| [-count, bucket] }
                      .to_h
      }
    end

    def verify_failure_hotspots(events)
      events.group_by { |event| [verify_failure_value(event['project']), verify_failure_bucket_for_event(event)] }
            .map do |(project, bucket), group|
              {
                project: project,
                bucket: bucket,
                count: group.length,
                latest_timestamp: group.map { |event| event['timestamp'].to_s }.reject(&:empty?).max,
                next_step: verify_failure_bucket_next_step(bucket),
                examples: group.last(3).map { |event| verify_failure_example(event) }
              }
            end
            .sort_by { |entry| [-entry[:count], entry[:project], entry[:bucket]] }
    end

    def verify_failure_recommended_actions(buckets, weak_green_events, hotspots = [])
      actions = []
      if buckets.empty?
        actions << 'No repeated zero-test failure bucket met the threshold in this window.'
      else
        top = buckets.first
        actions << "Fix the top zero-test bucket first: #{top[:bucket]} (#{top[:count]} event(s))."
        actions << top[:next_step]
      end
      if hotspots.any?
        top_hotspot = hotspots.first
        actions << "Start with the top project hotspot: #{top_hotspot[:project]} / #{top_hotspot[:bucket]} (#{top_hotspot[:count]} event(s))."
      end
      if weak_green_events.any?
        actions << "#{weak_green_events.length} green verify run(s) counted zero tests; treat these as build/syntax evidence, not tested evidence."
      end
      actions << 'Keep running this review after verify changes until legacy_unknown_zero_test_failure stops being the top bucket.'
      actions.uniq
    end

    def verify_failure_bucket_next_step(bucket)
      case bucket
      when 'timeout'
        'Inspect timeout logs for permission prompts, hung test hosts, and long-running suites; add a focused timeout fixture before changing limits.'
      when 'permission_prompt'
        'Fix Mini permission automation or preflight prompts; do not count runs blocked by TCC/manual grants as test evidence.'
      when 'runner_no_output'
        'Harden process startup diagnostics: empty test_output means the runner failed before useful test evidence existed.'
      when 'build_failure'
        'Cluster compiler/linker errors by signature and fix the build path before adding more test assertions.'
      when 'test_discovery_or_counting'
        'Fix test discovery or parser counting so green/failed runs cannot report zero tests when tests actually ran.'
      else
        'Future verify metrics need failure_bucket/failure_hint enrichment; sample raw logs for this legacy bucket.'
      end
    end

    def verify_failure_example(event)
      {
        timestamp: event['timestamp'],
        project: event['project'],
        reason: event['reason'],
        failure_bucket: event['failure_bucket'],
        failure_hint: event['failure_hint'],
        tests_run: event['tests_run']
      }.compact
    end

    def verify_failure_value(value)
      value.to_s.empty? ? 'unknown' : value.to_s
    end

    def print_verify_failure_review(result)
      puts 'Verify Failure Review'
      puts '=' * 21
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Verify attempts: #{result[:verify_attempts]}"
      puts "Zero-test failures: #{result[:zero_test_failures]}"
      puts "Weak green successes: #{result[:weak_green_successes]}"
      puts
      result[:buckets].each do |bucket|
        puts "#{bucket[:bucket]}: #{bucket[:count]}"
        puts "  Projects: #{bucket[:projects].map { |project, count| "#{project}=#{count}" }.join(', ')}"
        puts "  Next: #{bucket[:next_step]}"
      end
      if result[:hotspots].any?
        puts
        puts 'Top hotspots:'
        result[:hotspots].first(5).each do |hotspot|
          puts "  - #{hotspot[:project]} / #{hotspot[:bucket]}: #{hotspot[:count]}"
        end
      end
      puts
      puts 'Recommended actions:'
      result[:recommended_actions].each { |action| puts "  - #{action}" }
    end
  end
end
