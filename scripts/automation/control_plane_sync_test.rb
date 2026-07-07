#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'

ROOT = File.expand_path('..', __dir__)
SYNC = File.join(ROOT, 'automation', 'sync-codex-mini.sh')
RECONCILE = File.join(ROOT, 'automation', 'reconcile-air-mini.sh')

def assert(condition, message)
  raise message unless condition
end

def run(*command)
  stdout, stderr, status = Open3.capture3(*command)
  raise "command failed: #{command.join(' ')}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}" unless status.success?

  stdout
end

def parse_dump(text)
  text.lines.map do |line|
    next unless line.include?('=')

    key, value = line.strip.split('=', 2)
    [key, value]
  end.compact.to_h
end

tests = []

tests << lambda do
  dump = parse_dump(run('bash', SYNC, '--dump-config'))
  assert(dump['REMOTE_AM_STATUS'] == 'PAUSED', 'sync default should keep Mini AM paused')
  assert(dump['REMOTE_PM_STATUS'] == 'PAUSED', 'sync default should keep Mini PM paused')
end

tests << lambda do
  dump = parse_dump(run('bash', SYNC, 'mini', '--activate-mini-runs', '--dump-config'))
  assert(dump['REMOTE_AM_STATUS'] == 'ACTIVE', 'sync activate flag should enable Mini AM')
  assert(dump['REMOTE_PM_STATUS'] == 'ACTIVE', 'sync activate flag should enable Mini PM')
end

tests << lambda do
  dump = parse_dump(run('bash', RECONCILE, '--dump-config'))
  assert(dump['ACTIVATE_MINI_RUNS'] == '0', 'reconcile default should not activate Mini runs')
end

tests << lambda do
  dump = parse_dump(run('bash', RECONCILE, 'mini', '--activate-mini-runs', '--dump-config'))
  assert(dump['ACTIVATE_MINI_RUNS'] == '1', 'reconcile activate flag should opt into Mini runs')
end

tests << lambda do
  reconcile_source = File.read(RECONCILE)
  assert(!reconcile_source.include?('--reconcile-dirty'),
         'unattended Air/Mini reconcile must not auto-stash dirty app repos')
end

tests << lambda do
  git_sync_source = File.read(File.join(ROOT, 'automation', 'git-sync-safe.sh'))
  assert(git_sync_source.include?('SANEPROCESS_ALLOW_AUTO_STASH'),
         'legacy auto-stash path must require explicit operator opt-in')
  assert(git_sync_source.include?('no longer auto-stashes canonical repos by default'),
         'auto-stash refusal should explain why it stopped')
end

tests << lambda do
  sync_source = File.read(SYNC)
  assert(sync_source.include?('LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"'),
         'Mini control-plane sync should include shared .agents skills')
  assert(sync_source.include?('Shared agent skills parity check failed'),
         'Mini control-plane sync should verify shared .agents skill parity')
end

tests.each(&:call)
puts "PASS #{tests.length}/#{tests.length}"
