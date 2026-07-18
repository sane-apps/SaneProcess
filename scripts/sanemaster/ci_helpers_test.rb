#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'rbconfig'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'ci_helpers'

class CIHelpersHarness
  include SaneMasterModules::CIHelpers

  def monitor_plan(**attributes)
    send(:monitor_test_plan, **attributes)
  end

  def monitor_options(args, default_scheme: 'DefaultScheme')
    send(:monitor_test_options, args, default_scheme: default_scheme)
  end

  def prepare_plan(plan)
    send(
      :secure_test_prepare_run_directory!,
      project_root: plan.fetch(:project_root),
      lane: 'monitor-tests',
      run_directory: plan.fetch(:run_directory)
    )
  end

  def write_receipt(**attributes)
    send(:write_monitor_test_receipt, **attributes)
  end

  def termination_targets(pid, descendants)
    send(:monitor_test_signal_targets, pid, descendants)
  end

  def terminate_process_tree(pid, **attributes)
    send(:terminate_monitor_test_process_group, pid, **attributes)
  end

  def process_alive?(pid)
    send(:monitor_test_pid_alive?, pid)
  end

  def parse_process_snapshot(output)
    send(:monitor_test_parse_process_snapshot, output)
  end

  def process_scan_available?
    send(:monitor_test_process_scan_available?)
  end

  def result_summary(data, selector = nil)
    send(:monitor_test_result_summary_from_data, data, selector)
  end

  def log_lines(path, **attributes)
    send(:monitor_test_log_lines, path, **attributes)
  end
end

include TestFramework

