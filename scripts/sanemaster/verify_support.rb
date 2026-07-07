# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'socket'
require 'time'
require 'tmpdir'

module SaneMasterModules
  # Verify execution/support helpers (split from verify.rb for Rule #10):
  # git snapshots, process cleanup, test command construction, runner
  # execution, progress parsing, result classification. Permission-monitoring
  # helpers live in verify_permissions.rb (further Rule #10 split).
  module Verify
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

    def verify_source_fingerprint(repo_path = Dir.pwd)
      root_out, root_status = Open3.capture2e('git', '-C', repo_path, 'rev-parse', '--show-toplevel')
      return 'unknown' unless root_status.success?

      root = root_out.strip
      parts = []
      [
        %w[rev-parse HEAD],
        %w[status --porcelain=v1 --untracked-files=all],
        %w[diff --binary],
        %w[diff --cached --binary]
      ].each do |command|
        out, = Open3.capture2e('git', '-C', root, *command)
        parts << out
      end
      Digest::SHA256.hexdigest(parts.join("\n---\n"))
    rescue StandardError
      'unknown'
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

    def assert_no_runtime_probe_lock_for_verify!
      lock_path = runtime_probe_lock_path_for_project
      return unless File.exist?(lock_path)

      lock_file = File.open(lock_path, runtime_probe_lock_open_flags)
      unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        detail = runtime_probe_lock_detail(lock_file)
        puts "\n❌ Verify refused because #{project_name} runtime QA is active."
        puts "   Lock: #{lock_path}"
        puts "   Owner: #{detail.empty? ? 'unknown' : detail}"
        puts '   Wait for the runtime smoke/QA lane to finish, then rerun verify.'
        exit 75
      end

      FileUtils.rm_f(lock_path)
    rescue Errno::ENOENT
      nil
    rescue Errno::ELOOP
      puts "\n❌ Verify refused because runtime QA lock path is a symlink: #{lock_path}"
      exit 75
    ensure
      if lock_file
        begin
          lock_file.flock(File::LOCK_UN)
        rescue StandardError
          nil
        end
        begin
          lock_file.close unless lock_file.closed?
        rescue StandardError
          nil
        end
      end
    end

    def runtime_probe_lock_detail(lock_file)
      lock_file.rewind
      lock_file.read.to_s.strip
    rescue StandardError
      ''
    end

    def runtime_probe_lock_open_flags
      flags = File::RDWR
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags
    end

    def runtime_probe_lock_path_for_project
      ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] ||
        ENV["#{project_name.upcase.gsub(/[^A-Z0-9]/, '_')}_RUNTIME_TARGET_LOCK_PATH"] ||
        File.join('/tmp', "#{project_name.downcase}_runtime_probe.lock")
    end

    def terminate_running_app_instance
      system('pkill', '-9', '-x', project_name, err: File::NULL)
      sleep(0.2)
    end

    def cleanup_test_processes(permission_monitor = nil)
      print '🧹 Cleaning up test processes... '

      permission_monitor_pid = permission_monitor.is_a?(Hash) ? permission_monitor[:pid] : permission_monitor
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
                swift_testing_failed: false,
                phase: nil, last_log_line: nil, last_log_at: nil,
                spinner_chars: ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'], spinner_idx: 0 }

      result = { success: true, timeout: false }
      commands.each_with_index do |entry, index|
        puts "▶️  #{entry[:label]}" if commands.length > 1
        result = execute_with_logging(entry[:cmd], timeout_seconds, append: index.positive?, label: entry[:label], progress_state: state) do |line|
          handle_progress_update(line, state)
        end
        break unless result[:success]
      end

      print "\r"
      cleanup_test_processes

      # Use Swift Testing total if available (more accurate), otherwise fall back to counted tests
      total_tests = [state[:swift_testing_total].to_i, state[:tests_run].to_i].max
      # A Swift Testing run failure is authoritative even when the runner exit
      # status or the XCTest phase summary looked clean (mixed-runner runs
      # previously reported "Tests passed!" over real Swift Testing failures).
      success = result[:success] && !state[:swift_testing_failed]
      { success: success, tests_run: total_tests, duration: (Time.now - state[:start_time]).to_i, timeout: result[:timeout] }
    end

    def verify_log_indicates_failure?(text)
      body = text.to_s
      return true if body.match?(/\*\* TEST FAILED \*\*/)
      return true if body.match?(/\*\* BUILD FAILED \*\*/)
      return true if body.match?(/error:\s+-\[[^\]]+\]/)
      return true if body.match?(/Executed \d+ tests?, with [1-9]\d* failures?/)
      return true if body.match?(/Executed \d+ tests?, with \d+ failures?, with [1-9]\d* unexpected/)
      # Swift Testing failure markers. Without these, a mixed XCTest/Swift
      # Testing run could read as a "clean pass" because the XCTest phase
      # summary said 0 failures while the Swift Testing run failed.
      return true if body.match?(/Test run with \d+ tests? in \d+ suites? failed/)
      return true if body.match?(/^Failing tests:/)

      false
    end

    def verify_log_success_summary_present?(text)
      body = text.to_s
      return true if body.include?('✅ Tests passed!')
      return true if body.match?(/Swift Testing:\s+\d+ tests .* passed/)
      return true if body.match?(/Test run with \d+ tests? in \d+ suites? passed/)
      return true if body.match?(/Test Suite 'All tests' passed/)
      return true if body.match?(/Executed \d+ tests?, with 0 failures/)

      false
    end

    def verify_log_only_has_benign_app_intents_failure?(text)
      body = text.to_s
      return false unless body.include?('com.apple.linkd.autoShortcut')

      sanitized = body.lines.reject do |line|
        line.include?('com.apple.linkd.autoShortcut') ||
          line.include?('Error registering app with intents framework') ||
          line.include?('Unable to get synchronousRemoteObjectProxy') ||
          line.include?('Unable to re-register with Process Instance Registry')
      end.join
      sanitized = sanitized.gsub(/^\*\* TEST FAILED \*\*\s*$/i, '')
      verify_log_success_summary_present?(sanitized) && !verify_log_indicates_failure?(sanitized)
    end

    def verify_log_indicates_success?(text)
      body = text.to_s
      return false if verify_log_indicates_failure?(body)

      verify_log_success_summary_present?(body)
    end

    def verify_evidence_strength(tests_run)
      tests_run.to_i.positive? ? 'tested' : 'build_only'
    end

    def verify_log_permission_prompt_signal?(text)
      text.to_s.downcase.match?(/manual grant|permission prompt|system settings|system preferences|tcc|accessibility|screen recording/)
    end

    def verify_log_timeout_signal?(text)
      text.to_s.downcase.match?(/\b(time(?:d)?\s*out|timeout)\b/)
    end

    def verify_log_build_failure_signal?(text, tests_run)
      body = text.to_s.downcase
      return true if body.match?(/\*\* build failed \*\*|swiftcompile|compileerror|linker command failed|ld:|command compileswift failed/)

      tests_run.to_i.zero? && body.match?(/error:/)
    end

    def verify_process_timeout_bucket(tests_run)
      if tests_run.to_i.zero?
        { bucket: 'pre_test_process_timeout', hint: 'verify process exceeded the configured timeout before tests were counted' }
      else
        { bucket: 'counted_test_process_timeout', hint: 'verify process exceeded the configured timeout after tests had started' }
      end
    end

    def verify_timeout_signal_bucket(tests_run)
      if tests_run.to_i.zero?
        { bucket: 'pre_test_timeout_signal', hint: 'runner emitted timeout-like text before tests were counted; sample logs before changing limits' }
      else
        { bucket: 'counted_test_timeout_signal', hint: 'tests ran and emitted timeout-like text; inspect the named test/resource before changing limits' }
      end
    end

    def verify_metric_host
      Socket.gethostname
    rescue StandardError
      nil
    end

    def classify_verify_result(success:, timeout:, tests_run:, log_text:)
      text = log_text.to_s.downcase
      count = tests_run.to_i
      return { bucket: 'weak_zero_test_success', hint: 'verify succeeded but counted zero tests' } if success && tests_run.to_i.zero?

      return verify_process_timeout_bucket(count) if text.strip.empty? && timeout
      return { bucket: 'runner_no_output', hint: 'test_output.txt was empty; runner likely failed before tests started' } if text.strip.empty?
      return { bucket: 'permission_prompt', hint: 'permission or TCC prompt interrupted verification' } if verify_log_permission_prompt_signal?(text)
      return verify_process_timeout_bucket(count) if timeout
      return { bucket: 'build_failure', hint: 'build or compile failure prevented useful test evidence' } if verify_log_build_failure_signal?(text, count)
      return { bucket: 'test_discovery_or_counting', hint: 'test discovery or parser counting failed before useful coverage ran' } if text.match?(/no tests found|0 tests|test discovery|no test bundles|missing test target/)
      return verify_timeout_signal_bucket(count) if verify_log_timeout_signal?(text)
      if count.positive? && verify_log_indicates_failure?(log_text) && !verify_log_only_has_benign_app_intents_failure?(log_text)
        return { bucket: 'test_failure', hint: 'tests ran and emitted explicit failure markers' }
      end
      if verify_log_indicates_failure?(log_text) && !verify_log_only_has_benign_app_intents_failure?(log_text)
        return { bucket: 'test_failure', hint: 'tests ran and emitted explicit failure markers' }
      end

      count.zero? ? { bucket: 'unknown_zero_test_failure', hint: 'zero tests were counted but no known signature matched' } : { bucket: 'unknown_failure', hint: 'failure did not match a known verify bucket' }
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

      issues = script_only_verify_registry_issues
      if issues.any?
        puts '❌ SaneProcess script test registry is incomplete:'
        issues.each { |issue| puts "   - #{issue}" }
        exit 1
      end

      script_only_verify_required_entries.map do |entry|
        { label: entry.fetch('label'), cmd: entry.fetch('cmd') }
      end
    end

    def script_only_test_registry_path
      File.expand_path('../test_registry.json', __dir__)
    end

    def script_only_test_registry
      JSON.parse(File.read(script_only_test_registry_path))
    end

    def script_only_test_entries
      script_only_test_registry.fetch('tests')
    end

    def script_only_verify_required_entries
      script_only_test_entries.select { |entry| entry['status'] == 'required' }
    end

    def script_only_verify_registry_issues(registry = script_only_test_registry)
      entries = registry['tests']
      return ['registry is missing tests array'] unless entries.is_a?(Array)

      issues = []
      by_path = {}
      entries.each_with_index do |entry, index|
        unless entry.is_a?(Hash)
          issues << "tests[#{index}] is not an object"
          next
        end

        path = entry['path'].to_s
        status = entry['status'].to_s
        issues << "tests[#{index}] is missing path" if path.empty?
        issues << "tests[#{index}] has invalid status #{status.inspect}" unless %w[required manual support].include?(status)
        issues << "duplicate registry entry: #{path}" if by_path.key?(path)
        by_path[path] = entry unless path.empty?

        next unless status == 'required'

        cmd = entry['cmd']
        issues << "#{path} is required but has no cmd array" unless cmd.is_a?(Array) && cmd.any?
        issues << "#{path} is required but has no label" if entry['label'].to_s.strip.empty?
      end

      discovered = discovered_script_test_paths
      registered = by_path.keys
      (discovered - registered).each { |path| issues << "unregistered test-like file: #{path}" }
      (registered - discovered).each do |path|
        next if File.exist?(path)

        issues << "registered test file is missing: #{path}"
      end

      issues
    end

    def discovered_script_test_paths
      paths = Dir.glob('scripts/**/*_test.rb') + Dir.glob('scripts/**/*_test.py')
      paths.sort.uniq
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
      args.concat(['-scheme', project_scheme, '-destination', resolved_xcodebuild_destination(project_unit_destination)])
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
      args.concat(['-scheme', project_ui_scheme, '-destination', resolved_xcodebuild_destination(project_ui_destination)])
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

    def execute_with_logging(cmd, timeout_seconds, append: false, label: nil, progress_state: nil)
      success = false
      timed_out = false

      File.open('test_output.txt', append ? 'a' : 'w') do |log_file|
        puts '   📝 Full logs: test_output.txt'
        log_file.puts("\n=== #{label} ===") if label

        Open3.popen2e(*cmd) do |stdin, stdout_err, wait_thr|
          stdin.close
          progress_state ||= {
            tests_run: 0,
            swift_testing_total: 0,
            phase: 'starting',
            last_log_line: nil,
            last_log_at: nil
          }
          heartbeat_context = {
            label: label,
            log_path: 'test_output.txt',
            started_at: Time.now,
            last_output_at: Time.now,
            state: progress_state
          }

          reader = Thread.new do
            stdout_err.each_line do |line|
              line = line.chomp
              line = line.scrub('?') unless line.valid_encoding?
              log_file.puts(line)
              log_file.flush
              heartbeat_context[:last_output_at] = Time.now
              if block_given?
                yield(line)
              else
                record_verify_progress_line(line, heartbeat_context[:state])
              end
            end
          rescue IOError
            nil
          end

          if wait_for_process_with_timeout(wait_thr, timeout_seconds, heartbeat: heartbeat_context)
            success = wait_thr.value.success?
          else
            timed_out = true
            handle_timeout(timeout_seconds, wait_thr.pid)
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
        if verify_log_only_has_benign_app_intents_failure?(log_output)
          puts '   ℹ️  Test log only contains known App Intents autoShortcut diagnostics after a clean pass; treating verify as successful.'
          success = true
        elsif verify_log_indicates_failure?(log_output)
          puts '   ℹ️  Test log contains explicit failure markers; preserving the non-zero verify result.'
        elsif verify_log_indicates_success?(log_output)
          puts '   ℹ️  Test log shows a clean pass despite a non-zero runner exit; treating verify as successful.'
          success = true
        end
      end

      { success: success && !timed_out, timeout: timed_out }
    end

    def wait_for_process_with_timeout(wait_thr, timeout_seconds, heartbeat: nil)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds.to_f
      last_heartbeat_at = Time.at(0)

      loop do
        return true unless wait_thr.alive?
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        if heartbeat && verify_should_emit_heartbeat?(heartbeat[:last_output_at], last_heartbeat_at)
          print "\r"
          puts verify_heartbeat_line(heartbeat.merge(pid: wait_thr.pid, deadline: deadline))
          last_heartbeat_at = Time.now
        end

        sleep(0.25)
      end
    end

    def verify_heartbeat_seconds
      raw = ENV.fetch('SANEMASTER_VERIFY_HEARTBEAT_SECONDS', '15').to_i
      raw.positive? ? raw : 15
    rescue StandardError
      15
    end

    def verify_should_emit_heartbeat?(last_output_at, last_heartbeat_at)
      return false if ENV['SANEMASTER_VERIFY_HEARTBEAT'] == '0'

      quiet_seconds = verify_heartbeat_seconds
      now = Time.now
      (now - last_output_at) >= quiet_seconds && (now - last_heartbeat_at) >= quiet_seconds
    end

    def verify_heartbeat_line(context)
      state = context.fetch(:state)
      log_path = context.fetch(:log_path, 'test_output.txt')
      elapsed = (Time.now - context.fetch(:started_at)).to_i
      remaining = [(context.fetch(:deadline) - Process.clock_gettime(Process::CLOCK_MONOTONIC)).ceil, 0].max
      log_size = File.exist?(log_path) ? File.size(log_path) : 0
      last_log_age = state[:last_log_at] ? "#{[(Time.now - state[:last_log_at]).to_i, 0].max}s" : 'none'
      phase = state[:phase] || 'starting'
      tests = [state[:swift_testing_total].to_i, state[:tests_run].to_i].max
      last_line = verify_compact_log_line(state[:last_log_line])
      "   … verify heartbeat: label=#{context[:label] || 'tests'} pid=#{context[:pid]} elapsed=#{elapsed}s remaining=#{remaining}s phase=#{phase} tests=#{tests} log=#{log_path} size=#{log_size}B last_log_age=#{last_log_age} last=\"#{last_line}\""
    end

    def verify_compact_log_line(line)
      value = line.to_s.gsub(/\s+/, ' ').strip
      return 'none' if value.empty?

      value.length > 160 ? "#{value[0, 157]}..." : value
    end

    def handle_progress_update(line, state)
      record_verify_progress_line(line, state)

      case line
      # XCTest pattern: only completed test case lines count; "started" lines are progress, not evidence.
      # Swift Testing pattern can be prefixed by ✓/✔ or private-use glyphs in Xcode logs.
      when /Test Case.*'(.+)'\s+(?:passed|failed)/, /(?:[✔✓]\s+)?Test "(.+)" passed/
        state[:current_test] = ::Regexp.last_match(1)
        state[:tests_run] += 1
        elapsed = (Time.now - state[:start_time]).to_i
        spinner = state[:spinner_chars][state[:spinner_idx] % state[:spinner_chars].length]
        print "\r#{spinner} Running: #{state[:current_test]} (#{state[:tests_run]} tests, #{elapsed}s)    "
        state[:spinner_idx] += 1
        state[:last_update] = Time.now
      # Swift Testing run failure: authoritative even when the XCTest phase
      # and the runner exit status look clean (mixed-runner masking bug).
      when /Test run with (\d+) tests? in (\d+) suites? failed/
        state[:swift_testing_total] = [state[:swift_testing_total].to_i, ::Regexp.last_match(1).to_i].max
        state[:swift_testing_failed] = true
        print "\r"
        puts "   ❌ Swift Testing: run failed (#{::Regexp.last_match(1)} tests in #{::Regexp.last_match(2)} suites)"
      # Swift Testing summary: may appear with or without explicit checkmark glyph.
      when /(?:[✔✓]\s+)?Test run with (\d+) tests? in (\d+) suites? passed/
        state[:swift_testing_total] = ::Regexp.last_match(1).to_i
        suites = ::Regexp.last_match(2).to_i
        print "\r"
        puts "   ✅ Swift Testing: #{state[:swift_testing_total]} tests in #{suites} suites passed"
      when /RESULTS:\s+(\d+)\/(\d+)\s+passed/i,
           /Results:\s+(\d+)\/(\d+)\s+passed/i,
           /\bPASS\s+(\d+)\/(\d+)\b/i
        total = ::Regexp.last_match(2).to_i
        state[:tests_run] += total
        print "\r"
        puts "   ✅ Script tests: #{total} reported"
      when /Ran\s+(\d+)\s+tests?\b/i
        total = ::Regexp.last_match(1).to_i
        state[:tests_run] += total
        print "\r"
        puts "   ✅ Script tests: #{total} reported"
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

    def record_verify_progress_line(line, state)
      state[:last_log_line] = line
      state[:last_log_at] = Time.now
      state[:phase] =
        case line
        when /Resolve Package Graph|Fetching from|Creating working copy|Checking out|Cloning/i
          'package-resolution'
        when /SwiftCompile|CompileSwift|Compiling|Ld |Linking|Copy /i
          'build'
        when /Test Suite|Test Case|Testing started|Suite "|Running:|Test run with/i
          'test'
        when /BUILD FAILED|error:/i
          'failure'
        when /BUILD SUCCEEDED/i
          'build-complete'
        else
          state[:phase] || 'runner'
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
  end
end
