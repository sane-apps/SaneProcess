#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

INSTALLER = File.expand_path('mini-install-agentmemory.sh', __dir__)
SUPERVISOR = File.expand_path('mini-agentmemory-supervisor.sh', __dir__)

exit(run_tests('Mini AgentMemory Tests') do
  test_category('restart durability') do
    test('generates a private user LaunchAgent with restart guarantees') do
      Dir.mktmpdir('agentmemory-agent') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        plist = File.join(dir, 'com.saneapps.agentmemory.plist')
        log_dir = File.join(dir, 'logs')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        File.write(fake_bin, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, fake_bin)
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => log_dir,
          'SANE_AGENTMEMORY_SUPERVISOR' => supervisor
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(status.success?, err)
        source = File.read(plist)
        assert_includes(source, '<string>com.saneapps.agentmemory</string>')
        assert_includes(source, '<string>/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>')
        assert_includes(source, '<key>RunAtLoad</key>')
        assert_includes(source, '<key>KeepAlive</key>')
        assert_includes(source, '<key>SuccessfulExit</key>')
        assert_includes(source, '<key>ThrottleInterval</key>')
        assert_includes(source, '<integer>30</integer>')
        assert_includes(source, '<key>WorkingDirectory</key>')
        assert_includes(source, "<string>#{dir}</string>")
        assert_includes(source, "<string>#{supervisor}</string>")
        assert(File.executable?(supervisor), 'installed supervisor must be executable')
        assert_includes(File.read(INSTALLER), "grep -Eq 'Health:[[:space:]].*healthy'")
        assert_includes(File.read(INSTALLER), 'agentmemory/livez')
        true
      end
    end

    test('exits nonzero when the child engine loses health so launchd can restart it') do
      Dir.mktmpdir('agentmemory-supervisor') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_lsof = File.join(dir, 'lsof')
        count = File.join(dir, 'status-count')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          case "${1:-}" in
            status)
              count=0
              [ ! -f "$STATUS_COUNT" ] || count="$(cat "$STATUS_COUNT")"
              count=$((count + 1))
              printf '%s\n' "$count" > "$STATUS_COUNT"
              if [ "$count" -le 2 ]; then
                echo 'Health: healthy'
                exit 0
              fi
              echo 'Health: unknown'
              exit 1
              ;;
            stop)
              exit 0
              ;;
            *)
              while :; do sleep 1; done
              ;;
          esac
        SH
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          # livez required; fail after the second healthy status observation
          count=0
          [ ! -f "$STATUS_COUNT" ] || count="$(cat "$STATUS_COUNT")"
          if [ "$count" -le 2 ]; then
            exit 0
          fi
          exit 22
        SH
        File.write(fake_lsof, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_lsof])
        env = {
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_LSOF_BIN' => fake_lsof,
          'SANE_AGENTMEMORY_HEALTH_INTERVAL' => '0.1',
          'SANE_AGENTMEMORY_HEALTH_MISSES' => '2',
          'SANE_AGENTMEMORY_STARTUP_ATTEMPTS' => '2',
          'SANE_AGENTMEMORY_STARTUP_INTERVAL' => '0.1',
          'STATUS_COUNT' => count
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', SUPERVISOR)
        assert(!status.success?, 'supervisor must request a launchd restart after sustained health loss')
        assert_includes(err, 'exiting for launchd restart')
        true
      end
    end

    test('reclaims orphan listeners on the AgentMemory port before restart') do
      Dir.mktmpdir('agentmemory-reclaim') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_lsof = File.join(dir, 'lsof')
        fake_kill = File.join(dir, 'kill')
        kill_log = File.join(dir, 'kill.log')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          case "${1:-}" in
            status) echo 'Not running'; exit 1 ;;
            stop) exit 0 ;;
            *) exit 1 ;;
          esac
        SH
        File.write(fake_curl, "#!/bin/sh\nexit 22\n")
        File.write(fake_lsof, <<~SH)
          #!/bin/sh
          # First reclaim sees orphan 4242; later calls see nothing.
          if [ ! -f "$LSOF_FIRED" ]; then
            touch "$LSOF_FIRED"
            echo 4242
            exit 0
          fi
          exit 1
        SH
        File.write(fake_kill, <<~SH)
          #!/bin/sh
          echo "$*" >> "$KILL_LOG"
          exit 0
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_lsof, fake_kill])
        env = {
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_LSOF_BIN' => fake_lsof,
          'SANE_KILL_BIN' => fake_kill,
          'SANE_AGENTMEMORY_STARTUP_ATTEMPTS' => '1',
          'SANE_AGENTMEMORY_STARTUP_INTERVAL' => '0.05',
          'KILL_LOG' => kill_log,
          'LSOF_FIRED' => File.join(dir, 'lsof-fired')
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', SUPERVISOR)
        assert(!status.success?)
        assert_includes(err, 'Reclaiming orphan listener pid=4242')
        assert(File.file?(kill_log), 'kill must be invoked for orphan pid')
        assert_includes(File.read(kill_log), '-TERM 4242')
        true
      end
    end

    test('uses a bounded noninteractive admin fallback when remote launchd bootstrap is denied') do
      Dir.mktmpdir('agentmemory-remote-install') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_launchctl = File.join(dir, 'launchctl')
        fake_sudo = File.join(dir, 'sudo')
        launchctl_log = File.join(dir, 'launchctl.log')
        sudo_log = File.join(dir, 'sudo.log')
        plist = File.join(dir, 'com.saneapps.agentmemory.plist')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          [ "${1:-}" != status ] || echo 'Health: healthy'
          exit 0
        SH
        File.write(fake_launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          [ "${1:-}" != bootstrap ]
        SH
        File.write(fake_sudo, <<~SH)
          #!/bin/sh
          echo "$*" >> "$SUDO_LOG"
          exit 0
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_launchctl, fake_sudo])
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => File.join(dir, 'logs'),
          'SANE_AGENTMEMORY_SUPERVISOR' => supervisor,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_SUDO_BIN' => fake_sudo,
          'LAUNCHCTL_LOG' => launchctl_log,
          'SUDO_LOG' => sudo_log
        }
        out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(status.success?, "#{out}\n#{err}")
        assert_includes(File.read(launchctl_log), 'bootstrap gui/')
        assert_includes(File.read(sudo_log), "-n #{fake_launchctl} bootstrap gui/")
        assert_includes(out, 'noninteractive admin fallback')
        true
      end
    end
  end
end)
