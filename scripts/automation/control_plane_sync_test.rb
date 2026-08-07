#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
SYNC = File.join(ROOT, 'automation', 'sync-codex-mini.sh')
RECONCILE = File.join(ROOT, 'automation', 'reconcile-air-mini.sh')
START_WORKDAY = File.join(ROOT, 'automation', 'start-workday.sh')

manifest_output, manifest_status = Open3.capture2('bash', SYNC, '--dump-manifest')
raise 'could not load sync manifest' unless manifest_status.success?

CONTROL_PLANE_REL_FILES = manifest_output.lines.map(&:strip).reject(&:empty?).freeze

CODEX_BIN_FILES = %w[
  check-mcps
  github-mcp-bridge.mjs
  xcode-mcpbridge-wrapper.sh
].freeze

FORBIDDEN_AUTOMATION_PATHS = %w[
  .codex/automations
  codex-dev.db
  state_5.sqlite
].freeze

def assert(condition, message)
  raise message unless condition
end

def run(env, *command)
  stdout, stderr, status = Open3.capture3(env, *command)
  return [stdout, stderr, status] if block_given?

  raise "command failed: #{command.join(' ')}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}" unless status.success?

  stdout
end

def parse_dump(text)
  text.lines.map do |line|
    next unless line.include?('=')

    line.strip.split('=', 2)
  end.compact.to_h
end

def write(path, content, executable: false)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
  FileUtils.chmod(0o755, path) if executable
end

def sha(path)
  Digest::SHA256.file(path).hexdigest
end

def manifest_snapshot(root)
  CONTROL_PLANE_REL_FILES.to_h do |rel|
    path = File.join(root, rel)
    [rel, File.file?(path) ? sha(path) : :missing]
  end
end

def assert_manifest_snapshot(root, expected, label)
  actual = manifest_snapshot(root)
  changed = expected.keys.reject { |rel| expected[rel] == actual[rel] }
  assert(changed.empty?, "#{label} changed manifest paths: #{changed.join(', ')}")
end

