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

  test('blocks whole-keychain enumeration before it can flood prompts') do
    [
      'security dump-keychain -d login.keychain-db',
      '/usr/bin/security dump-keychain -d login.keychain-db',
      "ssh mini 'security dump-keychain -d login.keychain-db'"
    ].each do |command|
      _out, err, status = run_guard(
        'sane_bash_guards.rb',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } }
      )

      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'whole-keychain enumeration')
      assert_includes(err, '~/.config/nv/env')
    end
    true
  end

  test('allows scoped Keychain lookup and textual mention of blocked command') do
    [
      'security find-generic-password -s cloudflare -a api_token -w',
      'rg "security dump-keychain" scripts'
    ].each do |command|
      _out, err, status = run_guard(
        'sane_bash_guards.rb',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } }
      )

      assert_eq(status.exitstatus, 0)
      assert_eq(err, '')
    end
    true
  end


  test('blocks Safari and Chrome across direct absolute nested and remote forms') do
    commands = [
      '/usr/bin/open -a Safari https://example.com',
      'command /usr/bin/open -b com.google.Chrome https://example.com',
      '/bin/zsh -lc \'/usr/bin/open -a "Google Chrome" https://example.com\'',
      'ssh mini \'/usr/bin/open -b com.apple.Safari https://example.com\'',
      'osascript -e \'tell application "Google Chrome" to activate\'',
      'ssh mini \'osascript -e "tell application \\"Safari\\" to activate"\''
    ]
    commands.each do |command|
      _out, err, status = run_guard(
        'sane_bash_guards.rb',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } }
      )
      assert_eq(status.exitstatus, 2)
      assert_includes(err, 'Brave only')
    end
    true
  end

  test('allows Brave and source text that mentions prohibited browsers') do
    [
      '/usr/bin/open -a "Brave Browser" https://example.com',
      'rg \'tell application "Safari"\' scripts',
      'git commit -m "docs: Chrome is blocked; use Brave"'
    ].each do |command|
      _out, err, status = run_guard(
        'sane_bash_guards.rb',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } }
      )
      assert_eq(status.exitstatus, 0)
      assert_eq(err, '')
    end
    true
  end

  test('blocks deprecated ad-hoc Prophecy reviewer browser scripts') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => 'bash /tmp/admin-brave-e2e/run.sh' }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'ad-hoc Prophecy Ledger reviewer click')
    assert_includes(err, 'SaneMaster.rb prophecy_reviewer_click')
    true
  end

  test('blocks direct raw Mini screenshot even when ssh wrapper is bypassed') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/usr/bin/ssh -o BatchMode=yes mini "bash -lc \'screencapture -x /tmp/proof.png\'"'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    assert_includes(err, 'capture-mini-screenshot.sh desktop')
    true
  end

  test('blocks shell-wrapped direct raw Mini screenshot') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/bin/bash -lc "/usr/bin/ssh mini \\"screencapture -x /tmp/proof.png\\""'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    assert_includes(err, 'capture-mini-screenshot.sh desktop')
    true
  end

  test('blocks shell-wrapped raw Mini screenshot after shell option with value') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/bin/bash --rcfile /tmp/sane-test-rc -lc "/usr/bin/ssh mini.local \\"screencapture -x /tmp/proof.png\\""'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    true
  end

  test('blocks raw Mini screenshot mixed with canonical wrapper name') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => 'ssh mini "~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop; screencapture -x /tmp/proof.png"'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    true
  end

  test('blocks raw Mini peekaboo screen capture over ssh') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "ssh mini 'peekaboo image --mode screen --path /tmp/x.png'"
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    true
  end

  test('blocks raw Mini ffmpeg avfoundation screen capture over ssh') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "ssh mini 'ffmpeg -f avfoundation -i 2:none -t 3 /tmp/x.mp4'"
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'raw Mini screen capture')
    true
  end

  test('allows Mini screen capture routed through the mini-gui-run wrapper') do
    _out, _err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "ssh mini 'bash ~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh --close-window -- \"peekaboo image --path /tmp/x.png\"'"
        }
      }
    )

    assert_eq(status.exitstatus, 0)
    true
  end

  test('allows cliclick and ffmpeg file conversion over plain ssh') do
    %W[
      ssh\ mini\ 'cliclick\ p'
      ssh\ mini\ 'ffmpeg\ -i\ in.mp4\ out.mp4'
    ].each do |command|
      _out, _err, status = run_guard(
        'sane_bash_guards.rb',
        { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } }
      )
      assert_eq(status.exitstatus, 0)
    end
    true
  end

  test('blocks direct detached Mini QA command when ssh wrapper is bypassed') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/usr/bin/ssh mini "launchctl submit -l sanebar.qa.2174 -- /bin/bash ~/SaneApps/apps/SaneBar/outputs/run_sanebar_qa_2174.sh"'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'detached Mini SaneApps QA command')
    assert_includes(err, 'release_preflight')
    true
  end

  test('blocks shell-wrapped direct detached Mini QA command') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/bin/zsh -lc "/usr/bin/ssh mini \\"launchctl submit -l sanebar.qa.2174 -- /bin/bash ~/SaneApps/apps/SaneBar/outputs/run_sanebar_qa_2174.sh\\""'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'detached Mini SaneApps QA command')
    assert_includes(err, 'foreground canonical release/runtime receipts')
    true
  end

  test('allows read-only Mini source search for blocked detached QA text') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => 'ssh mini "cd ~/SaneApps/infra/SaneProcess && rg \\"launchctl submit\\" scripts/hooks scripts/sanemaster"'
        }
      }
    )

    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
    true
  end

  test('allows read-only Mini source search for blocked screenshot text') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => 'ssh mini "cd ~/SaneApps/infra/SaneProcess && rg \\"screencapture\\" scripts/mini scripts/hooks"'
        }
      }
    )

    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
    true
  end

  test('blocks shell-wrapped detached Mini QA after shell option with value') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => '/bin/bash --init-file /tmp/sane-test-rc -lc "/usr/bin/ssh user@mini.local \\"launchctl submit -l sanebar.qa.2174 -- /bin/bash ~/SaneApps/apps/SaneBar/outputs/run_sanebar_qa_2174.sh\\""'
        }
      }
    )

    assert_eq(status.exitstatus, 2)
    assert_includes(err, 'detached Mini SaneApps QA command')
    true
  end

  test('allows canonical Mini screenshot wrapper command') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => 'ssh mini "~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop"'
        }
      }
    )

    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
    true
  end

  test('allows ordinary Mini ssh commands') do
    _out, err, status = run_guard(
      'sane_bash_guards.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => { 'command' => 'ssh mini date' }
      }
    )

    assert_eq(status.exitstatus, 0)
    assert_eq(err, '')
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
