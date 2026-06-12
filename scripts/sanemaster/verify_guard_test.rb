#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'verify'

class VerifyHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Verify
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

exit(run_tests('SaneMaster Verify Repo Drift Tests') do
  subject = VerifyHarness.new

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
      assert_eq(commands.first[:label], 'SaneProcess hook enforcement tests')
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
  end

  test_category('Project test destinations') do
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
  end

  test_category('Quality command fallback') do
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

    test('classifies zero-test verify failures into useful buckets') do
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: true, tests_run: 0, log_text: '')[:bucket], 'timeout')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: '')[:bucket], 'runner_no_output')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: 'System Settings permission prompt')[:bucket], 'permission_prompt')
      assert_eq(subject.send(:classify_verify_result, success: false, timeout: false, tests_run: 0, log_text: '** BUILD FAILED ** error:')[:bucket], 'build_failure')
      assert_eq(subject.send(:classify_verify_result, success: true, timeout: false, tests_run: 0, log_text: 'BUILD SUCCEEDED')[:bucket], 'weak_zero_test_success')
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

    test('resets protected folder TCC services before verify') do
      # The TCC reset lives in the verify family; verify.rb was split per
      # Rule #10, so check the combined source rather than one file.
      content = %w[verify.rb verify_support.rb].map do |file|
        File.read(File.join(__dir__, file), encoding: Encoding::UTF_8)
      end.join("\n")

      assert_includes(content, 'SystemPolicyDocumentsFolder')
      assert_includes(content, 'SystemPolicyDesktopFolder')
      assert_includes(content, 'SystemPolicyDownloadsFolder')
      true
    end
  end
end)