def fake_transport!(bin_dir)
  write(File.join(bin_dir, 'ssh'), <<~'BASH', executable: true)
    #!/bin/bash
    set -euo pipefail
    printf 'ssh' >> "$SYNC_OP_LOG"
    printf '\t%s' "$@" >> "$SYNC_OP_LOG"
    printf '\n' >> "$SYNC_OP_LOG"

    while [[ "${1:-}" == -* ]]; do
      case "$1" in
        -o|-F|-i|-J|-l|-p) shift 2 ;;
        *) shift ;;
      esac
    done
    [[ $# -gt 0 ]] || exit 0
    shift # host
    command="$*"

    case "$command" in
      *'printf %s "$HOME"'*) printf '%s' "$REMOTE_HOME" ;;
      *'hostname -s'*) printf '%s\n' 'fixture-mini' ;;
      *'SUPPORTED_CODEX_CLI_VERSION='*'bash -s'*) cat >/dev/null ;;
      *'/.local/bin/codex" --version'*) printf 'codex-cli 0.250.0\n' ;;
      *'--validate-manifest-root'*)
        HOME="$REMOTE_HOME" /bin/bash -c "$command"
        status=$?
        if [[ "$status" -eq 0 && "${MUTATE_PEER_AFTER_STAGE:-0}" == "1" ]]; then
          target="$REMOTE_HOME/SaneApps/infra/scripts/check-inbox.sh"
          mkdir -p "$(dirname "$target")"
          printf 'concurrent peer mutation\n' > "$target"
        fi
        exit "$status"
        ;;
      *) HOME="$REMOTE_HOME" /bin/bash -c "$command" ;;
    esac
  BASH

  write(File.join(bin_dir, 'scp'), <<~'BASH', executable: true)
    #!/bin/bash
    set -euo pipefail
    printf 'scp' >> "$SYNC_OP_LOG"
    printf '\t%s' "$@" >> "$SYNC_OP_LOG"
    printf '\n' >> "$SYNC_OP_LOG"

    operands=()
    for arg in "$@"; do
      [[ "$arg" == -* ]] && continue
      operands+=("$arg")
    done
    destination="${operands[$((${#operands[@]} - 1))]}"
    destination="${destination#*:}"
    source_count=$((${#operands[@]} - 1))
    for ((i = 0; i < source_count; i++)); do
      source="${operands[$i]}"
      if [[ "$destination" == */ || -d "$destination" || $source_count -gt 1 ]]; then
        mkdir -p "$destination"
        cp "$source" "$destination/"
      else
        mkdir -p "$(dirname "$destination")"
        cp "$source" "$destination"
      fi
    done
  BASH

  write(File.join(bin_dir, 'rsync'), <<~'BASH', executable: true)
    #!/bin/bash
    set -euo pipefail
    printf 'rsync' >> "$SYNC_OP_LOG"
    printf '\t%s' "$@" >> "$SYNC_OP_LOG"
    printf '\n' >> "$SYNC_OP_LOG"

    dry_run=0
    operands=()
    for arg in "$@"; do
      [[ "$arg" == '--dry-run' ]] && dry_run=1
      [[ "$arg" == -* ]] && continue
      operands+=("$arg")
    done
    [[ "$dry_run" -eq 1 ]] && exit 0
    source="${operands[$((${#operands[@]} - 2))]}"
    destination="${operands[$((${#operands[@]} - 1))]}"
    destination="${destination#*:}"
    mkdir -p "$destination"
    cp -R "${source%/}/." "$destination/"
  BASH
end

def create_sync_fixture(home, remote_home)
  write(File.join(home, '.codex', 'config.toml'), <<~TOML)
    model = "gpt-5.6"
    command = "#{home}/bin/node"
    helper = "#{home}/SaneApps/infra/SaneProcess/scripts/codex-bin/check-mcps"

    [mcp_servers.agentmemory]
    command = "#{home}/SaneApps/infra/SaneProcess/scripts/automation/agentmemory-mcp-air.sh"
    args = []
  TOML
  write(File.join(remote_home, '.codex', 'config.toml'), <<~TOML)
    model = "fixture-mini-managed"
    command = "#{remote_home}/bin/node"
  TOML
  write(File.join(home, '.codex', 'SKILLS_REGISTRY.md'), "fixture registry\n")
  write(File.join(home, '.codex', 'skills', 'fixture', 'SKILL.md'), "fixture skill\n")
  write(File.join(home, '.agents', 'skills', 'shared', 'SKILL.md'), "shared skill\n")
  write(File.join(remote_home, '.codex', 'skills', 'mini-only', 'SKILL.md'), "preserve me\n")
  write(File.join(remote_home, '.agents', 'skills', 'mini-only', 'SKILL.md'), "preserve me too\n")

  CODEX_BIN_FILES.each do |name|
    write(File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'scripts', 'codex-bin', name),
          "#!/bin/bash\necho #{name}\n", executable: true)
  end
  CONTROL_PLANE_REL_FILES.each do |rel|
    write(File.join(home, rel), "fixture #{rel}\n", executable: rel.end_with?('.sh', '.rb'))
  end
  sync_rel = 'SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh'
  write(File.join(home, sync_rel), File.read(SYNC), executable: true)
  git_sync_rel = 'SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh'
  git_sync_fixture = <<~'BASH'
    #!/bin/bash
    printf 'snapshot\t%s\n' "$*" >> "$SYNC_OP_LOG"
  BASH
  write(File.join(home, git_sync_rel), git_sync_fixture, executable: true)
  write(File.join(remote_home, git_sync_rel), git_sync_fixture, executable: true)

  cli = "#!/bin/bash\necho 'codex-cli 0.250.0'\n"
  write(File.join(home, '.codex', 'packages', 'standalone', 'current', 'codex'), cli, executable: true)
  write(File.join(home, '.local', 'bin', 'codex'), cli, executable: true)
  write(File.join(remote_home, '.codex', 'packages', 'standalone', 'current', 'codex'), cli, executable: true)
  write(File.join(remote_home, '.local', 'bin', 'codex'), cli, executable: true)

  write(File.join(remote_home, sync_rel), File.read(File.join(home, sync_rel)), executable: true)
  [home, remote_home].each do |root|
    repo = File.join(root, 'SaneApps', 'infra', 'SaneProcess')
    write(File.join(repo, '.gitignore'), "*\n")
    run({}, 'git', '-C', repo, 'init', '-b', 'main')
    run({}, 'git', '-C', repo, 'config', 'user.email', 'fixture@example.com')
    run({}, 'git', '-C', repo, 'config', 'user.name', 'Fixture')
    run({}, 'git', '-C', repo, 'add', '-f', '.gitignore', 'scripts/automation/sync-codex-mini.sh')
    commit_env = {
      'GIT_AUTHOR_DATE' => '2026-01-01T00:00:00Z',
      'GIT_COMMITTER_DATE' => '2026-01-01T00:00:00Z'
    }
    run(commit_env, 'git', '-C', repo, 'commit', '-m', 'fixture control plane')
  end
end

def protect_automation_stores(home, remote_home)
  sentinels = []
  [home, remote_home].each do |root|
    automation = File.join(root, '.codex', 'automations', 'sentinel.toml')
    legacy_db = File.join(root, '.codex', 'sqlite', 'codex-dev.db')
    state_db = File.join(root, '.codex', 'state_5.sqlite')
    [automation, legacy_db, state_db].each do |path|
      write(path, "must remain untouched: #{path}\n")
      sentinels << [path, sha(path)]
      FileUtils.chmod(0o000, path)
    end
    FileUtils.chmod(0o000, File.dirname(automation))
  end
  sentinels
end

def restore_automation_store_permissions(home, remote_home, sentinels)
  [home, remote_home].each do |root|
    FileUtils.chmod(0o700, File.join(root, '.codex', 'automations'))
  end
  sentinels.each { |path, _| FileUtils.chmod(0o600, path) }
end

tests = []

tests << lambda do
  dump = parse_dump(run({}, 'bash', SYNC, '--dump-config'))
  assert(dump == {
           'MINI_HOST' => 'mini',
           'QUIET' => '0',
           'RESTART_CODEX' => '0',
           'ALLOW_REVIEWED_DIRTY' => '0'
         },
         "unexpected sync config: #{dump}")
  assert(CONTROL_PLANE_REL_FILES.include?('SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh'),
         'sync manifest must include itself')
  assert(CONTROL_PLANE_REL_FILES.include?('SaneApps/infra/SaneProcess/scripts/automation/control_plane_sync_test.rb'),
         'sync manifest must include its contract test')

  _stdout, stderr, status = run({}, 'bash', SYNC, '--activate-mini-runs', '--dump-config') { true }
  assert(!status.success? && stderr.include?('Unknown option'), 'legacy activation flag must fail closed')
end

tests << lambda do
  dump = parse_dump(run({}, 'bash', RECONCILE, '--dump-config'))
  assert(dump == { 'MINI_HOST' => 'mini', 'QUIET' => '0', 'SYNC_CONTROL_PLANE' => '0' },
         "unexpected reconcile config: #{dump}")

  _stdout, stderr, status = run({}, 'bash', RECONCILE, '--activate-mini-runs', '--dump-config') { true }
  assert(!status.success? && stderr.include?('Unknown option'), 'reconcile must reject legacy activation')
end

tests << lambda do
  sync_source = File.read(SYNC)
  reconcile_source = File.read(RECONCILE)
  start_workday_source = File.read(START_WORKDAY)
  (FORBIDDEN_AUTOMATION_PATHS + %w[saneops-am-run saneops-pm-run sqlite3]).each do |token|
    assert(!sync_source.include?(token), "control-plane sync still references forbidden automation store token #{token}")
  end
  assert(!reconcile_source.include?('activate-mini-runs'), 'reconcile still exposes automation activation')
  assert(!reconcile_source.include?('pause-mini-'), 'reconcile still exposes automation pause mutation')
  (FORBIDDEN_AUTOMATION_PATHS + ['activate-mini-runs', 'pause-mini-']).each do |token|
    assert(!start_workday_source.include?(token), "start-workday still references automation store token #{token}")
  end
  assert(!reconcile_source.include?('--reconcile-dirty'),
         'unattended Air/Mini reconcile must not auto-stash dirty app repos')
  air_memory = File.read(File.join(ROOT, 'automation', 'agentmemory-mcp-air.sh'))
  assert(air_memory.include?('ConnectTimeout=3'), 'Air AgentMemory tunnel must fail quickly')
  assert(air_memory.include?('127.0.0.1:3111'), 'Air AgentMemory tunnel target drifted')
  assert(air_memory.include?('ServerAliveInterval=15'), 'Air AgentMemory tunnel must detect dead connections')
  assert(air_memory.include?('ServerAliveCountMax=3'), 'Air AgentMemory tunnel retry bound drifted')
  assert(air_memory.include?('kickstart "gui/'), 'Air MCP clients must kickstart the single tunnel owner')
  assert(!air_memory.include?('kickstart -k'), 'Air MCP clients must not kill a tunnel owned by another client')
  assert(!air_memory.include?('ssh -f'), 'Air MCP shim must not create detached per-client tunnels')
end

tests << lambda do
  Dir.mktmpdir('control-plane-loopback-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)

    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log,
      'SANE_LOCAL_HOST_OVERRIDE' => 'fixture-mini',
      'SANE_REMOTE_HOST_OVERRIDE' => 'fixture-mini'
    }

    _stdout, stderr, status = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart') { true }
    assert(!status.success? && stderr.include?('Refusing Mini control-plane loopback'),
           'Mini loopback must fail closed')
    %w[curl open rsync security ssh swift xcodebuild].each do |command|
      wrapper = File.join(home, '.local', 'bin', command)
      assert(!File.exist?(wrapper) && !File.symlink?(wrapper),
             "loopback refusal mutated local wrapper: #{wrapper}")
    end
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-lock-contention-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log
    }

    local_lock = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'locks',
                           'control-plane-sync.lock')
    FileUtils.mkdir_p(local_lock)
    remote_before = manifest_snapshot(remote_home)
    _out, err, status = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart') { true }
    assert(!status.success? && err.include?('Local control-plane sync lock is held'),
           "local lock contention did not fail closed:\n#{err}")
    assert(Dir.exist?(local_lock), 'contended local lock was removed by the losing process')
    assert_manifest_snapshot(remote_home, remote_before, 'local-lock refusal')
    FileUtils.rm_r(local_lock)

    remote_lock = File.join(remote_home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'locks',
                            'control-plane-sync.lock')
    FileUtils.mkdir_p(remote_lock)
    _out2, err2, status2 = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart') { true }
    assert(!status2.success? && err2.include?('Peer control-plane sync lock is held'),
           "peer lock contention did not fail closed:\n#{err2}")
    assert(Dir.exist?(remote_lock), 'contended peer lock was removed by the losing process')
    assert(!Dir.exist?(local_lock), 'local lock leaked after peer lock contention')
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-concurrent-peer-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    untouched_rel = 'SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh'
    write(File.join(remote_home, untouched_rel), "peer original\n", executable: true)
    untouched_before = sha(File.join(remote_home, untouched_rel))
    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log,
      'MUTATE_PEER_AFTER_STAGE' => '1'
    }

    _out, err, status = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart') { true }
    assert(!status.success? && err.include?('Peer reviewed manifest changed after locked preflight'),
           "post-preflight peer mutation was not detected:\n#{err}")
    mutated = File.join(remote_home, 'SaneApps', 'infra', 'scripts', 'check-inbox.sh')
    assert(File.read(mutated) == "concurrent peer mutation\n", 'concurrent peer change was overwritten')
    assert(sha(File.join(remote_home, untouched_rel)) == untouched_before,
           'a different manifest file was promoted after concurrent mutation')
    assert(!File.exist?(File.join(remote_home, '.codex', 'SKILLS_REGISTRY.md')),
           'user-level control-plane files changed after concurrent mutation refusal')
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-rollback-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    tracked_sync = 'SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh'
    CONTROL_PLANE_REL_FILES.each do |rel|
      next if rel == tracked_sync

      write(File.join(remote_home, rel), "peer original #{rel}\n", executable: rel.end_with?('.sh', '.rb'))
    end
    originals = manifest_snapshot(remote_home)
    remote_config = File.join(remote_home, '.codex', 'config.toml')
    remote_config_before = sha(remote_config)
    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log,
      'SANE_CONTROL_PLANE_FAIL_AFTER_PROMOTIONS' => '5'
    }

    _out, err, status = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart') { true }
    assert(!status.success? && err.include?('Injected control-plane promotion failure after 5 file(s)'),
           "mid-promotion failure was not exercised:\n#{err}")
    assert_manifest_snapshot(remote_home, originals, 'promotion rollback')
    assert(sha(remote_config) == remote_config_before, 'rollback path changed host-managed config')
    assert(!File.exist?(File.join(remote_home, '.codex', 'SKILLS_REGISTRY.md')),
           'rollback path continued into user-level sync')
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-dirty-refusal-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    remote_config = File.join(remote_home, '.codex', 'config.toml')
    remote_config_before = sha(remote_config)
    write(File.join(remote_home, 'SaneApps', 'infra', 'SaneProcess', '.gitignore'), "*\n# dirty peer\n")

    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log
    }
    _stdout, stderr, status = run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart',
                                  '--allow-reviewed-dirty') { true }
    assert(!status.success? && stderr.include?('Peer SaneProcess is dirty'),
           "dirty peer must fail before mutation:\n#{stderr}")
    assert(File.read(log).include?("snapshot\t--snapshot-only"), 'dirty peer snapshot was not captured')
    assert(sha(remote_config) == remote_config_before, 'dirty-peer refusal changed Mini config')
    assert(!File.exist?(File.join(remote_home, '.codex', 'SKILLS_REGISTRY.md')),
           'dirty-peer refusal copied the skill registry')
    assert(!File.symlink?(File.join(home, '.local', 'bin', 'curl')),
           'dirty-peer refusal installed a local guard wrapper')
    assert(!Dir.glob(File.join(remote_home, 'SaneApps', 'infra', 'SaneProcess', 'outputs',
                              'control-plane-preimages', '*', 'hashes.txt')).empty?,
           'dirty-peer refusal did not preserve a remote preimage receipt')
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-reviewed-dirty-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    sync_rel = 'SaneApps/infra/SaneProcess/scripts/automation/sync-codex-mini.sh'
    local_sync = File.join(home, sync_rel)
    remote_sync = File.join(remote_home, sync_rel)
    write(local_sync, File.read(local_sync) + "# reviewed manifest change\n", executable: true)

    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log
    }
    run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart', '--allow-reviewed-dirty')
    assert(sha(local_sync) == sha(remote_sync), 'reviewed manifest-only source change did not sync')
    assert(File.read(log).include?("snapshot\t--snapshot-only"),
           'reviewed dirty source was not snapshotted before sync')
  end
