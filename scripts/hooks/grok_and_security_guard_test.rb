#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

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

_, chain_release_err, chain_release_status = run_ruby_hook(
  'sane_release_guard.rb',
  { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'ruby scripts/SaneMaster.rb verify; create-dmg SaneBar' } }
)
t('Release guard blocks forbidden operation after SaneMaster chain', chain_release_status.exitstatus == 2)
t('Release chain block names ad-hoc DMG', chain_release_err.include?('Ad-hoc DMG'))

_, chain_r2_err, chain_r2_status = run_ruby_hook(
  'sane_release_guard.rb',
  { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'bash scripts/release.sh --project .; wrangler r2 object put SaneBar.dmg sanebar-downloads/SaneBar.dmg' } }
)
t('Release guard blocks forbidden R2 operation after release.sh chain', chain_r2_status.exitstatus == 2)
t('R2 chain block names manual R2 operation', chain_r2_err.include?('Manual R2 operation'))

Dir.mktmpdir('ship-guard-test-') do |project_dir|
  File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
  _, ship_chain_err, ship_chain_status = run_ruby_hook(
    'sane_ship_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy; ruby scripts/SaneMaster.rb verify"
      }
    }
  )
  t('Ship guard blocks release chain even when SaneMaster appears', ship_chain_status.exitstatus == 2)
  t('Ship chain block requires /ship clearance', ship_chain_err.include?('/ship clearance'))
end

_, launch_chain_err, launch_chain_status = run_ruby_hook(
  'sane_launch_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb SaneBar; open /Applications/SaneBar.app' }
  }
)
t('Launch guard blocks manual app open after sane_test chain', launch_chain_status.exitstatus == 2)
t('Launch block points to shared sane_test path', launch_chain_err.include?('~/SaneApps/infra/SaneProcess/scripts/sane_test.rb'))

_, scan_launch_err, scan_launch_status = run_ruby_hook(
  'sane_launch_guard.rb',
  { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'open /Applications/SaneScan.app' } }
)
t('Launch guard blocks SaneScan app launch', scan_launch_status.exitstatus == 2)
t('SaneScan launch block points to shared sane_test path', scan_launch_err.include?('~/SaneApps/infra/SaneProcess/scripts/sane_test.rb'))

_, email_chain_err, email_chain_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'check-inbox.sh check; curl -X POST https://email-api.saneapps.com/api/reply -d "{}"' }
  }
)
t('Email guard blocks direct API write after check-inbox chain', email_chain_status.exitstatus == 2)
t('Email chain block names direct write', email_chain_err.include?('Direct write to email API'))

gh_approval_path = '/tmp/.gh_post_approved.json'
FileUtils.rm_f(gh_approval_path)
_, gh_unapproved_err, gh_unapproved_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue comment 123 --repo sane-apps/SaneBar --body "I fixed this."' }
  }
)
t('GitHub public post blocks without approval', gh_unapproved_status.exitstatus == 2)
t('GitHub public post block names SaneMaster approval command', gh_unapproved_err.include?('SaneMaster.rb github_post_approval'))
t('GitHub public post block does not instruct raw hidden flag write', !gh_unapproved_err.include?('touch /tmp/.gh_post_approved'))

_, gh_chain_err, gh_chain_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'ruby scripts/SaneMaster.rb github_post_approval --user-approval "post it"; gh issue comment 123 --repo sane-apps/SaneBar --body "I fixed this."' }
  }
)
t('GitHub guard blocks approve-and-post command chain', gh_chain_status.exitstatus == 2)
t('GitHub chain block names separate steps', gh_chain_err.include?('separate steps'))

Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'github_post_approval', '--user-approval', 'post it',
  chdir: SANEPROCESS_DIR
)
t('SaneMaster github_post_approval writes structured JSON approval', JSON.parse(File.read(gh_approval_path))['user_approval'] == 'post it')
_, gh_approved_err, gh_approved_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue comment 123 --repo sane-apps/SaneBar --body "I fixed this."' }
  }
)
t('GitHub guard accepts structured approval', gh_approved_status.exitstatus == 0)
t('Approved GitHub guard stays quiet', gh_approved_err.empty?)
FileUtils.rm_f(gh_approval_path)

Dir.mktmpdir('email-guard-test-') do |dir|
  body_path = File.join(dir, 'body.txt')
  body = "Thanks for sending this over.\n\nThanks,\nMr. Sane\nhttps://saneapps.com\n"
  File.write(body_path, body)
  approval_path = '/tmp/.email_post_approved.json'
  FileUtils.rm_f(approval_path)

  _, email_unapproved_err, email_unapproved_status = run_ruby_hook(
    'sane_email_guard.rb',
    { 'tool_name' => 'Bash', 'tool_input' => { 'command' => "check-inbox.sh reply 123 #{body_path}" } }
  )
  t('Email guard blocks unapproved check-inbox reply', email_unapproved_status.exitstatus == 2)
  t('Email approval block names canonical approve command', email_unapproved_err.include?('check-inbox.sh approve <body_file> --user-approval "<quote>"'))
  t('Email approval block does not instruct raw hidden flag write', !email_unapproved_err.include?('echo "<sha256'))

  File.write(
    approval_path,
    JSON.pretty_generate(
      'created_at' => Time.now.to_i - 10,
      'body_hash' => Digest::SHA256.hexdigest(body.strip),
      'body_file' => body_path,
      'user_approval' => 'send'
    )
  )
  _, email_approved_err, email_approved_status = run_ruby_hook(
    'sane_email_guard.rb',
    { 'tool_name' => 'Bash', 'tool_input' => { 'command' => "check-inbox.sh reply 123 #{body_path}" } }
  )
  t('Email guard accepts canonical JSON approval', email_approved_status.exitstatus == 0)
  t('Approved email guard stays quiet', email_approved_err.empty?)
  FileUtils.rm_f(approval_path)
end

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
