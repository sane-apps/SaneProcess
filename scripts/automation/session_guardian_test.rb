#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

INSTALLER = File.expand_path('install-session-guardian.sh', __dir__)
GUARDIAN = File.expand_path('../hooks/session-guardian.sh', __dir__)

exit(run_tests('Session Guardian Tests') do
  test_category('Air-only ownership') do
    test('dry-run validates without creating plist, logs, or directories') do
      Dir.mktmpdir('session-guardian-dry-run') do |dir|
        plist = File.join(dir, 'missing', 'guardian.plist')
        logs = File.join(dir, 'missing-logs')
        env = {
          'HOME' => dir,
          'SANE_SESSION_GUARDIAN_HOST_OVERRIDE' => 'fixture-macbook-air',
          'SANE_SESSION_GUARDIAN_PLIST' => plist,
          'SANE_SESSION_GUARDIAN_LOG_DIR' => logs,
          'SANE_SESSION_GUARDIAN_SCRIPT' => GUARDIAN
        }
        out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(status.success?, "#{out}\n#{err}")
        assert_includes(out, 'Validated Air session guardian LaunchAgent')
        assert(!File.exist?(plist), 'dry-run wrote the plist')
        assert(!Dir.exist?(logs), 'dry-run created the log directory')
        assert(!Dir.exist?(File.dirname(plist)), 'dry-run created the plist directory')
        true
      end
    end

    test('refuses Mini installation before any write') do
      Dir.mktmpdir('session-guardian-mini-refusal') do |dir|
        plist = File.join(dir, 'missing', 'guardian.plist')
        env = {
          'HOME' => dir,
          'SANE_SESSION_GUARDIAN_HOST_OVERRIDE' => 'fixture-mac-mini',
          'SANE_SESSION_GUARDIAN_PLIST' => plist,
          'SANE_SESSION_GUARDIAN_SCRIPT' => GUARDIAN
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(!status.success?, 'Mini installation was accepted')
        assert_includes(err, 'Refusing to install the Air session guardian')
        assert(!File.exist?(plist), 'Mini refusal wrote a plist')
        true
      end
    end

    test('normal install is idempotent and verifies loaded program plus health') do
      Dir.mktmpdir('session-guardian-install') do |dir|
        plist = File.join(dir, 'LaunchAgents', 'guardian.plist')
        logs = File.join(dir, 'logs')
        launchctl = File.join(dir, 'launchctl')
        launchctl_log = File.join(dir, 'launchctl.log')
        File.write(launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          if [ "${1:-}" = print ]; then
            echo "program = $GUARDIAN"
            echo "last exit code = 0"
          fi
          exit 0
        SH
        FileUtils.chmod(0o755, launchctl)
        env = {
          'HOME' => dir,
          'SANE_SESSION_GUARDIAN_HOST_OVERRIDE' => 'fixture-macbook-air',
          'SANE_SESSION_GUARDIAN_PLIST' => plist,
          'SANE_SESSION_GUARDIAN_LOG_DIR' => logs,
          'SANE_SESSION_GUARDIAN_SCRIPT' => GUARDIAN,
          'SANE_LAUNCHCTL_BIN' => launchctl,
          'LAUNCHCTL_LOG' => launchctl_log,
          'GUARDIAN' => GUARDIAN
        }
        2.times do
          out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
          assert(status.success?, "#{out}\n#{err}")
          assert_includes(out, 'health verified')
        end
        source = File.read(plist)
        assert_includes(source, '<string>com.saneapps.session-guardian</string>')
        assert_includes(source, "<string>#{GUARDIAN}</string>")
        assert_includes(source, '<integer>600</integer>')
        calls = File.read(launchctl_log)
        assert(calls.scan(/bootstrap gui\//).length == 2, calls)
        assert(calls.scan(/bootout gui\//).length == 2, calls)
        true
      end
    end
  end

  test_category('health probe') do
    test('is read-only and rejects unexpected arguments') do
      Dir.mktmpdir('session-guardian-health') do |dir|
        env = { 'HOME' => dir }
        out, err, status = Open3.capture3(env, '/bin/bash', GUARDIAN, '--health')
        assert(status.success?, "#{out}\n#{err}")
        assert_includes(out, 'session-guardian healthy')
        assert(!Dir.exist?(File.join(dir, 'Library')), 'health probe created the log directory')
        _bad_out, bad_err, bad_status = Open3.capture3(env, '/bin/bash', GUARDIAN, '--unknown')
        assert(!bad_status.success?, 'unexpected argument was accepted')
        assert_includes(bad_err, 'Usage:')
        true
      end
    end
  end

  test_category('conservative reaping') do
    test('keeps ambiguous daemonized and launchd-managed ppid-one descendants alive') do
      Dir.mktmpdir('session-guardian-report-only') do |dir|
        ps_bin = File.join(dir, 'ps')
        launchctl = File.join(dir, 'launchctl')
        kill_bin = File.join(dir, 'kill')
        sleep_bin = File.join(dir, 'sleep')
        memory_pressure = File.join(dir, 'memory_pressure')
        kill_log = File.join(dir, 'kill.log')
        guardian_log = File.join(dir, 'guardian.log')
        ownership = File.join(dir, 'missing-ownership.tsv')
        File.write(ps_bin, <<~SH)
          #!/bin/sh
          if [ "${1:-}" = -A ]; then
            echo '210 1 2048 /opt/homebrew/bin/node /tmp/@modelcontextprotocol/legitimate-daemon'
            echo '211 1 4096 /opt/homebrew/bin/node /tmp/@modelcontextprotocol/launchd-child'
          elif [ "${1:-}" = -p ]; then
            echo 'Mon Aug  2 12:00:00 2026'
          fi
        SH
        File.write(launchctl, <<~SH)
          #!/bin/sh
          echo 'PID Status Label'
          echo '211 0 com.example.legitimate'
        SH
        File.write(kill_bin, "#!/bin/sh\necho \"$*\" >> \"$KILL_LOG\"\nexit 0\n")
        File.write(sleep_bin, "#!/bin/sh\nexit 0\n")
        File.write(memory_pressure, "#!/bin/sh\necho 'System-wide memory free percentage: 80%'\n")
        FileUtils.chmod(0o755, [ps_bin, launchctl, kill_bin, sleep_bin, memory_pressure])
        env = {
          'HOME' => dir,
          'SANE_SESSION_GUARDIAN_LOG' => guardian_log,
          'SANE_SESSION_GUARDIAN_OWNERSHIP_FILE' => ownership,
          'SANE_SESSION_GUARDIAN_PS_BIN' => ps_bin,
          'SANE_SESSION_GUARDIAN_LAUNCHCTL_BIN' => launchctl,
          'SANE_SESSION_GUARDIAN_KILL_BIN' => kill_bin,
          'SANE_SESSION_GUARDIAN_SLEEP_BIN' => sleep_bin,
          'SANE_SESSION_GUARDIAN_MEMORY_PRESSURE_BIN' => memory_pressure,
          'KILL_LOG' => kill_log
        }
        out, err, status = Open3.capture3(env, '/bin/bash', GUARDIAN)
        assert(status.success?, "#{out}\n#{err}")
        assert(!File.exist?(kill_log) || File.read(kill_log).empty?, 'legitimate descendants were signaled')
        report = File.read(guardian_log)
        assert_includes(report, 'REPORT_ONLY ambiguous ppid=1 pid=210')
        assert(!report.include?('pid=211'), 'launchd-managed descendant should be silently excluded')
        true
      end
    end

    test('reaps only an exact durable binding to a dead session owner') do
      Dir.mktmpdir('session-guardian-dead-owner') do |dir|
        ps_bin = File.join(dir, 'ps')
        launchctl = File.join(dir, 'launchctl')
        kill_bin = File.join(dir, 'kill')
        sleep_bin = File.join(dir, 'sleep')
        memory_pressure = File.join(dir, 'memory_pressure')
        kill_log = File.join(dir, 'kill.log')
        guardian_log = File.join(dir, 'guardian.log')
        ownership = File.join(dir, 'ownership.tsv')
        command = '/opt/homebrew/bin/node /tmp/@modelcontextprotocol/dead-session-child'
        started = 'Mon Aug 2 12:00:00 2026'
        digest = Digest::SHA256.hexdigest(command)
        File.write(ownership, "220\t#{started}\t#{digest}\t999\n")
        FileUtils.chmod(0o600, ownership)
        File.write(ps_bin, <<~SH)
          #!/bin/sh
          if [ "${1:-}" = -A ]; then
            echo '220 1 3072 #{command}'
          elif [ "${1:-}" = -p ]; then
            echo '#{started}'
          fi
        SH
        File.write(launchctl, "#!/bin/sh\necho 'PID Status Label'\n")
        File.write(kill_bin, <<~SH)
          #!/bin/sh
          echo "$*" >> "$KILL_LOG"
          [ "${1:-}" != -0 ]
        SH
        File.write(sleep_bin, "#!/bin/sh\nexit 0\n")
        File.write(memory_pressure, "#!/bin/sh\necho 'System-wide memory free percentage: 80%'\n")
        FileUtils.chmod(0o755, [ps_bin, launchctl, kill_bin, sleep_bin, memory_pressure])
        env = {
          'HOME' => dir,
          'SANE_SESSION_GUARDIAN_LOG' => guardian_log,
          'SANE_SESSION_GUARDIAN_OWNERSHIP_FILE' => ownership,
          'SANE_SESSION_GUARDIAN_PS_BIN' => ps_bin,
          'SANE_SESSION_GUARDIAN_LAUNCHCTL_BIN' => launchctl,
          'SANE_SESSION_GUARDIAN_KILL_BIN' => kill_bin,
          'SANE_SESSION_GUARDIAN_SLEEP_BIN' => sleep_bin,
          'SANE_SESSION_GUARDIAN_MEMORY_PRESSURE_BIN' => memory_pressure,
          'KILL_LOG' => kill_log
        }
        out, err, status = Open3.capture3(env, '/bin/bash', GUARDIAN)
        assert(status.success?, "#{out}\n#{err}")
        signals = File.read(kill_log)
        assert_includes(signals, '-0 999')
        assert_includes(signals, '-TERM 220')
        assert_includes(File.read(guardian_log), 'REAPED orphan pid=220')
        true
      end
    end
  end
end)