end

tests << lambda do
  Dir.mktmpdir('control-plane-sync-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'operations.log')
    FileUtils.mkdir_p([home, remote_home, bin_dir])
    create_sync_fixture(home, remote_home)
    fake_transport!(bin_dir)
    sentinels = protect_automation_stores(home, remote_home)

    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'SYNC_OP_LOG' => log
    }

    local_config_path = File.join(home, '.codex', 'config.toml')
    remote_config_path = File.join(remote_home, '.codex', 'config.toml')
    local_config_before = sha(local_config_path)
    remote_config_before = sha(remote_config_path)

    begin
      run(env, 'bash', SYNC, 'mini', '--quiet', '--no-restart')
    ensure
      restore_automation_store_permissions(home, remote_home, sentinels)
    end

    operations = File.read(log)
    FORBIDDEN_AUTOMATION_PATHS.each do |token|
      assert(!operations.include?(token), "transport touched forbidden automation path #{token}:\n#{operations}")
    end
    sentinels.each { |path, before| assert(sha(path) == before, "automation sentinel changed: #{path}") }

    assert(sha(local_config_path) == local_config_before, 'local host-managed Codex config changed')
    assert(sha(remote_config_path) == remote_config_before, 'Mini host-managed Codex config changed')
    assert(File.file?(File.join(remote_home, '.codex', 'skills', 'fixture', 'SKILL.md')),
           'Codex skill did not sync')
    assert(File.file?(File.join(remote_home, '.agents', 'skills', 'shared', 'SKILL.md')),
           'shared agent skill did not sync')
    assert(File.file?(File.join(remote_home, '.codex', 'skills', 'mini-only', 'SKILL.md')),
           'Mini-only Codex skill was deleted')
    assert(File.file?(File.join(remote_home, '.agents', 'skills', 'mini-only', 'SKILL.md')),
           'Mini-only shared skill was deleted')
    assert(!operations.include?('--delete'), "skills sync must be non-destructive:\n#{operations}")
    assert(!Dir.glob(File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs',
                              'control-plane-preimages', '*', 'hashes.txt')).empty?,
           'local preimage receipt missing')
    assert(!Dir.glob(File.join(remote_home, 'SaneApps', 'infra', 'SaneProcess', 'outputs',
                              'control-plane-preimages', '*', 'hashes.txt')).empty?,
           'remote preimage receipt missing')
    CODEX_BIN_FILES.each do |name|
      assert(File.file?(File.join(remote_home, '.codex', 'bin', name)), "Codex helper did not sync: #{name}")
    end
    CONTROL_PLANE_REL_FILES.each do |rel|
      local = File.join(home, rel)
      remote = File.join(remote_home, rel)
      assert(File.file?(remote) && sha(local) == sha(remote), "control-plane file parity failed: #{rel}")
    end
    {
      'curl' => 'sane_curl_guard.sh',
      'open' => 'sane_open_guard.sh',
      'rsync' => 'sane_rsync_guard.sh',
      'security' => 'sane_security_guard.sh',
      'ssh' => 'sane_ssh_guard.sh',
      'swift' => 'swift',
      'xcodebuild' => 'xcodebuild'
    }.each do |command, target|
      [home, remote_home].each do |root|
        wrapper = File.join(root, '.local', 'bin', command)
        assert(File.symlink?(wrapper), "guard wrapper missing: #{wrapper}")
        assert(File.basename(File.readlink(wrapper)) == target, "guard wrapper target mismatch: #{wrapper}")
      end
    end
  end
