#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require_relative 'test/test_framework'

include TestFramework

HOOK_DIR = File.expand_path(__dir__)
DISPATCHER = File.join(HOOK_DIR, 'sane_bash_guards.rb')

def run_guard(script, payload)
  Open3.capture3(
    'ruby',
    File.join(HOOK_DIR, script),
    stdin_data: JSON.generate(payload),
    chdir: File.expand_path('../..', __dir__)
  )
end

exit(run_tests('Sane Bash Guards Dispatcher Tests') do
  test('preserves launch guard stderr and exit status exactly') do
    payload = {
      'tool_name' => 'Bash',
      'tool_input' => { 'command' => 'open /tmp/SaneBar.app' }
    }

    _launch_out, launch_err, launch_status = run_guard('sane_launch_guard.rb', payload)
    _dispatch_out, dispatch_err, dispatch_status = run_guard('sane_bash_guards.rb', payload)

    assert_eq(dispatch_status.exitstatus, launch_status.exitstatus)
    assert_eq(dispatch_err, launch_err)
    true
  end

  test('first block wins before later release guard') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => 'open /tmp/SaneBar.app; create-dmg SaneBar' }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'Manual launch of SaneApp')
    assert(!err.include?('Ad-hoc DMG'))
    true
  end

  test('release guard still blocks when launch guard allows') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => 'create-dmg SaneBar' }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'Ad-hoc DMG')
    true
  end

  test('email guard still blocks after earlier guards allow') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => "curl -X POST https://api.resend.com/emails -d '{}'" }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'Direct email send via Resend API')
    true
  end

  test('non-Bash payload passes') do
    _out, _err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Read',
        'tool_input' => { 'file_path' => 'README.md' }
      }
    )

    assert_eq(status.exitstatus, 0)
    true
  end
end)
