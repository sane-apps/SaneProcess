#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'test/test_framework'
require_relative 'sane_layout_guard'

include TestFramework

HOOK_DIR = File.expand_path(__dir__)
HOOK = File.join(HOOK_DIR, 'sane_layout_guard.rb')
HOME = Dir.home

def run_guard(payload, env: {})
  Open3.capture3(
    env,
    'ruby',
    HOOK,
    stdin_data: JSON.generate(payload),
    chdir: File.expand_path('../..', __dir__)
  )
end

def write_payload(path)
  {
    'tool_name' => 'Write',
    'tool_input' => { 'file_path' => path, 'content' => 'x' }
  }
end

def bash_payload(command)
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => command }
  }
end

exit(run_tests('Sane Layout Guard Tests') do
  test_category('Write / path checks') do
    test('blocks Write to nested fake Air tree under Mini home') do
      path = "#{HOME}/Users/sj/SaneApps/apps/Foo"
      reason = SaneLayoutGuard.violation_for_path(path)
      assert(reason, 'expected violation')
      assert_includes(reason, 'Users')

      _out, err, status = run_guard(write_payload(path))
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'Project layout violation')
      assert_includes(err, 'SaneApps/<bucket>')
      true
    end

    test('blocks Write to SaneApps/Users nested fake') do
      path = "#{HOME}/SaneApps/Users/sj/apps/Foo"
      reason = SaneLayoutGuard.violation_for_path(path)
      assert(reason, 'expected violation')
      assert_includes(reason, 'SaneApps/Users')

      _out, err, status = run_guard(write_payload(path))
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'layout')
      true
    end

    test('blocks Write to Desktop project dump') do
      path = "#{HOME}/Desktop/SaneClick-E2E.foo"
      reason = SaneLayoutGuard.violation_for_path(path)
      assert(reason, 'expected Desktop violation')
      assert_includes(reason, 'Desktop')

      _out, err, status = run_guard(write_payload(path))
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'Screenshots')
      true
    end

    test('allows Write under SaneApps/apps') do
      path = "#{HOME}/SaneApps/apps/SaneClip/README.md"
      assert_eq(SaneLayoutGuard.violation_for_path(path), nil)

      _out, err, status = run_guard(write_payload(path))
      assert_eq(status.exitstatus, 0)
      assert_eq(err.strip, '')
      true
    end

    test('allows Write under Desktop/Screenshots') do
      path = "#{HOME}/Desktop/Screenshots/proof.png"
      assert_eq(SaneLayoutGuard.violation_for_path(path), nil)

      _out, err, status = run_guard(write_payload(path))
      assert_eq(status.exitstatus, 0)
      assert_eq(err.strip, '')
      true
    end

    test('blocks literal $HOME path segment') do
      reason = SaneLayoutGuard.violation_for_path("#{HOME}/$HOME/SaneApps/apps/Foo")
      assert(reason, 'expected $HOME violation')
      assert_includes(reason, '$HOME')
      true
    end

    test('blocks SaneApps product under Dev') do
      reason = SaneLayoutGuard.violation_for_path("#{HOME}/Dev/SaneClick/README.md")
      assert(reason, 'expected Dev/Sane* violation')
      assert_includes(reason, 'Dev')
      true
    end

    test('allows non-Sane path under Dev') do
      assert_eq(SaneLayoutGuard.violation_for_path("#{HOME}/Dev/apple-docs-mcp/index.js"), nil)
      true
    end
  end

  test_category('Bash mutation checks') do
    test('blocks bash mkdir on Desktop project') do
      cmd = 'mkdir -p ~/Desktop/SaneClick-E2E.xxx'
      reason = SaneLayoutGuard.violation_for_bash(cmd)
      assert(reason, 'expected mkdir Desktop violation')

      _out, err, status = run_guard(bash_payload(cmd))
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'layout')
      assert_includes(err, 'Desktop')
      true
    end

    test('blocks bash mkdir targeting /Users/sj when HOME is stephansmac') do
      skip = HOME.end_with?('/sj')
      if skip
        warn '  (skip /Users/sj Mini check — running as Air user sj)'
        true
      else
        cmd = 'mkdir -p /Users/sj/SaneApps/apps/Foo'
        reason = SaneLayoutGuard.violation_for_bash(cmd)
        assert(reason, 'expected /Users/sj violation on Mini')
        assert_includes(reason, '/Users/sj')

        _out, err, status = run_guard(bash_payload(cmd))
        assert_eq(status.exitstatus, 2)
        assert_includes(err, '/Users/sj')
        true
      end
    end

    test('allows echo/rg that merely mention /Users/sj') do
      assert_eq(SaneLayoutGuard.violation_for_bash('echo never use /Users/sj/ on Mini'), nil)
      assert_eq(SaneLayoutGuard.violation_for_bash('rg -F /Users/sj/SaneApps'), nil)
      true
    end

    test('allows shell $HOME expansion into SaneApps') do
      assert_eq(SaneLayoutGuard.violation_for_bash('mkdir -p $HOME/SaneApps/apps/Foo'), nil)
      assert_eq(SaneLayoutGuard.violation_for_bash('mkdir -p $HOME/Desktop/Screenshots/x'), nil)
      true
    end

    test('allows mkdir under SaneApps/apps') do
      cmd = 'mkdir -p ~/SaneApps/apps/Foo'
      assert_eq(SaneLayoutGuard.violation_for_bash(cmd), nil)

      _out, err, status = run_guard(bash_payload(cmd))
      assert_eq(status.exitstatus, 0)
      assert_eq(err.strip, '')
      true
    end

    test('blocks mkdir of home top-level project') do
      reason = SaneLayoutGuard.violation_for_bash('mkdir -p ~/MyFragmentedApp')
      assert(reason, 'expected home top-level violation')
      assert_includes(reason, 'home top-level')
      true
    end

    test('blocks git clone onto Documents') do
      reason = SaneLayoutGuard.violation_for_bash(
        'git clone https://github.com/example/repo.git ~/Documents/BrokenClone'
      )
      assert(reason, 'expected Documents clone violation')
      assert_includes(reason, 'Documents')
      true
    end

    test('blocks Desktop redirect and curl -o') do
      assert(SaneLayoutGuard.violation_for_bash('echo x > ~/Desktop/evil.txt'), 'redirect')
      assert(SaneLayoutGuard.violation_for_bash('curl -o ~/Desktop/x.zip https://example.com/x.zip'), 'curl')
      assert(SaneLayoutGuard.violation_for_bash('tee ~/Desktop/evil.txt'), 'tee')
      true
    end

    test('blocks cd Desktop && git clone without dest') do
      reason = SaneLayoutGuard.violation_for_bash('cd ~/Desktop && git clone https://github.com/example/bar.git')
      assert(reason, 'expected Desktop clone without dest')
      assert_includes(reason, 'Desktop')
      true
    end

    test('dispatcher runs layout guard before email') do
      _dout, derr, dstatus = Open3.capture3(
        'ruby',
        File.join(HOOK_DIR, 'sane_bash_guards.rb'),
        stdin_data: JSON.generate(bash_payload('mkdir -p ~/Desktop/SaneClick-E2E.yyy'))
      )
      assert_eq(dstatus.exitstatus, 2)
      assert_includes(derr, 'layout')
      true
    end
  end
end)