end

tests << lambda do
  Dir.mktmpdir('reconcile-test') do |tmp|
    home = File.join(tmp, 'home')
    remote_home = File.join(tmp, 'remote')
    bin_dir = File.join(tmp, 'bin')
    log = File.join(tmp, 'reconcile.log')
    automation_dir = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'scripts', 'automation')
    FileUtils.mkdir_p([automation_dir, remote_home, bin_dir])
    FileUtils.cp(RECONCILE, File.join(automation_dir, 'reconcile-air-mini.sh'))

    write(File.join(automation_dir, 'sync-codex-mini.sh'), <<~'BASH', executable: true)
      #!/bin/bash
      printf 'sync\t%s\n' "$*" >> "$RECONCILE_LOG"
    BASH
    write(File.join(automation_dir, 'git-sync-safe.sh'), <<~'BASH', executable: true)
      #!/bin/bash
      printf 'git\t%s\n' "$*" >> "$RECONCILE_LOG"
    BASH
    write(File.join(bin_dir, 'ssh'), <<~'BASH', executable: true)
      #!/bin/bash
      set -euo pipefail
      while [[ "${1:-}" == -* ]]; do
        case "$1" in -o|-F|-i|-J|-l|-p) shift 2 ;; *) shift ;; esac
      done
      shift
      command="$*"
      if [[ "$command" == *'printf %s "$HOME"'* ]]; then
        printf '%s' "$REMOTE_HOME"
      else
        printf 'remote\t%s\n' "$command" >> "$RECONCILE_LOG"
      fi
    BASH

    env = {
      'HOME' => home,
      'PATH' => "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote_home,
      'RECONCILE_LOG' => log
    }
    run(env, 'bash', File.join(automation_dir, 'reconcile-air-mini.sh'), 'mini', '--quiet', '--sync-control-plane')
    lines = File.readlines(log, chomp: true)
    assert(lines.count { |line| line.start_with?("sync\t") } == 1, "expected one control-plane sync: #{lines}")
    assert(lines.include?("sync\tmini --quiet --no-restart"), "unsafe sync args: #{lines}")
    remote_snapshots = lines.each_index.select do |index|
      lines[index].start_with?("remote\tbash ") && lines[index].include?('--snapshot-only')
    end
    assert(remote_snapshots.length == 1, "expected one remote pre-mutation snapshot: #{lines}")
    assert(lines.include?("git\t--snapshot-only"), "local pre-mutation snapshot missing: #{lines}")
    assert(lines.any? { |line| line.start_with?("remote\tbash ") && !line.include?('--snapshot-only') },
           "remote git reconcile missing: #{lines}")
    assert(lines.include?("git\t--peer mini"), "local peer reconcile missing: #{lines}")
    sync_index = lines.index("sync\tmini --quiet --no-restart")
    local_reconcile_index = lines.index("git\t--peer mini")
    assert(sync_index && local_reconcile_index && sync_index > local_reconcile_index,
           "control-plane sync ran before Git reconciliation: #{lines}")
    FORBIDDEN_AUTOMATION_PATHS.each do |token|
      assert(lines.none? { |line| line.include?(token) }, "reconcile touched #{token}: #{lines}")
    end
    assert(File.read(START_WORKDAY).include?('"$MINI_HOST" --no-restart'),
           'start-workday must never interrupt an active Mini Codex process')
  end
