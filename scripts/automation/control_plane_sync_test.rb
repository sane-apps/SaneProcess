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

tests.each(&:call)
puts "PASS #{tests.length}/#{tests.length}"
