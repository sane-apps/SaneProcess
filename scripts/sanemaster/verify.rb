# frozen_string_literal: true

require 'open3'

module SaneMasterModules
  # Build, test execution, permissions, test validation
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

    def verify(args)
      running_from_preflight = verify_running_as_preflight?
      return unless running_from_preflight || ensure_research_gate_clear!('verify')

      if test_targets_disabled?
        handle_disabled_tests(args)
        return
      end

      clean_first = args.include?('--clean')
      include_ui = args.include?('--ui')
      default_timeout = config_value(%w[tests verify_timeout_seconds], 'SANEMASTER_VERIFY_TIMEOUT', 300).to_i
      timeout_flag_index = args.index('--timeout')
      timeout = if timeout_flag_index
                  override = args[timeout_flag_index + 1]
                  parsed_override = override&.to_i
                  parsed_override.to_i.positive? ? parsed_override.to_i : default_timeout
                else
                  default_timeout
                end
      signed_tests = args.include?('--signed-tests') || ENV['SANEMASTER_SIGN_TEST_BUILDS'] == '1'

      run_verify_preflight
      enforce_saneui_source_of_truth!
      clean([]) if clean_first
      repo_status_before = git_status_snapshot

      puts '🔨 --- [ SANEMASTER VERIFY ] ---'
      puts 'Building and running tests with progress monitoring...'
      auto_permissions = args.include?('--grant-permissions') || ENV['SANEMASTER_GRANT_PERMISSIONS'] == '1'
      permissions_status = auto_permissions ? '✅' : 'off (use --grant-permissions)'
      puts "⏱️  Timeout: #{timeout}s | Auto-handling permissions: #{permissions_status}"
      puts include_ui ? '📱 Including UI tests (use --ui flag)' : '⚡ Unit tests only (use --ui to include UI tests)'
      puts signed_tests ? '🔐 Test builds will use normal code signing' : '🧪 Headless mode: test builds run without code signing'
      puts ''

      permission_monitor_pid = auto_permissions ? grant_test_permissions : nil
      terminate_running_app_instance
      validate_test_references unless args.include?('--skip-test-validation')

      begin
        test_start_time = Time.now
        result = run_tests_with_progress(timeout_seconds: timeout, include_ui: include_ui, signed_tests: signed_tests)

        if result[:success]
          verify_repo_cleanliness!(before_snapshot: repo_status_before)
          record_verify_attempt(success: true, message: 'verify') unless running_from_preflight
          puts "\n✅ Tests passed! (#{result[:tests_run]} tests, #{result[:duration]}s)"
          # Suggest recording patterns after successful test run
          suggest_memory_record if respond_to?(:suggest_memory_record)
        else
          failure_message = result[:timeout] ? 'verify timeout' : 'verify failure'
          state = if running_from_preflight
                    { consecutive_failures: load_verify_state[:consecutive_failures].to_i }
                  else
                    record_verify_attempt(success: false, message: failure_message)
                  end
          log_size = File.exist?('test_output.txt') ? File.size('test_output.txt') : 0
          if log_size.zero?
            puts "\n❌ Tests failed: xcodebuild produced no output (test_output.txt is empty)."
            puts '   This usually means the build process failed to start or was killed immediately.'
            puts '   Try: ./scripts/SaneMaster.rb clean --nuclear && ./scripts/SaneMaster.rb verify'
          else
            puts "\n❌ Tests failed. Running diagnostics..."
            puts "⚠️  Test run timed out after #{timeout}s" if result[:timeout]
            diagnose(nil, dump: true, since: test_start_time)
          end
          if !running_from_preflight && state[:consecutive_failures].to_i >= 2
            puts ''
            puts '🛑 TWO-STRIKE RULE TRIGGERED'
            puts '   Fresh research is now required before more app work.'
          end
          exit 1
        end
      ensure
        cleanup_test_processes(permission_monitor_pid)
      end
    end

    def run_verify_preflight
      return if @verify_preflight_ran

      preflight_test_environment
      @verify_preflight_ran = true
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

        return true if system_with_bundle_env(preferred_bundle_bin, 'exec', 'fastlane', 'lint')

        puts '  ⚠️  bundle exec fastlane lint failed (gem/bundler or lane issue).'
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
        ok &&= system('swiftlint', 'lint', '--quiet')
      else
        puts '  ⚠️  SwiftLint not found (brew install swiftlint).'
      end

      if command_available?('swiftformat')
        any_tool = true
        ok &&= system('swiftformat', '.', '--lint', '--quiet')
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

      missing_in_ui = test_references - ui_identifiers

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

    def git_status_snapshot(repo_path = Dir.pwd)
      root_out, root_status = Open3.capture2('git', '-C', repo_path, 'rev-parse', '--show-toplevel')
      return [] unless root_status.success?

      root = root_out.strip
      status_out, status_result = Open3.capture2('git', '-C', root, 'status', '--porcelain=1', '--untracked-files=all')
      raise "git status failed for #{root}" unless status_result.success?

      status_out.lines
        .map(&:chomp)
        .reject(&:empty?)
        .sort
    end

    def verify_repo_dirt_report(before_snapshot:, repo_path: Dir.pwd)
      after_snapshot = git_status_snapshot(repo_path)
      {
        before: before_snapshot,
        after: after_snapshot,
        introduced: after_snapshot - before_snapshot
      }
    end

    def verify_repo_cleanliness!(before_snapshot:)
      report = verify_repo_dirt_report(before_snapshot: before_snapshot)
      return if report[:introduced].empty?
      return if ENV['SANEMASTER_ALLOW_VERIFY_REPO_DRIFT'] == '1'

      puts "\n❌ Verify introduced new git dirt:"
      report[:introduced].each { |entry| puts "   - #{entry}" }
      puts '   Fix the generated drift or ignore it properly before claiming verify passed.'
      puts '   Set SANEMASTER_ALLOW_VERIFY_REPO_DRIFT=1 only if you intentionally need to bypass this guard.'
      exit 1
    end

    def test_targets_disabled?
      project_yml = File.join(Dir.pwd, 'project.yml')
      return false unless File.exist?(project_yml)

      content = File.read(project_yml)
      content.include?('# Temporarily disabled test targets') ||
        (content.include?('# targets:') && content.include?("#   - #{project_tests_dir}"))
    end

    def handle_disabled_tests(args)
      puts '⚠️  Test targets are temporarily disabled due to SwiftUICore linker error (Xcode 16/macOS 26.2 bug)'
      puts '📝 Test files are preserved - they will be re-enabled when Xcode is updated'
      puts ''
      puts 'Building main app only (tests skipped)...'
      puts ''

      clean([]) if args.include?('--clean')

      puts "🔨 Building #{project_name} app..."
      result = system('xcodebuild', *xcodebuild_container_args, '-scheme', project_scheme,
                      '-destination', 'platform=macOS,arch=arm64', 'build')
      puts ''
      if result
        puts '✅ Build succeeded (tests disabled)'
      else
        puts '❌ Build failed'
        exit 1
      end
    end

    def grant_test_permissions
      print '🔐 Granting test permissions... '
      # Use dynamic bundle_id instead of hardcoded value
      %w[Camera Microphone ScreenRecording].each do |service|
        system('tccutil', 'reset', service, @bundle_id, err: File::NULL)
      end

      permission_pid = nil
      script_path = File.join(__dir__, '..', 'grant_permissions.applescript')
      if File.exist?(script_path)
        permission_pid = Process.spawn("osascript '#{script_path}' #{project_name} > /dev/null 2>&1")
        Process.detach(permission_pid)
      end

      puts '✅'
      permission_pid
    end

    def terminate_running_app_instance
      system('pkill', '-9', '-x', project_name, err: File::NULL)
      sleep(0.2)
    end

    def cleanup_test_processes(permission_monitor_pid = nil)
      print '🧹 Cleaning up test processes... '

      if permission_monitor_pid
        begin
          Process.kill('TERM', permission_monitor_pid) if permission_monitor_pid.positive?
        rescue Errno::ESRCH, Errno::EPERM
          # Process already dead or we don't have permission
        end
      end

      system('pkill', '-f', 'grant_permissions.applescript', err: File::NULL)
      terminate_project_test_processes('TERM')
      sleep(0.5)
      terminate_project_test_processes('KILL')
      system('killall', '-9', project_name, err: File::NULL)

      puts '✅'
    end

    def terminate_project_test_processes(signal)
      stale_test_processes.each do |pid|
        begin
          Process.kill(signal, pid.to_i)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    def run_tests_with_progress(timeout_seconds:, include_ui: false, signed_tests: false)
      require 'open3'

      run_verify_preflight

      commands = build_test_commands(include_ui, signed_tests)
      state = { start_time: Time.now, tests_run: 0, swift_testing_total: 0, current_test: nil, last_update: Time.now,
                spinner_chars: ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'], spinner_idx: 0 }

      result = { success: true, timeout: false }
      commands.each_with_index do |entry, index|
        puts "▶️  #{entry[:label]}" if commands.length > 1
        result = execute_with_logging(entry[:cmd], timeout_seconds, append: index.positive?, label: entry[:label]) do |line|
          handle_progress_update(line, state)
        end
        break unless result[:success]
      end

      print "\r"
      cleanup_test_processes

      # Use Swift Testing total if available (more accurate), otherwise fall back to counted tests
      total_tests = [state[:swift_testing_total].to_i, state[:tests_run].to_i].max
      { success: result[:success], tests_run: total_tests, duration: (Time.now - state[:start_time]).to_i, timeout: result[:timeout] }
    end

    def verify_log_indicates_success?(text)
      body = text.to_s
      return true if body.include?('✅ Tests passed!')
      return true if body.match?(/Swift Testing:\s+\d+ tests .* passed/)
      return true if body.match?(/Test Suite 'All tests' passed/)
      return true if body.match?(/Executed \d+ tests?, with 0 failures/)

      false
    end

    def build_test_commands(include_ui, signed_tests = false)
      script_commands = script_only_verify_commands
      if script_commands
        puts '  ℹ️  No Xcode project detected. Running the scripted SaneProcess verify suite.'
        return script_commands
      end

      if include_ui && mixed_platform_ui_tests?
        return [
          { label: "#{project_scheme} unit tests", cmd: build_test_command(false, signed_tests) },
          { label: "#{project_ui_scheme} UI tests", cmd: build_ui_test_command(signed_tests) }
        ]
      end

      [{ label: include_ui ? "#{project_scheme} unit + UI tests" : "#{project_scheme} unit tests",
         cmd: build_test_command(include_ui, signed_tests) }]
    end

    def script_only_verify_commands
      return nil unless project_name == 'SaneProcess'
      return nil if workspace_usable_for_scheme?(project_scheme)
      return nil if project_xcodeproj && File.exist?(project_xcodeproj.to_s)
      return nil if package_path_for_test_target(project_test_target)

      [
        { label: 'SaneProcess hook enforcement tests', cmd: ['ruby', 'scripts/hooks/test/tier_tests.rb'] },
        { label: 'SaneProcess app release guard tests', cmd: ['ruby', 'scripts/app_test_mode_test.rb'] },
        { label: 'SaneProcess App Store guard tests', cmd: ['ruby', 'scripts/appstore_submit_guardrail_test.rb'] },
        { label: 'SaneProcess dependency watchdog tests', cmd: ['ruby', 'scripts/sanemaster/dependencies_test.rb'] },
        { label: 'SaneProcess release guardrail tests', cmd: ['ruby', 'scripts/sanemaster/release_guardrail_test.rb'] },
        { label: 'SaneProcess release route tests', cmd: ['ruby', 'scripts/sanemaster/release_route_test.rb'] },
        { label: 'SaneProcess SaneUI guard tests', cmd: ['ruby', 'scripts/sanemaster/saneui_guard_test.rb'] },
        { label: 'SaneProcess test mode tests', cmd: ['ruby', 'scripts/sanemaster/test_mode_test.rb'] },
        { label: 'SaneProcess verify guard tests', cmd: ['ruby', 'scripts/sanemaster/verify_guard_test.rb'] },
        { label: 'SaneProcess validation report tests', cmd: ['ruby', 'scripts/validation_report_test.rb'] },
        { label: 'SaneProcess LemonSqueezy sales tests', cmd: ['python3', '-B', 'scripts/automation/ls_sales_test.py'] },
        { label: 'SaneProcess listing action tests', cmd: ['python3', '-B', 'scripts/automation/listing_actions_test.py'] }
      ]
    end

    def build_test_command(include_ui, signed_tests = false)
      if include_ui
        unless ui_tests_present?
          if runtime_smoke_coverage_present?
            puts "  ℹ️  No XCUITest target found (#{project_ui_tests_dir} directory does not exist)"
            puts '  ℹ️  Runtime UI coverage lives in Scripts/live_zone_smoke.rb + RuntimeGuardXCTests.'
          else
            puts "  ⚠️  UI tests not available (#{project_ui_tests_dir} directory does not exist)"
          end
          puts '  📦 Running unit tests only...'
        end
      end
      if use_test_plan? && !include_ui
        package_path = package_path_for_test_target(project_test_target)
        if package_path
          puts "  ℹ️  Running package test target directly: #{project_test_target} (#{package_path})"
          return ['swift', 'test', '--package-path', package_path, '--filter', project_test_target]
        end
      end
      args = ['xcodebuild', 'test']
      args.concat(xcodebuild_container_args)
      args.concat(['-scheme', project_scheme, '-destination', 'platform=macOS,arch=arm64'])
      args.concat(['-parallel-testing-enabled', 'NO'])
      args.concat(['-parallel-testing-worker-count', '1'])
      if use_test_plan?
        puts '  ℹ️  Using scheme-managed test plan selection.'
        unless include_ui
          if ui_tests_present?
            args << "-skip-testing:#{project_ui_test_target}"
            puts "  ℹ️  Skipping UI target from test plan: #{project_ui_test_target}"
          end
        end
      else
        if include_ui
          if ui_tests_present?
            args.concat(["-only-testing:#{project_test_target}", "-only-testing:#{project_ui_test_target}"])
          else
            # UI tests not yet implemented - warn and run unit tests only
            if runtime_smoke_coverage_present?
              puts "  ℹ️  No XCUITest target found (#{project_ui_tests_dir} directory does not exist)"
              puts '  ℹ️  Runtime UI coverage lives in Scripts/live_zone_smoke.rb + RuntimeGuardXCTests.'
            else
              puts "  ⚠️  UI tests not available (#{project_ui_tests_dir} directory does not exist)"
            end
            puts '  📦 Running unit tests only...'
            args << "-only-testing:#{project_test_target}"
          end
        else
          args << "-only-testing:#{project_test_target}"
        end
      end
      unless signed_tests
        args.concat([
                      'CODE_SIGNING_ALLOWED=NO',
                      'CODE_SIGNING_REQUIRED=NO',
                      'CODE_SIGN_IDENTITY=',
                      'DEVELOPMENT_TEAM=',
                      'PROVISIONING_PROFILE_SPECIFIER=',
                      'PROVISIONING_PROFILE='
                    ])
      end
      args
    end

    def build_ui_test_command(signed_tests = false)
      args = ['xcodebuild', 'test']
      args.concat(xcodebuild_container_args_for_scheme(project_ui_scheme))
      args.concat(['-scheme', project_ui_scheme, '-destination', project_ui_destination])
      args.concat(['-parallel-testing-enabled', 'NO'])
      args.concat(['-parallel-testing-worker-count', '1'])
      args << "-only-testing:#{project_ui_test_target}"
      unless signed_tests
        args.concat([
                      'CODE_SIGNING_ALLOWED=NO',
                      'CODE_SIGNING_REQUIRED=NO',
                      'CODE_SIGN_IDENTITY=',
                      'DEVELOPMENT_TEAM=',
                      'PROVISIONING_PROFILE_SPECIFIER=',
                      'PROVISIONING_PROFILE='
                    ])
      end
      args
    end

    def package_path_for_test_target(test_target)
      return nil if test_target.to_s.strip.empty?

      manifests = Dir.glob(['Package.swift', '*/Package.swift', '*/*/Package.swift', '*/*/*/Package.swift'])
      manifests.each do |manifest|
        next if manifest.include?('/.build/')
        next unless File.file?(manifest)

        contents = File.read(manifest)
        next unless contents.include?('.testTarget')
        next unless contents.include?("name: \"#{test_target}\"")

        return File.dirname(manifest)
      rescue StandardError
        next
      end

      nil
    end

    def use_test_plan?
      value = saneprocess_value('tests', 'use_test_plan')
      return false if value.nil?

      value == true || value.to_s.downcase == 'true'
    end

    def mixed_platform_ui_tests?
      return false unless ui_tests_present?

      project_ui_scheme.to_s != project_scheme.to_s || !project_ui_destination.to_s.include?('platform=macOS')
    end

    def execute_with_logging(cmd, timeout_seconds, append: false, label: nil)
      success = false
      timed_out = false

      File.open('test_output.txt', append ? 'a' : 'w') do |log_file|
        puts '   📝 Full logs: test_output.txt'
        log_file.puts("\n=== #{label} ===") if label

        Open3.popen2e(*cmd) do |stdin, stdout_err, wait_thr|
          stdin.close

          reader = Thread.new do
            stdout_err.each_line do |line|
              line = line.chomp
              log_file.puts(line)
              yield(line) if block_given?
            end
          rescue IOError
            nil
          end

          # Avoid Timeout.timeout here; Ruby docs explicitly warn it cannot
          # reliably enforce deadlines for arbitrary/blocking operations.
          if wait_thr.join(timeout_seconds).nil?
            timed_out = true
            handle_timeout(timeout_seconds, wait_thr.pid)
          else
            success = wait_thr.value.success?
          end

          begin
            stdout_err.close unless stdout_err.closed?
          rescue IOError
            nil
          end

          reader.join(2)
          reader.kill if reader.alive?
        end
      end

      if !success && !timed_out && File.exist?('test_output.txt')
        log_output = File.read('test_output.txt') rescue ''
        if verify_log_indicates_success?(log_output)
          puts '   ℹ️  Test log shows a clean pass despite a non-zero runner exit; treating verify as successful.'
          success = true
        end
      end

      { success: success && !timed_out, timeout: timed_out }
    end

    def handle_progress_update(line, state)
      case line
      # XCTest pattern: Test Case '-[TestClass testMethod]' started/passed
      # Swift Testing pattern can be prefixed by ✓/✔ or private-use glyphs in Xcode logs.
      when /Test Case.*'(.+)'/, /(?:[✔✓]\s+)?Test "(.+)" passed/
        state[:current_test] = ::Regexp.last_match(1)
        state[:tests_run] += 1
        elapsed = (Time.now - state[:start_time]).to_i
        spinner = state[:spinner_chars][state[:spinner_idx] % state[:spinner_chars].length]
        print "\r#{spinner} Running: #{state[:current_test]} (#{state[:tests_run]} tests, #{elapsed}s)    "
        state[:spinner_idx] += 1
        state[:last_update] = Time.now
      # Swift Testing summary: may appear with or without explicit checkmark glyph.
      when /(?:[✔✓]\s+)?Test run with (\d+) tests? in (\d+) suites? passed/
        state[:swift_testing_total] = ::Regexp.last_match(1).to_i
        suites = ::Regexp.last_match(2).to_i
        print "\r"
        puts "   ✅ Swift Testing: #{state[:swift_testing_total]} tests in #{suites} suites passed"
      # Swift Testing suite start: may include non-ASCII prefix glyphs in logs.
      when /Suite "(.+)" started/
        suite_name = ::Regexp.last_match(1)
        elapsed = (Time.now - state[:start_time]).to_i
        spinner = state[:spinner_chars][state[:spinner_idx] % state[:spinner_chars].length]
        print "\r#{spinner} Suite: #{suite_name} (#{state[:tests_run]} tests, #{elapsed}s)    "
        state[:spinner_idx] += 1
        state[:last_update] = Time.now
      when /Test Suite.*passed|Test Suite.*failed/, /BUILD (SUCCEEDED|FAILED)/, /error:|warning:|❌|✅/
        print "\r"
        puts "   #{line}"
      when /Testing|Building/
        if Time.now - state[:last_update] > 2
          spinner = state[:spinner_chars][state[:spinner_idx] % state[:spinner_chars].length]
          print "\r#{spinner} #{line}    "
          state[:spinner_idx] += 1
          state[:last_update] = Time.now
        end
      end
    end

    def handle_timeout(timeout_seconds, process_pid = nil)
      puts "\n\n⏱️  TIMEOUT: Test run exceeded #{timeout_seconds}s"
      puts '   This usually means a test is stuck or waiting for user input'
      puts '🔪 Force killing all test processes...'

      begin
        Process.kill('TERM', process_pid) if process_pid
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      3.times do |attempt|
        # Use -x for exact match to avoid killing helper processes
        system('pkill', '-9', '-f', 'xcodebuild test', err: File::NULL)
        system('pkill', '-9', '-x', 'xcodebuild', err: File::NULL)
        system('killall', '-9', 'xcodebuild', err: File::NULL)
        system('killall', '-9', project_name, err: File::NULL)
        system('pkill', '-9', '-x', 'xctest', err: File::NULL)
        sleep(0.5) if attempt < 2
      end

      puts '✅ Processes killed'
    end

    def check_disk_space
      puts "\n💾 Disk Space:"
      disk_info = `df -h . 2>/dev/null`.lines.last&.split || []
      return unless disk_info.length >= 4

      available = disk_info[3]
      puts "  ✅ Available: #{available}"
      puts '  ⚠️  Low disk space! Export/build may fail' if available.include?('G') && available.to_f < 10
    end

    def check_test_assets
      puts "\n📦 Test Assets:"
      assets_dir = 'Tests/Assets'
      test_asset_name = ENV['TEST_ASSET_NAME'] || 'test_video.mp4'
      test_video = File.join(assets_dir, test_asset_name)
      max_asset_mb = (ENV['SANEMASTER_MAX_TEST_ASSET_MB'] || '200').to_i
      max_assets_dir_mb = (ENV['SANEMASTER_MAX_TEST_ASSETS_DIR_MB'] || '500').to_i

      if File.exist?(test_video)
        size = File.size(test_video) / 1024 / 1024.0
        size_str = size >= 1 ? "#{size.round(1)}MB" : "#{(size * 1024).round}KB"
        puts "  ✅ #{test_asset_name} exists (#{size_str})"
      else
        puts "  ⚠️  #{test_asset_name} missing"
        puts '     Run: ./Scripts/SaneMaster.rb gen_assets'
      end

      return unless Dir.exist?(assets_dir)

      total_bytes = 0
      oversized = []
      Dir.glob(File.join(assets_dir, '*')).each do |asset_path|
        next unless File.file?(asset_path)

        bytes = File.size(asset_path)
        total_bytes += bytes
        oversized << [asset_path, bytes] if bytes > (max_asset_mb * 1024 * 1024)
      end

      total_mb = total_bytes / 1024.0 / 1024.0
      if total_mb > max_assets_dir_mb || oversized.any?
        puts "  ⚠️  Assets directory is large (#{total_mb.round(1)}MB)."
        oversized.sort_by { |(_, bytes)| -bytes }.first(5).each do |(path, bytes)|
          puts "     - #{File.basename(path)}: #{(bytes / 1024.0 / 1024.0).round(1)}MB"
        end
        puts "     Keep test media lightweight. Regenerate with: ./scripts/SaneMaster.rb gen_assets"
      end
    end

    def check_xcodegen_sync
      puts "\n📁 XcodeGen Sync:"
      unless project_xcodeproj && !project_xcodeproj.to_s.empty?
        puts '  ℹ️  No Xcode project for this repo. Skipping XcodeGen sync check.'
        return
      end

      project_path = File.join(project_xcodeproj, 'project.pbxproj')
      unless File.exist?(project_path)
        puts '  ❌ Project file missing. Run: xcodegen generate'
        return
      end

      puts '  ✅ Project file exists'
      begin
        require 'xcodeproj'
        project = Xcodeproj::Project.open(project_xcodeproj)
        project_swift_count = project.files.count { |f| f.path&.end_with?('.swift') }
        disk_swift_count = `find . -name "*.swift" -not -path "*/.*" -not -path "*/build/*" -not -path "*/vendor/*" | wc -l`.strip.to_i
        if (project_swift_count - disk_swift_count).abs > 15
          puts "  ⚠️  File count mismatch (project: #{project_swift_count}, disk: ~#{disk_swift_count})"
          puts '     Run: xcodegen generate'
        else
          puts "  ✅ Project appears in sync (#{project_swift_count} Swift files)"
        end
      rescue LoadError
        puts '  ⚠️  Skipping sync check (run with: bundle exec ./Scripts/SaneMaster.rb doctor)'
      rescue StandardError => e
        puts "  ⚠️  Could not verify sync: #{e.message}"
      end
    end

    def check_permissions
      puts "\n🔐 Permissions:"
      check_permission_status
    end

    def check_mockolo
      puts "\n🎭 Mock Generation:"
      if system('which mockolo > /dev/null 2>&1')
        version = `mockolo --version 2>&1`.strip
        puts "  ✅ Mockolo installed (#{version})"
      else
        puts '  ⚠️  Mockolo not found. Install: brew install mockolo'
      end
    end

    def check_xcode
      puts "\n🛠️  Xcode:"
      xcode_version = `xcodebuild -version 2>&1`.strip
      if xcode_version.include?('Xcode')
        puts "  ✅ #{xcode_version}"
      else
        puts '  ❌ Xcode not found'
      end
    end

    def check_code_quality_tools
      puts "\n🎨 Code Quality Tools:"
      if system('which swiftlint > /dev/null 2>&1')
        version = `swiftlint version 2>&1`.strip
        puts "  ✅ SwiftLint #{version}"
      else
        puts '  ⚠️  SwiftLint not found. Install: brew install swiftlint'
      end
    end

    def check_stuck_processes
      puts "\n🔄 Stuck Processes:"
      stuck = `pgrep -f 'xcodebuild|xctest' 2>/dev/null`.strip
      stuck_pids = stuck.split.reject do |pid|
        # Get full command to check what this process actually is
        cmd = `ps -p #{pid} -o command= 2>/dev/null`.strip
        # Exclude: system processes, MCP servers, and npm processes
        cmd.include?('testmanagerd') ||
          cmd.include?('/usr/libexec/') ||
          cmd.include?('mcp') ||
          cmd.include?('npm exec')
      end
      if stuck_pids.empty?
        puts '  ✅ No stuck test processes'
      else
        puts "  ⚠️  Found stuck processes: #{stuck_pids.join(', ')}"
        puts '     Run: killall -9 xcodebuild xctest'
      end
    end

    def check_derived_data
      puts "\n📁 DerivedData:"
      dd_path = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*")
      dd_dirs = Dir.glob(dd_path)
      if dd_dirs.any?
        total_size = dd_dirs.map { |d| `du -sh "#{d}" 2>/dev/null`.split.first }.join(', ')
        puts "  📦 Size: #{total_size}"
        puts '     Clean with: ./Scripts/SaneMaster.rb clean --nuclear'
      else
        puts '  ✅ No DerivedData cache'
      end
    end

    def scan_for_missing_identifiers(swift_files)
      missing_count = 0
      ui_components = %w[Button TextField Toggle Slider Picker]

      swift_files.uniq.each do |path|
        next unless File.exist?(path)

        content = File.read(path)
        ui_components.each do |component|
          last_pos = 0
          while (start_idx = content.index(/\b#{component}\s*\(/, last_pos))
            context = content[start_idx..(start_idx + 3000)] || ''
            unless context.include?('accessibilityIdentifier')
              puts "  ⚠️  Potential missing ID: #{component} in #{File.basename(path)} (near line #{content[0..start_idx].count("\n") + 1})"
              missing_count += 1
            end
            last_pos = start_idx + 1
          end
        end
      end

      missing_count
    end

    def extract_ui_identifiers
      identifiers = Set.new

      identifiers_file = File.join(project_app_dir, 'Core/Testing/AccessibilityIdentifiers.swift')
      if File.exist?(identifiers_file)
        content = File.read(identifiers_file)
        content.scan(/static let \w+ = ["']([^"']+)["']/) { |match| identifiers << match[0] }
      end

      Dir.glob(File.join(Dir.pwd, '**/*.swift')).each do |file|
        next if file.include?('/Tests/') ||
                file.include?('/UITests/') ||
                file.include?('/Mocks/') ||
                file.include?('/.build/') ||
                file.include?('/DerivedData/') ||
                file.include?('/docs/') ||
                file.include?('AccessibilityIdentifiers.swift')
        next unless File.exist?(file)

        content = File.read(file)
        content.scan(/\.accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
        content.scan(/accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
      end

      identifiers.to_a
    end

    def extract_test_references
      return Set.new.to_a unless ui_tests_present?

      identifiers = Set.new
      Dir.glob(File.join(project_ui_tests_dir, '**/*.swift')).each do |file|
        next unless File.exist?(file)

        content = File.read(file)
        content.scan(/accessibilityIdentifier\(["']([^"']+)["']\)/) do |match|
          value = match[0]
          identifiers << value if looks_like_custom_ui_identifier?(value)
        end
        content.scan(/\bapp\.(?!launchEnvironment\b)(?!launchArguments\b)\w+(?:\.\w+)*\s*\[\s*["']([^"']+)["']\s*\]/) do |match|
          value = match[0]
          identifiers << value if looks_like_custom_ui_identifier?(value)
        end
      end

      identifiers.to_a
    end

    def looks_like_custom_ui_identifier?(value)
      value.match?(/\A[a-z0-9]+(?:[._-][A-Za-z0-9]+)+\z/)
    end

    def find_references_in_files(identifier)
      return [] unless ui_tests_present?

      files = []
      Dir.glob(File.join(project_ui_tests_dir, '**/*.swift')).each do |file|
        next unless File.exist?(file)
        next unless File.read(file).include?(identifier)

        files << file
      end
      files
    end

    def ui_tests_present?
      Dir.exist?(project_ui_tests_dir)
    end

    def runtime_smoke_coverage_present?
      File.exist?(File.join(Dir.pwd, 'Scripts', 'live_zone_smoke.rb')) &&
        File.exist?(File.join(Dir.pwd, 'Tests', 'RuntimeGuardXCTests.swift'))
    end

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
      core_modules = %w[state_manager.rb coordinator.rb hook_registry.rb]
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
        'SaneSync' => '~/SaneApps/apps/SaneSync',
        'SaneVideo' => '~/SaneApps/apps/SaneVideo',
        'SaneClip' => '~/SaneApps/apps/SaneClip',
        'SaneHosts' => '~/SaneApps/apps/SaneHosts',
        'SaneClick' => '~/SaneApps/apps/SaneClick',
        'SaneAI' => '~/SaneApps/apps/SaneAI'
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