end

tests << lambda do
  git_sync_path = File.join(ROOT, 'automation', 'git-sync-safe.sh')
  git_sync_source = File.read(git_sync_path)
  run({}, '/bin/bash', '-n', git_sync_path)
  assert(git_sync_source.include?('SANEPROCESS_ALLOW_AUTO_STASH'),
         'legacy auto-stash path must require explicit operator opt-in')
  assert(git_sync_source.include?('no longer auto-stashes canonical repos by default'),
         'auto-stash refusal should explain why it stopped')
  assert(git_sync_source.include?('--snapshot-only'), 'non-clobbering dirty-work snapshot lane missing')
  assert(git_sync_source.include?('without fetch'), 'snapshot-only contract must forbid repo mutation')
end

tests << lambda do
  wrapper_path = File.join(ROOT, 'codex-bin', 'xcode-mcpbridge-wrapper.sh')
  run({}, '/bin/bash', '-n', wrapper_path)
  Dir.mktmpdir('xcode-wrapper-sandbox-test') do |tmp|
    home = File.join(tmp, 'home')
    bin = File.join(tmp, 'bin')
    FileUtils.mkdir_p(File.join(home, '.codex'))
    write(File.join(home, '.codex', 'xcode-mcp-session-id'), "9ae70354-c553-46a8-b0ce-ac556609b07c\n")
    write(File.join(bin, 'pgrep'), "#!/bin/bash\nexit 1\n", executable: true)
    write(File.join(bin, 'launchctl'), <<~'BASH', executable: true)
      #!/bin/bash
      printf '  4242  -  application.com.apple.dt.Xcode.fixture\n'
    BASH
    write(File.join(bin, 'xcrun'), <<~'BASH', executable: true)
      #!/bin/bash
      printf 'pid=%s session=%s command=%s\n' "$MCP_XCODE_PID" "$MCP_XCODE_SESSION_ID" "$*"
    BASH

    output = run({ 'HOME' => home, 'PATH' => "#{bin}:/usr/bin:/bin" }, '/bin/bash', wrapper_path)
    assert(output.include?('pid=4242'), 'Xcode MCP wrapper did not use launchd when pgrep was sandboxed')
    assert(output.include?('command=mcpbridge'), 'Xcode MCP wrapper did not start the canonical bridge')
  end
