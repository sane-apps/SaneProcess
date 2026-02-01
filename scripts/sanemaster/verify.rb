# frozen_string_literal: true

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
      if test_targets_disabled?
        handle_disabled_tests(args)
        return
      end

      clean_first = args.include?('--clean')
      include_ui = args.include?('--ui')
      timeout = args.include?('--timeout') ? args[args.index('--timeout') + 1].to_i : 180

      clean([]) if clean_first

      puts '🔨 --- [ SANEMASTER VERIFY ] ---'
      puts 'Building and running tests with progress monitoring...'
      puts "⏱️  Timeout: #{timeout}s | Auto-handling permissions: ✅"
      puts include_ui ? '📱 Including UI tests (use --ui flag)' : '⚡ Unit tests only (use --ui to include UI tests)'
      puts ''

      permission_monitor_pid = grant_test_permissions
      validate_test_references unless args.include?('--skip-test-validation')

      begin
        result = run_tests_with_progress(timeout_seconds: timeout, include_ui: include_ui)

        if result[:success]
          puts "\n✅ Tests passed! (#{result[:tests_run]} tests, #{result[:duration]}s)"
          # Suggest recording patterns after successful test run
          suggest_memory_record if respond_to?(:suggest_memory_record)
        else
          puts "\n❌ Tests failed. Running diagnostics..."
          puts "⚠️  Test run timed out after #{timeout}s" if result[:timeout]
          diagnose(nil, dump: true)
        end
      ensure
        cleanup_test_processes(permission_monitor_pid)
      end
    end

    def clean(args)
      nuclear = args.include?('--nuclear')

      puts '🧹 --- [ SANEMASTER CLEAN ] ---'

      if nuclear
        puts '⚠️  NUCLEAR CLEAN - Removing all build artifacts...'
        # DerivedData
        system('rm -rf ~/Library/Developer/Xcode/DerivedData/__PROJECT_NAME__-*')
        system('rm -rf .derivedData')
        # Asset catalog caches (critical for icon changes!)
        system('rm -rf ~/Library/Caches/com.apple.dt.Xcode/')
        # Module cache
        system('rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex')
        # Test output
        system('rm -rf fastlane/test_output')
        system('rm -rf /tmp/__PROJECT_NAME__*')
        # CRITICAL: Also clear Ruby's actual tmpdir (which differs from /tmp on macOS)
        # Dir.tmpdir returns /var/folders/.../T/ not /tmp
        diagnostics_dir = File.join(Dir.tmpdir, '__PROJECT_NAME___Diagnostics')
        FileUtils.rm_rf(diagnostics_dir)
        # Clear any test project leftovers (non-sandboxed app uses Application Support)
        system('rm -rf ~/Library/Application\\ Support/__PROJECT_NAME__/__PROJECT_NAME___Test_Projects 2>/dev/null')
        system('rm -f test_output.txt')
        # Regenerate project after nuclear clean
        puts '🔄 Regenerating Xcode project...'
        system('xcodegen generate 2>&1')
        puts '✅ Nuclear clean complete.'
      else
        puts 'Standard clean...'
        system('xcodebuild clean -scheme __PROJECT_NAME__ 2>&1 > /dev/null')
        system('rm -f test_output.txt')
        puts '✅ Clean complete.'
      end
    end

    def reset_permissions
      puts '🔐 --- [ SANEMASTER RESET PERMISSIONS ] ---'
      puts "Resetting TCC privacy permissions for #{@bundle_id}..."

      %w[Camera Microphone ScreenRecording].each do |service|
        print "  Resetting #{service}... "
        system("tccutil reset #{service} #{@bundle_id} 2>&1 > /dev/null")
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
      if system('bundle exec fastlane lint')
        puts '✅ Linting complete.'
      else
        puts '❌ Linting failed or SwiftLint not found.'
      end
    end

    def run_quality_report
      puts '📊 --- [ SANEMASTER QUALITY ] ---'
      if system('bundle exec fastlane quality')
        puts '✅ Quality report generation complete.'
      else
        puts '❌ Quality report generation failed.'
      end
    end

    def validate_test_references
      puts '🔍 --- [ VALIDATE TEST REFERENCES ] ---'
      puts 'Checking that all test references match UI code...'

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

    def test_targets_disabled?
      project_yml = File.join(Dir.pwd, 'project.yml')
      return false unless File.exist?(project_yml)

      content = File.read(project_yml)
      content.include?('# Temporarily disabled test targets') ||
        (content.include?('# targets:') && content.include?('#   - __PROJECT_NAME__Tests'))
    end

    def handle_disabled_tests(args)
      puts '⚠️  Test targets are temporarily disabled due to SwiftUICore linker error (Xcode 16/macOS 26.2 bug)'
      puts '📝 Test files are preserved - they will be re-enabled when Xcode is updated'
      puts ''
      puts 'Building main app only (tests skipped)...'
      puts ''

      clean([]) if args.include?('--clean')

      puts '🔨 Building __PROJECT_NAME__ app...'
      result = system("xcodebuild -project __PROJECT_NAME__.xcodeproj -scheme __PROJECT_NAME__ -destination 'platform=macOS,arch=arm64' build")
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
        system("tccutil reset #{service} #{@bundle_id} 2>/dev/null")
      end

      permission_pid = nil
      script_path = File.join(__dir__, '..', 'grant_permissions.applescript')
      if File.exist?(script_path)
        permission_pid = Process.spawn("osascript '#{script_path}' __PROJECT_NAME__ > /dev/null 2>&1")
        Process.detach(permission_pid)
      end

      puts '✅'
      permission_pid
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

      system("pkill -f 'grant_permissions.applescript' 2>/dev/null")
      system("pkill -f 'xcodebuild test' 2>/dev/null")
      system("pkill -f '__PROJECT_NAME__.*test' 2>/dev/null")
      # Use -x for exact match to avoid killing xcodebuildmcp MCP server
      system('pkill -9 -x xcodebuild 2>/dev/null')
      sleep(0.5)
      system('killall -9 xcodebuild 2>/dev/null')
      system('killall -9 __PROJECT_NAME__ 2>/dev/null')

      puts '✅'
    end

    def run_tests_with_progress(timeout_seconds:, include_ui: false)
      require 'timeout'
      require 'open3'

      cmd = build_test_command(include_ui)
      state = { start_time: Time.now, tests_run: 0, swift_testing_total: 0, current_test: nil, last_update: Time.now,
                spinner_chars: ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'], spinner_idx: 0 }

      result = execute_with_logging(cmd, timeout_seconds) { |line| handle_progress_update(line, state) }

      print "\r"
      cleanup_test_processes

      # Use Swift Testing total if available (more accurate), otherwise fall back to counted tests
      total_tests = state[:swift_testing_total].positive? ? state[:swift_testing_total] : state[:tests_run]
      { success: result[:success], tests_run: total_tests, duration: (Time.now - state[:start_time]).to_i, timeout: result[:timeout] }
    end

    def build_test_command(include_ui)
      if include_ui
        # UI tests not yet implemented - warn and run unit tests only
        puts '  ⚠️  UI tests not available (__PROJECT_NAME__UITests directory does not exist)'
        puts '  📦 Running unit tests only...'
      end
      "xcodebuild test -scheme __PROJECT_NAME__ -destination 'platform=macOS,arch=arm64' -only-testing:__PROJECT_NAME__Tests 2>&1"
    end

    def execute_with_logging(cmd, timeout_seconds)
      success = false
      timed_out = false

      begin
        File.open('test_output.txt', 'w') do |log_file|
          puts '   📝 Full logs: test_output.txt'

          Timeout.timeout(timeout_seconds) do
            Open3.popen2e(cmd) do |stdin, stdout_err, wait_thr|
              stdin.close
              stdout_err.each_line do |line|
                line = line.chomp
                log_file.puts(line)
                yield(line) if block_given?
              end
              success = wait_thr.value.success?
            end
          end
        end
      rescue Timeout::Error
        timed_out = true
        handle_timeout(timeout_seconds)
      end

      { success: success && !timed_out, timeout: timed_out }
    end

    def handle_progress_update(line, state)
      case line
      # XCTest pattern: Test Case '-[TestClass testMethod]' started/passed
      # Swift Testing pattern: ✔ Test "test name" passed after X seconds
      when /Test Case.*'(.+)'/, /[✔✓] Test "(.+)" passed/
        state[:current_test] = ::Regexp.last_match(1)
        state[:tests_run] += 1
        elapsed = (Time.now - state[:start_time]).to_i
        spinner = state[:spinner_chars][state[:spinner_idx] % state[:spinner_chars].length]
        print "\r#{spinner} Running: #{state[:current_test]} (#{state[:tests_run]} tests, #{elapsed}s)    "
        state[:spinner_idx] += 1
        state[:last_update] = Time.now
      # Swift Testing summary: ✔ Test run with 27 tests in 4 suites passed
      when /[✔✓] Test run with (\d+) tests? in (\d+) suites? passed/
        state[:swift_testing_total] = ::Regexp.last_match(1).to_i
        suites = ::Regexp.last_match(2).to_i
        print "\r"
        puts "   ✅ Swift Testing: #{state[:swift_testing_total]} tests in #{suites} suites passed"
      # Swift Testing suite start: ◇ Suite "name" started
      when /◇ Suite "(.+)" started/
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

    def handle_timeout(timeout_seconds)
      puts "\n\n⏱️  TIMEOUT: Test run exceeded #{timeout_seconds}s"
      puts '   This usually means a test is stuck or waiting for user input'
      puts '🔪 Force killing all test processes...'

      3.times do |attempt|
        # Use -x for exact match to avoid killing xcodebuildmcp MCP server
        system("pkill -9 -f 'xcodebuild test' 2>/dev/null")
        system('pkill -9 -x xcodebuild 2>/dev/null')
        system('killall -9 xcodebuild 2>/dev/null')
        system('killall -9 __PROJECT_NAME__ 2>/dev/null')
        system('pkill -9 -x xctest 2>/dev/null')
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

      if File.exist?(test_video)
        size = File.size(test_video) / 1024 / 1024.0
        size_str = size >= 1 ? "#{size.round(1)}MB" : "#{(size * 1024).round}KB"
        puts "  ✅ #{test_asset_name} exists (#{size_str})"
      else
        puts "  ⚠️  #{test_asset_name} missing"
        puts '     Run: ./Scripts/SaneMaster.rb gen_assets'
      end
    end

    def check_xcodegen_sync
      puts "\n📁 XcodeGen Sync:"
      project_path = '__PROJECT_NAME__.xcodeproj/project.pbxproj'
      unless File.exist?(project_path)
        puts '  ❌ Project file missing. Run: xcodegen generate'
        return
      end

      puts '  ✅ Project file exists'
      begin
        require 'xcodeproj'
        project = Xcodeproj::Project.open('__PROJECT_NAME__.xcodeproj')
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
          cmd.include?('xcodebuildmcp') ||
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
      dd_path = File.expand_path('~/Library/Developer/Xcode/DerivedData/__PROJECT_NAME__-*')
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

      identifiers_file = '__PROJECT_NAME__/Core/Testing/AccessibilityIdentifiers.swift'
      if File.exist?(identifiers_file)
        content = File.read(identifiers_file)
        content.scan(/static let \w+ = ["']([^"']+)["']/) { |match| identifiers << match[0] }
      end

      Dir.glob('__PROJECT_NAME__/**/*.swift').each do |file|
        next if file.include?('/Tests/') || file.include?('/Mocks/') || file.include?('AccessibilityIdentifiers.swift')
        next unless File.exist?(file)

        content = File.read(file)
        content.scan(/\.accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
        content.scan(/accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
      end

      identifiers.to_a
    end

    def extract_test_references
      # UI tests not yet implemented - return empty set
      # When __PROJECT_NAME__UITests is created, this will scan for accessibility identifier references
      Set.new.to_a
    end

    def find_references_in_files(_identifier)
      # UI tests not yet implemented - return empty array
      []
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
      serena_config = File.expand_path('~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/serena/.mcp.json')
      if File.exist?(serena_config)
        content = File.read(serena_config)
        if content.include?('project-from-cwd')
          puts "  ✅ Serena: --project-from-cwd flag present"
          results[:passed] += 1
        else
          puts "  ⚠️  Serena: Missing --project-from-cwd (manual activation needed)"
          results[:warnings] += 1
        end
      else
        puts "  ⚠️  Serena config not found"
        results[:warnings] += 1
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
