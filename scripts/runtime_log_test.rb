#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'runtime_log'
require_relative 'sane_test'
require_relative 'sanemaster/test_mode'
require 'rbconfig'
require 'stringio'

include TestFramework

# Real subprocesses with synthetic text prove lifecycle without starting an app.
def fake_log_command(extra = 'sleep 20')
  [RbConfig.ruby, '-e', "$stdout.sync = true; puts 'Filtering the log data using fixture'; #{extra}"]
end

def log_receipt(log)
  JSON.parse(File.read(log.receipt_path))
end

def await_log_state(log, state, timeout: 4)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = log_receipt(log)
    return value if value['state'] == state
    raise "expected #{state}, got #{value}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
end

def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
end

exit(run_tests('Saved runtime log lifecycle') do
  test_category('Launch build inputs') do
    %w[project.yml project.yaml Package.resolved Package.swift
       Fixture.xcodeproj/project.pbxproj
       Fixture.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
       Config/Release.xcconfig App/Info.plist App/App.entitlements
       App/PrivacyInfo.xcprivacy App/Assets.xcassets/Heart.imageset/Contents.json].each do |input|
      test("newer #{input} requires rebuild before launch") do
        Dir.mktmpdir('launch-freshness') do |dir|
          Dir.chdir(dir) do
            app = File.join(dir, 'Fixture.app')
            binary = File.join(app, 'Contents/MacOS/Fixture')
            FileUtils.mkdir_p(File.dirname(binary))
            File.write(binary, 'fixture, never executed')
            File.chmod(0o755, binary)
            File.utime(Time.now - 120, Time.now - 120, binary)
            FileUtils.mkdir_p(File.dirname(input))
            File.write(input, 'new dependency or configuration')
            harness = Object.new.extend(SaneMasterModules::TestMode)
            harness.define_singleton_method(:project_name) { 'Fixture' }
            harness.define_singleton_method(:ensure_research_gate_clear!) { |_kind| true }
            harness.define_singleton_method(:launch_build_config) { |_args| 'Release' }
            harness.define_singleton_method(:built_app_candidates) { |_config| [app] }
            rebuilt = false
            staged = false
            harness.define_singleton_method(:run_build_command) { |**_args| rebuilt = true; false }
            harness.define_singleton_method(:stage_to_canonical_local_app_path) { |_path| staged = true; throw :unexpected_launch }
            catch(:unexpected_launch) { harness.launch_app([]) }
            assert(rebuilt, "newer #{input} did not request a rebuild")
            assert(!staged, 'failed rebuild must not stage or launch the stale binary')
          end
        end
        true
      end
    end

    test('generated outputs and dependencies cannot make a build look stale') do
      Dir.mktmpdir('launch-input-exclusions') do |dir|
        Dir.chdir(dir) do
          wanted = %w[Core/Feature.swift project.yml Package.resolved]
          ignored = %w[outputs/receipt/Info.plist build/Package.resolved .build/checkouts/Other/Package.swift
                       DerivedData/Fixture/Info.plist vendor/Other/File.swift node_modules/pkg/project.yml]
          (wanted + ignored).each do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, 'fixture')
          end
          harness = Object.new.extend(SaneMasterModules::TestMode)
          assert_eq(harness.send(:project_build_inputs).sort, wanted.sort)
        end
      end
      true
    end
  end

  test_category('Native process lifecycle') do
    test('stream is ready before launch and quiet capture preserves startup evidence') do
      Dir.mktmpdir('runtime-log-test') do |dir|
        trigger = File.join(dir, 'launch')
        code = "100.times { break if File.exist?(#{trigger.inspect}); sleep 0.02 }; puts 'customer startup event'; sleep 20"
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command(code)).start
        assert_eq(log_receipt(log)['state'], 'recording')
        File.write(trigger, 'launched')
        log.launched!([Process.pid])
        log.detach
        sleep 0.15
        log.stop
        receipt = await_log_state(log, 'stopped')
        assert_includes(File.read(log.path), 'customer startup event')
        assert_eq(receipt['app_pids'], [Process.pid])
        assert_eq(receipt['stop_reason'], 'stop_requested')
        assert(!process_alive?(receipt['log_pid']), 'owned log process leaked')
        assert_eq(File.stat(log.path).mode & 0o777, 0o600)
        assert_eq(File.stat(log.receipt_path).mode & 0o777, 0o600)
      ensure
        log&.stop
      end
      true
    end

    test('logger startup failure prevents the launch body and records the failure') do
      Dir.mktmpdir('runtime-log-failure') do |dir|
        launched = false
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: [RbConfig.ruby, '-e', 'warn "fixture failure"; exit 17'])
        begin
          log.start
          launched = true
        rescue RuntimeError => e
          assert_includes(e.message, 'before launch')
        end
        assert(!launched, 'launch must not run without a ready stream')
        receipt = log_receipt(log)
        assert_eq(receipt['state'], 'failed')
        assert_includes(File.read(log.path), 'fixture failure')
        assert(!process_alive?(receipt['log_pid']), 'failed logger leaked')
      ensure
        log&.stop
      end
      true
    end

    test('launch failure stops the owned stream in the real sane_test workflow') do
      Dir.mktmpdir('runtime-log-launch-failure') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command).start
        runner = SaneTest.allocate
        %i[kill_local clean_local build_debug stage_canonical_copy_local dedupe_accessibility_entries_local
           ensure_developer_id_signature_local enforce_single_copy_local].each { |name| runner.define_singleton_method(name) {} }
        runner.define_singleton_method(:start_runtime_log) { log }
        runner.define_singleton_method(:launch_local) { raise 'fixture launch failed' }
        runner.define_singleton_method(:step) { |_name, &block| block.call }
        runner.instance_variable_set(:@no_logs, true)
        begin
          runner.send(:run_local)
        rescue RuntimeError => e
          assert_eq(e.message, 'fixture launch failed')
        end
        receipt = await_log_state(log, 'stopped')
        assert(!process_alive?(receipt['log_pid']), 'launch failure leaked its logger')
      ensure
        log&.stop
      end
      true
    end

    test('app exit stops capture even after the launcher returned quietly') do
      Dir.mktmpdir('runtime-log-app-exit') do |dir|
        app_pid = spawn(RbConfig.ruby, '-e', 'sleep 0.3')
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command).start
        log.launched!([app_pid]).detach
        Process.wait(app_pid)
        receipt = await_log_state(log, 'stopped')
        assert_eq(receipt['stop_reason'], 'app_exited')
        assert(!process_alive?(receipt['log_pid']), 'app exit leaked its logger')
      ensure
        log&.stop
      end
      true
    end

    test('deadline stops an idle stream while the app remains alive') do
      Dir.mktmpdir('runtime-log-deadline') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', seconds: 0.4, command: fake_log_command).start
        log.launched!([Process.pid]).detach
        receipt = await_log_state(log, 'stopped')
        assert_eq(receipt['stop_reason'], 'deadline')
        assert(!process_alive?(receipt['log_pid']), 'deadline leaked its logger')
      ensure
        log&.stop
      end
      true
    end

    test('unexpected stream death remains a failed receipt') do
      Dir.mktmpdir('runtime-log-died') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command('sleep 0.3; exit 5')).start
        log.launched!([Process.pid]).detach
        receipt = await_log_state(log, 'failed')
        assert_includes(receipt['error'], 'capture was required')
      ensure
        log&.stop
      end
      true
    end

    test('foreground interruption stops capture and preserves already saved events') do
      Dir.mktmpdir('runtime-log-interrupt') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command).start
        log.launched!([Process.pid])
        output = Object.new
        output.define_singleton_method(:write) { |_text| raise Interrupt }
        begin
          log.follow(output)
        rescue Interrupt
          nil
        end
        receipt = await_log_state(log, 'stopped')
        assert_includes(File.read(log.path), 'Filtering the log data using fixture')
        assert(!process_alive?(receipt['log_pid']), 'interrupt leaked its logger')
      ensure
        log&.stop
      end
      true
    end

    [true, false].each do |launch_ok|
      test("SaneMaster launch starts saved capture before open and handles result #{launch_ok}") do
        Dir.mktmpdir('runtime-log-sanemaster') do |dir|
          app = File.join(dir, 'Fixture.app')
          binary = File.join(app, 'Contents/MacOS/Fixture')
          FileUtils.mkdir_p(File.dirname(binary))
          File.write(binary, 'fixture, never executed')
          File.chmod(0o755, binary)
          log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command).start
          harness = Object.new.extend(SaneMasterModules::TestMode)
          harness.define_singleton_method(:project_name) { 'Fixture' }
          harness.define_singleton_method(:ensure_research_gate_clear!) { |_kind| true }
          harness.define_singleton_method(:launch_build_config) { |_args| 'Release' }
          harness.define_singleton_method(:built_app_candidates) { |_config| [app] }
          harness.define_singleton_method(:project_build_inputs) { [] }
          harness.define_singleton_method(:stage_to_canonical_local_app_path) { |_path| app }
          harness.define_singleton_method(:protected_local_app_paths) { |_path| [app] }
          harness.define_singleton_method(:trash_noncanonical_local_app_copies) { |**_args| 0 }
          %i[clear_gatekeeper_staging_attributes ensure_single_instance
             kill_other_saneapps_processes].each { |name| harness.define_singleton_method(name) { |*_args| } }
          harness.define_singleton_method(:reconcile_accessibility_trust_local) { |*_args| raise 'Routine launch must preserve existing TCC grants' }
          harness.define_singleton_method(:direct_binary_launch_required?) { |_path| false }
          harness.define_singleton_method(:launch_path_gatekeeper_ready?) { |_path, **_args| true }
          harness.define_singleton_method(:start_runtime_log) { |_args| log }
          harness.define_singleton_method(:launched_process_matches?) { |_path| true }
          harness.define_singleton_method(:local_app_processes) { |_path| ["#{Process.pid} fixture"] }
          observed_state = nil
          harness.define_singleton_method(:system) { |*_args| observed_state = log_receipt(log)['state']; launch_ok }
          result = harness.launch_app(['--quiet-logs'])
          assert_eq(observed_state, 'recording')
          assert_eq(result, launch_ok)
          if launch_ok
            assert_eq(log_receipt(log)['state'], 'recording')
            log.stop
          end
          receipt = await_log_state(log, 'stopped')
          assert(!process_alive?(receipt['log_pid']), 'SaneMaster launch leaked the owned logger')
        ensure
          log&.stop
        end
        true
      end
    end

    test('silent logger cannot claim readiness and is killed at the startup deadline') do
      Dir.mktmpdir('runtime-log-silent') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', startup_seconds: 0.2,
                                 command: [RbConfig.ruby, '-e', 'sleep 20'])
        begin
          log.start
          raise 'silent logger was accepted'
        rescue RuntimeError => e
          assert_includes(e.message, 'acknowledge')
        end
        receipt = log_receipt(log)
        assert_eq(receipt['state'], 'failed')
        assert(!process_alive?(receipt['log_pid']), 'silent logger leaked')
      ensure
        log&.stop
      end
      true
    end

    test('launcher loss before app launch cleans up the ready stream') do
      Dir.mktmpdir('runtime-log-launcher-exit') do |dir|
        log = SaneRuntimeLog.new(project_dir: dir, app_name: 'Fixture', command: fake_log_command).start
        log.detach
        receipt = await_log_state(log, 'stopped')
        assert_eq(receipt['stop_reason'], 'launcher_exited_before_launch')
        assert(!process_alive?(receipt['log_pid']), 'abandoned launch leaked its logger')
      ensure
        log&.stop
      end
      true
    end

    test('quiet supervisor survives launcher exit and the receipt stop command reaps it') do
      Dir.mktmpdir('runtime-log-detached') do |dir|
        receipt_pointer = File.join(dir, 'receipt-path')
        code = <<~'CODE'
          require 'runtime_log'
          require 'rbconfig'
          command = [RbConfig.ruby, '-e', "$stdout.sync=true; puts 'Filtering the log data using fixture'; sleep 20"]
          log = SaneRuntimeLog.new(project_dir: ARGV[2], app_name: 'Fixture', seconds: 5, command: command).start
          log.launched!([ARGV[0].to_i]).detach
          File.write(ARGV[1], log.receipt_path)
        CODE
        launcher = spawn(RbConfig.ruby, '-I', __dir__, '-e', code, Process.pid.to_s, receipt_pointer, dir,
                         out: File::NULL, err: File::NULL)
        Process.wait(launcher)
        receipt_path = File.read(receipt_pointer)
        sleep 0.15
        receipt = JSON.parse(File.read(receipt_path))
        assert_eq(receipt['state'], 'recording')
        assert(process_alive?(receipt['supervisor_pid']), 'supervisor died with launcher')
        assert(system(RbConfig.ruby, File.join(__dir__, 'runtime_log.rb'), 'stop', receipt_path))
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
        loop do
          receipt = JSON.parse(File.read(receipt_path))
          break if receipt['state'] == 'stopped'
          raise 'receipt stop did not finish' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.05
        end
        assert(!process_alive?(receipt['log_pid']), 'receipt stop leaked stream')
        assert_eq(receipt['stop_reason'], 'stop_requested')
      ensure
        File.write(File.join(File.dirname(receipt_path), 'stop'), '') if receipt_path && File.directory?(File.dirname(receipt_path))
      end
      true
    end

    test('log duration rejects missing and unbounded input') do
      assert_eq(SaneRuntimeLog.duration([]), 1800)
      assert_eq(SaneRuntimeLog.duration(['--log-seconds', '12']), 12)
      [[], ['0'], ['-1'], ['21601'], ['NaN'], ['bad']].each do |suffix|
        failed = false
        begin
          SaneRuntimeLog.duration(['--log-seconds', *suffix])
        rescue ArgumentError
          failed = true
        end
        assert(failed, "invalid duration accepted: #{suffix}")
      end
      true
    end
  end
end)
