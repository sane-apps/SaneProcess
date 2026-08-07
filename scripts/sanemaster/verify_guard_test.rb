#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'ci_helpers'
require_relative 'verify'

class VerifyHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Verify
  include SaneMasterModules::CIHelpers
end

def init_git_repo(path)
  system('git', 'init', '-q', path) or raise 'git init failed'
  system('git', '-C', path, 'config', 'user.name', 'Codex Test') or raise 'git config user.name failed'
  system('git', '-C', path, 'config', 'user.email', 'codex@example.com') or raise 'git config user.email failed'
  File.write(File.join(path, 'tracked.txt'), "baseline\n")
  system('git', '-C', path, 'add', 'tracked.txt') or raise 'git add failed'
  system('git', '-C', path, 'commit', '-q', '-m', 'baseline') or raise 'git commit failed'
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

def with_held_runtime_lock(lock_path)
  pid = fork do
    lock_file = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
    lock_file.flock(File::LOCK_EX)
    lock_file.rewind
    lock_file.truncate(0)
    lock_file.write("pid=#{Process.pid} started=2026-06-18T00:00:00Z command=qa-runtime-smoke\n")
    lock_file.flush
    trap('TERM') { exit 0 }
    sleep
  ensure
    begin
      lock_file&.flock(File::LOCK_UN)
    rescue StandardError
      nil
    end
    begin
      lock_file&.close unless lock_file&.closed?
    rescue StandardError
      nil
    end
  end

  deadline = Time.now + 2
  until File.exist?(lock_path) && File.read(lock_path).include?("pid=#{pid}")
    raise 'timed out waiting for held runtime lock' if Time.now >= deadline

    sleep 0.01
  end
  yield pid
ensure
  if pid
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end
end

def with_published_hardlink_runtime_lock(lock_path)
  pid = fork do
    temp_path = File.join(File.dirname(lock_path), ".#{File.basename(lock_path)}.#{Process.pid}.tmp")
    lock_file = File.open(temp_path, File::RDWR | File::CREAT | File::EXCL, 0o600)
    lock_file.flock(File::LOCK_EX)
    lock_file.write("pid=#{Process.pid} started=2026-06-18T00:00:00Z command=qa-runtime-smoke\n")
    lock_file.flush
    File.link(temp_path, lock_path)
    FileUtils.rm_f(temp_path)
    trap('TERM') { exit 0 }
    sleep
  ensure
    begin
      lock_file&.flock(File::LOCK_UN)
    rescue StandardError
      nil
    end
    begin
      lock_file&.close unless lock_file&.closed?
    rescue StandardError
      nil
    end
  end

  deadline = Time.now + 2
  until File.exist?(lock_path) && File.read(lock_path).include?("pid=#{pid}")
    raise 'timed out waiting for published runtime lock' if Time.now >= deadline

    sleep 0.01
  end
  yield pid
ensure
  if pid
    begin
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end
  FileUtils.rm_f(lock_path)
end