end

tests << lambda do
  Dir.mktmpdir('dirty-snapshot-test') do |tmp|
    home = File.join(tmp, 'home')
    repo = File.join(home, 'SaneApps', 'apps', 'FixtureApp')
    bare = File.join(tmp, 'origin.git')
    FileUtils.mkdir_p(repo)
    run({}, 'git', 'init', '--bare', bare)
    run({}, 'git', '-C', repo, 'init', '-b', 'main')
    run({}, 'git', '-C', repo, 'config', 'user.email', 'fixture@example.com')
    run({}, 'git', '-C', repo, 'config', 'user.name', 'Fixture')
    write(File.join(repo, 'tracked.txt'), "clean\n")
    write(File.join(repo, 'retired-secret.txt'), "sk_live_fixture_should_never_enter_snapshot_123456789\n")
    run({}, 'git', '-C', repo, 'add', 'tracked.txt')
    run({}, 'git', '-C', repo, 'add', 'retired-secret.txt')
    run({}, 'git', '-C', repo, 'commit', '-m', 'fixture')
    run({}, 'git', '-C', repo, 'remote', 'add', 'origin', bare)
    run({}, 'git', '-C', repo, 'push', '-u', 'origin', 'main')
    write(File.join(repo, 'tracked.txt'), "dirty\n")
    FileUtils.rm(File.join(repo, 'retired-secret.txt'))
    write(File.join(repo, 'untracked.txt'), "untracked\n")
    write(File.join(repo, 'recovery.orig'), "must survive\n")
    write(File.join(repo, '.DS_Store'), "must survive too\n")

    _stdout, _stderr, status = run({ 'HOME' => home }, 'bash', File.join(ROOT, 'automation', 'git-sync-safe.sh'), '--snapshot-only') { true }
    assert(
      status.success?,
      "snapshot-only must preserve work without turning dirty state into a mutation failure\n" \
      "STDOUT:\n#{_stdout}\nSTDERR:\n#{_stderr}"
    )
    snapshot_root = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'dirty-work-snapshots', 'FixtureApp')
    latest = File.readlines(File.join(snapshot_root, 'latest.txt'), chomp: true)
    snapshot = latest[1]
    tracked_archive = File.join(snapshot, 'tracked-current-files.tar.gz')
    assert(File.file?(tracked_archive), 'current tracked-file archive missing')
    archive_listing = run({}, '/usr/bin/tar', '-tzf', tracked_archive)
    assert(archive_listing.lines.map(&:chomp).include?('tracked.txt'),
           'current tracked-file archive did not preserve the dirty file')
    deleted_manifest = File.binread(File.join(snapshot, 'deleted-files.zlist')).split("\0")
    assert(deleted_manifest.include?('retired-secret.txt'), 'snapshot must retain the tracked deletion')
    snapshot_bytes = Dir.glob(File.join(snapshot, '*')).select { |path| File.file?(path) }.map { |path| File.binread(path) }.join
    assert(!snapshot_bytes.include?('sk_live_fixture_should_never_enter_snapshot'),
           'snapshot must not copy the preimage of a deleted secret-bearing file')
    assert(!File.exist?(File.join(snapshot, 'worktree.patch')), 'snapshot must not retain removed-line preimages')
    assert(File.file?(File.join(snapshot, 'untracked-files.tar.gz')), 'untracked archive missing')
    assert(File.read(File.join(snapshot, 'status.txt')).include?('tracked.txt'), 'status receipt missing dirty file')
    assert(File.read(File.join(repo, 'recovery.orig')) == "must survive\n", 'snapshot-only deleted recovery residue')
    assert(File.read(File.join(repo, '.DS_Store')) == "must survive too\n", 'snapshot-only mutated Finder residue')

    # A nested repo or worktree is reported by `git ls-files --others` as a single
    # directory entry, which shasum cannot hash. It must still register in the
    # dirty fingerprint instead of being dropped with a hashing error.
    fingerprint_before = File.readlines(File.join(snapshot_root, 'latest.txt'), chomp: true).first
    nested = File.join(repo, 'nested-evidence')
    FileUtils.mkdir_p(nested)
    run({}, 'git', 'init', '-b', 'main', nested)
    write(File.join(nested, 'evidence.txt'), "nested\n")
    _nested_stdout, nested_stderr, nested_status = run({ 'HOME' => home }, 'bash', File.join(ROOT, 'automation', 'git-sync-safe.sh'), '--snapshot-only') { true }
    assert(nested_status.success?,
           "snapshot-only must survive a nested repo\nSTDERR:\n#{nested_stderr}")
    assert(!nested_stderr.include?('Is a directory'),
           "nested repo must not be handed to shasum as a directory\nSTDERR:\n#{nested_stderr}")
    fingerprint_after = File.readlines(File.join(snapshot_root, 'latest.txt'), chomp: true).first
    assert(fingerprint_before != fingerprint_after,
           'an untracked nested repo must change the dirty fingerprint, not vanish from it')

    # Dirty-work protection must follow the layout in meta/PROJECT_MAP.md. Products
    # live in websites/ too, and their uncommitted work was going unsnapshotted.
    site = File.join(home, 'SaneApps', 'websites', 'FixtureSite')
    site_origin = File.join(tmp, 'site-origin.git')
    FileUtils.mkdir_p(site)
    run({}, 'git', 'init', '--bare', site_origin)
    run({}, 'git', '-C', site, 'init', '-b', 'main')
    run({}, 'git', '-C', site, 'config', 'user.email', 'fixture@example.com')
    run({}, 'git', '-C', site, 'config', 'user.name', 'Fixture')
    write(File.join(site, 'index.html'), "<h1>clean</h1>\n")
    run({}, 'git', '-C', site, 'add', 'index.html')
    run({}, 'git', '-C', site, 'commit', '-m', 'site fixture')
    run({}, 'git', '-C', site, 'remote', 'add', 'origin', site_origin)
    run({}, 'git', '-C', site, 'push', '-u', 'origin', 'main')
    write(File.join(site, 'index.html'), "<h1>uncommitted work</h1>\n")

    _site_stdout, site_stderr, site_status = run({ 'HOME' => home }, 'bash', File.join(ROOT, 'automation', 'git-sync-safe.sh'), '--snapshot-only') { true }
    assert(site_status.success?, "snapshot-only failed with a websites/ repo\nSTDERR:\n#{site_stderr}")
    site_snapshot_root = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'dirty-work-snapshots', 'FixtureSite')
    assert(File.directory?(site_snapshot_root),
           'a dirty websites/ repo must get dirty-work snapshot protection')

    # The mutating lane auto-pushes clean main commits. websites/* are Cloudflare
    # Pages sites that publish on push, so they must stay out of it: broader
    # snapshot coverage must never turn the daily reconcile into a deploy.
    run({}, 'git', '-C', site, 'checkout', '--', 'index.html')
    full_log = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'git_sync_safe.log')
    File.write(full_log, '') if File.exist?(full_log) # the log appends across runs
    full_stdout, full_stderr, _full_status = run({ 'HOME' => home }, 'bash', File.join(ROOT, 'automation', 'git-sync-safe.sh')) { true }
    processed = File.exist?(full_log) ? File.read(full_log) : "#{full_stdout}\n#{full_stderr}"
    assert(processed.include?('FixtureApp'),
           "mutating lane must still cover apps/\n#{processed}")
    assert(!processed.include?('FixtureSite'),
           "mutating lane must not touch websites/ (publishes on push)\n#{processed}")
  end
end

tests.each(&:call)
puts "PASS #{tests.length}/#{tests.length}"
