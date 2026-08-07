#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

SUPERVISOR = File.expand_path('mini-agentmemory-supervisor.sh', __dir__)
INSTALLER = File.expand_path('mini-install-agentmemory.sh', __dir__)

def write_executable(path, source)
  File.write(path, source)
  FileUtils.chmod(0o755, path)
end

def fake_process_tools(dir)
  state = File.join(dir, 'process-state')
  FileUtils.mkdir_p(state)
  lsof = File.join(dir, 'lsof')
  ps = File.join(dir, 'ps')
  kill = File.join(dir, 'kill')

  write_executable(lsof, <<~SH)
    #!/bin/sh
    port=""
    for arg in "$@"; do
      case "$arg" in -tiTCP:*) port="${arg#-tiTCP:}" ;; esac
    done
    [ -n "$port" ] || exit 1
    [ -f "$PROCESS_STATE/port.$port" ] || exit 0
    while IFS= read -r pid; do
      [ -f "$PROCESS_STATE/alive.$pid" ] && [ ! -f "$PROCESS_STATE/not-listening.$pid" ] && printf '%s\n' "$pid"
    done < "$PROCESS_STATE/port.$port"
  SH
  write_executable(ps, <<~SH)
    #!/bin/sh
    pid=""
    while [ "$#" -gt 0 ]; do
      [ "$1" != -p ] || { shift; pid="${1:-}"; }
      shift
    done
    [ -n "$pid" ] && [ -f "$PROCESS_STATE/alive.$pid" ] && [ -f "$PROCESS_STATE/cmd.$pid" ] || exit 1
    cat "$PROCESS_STATE/cmd.$pid"
  SH
  write_executable(kill, <<~SH)
    #!/bin/sh
    signal="$1"
    pid="$2"
    if [ "$signal" = -0 ]; then
      [ ! -f "$PROCESS_STATE/probe-eperm.$pid" ] || { echo 'Operation not permitted' >&2; exit 1; }
      [ -f "$PROCESS_STATE/alive.$pid" ] && exit 0
      echo 'No such process' >&2
      exit 1
    fi
    printf '%s %s\n' "$signal" "$pid" >> "$PROCESS_STATE/signals"
    if [ -f "$PROCESS_STATE/signal-fail.$pid" ]; then
      touch "$PROCESS_STATE/not-listening.$pid"
      echo 'Operation not permitted' >&2
      exit 1
    fi
    rm -f "$PROCESS_STATE/alive.$pid"
    if [ -n "${RESPAWN_AFTER_PID:-}" ] && [ "$pid" = "$RESPAWN_AFTER_PID" ] && [ -n "${RESPAWN_PID:-}" ]; then
      printf '%s\n' "$RESPAWN_PID" >> "$PROCESS_STATE/port.3113"
    fi
  SH
  [state, lsof, ps, kill]
end

def safe_capture3(env, *command)
  home = env.fetch('HOME')
  log_dir = env.fetch('SANE_AGENTMEMORY_LOG_DIR', File.join(home, 'logs'))
  raise 'test HOME must be isolated' unless home.include?('agentmemory-')
  raise 'test logs must be isolated' unless File.expand_path(log_dir).start_with?(File.expand_path(home) + '/')
  %w[SANE_LSOF_BIN SANE_PS_BIN SANE_KILL_BIN].each do |key|
    path = env.fetch(key)
    raise "unsafe real process tool in test: #{key}" if %w[/usr/sbin/lsof /bin/ps /bin/kill].include?(path)
  end
  Open3.capture3(env, *command)
end

def allowed_child_tools(dir, pid_file)
  ps = File.join(dir, 'allowed-ps')
  kill = File.join(dir, 'allowed-kill')
  write_executable(ps, <<~SH)
    #!/bin/sh
    pid=""
    while [ "$#" -gt 0 ]; do [ "$1" != -p ] || { shift; pid="$1"; }; shift; done
    [ -f "$ALLOWED_PID_FILE" ] && [ "$pid" = "$(cat "$ALLOWED_PID_FILE")" ] || exit 1
    exec /bin/ps -p "$pid" -o command=
  SH
  write_executable(kill, <<~SH)
    #!/bin/sh
    pid="$2"
    [ -f "$ALLOWED_PID_FILE" ] && [ "$pid" = "$(cat "$ALLOWED_PID_FILE")" ] || {
      echo 'No such process' >&2
      exit 1
    }
    exec /bin/kill "$1" "$pid"
  SH
  { 'SANE_PS_BIN' => ps, 'SANE_KILL_BIN' => kill, 'ALLOWED_PID_FILE' => pid_file }
