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
        installed_supervisor = File.read(supervisor)
        assert_includes(installed_supervisor, 'http://127.0.0.1:3111/agentmemory/livez')
        assert(!installed_supervisor.include?('Health:[[:space:]].*healthy'), 'supervisor must not parse CLI display text')
        assert_includes(File.read(INSTALLER), 'http://127.0.0.1:3111/agentmemory/livez')
        true
      end
    end

    test('accepts direct livez success even when CLI status text is unknown') do
      Dir.mktmpdir('agentmemory-supervisor-health') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        curl_log = File.join(dir, 'curl.log')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          case "${1:-}" in
            status)
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
          echo "$*" >> "$CURL_LOG"
          exit 0
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_curl])
        env = {
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_AGENTMEMORY_HEALTH_INTERVAL' => '0.05',
          'SANE_AGENTMEMORY_STARTUP_ATTEMPTS' => '2',
          'SANE_AGENTMEMORY_STARTUP_INTERVAL' => '0.05',
          'CURL_LOG' => curl_log
        }

        _stdin, _stdout, stderr, wait_thread = Open3.popen3(env, '/bin/bash', SUPERVISOR)
        sleep 0.2
        Process.kill('TERM', wait_thread.pid)
        status = wait_thread.value
        error_text = stderr.read

        assert(status.success?, error_text)
        assert_includes(File.read(curl_log), 'http://127.0.0.1:3111/agentmemory/livez')
        assert(!error_text.include?('startup health deadline'), error_text)
        true
      end
    end

    test('exits nonzero when the child engine loses health so launchd can restart it') do
      Dir.mktmpdir('agentmemory-supervisor') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        count = File.join(dir, 'livez-count')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          case "${1:-}" in
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
          count=0
          [ ! -f "$LIVEZ_COUNT" ] || count="$(cat "$LIVEZ_COUNT")"
          count=$((count + 1))
          printf '%s\n' "$count" > "$LIVEZ_COUNT"
          [ "$count" -le 2 ]
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_curl])
        env = {
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_AGENTMEMORY_HEALTH_INTERVAL' => '0.1',
          'SANE_AGENTMEMORY_HEALTH_MISSES' => '2',
          'SANE_AGENTMEMORY_STARTUP_ATTEMPTS' => '2',
          'SANE_AGENTMEMORY_STARTUP_INTERVAL' => '0.1',
          'LIVEZ_COUNT' => count
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', SUPERVISOR)
        assert(!status.success?, 'supervisor must request a launchd restart after sustained health loss')
        assert_includes(err, 'exiting for launchd restart')
        true
      end
    end

    test('uses a bounded noninteractive admin fallback when remote launchd bootstrap is denied') do
      Dir.mktmpdir('agentmemory-remote-install') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
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
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          exit 0
        SH
        File.write(fake_sudo, <<~SH)
          #!/bin/sh
          echo "$*" >> "$SUDO_LOG"
          exit 0
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_launchctl, fake_sudo])
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
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
