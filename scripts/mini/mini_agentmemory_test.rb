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
    test('dry-run is zero-write and normal install generates a private supervised LaunchAgent') do
      Dir.mktmpdir('agentmemory-agent') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_launchctl = File.join(dir, 'launchctl')
        plist = File.join(dir, 'com.saneapps.agentmemory.plist')
        log_dir = File.join(dir, 'logs')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          [ "${1:-}" != status ] || printf 'Connected — v0.9.27\nHealth: healthy\nMemories: 1,201\nEmbeddings: embeddings\n'
          exit 0
        SH
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          for arg in "$@"; do url="$arg"; done
          case "$url" in
            */agentmemory/livez) printf '{"status":"ok"}\n' ;;
            */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
            */agentmemory/search) printf '{"results":[{"title":"fixture"}]}\n' ;;
            *) exit 1 ;;
          esac
        SH
        File.write(fake_launchctl, <<~SH)
          #!/bin/sh
          if [ "${1:-}" = print ]; then
            echo "$2 = {"
            echo "path = $PLIST"
            echo "state = running"
            echo "program = $SUPERVISOR"
          fi
          exit 0
        SH
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_launchctl])
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_SUDO_BIN' => '/usr/bin/false',
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => log_dir,
          'SANE_AGENTMEMORY_SUPERVISOR' => supervisor,
          'PLIST' => plist,
          'SUPERVISOR' => supervisor
        }
        out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(status.success?, err)
        assert_includes(out, 'Validated AgentMemory LaunchAgent')
        assert(!File.exist?(plist), 'dry-run wrote the plist')
        assert(!Dir.exist?(log_dir), 'dry-run created the log directory')
        assert(!File.exist?(supervisor), 'dry-run installed the supervisor')

        out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(status.success?, "#{out}\n#{err}")
        assert_includes(out, 'livez, health, corpus, and search verified')
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
        assert_includes(File.read(INSTALLER), '/agentmemory/livez')
        assert_includes(File.read(INSTALLER), '/agentmemory/search')
        true
      end
    end

    test('rejects unexpected arguments before creating install targets') do
      Dir.mktmpdir('agentmemory-strict-args') do |dir|
        plist = File.join(dir, 'missing', 'agentmemory.plist')
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_PLIST' => plist
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER, '--dry-run', '--unexpected')
        assert(!status.success?, 'installer accepted extra arguments')
        assert(status.exitstatus == 2, "expected usage exit 2, got #{status.exitstatus}")
        assert_includes(err, 'Usage:')
        assert(!File.exist?(plist), 'argument rejection wrote the plist')
        assert(!Dir.exist?(File.dirname(plist)), 'argument rejection created the plist directory')
        true
      end
    end

    test('validates staged supervisor before replacing live files or touching launchd') do
      Dir.mktmpdir('agentmemory-staged-validation') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_launchctl = File.join(dir, 'launchctl')
        invalid_source = File.join(dir, 'invalid-supervisor.sh')
        launchctl_log = File.join(dir, 'launchctl.log')
        plist = File.join(dir, 'LaunchAgents', 'agentmemory.plist')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        FileUtils.mkdir_p([File.dirname(plist), File.dirname(supervisor)])
        old_plist = '<plist><dict><key>Label</key><string>previous</string></dict></plist>'
        old_supervisor = "#!/bin/bash\necho previous\n"
        File.write(plist, old_plist)
        File.write(supervisor, old_supervisor)
        File.write(fake_bin, "#!/bin/sh\nexit 0\n")
        File.write(fake_curl, "#!/bin/sh\nexit 0\n")
        File.write(fake_launchctl, "#!/bin/sh\necho \"$*\" >> \"$LAUNCHCTL_LOG\"\nexit 0\n")
        File.write(invalid_source, "#!/bin/bash\nif\n")
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_launchctl, invalid_source, supervisor])
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => File.join(dir, 'logs'),
          'SANE_AGENTMEMORY_SUPERVISOR_SOURCE' => invalid_source,
          'SANE_AGENTMEMORY_SUPERVISOR' => supervisor,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_SUDO_BIN' => '/usr/bin/false',
          'LAUNCHCTL_LOG' => launchctl_log
        }
        _out, _err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'invalid staged supervisor was accepted')
        assert(File.read(plist) == old_plist, 'plist changed before staged validation passed')
        assert(File.read(supervisor) == old_supervisor, 'supervisor changed before staged validation passed')
        assert(!File.exist?(launchctl_log), 'launchd was touched before staged validation passed')
        assert(Dir.glob("#{plist}.{new,backup,rollback}.*").empty?, 'plist transaction files leaked')
        assert(Dir.glob("#{supervisor}.{new,backup,rollback}.*").empty?, 'supervisor transaction files leaked')
        true
      end
    end

    test('rolls back files and re-bootstraps the prior service when launchd identity proof fails') do
      Dir.mktmpdir('agentmemory-rollback') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_launchctl = File.join(dir, 'launchctl')
        fake_sudo = File.join(dir, 'sudo')
        launchctl_log = File.join(dir, 'launchctl.log')
        service_state = File.join(dir, 'service.state')
        plist = File.join(dir, 'LaunchAgents', 'agentmemory.plist')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        FileUtils.mkdir_p([File.dirname(plist), File.dirname(supervisor)])
        old_plist = '<plist><dict><key>Label</key><string>previous</string></dict></plist>'
        old_supervisor = "#!/bin/bash\necho previous\n"
        File.write(plist, old_plist)
        File.write(supervisor, old_supervisor)
        File.write(service_state, "running\n")
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          [ "${1:-}" != status ] || printf 'Connected — v0.9.27\nHealth: healthy\nMemories: 1,201\n'
          exit 0
        SH
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          for arg in "$@"; do url="$arg"; done
          case "$url" in
            */agentmemory/livez) printf '{"status":"ok"}\n' ;;
            */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
            */agentmemory/search) printf '{"results":[{"title":"fixture"}]}\n' ;;
            *) exit 1 ;;
          esac
        SH
        File.write(fake_launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          case "${1:-}" in
            print)
              [ -f "$SERVICE_STATE" ] || exit 1
              echo "$2 = {"
              echo "path = /wrong/launch-agent.plist"
              echo "state = running"
              echo "program = $SUPERVISOR"
              ;;
            bootout)
              rm -f "$SERVICE_STATE"
              ;;
            bootstrap)
              printf 'running\n' > "$SERVICE_STATE"
              ;;
          esac
          exit 0
        SH
        File.write(fake_sudo, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_launchctl, fake_sudo, supervisor])
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_LOG_DIR' => File.join(dir, 'logs'),
          'SANE_AGENTMEMORY_SUPERVISOR' => supervisor,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_SUDO_BIN' => fake_sudo,
          'SANE_AGENTMEMORY_INSTALL_HEALTH_ATTEMPTS' => '1',
          'SANE_AGENTMEMORY_INSTALL_HEALTH_INTERVAL' => '0',
          'LAUNCHCTL_LOG' => launchctl_log,
          'SERVICE_STATE' => service_state,
          'SUPERVISOR' => supervisor
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'wrong launchd path was accepted as healthy')
        assert_includes(err, 'restoring the previous supervised service')
        assert(File.read(plist) == old_plist, 'previous plist was not restored')
        assert(File.read(supervisor) == old_supervisor, 'previous supervisor was not restored')
        calls = File.read(launchctl_log)
        assert(calls.scan(/bootstrap gui\//).length == 2, calls)
        assert(Dir.glob("#{plist}.{new,backup,rollback}.*").empty?, 'plist transaction files leaked')
        assert(Dir.glob("#{supervisor}.{new,backup,rollback}.*").empty?, 'supervisor transaction files leaked')
        true
      end
    end

    test('rolls back and re-bootstraps the prior service when candidate bootstrap fails') do
      Dir.mktmpdir('agentmemory-bootstrap-rollback') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_launchctl = File.join(dir, 'launchctl')
        fake_sudo = File.join(dir, 'sudo')
        launchctl_log = File.join(dir, 'launchctl.log')
        bootstrap_count = File.join(dir, 'bootstrap.count')
        service_state = File.join(dir, 'service.state')
        plist = File.join(dir, 'LaunchAgents', 'agentmemory.plist')
        supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        FileUtils.mkdir_p([File.dirname(plist), File.dirname(supervisor)])
        old_plist = '<plist><dict><key>Label</key><string>previous</string></dict></plist>'
        old_supervisor = "#!/bin/bash\necho previous\n"
        File.write(plist, old_plist)
        File.write(supervisor, old_supervisor)
        File.write(service_state, "running\n")
        File.write(fake_bin, "#!/bin/sh\nexit 0\n")
        File.write(fake_curl, "#!/bin/sh\nexit 0\n")
        File.write(fake_launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          case "${1:-}" in
            print)
              [ -f "$SERVICE_STATE" ] || exit 1
              echo "$2 = {"
              echo "path = $PLIST"
              echo "state = running"
              echo "program = $SUPERVISOR"
              ;;
            bootout)
              rm -f "$SERVICE_STATE"
              ;;
            bootstrap)
              count=0
              [ ! -f "$BOOTSTRAP_COUNT" ] || count="$(cat "$BOOTSTRAP_COUNT")"
              count=$((count + 1))
              echo "$count" > "$BOOTSTRAP_COUNT"
              [ "$count" -gt 1 ] || exit 1
              echo running > "$SERVICE_STATE"
              ;;
          esac
          exit 0
        SH
        File.write(fake_sudo, "#!/bin/sh\nexit 1\n")
        FileUtils.chmod(0o755, [fake_bin, fake_curl, fake_launchctl, fake_sudo, supervisor])
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
          'BOOTSTRAP_COUNT' => bootstrap_count,
          'SERVICE_STATE' => service_state,
          'PLIST' => plist,
          'SUPERVISOR' => supervisor
        }
        _out, err, status = Open3.capture3(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'candidate bootstrap failure was accepted')
        assert_includes(err, 'restoring the previous supervised service')
        assert(File.read(plist) == old_plist, 'previous plist was not restored')
        assert(File.read(supervisor) == old_supervisor, 'previous supervisor was not restored')
        assert(File.read(bootstrap_count).strip == '2', 'prior service was not re-bootstrapped')
        assert(File.exist?(service_state), 'prior service was not returned to a loaded state')
        true
      end
    end

    test('exits nonzero when the child engine loses health so launchd can restart it') do
      Dir.mktmpdir('agentmemory-supervisor') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
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
                printf 'Health: healthy\nMemories: 1,201\n'
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
        FileUtils.chmod(0o755, fake_bin)
        fake_curl = File.join(dir, 'curl')
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          for arg in "$@"; do url="$arg"; done
          case "$url" in
            */agentmemory/livez) printf '{"status":"ok"}\n' ;;
            */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
            */agentmemory/search) printf '{"results":[{"title":"fixture"}]}\n' ;;
            *) exit 1 ;;
          esac
        SH
        FileUtils.chmod(0o755, fake_curl)
        env = {
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
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
          [ "${1:-}" != status ] || printf 'Health: healthy\nMemories: 1,201\n'
          exit 0
        SH
        fake_curl = File.join(dir, 'curl')
        File.write(fake_curl, <<~SH)
          #!/bin/sh
          for arg in "$@"; do url="$arg"; done
          case "$url" in
            */agentmemory/livez) printf '{"status":"ok"}\n' ;;
            */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
            */agentmemory/search) printf '{"results":[{"title":"fixture"}]}\n' ;;
            *) exit 1 ;;
          esac
        SH
        File.write(fake_launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          case "${1:-}" in
            bootstrap) exit 1 ;;
            print)
              echo "$2 = {"
              echo "path = $PLIST"
              echo "state = running"
              echo "program = $SUPERVISOR"
              ;;
          esac
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
          'SUDO_LOG' => sudo_log,
          'PLIST' => plist,
          'SUPERVISOR' => supervisor
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
