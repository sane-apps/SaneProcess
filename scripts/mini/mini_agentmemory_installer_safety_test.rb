#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

INSTALLER = File.expand_path('mini-install-agentmemory.sh', __dir__)

def write_exec(path, source)
  File.write(path, source)
  FileUtils.chmod(0o755, path)
end

def safe_capture(env, *command)
  home = env.fetch('HOME')
  raise 'test HOME must be isolated' unless home.include?('agentmemory-')
  raise 'test logs must be isolated' unless env.fetch('SANE_AGENTMEMORY_LOG_DIR').start_with?(home + '/')
  %w[SANE_LSOF_BIN SANE_PS_BIN SANE_KILL_BIN].each do |key|
    raise "unsafe real process tool: #{key}" if %w[/usr/sbin/lsof /bin/ps /bin/kill].include?(env.fetch(key))
  end
  Open3.capture3(env, *command)
end

def installer_fixture(dir)
  state = File.join(dir, 'process-state')
  FileUtils.mkdir_p(state)
  lsof = File.join(dir, 'lsof')
  ps = File.join(dir, 'ps')
  kill = File.join(dir, 'kill')
  agentmemory = File.join(dir, 'agentmemory')
  curl = File.join(dir, 'curl')
  launchctl = File.join(dir, 'launchctl')
  service_state = File.join(dir, 'service-state')
  launchctl_log = File.join(dir, 'launchctl.log')
  bootstrap_count = File.join(dir, 'bootstrap-count')
  plist = File.join(dir, 'LaunchAgents', 'agentmemory.plist')
  supervisor = File.join(dir, 'libexec', 'agentmemory-supervisor')
  health_lib = File.join(dir, 'libexec', 'mini-agentmemory-health.sh')
  FileUtils.mkdir_p([File.dirname(plist), File.dirname(supervisor)])
  old_plist = '<plist><dict><key>Label</key><string>previous</string></dict></plist>'
  old_supervisor = "#!/bin/bash\necho previous\n"
  old_health = "# previous health helper\n"
  File.write(plist, old_plist)
  File.write(supervisor, old_supervisor)
  File.write(health_lib, old_health)
  File.write(service_state, "running\n")
  FileUtils.chmod(0o755, supervisor)

  write_exec(agentmemory, <<~SH)
    #!/bin/sh
    case "${1:-}" in
      --version) printf '%s\n' "${AGENTMEMORY_TEST_VERSION:-0.9.28}" ;;
      status) printf 'Health: healthy\nMemories: 1,201\n' ;;
    esac
  SH
  write_exec(curl, <<~SH)
    #!/bin/sh
    for arg in "$@"; do url="$arg"; done
    case "$url" in
      */agentmemory/livez) printf '{"status":"ok"}\n' ;;
      */agentmemory/health) printf '{"service":"agentmemory","status":"healthy"}\n' ;;
      */agentmemory/search) printf '{"results":[]}\n' ;;
      *) exit 1 ;;
    esac
  SH
  write_exec(lsof, <<~SH)
    #!/bin/sh
    if [ -f "$LSOF_FAIL_ONCE" ]; then
      rm -f "$LSOF_FAIL_ONCE"
      echo 'inspection unavailable' >&2
      exit 2
    fi
    port=""
    for arg in "$@"; do case "$arg" in -tiTCP:*) port="${arg#-tiTCP:}" ;; esac; done
    [ -f "$PROCESS_STATE/port.$port" ] || exit 0
    while IFS= read -r pid; do
      [ -f "$PROCESS_STATE/alive.$pid" ] && [ ! -f "$PROCESS_STATE/not-listening.$pid" ] && echo "$pid"
    done < "$PROCESS_STATE/port.$port"
  SH
  write_exec(ps, <<~SH)
    #!/bin/sh
    pid=""
    while [ "$#" -gt 0 ]; do [ "$1" != -p ] || { shift; pid="$1"; }; shift; done
    [ -f "$PROCESS_STATE/alive.$pid" ] && [ -f "$PROCESS_STATE/cmd.$pid" ] || exit 1
    cat "$PROCESS_STATE/cmd.$pid"
  SH
  write_exec(kill, <<~SH)
    #!/bin/sh
    signal="$1"; pid="$2"
    if [ "$signal" = -0 ]; then
      [ -f "$PROCESS_STATE/alive.$pid" ] && exit 0
      echo 'No such process' >&2; exit 1
    fi
    echo "$signal $pid" >> "$PROCESS_STATE/signals"
    [ ! -f "$PROCESS_STATE/signal-fail.$pid" ] || {
      touch "$PROCESS_STATE/not-listening.$pid"
      echo 'Operation not permitted' >&2; exit 1
    }
    rm -f "$PROCESS_STATE/alive.$pid"
  SH
  write_exec(launchctl, <<~SH)
    #!/bin/sh
    echo "$*" >> "$LAUNCHCTL_LOG"
    case "${1:-}" in
      print)
        [ ! -f "$LAUNCHCTL_PERMISSION_FAIL" ] || { echo 'Operation not permitted' >&2; exit 1; }
        [ -f "$SERVICE_STATE" ] || { echo 'Could not find service' >&2; exit 1; }
        printf '%s = {\npath = %s\nstate = running\nprogram = %s\n}\n' "$2" "$PLIST" "$SUPERVISOR"
        ;;
      print-disabled) printf 'disabled services = {\n}\n' ;;
      bootout)
        [ ! -f "$BOOTOUT_FAIL" ] || { echo 'Operation not permitted' >&2; exit 5; }
        [ -f "$SERVICE_STATE" ] || { echo 'Boot-out failed: 3: No such process' >&2; exit 3; }
        rm -f "$SERVICE_STATE"
        ;;
      bootstrap)
        count=0; [ ! -f "$BOOTSTRAP_COUNT" ] || count="$(cat "$BOOTSTRAP_COUNT")"
        count=$((count + 1)); echo "$count" > "$BOOTSTRAP_COUNT"
        if [ -f "$BOOTSTRAP_FAIL_ONCE" ]; then rm -f "$BOOTSTRAP_FAIL_ONCE"; exit 5; fi
        [ ! -f "$BOOTSTRAP_FAIL" ] || exit 5
        echo running > "$SERVICE_STATE"
        ;;
    esac
  SH

  env = {
    'HOME' => dir,
    'SANE_AGENTMEMORY_BIN' => agentmemory,
    'SANE_CURL_BIN' => curl,
    'SANE_LSOF_BIN' => lsof,
    'SANE_PS_BIN' => ps,
    'SANE_KILL_BIN' => kill,
    'SANE_LAUNCHCTL_BIN' => launchctl,
    'SANE_SUDO_BIN' => '/usr/bin/false',
    'SANE_AGENTMEMORY_PLIST' => plist,
    'SANE_AGENTMEMORY_SUPERVISOR' => supervisor,
    'SANE_AGENTMEMORY_HEALTH_LIB' => health_lib,
    'SANE_AGENTMEMORY_LOG_DIR' => File.join(dir, 'logs'),
    'SANE_AGENTMEMORY_STOP_INTERVAL' => '0.01',
    'SANE_AGENTMEMORY_WORKER_STOP_ATTEMPTS' => '2',
    'SANE_AGENTMEMORY_ENGINE_STOP_ATTEMPTS' => '2',
    'SANE_AGENTMEMORY_KILL_STOP_ATTEMPTS' => '2',
    'PROCESS_STATE' => state,
    'SERVICE_STATE' => service_state,
    'LAUNCHCTL_LOG' => launchctl_log,
    'BOOTSTRAP_COUNT' => bootstrap_count,
    'BOOTSTRAP_FAIL' => File.join(dir, 'bootstrap-fail'),
    'BOOTSTRAP_FAIL_ONCE' => File.join(dir, 'bootstrap-fail-once'),
    'BOOTOUT_FAIL' => File.join(dir, 'bootout-fail'),
    'LSOF_FAIL_ONCE' => File.join(dir, 'lsof-fail-once'),
    'LAUNCHCTL_PERMISSION_FAIL' => File.join(dir, 'launchctl-permission-fail'),
    'PLIST' => plist,
    'SUPERVISOR' => supervisor
  }
  [env, { state: state, plist: plist, supervisor: supervisor, health_lib: health_lib,
          old_plist: old_plist, old_supervisor: old_supervisor, old_health: old_health,
          launchctl_log: launchctl_log, bootstrap_count: bootstrap_count,
          service_state: service_state }]