end

def add_fake_process(state, pid:, command:, ports: [])
  File.write(File.join(state, "alive.#{pid}"), "alive\n")
  File.write(File.join(state, "cmd.#{pid}"), "#{command}\n")
  ports.each do |port|
    File.open(File.join(state, "port.#{port}"), 'a') { |file| file.puts(pid) }
  end
end

def cleanup_env(dir, state, lsof, ps, kill)
  {
    'HOME' => dir,
    'PROCESS_STATE' => state,
    'SANE_LSOF_BIN' => lsof,
    'SANE_PS_BIN' => ps,
    'SANE_KILL_BIN' => kill,
    'SANE_AGENTMEMORY_BIN' => File.join(dir, 'agentmemory'),
    'SANE_AGENTMEMORY_III_BIN' => File.join(dir, '.agentmemory', 'bin', 'iii'),
    'SANE_AGENTMEMORY_III_PIDFILE' => File.join(dir, '.agentmemory', 'iii.pid'),
    'SANE_AGENTMEMORY_WORKER_PIDFILE' => File.join(dir, '.agentmemory', 'worker.pid')
  }
end

def assert_signal_survivor(role, pid)
  Dir.mktmpdir("agentmemory-#{role}-survivor") do |dir|
    state, lsof, ps, kill = fake_process_tools(dir)
    env = cleanup_env(dir, state, lsof, ps, kill).merge(
      'SANE_AGENTMEMORY_STOP_INTERVAL' => '0.01',
      'SANE_AGENTMEMORY_WORKER_STOP_ATTEMPTS' => '2',
      'SANE_AGENTMEMORY_ENGINE_STOP_ATTEMPTS' => '2',
      'SANE_AGENTMEMORY_KILL_STOP_ATTEMPTS' => '2'
    )
    FileUtils.mkdir_p(File.dirname(env.fetch('SANE_AGENTMEMORY_III_PIDFILE')))
    if role == 'worker'
      command = env.fetch('SANE_AGENTMEMORY_BIN')
      port = 3113
      pidfile = env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE')
    else
      command = "#{env.fetch('SANE_AGENTMEMORY_III_BIN')} --config fixture"
      port = 3111
      pidfile = env.fetch('SANE_AGENTMEMORY_III_PIDFILE')
    end
    add_fake_process(state, pid: pid, command: command, ports: [port])
    File.write(pidfile, "#{pid}\n")
    File.write(File.join(state, "signal-fail.#{pid}"), "fail\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert(!status.success?, "surviving #{role} was accepted")
    assert_includes(err, "failed to send TERM to #{role} pid #{pid}")
    assert_includes(err, "managed #{role} pid #{pid} survived TERM and KILL")
    assert(File.exist?(File.join(state, "alive.#{pid}")), "#{role} did not survive failure fixture")
    assert(File.exist?(pidfile), "#{role} pidfile was deleted after cleanup failure")
    assert(elapsed < 2, "#{role} survivor cleanup exceeded bound: #{elapsed.round(2)}s")
  end
end

exit(run_tests('Mini AgentMemory Supervisor Tests') do
  test_category('owned runtime cleanup') do
    test('reaps an unresponsive stale iii engine without calling agentmemory stop') do
      Dir.mktmpdir('agentmemory-stale-engine') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        worker_entrypoint = '/opt/homebrew/lib/node_modules/@agentmemory/agentmemory/dist/cli.mjs'
        env['SANE_AGENTMEMORY_WORKER_TOKEN'] = worker_entrypoint
        FileUtils.mkdir_p(File.dirname(env.fetch('SANE_AGENTMEMORY_III_PIDFILE')))
        write_executable(env.fetch('SANE_AGENTMEMORY_BIN'), "#!/bin/sh\necho called >> \"$PROCESS_STATE/agentmemory-calls\"\n")
        add_fake_process(state, pid: 4101,
                         command: "#{env.fetch('SANE_AGENTMEMORY_III_BIN')} --config fixture",
                         ports: [3111, 3112, 49_134])
        add_fake_process(state, pid: 4102,
                         command: "/opt/homebrew/opt/node@24/bin/node #{worker_entrypoint}", ports: [3113])
        File.write(env.fetch('SANE_AGENTMEMORY_III_PIDFILE'), "4101\n")
        File.write(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE'), "4102\n")

        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(status.success?, err)
        signals = File.readlines(File.join(state, 'signals')).map(&:strip)
        assert(signals == ['-TERM 4102', '-TERM 4101'], "worker/engine stop order was #{signals.inspect}")
        assert(!File.exist?(File.join(state, 'alive.4101')), 'stale iii engine survived cleanup')
        assert(!File.exist?(File.join(state, 'alive.4102')), 'stale worker survived cleanup')
        assert(!File.exist?(File.join(state, 'agentmemory-calls')), 'cleanup delegated to the broken upstream stop command')
        assert(!File.exist?(env.fetch('SANE_AGENTMEMORY_III_PIDFILE')), 'stale iii pidfile survived cleanup')
        true
      end
    end

    test('fails closed without signaling an unrelated canonical-port listener') do
      Dir.mktmpdir('agentmemory-unrelated-listener') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        add_fake_process(state, pid: 4201, command: '/usr/bin/python3 unrelated.py', ports: [3111])

        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(!status.success?, 'unrelated listener was accepted')
        assert_includes(err, 'unrelated pid 4201')
        assert(File.exist?(File.join(state, 'alive.4201')), 'unrelated listener was killed')
        assert(!File.exist?(File.join(state, 'signals')), 'a signal was sent despite failed ownership proof')
        true
      end
    end

    test('reaps only validated iii while preserving an unrelated listener') do
      Dir.mktmpdir('agentmemory-no-collateral') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        worker_entrypoint = '/opt/homebrew/lib/node_modules/@agentmemory/agentmemory/dist/cli.mjs'
        env['SANE_AGENTMEMORY_WORKER_TOKEN'] = worker_entrypoint
        add_fake_process(state, pid: 4301,
                         command: "#{env.fetch('SANE_AGENTMEMORY_III_BIN')} --config fixture", ports: [3111])
        # v0.9.27 uses process.argv.slice(2): the managed foreground worker has
        # no subcommand, while a concurrent `status` CLI is not service-owned.
        add_fake_process(state, pid: 4302,
                         command: "/opt/homebrew/opt/node@24/bin/node #{worker_entrypoint} status", ports: [3113])

        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(!status.success?, 'mixed owned/unrelated runtime was accepted')
        signals = File.read(File.join(state, 'signals'))
        assert_includes(signals, '-TERM 4301')
        assert(!signals.include?('4302'), 'unrelated process received a signal')
        assert(File.exist?(File.join(state, 'alive.4302')), 'unrelated process was killed')
        true
      end
    end

    test('refuses cleanup when listener inspection fails operationally') do
      Dir.mktmpdir('agentmemory-lsof-failure') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        write_executable(lsof, "#!/bin/sh\necho 'permission denied' >&2\nexit 2\n")
        FileUtils.mkdir_p(File.dirname(env.fetch('SANE_AGENTMEMORY_III_PIDFILE')))
        add_fake_process(state, pid: 4401,
                         command: "#{env.fetch('SANE_AGENTMEMORY_III_BIN')} --config fixture",
                         ports: [3111])
        File.write(env.fetch('SANE_AGENTMEMORY_III_PIDFILE'), "4401\n")

        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(!status.success?, 'lsof operational failure was treated as free ports')
        assert_includes(err, 'Listener inspection failed')
        assert(!File.exist?(File.join(state, 'signals')), 'cleanup signaled a process without listener proof')
        assert(File.exist?(File.join(state, 'alive.4401')), 'pidfile-owned engine was killed without listener proof')
        true
      end
    end


    test('fails closed when a correlated worker survives TERM and KILL') do
      assert_signal_survivor('worker', 4501)
      true
    end

    test('fails closed when a correlated iii engine survives TERM and KILL') do
      assert_signal_survivor('engine', 4502)
      true
    end

    test('treats EPERM process existence as indeterminate, not absent') do
      Dir.mktmpdir('agentmemory-pid-eperm') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        FileUtils.mkdir_p(File.dirname(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE')))
        File.write(File.join(state, 'alive.4503'), "alive\n")
        File.write(File.join(state, 'probe-eperm.4503'), "eperm\n")
        File.write(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE'), "4503\n")
        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(!status.success?, 'EPERM existence probe was treated as an absent pid')
        assert_includes(err, 'could not determine worker pidfile pid 4503 state')
        assert(File.exist?(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE')), 'indeterminate pidfile was deleted')
        assert(!File.exist?(File.join(state, 'signals')), 'indeterminate PID received a signal')
        true
      end
    end

    test('rejects a malformed pidfile without signaling the whitespace-glued pid') do
      Dir.mktmpdir('agentmemory-malformed-pidfile') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill)
        FileUtils.mkdir_p(File.dirname(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE')))
        add_fake_process(state, pid: 1234, command: env.fetch('SANE_AGENTMEMORY_BIN'))
        File.write(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE'), "12 34\n")
        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(status.success?, err)
        assert(File.exist?(File.join(state, 'alive.1234')), 'malformed pidfile was normalized into a live pid')
        assert(!File.exist?(File.join(state, 'signals')), 'malformed pidfile caused a signal')
        assert(!File.exist?(env.fetch('SANE_AGENTMEMORY_WORKER_PIDFILE')), 'malformed stale pidfile was not removed')
        true
      end
    end

    test('stops a worker discovered after the first worker barrier before iii') do
      Dir.mktmpdir('agentmemory-worker-respawn') do |dir|
        state, lsof, ps, kill = fake_process_tools(dir)
        env = cleanup_env(dir, state, lsof, ps, kill).merge(
          'RESPAWN_AFTER_PID' => '4601',
          'RESPAWN_PID' => '4602'
        )
        add_fake_process(state, pid: 4601, command: env.fetch('SANE_AGENTMEMORY_BIN'), ports: [3113])
        add_fake_process(state, pid: 4602, command: env.fetch('SANE_AGENTMEMORY_BIN'))
        add_fake_process(state, pid: 4603,
                         command: "#{env.fetch('SANE_AGENTMEMORY_III_BIN')} --config fixture", ports: [3111])
        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR, '--cleanup')
        assert(status.success?, err)
        signals = File.readlines(File.join(state, 'signals')).map(&:strip)
        assert(signals == ['-TERM 4601', '-TERM 4602', '-TERM 4603'], "respawn stop order was #{signals.inspect}")
        true
      end
    end
  end

  test_category('installer port gate') do
    test('does not bootstrap when listener inspection is unavailable') do
      Dir.mktmpdir('agentmemory-installer-lsof-failure') do |dir|
        process_state, _default_lsof, fake_ps, fake_kill = fake_process_tools(dir)
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_lsof = File.join(dir, 'lsof')
        fake_launchctl = File.join(dir, 'launchctl')
        launchctl_log = File.join(dir, 'launchctl.log')
        plist = File.join(dir, 'LaunchAgents', 'agentmemory.plist')
        installed_supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
        write_executable(fake_bin, "#!/bin/sh\n[ \"${1:-}\" != --version ] || echo '0.9.28'\nexit 0\n")
        write_executable(fake_curl, "#!/bin/sh\nexit 1\n")
        write_executable(fake_lsof, "#!/bin/sh\necho 'inspection unavailable' >&2\nexit 2\n")
        write_executable(fake_launchctl, <<~SH)
          #!/bin/sh
          echo "$*" >> "$LAUNCHCTL_LOG"
          case "${1:-}" in
            print) echo 'Could not find service' >&2; exit 1 ;;
            print-disabled) printf 'disabled services = {\n}\n' ;;
          esac
          exit 0
        SH
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_LSOF_BIN' => fake_lsof,
          'SANE_PS_BIN' => fake_ps,
          'SANE_KILL_BIN' => fake_kill,
          'SANE_LAUNCHCTL_BIN' => fake_launchctl,
          'SANE_SUDO_BIN' => '/usr/bin/false',
          'SANE_AGENTMEMORY_PLIST' => plist,
          'SANE_AGENTMEMORY_SUPERVISOR' => installed_supervisor,
          'SANE_AGENTMEMORY_LOG_DIR' => File.join(dir, 'logs'),
          'LAUNCHCTL_LOG' => launchctl_log,
          'PROCESS_STATE' => process_state
        }

        _out, err, status = safe_capture3(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'installer bootstrapped without listener inspection')
        assert_includes(err, 'canonical ports are not safely owned and free')
        calls = File.readlines(launchctl_log).map(&:strip)
        assert(!calls.any? { |line| line.start_with?('bootstrap ') }, calls.join("\n"))
        true
      end
    end
  end

  test_category('route-loss restart') do
    test('treats HTTP route loss as unhealthy and stops the complete owned worker') do
      Dir.mktmpdir('agentmemory-route-loss') do |dir|
        fake_bin = File.join(dir, 'agentmemory')
        fake_curl = File.join(dir, 'curl')
        fake_lsof = File.join(dir, 'lsof')
        route_count = File.join(dir, 'route-count')
        child_pid = File.join(dir, 'child-pid')
        auth_log = File.join(dir, 'auth.log')
        curl_args_log = File.join(dir, 'curl-args.log')
        log_dir = File.join(dir, 'logs')
        FileUtils.mkdir_p(log_dir)
        File.write(File.join(log_dir, 'agentmemory.out.log'), 'x' * 100)
        File.write(File.join(log_dir, 'agentmemory.err.log'), 'y' * 100)

        write_executable(fake_bin, <<~SH)
          #!/bin/sh
          case "${1:-}" in
            status) printf 'Health: healthy\nMemories: 1,201\n' ;;
            *)
              printf '%s\n' "$$" > "$CHILD_PID_FILE"
              trap 'exit 0' TERM INT
              while :; do sleep 1; done
              ;;
          esac
        SH
        write_executable(fake_curl, <<~SH)
          #!/bin/sh
          printf '%s\n' "$*" >> "$CURL_ARGS_LOG"
          read_header=0
          for arg in "$@"; do
            [ "$arg" != '@-' ] || read_header=1
            url="$arg"
          done
          if [ "$read_header" -eq 1 ]; then
            IFS= read -r header || true
            printf '%s\n' "$header" >> "$AUTH_LOG"
          fi
          case "$url" in
            */agentmemory/livez)
              count=0
              [ ! -f "$ROUTE_COUNT" ] || count="$(cat "$ROUTE_COUNT")"
              count=$((count + 1))
              printf '%s\n' "$count" > "$ROUTE_COUNT"
              [ "$count" -le 2 ] || exit 22
              printf '{"status":"ok"}\n'
              ;;
            */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
            */agentmemory/search) printf '{"results":[]}\n' ;;
            *) exit 1 ;;
          esac
        SH
        write_executable(fake_lsof, "#!/bin/sh\nexit 0\n")
        env = {
          'HOME' => dir,
          'SANE_AGENTMEMORY_BIN' => fake_bin,
          'SANE_CURL_BIN' => fake_curl,
          'SANE_LSOF_BIN' => fake_lsof,
          'SANE_AGENTMEMORY_III_PIDFILE' => File.join(dir, 'iii.pid'),
          'SANE_AGENTMEMORY_WORKER_PIDFILE' => File.join(dir, 'worker.pid'),
          'SANE_AGENTMEMORY_HEALTH_INTERVAL' => '0.05',
          'SANE_AGENTMEMORY_HEALTH_MISSES' => '2',
          'SANE_AGENTMEMORY_STARTUP_ATTEMPTS' => '2',
          'SANE_AGENTMEMORY_STARTUP_INTERVAL' => '0.01',
          'SANE_AGENTMEMORY_LOG_DIR' => log_dir,
          'SANE_AGENTMEMORY_LOG_MAX_BYTES' => '50',
          'SANE_AGENTMEMORY_LOG_KEEP_BYTES' => '20',
          'ROUTE_COUNT' => route_count,
          'CHILD_PID_FILE' => child_pid,
          'AGENTMEMORY_SECRET' => 'fixture-secret',
          'AUTH_LOG' => auth_log,
          'CURL_ARGS_LOG' => curl_args_log
        }.merge(allowed_child_tools(dir, child_pid))

        _out, err, status = safe_capture3(env, '/bin/bash', SUPERVISOR)
        assert(!status.success?, 'route loss did not request a launchd restart')
        assert_includes(err, 'exiting for launchd restart')
        assert(File.read(route_count).to_i >= 4, 'route did not remain absent through the health threshold')
        assert(File.size(File.join(log_dir, 'agentmemory.out.log')) <= 20, 'stdout log was not bounded')
        assert(File.size(File.join(log_dir, 'agentmemory.err.log')) <= 20, 'stderr log was not bounded')
        assert_includes(File.read(auth_log), 'Authorization: Bearer fixture-secret')
        assert(!File.read(curl_args_log).include?('fixture-secret'), 'bearer secret leaked into curl argv')
        pid = Integer(File.read(child_pid))
        alive = true
        begin
          Process.kill(0, pid)
        rescue Errno::ESRCH
          alive = false
        end
        assert(!alive, "owned worker #{pid} survived route-loss restart")
        true
      end
    end
  end
end)
