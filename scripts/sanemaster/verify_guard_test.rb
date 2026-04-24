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
  end
end)