end

exit(run_tests('Mini AgentMemory Installer Safety Tests') do
  test_category('fail-closed discovery') do
    test('rejects launchctl permission failure before mutation') do
      Dir.mktmpdir('agentmemory-launchctl-permission') do |dir|
        env, paths = installer_fixture(dir)
        File.write(env.fetch('LAUNCHCTL_PERMISSION_FAIL'), "fail\n")
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'launchctl permission failure was treated as not loaded')
        assert_includes(err, 'Could not determine whether')
        calls = File.read(paths.fetch(:launchctl_log))
        assert(!calls.match?(/^(?:bootout|bootstrap) /), 'launchd mutated after discovery failure')
        true
      end
    end

    test('requires the exact managed AgentMemory version before dry-run') do
      Dir.mktmpdir('agentmemory-version-mismatch') do |dir|
        env, = installer_fixture(dir)
        env['AGENTMEMORY_TEST_VERSION'] = '0.9.27'
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER, '--dry-run')
        assert(!status.success?, 'stale AgentMemory version passed preflight')
        assert_includes(err, 'expected 0.9.28')
        true
      end
    end
  end

  test_category('rollback safety') do
    test('reboots the prior service when failed candidate bootstrap leaves no job') do
      Dir.mktmpdir('agentmemory-rollback-candidate-not-found') do |dir|
        env, paths = installer_fixture(dir)
        File.write(env.fetch('BOOTSTRAP_FAIL_ONCE'), "fail\n")
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'failed candidate bootstrap was reported as success')
        assert(File.exist?(paths.fetch(:service_state)), 'prior service was not re-bootstrapped')
        assert(File.read(paths.fetch(:bootstrap_count)).to_i == 2, 'expected candidate and rollback bootstrap attempts')
        assert(!err.include?('bootstrap skipped because rollback safety is unproven'), err)
        assert(File.read(paths.fetch(:plist)) == paths.fetch(:old_plist), 'previous plist was not restored')
        true
      end
    end

    test('reboots the prior service after a transient pre-bootstrap cleanup failure') do
      Dir.mktmpdir('agentmemory-rollback-transient-cleanup') do |dir|
        env, paths = installer_fixture(dir)
        File.write(env.fetch('LSOF_FAIL_ONCE'), "fail\n")
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'transient pre-bootstrap cleanup failure was reported as success')
        assert(File.exist?(paths.fetch(:service_state)), 'prior service was not re-bootstrapped')
        assert(File.read(paths.fetch(:bootstrap_count)).to_i == 1, 'rollback bootstrap was not the only bootstrap attempt')
        assert(!err.include?('bootstrap skipped because rollback safety is unproven'), err)
        assert(File.read(paths.fetch(:supervisor)) == paths.fetch(:old_supervisor), 'previous supervisor was not restored')
        true
      end
    end

    test('preserves survivor state and never bootstraps after cleanup failure') do
      Dir.mktmpdir('agentmemory-rollback-survivor') do |dir|
        env, paths = installer_fixture(dir)
        pid = 5101
        File.write(File.join(paths.fetch(:state), "alive.#{pid}"), "alive\n")
        File.write(File.join(paths.fetch(:state), "cmd.#{pid}"), "#{dir}/.agentmemory/bin/iii --config fixture\n")
        File.write(File.join(paths.fetch(:state), "port.3111"), "#{pid}\n")
        File.write(File.join(paths.fetch(:state), "signal-fail.#{pid}"), "fail\n")
        FileUtils.mkdir_p(File.join(dir, '.agentmemory'))
        pidfile = File.join(dir, '.agentmemory', 'iii.pid')
        File.write(pidfile, "#{pid}\n")
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'surviving candidate process was accepted')
        assert_includes(err, 'bootstrap skipped because rollback safety is unproven')
        assert(!File.exist?(paths.fetch(:bootstrap_count)), 'rollback bootstrapped over surviving candidate state')
        assert(File.exist?(pidfile), 'survivor pidfile was deleted')
        true
      end
    end

    test('skips bootstrap when prior files cannot be restored') do
      Dir.mktmpdir('agentmemory-rollback-restore-failure') do |dir|
        env, paths = installer_fixture(dir)
        File.write(env.fetch('BOOTSTRAP_FAIL'), "fail\n")
        restore_cp = File.join(dir, 'restore-cp')
        write_exec(restore_cp, "#!/bin/sh\nexit 1\n")
        env['SANE_AGENTMEMORY_RESTORE_CP_BIN'] = restore_cp
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'restore failure was accepted')
        assert_includes(err, 'previous AgentMemory plist could not be restored')
        assert_includes(err, 'bootstrap skipped because rollback safety is unproven')
        assert(File.read(paths.fetch(:bootstrap_count)).to_i == 1, 'rollback attempted a second bootstrap')
        true
      end
    end

    test('skips bootstrap when candidate launchd bootout fails') do
      Dir.mktmpdir('agentmemory-rollback-bootout-failure') do |dir|
        env, paths = installer_fixture(dir)
        File.write(env.fetch('BOOTOUT_FAIL'), "fail\n")
        _out, err, status = safe_capture(env, '/bin/bash', INSTALLER)
        assert(!status.success?, 'bootout failure was accepted')
        assert_includes(err, 'could not be unloaded during rollback')
        assert_includes(err, 'bootstrap skipped because rollback safety is unproven')
        assert(!File.exist?(paths.fetch(:bootstrap_count)), 'rollback bootstrapped after bootout failure')
        true
      end
    end
  end
end)
