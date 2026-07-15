# frozen_string_literal: true

require 'json'
require 'open3'
require 'socket'
require 'time'
require 'tmpdir'

require_relative 'verify_support'
require_relative 'verify_permissions'
require_relative 'verify_doctor'

module SaneMasterModules
  # Build, test execution, permissions, test validation.
  # Execution/support helpers live in verify_support.rb; permission-monitoring
  # helpers live in verify_permissions.rb; doctor environment checks live in
  # verify_doctor.rb (Rule #10 split).
  module Verify
    def doctor
      puts '🏥 --- [ SANEMASTER DOCTOR ] ---'

      check_disk_space
      check_test_assets
      check_xcodegen_sync
      check_permissions
      check_mockolo
      check_xcode
      check_code_quality_tools
      check_stuck_processes
      check_derived_data

      puts "\n✅ Doctor check complete."

      # Suggest recording patterns if recent fixes detected
      suggest_memory_record if respond_to?(:suggest_memory_record)
    end

    # Headless / cron / empty-locale shells leave Ruby's default_external at
    # US-ASCII, so a mid-suite File.read of a non-ASCII source (e.g. release.rb)
    # throws "invalid byte sequence in US-ASCII" and fails the suite for reasons
    # unrelated to the code under test. Force a UTF-8 locale for this process AND
    # the child test processes it spawns (they inherit ENV), so verify is robust
    # regardless of the caller's environment.
    def ensure_utf8_locale!
      utf8 = 'en_US.UTF-8'
      ascii = ->(value) { value.to_s.strip.empty? || value.to_s.strip.match?(/\A(?:C|POSIX)\z/i) }
      ENV['LANG'] = utf8 if ascii.call(ENV['LANG'])
      ENV['LC_ALL'] = utf8 if ascii.call(ENV['LC_ALL'])
      ENV['LC_CTYPE'] = utf8 if ascii.call(ENV['LC_CTYPE'])
      if Encoding.default_external == Encoding::US_ASCII
        Encoding.default_external = Encoding::UTF_8
        Encoding.default_internal = Encoding::UTF_8
      end
    rescue StandardError
      nil
    end

    def verify(args)
      ensure_utf8_locale!
      default_timeout = config_value(%w[tests verify_timeout_seconds], 'SANEMASTER_VERIFY_TIMEOUT', 300).to_i
      begin
        options = parse_verify_args(args, default_timeout: default_timeout)
      rescue ArgumentError => e
        puts "❌ Invalid verify arguments: #{e.message}"
        puts '   Usage: verify [--ui|--ui-only] [--clean] [--no-grant-permissions] [--signed-tests] [--skip-test-validation] [--quiet] [--timeout positive_seconds]'
        exit 2
      end
      running_from_preflight = verify_running_as_preflight?
      return unless running_from_preflight || ensure_research_gate_clear!('verify')

      assert_no_runtime_probe_lock_for_verify!

      if test_targets_disabled?
        handle_disabled_tests(options)
        return
      end

      clean_first = options[:clean]
      ui_only = options[:ui_only]
      include_ui = options[:include_ui]
      timeout = options[:timeout]
      signed_tests = options[:signed_tests] || ENV['SANEMASTER_SIGN_TEST_BUILDS'] == '1'

      run_verify_preflight
      enforce_saneui_source_of_truth!
      clean([]) if clean_first
      ensure_sanevideo_test_assets!
      repo_status_before = git_status_snapshot

      puts '🔨 --- [ SANEMASTER VERIFY ] ---'
      puts 'Building and running tests with progress monitoring...'
      auto_permissions = !options[:no_grant_permissions] && ENV['SANEMASTER_GRANT_PERMISSIONS'] != '0'
      permissions_status = auto_permissions ? '✅ monitor active' : 'off (--no-grant-permissions)'
      puts "⏱️  Timeout: #{timeout}s | Auto-handling permissions: #{permissions_status}"
      if ui_only
        puts '📱 UI tests only (diagnostic lane)'
      else
        puts include_ui ? '📱 Including UI tests (use --ui flag)' : '⚡ Unit tests only (use --ui to include UI tests)'
      end
      if include_ui
        puts '🔐 Unit tests run headless; the UI runner uses normal code signing in a separate session'
      else
        puts signed_tests ? '🔐 Test builds will use normal code signing' : '🧪 Headless mode: test builds run without code signing'
      end
      puts ''

      permission_monitor = auto_permissions ? grant_test_permissions(timeout_seconds: timeout) : nil
      terminate_running_app_instance
      validate_test_references unless options[:skip_test_validation]

      begin
        test_start_time = Time.now
        result = run_tests_with_progress(
          timeout_seconds: timeout,
          include_ui: include_ui,
          signed_tests: signed_tests,
          ui_only: ui_only
        )
        zero_test_success = result[:success] && result[:tests_run].to_i.zero?

        if result[:success] && !zero_test_success
          evidence_strength = verify_evidence_strength(result[:tests_run])
          enforce_no_unresolved_permission_prompt!(permission_monitor)
          verify_repo_cleanliness!(before_snapshot: repo_status_before)
          record_process_metric(
            'verify',
            success: true,
            tests_run: result[:tests_run],
            evidence_strength: evidence_strength,
            host: verify_metric_host,
            source_fingerprint: verify_source_fingerprint,
            duration_seconds: result[:duration],
            include_ui: include_ui,
            ui_only: ui_only,
            signed_tests: signed_tests
          ) if respond_to?(:record_process_metric)
          record_verify_attempt(success: true, message: 'verify') unless running_from_preflight
          puts "\n✅ Tests passed! (#{result[:tests_run]} tests, #{result[:duration]}s)"
          # Suggest recording patterns after successful test run
          suggest_memory_record if respond_to?(:suggest_memory_record)
        else
          failure_message = if zero_test_success
                              'verify zero-test failure'
                            elsif result[:timeout]
                              'verify timeout'
                            else
                              'verify failure'
                            end
          # The verifier writes each command to a unique receipt log. Use the
          # bounded output returned by the command that actually failed rather
          # than the legacy test_output.txt path, which may be stale or absent.
          failure_log_text = result[:failure_output].to_s
          failure = classify_verify_result(
            success: zero_test_success,
            timeout: result[:timeout],
            tests_run: result[:tests_run],
            log_text: failure_log_text
          )
          record_process_metric(
            'verify',
            success: false,
            tests_run: result[:tests_run],
            evidence_strength: 'failed',
            host: verify_metric_host,
            source_fingerprint: verify_source_fingerprint,
            duration_seconds: result[:duration],
            include_ui: include_ui,
            ui_only: ui_only,
            signed_tests: signed_tests,
            reason: failure_message,
            timeout_actual: result[:timeout],
            timeout_seconds: timeout,
            failure_bucket: failure[:bucket],
            failure_hint: failure[:hint]
          ) if respond_to?(:record_process_metric)
          # A verify nested inside release/App Store preflight is still a real
          # verify attempt. Skipping it let repeated identical failures evade
          # the two-strike research gate simply by using another canonical
          # wrapper.
          state = record_verify_failure_attempt(failure_message, failure_log_text, result)
          log_size = failure_log_text.bytesize
          if zero_test_success
            puts "\n❌ Verify failed: the test runner reported success but counted 0 tests."
            puts '   This is not tested evidence. Check test discovery and result parsing, then rerun verify.'
          elsif log_size.zero?
            puts "\n❌ Tests failed: the failing verify command produced no receipt output."
            puts '   This usually means the build process failed to start or was killed immediately.'
            puts '   Try: ./scripts/SaneMaster.rb clean --nuclear && ./scripts/SaneMaster.rb verify'
          else
            puts "\n❌ Tests failed. Running diagnostics..."
            puts "⚠️  Test run timed out after #{timeout}s" if result[:timeout]
            diagnose(nil, dump: true, since: test_start_time)
          end
          if state[:consecutive_failures].to_i >= 2
            puts ''
            puts '🛑 TWO-STRIKE RULE TRIGGERED'
            puts '   Fresh research is now required before more app work.'
          end
          exit 1
        end
      ensure
        cleanup_test_processes(permission_monitor)
      end
    end

    def parse_verify_args(args, default_timeout:)
      unless default_timeout.to_s.match?(/\A[1-9]\d*\z/)
        raise ArgumentError, "configured timeout must be a positive integer, got #{default_timeout.inspect}"
      end

      allowed_flags = %w[
        --clean
        --ui
        --ui-only
        --signed-tests
        --no-grant-permissions
        --skip-test-validation
        --quiet
      ].freeze
      seen = {}
      parsed = {}
      index = 0
      while index < args.length
        argument = args[index].to_s
        if argument == '--timeout'
          raise ArgumentError, 'duplicate --timeout' if seen[argument]

          value = args[index + 1]
          unless value.to_s.match?(/\A[1-9]\d*\z/)
            raise ArgumentError, '--timeout requires a positive integer value'
          end
          seen[argument] = true
          parsed[:timeout] = value.to_i
          index += 2
          next
        end

        raise ArgumentError, "unknown argument #{argument.inspect}" unless allowed_flags.include?(argument)
        raise ArgumentError, "duplicate #{argument}" if seen[argument]

        seen[argument] = true
        index += 1
      end
      raise ArgumentError, '--ui and --ui-only cannot be combined' if seen['--ui'] && seen['--ui-only']

      {
        clean: seen.key?('--clean'),
        ui_only: seen.key?('--ui-only'),
        include_ui: seen.key?('--ui') || seen.key?('--ui-only'),
        signed_tests: seen.key?('--signed-tests'),
        no_grant_permissions: seen.key?('--no-grant-permissions'),
        skip_test_validation: seen.key?('--skip-test-validation'),
        quiet: seen.key?('--quiet'),
        timeout: parsed.fetch(:timeout, default_timeout)
      }
    end

    def record_verify_failure_attempt(message, failure_output, result)
      record_verify_attempt(
        success: false,
        message: message,
        fingerprint: verify_failure_fingerprint(
          failure_output,
          fallback_identity: [result[:failure_label], result[:exit_status]].compact.join(':')
        )
      )
    end

    # Stable identity of WHICH tests failed, so the two-strike escalation can
    # distinguish "same problem twice" (escalate) from "fixed one problem,
    # surfaced the next" (legitimate iteration, streak restarts — see
    # record_verify_attempt). Compiler diagnostics count too: sequential fixes
    # commonly surface a different strict-concurrency error before tests start,
    # and those are not repeated attempts at the same problem. When a runner
    # exits without a recognized marker, bind the fingerprint to the failing
    # lane and its bounded output. nil is reserved for a truly unidentified
    # failure; two nil values must never be claimed as the "same problem."
    def verify_failure_fingerprint(log_text, fallback_identity: nil)
      text = log_text.to_s.dup.force_encoding('UTF-8')
      text = text.scrub('?') unless text.valid_encoding?
      # map+compact, not filter_map: must stay Ruby 2.6-compatible.
      lines = text.each_line.map do |line|
        stripped = line.strip
        test_failure = stripped.start_with?('❌') || stripped =~ /\AFAIL(ED)?[: ]/ || stripped =~ /\A✖ /
        compiler_failure = stripped.match?(%r{\.(?:swift|m|mm|c|cc|cpp|h|hpp):\d+(?::\d+)?:\s+(?:fatal\s+)?error:})
        next nil unless test_failure || compiler_failure
        stripped
      end.compact.uniq.sort
      if lines.empty?
        fallback = fallback_identity.to_s.strip
        return nil if fallback.empty?

        # Preserve the failing lane while stripping common volatile values so
        # a repeated opaque runner failure remains stable across attempts.
        normalized = text.gsub(/\e\[[0-9;]*m/, '')
                         .gsub(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b/, '<timestamp>')
                         .gsub(/\bpid[=: ]+\d+\b/i, 'pid=<pid>')
                         .gsub(/\belapsed[=: ]+\d+(?:\.\d+)?s?\b/i, 'elapsed=<duration>')
                         .lines.map(&:strip).reject(&:empty?).last(80).join("\n")
        lines = ["lane=#{fallback}", normalized]
      end

      require 'digest'
      Digest::SHA256.hexdigest(lines.join("\n"))[0, 16]
    end

    def run_verify_preflight
      return if @verify_preflight_ran

      preflight_test_environment
      @verify_preflight_ran = true
    end

    def ensure_sanevideo_test_assets!
      return unless project_name == 'SaneVideo'
      return unless respond_to?(:generate_test_assets)

      required_assets = %w[
        test_video.mp4
        test_silence.mp4
        test.mov
        file.mov
        IMG_7668.MOV
        German.MOV
        IMG_0422.MOV
        IMG_6091.MOV
        stress_test_clip.mp4
        website-demo-video-call.mp4
      ]
      missing_assets = required_assets.reject do |filename|
        File.exist?(File.join('Tests', 'Assets', filename))
      end
      return if missing_assets.empty?

      puts "📦 Generating missing SaneVideo test assets: #{missing_assets.join(', ')}"
      generate_test_assets
    end

    def enforce_saneui_source_of_truth!
      report = SaneMasterModules::SaneUIGuard.report_for_path(Dir.pwd)
      return unless report[:applicable]

      warnings = report[:warnings] || []
      errors = report[:errors] || []
      return if warnings.empty? && errors.empty?

      puts '🎨 --- [ SANEUI SOURCE OF TRUTH ] ---'
      SaneMasterModules::SaneUIGuard.format_report(report).each { |line| puts line }

      if errors.any?
        if ENV['SANEMASTER_ALLOW_SANEUI_DRIFT'] == '1'
          puts '⚠️  SANEMASTER_ALLOW_SANEUI_DRIFT=1 set — bypassing SaneUI drift blocker.'
        else
          puts '❌ Shared settings/UI drift detected.'
          puts "   Fix the shared-source violations or bypass explicitly with SANEMASTER_ALLOW_SANEUI_DRIFT=1."
          exit 1
        end
      end

      puts ''
    end

    def preflight_test_environment
      puts '🧪 --- [ SANEMASTER VERIFY PREFLIGHT ] ---'
      guard_test_localhost_ports
      terminate_stale_test_processes
      puts '✅ Verify preflight complete.'
      puts ''
    end

    def verify_running_as_preflight?
      ENV['SANEMASTER_RELEASE_PREFLIGHT'] == '1' || ENV['SANEMASTER_APPSTORE_PREFLIGHT'] == '1'
    end

    def guard_test_localhost_ports
      return unless command_available?('lsof')

      test_ports = (ENV['SANEMASTER_TEST_PORTS'] || '8999')
                   .split(',')
                   .map(&:strip)
                   .reject(&:empty?)

      stale_ports = []

      test_ports.each do |port|
        pids = test_listeners_for_port(port)
        next if pids.empty?

        stale_ports << port
        puts "  ⚠️  Port #{port} has active listeners: #{pids.join(', ')}"
        kill_test_processes_for_pids(pids)
      end

      stuck = stale_ports.reject do |port|
        test_listeners_for_port(port).empty?
      end

      return if stuck.empty?

      puts "  ❌ Could not clear test listener(s) on: #{stuck.join(', ')}"
      stuck.each do |port|
        pids = test_listeners_for_port(port)
        next if pids.empty?
        puts "     Port #{port} still bound by:"
        pids.each do |pid|
          cmd = process_command_for_pid(pid)
          puts "      - #{pid} => #{cmd.empty? ? '<unknown>' : cmd}"
        end
      end
      puts '  🧯 Set SANEMASTER_ALLOW_PORT_OCCUPIED=1 to bypass, or stop the owning process(es) and rerun.'
      exit 1 unless ENV['SANEMASTER_ALLOW_PORT_OCCUPIED'] == '1'
    end

    def terminate_stale_test_processes
      pids = stale_test_processes
      return if pids.empty?

      puts "  🧹 Reaping stale test process(es): #{pids.join(', ')}"
      pids.each do |pid|
        begin
          Process.kill('TERM', pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      sleep(0.5)

      lingering = stale_test_processes
      if lingering.empty?
        puts '  ✅ Stale test processes cleared.'
        return
      end

      puts '  ⚠️  Some stale test processes are still alive, force killing...'
      lingering.each do |pid|
        begin
          Process.kill('KILL', pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    def stale_test_processes
      raw = `pgrep -f '(xcodebuild|xctest|testmanagerd)' 2>/dev/null`
      return [] if raw.nil? || raw.empty?

      pids = raw.split
      pids.select do |pid|
        command = process_command_for_pid(pid)
        next false unless command

        command.downcase.include?(project_name.downcase) || project_related_test_process?(command)
      end
    end

    def project_related_test_process?(command)
      return false unless command

      text = command.downcase
      tool_marker = text.include?('xcodebuild') ||
                    text.include?('xctest') ||
                    text.include?('swift-testing') ||
                    text.include?('testmanager')

      tool_marker && project_process_matchers.any? { |matcher| text.include?(matcher) }
    end

    def test_listeners_for_port(port)
      raw = `lsof -nP -iTCP:#{port} -sTCP:LISTEN -t 2>/dev/null`
      return [] if raw.nil? || raw.empty?

      pids = raw.split
      return [] if pids.empty?

      pids.select do |pid|
        command = process_command_for_pid(pid)
        command && project_related_test_process?(command)
      end
    end

    def kill_test_processes_for_pids(pids)
      pids.each do |pid|
        begin
          Process.kill('TERM', pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    def process_command_for_pid(pid)
      `ps -p #{pid.to_i} -o command= 2>/dev/null`.strip
    rescue StandardError
      nil
    end

    def project_process_matchers
      @project_process_matchers ||= begin
        raw = [
          project_name,
          project_scheme,
          File.basename(Dir.pwd),
          project_xcodeproj,
          File.basename(project_xcodeproj.to_s),
          project_workspace,
          File.basename(project_workspace.to_s)
        ]

        raw.compact
          .map(&:to_s)
          .map(&:strip)
          .reject(&:empty?)
          .map(&:downcase)
          .uniq
      end
    end

    def command_available?(command_name)
      system("command -v #{command_name} >/dev/null 2>&1")
    end

    def clean(args)
      nuclear = args.include?('--nuclear')

      puts '🧹 --- [ SANEMASTER CLEAN ] ---'

      if nuclear
        puts '⚠️  NUCLEAR CLEAN - Removing all build artifacts...'
        # DerivedData
        system("rm -rf ~/Library/Developer/Xcode/DerivedData/#{project_name}-*")
        system('rm -rf .derivedData')
        # Asset catalog caches (critical for icon changes!)
        system('rm -rf ~/Library/Caches/com.apple.dt.Xcode/')
        # Module cache
        system('rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex')
        # Test output
        system('rm -rf fastlane/test_output')
        system("rm -rf /tmp/#{project_name}*")
        # CRITICAL: Also clear Ruby's actual tmpdir (which differs from /tmp on macOS)
        # Dir.tmpdir returns /var/folders/.../T/ not /tmp
        diagnostics_dir = File.join(Dir.tmpdir, "#{project_name}_Diagnostics")
        FileUtils.rm_rf(diagnostics_dir)
        # Clear any test project leftovers (non-sandboxed app uses Application Support)
        system("rm -rf ~/Library/Application\\ Support/#{project_name}/#{project_name}_Test_Projects 2>/dev/null")
        system('rm -f test_output.txt')
        # Regenerate project after nuclear clean
        puts '🔄 Regenerating Xcode project...'
        system('xcodegen generate 2>&1')
        puts '✅ Nuclear clean complete.'
      else
        puts 'Standard clean...'
        system('xcodebuild', *xcodebuild_container_args, '-scheme', project_scheme, 'clean', out: File::NULL, err: File::NULL)
        system('rm -f test_output.txt')
        puts '✅ Clean complete.'
      end
    end

    def reset_permissions
      puts '🔐 --- [ SANEMASTER RESET PERMISSIONS ] ---'
      puts "Resetting TCC privacy permissions for #{@bundle_id}..."

      %w[Camera Microphone ScreenRecording].each do |service|
        print "  Resetting #{service}... "
        system('tccutil', 'reset', service, @bundle_id, out: File::NULL, err: File::NULL)
        puts '✅'
      end

      puts "\n✅ Permissions reset. App will prompt again on next launch."
    end

    def check_permission_status
      puts 'Checking TCC database...'
      puts '  ℹ️  Run app to see current permission status'
    end

    def audit_project
      puts '🔍 --- [ SANEMASTER ACCESSIBILITY AUDIT ] ---'

      # Auto-detect .xcodeproj in current directory
      project_dir = Dir.glob('*.xcodeproj').first
      unless project_dir && File.exist?(project_dir)
        puts "❌ No .xcodeproj found. Run 'xcodegen generate' first."
        return
      end

      require 'xcodeproj'
      project = Xcodeproj::Project.open(project_dir)
      swift_files = project.files.select { |f| f.path.end_with?('.swift') && !f.path.include?('Test') }.map(&:real_path)

      puts '📂 Scanning Swift files for missing identifiers...'
      missing_count = scan_for_missing_identifiers(swift_files)

      if missing_count.zero?
        puts '✅ Audit Passed: All detected interactive elements have identifiers.'
      else
        puts "\n❗ Audit Found #{missing_count} potential gaps in accessibility coverage."
      end
    end

    def run_lint
      puts '🎨 --- [ SANEMASTER LINT ] ---'
      if run_fastlane_lint
        puts '✅ Linting complete.'
      else
        puts 'ℹ️  Falling back to direct lint tools (SwiftLint/SwiftFormat)...'
        if run_direct_lint
          puts '✅ Linting complete (direct tools).'
        else
          puts '❌ Linting failed.'
          exit 1
        end
      end
    end

    def run_fastlane_lint
      if File.exist?('Gemfile')
        unless bundle_available?
          puts '  ⚠️  bundle is not installed; skipping bundle exec fastlane lint.'
          return false
        end

        output, status = capture2e_with_bundle_env(preferred_bundle_bin, 'exec', 'fastlane', 'lint')
        return true if status.success?

        if output.match?(/Bundler::GemNotFound|Could not find .* in locally installed gems/)
          puts '  ⚠️  Fastlane bundle dependencies are not installed; using direct linters.'
        else
          puts '  ⚠️  bundle exec fastlane lint failed; using direct linters.'
        end
        return false
      end

      unless command_available?('fastlane')
        puts '  ⚠️  fastlane is not installed and no Gemfile is present.'
        return false
      end

      system('fastlane', 'lint')
    end

    def run_direct_lint
      any_tool = false
      ok = true

      if command_available?('swiftlint')
        any_tool = true
        swiftlint_ok = system('swiftlint', 'lint', '--quiet')
        ok = false unless swiftlint_ok
      else
        puts '  ⚠️  SwiftLint not found (brew install swiftlint).'
      end

      if command_available?('swiftformat')
        any_tool = true
        swiftformat_ok = system('swiftformat', '.', '--lint', '--quiet')
        ok = false unless swiftformat_ok
      else
        puts '  ⚠️  SwiftFormat not found (brew install swiftformat).'
      end

      return false unless any_tool

      ok
    end

    def run_quality_report
      puts '📊 --- [ SANEMASTER QUALITY ] ---'
      unless bundle_available?
        puts '❌ Quality report generation failed.'
        return
      end

      output, status = capture2e_with_bundle_env(preferred_bundle_bin, 'exec', 'fastlane', 'quality')
      if status.success?
        puts '✅ Quality report generation complete.'
      elsif output.include?('Could not find lane')
        puts 'ℹ️  No fastlane quality lane; falling back to the bundled rubocop report.'
        check_rubocop_issues
      else
        puts output unless output.to_s.strip.empty?
        puts '❌ Quality report generation failed.'
      end
    end

    def validate_test_references
      puts '🔍 --- [ VALIDATE TEST REFERENCES ] ---'
      puts 'Checking that all test references match UI code...'

      unless ui_tests_present?
        if runtime_smoke_coverage_present?
          puts "  ℹ️  No XCUITest target found (#{project_ui_tests_dir} missing). Runtime UI coverage lives in Scripts/live_zone_smoke.rb + RuntimeGuardXCTests."
        else
          puts "  ⚠️  No UI tests found (#{project_ui_tests_dir} missing). Skipping validation."
        end
        return
      end

      ui_identifiers = extract_ui_identifiers
      puts "  Found #{ui_identifiers.count} identifiers in UI code"

      test_references = extract_test_references
      puts "  Found #{test_references.count} references in test code"

      missing_in_ui = missing_test_identifiers

      if missing_in_ui.any?
        puts "\n❌ CRITICAL: Tests reference non-existent identifiers:"
        missing_in_ui.sort.each do |id|
          files = find_references_in_files(id)
          files.each { |file| puts "   - '#{id}' referenced in #{file}" }
        end
        puts "\n💡 Fix: Remove test references or add identifier to UI code"
        exit 1
      end

      puts "\n✅ All test references are valid!"
      puts "   UI identifiers: #{ui_identifiers.count}"
      puts "   Test references: #{test_references.count}"
    end

    private

    # ═══════════════════════════════════════════════════════════════════════════
    # UNIFIED SYSTEM AUDIT
    # Verifies the centralized SaneProcess hook system is working across all projects
    # ═══════════════════════════════════════════════════════════════════════════
    def audit_unified
      puts "╔══════════════════════════════════════════════════════════════╗"
      puts "║           UNIFIED SYSTEM AUDIT - SaneProcess                 ║"
      puts "╚══════════════════════════════════════════════════════════════╝"

      results = { passed: 0, failed: 0, warnings: 0 }
      saneprocess_hooks = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks')

      # 1. Hook Infrastructure
      puts "\n═══ 1. HOOK INFRASTRUCTURE ═══"
      hooks = %w[session_start.rb saneprompt.rb sanetools.rb sanetrack.rb sanestop.rb]
      hooks.each do |hook|
        path = File.join(saneprocess_hooks, hook)
        if File.exist?(path)
          # Check syntax
          if system("ruby -c #{path} > /dev/null 2>&1")
            puts "  ✅ #{hook}: Syntax OK"
            results[:passed] += 1
          else
            puts "  ❌ #{hook}: SYNTAX ERROR"
            results[:failed] += 1
          end
        else
          puts "  ❌ #{hook}: NOT FOUND"
          results[:failed] += 1
        end
      end

      # Core modules
      puts "\n  Core Modules:"
      core_modules = %w[state_manager.rb local_ui_guard.rb]
      core_modules.each do |mod|
        path = File.join(saneprocess_hooks, 'core', mod)
        if File.exist?(path) && system("ruby -c #{path} > /dev/null 2>&1")
          puts "    ✅ core/#{mod}: OK"
          results[:passed] += 1
        else
          puts "    ❌ core/#{mod}: MISSING or SYNTAX ERROR"
          results[:failed] += 1
        end
      end

      # 2. Project Configuration
      puts "\n═══ 2. PROJECT CONFIGURATION ═══"
      projects = {
        'SaneBar' => '~/SaneApps/apps/SaneBar',
        'SaneVideo' => '~/SaneApps/apps/SaneVideo',
        'SaneClip' => '~/SaneApps/apps/SaneClip',
        'SaneHosts' => '~/SaneApps/apps/SaneHosts',
        'SaneClick' => '~/SaneApps/apps/SaneClick'
      }

      projects.each do |name, path|
        expanded = File.expand_path(path)
        settings = File.join(expanded, '.claude', 'settings.json')

        if File.exist?(settings)
          begin
            require 'json'
            content = File.read(settings)
            JSON.parse(content)
            if content.include?('SaneProcess')
              puts "  ✅ #{name}: Valid JSON, references SaneProcess"
              results[:passed] += 1
            else
              puts "  ⚠️  #{name}: Valid JSON but NO SaneProcess reference"
              results[:warnings] += 1
            end
          rescue JSON::ParserError
            puts "  ❌ #{name}: INVALID JSON"
            results[:failed] += 1
          end
        else
          puts "  ⚠️  #{name}: No settings.json (may not use SaneProcess)"
          results[:warnings] += 1
        end
      end

      # 3. Key Features
      puts "\n═══ 3. KEY FEATURES ═══"
      features = {
        'Lock timeout' => { file: 'core/state_manager.rb', pattern: 'LOCK_TIMEOUT' },
        'Feature reminders' => { file: 'sanetrack.rb', pattern: 'emit_rewind_reminder' },
        'Log rotation' => { file: 'session_start.rb', pattern: 'rotate_log_files' },
        'Serena reminder' => { file: 'session_start.rb', pattern: 'Serena.*activate' }
      }

      features.each do |name, spec|
        path = File.join(saneprocess_hooks, spec[:file])
        if File.exist?(path)
          content = File.read(path)
          if content.match?(Regexp.new(spec[:pattern]))
            puts "  ✅ #{name}: Present"
            results[:passed] += 1
          else
            puts "  ❌ #{name}: MISSING from #{spec[:file]}"
            results[:failed] += 1
          end
        else
          puts "  ❌ #{name}: File not found (#{spec[:file]})"
          results[:failed] += 1
        end
      end

      # 4. Serena MCP
      puts "\n═══ 4. MCP CONFIGURATION ═══"
      serena_sources = [
        File.expand_path('~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/serena/.mcp.json'),
        File.expand_path('~/SaneApps/infra/SaneProcess/.mcp.json'),
        File.expand_path('~/.codex/config.toml')
      ]
      existing_sources = serena_sources.select { |p| File.exist?(p) }

      if existing_sources.empty?
        puts "  ⚠️  Serena config not found"
        results[:warnings] += 1
      else
        has_project_from_cwd = existing_sources.any? do |cfg|
          content = File.read(cfg)
          content.include?('project-from-cwd')
        end

        if has_project_from_cwd
          puts "  ✅ Serena: --project-from-cwd flag present"
          results[:passed] += 1
        else
          puts "  ⚠️  Serena: Missing --project-from-cwd (manual activation needed)"
          results[:warnings] += 1
        end
      end

      # 5. Bootstrap Template
      puts "\n═══ 5. BOOTSTRAP TEMPLATE ═══"
      template = File.expand_path('~/SaneApps/infra/SaneProcess/templates/NEW_PROJECT_TEMPLATE.md')
      if File.exist?(template)
        content = File.read(template)
        if content.include?('SaneProcess/scripts/hooks')
          puts "  ✅ Template references shared hooks"
          results[:passed] += 1
        else
          puts "  ❌ Template uses LOCAL hooks (will cause fragmentation!)"
          results[:failed] += 1
        end
      else
        puts "  ⚠️  Template not found"
        results[:warnings] += 1
      end

      # Summary
      puts "\n╔══════════════════════════════════════════════════════════════╗"
      puts "║                        SUMMARY                               ║"
      puts "╠══════════════════════════════════════════════════════════════╣"
      puts "║  ✅ Passed:   #{results[:passed].to_s.ljust(4)}                                          ║"
      puts "║  ⚠️  Warnings: #{results[:warnings].to_s.ljust(4)}                                          ║"
      puts "║  ❌ Failed:   #{results[:failed].to_s.ljust(4)}                                          ║"
      puts "╠══════════════════════════════════════════════════════════════╣"

      if results[:failed] == 0
        puts "║  STATUS: ✅ UNIFIED SYSTEM HEALTHY                           ║"
      else
        puts "║  STATUS: ❌ ISSUES DETECTED - Review above                   ║"
      end
      puts "╚══════════════════════════════════════════════════════════════╝"

      results[:failed] == 0
    end
  end
end
# rubocop:enable Metrics/ModuleLength
