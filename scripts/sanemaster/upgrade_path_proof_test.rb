#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'rbconfig'
require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative 'ci_helpers'
require_relative 'upgrade_path_proof'

class UpgradePathProofHarness
  include SaneMasterModules::UpgradePathProof

  attr_accessor :result_summary, :force_identity_binding_failure, :unbound_cleanup_pid

  def monitor_test_result_summary(_bundle, _selector)
    result_summary || {
      ok: true,
      discovered_test_count: 3,
      passed_test_count: 3,
      matched_test_count: 1,
      error: nil
    }
  end

  def upgrade_path_bind_spawned_runner(pid, **attributes)
    return nil if force_identity_binding_failure

    super
  end

  def upgrade_path_cleanup_unbound_spawn!(pid, **attributes)
    self.unbound_cleanup_pid = pid
    super
  end
end

class UpgradeMonitorBindingHarness
  include SaneMasterModules::CIHelpers

  def plan(**attributes)
    send(:monitor_test_plan, **attributes)
  end

  def receipt(**attributes)
    send(:build_monitor_test_receipt, **attributes)
  end
end

include TestFramework

def assert_raises(error_class = StandardError)
  begin
    yield
  rescue error_class => error
    return error
  end
  raise "Expected #{error_class} to be raised"
end

UPGRADE_RUN_ID = '20260713T120000-1234567890abcdef12345678'
UPGRADE_NONCE = 'a' * 64

def monitor_receipt_fixture(root, started_at:, finished_at:, scheme: 'Example',
                            selector: 'ExampleTests/UpgradeTests/testUpgrade',
                            package_path: nil,
                            test_plan: nil,
                            destination: nil,
                            upgrade_run_id: UPGRADE_RUN_ID, upgrade_nonce: UPGRADE_NONCE)
  binding = Digest::SHA256.hexdigest("#{upgrade_run_id}\0#{upgrade_nonce}")[0, 16]
  run = File.join(root, 'outputs', 'monitor-tests', "run-1-upgrade-#{binding}")
  bundle = File.join(run, 'test.xcresult')
  FileUtils.mkdir_p(bundle)
  File.write(File.join(bundle, 'Info.plist'), 'plist')
  receipt = {
    'source' => 'SaneMaster.monitor_tests',
    'status' => 'passed',
    'run_id' => File.basename(run),
    'upgrade_run_id' => upgrade_run_id,
    'upgrade_nonce' => upgrade_nonce,
    'host' => Socket.gethostname,
    'scheme' => scheme,
    'package_path' => package_path,
    'test_plan' => test_plan,
    'destination' => destination,
    'test_selector' => selector,
    'started_at' => started_at.iso8601(6),
    'completed_at' => finished_at.iso8601(6),
    'result_bundle_path' => bundle,
    'result_bundle_exists' => true,
    'result_bundle_valid' => true,
    'xcresult_verified' => true,
    'xcresult_path' => bundle,
    'discovered_test_count' => 3,
    'passed_test_count' => 3,
    'matched_test_count' => 1,
    'exit_status' => 0,
    'timed_out' => false,
    'command' => ['xcodebuild', 'test']
  }
  path = File.join(run, 'receipt.json')
  File.write(path, JSON.pretty_generate(receipt))
  [path, bundle]
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

