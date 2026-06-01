#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

HOOK_DIR = File.expand_path(__dir__)
SANEPROCESS_DIR = File.expand_path('../..', __dir__)

$passed = 0
$total = 0

def t(name, ok)
  $total += 1
  if ok
    $passed += 1
    warn "  ✅ #{name}"
  else
    warn "  ❌ #{name}"
  end
end

def run_ruby_hook(name, payload, env = {})
  Open3.capture3(
    env,
    'ruby', File.join(HOOK_DIR, name),
    stdin_data: JSON.generate(payload),
    chdir: SANEPROCESS_DIR
  )
end

warn '=' * 60
warn 'Grok + security guard regression tests'
warn '=' * 60

dangerous_release_payload = {
  'tool_name' => 'Bash',
  'tool_input' => { 'command' => 'create-dmg SaneBar' }
}

_, grok_release_err, grok_release_status = run_ruby_hook(
  'sane_release_guard.rb',
  dangerous_release_payload,
  { 'GROK_HOOK_EVENT' => 'PreToolUse' }
)
t('Grok hook event still enforces high-risk release guard', grok_release_status.exitstatus == 2)
t('Grok release block explains canonical release path', grok_release_err.include?('release.sh'))

_, grok_session_err, grok_session_status = run_ruby_hook(
  'sane_release_guard.rb',
  dangerous_release_payload,
  { 'GROK_SESSION_ID' => 'test-session' }
)
t('GROK_SESSION_ID alone does not no-op release guard', grok_session_status.exitstatus == 2)
t('GROK_SESSION_ID release block is the same guard family', grok_session_err.include?('Ad-hoc DMG'))

_, noisy_err, noisy_status = run_ruby_hook(
  'sanetrack.rb',
  { 'tool_name' => 'Read', 'tool_input' => { 'file_path' => 'README.md' }, 'tool_response' => {} },
  { 'GROK_HOOK_EVENT' => 'PostToolUse' }
)
t('Noisy passive tracking hook still no-ops under Grok hook event', noisy_status.exitstatus == 0 && noisy_err.empty?)

Dir.mktmpdir('sane-security-guard-test-') do |dir|
  env = {
    'CLAUDE_CODE' => '1',
    'TMPDIR' => dir,
    'SANE_REAL_SECURITY' => '/usr/bin/true',
    'SANE_SECURITY_REPEAT_COOLDOWN_SECONDS' => '300'
  }
  args = ['find-generic-password', '-s', 'Claude Code', '-w']

  stdout, stderr, status = Open3.capture3(env, 'bash', File.join(HOOK_DIR, 'sane_security_guard.sh'), *args)
  stamp_path = File.join(dir, 'sane-security-guard', 'last_lookup')
  t('Claude auth-shaped lookup is not exempted without a Claude caller', status.success? && File.exist?(stamp_path))
  t('Security guard test command stays quiet on allowed first lookup', stdout.empty? && stderr.empty?)

  _, repeat_err, repeat_status = Open3.capture3(env, 'bash', File.join(HOOK_DIR, 'sane_security_guard.sh'), *args)
  t('Repeated spoofed Claude auth lookup is throttled', repeat_status.exitstatus == 2)
  t('Repeated lookup block names Keychain reuse rule', repeat_err.include?('Repeated Keychain lookup too soon'))
end

warn ''
warn '=' * 60
warn "#{$passed}/#{$total} tests passed"
if $passed == $total
  warn 'ALL TESTS PASSED'
  exit 0
else
  warn "#{$total - $passed} TESTS FAILED"
  exit 1
end