exit(run_tests('SaneMaster CI Helpers Tests') do
  subject = CIHelpersHarness.new
  started_at = Time.utc(2026, 7, 11, 21, 30, 45, 123_456)

  test_category('Monitor test CLI options') do
    test('parses strict named options and preserves safe defaults') do
      explicit = subject.monitor_options(
        ['--scheme', 'SaneVideo', '--package-path', 'Feature', '--test-plan', 'Release', '--test=SaneVideoTests/PlaybackTests/testPlay', '--timeout', '120']
      )
      defaults = subject.monitor_options([], default_scheme: 'CurrentProject')

      assert_eq(
        explicit,
        {
          scheme: 'SaneVideo',
          package_path: 'Feature',
          test_plan: 'Release',
          test_selector: 'SaneVideoTests/PlaybackTests/testPlay',
          timeout: 120
        }
      )
      assert_eq(defaults, { scheme: 'CurrentProject', package_path: nil, test_plan: nil, test_selector: nil, timeout: 300 })
      true
    end

    test('rejects positional, unknown, missing, duplicate, and nonpositive values') do
      invalid_cases = {
        ['SaneVideo', 'PlaybackTests', '120'] => 'positional arguments are not supported',
        ['--bogus', 'value'] => 'unknown argument',
        ['--scheme'] => '--scheme requires a value',
        ['--test', '--timeout', '30'] => '--test requires a value',
        ['--test-plan'] => '--test-plan requires a value',
        ['--package-path'] => '--package-path requires a value',
        ['--scheme', 'One', '--scheme=Two'] => '--scheme was provided more than once',
        ['--timeout', '0'] => '--timeout must be a positive integer',
        ['--timeout=-1'] => '--timeout must be a positive integer',
        ['--timeout', '1.5'] => '--timeout must be a positive integer'
      }

      invalid_cases.each do |arguments, expected_message|
        error = begin
          subject.monitor_options(arguments)
          nil
        rescue ArgumentError => e
          e
        end
        assert(error, "expected #{arguments.inspect} to fail")
        assert_includes(error.message, expected_message)
      end
      true
    end
  end

  test_category('Monitor test invocation plan') do
    test('binds the exact selector and result bundle to a unique project-local run') do
      Dir.mktmpdir('ci-helpers-') do |root|
        selector = 'SaneVideoTests/CameraFPSRegressionTests'
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: selector,
          started_at: started_at,
          pid: 4321,
          nonce: 'a1b2c3d4'
        )
        expected_directory = File.join(
          File.realpath(root),
          'outputs',
          'monitor-tests',
          '20260711T213045.123456Z-4321-a1b2c3d4'
        )

        assert_eq(plan[:run_directory], expected_directory)
        assert_eq(plan[:result_bundle_path], File.join(expected_directory, 'test.xcresult'))
        assert_eq(plan[:xcresult_path], plan[:result_bundle_path])
        assert_eq(plan[:log_path], File.join(expected_directory, 'xcodebuild.log'))
        assert_eq(plan[:receipt_path], File.join(expected_directory, 'receipt.json'))
        assert_eq(
          plan[:command],
          [
            'xcodebuild', 'test', '-scheme', 'SaneVideo',
            '-destination', 'platform=macOS,arch=arm64',
            '-resultBundlePath', plan[:result_bundle_path],
            '-only-testing', selector
          ]
        )
      end
      true
    end

    test('omits only-testing when the exact selector is nil') do
      Dir.mktmpdir('ci-helpers-') do |root|
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: nil,
          started_at: started_at,
          pid: 4321,
          nonce: 'all-tests'
        )

        assert(!plan[:command].include?('-only-testing'), 'all-tests plans must not invent a selector')
        assert_eq(plan[:test_selector], nil)
      end
      true
    end

    test('uses an explicit test plan and verifies the selected test from xcresult') do
      Dir.mktmpdir('ci-helpers-') do |root|
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneHosts',
          test_plan: 'SaneHosts',
          test_selector: 'SaneHostsFeatureTests/ProfileStoreEssentialsPolicyTests/createsEssentialsAlongsideExistingEntries',
          started_at: started_at,
          pid: 4321,
          nonce: 'test-plan'
        )

        assert_eq(plan[:test_plan], 'SaneHosts')
        assert_includes(plan[:command], '-testPlan')
        assert_eq(plan[:command][plan[:command].index('-testPlan') + 1], 'SaneHosts')
        assert(!plan[:command].include?('-only-testing'), 'test-plan execution must not target a local package test bundle directly')
      end
      true
    end

    test('runs a package scheme from a project-contained package directory') do
      Dir.mktmpdir('ci-helpers-') do |root|
        package = File.join(root, 'SaneHostsPackage')
        Dir.mkdir(package)
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneHostsFeature-Package',
          package_path: 'SaneHostsPackage',
          test_selector: 'SaneHostsFeatureTests/ProfileStoreEssentialsPolicyTests/createsEssentialsAlongsideExistingEntries',
          started_at: started_at,
          pid: 4321,
          nonce: 'package'
        )

        assert_eq(plan[:working_directory], File.realpath(package))
        assert_eq(plan[:package_path], 'SaneHostsPackage')
        assert(!plan[:command].include?('-only-testing'), 'package execution must verify the exact selector from xcresult')
      end
      true
    end
  end

  test_category('Monitor test artifact containment') do
    test('rejects a symlinked outputs parent without writing outside the project') do
      Dir.mktmpdir('ci-helpers-symlink-') do |root|
        outside = Dir.mktmpdir('ci-helpers-outside-')
        File.symlink(outside, File.join(root, 'outputs'))
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: nil,
          started_at: started_at,
          pid: 4321,
          nonce: 'symlink'
        )
        error = begin
          subject.prepare_plan(plan)
          nil
        rescue StandardError => e
          e
        end

        assert(error, 'symlinked outputs parent must be rejected')
        assert_includes(error.message, 'Unsafe symlink')
        assert_eq(Dir.children(outside), [])
      ensure
        FileUtils.remove_entry(outside) if outside && File.directory?(outside)
      end
      true
    end
  end

  test_category('Monitor test receipts') do
    test('writes a passed receipt with verifiable artifact paths and exact command') do
      Dir.mktmpdir('ci-helpers-') do |root|
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: 'SaneVideoTests/CameraFPSRegressionTests',
          started_at: started_at,
          pid: 4321,
          nonce: 'passed'
        )
        FileUtils.mkdir_p(plan[:result_bundle_path])
        File.write(File.join(plan[:result_bundle_path], 'Info.plist'), '<plist/>')
        File.write(plan[:log_path], "** TEST SUCCEEDED **\n")
        receipt_path = subject.write_receipt(
          plan: plan,
          started_at: started_at,
          completed_at: started_at + 12.5,
          exit_status: 0,
          timed_out: false,
          host: 'Stephans-Mac-mini.local',
          result_summary: {
            ok: true,
            discovered_test_count: 1,
            passed_test_count: 1,
            matched_test_count: 1,
            error: nil
          }
        )
        receipt = JSON.parse(File.read(receipt_path))

        assert_eq(receipt['source'], 'SaneMaster.monitor_tests')
        assert_eq(receipt['status'], 'passed')
        assert_eq(receipt['host'], 'Stephans-Mac-mini.local')
        assert_eq(receipt['scheme'], 'SaneVideo')
        assert_eq(receipt['test_selector'], 'SaneVideoTests/CameraFPSRegressionTests')
        assert_eq(receipt['started_at'], '2026-07-11T21:30:45.123456Z')
        assert_eq(receipt['completed_at'], '2026-07-11T21:30:57.623456Z')
        assert_eq(receipt['result_bundle_path'], plan[:result_bundle_path])
        assert_eq(receipt['result_bundle_exists'], true)
        assert_eq(receipt['result_bundle_valid'], true)
        assert_eq(receipt['xcresult_verified'], true)
        assert_eq(receipt['discovered_test_count'], 1)
        assert_eq(receipt['passed_test_count'], 1)
        assert_eq(receipt['matched_test_count'], 1)
        assert_eq(receipt['xcresult_path'], receipt['result_bundle_path'])
        assert_eq(receipt['xcresult_exists'], true)
        assert_eq(receipt['command'], plan[:command])
        assert_eq(receipt['exit_status'], 0)
        assert_eq(receipt['log_path'], plan[:log_path])
        assert_eq(Time.iso8601(receipt['started_at']).utc_offset, 0)
        assert_eq(Time.iso8601(receipt['completed_at']).utc_offset, 0)
        assert_eq(Dir.glob("#{receipt_path}.tmp-*").length, 0)
      end
      true
    end

    test('classifies process failure and timeout as failed before exit') do
      Dir.mktmpdir('ci-helpers-') do |root|
        scenarios = [
          { name: 'process-failure', exit_status: 65, timed_out: false, termination_signal: nil },
          { name: 'timeout', exit_status: 124, timed_out: true, termination_signal: 9 }
        ]

        scenarios.each do |scenario|
          plan = subject.monitor_plan(
            root: root,
            scheme: 'SaneVideo',
            test_selector: 'SaneVideoTests/CameraConcurrencyRegressionTests',
            started_at: started_at,
            pid: 4321,
            nonce: scenario[:name]
          )
          FileUtils.mkdir_p(plan[:run_directory])
          receipt_path = subject.write_receipt(
            plan: plan,
            started_at: started_at,
            completed_at: started_at + 30,
            host: 'Stephans-Mac-mini.local',
            exit_status: scenario[:exit_status],
            timed_out: scenario[:timed_out],
            termination_signal: scenario[:termination_signal]
          )
          receipt = JSON.parse(File.read(receipt_path))

          assert_eq(receipt['status'], 'failed')
          assert_eq(receipt['exit_status'], scenario[:exit_status])
          assert_eq(receipt['timed_out'], scenario[:timed_out])
          assert_eq(receipt['termination_signal'], scenario[:termination_signal])
          assert_eq(receipt['result_bundle_path'], plan[:result_bundle_path])
          assert_eq(receipt['result_bundle_exists'], false)
          assert_eq(receipt['result_bundle_valid'], false)
          assert_eq(receipt['xcresult_exists'], false)
          assert(!receipt['error'].to_s.empty?, 'failed receipts must explain why they failed')
        end
      end
      true
    end

    test('fails closed when exit zero has no valid result bundle') do
      Dir.mktmpdir('ci-helpers-') do |root|
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: nil,
          started_at: started_at,
          pid: 4321,
          nonce: 'invalid-bundle'
        )
        FileUtils.mkdir_p(plan[:run_directory])
        File.write(plan[:log_path], 'fixture log')
        missing = subject.send(
          :build_monitor_test_receipt,
          plan: plan,
          started_at: started_at,
          completed_at: started_at + 1,
          exit_status: 0,
          timed_out: false,
          host: 'Stephans-Mac-mini.local'
        )
        FileUtils.mkdir_p(plan[:result_bundle_path])
        incomplete = subject.send(
          :build_monitor_test_receipt,
          plan: plan,
          started_at: started_at,
          completed_at: started_at + 1,
          exit_status: 0,
          timed_out: false,
          host: 'Stephans-Mac-mini.local'
        )

        assert_eq(missing[:status], 'failed')
        assert_eq(missing[:error], 'Result bundle was not created as a directory')
        assert_eq(incomplete[:status], 'failed')
        assert_eq(incomplete[:error], 'Result bundle is missing Info.plist')
      end
      true
    end


    test('requires a nonzero passed test matching the requested selector') do
      selector = 'SaneVideoUITests/SaneVideoSettingsEvidenceUITests/testSettingsTabs'
      matching_data = {
        'testNodes' => [
          {
            'nodeType' => 'Test Suite',
            'nodeIdentifier' => 'SaneVideoUITests.SaneVideoSettingsEvidenceUITests',
            'result' => 'Passed',
            'children' => [
              {
                'nodeType' => 'Test Case',
                'nodeIdentifier' => 'SaneVideoUITests.SaneVideoSettingsEvidenceUITests/testSettingsTabs()',
                'result' => 'Passed'
              },
              {
                'nodeType' => 'Test Case Run',
                'nodeIdentifier' => 'SaneVideoUITests.SaneVideoSettingsEvidenceUITests/testSettingsTabs()',
                'result' => 'Passed'
              }
            ]
          }
        ]
      }
      mismatch_data = {
        'testNodes' => [
          {
            'nodeType' => 'Test Case',
            'nodeIdentifier' => 'SaneVideoUITests.OtherTests/testDifferentAction()',
            'result' => 'Passed'
          }
        ]
      }
      suite_only_data = {
        'testNodes' => [
          {
            'nodeType' => 'Test Plan',
            'nodeIdentifier' => 'All Tests',
            'result' => 'Passed',
            'children' => [
              {
                'nodeType' => 'UI test bundle',
                'nodeIdentifier' => 'SaneVideoUITests',
                'result' => 'Passed',
                'children' => [
                  {
                    'nodeType' => 'Test Suite',
                    'nodeIdentifier' => 'SaneVideoSettingsEvidenceUITests',
                    'result' => 'Passed'
                  }
                ]
              }
            ]
          }
        ]
      }

      matching = subject.result_summary(matching_data, selector)
      mismatch = subject.result_summary(mismatch_data, selector)
      suite_only = subject.result_summary(suite_only_data, selector)
      identifier_optional_case = subject.result_summary(
        {
          'testNodes' => [
            { 'nodeType' => 'Test Case', 'name' => 'testWithoutIdentifier', 'result' => 'Passed' }
          ]
        },
        nil
      )

      assert_eq(matching[:ok], true)
      assert_eq(matching[:discovered_test_count], 1)
      assert_eq(matching[:passed_test_count], 1)
      assert_eq(matching[:matched_test_count], 1)
      assert_eq(mismatch[:ok], false)
      assert_includes(mismatch[:error], 'does not contain a passed test matching')
      assert_eq(suite_only[:ok], false)
      assert_eq(suite_only[:discovered_test_count], 0)
      assert_eq(suite_only[:error], 'xcresult contains zero test result nodes')
      assert_eq(identifier_optional_case[:ok], true)
      assert_eq(identifier_optional_case[:passed_test_count], 1)
      true
    end

    test('matches a bare target selector through the enclosing test bundle') do
      # Regression (2026-07-14): current xcresulttool emits bare
      # "Suite/testName()" identifiers with the target name only on the bundle
      # node, so SaneHosts evidence (selector "SaneHostsFeatureTests") was
      # rejected on every machine even though all tests passed.
      bundle_shaped_data = {
        'testNodes' => [
          {
            'nodeType' => 'Test Plan',
            'nodeIdentifier' => 'SaneHosts',
            'result' => 'Passed',
            'children' => [
              {
                'nodeType' => 'Unit test bundle',
                'nodeIdentifier' => 'SaneHostsFeatureTests.xctest',
                'result' => 'Passed',
                'children' => [
                  {
                    'nodeType' => 'Test Suite',
                    'nodeIdentifier' => 'ProSectionIconTests',
                    'result' => 'Passed',
                    'children' => [
                      {
                        'nodeType' => 'Test Case',
                        'nodeIdentifier' => 'ProSectionIconTests/padlockOpensWhenPro()',
                        'result' => 'Passed'
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      by_target = subject.result_summary(bundle_shaped_data, 'SaneHostsFeatureTests')
      by_target_and_suite = subject.result_summary(
        bundle_shaped_data,
        'SaneHostsFeatureTests/ProSectionIconTests/padlockOpensWhenPro'
      )
      wrong_target = subject.result_summary(bundle_shaped_data, 'SaneHostsUITests')

      assert_eq(by_target[:ok], true)
      assert_eq(by_target[:matched_test_count], 1)
      assert_eq(by_target_and_suite[:ok], true)
      assert_eq(wrong_target[:ok], false)
      assert_includes(wrong_target[:error], 'does not contain a passed test matching')
      true
    end

    test('uses the actual Mini hostname and parseable UTC timestamps by default') do
      Dir.mktmpdir('ci-helpers-') do |root|
        plan = subject.monitor_plan(
          root: root,
          scheme: 'SaneVideo',
          test_selector: nil,
          started_at: started_at,
          pid: 4321,
          nonce: 'host-time'
        )
        receipt = subject.send(
          :build_monitor_test_receipt,
          plan: plan,
          started_at: started_at,
          completed_at: started_at + 1,
          exit_status: 0,
          timed_out: false
        )

        assert_eq(receipt[:host], Socket.gethostname)
        assert_includes(receipt[:host].downcase, 'mini')
        assert_eq(Time.iso8601(receipt[:started_at]).utc_offset, 0)
        assert_eq(Time.iso8601(receipt[:completed_at]).utc_offset, 0)
      end
      true
    end

    test('prints a stable receipt marker for orchestration') do
      source = File.read(File.expand_path('ci_helpers.rb', __dir__))
      assert_includes(source, 'SANEMASTER_MONITOR_RECEIPT=#{receipt_path}')
      assert_eq(source.scan('SANEMASTER_MONITOR_RECEIPT=#{receipt_path}').length, 2)
      true
    end
  end


  test_category('Monitor test timeout cleanup') do
    test('timeout elapsed time uses a monotonic clock delta') do
      elapsed = subject.send(:monitor_test_elapsed_seconds, 100.25, now_monotonic: 104.75)
      assert_eq(elapsed, 4.5)
      true
    end

    test('targets the isolated process group, root, and every discovered descendant') do
      targets = subject.termination_targets(2468, [3001, 3002, 3001])
      source = File.read(File.join(__dir__, 'ci_helpers.rb')) +
               File.read(File.join(__dir__, 'process_tree_cleanup.rb'))

      assert_eq(targets, [-2468, 2468, 3001, 3002])
      assert_includes(source, 'pgroup: true')
      assert_includes(source, "signal_monitor_test_processes('TERM', pid, tracked_identities.keys")
      assert_includes(source, "signal_monitor_test_processes('KILL', pid, tracked_identities.keys")
      assert_includes(source, 'Timed-out test cleanup left survivors')
      true
    end

    test('does not signal reused PIDs or PGIDs whose captured identity changed') do
      root_identity = {
        pid: 2468, ppid: 1, pgid: 2468,
        start_time: 'Sun Jul 13 16:00:00 2026', command: 'original-root'
      }
      child_identity = {
        pid: 3001, ppid: 2468, pgid: 9000,
        start_time: 'Sun Jul 13 16:00:01 2026', command: 'original-child'
      }
      reused = {
        2468 => root_identity.merge(start_time: 'Sun Jul 13 17:00:00 2026', command: 'unrelated-root'),
        3001 => child_identity.merge(pgid: 7777, start_time: 'Sun Jul 13 17:00:01 2026', command: 'unrelated-child')
      }
      signals = []
      fresh_subject = CIHelpersHarness.new
      fresh_subject.define_singleton_method(:monitor_test_process_identity) { |pid| reused[pid] }
      fresh_subject.define_singleton_method(:monitor_test_send_signal) { |signal, target| signals << [signal, target] }

      fresh_subject.send(
        :signal_monitor_test_processes,
        'KILL',
        2468,
        [3001],
        root_identity: root_identity,
        tracked_identities: { 3001 => child_identity }
      )

      assert_eq(signals, [])
      true
    end

    test('keeps identity across exec and setsid observation changes') do
      captured = {
        pid: 3001, ppid: 2468, pgid: 2468,
        start_time: 'Sun Jul 13 16:00:01 2026', command: 'before-exec'
      }
      changed = captured.merge(ppid: 1, pgid: 3001, command: 'after-exec')
      assert(subject.send(:monitor_test_same_identity?, captured, changed))
      true
    end

    test('uses absolute ps despite a hostile PATH and rejects malformed snapshots') do
      Dir.mktmpdir('ci-helpers-fake-ps-') do |root|
        marker = File.join(root, 'fake-ps-ran')
        fake_ps = File.join(root, 'ps')
        File.write(fake_ps, "#!/bin/sh\ntouch '#{marker}'\nexit 9\n")
        FileUtils.chmod(0o755, fake_ps)
        original_path = ENV['PATH']
        ENV['PATH'] = root
        begin
          identity = subject.send(:monitor_test_process_identity, Process.pid)
          if subject.process_scan_available?
            assert_eq(identity[:pid], Process.pid)
          else
            assert_eq(identity, nil)
          end
          assert(!File.exist?(marker), 'cleanup discovery must never execute PATH-shadowed ps')
        ensure
          ENV['PATH'] = original_path
        end

        malformed_error = begin
          subject.parse_process_snapshot("123 1 123 S malformed\n")
          nil
        rescue StandardError => e
          e
        end
        duplicate = "123 1 123 S Sun Jul 13 16:00:00 2026 cmd\n" * 2
        duplicate_error = begin
          subject.parse_process_snapshot(duplicate)
          nil
        rescue StandardError => e
          e
        end
        assert_includes(malformed_error.message, 'Malformed process snapshot')
        assert_includes(duplicate_error.message, 'Inconsistent process snapshot')
      end
      true
    end


    test('kills a captured descendant after the original process group exits') do
      unless subject.process_scan_available?
        pid = Process.spawn(RbConfig.ruby, '-e', 'Signal.trap("TERM") { exit! 0 }; loop { sleep 1 }', pgroup: true)
        begin
          assert_eq(subject.terminate_process_tree(pid, grace_seconds: 0.2, kill_grace_seconds: 1.0), true)
          Process.wait(pid)
          assert(!subject.process_alive?(pid), 'sandbox fallback left the isolated root alive')
        ensure
          Process.kill('KILL', pid) rescue nil
          Process.wait(pid) rescue nil
        end
        next true
      end

      root_pid = nil
      child_pid = nil
      begin
        Dir.mktmpdir('ci-helpers-process-tree-') do |root|
          child_pid_path = File.join(root, 'escaped-child.pid')
          fixture_path = File.join(root, 'process-tree-fixture.rb')
          File.write(
            fixture_path,
            <<~RUBY
              child_pid_path = ARGV.fetch(0)
              child_pid = fork do
                Process.setsid
                Signal.trap('TERM', 'IGNORE')
                File.write(child_pid_path, Process.pid.to_s)
                loop { sleep 1 }
              end
              Signal.trap('TERM') { exit! 0 }
              Process.wait(child_pid)
            RUBY
          )

          root_pid = Process.spawn(RbConfig.ruby, fixture_path, child_pid_path, pgroup: true)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          until child_pid || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            child_pid = File.read(child_pid_path).to_i if File.file?(child_pid_path)
            sleep 0.02 unless child_pid
          end
          assert(child_pid.to_i.positive?, 'escaped descendant fixture did not become ready')

          assert_eq(subject.terminate_process_tree(root_pid, grace_seconds: 0.2, kill_grace_seconds: 1.0), true)
          Process.wait(root_pid)
          assert(!subject.process_alive?(child_pid), 'captured escaped descendant survived cleanup')
        end
      ensure
        [child_pid, root_pid].compact.each do |process_pid|
          Process.kill('KILL', process_pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(root_pid) if root_pid
        rescue Errno::ECHILD
          nil
        end
      end
      true
    end

    test('captures and kills a late descendant created after TERM') do
      unless subject.process_scan_available?
        pid = Process.spawn(RbConfig.ruby, '-e', 'Signal.trap("TERM", "IGNORE"); loop { sleep 1 }', pgroup: true)
        begin
          assert_eq(subject.terminate_process_tree(pid, grace_seconds: 0.1, kill_grace_seconds: 1.0), true)
          Process.wait(pid)
          assert(!subject.process_alive?(pid), 'sandbox fallback left the TERM-resistant root alive')
        ensure
          Process.kill('KILL', pid) rescue nil
          Process.wait(pid) rescue nil
        end
        next true
      end

      root_pid = nil
      late_pid = nil
      begin
        Dir.mktmpdir('ci-helpers-late-tree-') do |root|
          late_pid_path = File.join(root, 'late-child.pid')
          fixture_path = File.join(root, 'late-process-tree-fixture.rb')
          File.write(
            fixture_path,
            <<~RUBY
              late_pid_path = ARGV.fetch(0)
              terminate = false
              Signal.trap('TERM') { terminate = true }
              sleep 0.01 until terminate
              child = fork do
                Process.setsid
                Signal.trap('TERM', 'IGNORE')
                File.write(late_pid_path, Process.pid.to_s)
                loop { sleep 1 }
              end
              sleep 0.3
              exit! 0
            RUBY
          )
          root_pid = Process.spawn(RbConfig.ruby, fixture_path, late_pid_path, pgroup: true)
          assert_eq(subject.terminate_process_tree(root_pid, grace_seconds: 0.5, kill_grace_seconds: 1.0), true)
          deadline = Time.now + 2
          sleep 0.01 until File.file?(late_pid_path) || Time.now >= deadline
          late_pid = File.read(late_pid_path).to_i
          assert(late_pid.positive?, 'late descendant fixture did not run')
          assert(!subject.process_alive?(late_pid), 'late escaped descendant survived cleanup')
        end
      ensure
        [late_pid, root_pid].compact.each do |process_pid|
          Process.kill('KILL', process_pid)
        rescue Errno::ESRCH
          nil
        end
        begin
          Process.wait(root_pid) if root_pid
        rescue Errno::ECHILD
          nil
        end
      end
      true
    end
  end


  test_category('Monitor test progress output') do
    test('reads only a bounded tail from a large growing log') do
      Dir.mktmpdir('ci-helpers-large-log-') do |root|
        path = File.join(root, 'xcodebuild.log')
        File.open(path, 'wb') do |file|
          file.write("OLD FAILURE SHOULD NOT BE READ\n")
          file.write('x' * (5 * 1024 * 1024))
          file.write("\nTest Case '-[CurrentTests testOne]' passed\n")
          file.write("Test Case '-[CurrentTests testTwo]' passed\n")
        end

        lines = subject.log_lines(path, pattern: /Test Case/, limit: 10, max_bytes: 1024)
        source = File.read(File.join(__dir__, 'ci_helpers.rb'))

        assert_eq(lines.length, 2)
        assert_includes(lines.first, 'testOne')
        assert_includes(lines.last, 'testTwo')
        assert(!lines.any? { |line| line.include?('OLD FAILURE') }, 'bounded tail must not scan the full log')
        assert(!source.include?('File.readlines(path'), 'progress output must not load the whole log')
      end
      true
    end
  end
end)