exit(run_tests('SaneMaster Verify Repo Drift Tests') do
  subject = VerifyHarness.new

  test_category('Launch Services cleanup') do
    test('verify runs scoped Launch Services hygiene for a known SaneApp') do
      harness = VerifyHarness.new
      harness.define_singleton_method(:project_name) { 'SaneClip' }
      calls = []
      harness.define_singleton_method(:system) do |*args, **_kwargs|
        calls << args
        true
      end

      assert(harness.send(:cleanup_launch_services_after_verify))
      hygiene_call = calls.find { |args| args.include?('--launch-services-only') }
      assert(hygiene_call, 'verify must clean XCTest Launch Services registrations')
      assert_includes(hygiene_call, 'SaneClip')
      true
    end

    test('verify skips Launch Services hygiene for unrelated projects') do
      harness = VerifyHarness.new
      harness.define_singleton_method(:project_name) { 'ExampleApp' }
      harness.define_singleton_method(:system) { |*_args| raise 'unexpected cleanup command' }

      assert(harness.send(:cleanup_launch_services_after_verify))
      true
    end
  end

  test_category('Verify repo drift guard') do
    test('reports no introduced drift for a clean repo') do
      Dir.mktmpdir('verify-guard-clean-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_eq(report[:introduced], [])
      end
      true
    end

    test('reports newly modified tracked files') do
      Dir.mktmpdir('verify-guard-modified-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        File.write(File.join(dir, 'tracked.txt'), "changed\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_includes(report[:introduced], ' M tracked.txt')
      end
      true
    end

    test('reports newly introduced untracked files') do
      Dir.mktmpdir('verify-guard-untracked-') do |dir|
        init_git_repo(dir)
        before = subject.send(:git_status_snapshot, dir)
        File.write(File.join(dir, 'new.txt'), "hello\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_includes(report[:introduced], '?? new.txt')
      end
      true
    end

    test('does not report baseline dirt that already existed before verify') do
      Dir.mktmpdir('verify-guard-baseline-') do |dir|
        init_git_repo(dir)
        tracked = File.join(dir, 'tracked.txt')
        File.write(tracked, "already dirty\n")
        before = subject.send(:git_status_snapshot, dir)
        File.write(tracked, "still dirty\n")
        report = subject.send(:verify_repo_dirt_report, before_snapshot: before, repo_path: dir)
        assert_eq(report[:introduced], [])
      end
      true
    end
  end

  test_category('Runtime probe lock guard') do
    test('verify checks runtime probe lock before preflight can kill the app') do
      source = File.read(File.expand_path('verify.rb', __dir__))
      lock_index = source.index('assert_no_runtime_probe_lock_for_verify!')
      preflight_index = source.index('run_verify_preflight')

      assert(lock_index, 'verify should check runtime probe lock')
      assert(preflight_index, 'verify should still run normal preflight')
      assert(lock_index < preflight_index, 'runtime probe lock must be checked before verify preflight mutates app state')
      true
    end

    test('live runtime probe lock blocks verify') do
      Dir.mktmpdir('verify-runtime-lock-live-') do |dir|
        lock_path = File.join(dir, 'sanebar_runtime_probe.lock')
        fresh_subject = VerifyHarness.new
        fresh_subject.define_singleton_method(:project_name) { 'SaneBar' }

        previous = ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH']
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = lock_path
        with_held_runtime_lock(lock_path) do
          status = nil
          output = capture_stdout do
            begin
              fresh_subject.send(:assert_no_runtime_probe_lock_for_verify!)
            rescue SystemExit => e
              status = e.status
            end
          end

          assert_eq(status, 75)
          assert_includes(output, 'Verify refused because SaneBar runtime QA is active')
          assert_includes(output, lock_path)
        end
      ensure
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = previous
      end
      true
    end

    test('published hard-link runtime probe lock blocks verify') do
      Dir.mktmpdir('verify-runtime-lock-hardlink-') do |dir|
        lock_path = File.join(dir, 'sanebar_runtime_probe.lock')
        fresh_subject = VerifyHarness.new
        fresh_subject.define_singleton_method(:project_name) { 'SaneBar' }

        previous = ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH']
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = lock_path
        with_published_hardlink_runtime_lock(lock_path) do
          status = nil
          output = capture_stdout do
            begin
              fresh_subject.send(:assert_no_runtime_probe_lock_for_verify!)
            rescue SystemExit => e
              status = e.status
            end
          end

          assert_eq(status, 75)
          assert_includes(output, 'Verify refused because SaneBar runtime QA is active')
          assert(File.exist?(lock_path), 'verify must not unlink a live hard-link-published runtime lock')
        end
      ensure
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = previous
      end
      true
    end

    test('default runtime probe lock path matches project QA lock') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:project_name) { 'SaneBar' }

      assert_eq(fresh_subject.send(:runtime_probe_lock_path_for_project), '/tmp/sanebar_runtime_probe.lock')
      true
    end

    test('stale runtime probe lock is removed before verify') do
      Dir.mktmpdir('verify-runtime-lock-stale-') do |dir|
        lock_path = File.join(dir, 'sanebar_runtime_probe.lock')
        File.write(lock_path, "pid=999999 started=2026-06-18T00:00:00Z command=qa-runtime-smoke\n")
        fresh_subject = VerifyHarness.new
        fresh_subject.define_singleton_method(:project_name) { 'SaneBar' }

        previous = ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH']
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = lock_path
        fresh_subject.send(:assert_no_runtime_probe_lock_for_verify!)

        assert(!File.exist?(lock_path), 'stale runtime probe lock should not block future verify runs')
      ensure
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = previous
      end
      true
    end

    test('spoofed live pid without held lock is treated as stale') do
      Dir.mktmpdir('verify-runtime-lock-spoofed-') do |dir|
        lock_path = File.join(dir, 'sanebar_runtime_probe.lock')
        File.write(lock_path, "pid=#{Process.pid} started=2026-06-18T00:00:00Z command=qa-runtime-smoke\n")
        fresh_subject = VerifyHarness.new
        fresh_subject.define_singleton_method(:project_name) { 'SaneBar' }

        previous = ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH']
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = lock_path
        fresh_subject.send(:assert_no_runtime_probe_lock_for_verify!)

        assert(!File.exist?(lock_path), 'unlocked spoofed runtime probe lock should be removed')
      ensure
        ENV['SANEMASTER_RUNTIME_PROBE_LOCK_PATH'] = previous
      end
      true
    end
  end

  test_category('Script-only verify fallback') do
    test('does not invent a fake xcodeproj path when none exists') do
      Dir.mktmpdir('verify-base-no-xcodeproj-') do |dir|
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          assert_eq(fresh_subject.send(:project_xcodeproj), nil)
        end
      end
      true
    end

    test('uses the scripted SaneProcess verify suite when no Xcode project exists') do
      subject.define_singleton_method(:project_name) { 'SaneProcess' }
      subject.define_singleton_method(:project_scheme) { 'SaneProcess' }
      subject.define_singleton_method(:project_xcodeproj) { nil }
      subject.define_singleton_method(:project_workspace) { nil }
      subject.define_singleton_method(:workspace_usable_for_scheme?) { |_scheme = nil| false }
      subject.define_singleton_method(:project_test_target) { 'SaneProcessTests' }
      subject.define_singleton_method(:package_path_for_test_target) { |_target| nil }

      commands = subject.send(:script_only_verify_commands)

      assert(commands, 'expected scripted verify commands')
      assert_eq(commands.first[:label], 'SaneProcess hook integration tests')
      assert_eq(commands.first[:cmd].first, 'ruby')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/sanemaster/gate_review_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/sanemaster/process_metrics_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/sanemaster/near_miss_review_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/sanemaster/verify_failure_review_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/sanemaster/universal_control_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'ruby scripts/mini/mini_gui_run_test.rb')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'python3 -B scripts/automation/status_crossref_test.py')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'python3 -B scripts/automation/email_delivery_test.py')
      assert_includes(commands.map { |entry| entry[:cmd].join(' ') }, 'python3 -B scripts/automation/listing_actions_test.py')
      true
    end

    test('requires an explicit registry decision for every script test-like file') do
      issues = subject.send(:script_only_verify_registry_issues)

      assert_eq(issues, [])
      registered_paths = subject.send(:script_only_test_entries).map { |entry| entry.fetch('path') }
      assert_includes(registered_paths, 'scripts/hooks/test/hook_test.rb')
      assert_includes(registered_paths, 'scripts/sane_test.rb')
      true
    end

    test('infra script-only verify does not reset protected folder permissions') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:saneprocess_config) { { 'type' => 'infra' } }
      fresh_subject.define_singleton_method(:project_xcodeproj) { nil }
      fresh_subject.define_singleton_method(:project_workspace) { nil }

      services = fresh_subject.send(:verify_permission_services)

      assert_includes(services, 'Camera')
      assert(!services.include?('SystemPolicyDownloadsFolder'), 'infra verify should not reset Downloads access for the Ruby interpreter')
      assert(!services.include?('SystemPolicyDesktopFolder'), 'infra verify should not reset Desktop access for the Ruby interpreter')
      assert(!services.include?('SystemPolicyDocumentsFolder'), 'infra verify should not reset Documents access for the Ruby interpreter')
      true
    end

    test('app verify still resets protected folder permissions') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:saneprocess_config) { { 'type' => 'app' } }
      fresh_subject.define_singleton_method(:project_xcodeproj) { 'Example.xcodeproj' }
      fresh_subject.define_singleton_method(:project_workspace) { nil }

      services = fresh_subject.send(:verify_permission_services)

      assert_includes(services, 'SystemPolicyDownloadsFolder')
      assert_includes(services, 'SystemPolicyDesktopFolder')
      assert_includes(services, 'SystemPolicyDocumentsFolder')
      true
    end
  end

  test_category('Strict verify contract') do
    test('strictly parses verify flags and rejects unknown duplicate conflicting or invalid arguments') do
      parsed = subject.send(
        :parse_verify_args,
        %w[--ui --clean --signed-tests --no-grant-permissions --skip-test-validation --quiet --timeout 45],
        default_timeout: 300
      )
      assert_eq(parsed[:include_ui], true)
      assert_eq(parsed[:ui_only], false)
      assert_eq(parsed[:timeout], 45)
      assert_eq(parsed[:quiet], true)

      invalid_sets = [
        ['--unknown'],
        ['--clean', '--clean'],
        ['--ui', '--ui-only'],
        ['--timeout'],
        ['--timeout', '0'],
        ['--timeout', '-1'],
        ['--timeout', 'abc'],
        ['--timeout', '10', '--timeout', '20']
      ]
      invalid_sets.each do |arguments|
        error = nil
        begin
          subject.send(:parse_verify_args, arguments, default_timeout: 300)
        rescue ArgumentError => e
          error = e
        end
        assert(error, "expected #{arguments.inspect} to be rejected")
      end

      invalid_default = nil
      begin
        subject.send(:parse_verify_args, [], default_timeout: 0)
      rescue ArgumentError => e
        invalid_default = e
      end
      assert(invalid_default, 'nonpositive configured timeout must be rejected')
      true
    end

    test('uses a project verify timeout override when no CLI timeout is supplied') do
      Dir.mktmpdir('verify-project-timeout-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: Example
            type: ios_app
            tests:
              verify_timeout_seconds: 1800
          YAML
        )
        had_env_timeout = ENV.key?('SANEMASTER_VERIFY_TIMEOUT')
        previous_env_timeout = ENV.delete('SANEMASTER_VERIFY_TIMEOUT')
        begin
          Dir.chdir(dir) do
            fresh_subject = VerifyHarness.new
            configured_timeout = fresh_subject.send(
              :config_value,
              %w[tests verify_timeout_seconds],
              'SANEMASTER_VERIFY_TIMEOUT',
              300
            ).to_i
            parsed = fresh_subject.send(:parse_verify_args, [], default_timeout: configured_timeout)

            assert_eq(configured_timeout, 1800)
            assert_eq(parsed[:timeout], 1800)
          end
        ensure
          if had_env_timeout
            ENV['SANEMASTER_VERIFY_TIMEOUT'] = previous_env_timeout
          else
            ENV.delete('SANEMASTER_VERIFY_TIMEOUT')
          end
        end
      end
      true
    end

    test('assigns a unique result bundle and requested scope to every Xcode phase') do
      Dir.mktmpdir('verify-result-bundles-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneVideo
            type: macos_app
            scheme: SaneVideo
            project: SaneVideo.xcodeproj
            tests:
              unit_target: SaneVideoTests
              ui_target: SaneVideoUITests
          YAML
        )
        Dir.mkdir(File.join(dir, 'SaneVideoUITests'))
        Dir.chdir(dir) do
          phases = VerifyHarness.new.send(:build_test_commands, true)
          paths = phases.map { |entry| entry[:xcresult_path] }

          assert_eq(phases.map { |entry| entry[:test_selector] }, %w[SaneVideoTests SaneVideoUITests])
          assert_eq(paths.uniq.length, 2)
          phases.each do |entry|
            index = entry[:cmd].index('-resultBundlePath')
            assert(index, 'every xcodebuild test phase needs -resultBundlePath')
            assert_eq(entry[:cmd][index + 1], entry[:xcresult_path])
          end
        end
      end
      true
    end

    test('rejects missing xcresult evidence and scope mismatches through the shared parser') do
      Dir.mktmpdir('verify-xcresult-proof-') do |dir|
        missing = subject.send(:verify_xcresult_phase_summary, File.join(dir, 'missing.xcresult'), 'SaneVideoTests')
        assert_eq(missing[:ok], false)
        assert_includes(missing[:error], 'not created')

        bundle = File.join(dir, 'unit.xcresult')
        FileUtils.mkdir_p(bundle)
        File.write(File.join(bundle, 'Info.plist'), 'fixture')
        subject.define_singleton_method(:monitor_test_result_summary) do |_path, selector|
          {
            ok: false,
            discovered_test_count: 1,
            passed_test_count: 1,
            matched_test_count: 0,
            error: "xcresult does not contain a passed test matching #{selector.inspect}"
          }
        end
        mismatch = subject.send(:verify_xcresult_phase_summary, bundle, 'SaneVideoTests')
        assert_eq(mismatch[:ok], false)
        assert_includes(mismatch[:error], 'SaneVideoTests')
      end
      true
    end

    test('shares one monotonic timeout budget across unit and UI Xcode phases') do
      Dir.mktmpdir('verify-global-deadline-') do |dir|
        bundles = %w[unit ui].map do |name|
          path = File.join(dir, "#{name}.xcresult")
          FileUtils.mkdir_p(path)
          File.write(File.join(path, 'Info.plist'), 'fixture')
          path
        end
        fresh_subject = VerifyHarness.new
        phases = [
          { label: 'unit', cmd: ['unit'], test_selector: 'AppTests', xcresult_path: bundles[0] },
          { label: 'ui', cmd: ['ui'], test_selector: 'AppUITests', xcresult_path: bundles[1] }
        ]
        times = [100.0, 100.0, 104.0]
        received_timeouts = []
        fresh_subject.define_singleton_method(:run_verify_preflight) {}
        fresh_subject.define_singleton_method(:build_test_commands) { |*_args, **_options| phases }
        fresh_subject.define_singleton_method(:verify_monotonic_now) { times.shift }
        fresh_subject.define_singleton_method(:execute_with_logging) do |_cmd, timeout, **_options|
          received_timeouts << timeout
          { success: true, timeout: false, exit_status: 0 }
        end
        fresh_subject.define_singleton_method(:monitor_test_result_summary) do |_path, _selector|
          { ok: true, discovered_test_count: 1, passed_test_count: 1, matched_test_count: 1, error: nil }
        end
        fresh_subject.define_singleton_method(:cleanup_test_processes) { |_monitor = nil| }

        result = fresh_subject.send(:run_tests_with_progress, timeout_seconds: 10, include_ui: true)

        assert_eq(received_timeouts, [10.0, 6.0])
        assert_eq(result[:success], true)
        assert_eq(result[:tests_run], 2)
      end
      true
    end

    test('script-only registered summary evidence stays log-counted without xcresult') do
      fresh_subject = VerifyHarness.new
      timeouts = []
      fresh_subject.define_singleton_method(:run_verify_preflight) {}
      fresh_subject.define_singleton_method(:build_test_commands) do |*_args, **_options|
        [
          { label: 'ruby test one', cmd: ['one'], script_only: true },
          { label: 'ruby test two', cmd: ['two'], script_only: true }
        ]
      end
      fresh_subject.define_singleton_method(:execute_with_logging) do |_cmd, timeout, **_options, &block|
        timeouts << timeout
        block.call('RESULTS: 1/1 passed')
        { success: true, timeout: false, exit_status: 0 }
      end
      fresh_subject.define_singleton_method(:cleanup_test_processes) { |_monitor = nil| }

      result = fresh_subject.send(:run_tests_with_progress, timeout_seconds: 10)

      assert_eq(timeouts, [10.0, 10.0])
      assert_eq(result[:success], true)
      assert_eq(result[:tests_run], 2)
      true
    end

    test('disabled Xcode test targets cannot turn a build-only result into verify success') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:project_name) { 'Example' }
      fresh_subject.define_singleton_method(:project_scheme) { 'Example' }
      fresh_subject.define_singleton_method(:xcodebuild_container_args) { ['-project', 'Example.xcodeproj'] }
      fresh_subject.define_singleton_method(:system) { |*_args| true }
      status = nil
      output = capture_stdout do
        begin
          fresh_subject.send(:handle_disabled_tests, clean: false)
        rescue SystemExit => e
          status = e.status
        end
      end

      assert_eq(status, 1)
      assert_includes(output, 'cannot pass without executed test evidence')
      true
    end
  end

  test_category('Project test destinations') do
    test('maps custom iPhone simulator aliases to a deterministic iPhone device type') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:ios_simulator_device_types) do
        [
          { name: 'iPhone SE (3rd generation)', identifier: 'phone-se', product_family: 'iPhone' },
          { name: 'iPhone 17 Pro', identifier: 'phone-pro', product_family: 'iPhone' },
          { name: 'iPad Pro 13-inch (M4)', identifier: 'ipad-pro', product_family: 'iPad' }
        ]
      end

      chosen = fresh_subject.send(:ios_simulator_device_type_for, 'SaneLot-iPhone')

      assert_eq(chosen[:identifier], 'phone-pro')
      assert_eq(chosen[:product_family], 'iPhone')
      true
    end

    test('maps custom iPad simulator aliases to an iPad device type') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:ios_simulator_device_types) do
        [
          { name: 'iPhone 17 Pro', identifier: 'phone-pro', product_family: 'iPhone' },
          { name: 'iPad Air 13-inch (M3)', identifier: 'ipad-air', product_family: 'iPad' },
          { name: 'iPad Pro 13-inch (M4)', identifier: 'ipad-pro', product_family: 'iPad' }
        ]
      end

      chosen = fresh_subject.send(:ios_simulator_device_type_for, 'SaneLot-iPad')

      assert_eq(chosen[:identifier], 'ipad-air')
      assert_eq(chosen[:product_family], 'iPad')
      true
    end

    test('preserves an exact simulator device-type name over product-family fallback') do
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:ios_simulator_device_types) do
        [
          { name: 'iPhone 17 Pro', identifier: 'phone-pro', product_family: 'iPhone' },
          { name: 'SaneLot-iPhone', identifier: 'exact-alias', product_family: 'iPhone' }
        ]
      end

      chosen = fresh_subject.send(:ios_simulator_device_type_for, 'SaneLot-iPhone')

      assert_eq(chosen[:identifier], 'exact-alias')
      true
    end

    test('uses the configured iOS simulator destination for iOS-only unit tests') do
      Dir.mktmpdir('verify-ios-destination-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneScan
            type: ios_app
            scheme: SaneScan
            project: SaneScan.xcodeproj
            tests:
              unit_target: SaneScanTests
              unit_destination: "platform=iOS Simulator,name=iPhone 17 Pro"
          YAML
        )
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          fresh_subject.define_singleton_method(:ios_simulator_destinations) do
            [
              { name: 'iPhone 17 Pro', udid: 'shutdown-sim', os: '26.5', state: 'Shutdown' },
              { name: 'iPhone 17 Pro', udid: 'booted-sim', os: '26.5', state: 'Booted' }
            ]
          end
          command = fresh_subject.send(:build_test_command, false)

          destination_index = command.index('-destination')
          assert(destination_index, 'expected xcodebuild command to include a destination')
          assert_eq(command[destination_index + 1], 'id=booted-sim')
          assert(!command.include?('platform=macOS,arch=arm64'), 'iOS-only projects must not be routed to macOS tests')
        end
      end
      true
    end

    test('creates the configured iOS simulator when the Mini has no matching device') do
      Dir.mktmpdir('verify-ios-create-destination-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneScan
            type: ios_app
            scheme: SaneScan
            project: SaneScan.xcodeproj
            tests:
              unit_target: SaneScanTests
              unit_destination: "platform=iOS Simulator,name=iPhone 17 Pro"
          YAML
        )
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          fresh_subject.define_singleton_method(:ios_simulator_destinations) { [] }
          fresh_subject.define_singleton_method(:create_ios_simulator_destination) do |name, requested_os|
            @created_destination = [name, requested_os]
            'created-sim'
          end
          command = fresh_subject.send(:build_test_command, false)

          destination_index = command.index('-destination')
          assert(destination_index, 'expected xcodebuild command to include a destination')
          assert_eq(command[destination_index + 1], 'id=created-sim')
          assert_eq(fresh_subject.instance_variable_get(:@created_destination), ['iPhone 17 Pro', ''])
        end
      end
      true
    end

    test('keeps macOS as the default unit test destination for desktop projects') do
      Dir.mktmpdir('verify-macos-destination-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneBar
            scheme: SaneBar
            project: SaneBar.xcodeproj
            tests:
              unit_target: SaneBarTests
          YAML
        )
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          command = fresh_subject.send(:build_test_command, false)

          destination_index = command.index('-destination')
          assert_eq(command[destination_index + 1], 'platform=macOS,arch=arm64')
        end
      end
      true
    end

    test('keeps macOS as the default UI test destination for desktop projects') do
      Dir.mktmpdir('verify-macos-ui-destination-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneVideo
            type: macos_app
            scheme: SaneVideo
            project: SaneVideo.xcodeproj
            tests:
              ui_target: SaneVideoUITests
          YAML
        )
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          command = fresh_subject.send(:build_ui_test_command)

          destination_index = command.index('-destination')
          assert_eq(command[destination_index + 1], 'platform=macOS,arch=arm64')
        end
      end
      true
    end

    test('keeps macOS UI test runners signed so XCTest can launch') do
      Dir.mktmpdir('verify-macos-ui-signing-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: SaneVideo
            type: macos_app
            scheme: SaneVideo
            project: SaneVideo.xcodeproj
            tests:
              unit_target: SaneVideoTests
              ui_target: SaneVideoUITests
          YAML
        )
        Dir.mkdir(File.join(dir, 'SaneVideoUITests'))
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          combined_command = fresh_subject.send(:build_test_command, true)
          ui_command = fresh_subject.send(:build_ui_test_command)
          commands = fresh_subject.send(:build_test_commands, true)
          ui_only_commands = fresh_subject.send(:build_test_commands, true, false, ui_only: true)

          assert(!combined_command.include?('CODE_SIGNING_ALLOWED=NO'), 'combined UI test command must stay signed')
          assert(!ui_command.include?('CODE_SIGNING_ALLOWED=NO'), 'dedicated UI test command must stay signed')
          assert_eq(commands.length, 2)
          assert_includes(commands[0][:cmd], 'CODE_SIGNING_ALLOWED=NO')
          assert(!commands[1][:cmd].include?('CODE_SIGNING_ALLOWED=NO'), 'separate UI session must stay signed')
          assert_eq(ui_only_commands.length, 1)
          assert_eq(ui_only_commands[0][:label], 'SaneVideo UI tests')
          assert(!ui_only_commands[0][:cmd].include?('CODE_SIGNING_ALLOWED=NO'))
        end
      end
      true
    end
  end

  test_category('Quality command fallback') do
    test('suppresses Bundler stack traces when Fastlane dependencies are missing') do
      Dir.mktmpdir('verify-lint-bundle-fallback-') do |dir|
        File.write(File.join(dir, 'Gemfile'), "source 'https://rubygems.org'\n")
        Dir.chdir(dir) do
          fresh_subject = VerifyHarness.new
          fresh_subject.define_singleton_method(:bundle_available?) { true }
          fresh_subject.define_singleton_method(:preferred_bundle_bin) { '/tmp/fake-bundle' }
          fresh_subject.define_singleton_method(:capture2e_with_bundle_env) do |*_args|
            [
              "Bundler::GemNotFound: Could not find xcodeproj in locally installed gems\nfrom noisy-stack",
              Struct.new(:success?).new(false)
            ]
          end

          output = capture_stdout { fresh_subject.send(:run_fastlane_lint) }

          assert_includes(output, 'Fastlane bundle dependencies are not installed')
          assert(!output.include?('noisy-stack'), 'raw Bundler stack must not be printed')
        end
      end
      true
    end

    test('runs both direct linters even when the first one fails') do
      calls = []
      subject.define_singleton_method(:command_available?) { |_command| true }
      subject.define_singleton_method(:system) do |*command|
        calls << command
        command.first != 'swiftlint'
      end

      result = subject.send(:run_direct_lint)

      assert_eq(result, false)
      assert_eq(calls.map(&:first), %w[swiftlint swiftformat])
      true
    end

    test('falls back to rubocop when no fastlane quality lane exists') do
      fallback_called = false
      subject.define_singleton_method(:bundle_available?) { true }
      subject.define_singleton_method(:preferred_bundle_bin) { '/tmp/fake-bundle' }
      subject.define_singleton_method(:capture2e_with_bundle_env) do |*_args|
        ['Could not find lane \'mac quality\'', Struct.new(:success?).new(false)]
      end
      subject.define_singleton_method(:check_rubocop_issues) do
        fallback_called = true
        0
      end

      output = capture_stdout { subject.send(:run_quality_report) }

      assert(fallback_called, 'expected rubocop fallback to run')
      assert_includes(output, 'No fastlane quality lane')
      true
    end

    test('reports a real fastlane quality failure without masking it') do
      subject.define_singleton_method(:bundle_available?) { true }
      subject.define_singleton_method(:preferred_bundle_bin) { '/tmp/fake-bundle' }
      subject.define_singleton_method(:capture2e_with_bundle_env) do |*_args|
        ['fastlane exploded', Struct.new(:success?).new(false)]
      end
      subject.define_singleton_method(:check_rubocop_issues) do
        raise 'rubocop fallback should not run for real fastlane failures'
      end

      output = capture_stdout { subject.send(:run_quality_report) }

      assert_includes(output, 'fastlane exploded')
      assert_includes(output, '❌ Quality report generation failed.')
      true
    end
  end

  test_category('Verify timeout handling') do
    test('execute_with_logging returns on timeout for a stuck child process') do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = subject.send(
        :execute_with_logging,
        ['ruby', '-e', 'STDOUT.sync = true; puts "starting"; trap("TERM") { exit! 0 }; sleep 10'],
        1,
        append: false,
        label: 'timeout regression'
      ) { |_line| nil }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_eq(result[:success], false)
      assert_eq(result[:timeout], true)
      assert(elapsed < 4, "expected timeout path to return promptly, got #{elapsed.round(2)}s")
      true
    end

    test('Interrupt cleanup kills a captured descendant that escaped the process group') do
      Dir.mktmpdir('verify-interrupt-tree-') do |dir|
        child_pid = nil
        begin
          Dir.chdir(dir) do
            child_pid_path = File.join(dir, 'escaped.pid')
            command = [
              RbConfig.ruby,
              '-e',
              <<~RUBY,
                path = ARGV.fetch(0)
                child = fork do
                  Process.setsid
                  Signal.trap('TERM', 'IGNORE')
                  File.write(path, Process.pid.to_s)
                  loop { sleep 1 }
                end
                Process.wait(child)
              RUBY
              child_pid_path
            ]
            fresh_subject = VerifyHarness.new
            fresh_subject.define_singleton_method(:wait_for_process_with_timeout) do |_wait_thr, _timeout, **options|
              deadline = Time.now + 5
              sleep 0.01 until File.file?(child_pid_path) || Time.now >= deadline
              child_pid = File.read(child_pid_path).to_i
              options.fetch(:tracked_descendants) << child_pid
              raise Interrupt, 'deterministic cancellation'
            end

            interrupted = false
            begin
              fresh_subject.send(:execute_with_logging, command, 5, label: 'interrupt cleanup')
            rescue Interrupt
              interrupted = true
            end
            child_pid = File.read(child_pid_path).to_i
            assert(interrupted, 'fixture must propagate Interrupt after cleanup')
            assert(!fresh_subject.send(:monitor_test_pid_alive?, child_pid), 'escaped child survived verify Interrupt cleanup')
          end
        ensure
          if child_pid.to_i.positive?
            begin
              Process.kill('KILL', child_pid)
            rescue Errno::ESRCH
              nil
            end
          end
        end
      end
      true
    end

    test('verify artifact setup rejects a symlinked outputs parent') do
      Dir.mktmpdir('verify-symlink-output-') do |dir|
        outside = Dir.mktmpdir('verify-symlink-outside-')
        File.symlink(outside, File.join(dir, 'outputs'))
        error = Dir.chdir(dir) do
          begin
            subject.send(:attach_verify_result_bundles, [{ label: 'unit', cmd: ['true'], test_selector: nil }])
            nil
          rescue StandardError => e
            e
          end
        end
        assert(error, 'verify must reject a symlinked outputs parent')
        assert_includes(error.message, 'Unsafe symlink')
        assert_eq(Dir.children(outside), [])
      ensure
        FileUtils.remove_entry(outside) if outside && File.directory?(outside)
      end
      true
    end

    test('verify evidence buffer is bounded and retains the newest output') do
      buffer = String.new
      subject.send(:append_verify_command_evidence, buffer, 'old-output-', max_bytes: 12)
      subject.send(:append_verify_command_evidence, buffer, 'new-result', max_bytes: 12)

      assert(buffer.bytesize <= 12, "expected bounded evidence, got #{buffer.bytesize} bytes")
      assert_includes(buffer, 'new-result')
      true
    end

    test('timeout cleanup targets only the owned process group') do
      source = File.read(File.expand_path('verify_support.rb', __dir__))
      timeout_body = source[source.index('def handle_timeout')..]

      assert_includes(source, 'Open3.popen2e(*cmd, pgroup: true)')
      assert(!timeout_body.include?('pkill'), 'timeout must not pkill another verify run')
      assert(!timeout_body.include?('killall'), 'timeout must not kill host-wide xcodebuild or app processes')
      assert_includes(source, 'terminate_monitor_test_process_group(')
      assert_includes(source, 'tracked_descendants: tracked_descendants')
      true
    end

    test('never changes a nonzero process status to success from passing log text') do
      Dir.mktmpdir('verify-nonzero-authority-') do |dir|
        Dir.chdir(dir) do
          result = subject.send(
            :execute_with_logging,
            ['sh', '-c', %q{printf "Test Suite 'All tests' passed\nExecuted 3 tests, with 0 failures\n"; exit 7}],
            5,
            label: 'nonzero authority'
          )

          assert_eq(result[:success], false)
          assert_eq(result[:timeout], false)
          assert_eq(result[:exit_status], 7)
        end
      end
      true
    end
  end

  test_category('Verify log parser') do
    test('does not treat mixed Swift Testing and XCTest failure output as success') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
        /tmp/SaneVideoTests.swift:42: error: -[SaneVideoTests.ExampleTests testExample] : XCTAssertTrue failed
        ** TEST FAILED **
      LOG

      assert_eq(subject.send(:verify_log_indicates_failure?, body), true)
      assert_eq(subject.send(:verify_log_indicates_success?, body), false)
      true
    end

    test('accepts a clean Swift Testing summary when no failure markers are present') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
      LOG

      assert_eq(subject.send(:verify_log_indicates_failure?, body), false)
      assert_eq(subject.send(:verify_log_indicates_success?, body), true)
      true
    end

    test('does not treat failure in a passing test name as a failure marker') do
      body = <<~LOG
        Test "Initial refresh failure only blocks setup completion when no usable content was loaded" passed after 0.001 seconds.
        Swift Testing: 75 tests in 12 suites passed
        Test Suite 'All tests' passed at 2026-05-14 12:55:22.561.
      LOG

      assert_eq(subject.send(:verify_log_indicates_failure?, body), false)
      assert_eq(subject.send(:verify_log_indicates_success?, body), true)
      true
    end

    test('treats App Intents autoShortcut diagnostics as benign after clean pass') do
      body = <<~LOG
        2026-05-25 SaneSales[44908] [Connection] Unable to get synchronousRemoteObjectProxy, error: Error Domain=NSCocoaErrorDomain Code=4097 "connection to service named com.apple.linkd.autoShortcut"
        2026-05-25 SaneSales[44908] [Application] Error registering app with intents framework: Error Domain=NSCocoaErrorDomain Code=4097 "connection to service named com.apple.linkd.autoShortcut"
        Test Suite 'All tests' passed at 2026-05-25 22:07:17.663.
        Executed 87 tests, with 0 failures (0 unexpected) in 7.471 seconds
        ** TEST FAILED **
      LOG

      assert_eq(subject.send(:verify_log_indicates_failure?, body), true)
      assert_eq(subject.send(:verify_log_only_has_benign_app_intents_failure?, body), true)
      result = subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 87, log_text: body)
      assert(result[:bucket] != 'test_failure', 'benign App Intents diagnostics should not be bucketed as a real test failure')
      true
    end

    test('does not hide real failures behind App Intents diagnostics') do
      body = <<~LOG
        2026-05-25 SaneSales[44908] [Connection] Unable to get synchronousRemoteObjectProxy, error: Error Domain=NSCocoaErrorDomain Code=4097 "connection to service named com.apple.linkd.autoShortcut"
        /tmp/SaneSalesTests.swift:42: error: -[SaneSalesTests.ExampleTests testExample] : XCTAssertTrue failed
        ** TEST FAILED **
      LOG

      assert_eq(subject.send(:verify_log_only_has_benign_app_intents_failure?, body), false)
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 1, log_text: body)[:bucket], 'test_failure')
      true
    end

    test('never hides a missing xcodebuild destination behind an earlier clean pass') do
      body = <<~LOG
        Test run with 719 tests in 105 suites passed after 15.891 seconds.
        2026-07-10 App[1] connection to service named com.apple.linkd.autoShortcut
        xcodebuild: error: Unable to find a destination matching the provided destination specifier:
                { id:STALE-SIMULATOR-ID }
      LOG

      assert_eq(subject.send(:verify_log_indicates_failure?, body), true)
      assert_eq(subject.send(:verify_log_only_has_benign_app_intents_failure?, body), false)
      assert_eq(subject.send(:verify_log_indicates_success?, body), false)
      true
    end

    test('treats the Xcode UI runner Testing failed summary as authoritative') do
      log = <<~LOG
        Testing failed:
        SaneVideoUITests-Runner encountered an error (The test runner hung before establishing connection.)
      LOG

      assert(subject.send(:verify_log_indicates_failure?, log))
      assert(!subject.send(:verify_log_indicates_success?, log))
      true
    end

    test('an appended UI command cannot inherit an earlier unit-test success') do
      Dir.mktmpdir('verify-appended-command-scope-') do |dir|
        Dir.chdir(dir) do
          File.write('test_output.txt', "Test Suite 'All tests' passed\n")
          result = subject.send(
            :execute_with_logging,
            ['sh', '-c', 'echo "Testing failed:"; echo "com.apple.linkd.autoShortcut"; exit 1'],
            5,
            append: true,
            label: 'UI tests'
          )

          assert(!result[:success], 'UI failure must remain red even when the aggregate log has an earlier pass')
          assert_includes(result[:output], 'Testing failed:')
        end
      end
      true
    end

    test('counts script test summaries instead of reporting zero tests') do
      state = {
        start_time: Time.now,
        tests_run: 0,
        swift_testing_total: 0,
        current_test: nil,
        last_update: Time.now,
        spinner_chars: ['-'],
        spinner_idx: 0
      }

      capture_stdout do
        subject.send(:handle_progress_update, 'RESULTS: 4/4 passed', state)
        subject.send(:handle_progress_update, 'Ran 3 tests in 0.001s', state)
        subject.send(:handle_progress_update, 'PASS 2/2', state)
      end

      assert_eq(state[:tests_run], 9)
      true
    end

    test('normal verify rejects a successful runner result that counted zero tests') do
      Dir.mktmpdir('verify-zero-test-') do |dir|
        Dir.chdir(dir) do
          File.write('test_output.txt', "BUILD SUCCEEDED\n")
          fresh_subject = VerifyHarness.new
          metrics = []
          attempts = []
          suggested_memory = false

          fresh_subject.define_singleton_method(:verify_running_as_preflight?) { false }
          fresh_subject.define_singleton_method(:ensure_research_gate_clear!) { |_slug| true }
          fresh_subject.define_singleton_method(:assert_no_runtime_probe_lock_for_verify!) {}
          fresh_subject.define_singleton_method(:test_targets_disabled?) { false }
          fresh_subject.define_singleton_method(:config_value) { |_keys, _env, fallback| fallback }
          fresh_subject.define_singleton_method(:run_verify_preflight) {}
          fresh_subject.define_singleton_method(:enforce_saneui_source_of_truth!) {}
          fresh_subject.define_singleton_method(:ensure_sanevideo_test_assets!) {}
          fresh_subject.define_singleton_method(:git_status_snapshot) { [] }
          fresh_subject.define_singleton_method(:grant_test_permissions) { |**_options| nil }
          fresh_subject.define_singleton_method(:terminate_running_app_instance) {}
          fresh_subject.define_singleton_method(:validate_test_references) {}
          fresh_subject.define_singleton_method(:run_tests_with_progress) do |**_options|
            { success: true, tests_run: 0, duration: 1, timeout: false }
          end
          fresh_subject.define_singleton_method(:verify_metric_host) { 'test-host' }
          fresh_subject.define_singleton_method(:verify_source_fingerprint) { 'source-fingerprint' }
          fresh_subject.define_singleton_method(:record_process_metric) do |type, **attributes|
            metrics << attributes.merge(type: type)
          end
          fresh_subject.define_singleton_method(:record_verify_attempt) do |**attributes|
            attempts << attributes
            { consecutive_failures: 1 }
          end
          fresh_subject.define_singleton_method(:diagnose) { |_error = nil, **_options| }
          fresh_subject.define_singleton_method(:cleanup_test_processes) { |_monitor = nil| }
          fresh_subject.define_singleton_method(:suggest_memory_record) { suggested_memory = true }
          fresh_subject.define_singleton_method(:enforce_no_unresolved_permission_prompt!) do |_monitor|
            raise 'zero-test result reached success-only permission enforcement'
          end
          fresh_subject.define_singleton_method(:verify_repo_cleanliness!) do |**_options|
            raise 'zero-test result reached success-only cleanliness enforcement'
          end

          status = nil
          output = capture_stdout do
            begin
              fresh_subject.verify([])
            rescue SystemExit => e
              status = e.status
            end
          end

          assert_eq(status, 1)
          assert_includes(output, 'reported success but counted 0 tests')
          assert(!output.include?('Tests passed!'), 'zero tests must never be labeled passed')
          assert_eq(metrics.length, 1)
          assert_eq(metrics.first[:success], false)
          assert_eq(metrics.first[:tests_run], 0)
          assert_eq(metrics.first[:evidence_strength], 'failed')
          assert_eq(metrics.first[:failure_bucket], 'weak_zero_test_success')
          assert_eq(attempts.length, 1)
          assert_eq(attempts.first[:success], false)
          assert_eq(attempts.first[:message], 'verify zero-test failure')
          assert_eq(suggested_memory, false)
        end
      end
      true
    end

    test('counts each XCTest case once from completion lines only') do
      state = {
        start_time: Time.now,
        tests_run: 0,
        swift_testing_total: 0,
        current_test: nil,
        last_update: Time.now,
        spinner_chars: ['-'],
        spinner_idx: 0
      }

      capture_stdout do
        subject.send(:handle_progress_update, "Test Case '-[ExampleTests testThing]' started.", state)
        subject.send(:handle_progress_update, "Test Case '-[ExampleTests testThing]' passed (0.001 seconds).", state)
      end

      assert_eq(state[:tests_run], 1)
      true
    end

    test('records verify phase from package, build, and test log lines') do
      state = { tests_run: 0, swift_testing_total: 0, phase: nil, last_log_line: nil, last_log_at: nil }

      subject.send(:record_verify_progress_line, 'Resolve Package Graph', state)
      assert_eq(state[:phase], 'package-resolution')
      subject.send(:record_verify_progress_line, 'SwiftCompile normal arm64 Example.swift', state)
      assert_eq(state[:phase], 'build')
      subject.send(:record_verify_progress_line, "Test Case '-[ExampleTests testThing]' started.", state)
      assert_eq(state[:phase], 'test')

      true
    end

    test('verify heartbeat line includes phase, pid, tests, log path, and compact last line') do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, 'test_output.txt')
        File.write(log_path, "Resolve Package Graph\n")
        long_line = 'x' * 200
        state = {
          tests_run: 7,
          swift_testing_total: 0,
          phase: 'package-resolution',
          last_log_line: long_line,
          last_log_at: Time.now - 3
        }
        line = subject.send(:verify_heartbeat_line, {
                            label: 'SaneBar unit tests',
                            pid: 12_345,
                            log_path: log_path,
                            started_at: Time.now - 12,
                            deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 99,
                            state: state
                          })

        assert_includes(line, 'verify heartbeat')
        assert_includes(line, 'label=SaneBar unit tests')
        assert_includes(line, 'pid=12345')
        assert_includes(line, 'phase=package-resolution')
        assert_includes(line, 'tests=7')
        assert_includes(line, "log=#{log_path}")
        assert(line.include?('last="') && line.include?('...'), 'expected compact last log line')
      end

      true
    end

    test('verify heartbeat respects quiet interval and opt-out environment') do
      previous = ENV['SANEMASTER_VERIFY_HEARTBEAT']
      ENV.delete('SANEMASTER_VERIFY_HEARTBEAT')
      assert_eq(subject.send(:verify_should_emit_heartbeat?, Time.now - 20, Time.now - 20), true)
      assert_eq(subject.send(:verify_should_emit_heartbeat?, Time.now, Time.now - 20), false)
      ENV['SANEMASTER_VERIFY_HEARTBEAT'] = '0'
      assert_eq(subject.send(:verify_should_emit_heartbeat?, Time.now - 20, Time.now - 20), false)
      true
    ensure
      if previous.nil?
        ENV.delete('SANEMASTER_VERIFY_HEARTBEAT')
      else
        ENV['SANEMASTER_VERIFY_HEARTBEAT'] = previous
      end
    end

    test('classifies zero-test verify failures into useful buckets') do
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: true, tests_run: 0, log_text: '')[:bucket], 'pre_test_process_timeout')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: true, tests_run: 87, log_text: 'Test Case passed')[:bucket], 'counted_test_process_timeout')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: '')[:bucket], 'runner_no_output')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: 'System Settings permission prompt timed out')[:bucket], 'permission_prompt')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: '** BUILD FAILED ** timeout error:')[:bucket], 'build_failure')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: 'timed out waiting for simulator boot')[:bucket], 'pre_test_timeout_signal')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 1, log_text: 'Test timed out waiting for fixture')[:bucket], 'counted_test_timeout_signal')
      assert_eq(subject.send(:classify_verify_result, success: true, timeout: false, tests_run: 0, log_text: 'BUILD SUCCEEDED')[:bucket], 'weak_zero_test_success')
      true
    end

    test('classifies counted timeout failures separately from generic test failures') do
      body = "/tmp/Tests.swift:42: error: -[ExampleTests testThing] : timed out waiting for fixture\n** TEST FAILED **"
      result = subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 1, log_text: body)

      assert_eq(result[:bucket], 'counted_test_timeout_signal')
      true
    end

    test('classifies counted failures as test failures before generic error matching') do
      body = "/tmp/Tests.swift:42: error: -[ExampleTests testThing] : XCTAssertTrue failed\n** TEST FAILED **"
      result = subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 1, log_text: body)

      assert_eq(result[:bucket], 'test_failure')
      true
    end
  end

  test_category('Permission monitor guard') do
    test('treats protected folder prompts as verify blockers') do
      log = '🚫 PROTECTED_FOLDER_PROMPT detected on CoreServicesUIAgent: SaneVideo would like to access files in your Documents folder'

      assert_eq(subject.send(:permission_monitor_blocked?, log), true)
      true
    end

    test('still exposes protected folder TCC services for the explicit reset path') do
      # grant_test_permissions no longer resets TCC on every verify (that wiped
      # the installed app's real user grants). The protected-folder service list
      # is still exposed via verify_permission_services for the guard test and
      # the explicit reset_permissions command.
      fresh_subject = VerifyHarness.new
      fresh_subject.define_singleton_method(:saneprocess_config) { { 'type' => 'app' } }
      fresh_subject.define_singleton_method(:project_xcodeproj) { 'Example.xcodeproj' }
      fresh_subject.define_singleton_method(:project_workspace) { nil }

      services = fresh_subject.send(:verify_permission_services)

      assert_includes(services, 'SystemPolicyDocumentsFolder')
      assert_includes(services, 'SystemPolicyDesktopFolder')
      assert_includes(services, 'SystemPolicyDownloadsFolder')
      true
    end
  end

  test_category('UTF-8 locale hardening') do
    test('forces a UTF-8 locale when the caller locale is empty or ASCII') do
      saved = ENV.values_at('LANG', 'LC_ALL', 'LC_CTYPE')
      saved_ext = Encoding.default_external
      saved_int = Encoding.default_internal
      begin
        ENV['LANG'] = ''
        ENV['LC_ALL'] = 'C'
        ENV['LC_CTYPE'] = 'POSIX'
        subject.send(:ensure_utf8_locale!)
        assert_eq(ENV['LANG'], 'en_US.UTF-8')
        assert_eq(ENV['LC_ALL'], 'en_US.UTF-8')
        assert_eq(ENV['LC_CTYPE'], 'en_US.UTF-8')
      ensure
        ENV['LANG'], ENV['LC_ALL'], ENV['LC_CTYPE'] = saved
        Encoding.default_external = saved_ext
        Encoding.default_internal = saved_int
      end
      true
    end

    test('does not clobber an already-UTF-8 locale') do
      saved = ENV.values_at('LANG', 'LC_ALL', 'LC_CTYPE')
      saved_ext = Encoding.default_external
      saved_int = Encoding.default_internal
      begin
        ENV['LANG'] = 'en_GB.UTF-8'
        ENV['LC_ALL'] = ''
        ENV['LC_CTYPE'] = ''
        subject.send(:ensure_utf8_locale!)
        assert_eq(ENV['LANG'], 'en_GB.UTF-8')
        assert_eq(ENV['LC_ALL'], 'en_US.UTF-8')
      ensure
        ENV['LANG'], ENV['LC_ALL'], ENV['LC_CTYPE'] = saved
        Encoding.default_external = saved_ext
        Encoding.default_internal = saved_int
      end
      true
    end
  end

  test_category('UTF-8 locale hardening') do
    test('forces a UTF-8 locale when the caller locale is empty or ASCII') do
      saved = ENV.values_at('LANG', 'LC_ALL', 'LC_CTYPE')
      saved_ext = Encoding.default_external
      saved_int = Encoding.default_internal
      begin
        ENV['LANG'] = ''
        ENV['LC_ALL'] = 'C'
        ENV['LC_CTYPE'] = 'POSIX'
        subject.send(:ensure_utf8_locale!)
        assert_eq(ENV['LANG'], 'en_US.UTF-8')
        assert_eq(ENV['LC_ALL'], 'en_US.UTF-8')
        assert_eq(ENV['LC_CTYPE'], 'en_US.UTF-8')
      ensure
        ENV['LANG'], ENV['LC_ALL'], ENV['LC_CTYPE'] = saved
        Encoding.default_external = saved_ext
        Encoding.default_internal = saved_int
      end
      true
    end

    test('does not clobber an already-UTF-8 locale') do
      saved = ENV.values_at('LANG', 'LC_ALL', 'LC_CTYPE')
      saved_ext = Encoding.default_external
      saved_int = Encoding.default_internal
      begin
        ENV['LANG'] = 'en_GB.UTF-8'
        ENV['LC_ALL'] = ''
        ENV['LC_CTYPE'] = ''
        subject.send(:ensure_utf8_locale!)
        assert_eq(ENV['LANG'], 'en_GB.UTF-8')
        assert_eq(ENV['LC_ALL'], 'en_US.UTF-8')
      ensure
        ENV['LANG'], ENV['LC_ALL'], ENV['LC_CTYPE'] = saved
        Encoding.default_external = saved_ext
        Encoding.default_internal = saved_int
      end
      true
    end
  end
end)
