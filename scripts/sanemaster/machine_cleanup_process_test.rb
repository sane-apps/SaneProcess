#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'machine_cleanup'

class MachineCleanupProcessHarness
  include SaneMasterModules::MachineCleanup

  def initialize(ps_rows: [], sizes: {})
    @ps_rows = ps_rows
    @sizes = sizes
  end

  def machine_cleanup_ps_rows
    @ps_rows
  end

  def machine_cleanup_disk_snapshot
    { ok: true, available_gb: 10, available_bytes: 10 * 1024 * 1024 * 1024, capacity: '95%' }
  end

  def path_size_gb(path)
    @sizes.fetch(File.expand_path(path), 0.0)
  end

  def running_on_mini_host?
    false
  end
end

class FailedProcessScanHarness < MachineCleanupProcessHarness
  def machine_cleanup_ps_rows
    @machine_cleanup_process_scan_ok = false
    []
  end
end

include TestFramework

def with_process_home
  Dir.mktmpdir('machine-cleanup-process-') do |home|
    old_home = ENV['HOME']
    ENV['HOME'] = home
    yield home
  ensure
    ENV['HOME'] = old_home
  end
end

def process_row(pid:, ppid: 1, command:, executable: nil)
  {
    pid: pid,
    ppid: ppid,
    pgid: pid,
    stat: 'S',
    etime: '00:10',
    executable: executable,
    command: command
  }.compact
end

exit(run_tests('SaneMaster Machine Cleanup Process Tests') do
  test_category('executable ownership') do
    test('ignores app names in editor cwd, prompts, and cleanup preserve arguments') do
      subject = MachineCleanupProcessHarness.new(ps_rows: [
        process_row(
          pid: 10,
          executable: '/Applications/Cursor.app/Contents/Frameworks/Cursor Helper',
          command: '/Applications/Cursor.app/Contents/Frameworks/Cursor Helper --cwd /Users/test/SaneApps/apps/SaneClip'
        ),
        process_row(
          pid: 11,
          command: 'ruby scripts/SaneMaster.rb machine_cleanup --server --apply --preserve-apps Brave,SaneClip'
        ),
        process_row(
          pid: 12,
          executable: '/Applications/Cursor.app/Contents/Frameworks/Cursor Helper',
          command: 'Cursor Helper prompt="test SaneLot with xcodebuild"'
        )
      ])

      active = subject.send(:machine_cleanup_active_inventory)

      assert_eq(active[:apps], {})
      assert_eq(active[:xcodebuild_active], false)
      assert_eq(active[:workflow_active], false)
    end

    test('owns real app and build processes and propagates ownership to children') do
      subject = MachineCleanupProcessHarness.new(ps_rows: [
        process_row(
          pid: 20,
          command: '/tmp/SaneVideo.app/Contents/MacOS/SaneVideo'
        ),
        process_row(
          pid: 30,
          command: 'xcodebuild -project SaneLot.xcodeproj -scheme SaneLot test'
        ),
        process_row(
          pid: 31,
          ppid: 30,
          command: '/usr/bin/swift-frontend -frontend -c Sources/Feature.swift'
        )
      ])

      active = subject.send(:machine_cleanup_active_inventory)

      assert_eq(active[:apps].keys.sort, %w[SaneLot SaneVideo])
      assert_eq(active[:apps]['SaneLot'].map { |row| row[:pid] }.sort, [30, 31])
      assert_eq(active[:xcodebuild_active], true)
    end

    test('recognizes active canonical workflow but excludes machine cleanup itself') do
      verify = process_row(
        pid: 40,
        command: 'ruby scripts/SaneMaster.rb verify --timeout 900'
      ).merge(cwd: '/Users/test/SaneApps/apps/SaneScan')
      cleanup = process_row(
        pid: 41,
        command: 'ruby scripts/SaneMaster.rb machine_cleanup --preserve-apps SaneClip'
      )
      subject = MachineCleanupProcessHarness.new(ps_rows: [verify, cleanup])

      active = subject.send(:machine_cleanup_active_inventory)

      assert_eq(active[:workflow_active], true)
      assert_eq(active[:apps].keys, ['SaneScan'])
    end
  end

  test_category('fail closed preservation') do
    test('failed process inventory blocks server artifact cleanup') do
      subject = FailedProcessScanHarness.new
      active = subject.send(:machine_cleanup_active_inventory)

      assert_eq(active[:process_scan_failed], true)
      assert_includes(subject.send(:machine_cleanup_server_blocking_flags, active), :process_scan_failed)
    end

    test('server cleanup preserves declared app DerivedData and generated repo paths') do
      with_process_home do |home|
        derived = File.join(home, 'Library/Developer/Xcode/DerivedData')
        saneclip_derived = File.join(derived, 'SaneClip-abc')
        sanebar_derived = File.join(derived, 'SaneBar-def')
        saneclip_build = File.join(home, 'SaneApps/apps/SaneClip/.build')
        sanebar_build = File.join(home, 'SaneApps/apps/SaneBar/.build')
        FileUtils.mkdir_p([saneclip_derived, sanebar_derived, saneclip_build, sanebar_build])
        sizes = {
          saneclip_derived => 2.0,
          sanebar_derived => 2.0,
          saneclip_build => 1.0,
          sanebar_build => 1.0
        }
        subject = MachineCleanupProcessHarness.new(sizes: sizes)
        active = subject.send(:machine_cleanup_active_inventory)
        options = {
          server: true,
          preserve_apps: ['SaneClip'],
          deriveddata_age_days: 0
        }

        derived_paths = subject.send(:machine_cleanup_deriveddata_targets, active, options).map { |action| action[:path] }
        generated_paths = subject.send(
          :server_repo_generated_cleanup_targets,
          subject.send(:machine_cleanup_protected_apps, active, options)
        ).map { |action| action[:path] }

        assert_eq(derived_paths, [sanebar_derived])
        assert_eq(generated_paths, [sanebar_build])
      end
    end
  end
end)
