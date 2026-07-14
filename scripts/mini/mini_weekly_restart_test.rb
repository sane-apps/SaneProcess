#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

SCRIPT = File.expand_path('mini-weekly-restart.sh', __dir__)
INSTALLER = File.expand_path('mini-install-weekly-restart.sh', __dir__)
BASE = File.expand_path('../sanemaster/base.rb', __dir__)

def executable(path, body)
  File.write(path, body)
  FileUtils.chmod(0o755, path)
end

def run_restart_fixture(busy: false, filevault_off: true, autologin: true, dry_run: true,
                        maintenance_inhibit: false, codex_activity: false, active_holder: false)
  Dir.mktmpdir('mini-weekly-restart-test') do |dir|
    bin = File.join(dir, 'bin')
    FileUtils.mkdir_p(bin)
    power_marker = File.join(dir, 'power-called')
    log = File.join(dir, 'restart.log')

    executable(File.join(bin, 'uptime'), "#!/bin/sh\necho '10:00 up 8 days, 1 user, load averages: 1.00 1.00 1.00'\n")
    executable(File.join(bin, 'fdesetup'), "#!/bin/sh\necho 'FileVault is #{filevault_off ? 'Off' : 'On'}.'\n")
    executable(File.join(bin, 'defaults'), "#!/bin/sh\n#{autologin ? "echo stephansmac" : 'exit 1'}\n")
    executable(File.join(bin, 'pgrep'), "#!/bin/sh\n#{busy ? "echo '123 xcodebuild test'" : 'exit 1'}\n")
    executable(File.join(bin, 'shutdown'), "#!/bin/sh\necho shutdown >> #{power_marker.inspect}\n")
    FileUtils.mkdir_p(File.join(dir, '.sanemaster'))
    FileUtils.touch(File.join(dir, '.sanemaster', 'restart-inhibit')) if maintenance_inhibit
    if active_holder
      holder_dir = File.join(dir, '.sanemaster', 'maintenance-active')
      FileUtils.mkdir_p(holder_dir)
      File.write(File.join(holder_dir, Process.pid.to_s), "active\n")
    end
    if codex_activity
      session_dir = File.join(dir, '.codex', 'sessions', 'fixture')
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, 'rollout.jsonl'), "active\n")
    end

    env = {
      'PATH' => "#{bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'SANE_WEEKLY_RESTART_PATH' => "#{bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'SANE_SERVER_USER' => 'stephansmac',
      'SANE_SERVER_HOME' => dir,
      'SANE_WEEKDAY_OVERRIDE' => '0',
      'SANE_WEEKLY_RESTART_LOG' => log,
      'SANE_WEEKLY_RESTART_TEST_MODE' => '1',
      'SANE_WEEKLY_RESTART_TEST_UID' => '0',
      'SANE_WEEKLY_RESTART_TEST_SKIP_HID' => '1',
      'SANE_WEEKLY_RESTART_TEST_SHUTDOWN' => File.join(bin, 'shutdown')
    }
    args = ['/bin/bash', SCRIPT]
    args << '--dry-run' if dry_run
    stdout, stderr, status = Open3.capture3(env, *args)
    {
      stdout: stdout,
      stderr: stderr,
      status: status,
      power_called: File.exist?(power_marker)
    }
  end
end

exit(run_tests('Mini Weekly Restart Tests') do
  test_category('Guarded runtime') do
    test('accepts an idle FileVault-off auto-login server without rebooting in dry-run') do
      result = run_restart_fixture
      assert(result[:status].success?, result[:stderr])
      assert_includes(result[:stdout], 'eligible for a guarded restart', result[:stdout] + result[:stderr])
      assert(!result[:power_called], 'dry-run invoked a power command')
      true
    end

    test('eligible non-dry power path reaches only the injected test executor') do
      result = run_restart_fixture(dry_run: false)
      assert(result[:status].success?, result[:stdout] + result[:stderr])
      assert(result[:power_called], 'eligible non-dry branch did not reach the injected executor')
      assert_includes(result[:stdout], 'Preflight passed; restarting with /sbin/shutdown -r now')
      true
    end

    test('skips a busy server') do
      result = run_restart_fixture(busy: true)
      assert(result[:status].success?, result[:stderr])
      assert_includes(result[:stdout], 'Skipped: active work process: 123 xcodebuild test', result[:stdout] + result[:stderr])
      assert_includes(result[:stdout], 'next retry is later today or next Sunday')
      true
    end

    test('does not treat resident macOS update daemons as an active install') do
      source = File.read(SCRIPT)
      assert(!source.include?('pgrep -x softwareupdated'))
      assert(!source.include?('pgrep -x installd'))
      assert_includes(source, 'softwareupdate.*(--install|-i)')
      true
    end

    test('root runtime path excludes user-writable package-manager directories') do
      source = File.read(SCRIPT)
      assert_includes(source, 'SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"')
      assert(!source.include?('/opt/homebrew/bin'))
      assert(!source.include?('/usr/local/bin'))
      assert_includes(source, 'Refusing test-mode power injection in a real root runtime')
      assert_includes(source, '/sbin/shutdown -r now')
      true
    end

    test('protects interactive and remote server work') do
      source = File.read(SCRIPT)
      %w[git rsync SaneMaster SaneVideo codex sshd HIDIdleTime].each do |token|
        assert_includes(source, token)
      end
      true
    end

    test('honors the shared maintenance inhibit and recent Codex task activity') do
      maintenance = run_restart_fixture(maintenance_inhibit: true)
      codex = run_restart_fixture(codex_activity: true)
      active = run_restart_fixture(active_holder: true)
      assert_includes(maintenance[:stdout], 'SaneMaster maintenance inhibit is active')
      assert_includes(codex[:stdout], 'Codex task state changed within the last')
      assert_includes(active[:stdout], 'active SaneMaster maintenance holder')
      assert(!maintenance[:power_called] && !codex[:power_called] && !active[:power_called])
      base_source = File.read(BASE)
      assert_includes(base_source, 'FileUtils.touch(WORK_SESSION_RESTART_INHIBIT)')
      assert_includes(base_source, 'FileUtils.rm_f(WORK_SESSION_RESTART_INHIBIT)')
      assert_includes(base_source, 'acquire_server_maintenance_holder!')
      source = File.read(SCRIPT)
      assert_includes(source, 'acquire_restart_exclusive')
      assert_includes(source, 'Skipped after exclusive-lock recheck')
      true
    end

    test('skips until FileVault and automatic login are ready') do
      encrypted = run_restart_fixture(filevault_off: false)
      no_login = run_restart_fixture(autologin: false)
      assert_includes(encrypted[:stdout], 'FileVault is still enabled')
      assert_includes(no_login[:stdout], 'automatic login is not configured', no_login[:stdout] + no_login[:stderr])
      true
    end
  end

  test_category('Root-owned installation contract') do
    test('installs a root-owned helper and LaunchDaemon') do
      source = File.read(INSTALLER)
      assert_includes(source, 'install -m 0755 -o root -g wheel "$SOURCE" "$HELPER"')
      assert_includes(source, '/Library/LaunchDaemons/${LABEL}.plist')
      assert_includes(source, '<integer>0</integer>')
      assert_includes(source, '<integer>10</integer>')
      assert_includes(source, '<integer>11</integer>')
      assert_includes(source, '<integer>12</integer>')
      assert_includes(source, '<integer>30</integer>')
      assert_includes(source, '10:30, 11:30, and 12:30')
      true
    end
  end
end)
