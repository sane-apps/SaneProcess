#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'machine_cleanup'

class MachineCleanupRetentionHarness
  include SaneMasterModules::MachineCleanup

  attr_reader :events

  FakeStatus = Struct.new(:ok) do
    def success?
      ok
    end
  end

  def initialize(sizes: {}, snapshots: nil, hdiutil_info: '', hdiutil_ok: true)
    @sizes = sizes
    @snapshots = snapshots || [{
      ok: true,
      available_gb: 3,
      available_bytes: 3 * 1024 * 1024 * 1024,
      capacity: '99%'
    }]
    @events = []
    @hdiutil_info = hdiutil_info
    @hdiutil_ok = hdiutil_ok
  end

  def running_on_mini_host?
    true
  end

  def machine_cleanup_ps_rows
    []
  end

  def machine_cleanup_disk_snapshot
    @snapshots.shift || @snapshots.last
  end

  def path_size_gb(path)
    @sizes.fetch(File.expand_path(path), 0.0)
  end

  def trash_path(path)
    @events << [:trash, File.expand_path(path)]
    true
  end

  def empty_user_trash
    result = super
    @events << [:empty, File.expand_path('~/.Trash')] if result
    result
  end

  def machine_cleanup_hdiutil_info
    [@hdiutil_info, FakeStatus.new(@hdiutil_ok)]
  end

  def system(*args, **kwargs)
    return true if args.first == 'xcrun'

    super
  end
end

include TestFramework

def with_retention_home
  Dir.mktmpdir('machine-cleanup-retention-') do |home|
    old_home = ENV['HOME']
    ENV['HOME'] = home
    yield home
  ensure
    ENV['HOME'] = old_home
  end
end

def retention_options(empty_trash: false)
  {
    apply: true,
    empty_trash: empty_trash,
    host: 'local',
    server: false,
    min_free_gb: 30,
    cache_threshold_gb: 99,
    deriveddata_age_days: 999,
    trash_threshold_gb: 1,
    preserve_apps: []
  }
end

def create_evidence_run(root, name, artifacts, old_time)
  run = File.join(root, name)
  FileUtils.mkdir_p(run)
  File.write(File.join(run, 'receipt.json'), '{}')
  artifacts.each { |artifact| FileUtils.mkdir_p(File.join(run, artifact)) }
  Dir.children(run).each do |entry|
    path = File.join(run, entry)
    File.utime(old_time, old_time, path)
  end
  File.utime(old_time, old_time, run)
  run
end

