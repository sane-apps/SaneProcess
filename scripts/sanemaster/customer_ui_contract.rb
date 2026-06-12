# frozen_string_literal: true

require 'digest'
require 'date'
require 'fileutils'
require 'json'
require 'open3'
require 'socket'
require 'time'
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
      'outputs/customer_ui_action_receipt.json',
      '.sane/customer_ui_action_receipt.json'
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
    CUSTOMER_UI_MIN_SCREENSHOT_WIDTH = 80
    CUSTOMER_UI_MIN_SCREENSHOT_HEIGHT = 80
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
      fullscreen_maximize_transition
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
      json = args.include?('--json')
      dry_run = args.include?('--dry-run')
      report = customer_ui_sweep_report(dry_run: dry_run)
      if json
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_sweep_report(report)
      end
      exit 1 unless report[:ok] || args.include?('--no-exit')
      report
    end

    def resource_soak(args = [])
      report = resource_soak_report(args)
      if report[:json]
        puts JSON.pretty_generate(report.reject { |key, _| key == :json })
      elsif report[:ok]
        puts format(
          '✅ Resource soak passed: duration=%<duration>.0fs samples=%<samples>d avgCpu=%<cpu>.1f%% peakRss=%<rss>.1fMB peakPhysical=%<physical>.1fMB',
          duration: report[:duration_seconds],
          samples: report[:sample_count],
          cpu: report[:avg_cpu],
          rss: report[:peak_rss_mb],
          physical: report[:peak_physical_footprint_mb]
        )
        puts "   Artifact: #{report[:artifact_path]}"
        puts "   Log: #{report[:log_path]}"
      else
        puts '❌ Resource soak failed'
        Array(report[:issues]).each { |issue| puts "   - #{issue}" }
        puts "   Artifact: #{report[:artifact_path]}" if report[:artifact_path]
        puts "   Log: #{report[:log_path]}" if report[:log_path]
      end
      exit 1 unless report[:ok] || report[:no_exit]
      report
    end

    def resource_soak_report(args = [])
      options = parse_resource_soak_args(args)
      return resource_soak_dry_run_report(options) if options[:dry_run]

      candidate = resource_soak_running_app_candidate(options[:app_name])
      unless candidate
        return {
          ok: false,
          json: options[:json],
          no_exit: options[:no_exit],
          issues: ["#{options[:app_name]} is not running from /Applications; launch with ./scripts/SaneMaster.rb test_mode --release --no-logs"]
        }
      end

      FileUtils.mkdir_p(File.dirname(options[:artifact_path]))
      log_lines = []
      started_at = Time.now.utc
      deadline = Time.now + options[:duration_seconds]
      samples = []

      log_lines << "resource_soak_started_at=#{started_at.iso8601}"
      log_lines << "candidate=#{candidate.inspect}"
      log_lines << "duration_seconds=#{options[:duration_seconds]}"
      log_lines << "interval_seconds=#{options[:interval_seconds]}"

      loop do
        sample = resource_soak_sample(candidate[:pid])
        if sample
          samples << sample
          log_lines << format(
            'sample=%<index>d elapsed=%<elapsed>.1fs cpu=%<cpu>.1f rss=%<rss>.1fMB physical=%<physical>s',
            index: samples.length,
            elapsed: Time.now - started_at,
            cpu: sample[:cpu],
            rss: sample[:rss_mb],
            physical: sample[:physical_footprint_mb] ? format('%.1fMB', sample[:physical_footprint_mb]) : 'unknown'
          )
        else
          log_lines << format('sample_missing elapsed=%.1fs pid=%d', Time.now - started_at, candidate[:pid])
        end

        break if Time.now >= deadline

        sleep [options[:interval_seconds], deadline - Time.now].min
      end

      finished_at = Time.now.utc
      metrics = resource_soak_metrics(samples)
      issues = resource_soak_issues(metrics, options)
      status = issues.empty? ? 'pass' : 'fail'
      scenarios = [
        'at least 20m Mini soak sampled on the release candidate',
        'average CPU remains within idle budget',
        'RSS and physical footprint do not grow beyond the short-soak release budget'
      ]

      log_lines << "resource_soak_finished_at=#{finished_at.iso8601}"
      log_lines << "status=#{status}"
      log_lines.concat(issues.map { |issue| "issue=#{issue}" })
      File.write(options[:log_path], log_lines.join("\n") + "\n")

      artifact = {
        status: status,
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        duration_seconds: finished_at - started_at,
        sample_count: metrics[:sample_count],
        interval_seconds: options[:interval_seconds],
        avg_cpu: metrics[:avg_cpu],
        peak_cpu: metrics[:peak_cpu],
        avg_rss_mb: metrics[:avg_rss_mb],
        peak_rss_mb: metrics[:peak_rss_mb],
        rss_growth_mb: metrics[:rss_growth_mb],
        avg_physical_footprint_mb: metrics[:avg_physical_footprint_mb],
        peak_physical_footprint_mb: metrics[:peak_physical_footprint_mb],
        physical_footprint_growth_mb: metrics[:physical_footprint_growth_mb],
        budgets: resource_soak_budget_payload(options),
        evidence_types: %w[mini_runtime log state_receipt],
        evidence_paths: [options[:log_path]],
        completed_scenarios: status == 'pass' ? scenarios : [],
        candidate: candidate.reject { |key, _| key == :pid },
        issues: issues
      }
      File.write(options[:artifact_path], JSON.pretty_generate(artifact) + "\n")

      {
        ok: issues.empty?,
        json: options[:json],
        no_exit: options[:no_exit],
        artifact_path: options[:artifact_path],
        log_path: options[:log_path],
        duration_seconds: artifact[:duration_seconds],
        sample_count: metrics[:sample_count],
        avg_cpu: metrics[:avg_cpu],
        peak_cpu: metrics[:peak_cpu],
        peak_rss_mb: metrics[:peak_rss_mb],
        peak_physical_footprint_mb: metrics[:peak_physical_footprint_mb],
        issues: issues
      }
    end

    def customer_ui_sweep_report(dry_run: false)
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

      if dry_run
        return {
          ok: true,
          app: app_name,
          script_path: script_path,
          dry_run: true,
          issues: []
        }
      end

      prepare_issues = customer_ui_prepare_target_before_sweep(app_name)
      return { ok: false, app: app_name, script_path: script_path, issues: prepare_issues } unless prepare_issues.empty?

      cleanup_issues = customer_ui_cleanup_before_sweep(app_name)
      return { ok: false, app: app_name, script_path: script_path, issues: cleanup_issues } unless cleanup_issues.empty?

      visual_precheck = customer_ui_visual_precheck(app_name)
      return { ok: false, app: app_name, script_path: script_path, issues: visual_precheck[:issues] } unless visual_precheck[:ok]

      output, status = customer_ui_run_command('ruby', script_path)
      return { ok: false, app: app_name, script_path: script_path, issues: ["Customer UI workflow runner failed: #{output}"] } unless status.success?

      contract = customer_ui_contract_report(config: config)
      {
        ok: contract[:ok],
        app: app_name,
        script_path: script_path,
        contract: contract,
        runner_output: output,
        issues: Array(contract[:issues])
      }
    end

    def customer_ui_contract_report(config:, strict_visual: false)
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      receipt_path = CUSTOMER_UI_RECEIPT_PATHS.find { |path| File.exist?(path) }
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
      required_actions = actions.reject { |action| action['release_required'] == false }

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
      lines.join("\n")
    end

    def format_customer_ui_sweep_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI WORKFLOW SWEEP ] ---'
      lines << "App: #{report[:app]}"
      lines << "Runner: #{report[:script_path] || 'missing'}"
      if report[:dry_run]
        lines << '✅ Dry run: runner found'
      elsif report[:ok]
        lines << '✅ Workflow sweep and contract passed'
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      lines.join("\n")
    end

    private

    def customer_ui_allowed_host?
      customer_ui_mini_host? || customer_ui_air_fallback_approved?
    end

    def customer_ui_mini_host?
      Socket.gethostname.downcase.include?('mini') || ENV.fetch('USER', '').downcase == 'stephansmac'
    end

    def customer_ui_air_fallback_approved?
      ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] == 'MR. SANE APPROVES LOCAL UI ON AIR'
    end

    def customer_ui_receipt_host_allowed?(host)
      normalized = host.to_s.downcase
      return true if normalized == 'mini' || normalized.include?('mini')
      return true if normalized == 'stephansmac'
      return false unless customer_ui_air_fallback_approved?

      normalized == Socket.gethostname.to_s.downcase ||
        normalized == 'macbook-air' ||
        normalized == 'air' ||
        normalized.include?('macbook')
    end

    def parse_resource_soak_args(args)
      options = {
        app_name: metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd),
        duration_seconds: Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_SECONDS', (20 * 60).to_s), 10),
        min_duration_seconds: Integer(ENV.fetch('SANEMASTER_RESOURCE_SOAK_MIN_SECONDS', (20 * 60).to_s), 10),
        interval_seconds: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_INTERVAL_SECONDS', '10')),
        cpu_avg_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_CPU_AVG_MAX', '5.0')),
        rss_peak_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_RSS_PEAK_MB_MAX', '256.0')),
        rss_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_RSS_GROWTH_MB_MAX', '64.0')),
        physical_peak_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_PEAK_MB_MAX', '192.0')),
        physical_growth_mb_max: Float(ENV.fetch('SANEMASTER_RESOURCE_SOAK_PHYSICAL_GROWTH_MB_MAX', '64.0')),
        artifact_path: '/tmp/sanebar_runtime_resource_soak.json',
        log_path: '/tmp/sanebar_runtime_resource_soak.log',
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
      options[:interval_seconds] = 1.0 if options[:interval_seconds] < 1.0
      options
    end

    def resource_soak_dry_run_report(options)
      {
        ok: true,
        json: options[:json],
        no_exit: options[:no_exit],
        dry_run: true,
        app: options[:app_name],
        duration_seconds: options[:duration_seconds],
        interval_seconds: options[:interval_seconds],
        artifact_path: options[:artifact_path],
        log_path: options[:log_path],
        issues: []
      }
    end

    def resource_soak_running_app_candidate(app_name)
      app_path = "/Applications/#{app_name}.app"
      executable = File.join(app_path, 'Contents', 'MacOS', app_name)
      return nil unless File.executable?(executable)

      pids_output, = Open3.capture2('pgrep', '-x', app_name)
      pids_output.lines.map(&:strip).reject(&:empty?).each do |pid_text|
        pid = pid_text.to_i
        command_line, = Open3.capture2('ps', '-o', 'command=', '-p', pid.to_s)
        process_path = command_line.strip.split(/\s+/, 2).first
        next unless File.expand_path(process_path.to_s) == executable

        return {
          pid: pid,
          app_path: app_path,
          app_version: resource_soak_plist_value(app_path, 'CFBundleShortVersionString'),
          app_build: resource_soak_plist_value(app_path, 'CFBundleVersion'),
          process_path: executable
        }
      end
      nil
    end

    def resource_soak_plist_value(app_path, key)
      value, status = Open3.capture2('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(app_path, 'Contents', 'Info.plist'))
      status.success? ? value.strip : nil
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

    def resource_soak_metrics(samples)
      return resource_soak_empty_metrics if samples.empty?

      rss_values = samples.map { |sample| sample[:rss_mb].to_f }
      cpu_values = samples.map { |sample| sample[:cpu].to_f }
      physical_values = samples.map { |sample| sample[:physical_footprint_mb] }.compact.map(&:to_f)
      {
        sample_count: samples.length,
        avg_cpu: resource_soak_round(cpu_values.sum / cpu_values.length),
        peak_cpu: resource_soak_round(cpu_values.max),
        avg_rss_mb: resource_soak_round(rss_values.sum / rss_values.length),
        peak_rss_mb: resource_soak_round(rss_values.max),
        rss_growth_mb: resource_soak_round(rss_values.last - rss_values.first),
        avg_physical_footprint_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.sum / physical_values.length),
        peak_physical_footprint_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.max),
        physical_footprint_growth_mb: physical_values.empty? ? nil : resource_soak_round(physical_values.last - physical_values.first)
      }
    end

    def resource_soak_empty_metrics
      {
        sample_count: 0,
        avg_cpu: 0.0,
        peak_cpu: 0.0,
        avg_rss_mb: 0.0,
        peak_rss_mb: 0.0,
        rss_growth_mb: 0.0,
        avg_physical_footprint_mb: nil,
        peak_physical_footprint_mb: nil,
        physical_footprint_growth_mb: nil
      }
    end

    def resource_soak_issues(metrics, options)
      issues = []
      if options[:duration_seconds] < options[:min_duration_seconds]
        issues << "duration #{options[:duration_seconds]}s is shorter than required #{options[:min_duration_seconds]}s"
      end
      issues << 'no process samples collected' if metrics[:sample_count].to_i <= 0
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
        min_duration_seconds: options[:min_duration_seconds],
        cpu_avg_max: options[:cpu_avg_max],
        rss_peak_mb_max: options[:rss_peak_mb_max],
        rss_growth_mb_max: options[:rss_growth_mb_max],
        physical_peak_mb_max: options[:physical_peak_mb_max],
        physical_growth_mb_max: options[:physical_growth_mb_max]
      }
    end

    def resource_soak_round(value)
      value.nil? ? nil : value.round(3)
    end

    def customer_ui_required_arg(args, index, flag)
      value = args[index + 1]
      raise ArgumentError, "missing value for #{flag}" if value.nil? || value.start_with?('--')

      value
    end

    def customer_ui_run_command(*command)
      Open3.capture2e(*command)
    end

    def customer_ui_prepare_target_before_sweep(app_name)
      return [] unless customer_ui_visual_precheck_required?
      return [] if app_name == 'SaneBar'

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
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    def read_customer_ui_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [Time, Date], aliases: false) || {}
    end

    def read_customer_ui_json(path)
      JSON.parse(File.read(path))
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
      issues << 'Receipt source fingerprint is stale; rerun customer UI QA after the latest code change' unless receipt['source_fingerprint'].to_s == source_fingerprint
      issues << 'Receipt is missing screenshot evidence' if Array(receipt['screenshots']).empty?
      issues.concat(customer_ui_screenshot_issues(Array(receipt['screenshots'])))

      tested_ids = Array(receipt['tested_action_ids']).map(&:to_s)
      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      missing_ids = required_ids - tested_ids
      issues << "Receipt does not cover release-required action(s): #{missing_ids.join(', ')}" unless missing_ids.empty?
      issues.concat(customer_ui_action_result_issues(required_actions, receipt, strict_visual: strict_visual))
      issues.concat(customer_ui_runtime_state_receipt_issues(receipt, manifest: manifest))
      issues.concat(customer_ui_screenshot_reuse_issues(required_actions, receipt))

      begin
        generated_at = Time.parse(receipt['generated_at'].to_s)
        issues << 'Receipt is older than 12 hours; rerun customer UI QA for this release' if Time.now - generated_at > 12 * 60 * 60
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

        issues << "#{id}: status is #{result['status'].inspect}, expected \"passed\"" unless result['status'].to_s == 'passed'
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
        result['workflow'],
        result['evidence']
      ].map { |value| value.is_a?(String) ? value : JSON.generate(value) }.join("\n")
      blocking = CUSTOMER_UI_BLOCKING_STATUS_TEXT.select { |label| text.include?(label) }
      return [] if blocking.empty?

      ["#{id}: customer UI evidence contains blocking status text: #{blocking.uniq.join(', ')}"]
    end

    def customer_ui_runtime_state_receipt_issues(receipt, manifest: {})
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

        issues.concat(customer_ui_runtime_state_row_receipt_issues(id, matrix_row, row))
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

    def customer_ui_runtime_state_row_receipt_issues(id, matrix_row, receipt_row)
      label = id.empty? ? 'runtime_state_results row' : "runtime_state_results #{id}"
      issues = []

      required_types = Array(matrix_row['required_evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
      evidence_types = Array(receipt_row['evidence_types']).map(&:to_s).map(&:strip).reject(&:empty?)
      missing_types = required_types - evidence_types
      unless missing_types.empty?
        issues << "#{label}: missing required evidence type(s): #{missing_types.join(', ')}"
      end

      required_scenarios = Array(matrix_row['required_scenarios']).map(&:to_s).map(&:strip).reject(&:empty?)
      return issues if required_scenarios.empty?

      completed_scenarios = customer_ui_runtime_completed_scenarios(receipt_row)
      missing_scenarios = required_scenarios - completed_scenarios
      unless missing_scenarios.empty?
        issues << "#{label}: missing required scenario proof(s): #{missing_scenarios.join(', ')}"
      end
      issues
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
        issues << "#{id}: missing exercised user inputs from receipt" if inputs.empty?
      end

      expected_outputs = Array(action['expected_outputs']).map(&:to_s).map(&:strip).reject(&:empty?)
      if expected_outputs.any?
        output_assertions = Array(result['output_assertions']).map(&:to_s).map(&:strip).reject(&:empty?)
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
        return ["#{id}: missing structured workflow proof; runtime evidence must name the runner, completed steps, outcome, and artifacts"]
      end

      issues = []
      issues << "#{id}: workflow proof missing runner" if workflow['runner'].to_s.strip.empty?
      issues << "#{id}: workflow proof missing outcome" if workflow['outcome'].to_s.strip.empty?

      completed_steps = Array(workflow['steps_completed']).map(&:to_s).map(&:strip).reject(&:empty?)
      issues << "#{id}: workflow proof missing steps_completed" if completed_steps.empty?
      declared_steps = Array(action['steps']).map(&:to_s).map(&:strip).reject(&:empty?)
      missing_steps = declared_steps - completed_steps
      unless missing_steps.empty?
        issues << "#{id}: workflow proof did not complete declared step(s): #{missing_steps.join(' | ')}"
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

    def customer_ui_source_fingerprint
      digest = Digest::SHA256.new
      customer_ui_source_files.each do |path|
        next unless File.file?(path)

        digest.update(path)
        digest.update("\0")
        digest.update(Digest::SHA256.file(path).hexdigest)
        digest.update("\0")
      end
      digest.hexdigest
    end

    def customer_ui_source_files
      files = git_list_customer_ui_files
      files = filesystem_customer_ui_files if files.empty?
      files.select { |path| customer_ui_source_file?(path) }.uniq.sort
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

    def customer_ui_source_file?(path)
      return false if CUSTOMER_UI_RECEIPT_PATHS.include?(path)
      return false if path.start_with?('.sanemaster/')
      return false if path.start_with?('node_modules/')
      return false if path == '.mcp.json' || path.start_with?('.claude/') || path.start_with?('.codex/') || path.start_with?('.serena/')
      return true if CUSTOMER_UI_MANIFEST_PATHS.include?(path)
      return true if path == '.saneprocess' || path == 'project.yml' || path == 'Package.swift'
      return true if path.end_with?('.xcodeproj/project.pbxproj')
      return true if path.start_with?('Sane') || path.start_with?('Shared/')
      return true if path.start_with?('Sources/') || path.start_with?('Tests/')
      return true if path == 'scripts/qa.rb' || path == 'Scripts/qa.rb'
      return true if path.start_with?('scripts/customer_ui_qa') || path.start_with?('Scripts/customer_ui_qa')

      CUSTOMER_UI_SOURCE_EXTENSIONS.include?(File.extname(path)) &&
        !path.start_with?('docs/') &&
        !path.start_with?('website/') &&
        !path.start_with?('outputs/')
    end
  end
end
