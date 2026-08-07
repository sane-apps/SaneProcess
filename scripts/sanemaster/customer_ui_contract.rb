# frozen_string_literal: true

require 'digest'
require 'date'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'time'
require 'tmpdir'
require 'yaml'

module SaneMasterModules
  # Release-blocking customer-facing UI/UX action contract.
  module CustomerUIContract
    CUSTOMER_UI_MANIFEST_PATHS = [
      'Tests/CustomerUIActions.yml',
      'tests/customer_ui_actions.yml',
      'config/customer_ui_actions.yml',
      '.sane/customer_ui_actions.yml'
    ].freeze
    CUSTOMER_UI_RECEIPT_PATHS = [
      '.sane/customer_ui_action_receipt.json',
      'outputs/customer_ui_action_receipt.json'
    ].freeze
    CUSTOMER_UI_SWEEP_PATHS = [
      'scripts/customer_ui_action_sweep.rb',
      'Scripts/customer_ui_action_sweep.rb',
      'scripts/customer_ui_qa.rb',
      'Scripts/customer_ui_qa.rb'
    ].freeze
    CUSTOMER_UI_PROOF_LEVELS = %w[
      source_guard
      unit_guard
      fixture_completion
      safe_first_surface
      runtime_visual
      full_runtime_completion
      manual_verification
    ].freeze
    CUSTOMER_UI_FAILURE_CLASSES = %w[
      activation_noop
      context_menu_extension_missing
      data_loss_or_unexpected_mutation
      docs_promise_drift
      duplicate_or_stale_menu_item
      external_integration_stub
      hardware_or_tcc_runtime
      install_update_packaging
      layout_visual_regression
      menu_entry_missing
      permission_recovery_dead_end
      persistence_or_relaunch_reset
      pro_basic_gate_drift
      shortcut_focus_or_dispatch
      state_count_drift
    ].freeze
    CUSTOMER_UI_IMAGE_EXTENSIONS = %w[.png .jpg .jpeg].freeze
    CUSTOMER_UI_COMMAND_TIMEOUT_SECONDS = 1800.0
    CUSTOMER_UI_MIN_SCREENSHOT_WIDTH = 80
    CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT = 80
    RESOURCE_SOAK_ADAPTIVE_SCENARIO = 'adaptive Mini resource check passed for this release build'
    RESOURCE_SOAK_FIXED_SCENARIO = 'fixed-duration Mini resource check passed for this release build'
    CUSTOMER_UI_PATH_BACKED_EVIDENCE_TYPES = %w[
      actual_output
      api_response
      automation_transcript
      file_state
      fixture
      log
      mini_automation
      mini_ax
      mini_click
      mini_runtime
      mini_screenshots
      mini_url_route
      mini_screenshot
      model_response
      state_receipt
      support_report
      screenshot
      visual_screenshot
      visual_smoke
    ].freeze
    CUSTOMER_UI_WORKFLOW_PROOF_LEVELS = %w[
      runtime_visual
      full_runtime_completion
    ].freeze
    CUSTOMER_UI_VISUAL_PRECHECK_REQUIRED_PROOF_LEVELS = %w[
      safe_first_surface
      runtime_visual
      full_runtime_completion
    ].freeze
    CUSTOMER_UI_STANDARD_RUNTIME_STATES = %w[
      upgrade_update
      cold_launch_relaunch
      wake_unlock
      display_topology
      basic_pro_mode
      support_report_media
    ].freeze
    CUSTOMER_UI_FULL_RUNTIME_ARTIFACT_TYPES = %w[
      actual_output
      api_response
      automation_transcript
      file_state
      log
      mini_automation
      mini_ax
      mini_click
      mini_runtime
      mini_screenshot
      mini_url_route
      model_response
      screenshot
      state_receipt
      support_report
      visual_screenshot
      visual_smoke
    ].freeze
    CUSTOMER_UI_SCREENSHOT_EVIDENCE_TYPES = %w[
      mini_screenshot
      screenshot
      visual_screenshot
      visual_smoke
    ].freeze
    CUSTOMER_UI_BLOCKING_STATUS_TEXT = [
      'Needs Action',
      'Needs Check',
      'Needs Repair',
      'Missing Items',
      'Hidden by macOS',
      'Detached'
    ].freeze
    CUSTOMER_UI_SOURCE_EXTENSIONS = %w[
      .swift .rb .sh .yml .yaml .json .plist .xcconfig .entitlements .xcstrings
    ].freeze

    def customer_ui_contract(args = [])
      strict_visual = args.include?('--strict-visual')
      report = customer_ui_contract_report(config: current_saneprocess_config, strict_visual: strict_visual)
      if args.include?('--json')
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_contract_report(report)
      end
      exit 1 unless report[:ok] || args.include?('--no-exit')
      report
    end

    def customer_ui_sweep(args = [])
      options = parse_customer_ui_sweep_args(args)
      report = customer_ui_sweep_report(
        dry_run: options[:dry_run],
        execution_evidence_path: options[:execution_evidence_path]
      )
      if options[:json]
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_sweep_report(report)
      end
      exit 1 unless report[:ok] || options[:no_exit]
      report
    end

    def resource_soak(args = [])
      report = resource_soak_report(args)
      if report[:json]
        puts JSON.pretty_generate(report.reject { |key, _| key == :json })
      elsif report[:ok]
        puts format(
          '✅ Resource check passed: mode=%<mode>s result=%<decision>s duration=%<duration>.0fs samples=%<samples>d avgCpu=%<cpu>.1f%% peakRss=%<rss>.1fMB peakPhysical=%<physical>.1fMB',
          mode: report[:adaptive] ? 'adaptive' : 'fixed',
          decision: resource_soak_human_status(report[:adaptive_status]),
          duration: report[:duration_seconds],
          samples: report[:sample_count],
          cpu: report[:avg_cpu],
          rss: report[:peak_rss_mb],
          physical: report[:peak_physical_footprint_mb]
        )
        puts "   Artifact: #{report[:artifact_path]}"
        puts "   Log: #{report[:log_path]}"
      else
        puts '❌ Resource check failed'
        Array(report[:issues]).each { |issue| puts "   - #{resource_soak_human_issue(issue)}" }
        puts "   Artifact: #{report[:artifact_path]}" if report[:artifact_path]
        puts "   Log: #{report[:log_path]}" if report[:log_path]
      end
      exit 1 unless report[:ok] || report[:no_exit]
      report
    end

    def resource_soak_report(args = [])
      options = parse_resource_soak_args(args)
      options[:progress] = !options[:json] && !options[:no_exit] && ENV.fetch('SANEMASTER_RESOURCE_SOAK_PROGRESS', '1') != '0'
      return resource_soak_dry_run_report(options) if options[:dry_run]

      candidates = resource_soak_running_app_candidates(options[:app_name])
      if candidates.empty?
        return {
          ok: false,
          json: options[:json],
          no_exit: options[:no_exit],
          issues: ["#{options[:app_name]} is not running from /Applications; launch with ./scripts/SaneMaster.rb test_mode --release --no-logs"]
        }
      end
      if candidates.length > 1
        return {
          ok: false,
          json: options[:json],
          no_exit: options[:no_exit],
          issues: [
            "Multiple #{options[:app_name]} processes are running from /Applications: #{candidates.map { |candidate| candidate[:pid] }.join(', ')}; relaunch with ./scripts/SaneMaster.rb test_mode --release --no-logs"
          ]
        }
      end
      candidate = candidates.first

      version_issues = resource_soak_candidate_version_issues(candidate)
      unless version_issues.empty?
        return {
          ok: false,
          json: options[:json],
          no_exit: options[:no_exit],
          issues: version_issues
        }
      end

      FileUtils.mkdir_p(File.dirname(options[:artifact_path]))
      log_lines = []
      started_at = Time.now.utc
      deadline = Time.now + options[:duration_seconds]
      samples = []
      missing_sample_count = 0
      adaptive_state = { status: 'fixed', reasons: [], fail_streak: 0 }
      adaptive_terminal_issues = []
      adaptive_fail_streak = 0

      log_lines << "resource_soak_started_at=#{started_at.iso8601}"
      log_lines << "candidate=#{candidate.inspect}"
      log_lines << "duration_seconds=#{options[:duration_seconds]}"
      log_lines << "min_duration_seconds=#{options[:min_duration_seconds]}"
      log_lines << "interval_seconds=#{options[:interval_seconds]}"
      log_lines << "adaptive=#{options[:adaptive]}"

      loop do
        elapsed = Time.now - started_at
        sample = resource_soak_sample(candidate[:pid])
        if sample
          sample = sample.merge(elapsed_seconds: elapsed)
          samples << sample
          log_lines << format(
            'sample=%<index>d elapsed=%<elapsed>.1fs cpu=%<cpu>.1f rss=%<rss>.1fMB physical=%<physical>s',
            index: samples.length,
            elapsed: elapsed,
            cpu: sample[:cpu],
            rss: sample[:rss_mb],
            physical: sample[:physical_footprint_mb] ? format('%.1fMB', sample[:physical_footprint_mb]) : 'unknown'
          )
        else
          missing_sample_count += 1
          log_lines << format('sample_missing elapsed=%.1fs pid=%d', elapsed, candidate[:pid])
        end

        if options[:adaptive]
          adaptive_state = resource_soak_adaptive_state(
            resource_soak_metrics(samples, options),
            options,
            elapsed_seconds: elapsed,
            missing_sample_count: missing_sample_count,
            fail_streak: adaptive_fail_streak
          )
          adaptive_fail_streak = adaptive_state[:fail_streak]
          unless adaptive_state[:status] == 'running'
            adaptive_terminal_issues = Array(adaptive_state[:issues])
            log_lines << "adaptive_decision=#{adaptive_state[:status]}"
            Array(adaptive_state[:reasons]).each { |reason| log_lines << "adaptive_reason=#{reason}" }
            break
          end
        end
        resource_soak_print_progress(options, samples: samples, missing_sample_count: missing_sample_count, elapsed: elapsed)

        break if Time.now >= deadline

        interval_seconds = resource_soak_next_interval_seconds(options, elapsed)
        sleep [interval_seconds, deadline - Time.now].min
      end

      finished_at = Time.now.utc
      metrics = resource_soak_metrics(samples, options)
      issues = (adaptive_terminal_issues + resource_soak_issues(metrics, options, missing_sample_count: missing_sample_count)).uniq
      status = issues.empty? ? 'pass' : 'fail'
      if options[:adaptive] && status == 'pass' && adaptive_state[:status] == 'running'
        adaptive_state = {
          status: 'full_duration_pass',
          fail_streak: adaptive_fail_streak,
          reasons: ['reached max duration within release thresholds'],
          issues: []
        }
      end
      scenarios = [
        options[:adaptive] ? RESOURCE_SOAK_ADAPTIVE_SCENARIO : RESOURCE_SOAK_FIXED_SCENARIO,
        'average CPU remains within idle budget',
        'RSS and physical footprint do not grow beyond the short-soak release budget'
      ]

      log_lines << "resource_soak_finished_at=#{finished_at.iso8601}"
      log_lines << "status=#{status}"
      log_lines.concat(issues.map { |issue| "issue=#{issue}" })
      safe_resource_soak_write(options[:log_path], log_lines.join("\n") + "\n")

      artifact = {
        status: status,
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        duration_seconds: finished_at - started_at,
        target_duration_seconds: options[:duration_seconds],
        min_duration_seconds: options[:min_duration_seconds],
        adaptive: options[:adaptive],
        adaptive_status: options[:adaptive] ? adaptive_state[:status] : 'fixed',
        adaptive_reasons: Array(adaptive_state[:reasons]),
        sample_count: metrics[:sample_count],
        missing_sample_count: missing_sample_count,
        physical_sample_count: metrics[:physical_sample_count],
        physical_missing_sample_count: metrics[:physical_missing_sample_count],
        interval_seconds: options[:interval_seconds],
        initial_interval_seconds: options[:adaptive] ? options[:adaptive_initial_interval_seconds] : options[:interval_seconds],
        avg_cpu: metrics[:avg_cpu],
        peak_cpu: metrics[:peak_cpu],
        rolling_cpu_avg_60s: metrics[:rolling_cpu_avg_60s],
        rolling_cpu_peak_60s: metrics[:rolling_cpu_peak_60s],
        avg_rss_mb: metrics[:avg_rss_mb],
        peak_rss_mb: metrics[:peak_rss_mb],
        rss_growth_mb: metrics[:rss_growth_mb],
        baseline_rss_mb: metrics[:baseline_rss_mb],
        rss_growth_from_baseline_mb: metrics[:rss_growth_from_baseline_mb],
        rss_slope_mb_per_min: metrics[:rss_slope_mb_per_min],
        avg_physical_footprint_mb: metrics[:avg_physical_footprint_mb],
        peak_physical_footprint_mb: metrics[:peak_physical_footprint_mb],
        physical_footprint_growth_mb: metrics[:physical_footprint_growth_mb],
        baseline_physical_footprint_mb: metrics[:baseline_physical_footprint_mb],
        physical_footprint_growth_from_baseline_mb: metrics[:physical_footprint_growth_from_baseline_mb],
        physical_footprint_slope_mb_per_min: metrics[:physical_footprint_slope_mb_per_min],
        sample_span_seconds: metrics[:sample_span_seconds],
        budgets: resource_soak_budget_payload(options),
        evidence_types: %w[mini_runtime log state_receipt],
        evidence_paths: [options[:log_path]],
        completed_scenarios: status == 'pass' ? scenarios : [],
        candidate: candidate.reject { |key, _| key == :pid },
        samples: samples,
        issues: issues
      }
      safe_resource_soak_write(options[:artifact_path], JSON.pretty_generate(artifact) + "\n")

      {
        ok: issues.empty?,
        json: options[:json],
        no_exit: options[:no_exit],
        artifact_path: options[:artifact_path],
        log_path: options[:log_path],
        duration_seconds: artifact[:duration_seconds],
        sample_count: metrics[:sample_count],
        missing_sample_count: missing_sample_count,
        physical_sample_count: metrics[:physical_sample_count],
        physical_missing_sample_count: metrics[:physical_missing_sample_count],
        avg_cpu: metrics[:avg_cpu],
        peak_cpu: metrics[:peak_cpu],
        rolling_cpu_avg_60s: metrics[:rolling_cpu_avg_60s],
        rolling_cpu_peak_60s: metrics[:rolling_cpu_peak_60s],
        peak_rss_mb: metrics[:peak_rss_mb],
        peak_physical_footprint_mb: metrics[:peak_physical_footprint_mb],
        sample_span_seconds: metrics[:sample_span_seconds],
        adaptive: options[:adaptive],
        adaptive_status: artifact[:adaptive_status],
        issues: issues
      }
    end

    def customer_ui_sweep_report(dry_run: false, execution_evidence_path: nil)
      config = current_saneprocess_config
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      script_path = CUSTOMER_UI_SWEEP_PATHS.find { |path| File.file?(path) }
      unless script_path
        return {
          ok: false,
          app: app_name,
          script_path: nil,
          issues: ["Missing customer UI workflow runner (expected one of: #{CUSTOMER_UI_SWEEP_PATHS.join(', ')})"]
        }
      end

      unless customer_ui_allowed_host? || dry_run
        return {
          ok: false,
          app: app_name,
          script_path: script_path,
          issues: ["customer_ui_sweep must run on the Mini unless explicit Air fallback is approved; current host=#{Socket.gethostname.inspect} user=#{ENV.fetch('USER', '')}"]
        }
      end

      execution_evidence_path = customer_ui_execution_evidence_path!(execution_evidence_path) if execution_evidence_path

      if dry_run
        return {
          ok: true,
          app: app_name,
          script_path: script_path,
          execution_evidence_path: execution_evidence_path,
          dry_run: true,
          issues: []
        }
      end

      report = customer_ui_with_live_app_logs(app_name) do
        prepare_issues = customer_ui_prepare_target_before_sweep(app_name)
        unless prepare_issues.empty?
          next({ ok: false, app: app_name, script_path: script_path, issues: prepare_issues })
        end

        cleanup_issues = customer_ui_cleanup_before_sweep(app_name)
        unless cleanup_issues.empty?
          next({ ok: false, app: app_name, script_path: script_path, issues: cleanup_issues })
        end

        runtime_issues = customer_ui_refresh_runtime_evidence_before_sweep(app_name)
        unless runtime_issues.empty?
          next({ ok: false, app: app_name, script_path: script_path, issues: runtime_issues })
        end

        if app_name == 'SaneBar'
          post_runtime_cleanup_issues = customer_ui_cleanup_before_sweep(app_name)
          unless post_runtime_cleanup_issues.empty?
            next({ ok: false, app: app_name, script_path: script_path, issues: post_runtime_cleanup_issues })
          end
        end

        visual_precheck = customer_ui_visual_precheck(app_name)
        unless visual_precheck[:ok]
          next({ ok: false, app: app_name, script_path: script_path, issues: visual_precheck[:issues] })
        end

        runner_command = [RbConfig.ruby, script_path]
        runner_command.concat(['--execution-evidence', execution_evidence_path]) if execution_evidence_path
        output, status = customer_ui_run_command(*runner_command)
        unless status.success?
          next({ ok: false, app: app_name, script_path: script_path, issues: ["Customer UI workflow runner failed: #{output}"] })
        end

        contract = customer_ui_contract_report(config: config)
        {
          ok: contract[:ok],
          app: app_name,
          script_path: script_path,
          execution_evidence_path: execution_evidence_path,
          contract: contract,
          runner_output: output,
          issues: Array(contract[:issues])
        }
      end
      report[:live_log_path] ||= @customer_ui_live_log_path if report.is_a?(Hash) && @customer_ui_live_log_path
      report
    end

    def customer_ui_contract_report(config:, strict_visual: false)
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      receipt_path = newest_customer_ui_receipt_path
      issues = []
      warnings = []

      unless manifest_path
        return {
          ok: false,
          app: app_name,
          manifest_path: nil,
          receipt_path: receipt_path,
          issues: ["Missing customer UI action contract (expected one of: #{CUSTOMER_UI_MANIFEST_PATHS.join(', ')})"],
          warnings: warnings
        }
      end

      manifest = read_customer_ui_yaml(manifest_path)
      actions = Array(manifest['actions'])
      release_profile = metadata_value(config, 'customer_ui_release_profile').to_s.strip
      required_actions = if release_profile.empty?
                           actions.reject { |action| action['release_required'] == false }
                         else
                           profile_ids = Array(manifest.dig('release_profiles', release_profile)).map(&:to_s)
                           if profile_ids.empty?
                             issues << "Unknown or empty customer UI release profile #{release_profile.inspect}"
                             []
                           else
                             actions_by_id = actions.to_h { |action| [action['id'].to_s, action] }
                             unknown_ids = profile_ids - actions_by_id.keys
                             unless unknown_ids.empty?
                               issues << "Customer UI release profile #{release_profile.inspect} references unknown action(s): #{unknown_ids.join(', ')}"
                             end
                             profile_ids.filter_map { |id| actions_by_id[id] }
                           end
                         end

      issues << 'Customer UI action contract has no release-required actions' if required_actions.empty?
      issues.concat(customer_ui_manifest_issues(manifest_path, manifest, required_actions))

      manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
      source_fingerprint = customer_ui_source_fingerprint

      unless receipt_path
        issues << 'Missing fresh customer UI QA receipt (run the app-specific Mini click/screenshot sweep)'
        return {
          ok: false,
          app: app_name,
          manifest_path: manifest_path,
          receipt_path: nil,
          manifest_sha256: manifest_sha,
          source_fingerprint: source_fingerprint,
          release_profile: release_profile,
          action_count: required_actions.length,
          issues: issues,
          warnings: warnings
        }
      end

      receipt = read_customer_ui_json(receipt_path)
      issues.concat(customer_ui_receipt_issues(
        app_name: app_name,
        manifest_sha: manifest_sha,
        source_fingerprint: source_fingerprint,
        required_actions: required_actions,
        manifest: manifest,
        receipt: receipt,
        strict_visual: strict_visual
      ))

      {
        ok: issues.empty?,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        manifest_sha256: manifest_sha,
        source_fingerprint: source_fingerprint,
        release_profile: release_profile,
        action_count: required_actions.length,
        receipt_generated_at: receipt['generated_at'],
        issues: issues,
        warnings: warnings,
        strict_visual: strict_visual
      }
    rescue Psych::SyntaxError, JSON::ParserError => e
      {
        ok: false,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        issues: ["Customer UI QA contract parse failure: #{e.message}"],
        warnings: warnings,
        strict_visual: strict_visual
      }
    end

    def format_customer_ui_contract_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI ACTION CONTRACT ] ---'
      lines << "App: #{report[:app]}"
      if report[:ok]
        lines << "✅ #{report[:action_count]} release-required action(s) covered"
        lines << "   Manifest: #{report[:manifest_path]}"
        lines << "   Receipt: #{report[:receipt_path]}"
        lines << "   Generated: #{report[:receipt_generated_at]}"
        lines << '   Strict visual: enabled' if report[:strict_visual]
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      Array(report[:warnings]).each { |warning| lines << "⚠️  #{warning}" }
      lines.map { |line| customer_ui_report_utf8(line) }.join("\n")
    end

    def format_customer_ui_sweep_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI WORKFLOW SWEEP ] ---'
      lines << "App: #{report[:app]}"
      lines << "Runner: #{report[:script_path] || 'missing'}"
      lines << "Live logs: #{report[:live_log_path]}" if report[:live_log_path]
      if report[:dry_run]
        lines << '✅ Dry run: runner found'
      elsif report[:ok]
        lines << '✅ Workflow sweep and contract passed'
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      lines.map { |line| customer_ui_report_utf8(line) }.join("\n")
    end

    private

    def parse_customer_ui_sweep_args(args)
      options = {
        json: false,
        dry_run: false,
        no_exit: false,
        execution_evidence_path: nil
      }
      i = 0
      while i < args.length
        arg = args[i]
        case arg
        when '--json'
          options[:json] = true
        when '--dry-run'
          options[:dry_run] = true
        when '--no-exit'
          options[:no_exit] = true
        when '--local'
          # Consumed by SaneMaster Mini routing.
        when '--execution-evidence'
          raise ArgumentError, '--execution-evidence may only be supplied once' if options[:execution_evidence_path]

          options[:execution_evidence_path] = customer_ui_required_arg(args, i, arg)
          i += 1
        when /\A--execution-evidence=(.+)\z/
          raise ArgumentError, '--execution-evidence may only be supplied once' if options[:execution_evidence_path]

          options[:execution_evidence_path] = Regexp.last_match(1)
        else
          raise ArgumentError, "unknown option: #{arg}"
        end
        i += 1
      end
      options
    end

    def customer_ui_execution_evidence_path!(path)
      project_root = File.expand_path(Dir.pwd)
      allowed_root = File.join(project_root, 'outputs', 'customer-ui')
      expanded = File.expand_path(path.to_s, project_root)
      raise ArgumentError, '--execution-evidence must be a JSON file' unless File.extname(expanded).downcase == '.json'

      safe_customer_ui_directory_path!(File.dirname(expanded))
      stat = File.lstat(expanded)
      raise ArgumentError, '--execution-evidence must be a regular non-symlink file' unless stat.file? && !stat.symlink?

      real_path = File.realpath(expanded)
      real_allowed_root = File.realpath(allowed_root)
      unless real_path.start_with?("#{real_allowed_root}/")
        raise ArgumentError, '--execution-evidence must be under outputs/customer-ui'
      end

      real_path
    rescue Errno::ENOENT
      raise ArgumentError, "customer UI execution evidence not found: #{expanded}"
    end

    def customer_ui_report_utf8(value)
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
    end

    def customer_ui_allowed_host?
      customer_ui_mini_host? || customer_ui_air_fallback_approved?
    end

    def customer_ui_mini_host?
      host = Socket.gethostname.to_s.downcase
      return true if host.include?('mini')

      return false unless RUBY_PLATFORM.include?('darwin')

      computer_name, status = Open3.capture2('/usr/sbin/scutil', '--get', 'ComputerName')
      status.success? && computer_name.to_s.downcase.include?('mac mini')
    end

    def customer_ui_air_fallback_approved?
      ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] == 'MR. SANE APPROVES LOCAL UI ON AIR'
    end

    def customer_ui_receipt_host_allowed?(host)
      normalized = host.to_s.downcase
      return true if normalized == 'mini' || normalized.include?('mini')
      return false unless customer_ui_air_fallback_approved?

      normalized == Socket.gethostname.to_s.downcase ||
        normalized == 'macbook-air' ||
        normalized == 'air' ||
        normalized.include?('macbook')
    end

    def parse_resource_soak_args(args)
      adaptive_default = ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE', '1') != '0'
      duration_default = Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_SECONDS', (10 * 60).to_s), 10)
      min_duration_overridden = ENV.key?('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS')
      min_duration_default = min_duration_overridden ? Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS'), 10) : nil
      options = {
        app_name: metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd),
        adaptive: adaptive_default,
        duration_seconds: duration_default,
        min_duration_seconds: min_duration_default,
        interval_seconds: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_INTERVAL_SECONDS', '10')),
        adaptive_initial_interval_seconds: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_INITIAL_INTERVAL_SECONDS', '5')),
        adaptive_initial_duration_seconds: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_INITIAL_DURATION_SECONDS', '120')),
        adaptive_baseline_sample_count: Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_BASELINE_SAMPLES', '6'), 10),
        adaptive_rolling_window_seconds: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ROLLING_WINDOW_SECONDS', '60')),
        adaptive_consecutive_failures: Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_CONSECUTIVE_FAILURES', '3'), 10),
        cpu_avg_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_CPU_AVG_MAX', '5.0')),
        rss_peak_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_RSS_PEAK_MB_MAX', '256.0')),
        rss_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_RSS_GROWTH_MB_MAX', '64.0')),
        physical_peak_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_PEAK_MB_MAX', '192.0')),
        physical_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_GROWTH_MB_MAX', '64.0')),
        adaptive_cpu_avg_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_CPU_AVG_MAX', '8.0')),
        adaptive_cpu_peak_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_CPU_PEAK_MAX', '20.0')),
        adaptive_rss_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_RSS_GROWTH_MB_MAX', '32.0')),
        adaptive_physical_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_PHYSICAL_GROWTH_MB_MAX', '24.0')),
        adaptive_rss_slope_mb_per_min_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_RSS_SLOPE_MB_PER_MIN_MAX', '4.0')),
        adaptive_physical_slope_mb_per_min_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_ADAPTIVE_PHYSICAL_SLOPE_MB_PER_MIN_MAX', '2.0')),
        adaptive_early_cpu_avg_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_CPU_AVG_MAX', '2.0')),
        adaptive_early_cpu_peak_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_CPU_PEAK_MAX', '6.0')),
        adaptive_early_rss_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_RSS_GROWTH_MB_MAX', '8.0')),
        adaptive_early_physical_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_PHYSICAL_GROWTH_MB_MAX', '4.0')),
        adaptive_early_rss_slope_mb_per_min_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_RSS_SLOPE_MB_PER_MIN_MAX', '1.0')),
        adaptive_early_physical_slope_mb_per_min_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_PHYSICAL_SLOPE_MB_PER_MIN_MAX', '0.5')),
        adaptive_early_rss_range_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_RSS_RANGE_MB_MAX', '4.0')),
        adaptive_early_physical_range_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_EARLY_PHYSICAL_RANGE_MB_MAX', '2.0')),
        artifact_path: ENV.fetch('SANEMASTER_RESOURCE_SOAK_ARTIFACT_PATH', '/tmp/sanebar_runtime_resource_soak.json'),
        log_path: ENV.fetch('SANEMASTER_RESOURCE_SOAK_LOG_PATH', '/tmp/sanebar_runtime_resource_soak.log'),
        dry_run: false,
        json: false,
        no_exit: false
      }

      i = 0
      while i < args.length
        arg = args[i]
        case arg
        when '--app'
          options[:app_name] = customer_ui_required_arg(args, i, arg)
          i += 1
        when /\A--app=(.+)\z/
          options[:app_name] = Regexp.last_match(1)
        when '--duration-seconds'
          options[:duration_seconds] = Integer(customer_ui_required_arg(args, i, arg), 10)
          i += 1
        when /\A--duration-seconds=(\d+)\z/
          options[:duration_seconds] = Integer(Regexp.last_match(1), 10)
        when '--interval-seconds'
          options[:interval_seconds] = Float(customer_ui_required_arg(args, i, arg))
          i += 1
        when /\A--interval-seconds=(\d+(?:\.\d+)?)\z/
          options[:interval_seconds] = Float(Regexp.last_match(1))
        when '--fixed'
          options[:adaptive] = false
        when '--adaptive'
          options[:adaptive] = true
        when '--json'
          options[:json] = true
        when '--dry-run'
          options[:dry_run] = true
        when '--no-exit'
          options[:no_exit] = true
        when '--local'
          # Consumed by SaneMaster Mini routing.
        else
          raise ArgumentError, "unknown option: #{arg}"
        end
        i += 1
      end

      options[:duration_seconds] = 0 if options[:duration_seconds].negative?
      unless min_duration_overridden
        options[:min_duration_seconds] = options[:adaptive] ? 4 * 60 : options[:duration_seconds]
      end
      options[:min_duration_seconds] = 0 if options[:min_duration_seconds].negative?
      options[:interval_seconds] = 1.0 if options[:interval_seconds] < 1.0
      options[:adaptive_initial_interval_seconds] = 1.0 if options[:adaptive_initial_interval_seconds] < 1.0
      options[:adaptive_consecutive_failures] = 1 if options[:adaptive_consecutive_failures] < 1
      options[:adaptive_baseline_sample_count] = 1 if options[:adaptive_baseline_sample_count] < 1
      unless options[:adaptive]
        options[:artifact_path] = ENV.fetch('SANEMASTER_RESOURCE_SOAK_FIXED_ARTIFACT_PATH', '/tmp/sanebar_runtime_resource_soak_fixed.json')
        options[:log_path] = ENV.fetch('SANEMASTER_RESOURCE_SOAK_FIXED_LOG_PATH', '/tmp/sanebar_runtime_resource_soak_fixed.log')
      end
      options
    end

    def safe_resource_soak_write(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      safe_customer_ui_directory_path!(File.dirname(path))
      File.open(path, safe_resource_soak_write_flags, 0o600) do |file|
        file.write(content)
      end
    end

    def safe_resource_soak_write_flags
      flags = File::WRONLY | File::CREAT | File::TRUNC
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags
    end

    def resource_soak_dry_run_report(options)
      {
        ok: true,
        json: options[:json],
        no_exit: options[:no_exit],
        dry_run: true,
        app: options[:app_name],
        adaptive: options[:adaptive],
        duration_seconds: options[:duration_seconds],
        min_duration_seconds: options[:min_duration_seconds],
        interval_seconds: options[:interval_seconds],
        initial_interval_seconds: options[:adaptive] ? options[:adaptive_initial_interval_seconds] : options[:interval_seconds],
        artifact_path: options[:artifact_path],
        log_path: options[:log_path],
        issues: []
      }
    end

    def resource_soak_running_app_candidate(app_name)
      candidates = resource_soak_running_app_candidates(app_name)
      candidates.length == 1 ? candidates.first : nil
    end

    def resource_soak_running_app_candidates(app_name)
      app_path = "/Applications/#{app_name}.app"
      executable = File.join(app_path, 'Contents', 'MacOS', app_name)
      return [] unless File.executable?(executable)

      pids_output, = Open3.capture2('pgrep', '-x', app_name)
      pids_output.lines.map(&:strip).reject(&:empty?).each_with_object([]) do |pid_text, candidates|
        pid = pid_text.to_i
        command_line, = Open3.capture2('ps', '-o', 'command=', '-p', pid.to_s)
        process_path = command_line.strip.split(/\s+/, 2).first
        next unless File.expand_path(process_path.to_s) == executable

        candidates << {
          pid: pid,
          app_path: app_path,
          app_version: resource_soak_plist_value(app_path, 'CFBundleShortVersionString'),
          app_build: resource_soak_plist_value(app_path, 'CFBundleVersion'),
          process_path: executable,
          process_started_at: resource_soak_process_started_at(pid)&.iso8601,
          app_executable_mtime: File.mtime(executable).iso8601
        }
      end
    end

    def resource_soak_candidate_version_issues(candidate)
      expected = resource_soak_expected_project_version
      issues = []
      if expected[:app_version] && candidate[:app_version].to_s != expected[:app_version].to_s
        issues << "Running candidate version #{candidate[:app_version]} does not match project MARKETING_VERSION #{expected[:app_version]}"
      end
      if expected[:app_build] && candidate[:app_build].to_s != expected[:app_build].to_s
        issues << "Running candidate build #{candidate[:app_build]} does not match project CURRENT_PROJECT_VERSION #{expected[:app_build]}"
      end
      process_started_at = resource_soak_time(candidate[:process_started_at])
      executable_mtime = resource_soak_time(candidate[:app_executable_mtime])
      if process_started_at && executable_mtime && executable_mtime > process_started_at + 1
        issues << "Running candidate process #{candidate[:pid]} started before /Applications executable was last replaced; relaunch with ./scripts/SaneMaster.rb test_mode --release --no-logs"
      end
      issues
    end

    def resource_soak_expected_project_version
      project_yml = File.join(Dir.pwd, 'project.yml')
      return {} unless customer_ui_regular_file?(project_yml)

      content = safe_customer_ui_file_read(project_yml)
      {
        app_version: content[/MARKETING_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip,
        app_build: content[/CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip
      }.reject { |_, value| value.empty? }
    end

    def resource_soak_plist_value(app_path, key)
      value, status = Open3.capture2('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(app_path, 'Contents', 'Info.plist'))
      status.success? ? value.strip : nil
    end

    def resource_soak_process_started_at(pid)
      output, status = Open3.capture2('ps', '-o', 'lstart=', '-p', pid.to_s)
      return nil unless status.success?

      Time.strptime(output.strip, '%a %b %e %H:%M:%S %Y')
    rescue ArgumentError
      nil
    end

    def resource_soak_time(value)
      return value if value.is_a?(Time)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def resource_soak_sample(pid)
      output, status = Open3.capture2('ps', '-o', '%cpu=,rss=', '-p', pid.to_s)
      return nil unless status.success?

      cpu_text, rss_text = output.strip.split(/\s+/, 2)
      return nil unless cpu_text && rss_text

      {
        sampled_at: Time.now.utc.iso8601,
        cpu: cpu_text.to_f,
        rss_mb: rss_text.to_f / 1024.0,
        physical_footprint_mb: resource_soak_physical_footprint_mb(pid)
      }
    end

    def resource_soak_physical_footprint_mb(pid)
      output, status = Open3.capture2e('footprint', '-pid', pid.to_s, '-summary')
      return nil unless status.success?

      resource_soak_parse_footprint_mb(output)
    end

    def resource_soak_parse_footprint_mb(output)
      line = output.to_s.lines.find { |candidate| candidate.include?('phys_footprint:') }
      return nil unless line

      match = line.match(/phys_footprint:\s*([0-9.]+)\s*([KMG])B?\b/i)
      return nil unless match

      value = match[1].to_f
      unit = match[2].upcase
      case unit
      when 'K' then value / 1024.0
      when 'G' then value * 1024.0
      else value
      end
    end

    def resource_soak_metrics(samples, options = {})
      return resource_soak_empty_metrics if samples.empty?

      rss_values = samples.map { |sample| sample[:rss_mb].to_f }
      cpu_values = samples.map { |sample| sample[:cpu].to_f }
      physical_values = samples.map { |sample| sample[:physical_footprint_mb] }.compact.map(&:to_f)
      physical_sample_count = physical_values.length
      baseline_sample_count = [options.fetch(:adaptive_baseline_sample_count, 6).to_i, 1].max
      rolling_window_seconds = [options.fetch(:adaptive_rolling_window_seconds, 60.0).to_f, 1.0].max
      baseline_samples = samples.first(baseline_sample_count)
      baseline_rss = resource_soak_median(baseline_samples.map { |sample| sample[:rss_mb] }.compact.map(&:to_f))
      baseline_physical = resource_soak_median(baseline_samples.map { |sample| sample[:physical_footprint_mb] }.compact.map(&:to_f))
      latest_elapsed = samples.last[:elapsed_seconds].to_f
      rolling_samples = samples.select { |sample| latest_elapsed - sample[:elapsed_seconds].to_f <= rolling_window_seconds }
      rolling_cpu_values = rolling_samples.map { |sample| sample[:cpu].to_f }
      recent_samples = samples.last(baseline_sample_count)
      {
        sample_count: samples.length,
        physical_sample_count: physical_sample_count,
        physical_missing_sample_count: samples.length - physical_sample_count,
        avg_cpu: resource_soak_round(cpu_values.sum / cpu_values.length),
        peak_cpu: resource_soak_round(cpu_values.max),
        rolling_cpu_avg_60s: resource_soak_round(rolling_cpu_values.empty? ? 0.0 : rolling_cpu_values.sum / rolling_cpu_values.length),
        rolling_cpu_peak_60s: resource_soak_round(rolling_cpu_values.empty? ? 0.0 : rolling_cpu_values.max),
        avg_rss_mb: resource_soak_round(rss_values.sum / rss_values.length),
        peak_rss_mb: resource_soak_round(rss_values.max),
        rss_growth_mb: resource_soak_round(rss_values.last - rss_values.first),
        baseline_rss_mb: resource_soak_round(baseline_rss),
        rss_growth_from_baseline_mb: resource_soak_round(baseline_rss.nil? ? nil : rss_values.last - baseline_rss),
        rss_slope_mb_per_min: resource_soak_round(resource_soak_slope_mb_per_min(samples.last(baseline_sample_count), :rss_mb)),
        recent_rss_range_mb: resource_soak_round(resource_soak_value_range(recent_samples, :rss_mb)),
        avg_physical_footprint_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.sum / physical_values.length),
        peak_physical_footprint_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.max),
        physical_footprint_growth_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.last - physical_values.first),
        baseline_physical_footprint_mb: resource_soak_round(baseline_physical),
        physical_footprint_growth_from_baseline_mb: resource_soak_round(baseline_physical.nil? || physical_values.empty? ? nil : physical_values.last - baseline_physical),
        physical_footprint_slope_mb_per_min: resource_soak_round(resource_soak_slope_mb_per_min(samples.last(baseline_sample_count), :physical_footprint_mb)),
        recent_physical_footprint_range_mb: resource_soak_round(resource_soak_value_range(recent_samples, :physical_footprint_mb)),
        sample_span_seconds: resource_soak_round(samples.last[:elapsed_seconds].to_f - samples.first[:elapsed_seconds].to_f)
      }
    end

    def resource_soak_empty_metrics
      {
        sample_count: 0,
        physical_sample_count: 0,
        physical_missing_sample_count: 0,
        avg_cpu: 0.0,
        peak_cpu: 0.0,
        rolling_cpu_avg_60s: 0.0,
        rolling_cpu_peak_60s: 0.0,
        avg_rss_mb: 0.0,
        peak_rss_mb: 0.0,
        rss_growth_mb: 0.0,
        baseline_rss_mb: nil,
        rss_growth_from_baseline_mb: nil,
        rss_slope_mb_per_min: nil,
        recent_rss_range_mb: nil,
        avg_physical_footprint_mb: nil,
        peak_physical_footprint_mb: nil,
        physical_footprint_growth_mb: nil,
        baseline_physical_footprint_mb: nil,
        physical_footprint_growth_from_baseline_mb: nil,
        physical_footprint_slope_mb_per_min: nil,
        recent_physical_footprint_range_mb: nil,
        sample_span_seconds: 0.0
      }
    end

    def resource_soak_median(values)
      clean = values.compact.map(&:to_f).sort
      return nil if clean.empty?

      mid = clean.length / 2
      if clean.length.odd?
        clean[mid]
      else
        (clean[mid - 1] + clean[mid]) / 2.0
      end
    end

    def resource_soak_slope_mb_per_min(samples, key)
      points = samples.select { |sample| !sample[key].nil? && !sample[:elapsed_seconds].nil? }
      return nil if points.length < 2

      first = points.first
      last = points.last
      elapsed_minutes = (last[:elapsed_seconds].to_f - first[:elapsed_seconds].to_f) / 60.0
      return 0.0 if elapsed_minutes <= 0.0

      (last[key].to_f - first[key].to_f) / elapsed_minutes
    end

    def resource_soak_value_range(samples, key)
      values = samples.map { |sample| sample[key] }.compact.map(&:to_f)
      return nil if values.empty?

      values.max - values.min
    end

    def resource_soak_adaptive_state(metrics, options, elapsed_seconds:, missing_sample_count:, fail_streak:)
      if missing_sample_count.to_i.positive?
        return {
          status: 'fail',
          fail_streak: fail_streak,
          reasons: ["missing process samples: #{missing_sample_count}"],
          issues: ["missing process samples: #{missing_sample_count}"]
        }
      end
      if metrics[:physical_missing_sample_count].to_i.positive?
        return {
          status: 'fail',
          fail_streak: fail_streak,
          reasons: ["physical footprint missing for #{metrics[:physical_missing_sample_count]} sample(s)"],
          issues: ["physical footprint missing for #{metrics[:physical_missing_sample_count]} sample(s)"]
        }
      end

      immediate_issues = resource_soak_adaptive_immediate_issues(metrics, options)
      unless immediate_issues.empty?
        return {
          status: 'fail',
          fail_streak: fail_streak,
          reasons: immediate_issues,
          issues: immediate_issues
        }
      end

      fail_conditions = resource_soak_adaptive_fail_conditions(metrics, options, elapsed_seconds: elapsed_seconds)
      next_fail_streak = fail_conditions.empty? ? 0 : fail_streak.to_i + 1
      if next_fail_streak >= options[:adaptive_consecutive_failures].to_i
        return {
          status: 'fail',
          fail_streak: next_fail_streak,
          reasons: fail_conditions,
          issues: fail_conditions
        }
      end

      if elapsed_seconds.to_f >= options[:min_duration_seconds].to_f &&
         resource_soak_adaptive_early_pass?(metrics, options)
        return {
          status: 'early_pass',
          fail_streak: 0,
          reasons: ['stable resource profile reached early-pass thresholds'],
          issues: []
        }
      end

      {
        status: 'running',
        fail_streak: next_fail_streak,
        reasons: fail_conditions,
        issues: []
      }
    end

    def resource_soak_adaptive_immediate_issues(metrics, options)
      issues = []
      if metrics[:peak_rss_mb].to_f > options[:rss_peak_mb_max].to_f
        issues << format('peakRss %.1fMB > %.1fMB', metrics[:peak_rss_mb], options[:rss_peak_mb_max])
      end
      unless metrics[:peak_physical_footprint_mb].nil?
        if metrics[:peak_physical_footprint_mb].to_f > options[:physical_peak_mb_max].to_f
          issues << format('peakPhysical %.1fMB > %.1fMB', metrics[:peak_physical_footprint_mb], options[:physical_peak_mb_max])
        end
      end
      issues
    end

    def resource_soak_adaptive_fail_conditions(metrics, options, elapsed_seconds: nil)
      return [] if metrics[:sample_count].to_i < options[:adaptive_baseline_sample_count].to_i

      issues = []
      if metrics[:rolling_cpu_avg_60s].to_f > options[:adaptive_cpu_avg_max].to_f
        issues << format('rollingAvgCpu60s %.1f%% > %.1f%%', metrics[:rolling_cpu_avg_60s], options[:adaptive_cpu_avg_max])
      end
      if metrics[:rolling_cpu_peak_60s].to_f > options[:adaptive_cpu_peak_max].to_f
        issues << format('rollingPeakCpu60s %.1f%% > %.1f%%', metrics[:rolling_cpu_peak_60s], options[:adaptive_cpu_peak_max])
      end

      # RSS/physical growth and slope are release-proof signals, not startup
      # warmup signals. Do not terminally fail an adaptive soak on those before
      # the minimum sample span; otherwise the run can fail because the sample
      # span is too short to be valid proof.
      if elapsed_seconds && elapsed_seconds.to_f < options[:min_duration_seconds].to_f
        return issues
      end

      if metrics[:rss_growth_from_baseline_mb].to_f > options[:adaptive_rss_growth_mb_max].to_f
        issues << format('rssGrowthFromBaseline %.1fMB > %.1fMB', metrics[:rss_growth_from_baseline_mb], options[:adaptive_rss_growth_mb_max])
      end
      if metrics[:physical_footprint_growth_from_baseline_mb].to_f > options[:adaptive_physical_growth_mb_max].to_f
        issues << format('physicalGrowthFromBaseline %.1fMB > %.1fMB', metrics[:physical_footprint_growth_from_baseline_mb], options[:adaptive_physical_growth_mb_max])
      end
      if !metrics[:rss_slope_mb_per_min].nil? && metrics[:rss_slope_mb_per_min].to_f > options[:adaptive_rss_slope_mb_per_min_max].to_f
        issues << format('rssSlope %.1fMB/min > %.1fMB/min', metrics[:rss_slope_mb_per_min], options[:adaptive_rss_slope_mb_per_min_max])
      end
      if !metrics[:physical_footprint_slope_mb_per_min].nil? && metrics[:physical_footprint_slope_mb_per_min].to_f > options[:adaptive_physical_slope_mb_per_min_max].to_f
        issues << format('physicalSlope %.1fMB/min > %.1fMB/min', metrics[:physical_footprint_slope_mb_per_min], options[:adaptive_physical_slope_mb_per_min_max])
      end
      issues
    end

    def resource_soak_adaptive_early_pass?(metrics, options)
      return false if metrics[:sample_count].to_i <= 0
      if options[:min_duration_seconds].to_i.positive?
        return false if metrics[:sample_count].to_i < options[:adaptive_baseline_sample_count].to_i
        return false if metrics[:peak_physical_footprint_mb].nil?
      end

      return false if metrics[:rolling_cpu_avg_60s].to_f > options[:adaptive_early_cpu_avg_max].to_f
      return false if metrics[:rolling_cpu_peak_60s].to_f > options[:adaptive_early_cpu_peak_max].to_f
      return false if metrics[:rss_growth_from_baseline_mb].to_f > options[:adaptive_early_rss_growth_mb_max].to_f
      return false if metrics[:physical_footprint_growth_from_baseline_mb].to_f > options[:adaptive_early_physical_growth_mb_max].to_f
      return false if !metrics[:rss_slope_mb_per_min].nil? && metrics[:rss_slope_mb_per_min].to_f > options[:adaptive_early_rss_slope_mb_per_min_max].to_f
      return false if !metrics[:physical_footprint_slope_mb_per_min].nil? && metrics[:physical_footprint_slope_mb_per_min].to_f > options[:adaptive_early_physical_slope_mb_per_min_max].to_f
      return false if !metrics[:recent_rss_range_mb].nil? && metrics[:recent_rss_range_mb].to_f > options[:adaptive_early_rss_range_mb_max].to_f
      return false if !metrics[:recent_physical_footprint_range_mb].nil? && metrics[:recent_physical_footprint_range_mb].to_f > options[:adaptive_early_physical_range_mb_max].to_f

      true
    end

    def resource_soak_next_interval_seconds(options, elapsed)
      return options[:interval_seconds] unless options[:adaptive]

      if elapsed.to_f < options[:adaptive_initial_duration_seconds].to_f
        options[:adaptive_initial_interval_seconds]
      else
        options[:interval_seconds]
      end
    end

    def resource_soak_issues(metrics, options, missing_sample_count: 0)
      issues = []
      if options[:duration_seconds] < options[:min_duration_seconds]
        issues << "duration #{options[:duration_seconds]}s is shorter than required #{options[:min_duration_seconds]}s"
      end
      issues << "missing process samples: #{missing_sample_count}" if missing_sample_count.to_i.positive?
      issues << 'no process samples collected' if metrics[:sample_count].to_i <= 0
      if metrics[:physical_missing_sample_count].to_i.positive?
        issues << "physical footprint missing for #{metrics[:physical_missing_sample_count]} sample(s)"
      end
      required_sample_span = [options[:min_duration_seconds].to_f - options[:interval_seconds].to_f - 1.0, 0.0].max
      if required_sample_span.positive? && metrics[:sample_span_seconds].to_f < required_sample_span
        issues << format(
          'sampled span %.1fs is shorter than required %.1fs',
          metrics[:sample_span_seconds].to_f,
          required_sample_span
        )
      end
      issues << format('avgCpu %.1f%% > %.1f%%', metrics[:avg_cpu], options[:cpu_avg_max]) if metrics[:avg_cpu].to_f > options[:cpu_avg_max]
      issues << format('peakRss %.1fMB > %.1fMB', metrics[:peak_rss_mb], options[:rss_peak_mb_max]) if metrics[:peak_rss_mb].to_f > options[:rss_peak_mb_max]
      issues << format('rssGrowth %.1fMB > %.1fMB', metrics[:rss_growth_mb], options[:rss_growth_mb_max]) if metrics[:rss_growth_mb].to_f > options[:rss_growth_mb_max]
      if metrics[:peak_physical_footprint_mb].nil?
        issues << 'physical footprint samples missing'
      else
        if metrics[:peak_physical_footprint_mb].to_f > options[:physical_peak_mb_max]
          issues << format('peakPhysical %.1fMB > %.1fMB', metrics[:peak_physical_footprint_mb], options[:physical_peak_mb_max])
        end
        if metrics[:physical_footprint_growth_mb].to_f > options[:physical_growth_mb_max]
          issues << format('physicalGrowth %.1fMB > %.1fMB', metrics[:physical_footprint_growth_mb], options[:physical_growth_mb_max])
        end
      end
      issues
    end

    def resource_soak_budget_payload(options)
      {
        adaptive: options[:adaptive],
        target_duration_seconds: options[:duration_seconds],
        min_duration_seconds: options[:min_duration_seconds],
        adaptive_initial_interval_seconds: options[:adaptive_initial_interval_seconds],
        adaptive_initial_duration_seconds: options[:adaptive_initial_duration_seconds],
        adaptive_consecutive_failures: options[:adaptive_consecutive_failures],
        adaptive_baseline_sample_count: options[:adaptive_baseline_sample_count],
        adaptive_rolling_window_seconds: options[:adaptive_rolling_window_seconds],
        cpu_avg_max: options[:cpu_avg_max],
        rss_peak_mb_max: options[:rss_peak_mb_max],
        rss_growth_mb_max: options[:rss_growth_mb_max],
        physical_peak_mb_max: options[:physical_peak_mb_max],
        physical_growth_mb_max: options[:physical_growth_mb_max],
        adaptive_cpu_avg_max: options[:adaptive_cpu_avg_max],
        adaptive_cpu_peak_max: options[:adaptive_cpu_peak_max],
        adaptive_rss_growth_mb_max: options[:adaptive_rss_growth_mb_max],
        adaptive_physical_growth_mb_max: options[:adaptive_physical_growth_mb_max],
        adaptive_rss_slope_mb_per_min_max: options[:adaptive_rss_slope_mb_per_min_max],
        adaptive_physical_slope_mb_per_min_max: options[:adaptive_physical_slope_mb_per_min_max],
        adaptive_early_cpu_avg_max: options[:adaptive_early_cpu_avg_max],
        adaptive_early_cpu_peak_max: options[:adaptive_early_cpu_peak_max],
        adaptive_early_rss_growth_mb_max: options[:adaptive_early_rss_growth_mb_max],
        adaptive_early_physical_growth_mb_max: options[:adaptive_early_physical_growth_mb_max],
        adaptive_early_rss_slope_mb_per_min_max: options[:adaptive_early_rss_slope_mb_per_min_max],
        adaptive_early_physical_slope_mb_per_min_max: options[:adaptive_early_physical_slope_mb_per_min_max]
      }
    end

    def resource_soak_print_progress(options, samples:, missing_sample_count:, elapsed:)
      return unless options[:progress]

      current_interval = resource_soak_next_interval_seconds(options, elapsed)
      print_every = [(60.0 / current_interval.to_f).ceil, 1].max
      sample_count = samples.length
      return unless sample_count == 1 || (sample_count % print_every).zero? || elapsed >= options[:duration_seconds]

      remaining = [options[:duration_seconds].to_f - elapsed.to_f, 0.0].max
      physical_count = samples.count { |sample| !sample[:physical_footprint_mb].nil? }
      if options[:adaptive]
        puts format(
          '   resource check progress: mode=adaptive sample=%<sample>d elapsed=%<elapsed>.0fs minPassAt=%<min>.0fs cap=%<cap>.0fs cadence=%<cadence>.0fs missing=%<missing>d physicalSamples=%<physical_samples>d/%<sample>d rss=%<rss>s physical=%<physical>s',
          sample: sample_count,
          elapsed: elapsed,
          min: options[:min_duration_seconds].to_f,
          cap: options[:duration_seconds].to_f,
          cadence: current_interval,
          missing: missing_sample_count,
          physical_samples: physical_count,
          rss: samples.last ? format('%.1fMB', samples.last[:rss_mb].to_f) : 'unknown',
          physical: samples.last && samples.last[:physical_footprint_mb] ? format('%.1fMB', samples.last[:physical_footprint_mb].to_f) : 'unknown'
        )
        $stdout.flush
        return
      end

      expected_samples = [(options[:duration_seconds].to_f / options[:interval_seconds].to_f).ceil, 1].max
      puts format(
        '   resource check progress: mode=fixed sample=%<sample>d/%<expected>d elapsed=%<elapsed>.0fs remaining=%<remaining>.0fs missing=%<missing>d physicalSamples=%<physical_samples>d/%<sample>d rss=%<rss>s physical=%<physical>s',
        sample: sample_count,
        expected: expected_samples,
        elapsed: elapsed,
        remaining: remaining,
        missing: missing_sample_count,
        physical_samples: physical_count,
        rss: samples.last ? format('%.1fMB', samples.last[:rss_mb].to_f) : 'unknown',
        physical: samples.last && samples.last[:physical_footprint_mb] ? format('%.1fMB', samples.last[:physical_footprint_mb].to_f) : 'unknown'
      )
      $stdout.flush
    end

    def resource_soak_human_status(status)
      case status.to_s
      when 'early_pass' then 'stable after minimum check'
      when 'full_duration_pass' then 'stable through full cap'
      when 'fixed' then 'fixed duration completed'
      when 'fail' then 'failed'
      when 'running' then 'still running'
      else status.to_s.empty? ? 'unknown' : status.to_s.tr('_', ' ')
      end
    end

    def resource_soak_human_issue(issue)
      text = issue.to_s
      case text
      when /\AavgCpu ([^ ]+) > ([^ ]+)/
        "average CPU #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ApeakRss ([^ ]+) > ([^ ]+)/
        "peak memory #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ArssGrowth(?:FromBaseline)? ([^ ]+) > ([^ ]+)/
        "memory growth #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ApeakPhysical ([^ ]+) > ([^ ]+)/
        "peak physical footprint #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\AphysicalGrowth(?:FromBaseline)? ([^ ]+) > ([^ ]+)/
        "physical footprint growth #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ArollingAvgCpu60s ([^ ]+) > ([^ ]+)/
        "60s average CPU #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ArollingPeakCpu60s ([^ ]+) > ([^ ]+)/
        "60s peak CPU #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\ArssSlope ([^ ]+) > ([^ ]+)/
        "memory trend #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      when /\AphysicalSlope ([^ ]+) > ([^ ]+)/
        "physical footprint trend #{Regexp.last_match(1)} exceeded #{Regexp.last_match(2)}"
      else
        text
      end
    end

    def resource_soak_round(value)
      value.nil? ? nil : value.round(3)
    end

    def customer_ui_required_arg(args, index, flag)
      value = args[index + 1]
      raise ArgumentError, "missing value for #{flag}" if value.nil? || value.start_with?('--')

      value
    end

    def customer_ui_with_live_app_logs(app_name)
      live_log = customer_ui_start_live_app_logs(app_name)
      @customer_ui_live_log_path = live_log && live_log[:path]
      yield
    ensure
      customer_ui_stop_live_app_logs(live_log) if live_log
    end

    def customer_ui_start_live_app_logs(app_name)
      return nil if ENV.fetch('SANEMASTER_CUSTOMER_UI_LIVE_APP_LOGS', '1') == '0'

      FileUtils.mkdir_p('outputs/live-logs')
      path = File.join(
        'outputs/live-logs',
        "customer_ui_#{app_name.downcase}_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.log"
      )
      reader, writer = IO.pipe
      pid = Process.spawn(
        '/usr/bin/log',
        'stream',
        '--level',
        'debug',
        '--predicate',
        "process == \"#{app_name}\"",
        '--style',
        'compact',
        out: writer,
        err: writer,
        pgroup: true
      )
      writer.close
      file = File.open(path, 'ab')
      file.binmode
      customer_ui_stream_command_output("📡 Live #{app_name} unified log stream: #{path}\n")
      thread = Thread.new do
        loop do
          chunk = reader.readpartial(8192)
          file.write(chunk)
          file.flush
          customer_ui_stream_live_log_chunk(chunk)
        end
      rescue EOFError, IOError, EncodingError
        nil
      ensure
        file.close unless file.closed?
        reader.close unless reader.closed?
      end
      { pid: pid, thread: thread, path: path }
    rescue StandardError => e
      customer_ui_stream_command_output("⚠️  Could not start live #{app_name} logs: #{e.class}: #{e.message}\n")
      nil
    ensure
      writer.close if defined?(writer) && writer && !writer.closed?
    end

    def customer_ui_stream_live_log_chunk(chunk)
      return unless customer_ui_stream_live_logs_to_stdout?

      text = chunk.to_s.b.force_encoding(Encoding::UTF_8).scrub
      @customer_ui_live_log_partial ||= +''
      @customer_ui_live_log_partial << text
      lines = @customer_ui_live_log_partial.lines
      if @customer_ui_live_log_partial.end_with?("\n")
        @customer_ui_live_log_partial = +''
      else
        @customer_ui_live_log_partial = lines.pop || +''
      end
      lines.each do |line|
        next unless customer_ui_relevant_live_log_line?(line)

        customer_ui_stream_command_output(line)
      end
    end

    def customer_ui_relevant_live_log_line?(line)
      return true if line.include?('[com.sanebar.app:')
      return true if line.match?(/Always-hidden|always-hidden|Move verification|Target X|layout snapshot|status-item|wake|separator|notch/)

      false
    end

    def customer_ui_stream_live_logs_to_stdout?
      ENV.fetch('SANEMASTER_CUSTOMER_UI_LIVE_LOG_STDOUT', '0') == '1'
    end

    def customer_ui_stop_live_app_logs(live_log)
      pid = live_log[:pid]
      begin
        Process.kill('TERM', -pid)
      rescue Errno::ESRCH, Errno::EINVAL, Errno::EPERM
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH, Errno::EINVAL, Errno::EPERM
          nil
        end
      end
      live_log[:thread]&.join(1)
      customer_ui_stream_command_output("📡 Live app log receipt: #{live_log[:path]}\n")
    end

    def customer_ui_run_command(*command)
      output = +''
      status = nil
      started_at = Time.now
      last_output_at = started_at
      last_heartbeat_at = Time.at(0)
      last_receipt_at = Time.at(0)
      timeout = customer_ui_command_timeout_seconds
      heartbeat_path = customer_ui_command_heartbeat_path(started_at)

      Open3.popen2e(*command, pgroup: true) do |stdin, stdout_err, wait_thr|
        stdin.close
        customer_ui_write_command_heartbeat(
          heartbeat_path,
          status: 'running',
          started_at: started_at,
          command: command,
          pid: wait_thr.pid,
          note: 'started'
        )
        loop do
          if customer_ui_drain_command_output(stdout_err, output) { |chunk| customer_ui_stream_command_output(chunk) }
            last_output_at = Time.now
          end

          if wait_thr.join(0.2)
            status = wait_thr.value
            customer_ui_drain_command_output(stdout_err, output, max_drain_seconds: 1.0) { |chunk| customer_ui_stream_command_output(chunk) }
            customer_ui_write_command_heartbeat(
              heartbeat_path,
              status: status.success? ? 'passed' : 'failed',
              started_at: started_at,
              command: command,
              pid: wait_thr.pid,
              exitstatus: status.exitstatus,
              note: 'exited'
            )
            break
          end

          if customer_ui_should_emit_heartbeat?(last_output_at, last_heartbeat_at)
            elapsed = (Time.now - started_at).round(1)
            customer_ui_stream_command_output("   ... customer UI command still running (#{elapsed}s): #{customer_ui_command_summary(command)}\n")
            last_heartbeat_at = Time.now
          end

          if customer_ui_should_write_heartbeat?(last_receipt_at)
            customer_ui_write_command_heartbeat(
              heartbeat_path,
              status: 'running',
              started_at: started_at,
              command: command,
              pid: wait_thr.pid,
              note: 'heartbeat'
            )
            last_receipt_at = Time.now
          end

          next unless timeout && (Time.now - started_at) >= timeout

          output << "\ncustomer UI command timeout after #{timeout.to_i}s: #{customer_ui_command_summary(command)}\n"
          customer_ui_stream_command_output("customer UI command timeout after #{timeout.to_i}s: #{customer_ui_command_summary(command)}\n")
          customer_ui_write_command_heartbeat(
            heartbeat_path,
            status: 'timeout',
            started_at: started_at,
            command: command,
            pid: wait_thr.pid,
            note: "timeout after #{timeout.to_i}s"
          )
          customer_ui_terminate_process_group(wait_thr)
          status = customer_ui_failed_status
          customer_ui_drain_command_output(stdout_err, output, max_drain_seconds: 1.0) { |chunk| customer_ui_stream_command_output(chunk) }
          break
        end
      end

      [output, status || customer_ui_failed_status]
    rescue StandardError => e
      customer_ui_write_command_heartbeat(
        heartbeat_path,
        status: 'failed',
        started_at: started_at,
        command: command,
        note: "#{e.class}: #{e.message}"
      ) if defined?(heartbeat_path) && heartbeat_path
      ["customer UI command failed: #{e.class}: #{e.message}", customer_ui_failed_status]
    end

    def customer_ui_command_heartbeat_path(started_at)
      FileUtils.mkdir_p('outputs/live-logs')
      File.join(
        'outputs/live-logs',
        "customer_ui_command_heartbeat_#{started_at.utc.strftime('%Y%m%dT%H%M%SZ')}_#{$$}.json"
      )
    end

    def customer_ui_write_command_heartbeat(path, status:, started_at:, command:, pid: nil, exitstatus: nil, note: nil)
      elapsed = (Time.now - started_at).round(1)
      payload = {
        status: status,
        pid: pid,
        process_group: pid,
        exitstatus: exitstatus,
        elapsed_seconds: elapsed,
        updated_at: Time.now.utc.iso8601,
        started_at: started_at.utc.iso8601,
        host: Socket.gethostname,
        command: customer_ui_command_summary(command),
        live_log_path: @customer_ui_live_log_path,
        note: note
      }.compact
      tmp_path = "#{path}.tmp"
      File.write(tmp_path, JSON.pretty_generate(payload))
      File.rename(tmp_path, path)
    rescue StandardError
      nil
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
    end

    def customer_ui_command_timeout_seconds
      timeout = ENV.fetch('SANEMASTER_CUSTOMER_UI_COMMAND_TIMEOUT', CUSTOMER_UI_COMMAND_TIMEOUT_SECONDS.to_s).to_f
      timeout.positive? ? timeout : CUSTOMER_UI_COMMAND_TIMEOUT_SECONDS
    end

    def customer_ui_drain_command_output(stdout_err, output, max_drain_seconds: 0.05)
      deadline = Time.now + max_drain_seconds
      drained = false
      loop do
        ready = IO.select([stdout_err], nil, nil, 0.05)
        break unless ready

        chunk = stdout_err.read_nonblock(8192, exception: false)
        case chunk
        when String
          output << chunk
          yield chunk if block_given?
          drained = true unless chunk.empty?
        when :wait_readable, nil
          break
        end

        break if Time.now >= deadline
      end
      drained
    rescue EOFError, IOError
      false
    end

    def customer_ui_should_emit_heartbeat?(last_output_at, last_heartbeat_at)
      return false unless customer_ui_stream_progress?

      quiet_seconds = customer_ui_progress_heartbeat_seconds
      (Time.now - last_output_at) >= quiet_seconds && (Time.now - last_heartbeat_at) >= quiet_seconds
    end

    def customer_ui_should_write_heartbeat?(last_receipt_at)
      (Time.now - last_receipt_at) >= customer_ui_progress_heartbeat_seconds
    end

    def customer_ui_progress_heartbeat_seconds
      seconds = ENV.fetch('SANEMASTER_CUSTOMER_UI_PROGRESS_HEARTBEAT_SECONDS', '15').to_f
      seconds.positive? ? seconds : 15.0
    end

    def customer_ui_stream_progress?
      ENV.fetch('SANEMASTER_CUSTOMER_UI_STREAM_PROGRESS', '1') != '0'
    end

    def customer_ui_stream_command_output(chunk)
      return if chunk.to_s.empty? || !customer_ui_stream_progress? || @customer_ui_stream_output_closed

      $stderr.write(chunk)
      $stderr.flush
    rescue Errno::EPIPE, IOError
      @customer_ui_stream_output_closed = true
    end

    def customer_ui_terminate_process_group(wait_thr)
      descendants = customer_ui_descendant_pids(wait_thr.pid)
      [-(wait_thr.pid), wait_thr.pid, *descendants].uniq.each do |pid|
        begin
          Process.kill('TERM', pid)
        rescue Errno::ESRCH, Errno::EINVAL
          nil
        end
      end
      return if wait_thr.join(1)

      descendants = customer_ui_descendant_pids(wait_thr.pid)
      [-(wait_thr.pid), wait_thr.pid, *descendants].uniq.each do |pid|
        begin
          Process.kill('KILL', pid)
        rescue Errno::ESRCH, Errno::EINVAL
          nil
        end
      end
      wait_thr.join(1)
    end

    def customer_ui_descendant_pids(root_pid)
      output, status = Open3.capture2('ps', '-axo', 'pid=,ppid=')
      return [] unless status.success?

      children_by_parent = Hash.new { |hash, key| hash[key] = [] }
      output.each_line do |line|
        pid_text, ppid_text = line.strip.split(/\s+/, 2)
        pid = pid_text.to_i
        ppid = ppid_text.to_i
        next unless pid.positive? && ppid.positive?

        children_by_parent[ppid] << pid
      end

      descendants = []
      queue = children_by_parent[root_pid.to_i].dup
      until queue.empty?
        pid = queue.shift
        next if descendants.include?(pid)

        descendants << pid
        queue.concat(children_by_parent[pid])
      end
      descendants
    rescue StandardError
      []
    end

    def customer_ui_command_summary(command)
      command.reject { |part| part.is_a?(Hash) }.map(&:to_s).join(' ')
    end

    def customer_ui_failed_status
      @customer_ui_failed_status ||= Struct.new(:exitstatus) do
        def success?
          false
        end
      end.new(nil)
    end

    def customer_ui_prepare_target_before_sweep(app_name)
      return [] unless customer_ui_visual_precheck_required?
      project_type = metadata_value(current_saneprocess_config, 'type').to_s
      # The generic launch lane stages a macOS bundle in /Applications and
      # cannot launch an iOS simulator target. iOS workflow runners provide
      # their own simulator/source-bound evidence, so continue to the normal
      # cleanup, visual precheck, and app-specific runner instead.
      return [] if project_type == 'ios_app'

      if app_name == 'SaneBar'
        return [] if resource_soak_running_app_candidate(app_name)

        output, status = customer_ui_run_command('./scripts/SaneMaster.rb', 'test_mode', '--release', '--no-logs')
        return [] if status.success? && resource_soak_running_app_candidate(app_name)

        return ["Mini release target launch failed before customer UI sweep: #{output}"]
      end

      output, status = customer_ui_run_command('./scripts/SaneMaster.rb', 'launch')
      status.success? ? [] : ["Mini target launch failed before customer UI sweep: #{output}"]
    end

    def customer_ui_cleanup_before_sweep(app_name)
      guard = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/mini/mini-visual-workspace-guard.sh')
      return [] unless File.file?(guard)

      output, status = customer_ui_run_command(
        guard,
        '--cleanup',
        '--app',
        app_name,
        '--allow-windowless-target',
        '--json'
      )
      status.success? ? [] : ["Mini visual workspace cleanup failed before customer UI sweep: #{output}"]
    end

    def customer_ui_refresh_runtime_evidence_before_sweep(app_name)
      return [] unless app_name == 'SaneBar'

      qa_script = if respond_to?(:release_project_qa_script)
                    release_project_qa_script
                  else
                    ['Scripts/qa.rb', 'scripts/qa.rb'].find { |path| File.exist?(path) }
                  end
      return ['Missing SaneBar runtime QA script before customer UI sweep'] unless qa_script

      qa_env = customer_ui_runtime_smoke_env(app_name)
      output, status = customer_ui_run_command(qa_env, RbConfig.ruby, qa_script)
      return ["Mini runtime smoke failed before customer UI sweep: #{customer_ui_summarize_visual_precheck_failure(output)}"] unless status.success?

      customer_ui_refresh_resource_soak_before_sweep(app_name)
    end

    def customer_ui_refresh_resource_soak_before_sweep(app_name)
      return [] unless app_name == 'SaneBar'

      duration = ENV.fetch('SANEMASTER_CUSTOMER_UI_RESOURCE_SOAK_SECONDS', '600')
      min_duration = ENV.fetch('SANEMASTER_CUSTOMER_UI_RESOURCE_SOAK_MIN_SECONDS', '240')
      soak_env = {
        'SANEMASTER_RESOURCE_SOAK_SECONDS' => duration,
        'SANEMASTER_RESOURCE_SOAK_MIN_SECONDS' => min_duration,
        'SANEMASTER_RESOURCE_SOAK_PROGRESS' => '0'
      }
      output, status = customer_ui_run_command(
        soak_env,
        './scripts/SaneMaster.rb',
        'resource_soak',
        '--adaptive',
        '--duration-seconds',
        duration,
        '--json'
      )
      return [] if status.success?

      ["Mini resource soak failed before customer UI sweep: #{customer_ui_summarize_visual_precheck_failure(output)}"]
    end

    def customer_ui_runtime_smoke_env(app_name)
      app_prefix = app_name.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')
      env = {
        'LANG' => (ENV['LANG'].to_s.empty? ? 'en_US.UTF-8' : ENV['LANG']),
        'LC_ALL' => (ENV['LC_ALL'].to_s.empty? ? 'en_US.UTF-8' : ENV['LC_ALL']),
        'PATH' => ([ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin'].compact.join(':')),
        'SANEPROCESS_RUNTIME_SMOKE_ONLY' => '1',
        'SANEPROCESS_RUN_RUNTIME_SMOKE' => '1',
        'SANEBAR_STARTUP_PROBE_RESOURCE_SOAK_AFTER_155' => '0'
      }
      # FM-1 + FM-2 regression gates are DEFAULT-ON and release-blocking on the
      # normal customer_ui_sweep runtime-smoke path. They run without anyone
      # setting an env flag:
      #   FM-1 hidden-outbound Always-Hidden move (live_zone_smoke) — keeps the
      #        release red while the window-invalidation no-op bug is unfixed.
      #   FM-2 explicit divider survives wake/validation churn (wake_layout_probe).
      # A focused unrelated run can opt out only by exporting the matching
      # SANEBAR_SMOKE_DISABLE_HIDDEN_OUTBOUND_AH=1 /
      # SANEBAR_WAKE_PROBE_EXPLICIT_DIVIDER_SURVIVAL=0 before invoking the sweep;
      # that opt-out is passed through here but the default below is ON.
      if app_name == 'SaneBar'
        env['SANEBAR_SMOKE_REQUIRE_HIDDEN_OUTBOUND_AH'] =
          ENV['SANEBAR_SMOKE_DISABLE_HIDDEN_OUTBOUND_AH'] == '1' ? '0' : '1'
        env['SANEBAR_WAKE_PROBE_EXPLICIT_DIVIDER_SURVIVAL'] =
          ENV.fetch('SANEBAR_WAKE_PROBE_EXPLICIT_DIVIDER_SURVIVAL', '1')
        env['SANEBAR_SMOKE_DISABLE_HIDDEN_OUTBOUND_AH'] =
          ENV.fetch('SANEBAR_SMOKE_DISABLE_HIDDEN_OUTBOUND_AH', '0')
      end
      unless app_prefix.empty?
        env["#{app_prefix}_RUNTIME_SMOKE_ONLY"] = '1'
        env["#{app_prefix}_RUN_RUNTIME_SMOKE"] = '1'
      end
      env
    end

    def customer_ui_visual_precheck(app_name)
      return { ok: true, issues: [] } unless customer_ui_visual_precheck_required?

      out, status = customer_ui_run_command(
        './scripts/SaneMaster.rb',
        'visual_smoke',
        '--app',
        app_name,
        '--require-peekaboo',
        '--no-app',
        '--json'
      )
      unless status.success?
        return {
          ok: false,
          issues: ["Mini visual precheck failed before customer UI sweep: #{customer_ui_summarize_visual_precheck_failure(out)}"]
        }
      end

      report = customer_ui_parse_json_object(out)
      image_artifacts = Array(report['artifacts']).select do |path|
        CUSTOMER_UI_IMAGE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
      end
      usable_image_artifacts = image_artifacts.reject.with_index do |path, index|
        customer_ui_single_screenshot_issues(path.to_s, index).any?
      end
      if report['ok'] == true && usable_image_artifacts.any?
        { ok: true, issues: [] }
      else
        image_issues = image_artifacts.flat_map.with_index do |path, index|
          customer_ui_single_screenshot_issues(path.to_s, index)
        end
        reason = [report['reason'].to_s.strip, *image_issues].reject(&:empty?).join('; ')
        {
          ok: false,
          issues: ["Mini visual precheck did not produce usable screenshot evidence: #{reason}"]
        }
      end
    rescue JSON::ParserError => e
      { ok: false, issues: ["Mini visual precheck returned invalid JSON: #{e.message}"] }
    end

    def customer_ui_parse_json_object(output)
      JSON.parse(output)
    rescue JSON::ParserError
      text = output.to_s
      start_index = text.index('{')
      end_index = text.rindex('}')
      raise unless start_index && end_index && end_index >= start_index

      JSON.parse(text[start_index..end_index])
    end

    def customer_ui_visual_precheck_required?
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      return false unless manifest_path

      manifest = read_customer_ui_yaml(manifest_path)
      Array(manifest['actions']).any? do |action|
        next false if action['release_required'] == false

        CUSTOMER_UI_VISUAL_PRECHECK_REQUIRED_PROOF_LEVELS.include?(action['required_proof_level'].to_s) ||
          required_evidence_types(action).any? { |type| %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(type) } ||
          action['requires_visual'] == true ||
          action['requires_visual_evidence'] == true
      end
    rescue Psych::SyntaxError
      true
    end

    def customer_ui_summarize_visual_precheck_failure(output)
      parsed = JSON.parse(output)
      reason = parsed['reason'].to_s.strip
      cleanliness = Array(parsed.dig('cleanliness', 'issues')).map(&:to_s).reject(&:empty?)
      summary = ([reason] + cleanliness).reject(&:empty?).join('; ')
      return summary unless summary.empty?

      output.to_s.lines.last(6).map(&:strip).reject(&:empty?).join(' | ')
    rescue JSON::ParserError
      output.to_s.lines.last(6).map(&:strip).reject(&:empty?).join(' | ')
    end

    def current_saneprocess_config
      path = File.join(Dir.pwd, '.saneprocess')
      return {} unless customer_ui_regular_file?(path)

      YAML.safe_load(safe_customer_ui_file_read(path)) || {}
    rescue StandardError
      {}
    end

    def read_customer_ui_yaml(path)
      YAML.safe_load(safe_customer_ui_file_read(path), permitted_classes: [Time, Date], aliases: false) || {}
    end

    def read_customer_ui_json(path)
      JSON.parse(safe_customer_ui_file_read(path))
    end

    def newest_customer_ui_receipt_path
      CUSTOMER_UI_RECEIPT_PATHS
        .select { |path| customer_ui_regular_file?(path) }
        .max_by { |path| File.mtime(File.expand_path(path, Dir.pwd)) }
    end

    def customer_ui_manifest_issues(manifest_path, manifest, required_actions)
      issues = []
      issues << "Manifest app does not match .saneprocess name" if manifest['app'] && manifest['app'].to_s != (metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd)).to_s

      ids = []
      required_actions.each_with_index do |action, index|
        id = action['id'].to_s.strip
        ids << id
        prefix = id.empty? ? "action ##{index + 1}" : id
        issues << "#{prefix}: missing id" if id.empty?
        issues << "#{prefix}: missing title" if action['title'].to_s.strip.empty?
        issues << "#{prefix}: missing customer surface" if Array(action['surfaces']).empty?
        issues << "#{prefix}: missing click/interaction steps" if Array(action['steps']).empty?
        issues << "#{prefix}: missing assertions" if Array(action['assertions']).empty?
        issues << "#{prefix}: missing evidence requirement" if Array(action['evidence']).empty?
        proof_level = action['required_proof_level'].to_s.strip
        if proof_level.empty?
          issues << "#{prefix}: missing required_proof_level"
        elsif !CUSTOMER_UI_PROOF_LEVELS.include?(proof_level)
          issues << "#{prefix}: invalid required_proof_level #{proof_level.inspect}"
        end
        evidence_types = action['required_evidence_types']
        if evidence_types && !(evidence_types.is_a?(Array) && evidence_types.all? { |item| item.to_s.strip != '' })
          issues << "#{prefix}: required_evidence_types must be a non-empty list when present"
        end
        failure_classes = action['historical_failure_classes']
        if failure_classes.nil?
          issues << "#{prefix}: missing historical_failure_classes; every release action must name the prior customer failure class it guards against"
        elsif !(failure_classes.is_a?(Array) && failure_classes.all? { |item| CUSTOMER_UI_FAILURE_CLASSES.include?(item.to_s.strip) })
          issues << "#{prefix}: historical_failure_classes must use known values: #{CUSTOMER_UI_FAILURE_CLASSES.join(', ')}"
        end
        issues.concat(customer_ui_functional_state_manifest_issues(prefix, action))
      end

      id_counts = Hash.new(0)
      ids.reject(&:empty?).each { |id| id_counts[id] += 1 }
      duplicate_ids = id_counts.select { |_id, count| count > 1 }.keys
      issues << "Duplicate customer UI action ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
      issues.concat(customer_ui_runtime_state_matrix_issues(manifest, required_actions))
      issues << "#{manifest_path}: version must be 1" unless manifest['version'].to_i == 1
      issues
    end

    def customer_ui_runtime_state_matrix_issues(manifest, required_actions)
      issues = []
      matrix = manifest['runtime_state_matrix']
      required = manifest['require_standard_runtime_state_matrix'] == true
      if matrix.nil?
        issues << "Missing runtime_state_matrix; released apps with customer runtime workflows must map lifecycle states to action ids" if required
        return issues
      end

      rows = case matrix
             when Hash
               matrix.map do |id, row|
                 row = {} unless row.is_a?(Hash)
                 row.merge('id' => row['id'] || id.to_s)
               end
             when Array
               matrix
             else
               issues << 'runtime_state_matrix must be a mapping or list'
               return issues
             end

      action_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      row_ids = []
      rows.each_with_index do |row, index|
        unless row.is_a?(Hash)
          issues << "runtime_state_matrix row ##{index + 1} must be an object"
          next
        end

        id = row['id'].to_s.strip
        prefix = id.empty? ? "runtime_state_matrix row ##{index + 1}" : "runtime_state_matrix #{id}"
        row_ids << id unless id.empty?
        issues << "#{prefix}: missing id" if id.empty?

        linked_action_ids = Array(row['action_ids']).map(&:to_s).map(&:strip).reject(&:empty?)
        issues << "#{prefix}: missing action_ids" if linked_action_ids.empty?
        unknown_ids = linked_action_ids - action_ids
        issues << "#{prefix}: unknown action_id(s): #{unknown_ids.join(', ')}" unless unknown_ids.empty?

        proof_level = row['required_proof_level'].to_s.strip
        if proof_level.empty?
          issues << "#{prefix}: missing required_proof_level"
        elsif !CUSTOMER_UI_WORKFLOW_PROOF_LEVELS.include?(proof_level)
          issues << "#{prefix}: required_proof_level must be runtime_visual or full_runtime_completion"
        end

        evidence_types = Array(row['required_evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
        issues << "#{prefix}: missing required_evidence_types" if evidence_types.empty?

        runner = row['runner'].to_s.strip
        proof_command = row['proof_command'].to_s.strip
        issues << "#{prefix}: missing runner or proof_command" if runner.empty? && proof_command.empty?

        why = row['why'].to_s.strip
        issues << "#{prefix}: missing why/customer risk" if why.empty?
      end

      if required
        missing_states = CUSTOMER_UI_STANDARD_RUNTIME_STATES - row_ids
        issues << "runtime_state_matrix missing standard state(s): #{missing_states.join(', ')}" unless missing_states.empty?
      end

      issues
    end

    def customer_ui_functional_state_manifest_issues(prefix, action)
      issues = []
      state = action['functional_state']
      unless state.is_a?(Hash)
        issues << "#{prefix}: missing functional_state; every customer action must declare the seeded app/user state needed to test promised behavior"
        state = {}
      end

      description = state['description'].to_s.strip
      setup_steps = Array(state['setup_steps']).map(&:to_s).map(&:strip).reject(&:empty?)
      fixture_paths = Array(state['fixture_paths']).map(&:to_s).map(&:strip).reject(&:empty?)
      not_required_reason = state['not_required_reason'].to_s.strip

      issues << "#{prefix}: functional_state missing description" if description.empty?
      if setup_steps.empty? && fixture_paths.empty? && not_required_reason.empty?
        issues << "#{prefix}: functional_state must include setup_steps, fixture_paths, or not_required_reason"
      end

      user_inputs = Array(action['user_inputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      expected_outputs = Array(action['expected_outputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      if %w[fixture_completion full_runtime_completion].include?(action['required_proof_level'].to_s)
        issues << "#{prefix}: full/fixture completion actions must declare user_inputs or fixture_paths" if user_inputs.empty? && fixture_paths.empty?
        issues << "#{prefix}: full/fixture completion actions must declare expected_outputs" if expected_outputs.empty?
      end

      issues
    end

    def customer_ui_receipt_issues(app_name:, manifest_sha:, source_fingerprint:, required_actions:, manifest: {}, receipt:, strict_visual: false)
      issues = []
      issues << "Receipt app #{receipt['app']} does not match #{app_name}" if receipt['app'].to_s != app_name.to_s
      issues << "Receipt status is #{receipt['status'].inspect}, expected \"passed\"" unless receipt['status'].to_s == 'passed'
      unless customer_ui_receipt_host_allowed?(receipt['host'])
        issues << 'Receipt was not generated on the Mini or an explicitly approved local Air fallback'
      end
      issues << 'Receipt manifest hash is stale' unless receipt['manifest_sha256'].to_s == manifest_sha
      unless customer_ui_receipt_source_fingerprint_current?(receipt, source_fingerprint)
        issues << 'Receipt source fingerprint is stale; rerun customer UI QA after the latest code change'
      end
      issues << 'Receipt is missing screenshot evidence' if Array(receipt['screenshots']).empty?
      issues.concat(customer_ui_screenshot_issues(Array(receipt['screenshots'])))

      tested_ids = Array(receipt['tested_action_ids']).map(&:to_s)
      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      missing_ids = required_ids - tested_ids
      issues << "Receipt does not cover release-required action(s): #{missing_ids.join(', ')}" unless missing_ids.empty?
      issues.concat(customer_ui_action_result_issues(required_actions, receipt, strict_visual: strict_visual))
      issues.concat(customer_ui_runtime_state_receipt_issues(receipt, manifest: manifest, app_name: app_name))
      issues.concat(customer_ui_screenshot_reuse_issues(required_actions, receipt))

      begin
        generated_at = Time.parse(receipt['generated_at'].to_s)
        now = Time.now
        if generated_at > now + 5 * 60
          issues << 'Receipt generated_at is future-dated; rerun customer UI QA for this release'
        elsif now - generated_at > 12 * 60 * 60
          issues << 'Receipt is older than 12 hours; rerun customer UI QA for this release'
        end
      rescue ArgumentError
        issues << 'Receipt generated_at is missing or invalid'
      end

      issues
    end

    def customer_ui_action_result_issues(required_actions, receipt, strict_visual: false)
      issues = []
      results = receipt['action_results']
      unless results.is_a?(Hash)
        return ['Receipt is missing per-action results; do not mark customer-facing actions covered from a coarse smoke bucket']
      end

      required_actions.each do |action|
        id = action['id'].to_s
        result = results[id]
        if result.nil?
          issues << "#{id}: missing per-action result"
          next
        end

        unless result.is_a?(Hash)
          issues << "#{id}: per-action result must be an object"
          next
        end

        coverage_status = result['coverage_status'].to_s.strip
        action_status = result['status'].to_s.strip
        if coverage_status.empty?
          issues << "#{id}: status is #{result['status'].inspect}, expected \"passed\"" unless action_status == 'passed'
        else
          issues << "#{id}: coverage_status is #{result['coverage_status'].inspect}, expected \"covered\"" unless coverage_status == 'covered'
          issues << "#{id}: do not mix coverage_status with action status; use action status only for real completion receipts" unless action_status.empty?
        end
        required_proof_level = action['required_proof_level'].to_s
        proof_level = result['proof_level'].to_s.strip
        if proof_level.empty?
          issues << "#{id}: missing proof_level; source/test/safe-surface notes cannot silently count as release proof"
        elsif !CUSTOMER_UI_PROOF_LEVELS.include?(proof_level)
          issues << "#{id}: invalid proof_level #{proof_level.inspect}"
        elsif !customer_ui_proof_satisfies?(proof_level, required_proof_level)
          issues << "#{id}: proof_level #{proof_level.inspect} does not satisfy required_proof_level #{required_proof_level.inspect}"
        end

        evidence = Array(result['evidence'])
        issues << "#{id}: missing per-action evidence" if evidence.empty?
        evidence_types = []
        evidence.each_with_index do |item, index|
          if item.is_a?(Hash)
            evidence_type = item['type'].to_s.strip
            evidence_types << evidence_type unless evidence_type.empty?
            issues << "#{id}: evidence ##{index + 1} missing type" if evidence_type.empty?
            issues << "#{id}: evidence ##{index + 1} missing detail" if item['detail'].to_s.strip.empty?
            issues.concat(customer_ui_evidence_artifact_issues(id, item, index))
          elsif item.to_s.strip.empty?
            issues << "#{id}: evidence ##{index + 1} is blank"
          end
        end
        required_evidence_types(action).each do |required_type|
          next if evidence_types.include?(required_type)

          issues << "#{id}: missing required evidence type #{required_type.inspect}"
        end
        if customer_ui_action_requires_visual?(action, result) &&
           evidence_types.none? { |type| CUSTOMER_UI_SCREENSHOT_EVIDENCE_TYPES.include?(type) }
          issues << "#{id}: visual proof required but no screenshot/visual evidence is attached to the action result"
        end
        if strict_visual && evidence_types.none? { |type| CUSTOMER_UI_SCREENSHOT_EVIDENCE_TYPES.include?(type) }
          issues << "#{id}: App Store strict visual gate requires screenshot/visual evidence for every release-required action"
        end
        issues.concat(customer_ui_blocking_status_text_issues(id, result))
        issues.concat(customer_ui_full_runtime_completion_issues(id, action, result))
        issues.concat(customer_ui_functional_state_receipt_issues(id, action, result))
        issues.concat(customer_ui_workflow_receipt_issues(id, action, result))
      end

      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      extra_ids = results.keys.map(&:to_s) - required_ids
      issues << "Receipt has per-action result(s) not in manifest: #{extra_ids.join(', ')}" unless extra_ids.empty?
      issues
    end

    def customer_ui_blocking_status_text_issues(id, result)
      text = [
        result['functional_state'],
        result['inputs'],
        result['output_assertions'],
        result['declared_inputs'],
        result['covered_assertions'],
        result['workflow'],
        result['evidence']
      ].map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join("\n")
      blocking = CUSTOMER_UI_BLOCKING_STATUS_TEXT.select { |label| text.include?(label) }
      return [] if blocking.empty?

      ["#{id}: customer UI evidence contains blocking status text: #{blocking.uniq.join(', ')}"]
    end

    def customer_ui_runtime_state_receipt_issues(receipt, manifest: {}, app_name: nil)
      rows = receipt['runtime_state_results']
      matrix_rows = customer_ui_runtime_matrix_rows(manifest)
      requires_rows = !matrix_rows.empty?
      return [] if rows.nil? && !requires_rows
      return ['Receipt is missing runtime_state_results; lifecycle matrices cannot pass from action evidence alone'] unless rows.is_a?(Array)

      issues = []
      rows_by_id = {}
      rows.each do |row|
        rows_by_id[row['id'].to_s.strip] = row if row.is_a?(Hash)
      end
      matrix_ids = matrix_rows.map { |row| row['id'].to_s.strip }.reject(&:empty?)
      missing_ids = matrix_ids - rows_by_id.keys
      issues << "Receipt runtime_state_results missing manifest state(s): #{missing_ids.join(', ')}" unless missing_ids.empty?

      matrix_rows.each do |matrix_row|
        id = matrix_row['id'].to_s.strip
        row = rows_by_id[id]
        next unless row.is_a?(Hash)

        issues.concat(customer_ui_runtime_state_row_receipt_issues(id, matrix_row, row, app_name: app_name))
      end

      rows.each do |row|
        unless row.is_a?(Hash)
          issues << 'runtime_state_results row must be an object'
          next
        end

        id = row['id'].to_s.strip
        label = id.empty? ? 'runtime_state_results row' : "runtime_state_results #{id}"
        status = row['status'].to_s.strip
        issues << "#{label}: status is #{status.inspect}, expected \"passed\"" unless status == 'passed'
        issues << "#{label}: missing evidence_paths" if Array(row['evidence_paths']).empty?
      end
      issues
    end

    def customer_ui_runtime_matrix_rows(manifest)
      return [] unless manifest.is_a?(Hash)

      matrix = manifest['runtime_state_matrix']
      case matrix
      when Hash
        matrix.map do |id, row|
          row = {} unless row.is_a?(Hash)
          row.merge('id' => row['id'] || id.to_s)
        end
      when Array
        matrix.select { |row| row.is_a?(Hash) }
      else
        []
      end
    end

    def customer_ui_runtime_state_row_receipt_issues(id, matrix_row, receipt_row, app_name: nil)
      label = id.empty? ? 'runtime_state_results row' : "runtime_state_results #{id}"
      issues = []

      required_types = Array(matrix_row['required_evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
      evidence_types = Array(receipt_row['evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
      missing_types = required_types - evidence_types
      unless missing_types.empty?
        issues << "#{label}: missing required evidence type(s): #{missing_types.join(', ')}"
      end

      if id == 'resource_soak_growth'
        issues.concat(customer_ui_resource_soak_runtime_receipt_issues(label, receipt_row))
      end
      issues.concat(customer_ui_runtime_evidence_receipt_issues(id, label, receipt_row))
      issues.concat(customer_ui_runtime_candidate_receipt_issues(label, receipt_row, app_name: app_name))

      required_scenarios = Array(matrix_row['required_scenarios']).map(&:to_s).map(&:strip).reject(&:empty?)
      return issues if required_scenarios.empty?

      completed_scenarios = customer_ui_runtime_completed_scenarios(receipt_row)
      missing_scenarios = required_scenarios - completed_scenarios
      unless missing_scenarios.empty?
        issues << "#{label}: missing required scenario proof(s): #{missing_scenarios.join(', ')}"
      end
      issues
    end

    def customer_ui_runtime_candidate_receipt_issues(label, receipt_row, app_name: nil)
      candidate = receipt_row['runtime_candidate']
      return ["#{label}: missing runtime candidate metadata"] unless candidate.is_a?(Hash)

      issues = []
      app_path = candidate['app_path'].to_s
      app_version = candidate['app_version'].to_s
      app_build = candidate['app_build'].to_s
      issues << "#{label}: runtime candidate missing app_path" if app_path.empty?
      issues << "#{label}: runtime candidate missing app_version" if app_version.empty?
      issues << "#{label}: runtime candidate missing app_build" if app_build.empty?
      unless app_name.to_s.empty? || app_path.empty? || File.expand_path(app_path) == File.join('/Applications', "#{app_name}.app")
        issues << "#{label}: runtime candidate app_path #{app_path.inspect} does not match installed candidate #{File.join('/Applications', "#{app_name}.app").inspect}"
      end

      expected = resource_soak_expected_project_version
      unless expected[:app_version].to_s.empty? || app_version == expected[:app_version].to_s
        issues << "#{label}: runtime candidate version #{app_version.inspect} does not match project #{expected[:app_version].inspect}"
      end
      unless expected[:app_build].to_s.empty? || app_build == expected[:app_build].to_s
        issues << "#{label}: runtime candidate build #{app_build.inspect} does not match project #{expected[:app_build].inspect}"
      end
      issues
    end

    def customer_ui_runtime_evidence_receipt_issues(id, label, receipt_row)
      paths = Array(receipt_row['evidence_paths']).map(&:to_s).map(&:strip).reject(&:empty?)
      return ["#{label}: missing evidence_paths"] if paths.empty?

      issues = []
      temp_paths = paths.select { |path| customer_ui_temp_artifact_path?(path) }
      unless temp_paths.empty?
        issues << "#{label}: runtime evidence must be durable; temp path(s) are not release proof: #{temp_paths.join(', ')}"
      end

      if customer_ui_runtime_preflight_required_id?(id)
        runtime_preflight_paths = paths.select { |path| customer_ui_durable_runtime_preflight_path?(id, path) }
        if runtime_preflight_paths.empty?
          issues << "#{label}: missing durable runtime-preflight evidence under outputs/runtime-preflight"
        end
        missing_preflight_paths = runtime_preflight_paths.reject { |path| customer_ui_regular_file?(path) }
        unless missing_preflight_paths.empty?
          issues << "#{label}: durable runtime-preflight evidence path(s) do not exist or are unsafe: #{missing_preflight_paths.join(', ')}"
        end
      end

      durable_paths = paths.select do |path|
        customer_ui_durable_runtime_evidence_path?(path) ||
          customer_ui_durable_runtime_preflight_path?(id, path)
      end
      if durable_paths.empty?
        issues << "#{label}: missing durable runtime evidence under outputs/customer-ui or outputs/runtime-preflight"
      end

      missing_paths = durable_paths.reject { |path| customer_ui_regular_file?(path) }
      return issues if missing_paths.empty?

      issues << "#{label}: durable runtime evidence path(s) do not exist or are unsafe: #{missing_paths.join(', ')}"
      issues
    end

    def customer_ui_durable_runtime_evidence_path?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      root = File.expand_path(File.join(Dir.pwd, 'outputs', 'customer-ui'))
      expanded = File.realpath(expanded) if File.exist?(expanded)
      root = File.realpath(root) if File.exist?(root)
      expanded.tr('\\', '/').start_with?("#{root.tr('\\', '/')}/")
    rescue StandardError
      false
    end

    def customer_ui_runtime_preflight_required_id?(id)
      %w[hover_auto_rehide license_clipboard_paste].include?(id.to_s)
    end

    def customer_ui_durable_runtime_preflight_path?(id, path)
      basename = case id.to_s
                 when 'hover_auto_rehide'
                   'sanebar_runtime_hover_rehide'
                 when 'license_clipboard_paste'
                   'sanebar_runtime_license_paste'
                 else
                   return false
                 end
      expanded = File.expand_path(path.to_s, Dir.pwd)
      normalized = expanded.tr('\\', '/')
      root = File.expand_path(File.join(Dir.pwd, 'outputs', 'runtime-preflight')).tr('\\', '/')
      normalized.start_with?("#{root}/") &&
        File.basename(normalized).match?(/\A#{Regexp.escape(basename)}\.(?:json|log|png)\z/)
    rescue StandardError
      false
    end

    def customer_ui_resource_soak_runtime_receipt_issues(label, receipt_row)
      paths = Array(receipt_row['evidence_paths']).map(&:to_s).map(&:strip).reject(&:empty?)
      issues = []
      temp_paths = paths.select { |path| customer_ui_temp_artifact_path?(path) }
      unless temp_paths.empty?
        issues << "#{label}: resource soak evidence must be durable; temp path(s) are not release proof: #{temp_paths.join(', ')}"
      end

      durable_paths = paths.select { |path| customer_ui_durable_resource_soak_path?(path) }
      if durable_paths.empty?
        issues << "#{label}: missing durable resource-soak evidence under outputs/customer-ui"
      end
      missing_durable_paths = durable_paths.reject { |path| customer_ui_regular_file?(path) }
      unless missing_durable_paths.empty?
        issues << "#{label}: durable resource-soak evidence path(s) do not exist or are unsafe: #{missing_durable_paths.join(', ')}"
      end
      json_paths = durable_paths.select { |path| File.extname(path) == '.json' && customer_ui_regular_file?(path) }
      if json_paths.empty?
        issues << "#{label}: durable resource-soak JSON artifact is missing"
      else
        json_paths.each do |path|
          issues.concat(customer_ui_resource_soak_artifact_issues(label, path, receipt_row: receipt_row, evidence_paths: paths))
        end
      end
      issues
    end

    def customer_ui_temp_artifact_path?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      expanded = File.realpath(expanded) if File.exist?(expanded)
      expanded.start_with?('/tmp/') ||
        expanded.start_with?('/private/tmp/') ||
        expanded.start_with?('/var/folders/')
    rescue StandardError
      false
    end

    def customer_ui_durable_resource_soak_path?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      normalized = expanded.tr('\\', '/')
      normalized.include?('/outputs/customer-ui/') &&
        File.basename(normalized).start_with?('resource-soak-')
    rescue StandardError
      false
    end

    def customer_ui_regular_file?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      safe_customer_ui_directory_path!(File.dirname(expanded))
      stat = File.lstat(expanded)
      stat.file?
    rescue StandardError
      false
    end

    def safe_customer_ui_file_read(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      safe_customer_ui_directory_path!(File.dirname(expanded))
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(expanded, flags) do |file|
        file.read
      end
    end

    def safe_customer_ui_file_lines(path)
      safe_customer_ui_file_read(path).lines(chomp: true)
    end

    def safe_customer_ui_directory_path!(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      current = expanded.start_with?(File::SEPARATOR) ? File::SEPARATOR : Dir.pwd
      expanded.split(File::SEPARATOR).reject(&:empty?).each do |component|
        current = current == File::SEPARATOR ? File.join(current, component) : File.join(current, component)
        next unless File.exist?(current)

        stat = File.lstat(current)
        if stat.symlink?
          real = File.realpath(current) rescue nil
          next if allowed_system_temp_directory_symlink?(current, real)

          raise "Unsafe symlink directory path: #{current}"
        end
        raise "Unsafe non-directory path: #{current}" unless stat.directory?
      end
      true
    end

    def allowed_system_temp_directory_symlink?(path, real)
      expanded = File.expand_path(path)
      canonical = File.expand_path(real.to_s)
      return true if expanded == '/tmp' && canonical == '/private/tmp'
      return true if expanded == '/var' && canonical == '/private/var'

      expanded == File.expand_path(Dir.tmpdir) && canonical == File.realpath(Dir.tmpdir)
    rescue StandardError
      false
    end

    def customer_ui_resource_soak_artifact_issues(label, path, receipt_row: {}, evidence_paths: [])
      payload = JSON.parse(safe_customer_ui_file_read(path))
      issues = []
      issues << "#{label}: resource-soak artifact status is #{payload['status'].inspect}, expected \"pass\"" unless payload['status'].to_s == 'pass'
      issues << "#{label}: resource-soak artifact was not adaptive" unless payload['adaptive'] == true
      unless %w[early_pass full_duration_pass].include?(payload['adaptive_status'].to_s)
        issues << "#{label}: resource-soak artifact adaptive status #{payload['adaptive_status'].inspect} is not accepted"
      end

      sample_count = payload['sample_count'].to_i
      complete_samples = Array(payload['samples']).count do |sample|
        sample.is_a?(Hash) &&
          sample.key?('sampled_at') &&
          customer_ui_numeric_value?(sample['elapsed_seconds'] || sample['elapsed']) &&
          customer_ui_numeric_value?(sample['cpu'] || sample['cpu_percent']) &&
          customer_ui_numeric_value?(sample['rss_mb']) &&
          customer_ui_numeric_value?(sample['physical_footprint_mb'])
      end
      issues << "#{label}: resource-soak artifact has fewer than 2 samples" if sample_count < 2
      issues << "#{label}: resource-soak artifact has #{complete_samples} complete sample(s), expected #{sample_count}" unless complete_samples == sample_count
      unless payload['physical_sample_count'].to_i == sample_count && payload['physical_missing_sample_count'].to_i == 0
        issues << "#{label}: resource-soak artifact physical footprint coverage is incomplete"
      end
      issues.concat(customer_ui_resource_soak_candidate_issues(label, payload, receipt_row))
      issues.concat(customer_ui_resource_soak_log_issues(label, path, payload, evidence_paths))

      begin
        finished_at = Time.parse((payload['finished_at'] || payload['generated_at'] || payload['started_at']).to_s)
        now = Time.now
        if now - finished_at > 12 * 60 * 60 || finished_at > now + 5 * 60
          issues << "#{label}: resource-soak artifact timestamp is stale or future-dated"
        end
      rescue ArgumentError
        issues << "#{label}: resource-soak artifact timestamp is missing or invalid"
      end
      issues
    rescue JSON::ParserError
      ["#{label}: resource-soak artifact JSON is unreadable"]
    rescue StandardError => e
      ["#{label}: resource-soak artifact could not be validated: #{e.class}: #{e.message}"]
    end

    def customer_ui_resource_soak_candidate_issues(label, payload, receipt_row)
      candidate = payload['candidate'].is_a?(Hash) ? payload['candidate'] : {}
      issues = []
      if candidate['app_version'].to_s.empty? || candidate['app_build'].to_s.empty?
        issues << "#{label}: resource-soak artifact candidate version/build is missing"
        return issues
      end

      expected = resource_soak_expected_project_version
      if expected[:app_version] && candidate['app_version'].to_s != expected[:app_version].to_s
        issues << "#{label}: resource-soak artifact candidate version #{candidate['app_version']} does not match project MARKETING_VERSION #{expected[:app_version]}"
      end
      if expected[:app_build] && candidate['app_build'].to_s != expected[:app_build].to_s
        issues << "#{label}: resource-soak artifact candidate build #{candidate['app_build']} does not match project CURRENT_PROJECT_VERSION #{expected[:app_build]}"
      end

      receipt_candidate = receipt_row['runtime_candidate']
      unless receipt_candidate.is_a?(Hash)
        issues << "#{label}: receipt is missing resource-soak runtime_candidate"
        return issues
      end

      %w[app_version app_build app_path].each do |key|
        next if candidate[key].to_s.empty? || receipt_candidate[key].to_s.empty?
        next if candidate[key].to_s == receipt_candidate[key].to_s

        issues << "#{label}: resource-soak artifact candidate #{key} #{candidate[key]} does not match receipt runtime_candidate #{receipt_candidate[key]}"
      end
      issues
    end

    def customer_ui_resource_soak_log_issues(label, json_path, payload, evidence_paths)
      expanded_json_path = File.expand_path(json_path.to_s, Dir.pwd)
      log_path = expanded_json_path.sub(/\.json\z/, '.log')
      issues = []
      expanded_evidence_paths = Array(evidence_paths).map { |path| File.expand_path(path.to_s, Dir.pwd) }
      unless expanded_evidence_paths.include?(log_path)
        issues << "#{label}: durable resource-soak log sibling is missing from evidence_paths: #{customer_ui_relative_path(log_path)}"
      end
      unless customer_ui_regular_file?(log_path)
        issues << "#{label}: durable resource-soak log sibling is missing: #{customer_ui_relative_path(log_path)}"
        return issues
      end

      lines = safe_customer_ui_file_lines(log_path)
      body = lines.join("\n")
      issues << "#{label}: resource-soak log has missing process or physical samples" if lines.any? { |line| line.include?('sample_missing') || line.include?('physical=unknown') }
      issues << "#{label}: resource-soak log did not record pass status" unless body.include?('status=pass')

      log_sample_count = lines.count do |line|
        line.match?(/\bsample=\d+\b/) &&
          line.match?(/\belapsed=\d+(?:\.\d+)?s\b/) &&
          line.match?(/\bcpu=\d+(?:\.\d+)?\b/) &&
          line.match?(/\brss=\d+(?:\.\d+)?MB\b/) &&
          line.match?(/\bphysical=\d+(?:\.\d+)?MB\b/)
      end
      expected_sample_count = payload['sample_count'].to_i
      unless log_sample_count == expected_sample_count
        issues << "#{label}: resource-soak log has #{log_sample_count} complete sample line(s), expected #{expected_sample_count}"
      end

      candidate = payload['candidate'].is_a?(Hash) ? payload['candidate'] : {}
      if candidate['app_version'].to_s != '' &&
         !customer_ui_resource_soak_log_candidate_value?(body, 'app_version', candidate['app_version'])
        issues << "#{label}: resource-soak log candidate version does not match JSON artifact"
      end
      if candidate['app_build'].to_s != '' &&
         !customer_ui_resource_soak_log_candidate_value?(body, 'app_build', candidate['app_build'])
        issues << "#{label}: resource-soak log candidate build does not match JSON artifact"
      end

      begin
        finished_at_text = lines.find { |line| line.start_with?('resource_soak_finished_at=') }.to_s.sub(/\Aresource_soak_finished_at=/, '')
        finished_at = Time.parse(finished_at_text)
        now = Time.now
        if now - finished_at > 12 * 60 * 60 || finished_at > now + 5 * 60
          issues << "#{label}: resource-soak log timestamp is stale or future-dated"
        end
      rescue ArgumentError
        issues << "#{label}: resource-soak log timestamp is missing or invalid"
      end
      issues
    rescue StandardError => e
      ["#{label}: resource-soak log could not be validated: #{e.class}: #{e.message}"]
    end

    def customer_ui_resource_soak_log_candidate_value?(body, key, value)
      escaped_value = Regexp.escape(value.to_s)
      escaped_key = Regexp.escape(key.to_s)
      body.match?(/:?#{escaped_key}\s*=>\s*"#{escaped_value}"/) ||
        body.match?(/#{escaped_key}:\s+"#{escaped_value}"/) ||
        body.match?(/"#{escaped_key}"\s*=>\s*"#{escaped_value}"/)
    end

    def customer_ui_relative_path(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      root = File.expand_path(Dir.pwd)
      expanded.start_with?("#{root}/") ? expanded.sub("#{root}/", '') : expanded
    end

    def customer_ui_numeric_value?(value)
      !value.nil? && Float(value)
    rescue ArgumentError, TypeError
      false
    end

    def customer_ui_runtime_completed_scenarios(receipt_row)
      direct = Array(receipt_row['completed_scenarios']).map(&:to_s)
      scenarios = Array(receipt_row['scenarios']).map do |scenario|
        if scenario.is_a?(Hash)
          status = scenario['status'].to_s.strip
          next nil unless status.empty? || status == 'passed'

          scenario['id'] || scenario['name'] || scenario['scenario']
        else
          scenario
        end
      end
      scenario_results = receipt_row['scenario_results']
      result_names =
        case scenario_results
        when Hash
          scenario_results.each_with_object([]) do |(name, result), names|
            status = result.is_a?(Hash) ? result['status'].to_s.strip : result.to_s.strip
            names << name if status == 'passed' || status == 'true'
          end
        when Array
          scenario_results.each_with_object([]) do |result, names|
            next names unless result.is_a?(Hash)

            status = result['status'].to_s.strip
            next names unless status == 'passed' || status.empty?

            names << (result['id'] || result['name'] || result['scenario'])
          end
        else
          []
        end

      (direct + scenarios + result_names).map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def customer_ui_full_runtime_completion_issues(id, action, result)
      return [] unless action['required_proof_level'].to_s == 'full_runtime_completion'

      evidence = Array(result['evidence']).select { |item| item.is_a?(Hash) }
      runtime_items = evidence.select do |item|
        CUSTOMER_UI_FULL_RUNTIME_ARTIFACT_TYPES.include?(item['type'].to_s.strip)
      end
      artifact_backed = runtime_items.any? { |item| customer_ui_evidence_paths(item).any? }
      return [] if artifact_backed

      ["#{id}: full_runtime_completion requires path-backed runtime/output evidence; source, unit, fixture, or prose-only notes are not enough"]
    end

    def customer_ui_functional_state_receipt_issues(id, action, result)
      issues = []
      state = result['functional_state']
      unless state.is_a?(Hash)
        issues << "#{id}: missing functional_state proof; clicks only count after the required user/app state is established"
        state = {}
      end

      status = state['status'].to_s.strip
      unless %w[established not_required].include?(status)
        issues << "#{id}: functional_state status must be established or not_required"
      end
      issues << "#{id}: functional_state proof missing detail" if state['detail'].to_s.strip.empty?
      if status == 'not_required' && action.dig('functional_state', 'not_required_reason').to_s.strip.empty?
        issues << "#{id}: receipt says functional state is not required but manifest does not declare why"
      end

      if Array(action['user_inputs']).any?
        inputs = Array(result['inputs']).map(&:to_s).map(&:strip).reject(&:empty?)
        inputs.concat(Array(result['declared_inputs']).map(&:to_s).map(&:strip).reject(&:empty?))
        issues << "#{id}: missing exercised user inputs from receipt" if inputs.empty?
      end

      expected_outputs = Array(action['expected_outputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      if expected_outputs.any?
        output_assertions = Array(result['output_assertions']).map(&:to_s).map(&:strip).reject(&:empty?)
        output_assertions.concat(Array(result['covered_assertions']).map(&:to_s).map(&:strip).reject(&:empty?))
        issues << "#{id}: missing output_assertions proving expected outcomes" if output_assertions.empty?
      end

      if %w[fixture_completion full_runtime_completion].include?(action['required_proof_level'].to_s)
        evidence_types = Array(result['evidence']).map do |item|
          item['type'].to_s.strip if item.is_a?(Hash)
        end.compact
        unless evidence_types.any? { |type| %w[fixture actual_output log file_state api_response model_response].include?(type) }
          issues << "#{id}: completion proof requires fixture, actual output, log, file state, API response, or model response evidence"
        end
      end

      issues
    end

    def customer_ui_screenshot_reuse_issues(required_actions, receipt)
      results = receipt['action_results']
      return [] unless results.is_a?(Hash)

      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      paths_by_action = {}
      required_ids.each do |id|
        result = results[id]
        next unless result.is_a?(Hash)

        paths = Array(result['evidence']).flat_map do |item|
          next [] unless item.is_a?(Hash)
          next [] unless CUSTOMER_UI_SCREENSHOT_EVIDENCE_TYPES.include?(item['type'].to_s.strip)

          customer_ui_evidence_paths(item)
        end
        paths_by_action[id] = paths.map { |path| customer_ui_normalized_artifact_path(path) }.reject(&:empty?).uniq
      end

      issues = []
      path_owners = Hash.new { |hash, key| hash[key] = [] }
      paths_by_action.each do |id, paths|
        paths.each { |path| path_owners[path] << id }
      end
      path_owners.each do |path, owners|
        next unless owners.length > 1

        issues << "Screenshot artifact reused across release actions (#{owners.join(', ')}): #{path}"
      end

      hash_owners = Hash.new { |hash, key| hash[key] = [] }
      path_owners.each_key do |path|
        absolute = File.absolute_path(path, Dir.pwd)
        next unless File.file?(absolute)

        hash_owners[Digest::SHA256.file(absolute).hexdigest] << path
      rescue StandardError
        next
      end
      hash_owners.each_value do |paths|
        owner_ids = paths.flat_map { |path| path_owners[path] }.uniq
        next unless paths.length > 1 && owner_ids.length > 1

        issues << "Identical screenshot bytes reused across release actions (#{owner_ids.join(', ')}): #{paths.join(', ')}"
      end

      visual_owners = Hash.new { |hash, key| hash[key] = [] }
      path_owners.each_key do |path|
        absolute = File.absolute_path(path, Dir.pwd)
        signature = customer_ui_png_visual_signature(absolute)
        source = customer_ui_png_text_chunk(absolute, 'SaneSource')
        visual_owners[[signature, source]] << path if signature && source.to_s.strip != ''
      end
      visual_owners.each_value do |paths|
        owner_ids = paths.flat_map { |path| path_owners[path] }.uniq
        next unless owner_ids.any? { |id| id.include?('appearance') || id.include?('startup-wake') }
        next unless paths.length > 1 && owner_ids.length > 1

        issues << "Identical screenshot pixels reused across release actions (#{owner_ids.join(', ')}): #{paths.join(', ')}"
      end

      issues
    end

    def customer_ui_png_visual_signature(path)
      data = File.binread(path)
      return nil unless data.start_with?("\x89PNG\r\n\x1A\n".b)

      offset = 8
      critical_payload = +""
      while offset + 12 <= data.bytesize
        length = data.byteslice(offset, 4).unpack1('N')
        type = data.byteslice(offset + 4, 4)
        chunk_data = data.byteslice(offset + 8, length)
        break unless type && chunk_data && offset + 12 + length <= data.bytesize

        critical_payload << type << chunk_data if %w[IHDR PLTE IDAT tRNS].include?(type)
        offset += 12 + length
        break if type == 'IEND'
      end

      return nil if critical_payload.empty?

      Digest::SHA256.hexdigest(critical_payload)
    rescue StandardError
      nil
    end

    def customer_ui_png_text_chunk(path, keyword)
      data = File.binread(path)
      return nil unless data.start_with?("\x89PNG\r\n\x1A\n".b)

      offset = 8
      marker = "#{keyword}\0"
      while offset + 12 <= data.bytesize
        length = data.byteslice(offset, 4).unpack1('N')
        type = data.byteslice(offset + 4, 4)
        chunk_data = data.byteslice(offset + 8, length)
        break unless type && chunk_data && offset + 12 + length <= data.bytesize
        return chunk_data.byteslice(marker.bytesize..)&.force_encoding('UTF-8') if type == 'tEXt' && chunk_data.start_with?(marker)

        offset += 12 + length
        break if type == 'IEND'
      end

      nil
    rescue StandardError
      nil
    end

    def customer_ui_workflow_receipt_issues(id, action, result)
      proof_level = result['proof_level'].to_s
      return [] unless CUSTOMER_UI_WORKFLOW_PROOF_LEVELS.include?(proof_level)

      workflow = result['workflow']
      unless workflow.is_a?(Hash)
        return ["#{id}: missing structured workflow proof; runtime evidence must name the runner, covered steps, outcome, and artifacts"]
      end

      issues = []
      issues << "#{id}: workflow proof missing runner" if workflow['runner'].to_s.strip.empty?
      issues << "#{id}: workflow proof missing outcome" if workflow['outcome'].to_s.strip.empty?

      covered_steps = Array(workflow['steps_covered']).map(&:to_s).map(&:strip).reject(&:empty?)
      completed_steps = Array(workflow['steps_completed']).map(&:to_s).map(&:strip).reject(&:empty?)
      proof_steps = covered_steps.empty? ? completed_steps : covered_steps
      issues << "#{id}: workflow proof missing steps_covered" if proof_steps.empty?
      declared_steps = Array(action['steps']).map(&:to_s).map(&:strip).reject(&:empty?)
      missing_steps = declared_steps - proof_steps
      unless missing_steps.empty?
        issues << "#{id}: workflow proof did not cover declared step(s): #{missing_steps.join(' | ')}"
      end

      artifacts = Array(workflow['artifacts']).map(&:to_s).map(&:strip).reject(&:empty?)
      issues << "#{id}: workflow proof missing artifacts" if artifacts.empty?
      artifacts.each_with_index do |path, index|
        issues.concat(customer_ui_generic_artifact_issues(
          path,
          label: "#{id}: workflow artifact ##{index + 1}",
          image_required: false
        ))
      end

      issues
    end

    def customer_ui_evidence_artifact_issues(id, item, index)
      evidence_type = item['type'].to_s.strip
      return [] unless CUSTOMER_UI_PATH_BACKED_EVIDENCE_TYPES.include?(evidence_type)

      paths = customer_ui_evidence_paths(item)
      label = "#{id}: evidence ##{index + 1} #{evidence_type}"
      return ["#{label} missing artifact path"] if paths.empty?

      image_required = CUSTOMER_UI_SCREENSHOT_EVIDENCE_TYPES.include?(evidence_type)
      paths.flat_map.with_index do |path, path_index|
        customer_ui_generic_artifact_issues(
          path,
          label: "#{label} artifact ##{path_index + 1}",
          image_required: image_required
        )
      end
    end

    def customer_ui_evidence_paths(item)
      paths = []
      %w[path artifact file].each do |key|
        value = item[key]
        paths.concat(Array(value)) unless value.nil?
      end
      paths.concat(Array(item['artifacts'])) unless item['artifacts'].nil?
      paths.map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def customer_ui_normalized_artifact_path(path)
      File.absolute_path(path.to_s.strip, Dir.pwd)
    rescue StandardError
      path.to_s.strip
    end

    def customer_ui_generic_artifact_issues(path, label:, image_required:)
      return ["#{label}: blank path"] if path.to_s.strip.empty?

      absolute = File.absolute_path(path, Dir.pwd)
      return ["#{label}: file does not exist: #{path}"] unless File.file?(absolute)

      return customer_ui_single_screenshot_issues(path, 0).map { |issue| issue.sub('screenshot #1', label) } if image_required

      []
    end

    def required_evidence_types(action)
      Array(action['required_evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def customer_ui_action_requires_visual?(action, result)
      return true if action['requires_visual'] == true || action['requires_visual_evidence'] == true

      required_evidence_types(action).any? { |type| %w[screenshot visual_screenshot mini_screenshot visual_smoke].include?(type) } ||
        Array(action['evidence']).any? { |item| item.to_s.downcase.include?('screenshot') } ||
        %w[runtime_visual full_runtime_completion].include?(result['proof_level'].to_s)
    end

    def customer_ui_proof_satisfies?(actual, required)
      return false unless CUSTOMER_UI_PROOF_LEVELS.include?(actual)
      return false unless CUSTOMER_UI_PROOF_LEVELS.include?(required)

      case required
      when 'source_guard'
        true
      when 'unit_guard'
        %w[unit_guard fixture_completion safe_first_surface runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'fixture_completion'
        %w[fixture_completion full_runtime_completion manual_verification].include?(actual)
      when 'safe_first_surface'
        %w[safe_first_surface runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'runtime_visual'
        %w[runtime_visual full_runtime_completion manual_verification].include?(actual)
      when 'full_runtime_completion'
        %w[full_runtime_completion manual_verification].include?(actual)
      when 'manual_verification'
        actual == 'manual_verification'
      else
        false
      end
    end

    def customer_ui_screenshot_issues(screenshots)
      screenshots.flat_map.with_index do |path, index|
        customer_ui_single_screenshot_issues(path.to_s, index)
      end
    end

    def customer_ui_single_screenshot_issues(path, index)
      label = "screenshot ##{index + 1}"
      return ["#{label}: blank path"] if path.strip.empty?

      absolute = File.absolute_path(path, Dir.pwd)
      return ["#{label}: file does not exist: #{path}"] unless File.file?(absolute)

      extension = File.extname(absolute).downcase
      unless CUSTOMER_UI_IMAGE_EXTENSIONS.include?(extension)
        return ["#{label}: unsupported artifact type #{extension.inspect}; expected PNG or JPEG screenshot"]
      end

      width, height = customer_ui_image_dimensions(absolute)
      return ["#{label}: could not read image dimensions"] unless width && height
      minimum_height = File.basename(absolute).start_with?('sanebar-appearance-', 'appearance-', 'startup-wake-appearance') ? 20 : CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT
      if width < CUSTOMER_UI_MIN_SCREENSHOT_WIDTH || height < minimum_height
        return ["#{label}: image is #{width}x#{height}, below #{CUSTOMER_UI_MIN_SCREENSHOT_WIDTH}x#{minimum_height}; placeholder screenshots are not release evidence"]
      end

      []
    end

    def customer_ui_image_dimensions(path)
      data = File.binread(path, 32)
      if data.start_with?("\x89PNG\r\n\x1A\n".b) && data.bytesize >= 24
        return data.byteslice(16, 8).unpack('NN')
      end

      output, status = Open3.capture2e('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path)
      return nil unless status.success?

      width = output[/pixelWidth:\s*(\d+)/, 1]&.to_i
      height = output[/pixelHeight:\s*(\d+)/, 1]&.to_i
      return nil unless width&.positive? && height&.positive?

      [width, height]
    rescue StandardError
      nil
    end

    def customer_ui_receipt_source_fingerprint_current?(receipt, source_fingerprint)
      receipt_fingerprint = receipt['source_fingerprint'].to_s
      return true if receipt_fingerprint == source_fingerprint
      return false unless receipt_fingerprint.match?(/\A[0-9a-f]{64}\z/)

      legacy_fingerprint = customer_ui_source_fingerprint(include_tests: true)
      return true if receipt_fingerprint == legacy_fingerprint
      legacy_harness_fingerprint = customer_ui_source_fingerprint(include_release_harness: true)
      return true if receipt_fingerprint == legacy_harness_fingerprint
      customer_ui_visual_sources_unchanged_since_receipt?(receipt)
    end

    def customer_ui_source_fingerprint(include_tests: false, include_release_harness: false)
      digest = Digest::SHA256.new
      customer_ui_source_entries(include_tests: include_tests, include_release_harness: include_release_harness).each do |entry|
        absolute_path = entry.fetch(:absolute_path)
        next unless File.file?(absolute_path)

        digest.update(entry.fetch(:digest_path))
        digest.update("\0")
        digest.update(Digest::SHA256.hexdigest(customer_ui_source_digest_content(entry)))
        digest.update("\0")
      end
      digest.hexdigest
    end

    def customer_ui_source_entries(include_tests: false, include_release_harness: false)
      app_entries = customer_ui_source_files(include_tests: include_tests, include_release_harness: include_release_harness).map do |relative_path|
        {
          scope: :app,
          relative_path: relative_path,
          digest_path: "app/#{relative_path}",
          absolute_path: File.join(Dir.pwd, relative_path)
        }
      end
      shared_entries = customer_ui_shared_source_files(include_release_harness: include_release_harness).map do |relative_path|
        {
          scope: :shared,
          relative_path: relative_path,
          digest_path: "SaneApps/#{relative_path}",
          absolute_path: File.join(customer_ui_saneapps_root, relative_path)
        }
      end
      app_entries + shared_entries
    end

    def customer_ui_source_files(include_tests: false, include_release_harness: false)
      files = git_list_customer_ui_files
      files = filesystem_customer_ui_files if files.empty?
      files.select { |path| customer_ui_source_file?(path, include_tests: include_tests, include_release_harness: include_release_harness) }.uniq.sort
    end

    def git_list_customer_ui_files
      tracked, tracked_status = Open3.capture2e('git', 'ls-files', '-z')
      others, others_status = Open3.capture2e('git', 'ls-files', '--others', '--exclude-standard', '-z')
      files = []
      files.concat(tracked.split("\0")) if tracked_status.success?
      files.concat(others.split("\0")) if others_status.success?
      files
    rescue StandardError
      []
    end

    def filesystem_customer_ui_files
      Dir.glob('**/*', File::FNM_DOTMATCH).reject do |path|
        path.start_with?('.git/') || path.start_with?('outputs/') || File.directory?(path)
      end
    end

    def customer_ui_source_file?(path, include_tests: false, include_release_harness: false)
      return false if CUSTOMER_UI_RECEIPT_PATHS.include?(path)
      return false if path.start_with?('.sanemaster/')
      return false if path.start_with?('node_modules/')
      return false if path == '.mcp.json' || path.start_with?('.claude/') || path.start_with?('.codex/') || path.start_with?('.serena/')
      return false if path == '.outreach.yml' || path == '.outreach.yaml'
      return false if path == 'Scripts/check_outreach_opportunities.rb' || path == 'scripts/check_outreach_opportunities.rb'
      return false if path == 'Scripts/sign_update.swift' || path == 'scripts/sign_update.swift'
      return true if CUSTOMER_UI_MANIFEST_PATHS.include?(path)
      return include_tests if path.start_with?('Tests/')
      return include_tests if path.match?(%r{\A(?:scripts|Scripts)/.*(?:_test|Test)\.(?:rb|py|sh)\z})
      return false if path == '.saneprocess' || path == 'project.yml' || path == 'Package.swift' || path == 'Package.resolved'
      return false if path.end_with?('.xcodeproj/project.pbxproj')
      return true if path.start_with?('Sane') || path.start_with?('Shared/')
      return true if path.start_with?('Sources/')
      return false if path.start_with?('scripts/', 'Scripts/')

      CUSTOMER_UI_SOURCE_EXTENSIONS.include?(File.extname(path)) &&
        !path.start_with?('docs/') &&
        !path.start_with?('website/') &&
        !path.start_with?('outputs/')
    end

    def customer_ui_shared_source_files(include_release_harness: false)
      root = customer_ui_saneapps_root
      patterns = [
        'infra/SaneUI/Sources/**/*.{swift,xcstrings}'
      ]
      if include_release_harness
        patterns.concat(
          [
            'infra/SaneProcess/scripts/SaneMaster.rb',
            'infra/SaneProcess/scripts/release.sh',
            'infra/SaneProcess/scripts/sanemaster/test_mode.rb',
            'infra/SaneProcess/scripts/sanemaster/visual_smoke.rb',
            'infra/SaneProcess/scripts/sanemaster/customer_ui_contract.rb',
            'infra/SaneProcess/scripts/sanemaster/release.rb',
            'infra/SaneProcess/scripts/sanemaster/release_readiness.rb',
            'infra/SaneProcess/scripts/sanemaster/release_guardrail_test.rb',
            'infra/SaneProcess/scripts/hooks/**/*.{rb,sh}'
          ]
        )
      end
      patterns.flat_map { |pattern| Dir.glob(File.join(root, pattern)) }
              .select { |path| File.file?(path) }
              .map { |path| path.sub(%r{\A#{Regexp.escape(root)}/?}, '') }
              .uniq
              .sort
    rescue StandardError
      []
    end

    def customer_ui_source_digest_content(entry)
      content = File.read(entry.fetch(:absolute_path), encoding: Encoding::UTF_8, invalid: :replace, undef: :replace)
      customer_ui_normalize_visual_source_content(entry.fetch(:relative_path).to_s, content)
    rescue StandardError
      File.binread(entry.fetch(:absolute_path))
    end

    def customer_ui_normalize_visual_source_content(relative_path, content)
      return content unless customer_ui_version_metadata_path?(relative_path)

      content
        .lines
        .reject { |line| line.match?(/\b(?:CURRENT_PROJECT_VERSION|MARKETING_VERSION)\b\s*(?:=|:)/) }
        .join
    end

    def customer_ui_version_metadata_path?(relative_path)
      relative_path == 'project.yml' ||
        relative_path.end_with?('.xcodeproj/project.pbxproj') ||
        relative_path.end_with?('.xcconfig')
    end

    def customer_ui_visual_sources_unchanged_since_receipt?(receipt)
      generated_at = Time.parse(receipt['generated_at'].to_s)
      customer_ui_stale_visual_source_entries_since(generated_at).empty?
    rescue ArgumentError, TypeError
      false
    end

    def customer_ui_stale_visual_source_entries_since(generated_at)
      customer_ui_source_entries.select do |entry|
        absolute_path = entry.fetch(:absolute_path)
        next false unless File.file?(absolute_path)
        next false unless File.mtime(absolute_path) > generated_at
        next false if customer_ui_app_source_matches_receipt_baseline?(entry, generated_at)

        true
      end
    end

    def customer_ui_app_source_matches_receipt_baseline?(entry, generated_at)
      return false unless entry.fetch(:scope) == :app

      relative_path = entry.fetch(:relative_path).to_s
      baseline = customer_ui_git_file_before_time(relative_path, generated_at)
      return false if baseline.nil?

      current = customer_ui_source_digest_content(entry)
      customer_ui_normalize_visual_source_content(relative_path, baseline) == current
    end

    def customer_ui_git_file_before_time(relative_path, generated_at)
      commit, status = Open3.capture2e(
        'git',
        'rev-list',
        '-1',
        "--before=#{generated_at.utc.iso8601}",
        'HEAD',
        '--',
        relative_path
      )
      return nil unless status.success?

      commit = commit.to_s.strip
      return nil if commit.empty?

      content, show_status = Open3.capture2e('git', 'show', "#{commit}:#{relative_path}")
      return nil unless show_status.success?

      content
    rescue StandardError
      nil
    end

    def customer_ui_saneapps_root
      if respond_to?(:saneapps_root, true)
        saneapps_root
      else
        File.expand_path('../..', saneprocess_repo_root)
      end
    end
  end
end
