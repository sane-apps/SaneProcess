#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative 'test/test_framework'

include TestFramework

HOOK_DIR = File.expand_path(__dir__)

def run_guard(script, payload)
  Open3.capture3(
    'ruby',
    File.join(HOOK_DIR, script),
    stdin_data: JSON.generate(payload),
    chdir: File.expand_path('../..', __dir__)
  )
end

def push_payload(command)
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => command }
  }
end

GIT_IDENTITY = ['-c', 'user.name=Sane Test', '-c', 'user.email=test@saneapps.com'].freeze

def git_run(*args, dir: nil)
  argv = ['git']
  argv += ['-C', dir] if dir
  argv += GIT_IDENTITY + args
  out, status = Open3.capture2e(*argv)
  raise "git failed: #{argv.join(' ')}\n#{out}" unless status.success?

  out
end

# Builds an offline push scenario: a bare "origin", a rival clone that
# advances it, and an agent clone left behind. All file-local, no network.
# Yields [agent_dir, origin_dir].
def with_behind_push
  Dir.mktmpdir('push-guard-origin') do |origin_parent|
    origin_dir = File.join(origin_parent, 'origin.git')
    git_run('init', '--bare', '-b', 'main', origin_dir)
    Dir.mktmpdir('push-guard-rival') do |rival_parent|
      rival_dir = File.join(rival_parent, 'rival')
      git_run('clone', origin_dir, rival_dir)
      File.write(File.join(rival_dir, 'remote.txt'), "remote\n")
      git_run('add', 'remote.txt', dir: rival_dir)
      git_run('commit', '-m', 'remote advance', dir: rival_dir)
      git_run('push', 'origin', 'main', dir: rival_dir)
      Dir.mktmpdir('push-guard-agent') do |agent_parent|
        agent_dir = File.join(agent_parent, 'agent')
        git_run('clone', origin_dir, agent_dir)
        # Agent's clone predates nothing here — rewind it behind origin by
        # adding a second remote commit after the clone.
        File.write(File.join(rival_dir, 'remote2.txt'), "remote2\n")
        git_run('add', 'remote2.txt', dir: rival_dir)
        git_run('commit', '-m', 'remote advance 2', dir: rival_dir)
        git_run('push', 'origin', 'main', dir: rival_dir)
        yield agent_dir, origin_dir
      end
    end
  end
end

def with_current_push
  Dir.mktmpdir('push-guard-origin') do |origin_parent|
    origin_dir = File.join(origin_parent, 'origin.git')
    git_run('init', '--bare', '-b', 'main', origin_dir)
    Dir.mktmpdir('push-guard-agent') do |agent_parent|
      agent_dir = File.join(agent_parent, 'agent')
      git_run('clone', origin_dir, agent_dir)
      File.write(File.join(agent_dir, 'work.txt'), "work\n")
      git_run('add', 'work.txt', dir: agent_dir)
      git_run('commit', '-m', 'agent work', dir: agent_dir)
      # Establish the upstream at the same tip, so the guard passes because
      # the branch is current — not because no upstream exists.
      git_run('push', '-u', 'origin', 'main', dir: agent_dir)
      yield agent_dir, origin_dir
    end
  end
end

exit(run_tests('Sane Push Guard Tests') do
  test('blocks a push that is behind its upstream') do
    with_behind_push do |agent_dir, _origin|
      _out, err, status = run_guard(
        'sane_push_guard.rb',
        push_payload("git -C #{agent_dir} push origin main")
      )
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'behind')
      assert_includes(err, 'pull --rebase')
      true
    end
  end

  test('allows a push that is up to date with upstream') do
    with_current_push do |agent_dir, _origin|
      _out, _err, status = run_guard(
        'sane_push_guard.rb',
        push_payload("git -C #{agent_dir} push origin main")
      )
      assert_eq(status.exitstatus, 0)
      true
    end
  end

  test('ignores non-push commands') do
    _out, _err, status = run_guard(
      'sane_push_guard.rb',
      push_payload('git -C /tmp status --short')
    )
    assert_eq(status.exitstatus, 0)
    true
  end

  test('defers force pushes to the catastrophic guard') do
    with_behind_push do |agent_dir, _origin|
      _out, _err, status = run_guard(
        'sane_push_guard.rb',
        push_payload("git -C #{agent_dir} push --force origin main")
      )
      assert_eq(status.exitstatus, 0)
      true
    end
  end

  test('fails open when the remote is unreachable') do
    Dir.mktmpdir('push-guard-dead') do |dir|
      git_run('init', '-b', 'main', dir)
      git_run('remote', 'add', 'origin', File.join(dir, 'missing.git'), dir: dir)
      File.write(File.join(dir, 'f.txt'), "f\n")
      git_run('add', 'f.txt', dir: dir)
      git_run('commit', '-m', 'init', dir: dir)
      _out, _err, status = run_guard(
        'sane_push_guard.rb',
        push_payload("git -C #{dir} push origin main")
      )
      assert_eq(status.exitstatus, 0)
      true
    end
  end

  test('fails open for a bare push with no resolvable repo') do
    _out, _err, status = run_guard(
      'sane_push_guard.rb',
      push_payload('git push origin main')
    )
    assert_eq(status.exitstatus, 0)
    true
  end
end)