def wait_until_dead(pid, timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  while process_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    sleep 0.05
  end
  !process_alive?(pid)
end

exit(run_tests('Upgrade Path Proof Security Tests') do
  subject = UpgradePathProofHarness.new
  monitor_subject = UpgradeMonitorBindingHarness.new

  test_category('canonical runner and concrete evidence') do
    test('runner is fixed to canonical SaneMaster monitor_tests with an exact selector') do
      argv = subject.send(
        :upgrade_path_runner_argv,
        scheme: 'Example',
        test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
        timeout_seconds: 120
      )
      assert_eq(argv[0], File.realpath(RbConfig.ruby))
      assert_eq(argv[1], File.realpath(File.join(__dir__, '..', 'SaneMaster.rb')))
      assert_eq(argv[2..], [
        'monitor_tests', '--scheme', 'Example', '--test',
        'ExampleTests/UpgradeTests/testUpgrade', '--timeout', '120'
      ])
      environment = subject.send(:upgrade_path_runner_env, UPGRADE_RUN_ID, UPGRADE_NONCE)
      assert_eq(environment['SANEMASTER_UPGRADE_RUN_ID'], UPGRADE_RUN_ID)
      assert_eq(environment['SANEMASTER_UPGRADE_NONCE'], UPGRADE_NONCE)
      true
    end

    test('runner binds an optional test plan to the canonical monitor command') do
      argv = subject.send(
        :upgrade_path_runner_argv,
        scheme: 'SaneHosts',
        test_plan: 'SaneHosts',
        test_selector: 'SaneHostsFeatureTests/ProfileStoreEssentialsPolicyTests/createsEssentialsAlongsideExistingEntries',
        timeout_seconds: 120
      )

      assert_includes(argv, '--test-plan')
      assert_eq(argv[argv.index('--test-plan') + 1], 'SaneHosts')
      true
    end

    test('runner binds an optional package path to the canonical monitor command') do
      argv = subject.send(
        :upgrade_path_runner_argv,
        scheme: 'SaneHostsFeature-Package',
        package_path: 'SaneHostsPackage',
        test_selector: 'SaneHostsFeatureTests/ProfileStoreEssentialsPolicyTests/createsEssentialsAlongsideExistingEntries',
        timeout_seconds: 120
      )

      assert_includes(argv, '--package-path')
      assert_eq(argv[argv.index('--package-path') + 1], 'SaneHostsPackage')
      true
    end

    test('runner binds an optional simulator destination to the canonical monitor command') do
      destination = 'platform=iOS Simulator,name=SaneLot-iPhone'
      argv = subject.send(
        :upgrade_path_runner_argv,
        scheme: 'SaneLot',
        destination: destination,
        test_selector: 'SaneLotTests/P0SafetyTests/testUpgrade',
        timeout_seconds: 120
      )

      assert_includes(argv, '--destination')
      assert_eq(argv[argv.index('--destination') + 1], destination)
      true
    end

    test('monitor runtime echoes the fresh upgrade binding and binds it into the xcresult run path') do
      Dir.mktmpdir('upgrade-monitor-binding-') do |root|
        started_at = Time.now.utc
        plan = monitor_subject.plan(
          root: root,
          scheme: 'Example',
          test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
          started_at: started_at,
          pid: 4321,
          nonce: 'monitor',
          upgrade_run_id: UPGRADE_RUN_ID,
          upgrade_nonce: UPGRADE_NONCE
        )
        binding = Digest::SHA256.hexdigest("#{UPGRADE_RUN_ID}\0#{UPGRADE_NONCE}")[0, 16]
        assert(plan[:run_id].end_with?("-upgrade-#{binding}"), 'monitor run path omitted upgrade challenge binding')
        assert_eq(File.basename(File.dirname(plan[:result_bundle_path])), plan[:run_id])

        FileUtils.mkdir_p(plan[:result_bundle_path])
        File.write(File.join(plan[:result_bundle_path], 'Info.plist'), 'plist')
        File.write(plan[:log_path], 'test log')
        receipt = monitor_subject.receipt(
          plan: plan,
          started_at: started_at,
          completed_at: started_at + 1,
          exit_status: 0,
          timed_out: false,
          result_summary: {
            ok: true,
            discovered_test_count: 1,
            passed_test_count: 1,
            matched_test_count: 1,
            error: nil
          }
        )
        assert_eq(receipt[:run_id], plan[:run_id])
        assert_eq(receipt[:upgrade_run_id], UPGRADE_RUN_ID)
        assert_eq(receipt[:upgrade_nonce], UPGRADE_NONCE)
      end
      true
    end

    test('independently validates a real scoped xcresult and matching passed test') do
      Dir.mktmpdir('upgrade-proof-') do |root|
        started_at = Time.now.utc
        receipt_path, = monitor_receipt_fixture(
          root,
          started_at: started_at,
          finished_at: started_at + 1
        )
        receipt, summary = subject.send(
          :upgrade_path_validate_monitor_receipt!,
          receipt_path,
          project_root: root,
          scheme: 'Example',
          test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
          started_at: started_at,
          finished_at: started_at + 2,
          run_id: UPGRADE_RUN_ID,
          nonce: UPGRADE_NONCE
        )
        assert_eq(receipt['source'], 'SaneMaster.monitor_tests')
        assert_eq(summary[:matched_test_count], 1)
      end
      true
    end

    test('rejects echoed pass JSON without a concrete xcresult bundle') do
      Dir.mktmpdir('upgrade-proof-forgery-') do |root|
        started_at = Time.now.utc
        receipt_path, bundle = monitor_receipt_fixture(
          root,
          started_at: started_at,
          finished_at: started_at + 1
        )
        FileUtils.remove_entry(bundle)
        error = assert_raises(StandardError) do
          subject.send(
            :upgrade_path_validate_monitor_receipt!,
            receipt_path,
            project_root: root,
            scheme: 'Example',
            test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
            started_at: started_at,
            finished_at: started_at + 2,
            run_id: UPGRADE_RUN_ID,
            nonce: UPGRADE_NONCE
          )
        end
        assert(
          error.message.include?('No such file') || error.message.include?('result bundle'),
          "expected missing concrete result bundle rejection, got: #{error.message}"
        )
      end
      true
    end


    test('rejects a prior monitor receipt and xcresult that lack the fresh run binding') do
      Dir.mktmpdir('upgrade-proof-replay-') do |root|
        started_at = Time.now.utc
        receipt_path, = monitor_receipt_fixture(
          root,
          started_at: started_at,
          finished_at: started_at + 1,
          upgrade_run_id: '20260713T115900-aaaaaaaaaaaaaaaaaaaaaaaa',
          upgrade_nonce: 'b' * 64
        )
        error = assert_raises(StandardError) do
          subject.send(
            :upgrade_path_validate_monitor_receipt!,
            receipt_path,
            project_root: root,
            scheme: 'Example',
            test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
            started_at: started_at,
            finished_at: started_at + 2,
            run_id: UPGRADE_RUN_ID,
            nonce: UPGRADE_NONCE
          )
        end
        assert(
          error.message.include?('upgrade challenge') || error.message.include?('upgrade_run_id'),
          "expected replay binding rejection, got: #{error.message}"
        )
      end
      true
    end

    test('rejects an xcresult path outside the monitor receipt run directory') do
      Dir.mktmpdir('upgrade-proof-rewrap-') do |root|
        started_at = Time.now.utc
        receipt_path, = monitor_receipt_fixture(root, started_at: started_at, finished_at: started_at + 1)
        receipt = JSON.parse(File.read(receipt_path))
        prior_bundle = File.join(root, 'outputs', 'monitor-tests', 'prior-run', 'test.xcresult')
        FileUtils.mkdir_p(prior_bundle)
        File.write(File.join(prior_bundle, 'Info.plist'), 'plist')
        receipt['result_bundle_path'] = prior_bundle
        receipt['xcresult_path'] = prior_bundle
        File.write(receipt_path, JSON.pretty_generate(receipt))

        error = assert_raises(StandardError) do
          subject.send(
            :upgrade_path_validate_monitor_receipt!,
            receipt_path,
            project_root: root,
            scheme: 'Example',
            test_selector: 'ExampleTests/UpgradeTests/testUpgrade',
            started_at: started_at,
            finished_at: started_at + 2,
            run_id: UPGRADE_RUN_ID,
            nonce: UPGRADE_NONCE
          )
        end
        assert_includes(error.message, 'not bound to its receipt run')
      end
      true
    end

    test('rejects symlinked entries in the retained xcresult manifest') do
      Dir.mktmpdir('upgrade-proof-symlink-') do |root|
        started_at = Time.now.utc
        _receipt_path, bundle = monitor_receipt_fixture(
          root,
          started_at: started_at,
          finished_at: started_at + 1
        )
        File.symlink('/tmp', File.join(bundle, 'escaped'))
        error = assert_raises(StandardError) do
          subject.send(:upgrade_path_result_bundle_manifest!, bundle, root)
        end
        assert_includes(error.message, 'symlink')
      end
      true
    end

    test('accepts exactly one canonical monitor receipt path and rejects an external path') do
      Dir.mktmpdir('upgrade-proof-path-') do |root|
        started_at = Time.now.utc
        receipt_path, = monitor_receipt_fixture(root, started_at: started_at, finished_at: started_at + 1)
        log = File.join(root, 'command.log')
        File.write(log, "SANEMASTER_MONITOR_RECEIPT=#{receipt_path}\n")
        assert_eq(subject.send(:upgrade_path_monitor_receipt_path!, log, root), File.realpath(receipt_path))

        File.write(log, "SANEMASTER_MONITOR_RECEIPT=/etc/hosts\n")
        assert_raises(StandardError) { subject.send(:upgrade_path_monitor_receipt_path!, log, root) }
      end
      true
    end
  end

  test_category('identity-bound timeout cleanup') do
    test('does not release the runner and reaps it when initial identity binding fails') do
      Dir.mktmpdir('upgrade-bind-failure-') do |root|
        marker = File.join(root, 'runner-executed')
        subject.force_identity_binding_failure = true
        error = assert_raises(StandardError) do
          subject.send(
            :upgrade_path_spawn,
            [File.realpath(RbConfig.ruby), '-e', 'File.write(ARGV.fetch(0), "executed")', marker],
            { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home, 'LANG' => 'C', 'LC_ALL' => 'C' },
            root,
            File.join(root, 'command.log'),
            1
          )
        end
        assert_includes(error.message, 'Could not bind canonical upgrade runner identity')
        assert(!File.exist?(marker), 'runner executed before its identity was bound')
        assert(subject.unbound_cleanup_pid, 'binding failure did not enter exact-child cleanup')
        assert(wait_until_dead(subject.unbound_cleanup_pid), 'unbound runner survived cleanup')
      ensure
        subject.force_identity_binding_failure = false
        subject.unbound_cleanup_pid = nil
      end
      true
    end

    test('kills a tracked descendant that escapes into a new session on timeout') do
      Dir.mktmpdir('upgrade-timeout-') do |root|
        pid_path = File.join(root, 'escaped.pid')
        script = <<~'RUBY'
          child = fork do
            Process.setsid
            File.write(ARGV.fetch(0), Process.pid.to_s)
            sleep 30
          end
          sleep 30
        RUBY
        unless subject.send(:monitor_test_process_scan_available?)
          error = assert_raises(StandardError) do
            subject.send(
              :upgrade_path_spawn,
              [File.realpath(RbConfig.ruby), '-e', script, pid_path],
              { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home, 'LANG' => 'C', 'LC_ALL' => 'C' },
              root,
              File.join(root, 'command.log'),
              0.5
            )
          end
          assert_includes(error.message, 'Could not bind canonical upgrade runner identity')
          assert(!File.exist?(pid_path), 'sandboxed runner executed before identity binding')
          next true
        end

        result = subject.send(
          :upgrade_path_spawn,
          [File.realpath(RbConfig.ruby), '-e', script, pid_path],
          { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home, 'LANG' => 'C', 'LC_ALL' => 'C' },
          root,
          File.join(root, 'command.log'),
          0.5
        )
        escaped_pid = Integer(File.read(pid_path))
        assert_eq(result[:timed_out], true)
        assert(wait_until_dead(escaped_pid), "escaped descendant #{escaped_pid} survived timeout cleanup")
      end
      true
    end

    test('cleans a tracked escaped descendant even when the root exits successfully') do
      Dir.mktmpdir('upgrade-exit-cleanup-') do |root|
        pid_path = File.join(root, 'escaped.pid')
        script = <<~'RUBY'
          fork do
            Process.setsid
            File.write(ARGV.fetch(0), Process.pid.to_s)
            sleep 30
          end
          sleep 0.3
          exit 0
        RUBY
        unless subject.send(:monitor_test_process_scan_available?)
          error = assert_raises(StandardError) do
            subject.send(
              :upgrade_path_spawn,
              [File.realpath(RbConfig.ruby), '-e', script, pid_path],
              { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home, 'LANG' => 'C', 'LC_ALL' => 'C' },
              root,
              File.join(root, 'command.log'),
              5
            )
          end
          assert_includes(error.message, 'Could not bind canonical upgrade runner identity')
          assert(!File.exist?(pid_path), 'sandboxed runner executed before identity binding')
          next true
        end

        result = subject.send(
          :upgrade_path_spawn,
          [File.realpath(RbConfig.ruby), '-e', script, pid_path],
          { 'PATH' => '/usr/bin:/bin', 'HOME' => Dir.home, 'LANG' => 'C', 'LC_ALL' => 'C' },
          root,
          File.join(root, 'command.log'),
          5
        )
        escaped_pid = Integer(File.read(pid_path))
        assert_eq(result[:success], true)
        assert(wait_until_dead(escaped_pid), "escaped descendant #{escaped_pid} survived successful runner exit")
      end
      true
    end
  end
end)
