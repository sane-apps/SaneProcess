# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'securerandom'
require 'socket'
require_relative 'resource_soak_targets'

module SaneMasterModules
  # Bounded resource receipt runner shared by app, browser, and command targets.
  module ResourceSoak
    include ResourceSoakTargets

    ResourceSoakTargetError = ResourceSoakTargets::ResourceSoakTargetError
    RESOURCE_SOAK_TARGETS = ResourceSoakTargets::RESOURCE_SOAK_TARGETS
    RESOURCE_SOAK_ADAPTIVE_SCENARIO = 'adaptive Mini resource check passed for this release build'
    RESOURCE_SOAK_FIXED_SCENARIO = 'fixed-duration Mini resource check passed for this release build'

    def resource_soak(args = [])
      report = resource_soak_report(args)
      if report[:json]
        puts JSON.pretty_generate(report.reject { |key, _| key == :json })
      elsif report[:ok]
        physical = report[:peak_physical_footprint_mb]
        puts format(
          '✅ Resource check passed: target=%<target>s mode=%<mode>s result=%<decision>s duration=%<duration>.0fs samples=%<samples>d avgCpu=%<cpu>.1f%% peakRss=%<rss>.1fMB peakPhysical=%<physical>s',
          target: report[:target], mode: report[:adaptive] ? 'adaptive' : 'fixed',
          decision: resource_soak_human_status(report[:adaptive_status]), duration: report[:duration_seconds],
          samples: report[:sample_count], cpu: report[:avg_cpu], rss: report[:peak_rss_mb],
          physical: physical.nil? ? 'n/a' : format('%.1fMB', physical)
        )
        puts "   Artifact: #{report[:artifact_path]}"
        puts "   Log: #{report[:log_path]}"
      else
        puts '❌ Resource check failed'
        Array(report[:issues]).each { |issue| puts "   - #{resource_soak_human_issue(issue)}" }
      end
      exit 1 unless report[:ok] || report[:no_exit]
      report
    end

    def resource_soak_report(args = [])
      options = parse_resource_soak_args(args)
      options[:progress] = !options[:json] && !options[:no_exit] && ENV.fetch('SANEMASTER_RESOURCE_SOAK_PROGRESS', '1') != '0'
      return resource_soak_dry_run_report(options) if options[:dry_run]

      target = nil
      cleanup_done = false
      begin
        target = resource_soak_prepare_target(options)
        candidate = target[:candidate]
        version_issues = %w[macos-app ios-simulator].include?(target[:kind]) ? resource_soak_candidate_version_issues(candidate) : []
        return resource_soak_failure(options, version_issues) unless version_issues.empty?

        started_at = Time.now.utc
        deadline = Time.now + options[:duration_seconds]
        samples = []
        missing = 0
        fail_streak = 0
        adaptive = { status: 'fixed', reasons: [], issues: [], fail_streak: 0 }
        log = resource_soak_log_header(started_at, target, options)
        loop do
          elapsed = Time.now - started_at
          sample = resource_soak_target_sample(target)
          if sample
            samples << sample.merge(elapsed_seconds: elapsed)
            log << resource_soak_sample_log(samples.length, samples.last)
          else
            missing += 1
            log << format('sample_missing elapsed=%.1fs root_pid=%d', elapsed, candidate[:pid])
          end
          if options[:adaptive]
            adaptive = resource_soak_adaptive_state(resource_soak_metrics(samples, options), options,
                                                     elapsed_seconds: elapsed, missing_sample_count: missing,
                                                     fail_streak: fail_streak)
            fail_streak = adaptive[:fail_streak]
            break unless adaptive[:status] == 'running'
          end
          resource_soak_print_progress(options, samples: samples, missing_sample_count: missing, elapsed: elapsed)
          break if Time.now >= deadline
          sleep [resource_soak_next_interval_seconds(options, elapsed), deadline - Time.now].min
        end
        cleanup = resource_soak_cleanup_target(target)
        cleanup_done = true
        resource_soak_finish_report(options, target, started_at, samples, missing, adaptive, fail_streak, log, cleanup)
      rescue ResourceSoakTargetError => e
        resource_soak_failure(options, [e.message])
      ensure
        resource_soak_cleanup_target(target) if target && !cleanup_done
      end
    end

    def resource_soak_finish_report(options, target, started_at, samples, missing, adaptive, fail_streak, log, cleanup)
      finished_at = Time.now.utc
      metrics = resource_soak_metrics(samples, options)
      issues = (Array(adaptive[:issues]) + resource_soak_issues(metrics, options, missing_sample_count: missing)).uniq
      cleanup_issue = resource_soak_cleanup_issue(target, cleanup)
      issues << cleanup_issue if cleanup_issue
      if options[:adaptive] && issues.empty? && adaptive[:status] == 'running'
        adaptive = { status: 'full_duration_pass', fail_streak: fail_streak,
                     reasons: ['reached max duration within release thresholds'], issues: [] }
      end
      status = issues.empty? ? 'pass' : 'fail'
      log << "resource_soak_finished_at=#{finished_at.iso8601}" << "status=#{status}"
      log << "adaptive_decision=#{adaptive[:status]}" if options[:adaptive]
      Array(adaptive[:reasons]).each { |reason| log << "adaptive_reason=#{reason}" }
      log.concat(issues.map { |issue| "issue=#{issue}" })
      safe_resource_soak_write(options[:log_path], log.join("\n") + "\n")
      scenarios = [options[:adaptive] ? RESOURCE_SOAK_ADAPTIVE_SCENARIO : RESOURCE_SOAK_FIXED_SCENARIO,
                   'average CPU remains within idle budget',
                   'RSS and file descriptors remain within the bounded resource budget']
      artifact = {
        status: status, started_at: started_at.iso8601, finished_at: finished_at.iso8601,
        duration_seconds: finished_at - started_at, target_duration_seconds: options[:duration_seconds],
        min_duration_seconds: options[:min_duration_seconds], adaptive: options[:adaptive],
        adaptive_status: options[:adaptive] ? adaptive[:status] : 'fixed', adaptive_reasons: Array(adaptive[:reasons]),
        interval_seconds: options[:interval_seconds],
        initial_interval_seconds: options[:adaptive] ? options[:adaptive_initial_interval_seconds] : options[:interval_seconds],
        budgets: resource_soak_budget_payload(options),
        evidence_types: %w[mini_runtime log state_receipt], evidence_paths: [options[:log_path]],
        completed_scenarios: status == 'pass' ? scenarios : [], candidate: target[:candidate].reject { |key, _| key == :pid },
        samples: samples, issues: issues
      }.merge(resource_soak_metric_payload(metrics, missing))
      if target[:kind] != 'macos-app'
        artifact[:schema_version] = 2
        artifact[:target] = resource_soak_target_payload(target, samples, options, cleanup, adaptive)
      end
      safe_resource_soak_write(options[:artifact_path], JSON.pretty_generate(artifact) + "\n")
      resource_soak_report_payload(options, artifact, metrics, issues)
    end

    def resource_soak_metric_payload(metrics, missing)
      metrics.slice(:sample_count, :physical_sample_count, :physical_missing_sample_count,
                    :fd_sample_count, :fd_missing_sample_count, :avg_cpu, :peak_cpu,
                    :rolling_cpu_avg_60s, :rolling_cpu_peak_60s, :avg_rss_mb, :peak_rss_mb,
                    :rss_growth_mb, :baseline_rss_mb, :rss_growth_from_baseline_mb, :rss_slope_mb_per_min,
                    :avg_physical_footprint_mb, :peak_physical_footprint_mb,
                    :physical_footprint_growth_mb, :baseline_physical_footprint_mb,
                    :physical_footprint_growth_from_baseline_mb, :physical_footprint_slope_mb_per_min,
                    :peak_fd_count, :fd_growth, :sample_span_seconds).merge(missing_sample_count: missing)
    end

    def resource_soak_target_payload(target, samples, options, cleanup, adaptive)
      pid_sets = samples.map { |sample| Array(sample[:pids]).sort }.uniq
      { kind: target[:kind], ownership: target[:ownership], root_identity: target[:root_identity],
        candidate: target[:candidate], observed_pid_sets: pid_sets, process_churn: [pid_sets.length - 1, 0].max,
        host: Socket.gethostname, source_binding: resource_soak_source_binding,
        package_binding: resource_soak_package_binding(target), cleanup: cleanup,
        timeout: { seconds: options[:duration_seconds],
                   reached: !options[:adaptive] || adaptive[:status] == 'full_duration_pass' } }
    end

    def resource_soak_source_binding
      fingerprint = respond_to?(:customer_ui_source_fingerprint, true) ? customer_ui_source_fingerprint : nil
      { project: File.basename(Dir.pwd), fingerprint: fingerprint }
    end

    def resource_soak_package_binding(target)
      candidate = target[:candidate]
      digest = File.file?(candidate[:process_path].to_s) ? Digest::SHA256.file(candidate[:process_path]).hexdigest : nil
      { executable_sha256: digest, app_version: candidate[:app_version], app_build: candidate[:app_build],
        session_receipt_sha256: candidate[:session_receipt_sha256], package_sha256: candidate[:package_sha256],
        argv_sha256: candidate[:argv_sha256] }.reject { |_, value| value.nil? }
    end

    def resource_soak_cleanup_issue(target, cleanup)
      return nil unless target[:ownership] == 'owned'
      result = cleanup[:result].to_s
      return nil if %w[terminated killed_after_term already_exited exited].include?(result)

      "owned process cleanup incomplete: #{result.empty? ? 'unknown' : result}"
    end

    def resource_soak_report_payload(options, artifact, metrics, issues)
      { ok: issues.empty?, json: options[:json], no_exit: options[:no_exit], target: options[:target],
        artifact_path: options[:artifact_path], log_path: options[:log_path],
        duration_seconds: artifact[:duration_seconds], sample_count: metrics[:sample_count],
        missing_sample_count: artifact[:missing_sample_count], physical_sample_count: metrics[:physical_sample_count],
        physical_missing_sample_count: metrics[:physical_missing_sample_count], avg_cpu: metrics[:avg_cpu],
        peak_cpu: metrics[:peak_cpu], rolling_cpu_avg_60s: metrics[:rolling_cpu_avg_60s],
        rolling_cpu_peak_60s: metrics[:rolling_cpu_peak_60s], peak_rss_mb: metrics[:peak_rss_mb],
        peak_physical_footprint_mb: metrics[:peak_physical_footprint_mb],
        sample_span_seconds: metrics[:sample_span_seconds], adaptive: options[:adaptive],
        adaptive_status: artifact[:adaptive_status], issues: issues }
    end

    def parse_resource_soak_args(args)
      separator = args.index('--')
      command_argv = separator ? args[(separator + 1)..] : []
      args = separator ? args[0...separator] : args
      adaptive_default = ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE', '1') != '0'
      min_overridden = ENV.key?('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS')
      options = resource_soak_default_options(adaptive_default, min_overridden).merge(command_argv: command_argv)
      value_flags = {
        '--app' => :app_name, '--target' => :target, '--bundle-id' => :bundle_id,
        '--simulator-udid' => :simulator_udid, '--session-receipt' => :session_receipt,
        '--cwd' => :cwd, '--artifact' => :artifact_path, '--artifact-path' => :artifact_path,
        '--log' => :log_path, '--log-path' => :log_path
      }
      number_flags = { '--duration-seconds' => [:duration_seconds, :integer], '--timeout-seconds' => [:duration_seconds, :integer],
                       '--interval-seconds' => [:interval_seconds, :float], '--fd-peak-max' => [:fd_peak_max, :integer],
                       '--fd-growth-max' => [:fd_growth_max, :integer] }
      explicit_paths = []
      i = 0
      while i < args.length
        arg = args[i]
        if value_flags.key?(arg)
          options[value_flags[arg]] = customer_ui_required_arg(args, i, arg)
          explicit_paths << value_flags[arg] if %i[artifact_path log_path].include?(value_flags[arg])
          i += 1
        elsif number_flags.key?(arg)
          key, type = number_flags[arg]
          raw = customer_ui_required_arg(args, i, arg)
          options[key] = type == :integer ? Integer(raw, 10) : Float(raw)
          i += 1
        elsif arg =~ /\A--([a-z-]+)=(.+)\z/
          flag = "--#{Regexp.last_match(1)}"
          raw = Regexp.last_match(2)
          if value_flags.key?(flag)
            options[value_flags[flag]] = raw
            explicit_paths << value_flags[flag] if %i[artifact_path log_path].include?(value_flags[flag])
          elsif number_flags.key?(flag)
            key, type = number_flags[flag]
            options[key] = type == :integer ? Integer(raw, 10) : Float(raw)
          else
            raise ArgumentError, "unknown option: #{flag}"
          end
        else
          case arg
          when '--fixed' then options[:adaptive] = false
          when '--adaptive' then options[:adaptive] = true
          when '--json' then options[:json] = true
          when '--dry-run' then options[:dry_run] = true
          when '--no-exit' then options[:no_exit] = true
          when '--local' then nil
          else raise ArgumentError, "unknown option: #{arg}"
          end
        end
        i += 1
      end
      resource_soak_finalize_options(options, min_overridden, explicit_paths)
    end

    def resource_soak_default_options(adaptive, min_overridden)
      env = ENV
      {
        app_name: metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd), target: 'macos-app',
        adaptive: adaptive, duration_seconds: Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_SECONDS', '600'), 10),
        min_duration_seconds: min_overridden ? Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS'), 10) : nil,
        interval_seconds: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_INTERVAL_SECONDS', '10')),
        adaptive_initial_interval_seconds: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_INITIAL_INTERVAL_SECONDS', '5')),
        adaptive_initial_duration_seconds: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_INITIAL_DURATION_SECONDS', '120')),
        adaptive_baseline_sample_count: Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_BASELINE_SAMPLES', '6'), 10),
        adaptive_rolling_window_seconds: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_ROLLING_WINDOW_SECONDS', '60')),
        adaptive_consecutive_failures: Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_CONSECUTIVE_FAILURES', '3'), 10),
        cpu_avg_max: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_CPU_AVG_MAX', '5')), rss_peak_mb_max: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_RSS_PEAK_MB_MAX', '256')),
        rss_growth_mb_max: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_RSS_GROWTH_MB_MAX', '64')), physical_peak_mb_max: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_PEAK_MB_MAX', '192')),
        physical_growth_mb_max: Float(env.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_GROWTH_MB_MAX', '64')), fd_peak_max: Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_FD_PEAK_MAX', '4096'), 10),
        fd_growth_max: Integer(env.fetch('SANEMASTER_RESOURCE_SOAK_FD_GROWTH_MAX', '512'), 10), artifact_path: env.fetch('SANEMASTER_RESOURCE_SOAK_ARTIFACT_PATH', '/tmp/sanebar_runtime_resource_soak.json'),
        log_path: env.fetch('SANEMASTER_RESOURCE_SOAK_LOG_PATH', '/tmp/sanebar_runtime_resource_soak.log'),
        dry_run: false, json: false, no_exit: false
      }.merge(resource_soak_adaptive_defaults(env))
    end

    def resource_soak_adaptive_defaults(env)
      names = { adaptive_cpu_avg_max: ['ADAPTIVE_CPU_AVG_MAX', 8.0], adaptive_cpu_peak_max: ['ADAPTIVE_CPU_PEAK_MAX', 20.0],
                adaptive_rss_growth_mb_max: ['ADAPTIVE_RSS_GROWTH_MB_MAX', 32.0], adaptive_physical_growth_mb_max: ['ADAPTIVE_PHYSICAL_GROWTH_MB_MAX', 24.0],
                adaptive_rss_slope_mb_per_min_max: ['ADAPTIVE_RSS_SLOPE_MB_PER_MIN_MAX', 4.0], adaptive_physical_slope_mb_per_min_max: ['ADAPTIVE_PHYSICAL_SLOPE_MB_PER_MIN_MAX', 2.0],
                adaptive_early_cpu_avg_max: ['EARLY_CPU_AVG_MAX', 2.0], adaptive_early_cpu_peak_max: ['EARLY_CPU_PEAK_MAX', 6.0],
                adaptive_early_rss_growth_mb_max: ['EARLY_RSS_GROWTH_MB_MAX', 8.0], adaptive_early_physical_growth_mb_max: ['EARLY_PHYSICAL_GROWTH_MB_MAX', 4.0],
                adaptive_early_rss_slope_mb_per_min_max: ['EARLY_RSS_SLOPE_MB_PER_MIN_MAX', 1.0], adaptive_early_physical_slope_mb_per_min_max: ['EARLY_PHYSICAL_SLOPE_MB_PER_MIN_MAX', 0.5],
                adaptive_early_rss_range_mb_max: ['EARLY_RSS_RANGE_MB_MAX', 4.0], adaptive_early_physical_range_mb_max: ['EARLY_PHYSICAL_RANGE_MB_MAX', 2.0] }
      names.transform_values { |name, default| Float(env.fetch("SANEMASTER_RESOURCE_SOAK_#{name}", default.to_s)) }
    end

    def resource_soak_finalize_options(options, min_overridden, explicit_paths)
      raise ArgumentError, "unknown resource target: #{options[:target]}" unless RESOURCE_SOAK_TARGETS.include?(options[:target])
      options[:duration_seconds] = [options[:duration_seconds], 0].max
      options[:min_duration_seconds] = options[:adaptive] ? 240 : options[:duration_seconds] unless min_overridden
      options[:min_duration_seconds] = [options[:min_duration_seconds], 0].max
      options[:interval_seconds] = [options[:interval_seconds], 1.0].max
      options[:adaptive_initial_interval_seconds] = [options[:adaptive_initial_interval_seconds], 1.0].max
      options[:adaptive_consecutive_failures] = [options[:adaptive_consecutive_failures], 1].max
      options[:adaptive_baseline_sample_count] = [options[:adaptive_baseline_sample_count], 1].max
      options[:require_physical] = %w[macos-app ios-simulator].include?(options[:target])
      options[:require_fd] = !%w[macos-app ios-simulator].include?(options[:target])
      # Simulator RSS includes host-mapped clean/shared pages and is not the iOS
      # memory-pressure metric. Keep RSS growth checks, but use phys_footprint
      # for the absolute iOS Simulator ceiling (matching Xcode/XCTMemoryMetric).
      options[:enforce_rss_peak] = options[:target] != 'ios-simulator'
      if options[:target] != 'macos-app'
        stem = options[:target].tr('-', '_')
        options[:artifact_path] = "/tmp/sane_resource_soak_#{stem}.json" unless explicit_paths.include?(:artifact_path)
        options[:log_path] = "/tmp/sane_resource_soak_#{stem}.log" unless explicit_paths.include?(:log_path)
      elsif !options[:adaptive]
        options[:artifact_path] = ENV.fetch('SANEMASTER_RESOURCE_SOAK_FIXED_ARTIFACT_PATH', '/tmp/sanebar_runtime_resource_soak_fixed.json') unless explicit_paths.include?(:artifact_path)
        options[:log_path] = ENV.fetch('SANEMASTER_RESOURCE_SOAK_FIXED_LOG_PATH', '/tmp/sanebar_runtime_resource_soak_fixed.log') unless explicit_paths.include?(:log_path)
      end
      options
    end

    def resource_soak_adaptive_state(metrics, options, elapsed_seconds:, missing_sample_count:, fail_streak:)
      immediate = []
      immediate << "missing process samples: #{missing_sample_count}" if missing_sample_count.to_i.positive?
      if options[:require_physical] && metrics[:physical_missing_sample_count].to_i.positive?
        immediate << "physical footprint missing for #{metrics[:physical_missing_sample_count]} sample(s)"
      end
      if options[:require_fd] && metrics[:fd_missing_sample_count].to_i.positive?
        immediate << "file descriptor count missing for #{metrics[:fd_missing_sample_count]} sample(s)"
      end
      immediate.concat(resource_soak_adaptive_immediate_issues(metrics, options))
      return { status: 'fail', fail_streak: fail_streak, reasons: immediate, issues: immediate } unless immediate.empty?

      failures = resource_soak_adaptive_fail_conditions(metrics, options, elapsed_seconds: elapsed_seconds)
      streak = failures.empty? ? 0 : fail_streak.to_i + 1
      return { status: 'fail', fail_streak: streak, reasons: failures, issues: failures } if streak >= options[:adaptive_consecutive_failures]
      if elapsed_seconds.to_f >= options[:min_duration_seconds] && resource_soak_adaptive_early_pass?(metrics, options)
        return { status: 'early_pass', fail_streak: 0, reasons: ['stable resource profile reached early-pass thresholds'], issues: [] }
      end
      { status: 'running', fail_streak: streak, reasons: failures, issues: [] }
    end

    def resource_soak_adaptive_immediate_issues(metrics, options)
      issues = []
      if options[:enforce_rss_peak] && metrics[:peak_rss_mb].to_f > options[:rss_peak_mb_max]
        issues << format('peakRss %.1fMB > %.1fMB', metrics[:peak_rss_mb], options[:rss_peak_mb_max])
      end
      if metrics[:peak_physical_footprint_mb] && metrics[:peak_physical_footprint_mb].to_f > options[:physical_peak_mb_max]
        issues << format('peakPhysical %.1fMB > %.1fMB', metrics[:peak_physical_footprint_mb], options[:physical_peak_mb_max])
      end
      issues << "peakFd #{metrics[:peak_fd_count]} > #{options[:fd_peak_max]}" if metrics[:peak_fd_count].to_i > options[:fd_peak_max]
      issues
    end

    def resource_soak_adaptive_fail_conditions(metrics, options, elapsed_seconds: nil)
      return [] if metrics[:sample_count].to_i < options[:adaptive_baseline_sample_count]
      checks = [[:rolling_cpu_avg_60s, :adaptive_cpu_avg_max, 'rollingAvgCpu60s %.1f%% > %.1f%%'],
                [:rolling_cpu_peak_60s, :adaptive_cpu_peak_max, 'rollingPeakCpu60s %.1f%% > %.1f%%']]
      if !elapsed_seconds || elapsed_seconds.to_f >= options[:min_duration_seconds]
        checks += [[:rss_growth_from_baseline_mb, :adaptive_rss_growth_mb_max, 'rssGrowthFromBaseline %.1fMB > %.1fMB'],
                   [:physical_footprint_growth_from_baseline_mb, :adaptive_physical_growth_mb_max, 'physicalGrowthFromBaseline %.1fMB > %.1fMB'],
                   [:rss_slope_mb_per_min, :adaptive_rss_slope_mb_per_min_max, 'rssSlope %.1fMB/min > %.1fMB/min'],
                   [:physical_footprint_slope_mb_per_min, :adaptive_physical_slope_mb_per_min_max, 'physicalSlope %.1fMB/min > %.1fMB/min']]
      end
      checks.map do |metric, budget, format_string|
        value = metrics[metric]
        format(format_string, value, options[budget]) if !value.nil? && value.to_f > options[budget]
      end.compact
    end

    def resource_soak_adaptive_early_pass?(metrics, options)
      return false if metrics[:sample_count].to_i <= 0
      return false if options[:min_duration_seconds].positive? && metrics[:sample_count] < options[:adaptive_baseline_sample_count]
      return false if options[:require_physical] && options[:min_duration_seconds].positive? && metrics[:peak_physical_footprint_mb].nil?
      checks = [[:rolling_cpu_avg_60s, :adaptive_early_cpu_avg_max], [:rolling_cpu_peak_60s, :adaptive_early_cpu_peak_max],
                [:rss_growth_from_baseline_mb, :adaptive_early_rss_growth_mb_max], [:physical_footprint_growth_from_baseline_mb, :adaptive_early_physical_growth_mb_max],
                [:rss_slope_mb_per_min, :adaptive_early_rss_slope_mb_per_min_max], [:physical_footprint_slope_mb_per_min, :adaptive_early_physical_slope_mb_per_min_max],
                [:recent_rss_range_mb, :adaptive_early_rss_range_mb_max], [:recent_physical_footprint_range_mb, :adaptive_early_physical_range_mb_max]]
      checks.none? { |metric, budget| metrics[metric] && metrics[metric].to_f > options[budget] }
    end

    def resource_soak_issues(metrics, options, missing_sample_count: 0)
      issues = []
      issues << "duration #{options[:duration_seconds]}s is shorter than required #{options[:min_duration_seconds]}s" if options[:duration_seconds] < options[:min_duration_seconds]
      issues << "missing process samples: #{missing_sample_count}" if missing_sample_count.positive?
      issues << 'no process samples collected' if metrics[:sample_count].to_i <= 0
      issues << "physical footprint missing for #{metrics[:physical_missing_sample_count]} sample(s)" if options[:require_physical] && metrics[:physical_missing_sample_count].to_i.positive?
      issues << "file descriptor count missing for #{metrics[:fd_missing_sample_count]} sample(s)" if options[:require_fd] && metrics[:fd_missing_sample_count].to_i.positive?
      required_span = [options[:min_duration_seconds].to_f - options[:interval_seconds] - 1.0, 0.0].max
      issues << format('sampled span %.1fs is shorter than required %.1fs', metrics[:sample_span_seconds], required_span) if required_span.positive? && metrics[:sample_span_seconds].to_f < required_span
      checks = [[:avg_cpu, :cpu_avg_max, 'avgCpu %.1f%% > %.1f%%'],
                [:rss_growth_mb, :rss_growth_mb_max, 'rssGrowth %.1fMB > %.1fMB'],
                [:peak_physical_footprint_mb, :physical_peak_mb_max, 'peakPhysical %.1fMB > %.1fMB'],
                [:physical_footprint_growth_mb, :physical_growth_mb_max, 'physicalGrowth %.1fMB > %.1fMB']]
      checks << [:peak_rss_mb, :rss_peak_mb_max, 'peakRss %.1fMB > %.1fMB'] if options[:enforce_rss_peak]
      checks.each do |metric, budget, template|
        issues << format(template, metrics[metric], options[budget]) if metrics[metric] && metrics[metric].to_f > options[budget]
      end
      if options[:fd_peak_max] && metrics[:peak_fd_count].to_i > options[:fd_peak_max]
        issues << "peakFd #{metrics[:peak_fd_count]} > #{options[:fd_peak_max]}"
      end
      if options[:fd_growth_max] && metrics[:fd_growth].to_i > options[:fd_growth_max]
        issues << "fdGrowth #{metrics[:fd_growth]} > #{options[:fd_growth_max]}"
      end
      issues << 'physical footprint samples missing' if options[:require_physical] && metrics[:peak_physical_footprint_mb].nil?
      issues
    end

    def resource_soak_next_interval_seconds(options, elapsed)
      options[:adaptive] && elapsed < options[:adaptive_initial_duration_seconds] ? options[:adaptive_initial_interval_seconds] : options[:interval_seconds]
    end

    def resource_soak_budget_payload(options)
      keys = %i[adaptive target_duration_seconds min_duration_seconds adaptive_initial_interval_seconds
                adaptive_initial_duration_seconds adaptive_consecutive_failures adaptive_baseline_sample_count
                adaptive_rolling_window_seconds cpu_avg_max rss_peak_mb_max rss_growth_mb_max enforce_rss_peak
                physical_peak_mb_max physical_growth_mb_max fd_peak_max fd_growth_max adaptive_cpu_avg_max
                adaptive_cpu_peak_max adaptive_rss_growth_mb_max adaptive_physical_growth_mb_max
                adaptive_rss_slope_mb_per_min_max adaptive_physical_slope_mb_per_min_max
                adaptive_early_cpu_avg_max adaptive_early_cpu_peak_max adaptive_early_rss_growth_mb_max
                adaptive_early_physical_growth_mb_max adaptive_early_rss_slope_mb_per_min_max
                adaptive_early_physical_slope_mb_per_min_max adaptive_early_rss_range_mb_max
                adaptive_early_physical_range_mb_max]
      payload = options.slice(*keys)
      payload[:target_duration_seconds] = options[:duration_seconds]
      payload
    end

    def safe_resource_soak_write(path, content)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory)
      safe_customer_ui_directory_path!(directory)
      directory_identity = File.stat(directory).then { |stat| [stat.dev, stat.ino] }
      original = resource_soak_safe_destination(path)
      temp_path = File.join(directory, ".#{File.basename(path)}.#{Process.pid}.#{SecureRandom.hex(8)}.tmp")
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(temp_path, flags, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      temp = File.lstat(temp_path)
      raise "unsafe resource soak temporary file: #{temp_path}" unless temp.file? && temp.nlink == 1
      current = resource_soak_safe_destination(path)
      unchanged = original ? current && [current.dev, current.ino] == [original.dev, original.ino] : current.nil?
      raise "resource soak destination changed while writing: #{path}" unless unchanged
      safe_customer_ui_directory_path!(directory)
      raise "resource soak output directory changed: #{directory}" unless File.stat(directory).then { |stat| [stat.dev, stat.ino] } == directory_identity
      File.rename(temp_path, path)
      File.open(directory, File::RDONLY) { |dir| dir.fsync }
    ensure
      File.unlink(temp_path) if defined?(temp_path) && temp_path && File.exist?(temp_path)
    end

    # Existing receipts may be replaced only when the inode stayed regular,
    # singly linked, and unchanged until the atomic same-directory rename.
    def resource_soak_safe_destination(path)
      stat = File.lstat(path)
      raise "unsafe resource soak destination: #{path}" unless stat.file? && stat.nlink == 1
      stat
    rescue Errno::ENOENT
      nil
    end

    def resource_soak_dry_run_report(options)
      options.slice(:target, :adaptive, :duration_seconds, :min_duration_seconds, :interval_seconds,
                    :artifact_path, :log_path).merge(ok: true, json: options[:json], no_exit: options[:no_exit],
                                                   dry_run: true, app: options[:app_name],
                                                   initial_interval_seconds: options[:adaptive] ? options[:adaptive_initial_interval_seconds] : options[:interval_seconds],
                                                   issues: [])
    end

    def resource_soak_failure(options, issues)
      { ok: false, json: options[:json], no_exit: options[:no_exit], target: options[:target],
        artifact_path: options[:artifact_path], log_path: options[:log_path], issues: issues }
    end

    def resource_soak_log_header(started_at, target, options)
      ["resource_soak_started_at=#{started_at.iso8601}", "target=#{target[:kind]}",
       "ownership=#{target[:ownership]}", "candidate=#{target[:candidate].inspect}",
       "duration_seconds=#{options[:duration_seconds]}", "min_duration_seconds=#{options[:min_duration_seconds]}",
       "interval_seconds=#{options[:interval_seconds]}", "adaptive=#{options[:adaptive]}"]
    end

    def resource_soak_sample_log(index, sample)
      format('sample=%<index>d elapsed=%<elapsed>.1fs cpu=%<cpu>.1f rss=%<rss>.1fMB physical=%<physical>s fd=%<fd>s pids=%<pids>s',
             index: index, elapsed: sample[:elapsed_seconds], cpu: sample[:cpu], rss: sample[:rss_mb],
             physical: sample[:physical_footprint_mb] ? format('%.1fMB', sample[:physical_footprint_mb]) : 'unknown',
             fd: sample[:fd_count] || 'unknown', pids: Array(sample[:pids]).join(','))
    end

    def resource_soak_print_progress(options, samples:, missing_sample_count:, elapsed:)
      return unless options[:progress]
      interval = resource_soak_next_interval_seconds(options, elapsed)
      every = [(60.0 / interval).ceil, 1].max
      return unless samples.length == 1 || (samples.length % every).zero? || elapsed >= options[:duration_seconds]
      puts format('   resource check progress: target=%<target>s sample=%<sample>d elapsed=%<elapsed>.0fs missing=%<missing>d rss=%<rss>s fd=%<fd>s',
                  target: options[:target], sample: samples.length, elapsed: elapsed, missing: missing_sample_count,
                  rss: samples.last ? format('%.1fMB', samples.last[:rss_mb]) : 'unknown',
                  fd: samples.last && samples.last[:fd_count] || 'unknown')
      $stdout.flush
    end

    def resource_soak_human_status(status)
      { 'early_pass' => 'stable after minimum check', 'full_duration_pass' => 'stable through full cap',
        'fixed' => 'fixed duration completed', 'fail' => 'failed', 'running' => 'still running' }
        .fetch(status.to_s, status.to_s.empty? ? 'unknown' : status.to_s.tr('_', ' '))
    end

    def resource_soak_human_issue(issue)
      issue.to_s
    end

    def resource_soak_round(value)
      value.nil? ? nil : value.round(3)
    end
  end
end
