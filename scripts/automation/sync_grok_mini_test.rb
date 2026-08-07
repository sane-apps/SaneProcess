#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

SYNC = File.expand_path('sync-grok-mini.sh', __dir__)

def write(path, content, executable: false)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content)
  FileUtils.chmod(0o755, path) if executable
end

def fixture
  Dir.mktmpdir('grok-sync') do |dir|
    home = File.join(dir, 'home')
    remote = File.join(dir, 'remote')
    bin = File.join(dir, 'bin')
    log = File.join(dir, 'calls.log')
    count = File.join(dir, 'rsync-count')
    repo = File.join(home, 'SaneApps', 'infra', 'SaneProcess')
    grok_bin = File.join(repo, 'scripts', 'grok-bin')
    shared = File.join(repo, 'scripts', 'automation', 'sync-codex-mini.sh')
    FileUtils.mkdir_p([grok_bin, bin, File.join(remote, '.agents', 'skills', 'peer-only')])
    write(File.join(grok_bin, 'check-mcps'), "canonical helper\n", executable: true)
    write(File.join(home, '.grok', 'bin', 'local-only'), "keep local\n")
    write(File.join(remote, '.grok', 'bin', 'peer-only'), "keep peer\n")
    write(File.join(remote, '.agents', 'skills', 'peer-only', 'SKILL.md'), "keep skill\n")
    write(shared, <<~'SH', executable: true)
      #!/bin/bash
      printf 'shared %s\n' "$*" >> "$CALL_LOG"
      if [ -f "$REMOTE_HOME/.dirty-peer" ]; then
        echo 'Peer SaneProcess is dirty' >&2
        exit 42
      fi
    SH
    write(File.join(bin, 'ssh'), <<~'SH', executable: true)
      #!/bin/bash
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o) shift 2 ;;
          *) host="$1"; shift; break ;;
        esac
      done
      command="${1:-}"
      if [ "$command" = 'printf %s "$HOME"' ]; then
        printf '%s' "$REMOTE_HOME"
        exit 0
      fi
      HOME="$REMOTE_HOME" /bin/bash -c "$command"
    SH
    write(File.join(bin, 'rsync'), <<~'SH', executable: true)
      #!/bin/bash
      count=0
      [ ! -f "$RSYNC_COUNT" ] || count=$(cat "$RSYNC_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$RSYNC_COUNT"
      dry=0
      source=""
      destination=""
      for arg in "$@"; do
        case "$arg" in
          --dry-run) dry=1 ;;
          -*) ;;
          *)
            if [ -z "$source" ]; then
              source="$arg"
            else
              destination="$arg"
            fi
            ;;
        esac
      done
      destination="${destination#*:}"
      mkdir -p "$destination"
      if [ "${FAIL_RSYNC_AT:-0}" = "$count" ]; then
        first=$(find "$source" -type f | head -1)
        [ -z "$first" ] || cp "$first" "$destination/partial-copy"
        exit 23
      fi
      [ "$dry" -eq 1 ] && exit 0
      cp -Rp "$source/." "$destination/"
    SH

    env = {
      'HOME' => home,
      'PATH' => "#{bin}:/usr/bin:/bin:/usr/sbin:/sbin",
      'REMOTE_HOME' => remote,
      'CALL_LOG' => log,
      'RSYNC_COUNT' => count,
      'SANE_GROK_SHARED_SYNC' => shared,
      'SANE_GROK_SSH_BIN' => File.join(bin, 'ssh'),
      'SANE_GROK_RSYNC_BIN' => File.join(bin, 'rsync')
    }
    yield(dir, home, remote, env, log)
  end
end

def run_sync(env)
  Open3.capture3(env, '/bin/bash', SYNC, 'fixture-mini', '--quiet')
end

exit(run_tests('Grok Control-Plane Sync Tests') do
  test('dirty peer refusal stops before Grok helper staging or promotion') do
    fixture do |_dir, home, remote, env, _log|
      write(File.join(remote, '.dirty-peer'), "dirty\n")
      local_before = File.read(File.join(home, '.grok', 'bin', 'local-only'))
      remote_before = File.read(File.join(remote, '.grok', 'bin', 'peer-only'))
      _out, err, status = run_sync(env)
      assert(!status.success?, 'dirty peer unexpectedly succeeded')
      assert_includes(err, 'Canonical control-plane sync refused or failed')
      assert(File.read(File.join(home, '.grok', 'bin', 'local-only')) == local_before)
      assert(File.read(File.join(remote, '.grok', 'bin', 'peer-only')) == remote_before)
      assert(Dir.glob(File.join(remote, '.grok', '.bin-stage-*')).empty?, 'dirty refusal created a peer stage')
      true
    end
  end

  test('successful overlay preserves peer-only skills and helpers') do
    fixture do |_dir, home, remote, env, log|
      out, err, status = run_sync(env)
      assert(status.success?, "#{out}\n#{err}")
      assert(File.file?(File.join(remote, '.agents', 'skills', 'peer-only', 'SKILL.md')))
      assert(File.read(File.join(remote, '.grok', 'bin', 'peer-only')) == "keep peer\n")
      assert(File.read(File.join(remote, '.grok', 'bin', 'check-mcps')) == "canonical helper\n")
      assert(File.read(File.join(home, '.grok', 'bin', 'local-only')) == "keep local\n")
      assert_includes(File.read(log), 'shared fixture-mini --no-restart --quiet')
      true
    end
  end

  test('partial staged copy failure leaves both live helper directories unchanged') do
    fixture do |_dir, home, remote, env, _log|
      env['FAIL_RSYNC_AT'] = '2'
      local_files_before = Dir.glob(File.join(home, '.grok', 'bin', '*')).to_h { |path| [File.basename(path), File.read(path)] }
      remote_files_before = Dir.glob(File.join(remote, '.grok', 'bin', '*')).to_h { |path| [File.basename(path), File.read(path)] }
      _out, err, status = run_sync(env)
      assert(!status.success?, 'partial peer copy unexpectedly succeeded')
      assert_includes(err, 'live helper directories are unchanged')
      local_files_after = Dir.glob(File.join(home, '.grok', 'bin', '*')).to_h { |path| [File.basename(path), File.read(path)] }
      remote_files_after = Dir.glob(File.join(remote, '.grok', 'bin', '*')).to_h { |path| [File.basename(path), File.read(path)] }
      assert(local_files_after == local_files_before, 'partial copy changed local live helpers')
      assert(remote_files_after == remote_files_before, 'partial copy changed peer live helpers')
      true
    end
  end

  test('source contains no destructive skill sync or swallowed remote copy failure') do
    source = File.read(SYNC)
    assert(!source.include?('--delete'), 'Grok sync still contains --delete')
    assert(!source.match?(/rsync[^\n]*\|\|\s*(?:true|log)/), 'Grok rsync failure is still swallowed')
    assert_includes(source, 'sync-codex-mini.sh')
    true
  end
end)
