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

CONTROL_PLANE_REL_FILES = %w[
  SaneApps/infra/scripts/check-inbox.sh
  SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh
  SaneApps/infra/SaneProcess/scripts/automation/reconcile-air-mini.sh
  SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh
  SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh
  SaneApps/infra/SaneProcess/scripts/mini/mini-reclaim-automation-windows.sh
  SaneApps/infra/SaneProcess/scripts/mini/mini-nightly.sh
  SaneApps/infra/SaneProcess/scripts/mini/mini-prepare-automation-root.sh
  SaneApps/infra/SaneProcess/scripts/validation_report.rb
  SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb
  SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb
  SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb
].freeze

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
      *'command -v node'*) printf '%s\n' "$REMOTE_NODE" ;;
      *'MIN_CODEX_CLI_VERSION='*'bash -s'*) cat >/dev/null ;;
      *'/.local/bin/codex" --version'*) printf 'codex-cli 0.139.0\n' ;;
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
  write(File.join(home, '.codex', 'SKILLS_REGISTRY.md'), "fixture registry\n")
  write(File.join(home, '.codex', 'skills', 'fixture', 'SKILL.md'), "fixture skill\n")
  write(File.join(home, '.agents', 'skills', 'shared', 'SKILL.md'), "shared skill\n")

  CODEX_BIN_FILES.each do |name|
    write(File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'scripts', 'codex-bin', name),
          "#!/bin/bash\necho #{name}\n", executable: true)
  end
  CONTROL_PLANE_REL_FILES.each do |rel|
    write(File.join(home, rel), "fixture #{rel}\n", executable: rel.end_with?('.sh', '.rb'))
  end

  cli = "#!/bin/bash\necho 'codex-cli 0.139.0'\n"
  write(File.join(home, '.codex', 'packages', 'standalone', 'current', 'codex'), cli, executable: true)
  write(File.join(home, '.local', 'bin', 'codex'), cli, executable: true)
  write(File.join(remote_home, '.local', 'bin', 'codex'), cli, executable: true)
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
  assert(dump == { 'MINI_HOST' => 'mini', 'QUIET' => '0', 'RESTART_CODEX' => '0' },
         "unexpected sync config: #{dump}")

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
  assert(air_memory.include?('-L 3111:127.0.0.1:3111 mini'), 'Air AgentMemory tunnel target drifted')
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
      'REMOTE_NODE' => '/fixture/bin/node',
      'SYNC_OP_LOG' => log
    }

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

    remote_config = File.read(File.join(remote_home, '.codex', 'config.toml'))
    assert(remote_config.include?('command = "/fixture/bin/node"'), 'Mini config did not rewrite Node path')
    assert(remote_config.include?(remote_home), 'Mini config did not rewrite local home path')
    assert(remote_config.include?('command = "npx"'), 'Mini config did not install direct AgentMemory MCP')
    assert(remote_config.include?('AGENTMEMORY_URL = "http://localhost:3111"'), 'Mini AgentMemory URL missing')
    assert(!remote_config.include?('agentmemory-mcp-air.sh'), 'Air AgentMemory tunnel leaked into Mini config')
    assert(File.file?(File.join(remote_home, '.codex', 'skills', 'fixture', 'SKILL.md')),
           'Codex skill did not sync')
    assert(File.file?(File.join(remote_home, '.agents', 'skills', 'shared', 'SKILL.md')),
           'shared agent skill did not sync')
    CODEX_BIN_FILES.each do |name|
      assert(File.file?(File.join(remote_home, '.codex', 'bin', name)), "Codex helper did not sync: #{name}")
    end
    CONTROL_PLANE_REL_FILES.each do |rel|
      local = File.join(home, rel)
      remote = File.join(remote_home, rel)
      assert(File.file?(remote) && sha(local) == sha(remote), "control-plane file parity failed: #{rel}")
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
    assert(lines.any? { |line| line.start_with?("remote\tbash ") }, "remote git reconcile missing: #{lines}")
    assert(lines.include?("git\t--peer mini"), "local peer reconcile missing: #{lines}")
    FORBIDDEN_AUTOMATION_PATHS.each do |token|
      assert(lines.none? { |line| line.include?(token) }, "reconcile touched #{token}: #{lines}")
    end
    assert(File.read(START_WORKDAY).include?('"$MINI_HOST" --no-restart'),
           'start-workday must never interrupt an active Mini Codex process')
  end
end

tests << lambda do
  git_sync_source = File.read(File.join(ROOT, 'automation', 'git-sync-safe.sh'))
  assert(git_sync_source.include?('SANEPROCESS_ALLOW_AUTO_STASH'),
         'legacy auto-stash path must require explicit operator opt-in')
  assert(git_sync_source.include?('no longer auto-stashes canonical repos by default'),
         'auto-stash refusal should explain why it stopped')
  assert(git_sync_source.include?('--snapshot-only'), 'non-clobbering dirty-work snapshot lane missing')
  assert(git_sync_source.include?('without fetch'), 'snapshot-only contract must forbid repo mutation')
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
    run({}, 'git', '-C', repo, 'add', 'tracked.txt')
    run({}, 'git', '-C', repo, 'commit', '-m', 'fixture')
    run({}, 'git', '-C', repo, 'remote', 'add', 'origin', bare)
    run({}, 'git', '-C', repo, 'push', '-u', 'origin', 'main')
    write(File.join(repo, 'tracked.txt'), "dirty\n")
    write(File.join(repo, 'untracked.txt'), "untracked\n")
    write(File.join(repo, 'recovery.orig'), "must survive\n")
    write(File.join(repo, '.DS_Store'), "must survive too\n")

    _stdout, _stderr, status = run({ 'HOME' => home }, 'bash', File.join(ROOT, 'automation', 'git-sync-safe.sh'), '--snapshot-only') { true }
    assert(status.success?, 'snapshot-only must preserve work without turning dirty state into a mutation failure')
    snapshot_root = File.join(home, 'SaneApps', 'infra', 'SaneProcess', 'outputs', 'dirty-work-snapshots', 'FixtureApp')
    latest = File.readlines(File.join(snapshot_root, 'latest.txt'), chomp: true)
    snapshot = latest[1]
    assert(File.file?(File.join(snapshot, 'worktree.patch')), 'dirty patch missing')
    assert(File.file?(File.join(snapshot, 'untracked-files.tar.gz')), 'untracked archive missing')
    assert(File.read(File.join(snapshot, 'status.txt')).include?('tracked.txt'), 'status receipt missing dirty file')
    assert(File.read(File.join(repo, 'recovery.orig')) == "must survive\n", 'snapshot-only deleted recovery residue')
    assert(File.read(File.join(repo, '.DS_Store')) == "must survive too\n", 'snapshot-only mutated Finder residue')
  end
end

tests.each(&:call)
puts "PASS #{tests.length}/#{tests.length}"