exit(run_tests('SaneMaster Machine Cleanup Retention Tests') do
  test_category('bounded generated evidence') do
    test('keeps receipts while pruning heavy children outside retention') do
      with_retention_home do |home|
        repo = File.join(home, 'SaneApps/apps/SaneLot')
        verify = File.join(repo, 'outputs/verify')
        monitor = File.join(repo, 'outputs/monitor-tests')
        FileUtils.mkdir_p([verify, monitor])
        old_time = Time.now - (3 * 60 * 60)
        sizes = {}

        verify_runs = 8.times.map do |index|
          name = format('20260801T0000%02dZ-run', index)
          run = create_evidence_run(verify, name, ['DerivedData', '01-test.xcresult'], old_time + index)
          %w[DerivedData 01-test.xcresult].each { |child| sizes[File.join(run, child)] = 1.0 }
          run
        end
        File.write(File.join(repo, 'SESSION_HANDOFF.md'), "keep #{File.basename(verify_runs.first)}\n")

        monitor_runs = 10.times.map do |index|
          name = format('20260801T0100%02dZ-run', index)
          run = create_evidence_run(monitor, name, ['test.xcresult', 'attachments'], old_time + index)
          %w[test.xcresult attachments].each { |child| sizes[File.join(run, child)] = 1.0 }
          run
        end

        subject = MachineCleanupRetentionHarness.new(sizes: sizes)
        plan = subject.send(:build_machine_cleanup_plan, retention_options)
        paths = plan[:actions].select { |action| action[:category] == 'generated_evidence' }
                              .map { |action| action[:path] }

        assert_eq(paths.sort, [
          File.join(verify_runs[1], 'DerivedData'),
          File.join(verify_runs[1], '01-test.xcresult'),
          File.join(verify_runs[2], 'DerivedData'),
          File.join(verify_runs[2], '01-test.xcresult'),
          File.join(monitor_runs[0], 'test.xcresult'),
          File.join(monitor_runs[1], 'test.xcresult')
        ].sort)
        assert(!paths.any? { |path| File.basename(path) == 'receipt.json' }, 'receipts must remain')
        assert(!paths.any? { |path| File.basename(path) == 'attachments' }, 'attachments must remain')
        paths.each { |path| assert_eq(subject.send(:machine_cleanup_safe_path?, path), true) }
      end
    end

    test('only canonical Mini pressure prunes canonical runs and protected apps remain intact') do
      with_retention_home do |home|
        repo = File.join(home, 'SaneApps/apps/SaneLot')
        verify = File.join(repo, 'outputs/verify')
        FileUtils.mkdir_p(verify)
        old_time = Time.now - (3 * 60 * 60)
        sizes = {}
        runs = 6.times.map do |index|
          run = create_evidence_run(verify, format('20260801T0200%02dZ-run', index), ['test.xcresult'], old_time + index)
          sizes[File.join(run, 'test.xcresult')] = 1.0
          run
        end
        noncanonical = create_evidence_run(verify, 'manual-debug-run', ['test.xcresult'], old_time)
        sizes[File.join(noncanonical, 'test.xcresult')] = 1.0
        subject = MachineCleanupRetentionHarness.new(sizes: sizes)

        protected = subject.send(
          :machine_cleanup_evidence_targets,
          { apps: {} },
          retention_options.merge(preserve_apps: ['SaneLot']),
          true
        )
        subject.define_singleton_method(:running_on_mini_host?) { false }
        local = subject.send(
          :machine_cleanup_evidence_targets,
          { apps: {} },
          retention_options.merge(preserve_apps: []),
          true
        )

        assert(protected.all? { |action| action[:type] == 'skip' }, 'protected app evidence must not be pruned')
        assert_eq(local, [])
        assert_eq(subject.send(:machine_cleanup_safe_path?, File.join(noncanonical, 'test.xcresult')), false)
        assert_eq(subject.send(:machine_cleanup_safe_path?, File.join(runs.first, 'test.xcresult')), true)
      end
    end
  end

  test_category('explicit permanent reclaim') do
    test('refuses to empty Trash while a mounted disk image is backed by Trash') do
      with_retention_home do |home|
        trash = File.join(home, '.Trash')
        image = File.join(trash, 'iOS_26.5_runtime.dmg')
        FileUtils.mkdir_p(trash)
        File.write(image, 'mounted runtime backing image')
        subject = MachineCleanupRetentionHarness.new(
          sizes: { trash => 18.0 },
          hdiutil_info: "image-path      : #{image}\n"
        )
        plan = {
          disk: { ok: true, available_bytes: 1, available_gb: 1, capacity: '99%' },
          actions: [{ type: 'empty_trash', category: 'trash', path: trash, size_gb: 18.0 }]
        }

        result = subject.send(:apply_machine_cleanup_plan, plan, retention_options(empty_trash: true))

        assert_eq(result[:success], false)
        assert_eq(subject.events, [])
        assert(File.file?(image), 'mounted runtime backing image must remain in Trash')
        assert_includes(result[:failed].first[:error], 'valid Trash root')
      end
    end

    test('refuses to empty Trash when mounted disk-image inspection fails') do
      with_retention_home do |home|
        trash = File.join(home, '.Trash')
        file = File.join(trash, 'keep.txt')
        FileUtils.mkdir_p(trash)
        File.write(file, 'keep')
        subject = MachineCleanupRetentionHarness.new(
          sizes: { trash => 1.0 }, hdiutil_ok: false
        )
        plan = {
          disk: { ok: true, available_bytes: 1, available_gb: 1, capacity: '99%' },
          actions: [{ type: 'empty_trash', category: 'trash', path: trash, size_gb: 1.0 }]
        }

        result = subject.send(:apply_machine_cleanup_plan, plan, retention_options(empty_trash: true))

        assert_eq(result[:success], false)
        assert_eq(subject.events, [])
        assert(File.file?(file), 'Trash must remain intact when disk-image inspection fails')
      end
    end

    test('explicit empty Trash bypasses the routine size threshold') do
      with_retention_home do |home|
        trash = File.join(home, '.Trash')
        FileUtils.mkdir_p(trash)
        subject = MachineCleanupRetentionHarness.new(sizes: { trash => 0.25 })

        action = subject.send(:machine_cleanup_trash_target, retention_options(empty_trash: true))

        assert_eq(action[:type], 'empty_trash')
        assert_eq(action[:path], trash)
        assert_eq(action[:size_gb], 0.25)
      end
    end

    test('empties Trash last and reports bytes freed') do
      with_retention_home do |home|
        trash = File.join(home, '.Trash')
        cache = File.join(home, '.cache/old')
        FileUtils.mkdir_p([trash, cache])
        before = { ok: true, available_gb: 3, available_bytes: 3 * 1024 * 1024 * 1024, capacity: '99%' }
        after = { ok: true, available_gb: 8, available_bytes: 8 * 1024 * 1024 * 1024, capacity: '96%' }
        subject = MachineCleanupRetentionHarness.new(
          sizes: { trash => 2.0, cache => 3.0 },
          snapshots: [after]
        )
        plan = {
          disk: before,
          actions: [
            { type: 'trash_path', category: 'test', path: cache, size_gb: 3.0 },
            { type: 'empty_trash', category: 'trash', path: trash, size_gb: 2.0 }
          ]
        }

        result = subject.send(:apply_machine_cleanup_plan, plan, quiet: true, empty_trash: true)

        assert_eq(result[:success], true)
        assert_eq(subject.events, [[:trash, cache], [:empty, trash]])
        assert_eq(result[:freed_bytes], 5 * 1024 * 1024 * 1024)
        assert_eq(result[:freed_gb], 5.0)
      end
    end

    test('refuses a crafted empty Trash action without the explicit option') do
      with_retention_home do |home|
        trash = File.join(home, '.Trash')
        FileUtils.mkdir_p(trash)
        subject = MachineCleanupRetentionHarness.new
        plan = {
          disk: { available_bytes: 3 * 1024 * 1024 * 1024 },
          actions: [{ type: 'empty_trash', category: 'trash', path: trash, size_gb: 1.0 }]
        }

        result = subject.send(:apply_machine_cleanup_plan, plan, quiet: true, empty_trash: false)

        assert_eq(result[:success], false)
        assert_eq(subject.events, [])
        assert_includes(result[:failed].first[:error], 'explicit --empty-trash')
      end
    end
  end
end)
