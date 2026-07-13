#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'time'

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

Dir.mktmpdir('ship-guard-test-home-') do |home_dir|
  Dir.mktmpdir('ship-guard-test-') do |project_dir|
    File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
    _, ship_chain_err, ship_chain_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy; ruby scripts/SaneMaster.rb verify"
        }
      },
      {
        'HOME' => home_dir,
        'SANE_NO_KEYCHAIN' => '1',
        'SANE_ENV_CACHE_WRITE' => '0'
      }
    )
    t('Ship guard blocks release chain even when SaneMaster appears', ship_chain_status.exitstatus == 2)
    t('Ship chain block requires /ship clearance', ship_chain_err.include?('/ship clearance'))
  end
end

Dir.mktmpdir('ship-guard-clearance-') do |home_dir|
  Dir.mktmpdir('ship-guard-project-') do |project_dir|
    system('git', '-C', project_dir, 'init', '-q')
    system('git', '-C', project_dir, 'config', 'user.email', 'test@example.com')
    system('git', '-C', project_dir, 'config', 'user.name', 'Test')
    File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
    system('git', '-C', project_dir, 'add', '.saneprocess')
    system('git', '-C', project_dir, 'commit', '-q', '-m', 'baseline')
    baseline_sha = `git -C #{project_dir} rev-parse HEAD`.strip

    require_relative 'state_signer'
    test_hook_secret = 'ship-clearance-test-hook-secret'
    ship_guard_env = {
      'HOME' => home_dir,
      'CLAUDE_HOOK_SECRET' => test_hook_secret,
      'SANE_NO_KEYCHAIN' => '1',
      'SANE_ENV_CACHE_WRITE' => '0'
    }
    clearance_dir = File.join(home_dir, '.claude', 'ship_clearance')
    FileUtils.mkdir_p(clearance_dir)
    clearance_path = File.join(clearance_dir, 'SaneBar.json')
    write_clearance = lambda do |payload|
      old_hook_secret = ENV['CLAUDE_HOOK_SECRET']
      old_no_keychain = ENV['SANE_NO_KEYCHAIN']
      old_env_cache_write = ENV['SANE_ENV_CACHE_WRITE']
      begin
        ENV['CLAUDE_HOOK_SECRET'] = test_hook_secret
        ENV['SANE_NO_KEYCHAIN'] = '1'
        ENV['SANE_ENV_CACHE_WRITE'] = '0'
        StateSigner.instance_variable_set(:@secret, nil)
        StateSigner.write_signed(clearance_path, payload)
      ensure
        old_hook_secret.nil? ? ENV.delete('CLAUDE_HOOK_SECRET') : ENV['CLAUDE_HOOK_SECRET'] = old_hook_secret
        old_no_keychain.nil? ? ENV.delete('SANE_NO_KEYCHAIN') : ENV['SANE_NO_KEYCHAIN'] = old_no_keychain
        old_env_cache_write.nil? ? ENV.delete('SANE_ENV_CACHE_WRITE') : ENV['SANE_ENV_CACHE_WRITE'] = old_env_cache_write
        StateSigner.instance_variable_set(:@secret, nil)
      end
    end
    valid_clearance = {
      'app' => 'SaneBar',
      'project_dir' => project_dir,
      'git_sha' => baseline_sha,
      'cleared_at' => Time.now.utc.iso8601,
      'expires_at' => (Time.now.utc + 3600).iso8601
    }
    write_clearance.call(valid_clearance)

    release_payload = {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy"
      }
    }
    [
      ['missing project_dir', valid_clearance.reject { |key, _| key == 'project_dir' }, 'project mismatch'],
      ['missing git_sha', valid_clearance.reject { |key, _| key == 'git_sha' }, 'valid git_sha'],
      ['malformed expires_at', valid_clearance.merge('expires_at' => 'not-a-time'), 'malformed, or expired'],
      ['missing expires_at', valid_clearance.reject { |key, _| key == 'expires_at' }, 'malformed, or expired']
    ].each do |label, payload, expected_error|
      write_clearance.call(payload)
      _, invalid_err, invalid_status = run_ruby_hook('sane_ship_guard.rb', release_payload, ship_guard_env)
      t("Ship clearance blocks #{label}", invalid_status.exitstatus == 2)
      t("#{label} block is explicit", invalid_err.include?(expected_error))
    end
    write_clearance.call(valid_clearance)

    FileUtils.mkdir_p(File.join(project_dir, 'outputs'))
    File.write(File.join(project_dir, 'outputs', 'release_preflight_status.json'), "{}\n")
    system('git', '-C', project_dir, 'add', 'outputs/release_preflight_status.json')
    system('git', '-C', project_dir, 'commit', '-q', '-m', 'refresh receipt')
    _, receipt_err, receipt_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy"
        }
      },
      ship_guard_env
    )
    t('Ship clearance survives receipt-only commits', receipt_status.exitstatus == 0)
    t('Receipt-only clearance does not warn about code drift', !receipt_err.include?('Release-relevant code changed'))

    File.write(File.join(project_dir, 'README.md'), "docs only\n")
    system('git', '-C', project_dir, 'add', 'README.md')
    system('git', '-C', project_dir, 'commit', '-q', '-m', 'update docs')
    _, docs_err, docs_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy"
        }
      },
      ship_guard_env
    )
    t('Ship clearance survives docs-only commits', docs_status.exitstatus == 0)
    t('Docs-only clearance does not warn about code drift', !docs_err.include?('Release-relevant code changed'))

    FileUtils.mkdir_p(File.join(project_dir, 'website'))
    File.write(File.join(project_dir, 'website', 'index.html'), "<p>changed</p>\n")
    system('git', '-C', project_dir, 'add', 'website/index.html')
    system('git', '-C', project_dir, 'commit', '-q', '-m', 'update website')
    _, website_err, website_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy"
        }
      },
      ship_guard_env
    )
    t('Ship clearance blocks public website commits', website_status.exitstatus == 2)
    t('Website clearance block explains scoped invalidation', website_err.include?('Release-relevant code changed'))

    FileUtils.mkdir_p(File.join(project_dir, 'Scripts'))
    File.write(File.join(project_dir, 'Scripts', 'probe.rb'), "puts 'changed'\n")
    system('git', '-C', project_dir, 'add', 'Scripts/probe.rb')
    system('git', '-C', project_dir, 'commit', '-q', '-m', 'change release script')
    _, source_err, source_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --full --deploy"
        }
      },
      ship_guard_env
    )
    t('Ship clearance blocks release-relevant commits', source_status.exitstatus == 2)
    t('Release-relevant block explains scoped invalidation', source_err.include?('Release-relevant code changed'))
  end
end

Dir.mktmpdir('ship-guard-sanemaster-') do |home_dir|
  Dir.mktmpdir('ship-guard-app-') do |project_dir|
    File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
    _, sanemaster_release_err, sanemaster_release_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "cd #{project_dir} && ruby scripts/SaneMaster.rb release --full --deploy --version 9.9.9"
        }
      },
      {
        'HOME' => home_dir,
        'SANE_NO_KEYCHAIN' => '1',
        'SANE_ENV_CACHE_WRITE' => '0'
      }
    )
    t('Ship guard blocks SaneMaster release without /ship clearance', sanemaster_release_status.exitstatus == 2)
    t('SaneMaster release block requires /ship clearance', sanemaster_release_err.include?('/ship clearance'))
  end
end

Dir.mktmpdir('ship-guard-website-only-') do |home_dir|
  Dir.mktmpdir('ship-guard-website-app-') do |project_dir|
    # No clearance file is written for this app. --website-only deploys
    # marketing copy only (no build/sign/submit), so the ship guard must NOT
    # require /ship clearance for it. A full --deploy on the same uncleared app
    # must still block, proving the exemption is scoped to --website-only.
    File.write(File.join(project_dir, '.saneprocess'), "name: SaneVideo\n")
    guard_env = {
      'HOME' => home_dir,
      'SANE_NO_KEYCHAIN' => '1',
      'SANE_ENV_CACHE_WRITE' => '0'
    }
    _, website_only_err, website_only_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --website-only"
        }
      },
      guard_env
    )
    t('Ship guard allows --website-only without /ship clearance', website_only_status.exitstatus == 0)
    t('--website-only is not blocked for missing clearance', !website_only_err.include?('No /ship clearance'))

    _, deploy_err, deploy_status = run_ruby_hook(
      'sane_ship_guard.rb',
      {
        'tool_name' => 'Bash',
        'tool_input' => {
          'command' => "bash scripts/release.sh --project #{project_dir} --deploy"
        }
      },
      guard_env
    )
    t('Ship guard still blocks --deploy without clearance (exemption is scoped)', deploy_status.exitstatus == 2)
    t('--deploy block still requires /ship clearance', deploy_err.include?('/ship clearance'))
  end
end

Dir.mktmpdir('env-cache-default-') do |dir|
  cache_path = File.join(dir, 'env')
  script = <<~'RUBY'
    ENV['SANE_ENV_CACHE_FILE'] = ARGV.fetch(0)
    ENV.delete('SANE_ENV_CACHE_WRITE')
    require File.expand_path('state_signer', Dir.pwd)
    StateSigner.send(:persist_secret_to_env_cache, 'fake-regression-secret')
    if File.exist?(ARGV.fetch(0)) && File.read(ARGV.fetch(0)).include?('CLAUDE_HOOK_SECRET')
      warn 'hook secret was written to env cache'
      exit 1
    end
  RUBY
  _, env_cache_err, env_cache_status = Open3.capture3(
    'ruby', '-e', script, cache_path,
    chdir: HOOK_DIR
  )
  t('StateSigner does not persist hook secret to env cache by default', env_cache_status.success?)
  t('StateSigner env-cache regression test stays secret-free', env_cache_err.empty?)
end

Dir.mktmpdir('state-signer-keychain-write-') do |dir|
  bin_dir = File.join(dir, 'bin')
  home_dir = File.join(dir, 'home')
  log_path = File.join(dir, 'security.log')
  FileUtils.mkdir_p(bin_dir)
  FileUtils.mkdir_p(home_dir)
  fake_security = File.join(bin_dir, 'security')
  File.write(fake_security, <<~'SH')
    #!/bin/sh
    printf '%s\n' "$*" >> "$SECURITY_LOG"
    case "$1" in
      find-generic-password) exit 44 ;;
      add-generic-password) exit 42 ;;
      delete-generic-password) exit 0 ;;
      *) exit 0 ;;
    esac
  SH
  File.chmod(0o755, fake_security)
  script = <<~'RUBY'
    require File.expand_path('state_signer', Dir.pwd)
    StateSigner.send(:remove_const, :SECURITY_BIN)
    StateSigner.const_set(:SECURITY_BIN, ENV.fetch('FAKE_SECURITY_BIN'))
    StateSigner.instance_variable_set(:@secret, nil)
    StateSigner.secret
    raise 'file fallback missing' unless File.exist?(File.expand_path('~/.claude_hook_secret'))
  RUBY
  env = {
    'HOME' => home_dir,
    'PATH' => "#{bin_dir}:#{ENV.fetch('PATH')}",
    'FAKE_SECURITY_BIN' => fake_security,
    'SECURITY_LOG' => log_path,
    'SANE_ENV_CACHE_FILE' => File.join(dir, 'env'),
    'SANE_ENV_CACHE_WRITE' => '0',
    'CLAUDE_HOOK_SECRET' => nil,
    'SANE_HOOK_KEYCHAIN_WRITE' => nil
  }
  _keychain_out, keychain_err, keychain_status = Open3.capture3(env, 'ruby', '-e', script, chdir: HOOK_DIR)
  security_log = File.exist?(log_path) ? File.read(log_path) : ''
  t('StateSigner falls back to file when hook keychain item is missing', keychain_status.success?)
  t('StateSigner does not create hook keychain item by default', !security_log.include?('add-generic-password'))
  t('StateSigner keychain fallback test stays quiet', keychain_err.empty?)
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

Dir.mktmpdir('canonical-path-app-') do |project_dir|
  File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
  FileUtils.mkdir_p(File.join(project_dir, 'SaneBar.xcodeproj'))

  _, raw_xcode_err, raw_xcode_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{project_dir} && xcodebuild -scheme SaneBar test"
      }
    }
  )
  t('Launch guard blocks raw xcodebuild test in SaneApps repo', raw_xcode_status.exitstatus == 2)
  t('Raw xcodebuild block points to SaneMaster verify', raw_xcode_err.include?('SaneMaster.rb verify'))

  _, raw_swift_err, raw_swift_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{project_dir} && swift test"
      }
    }
  )
  t('Launch guard blocks raw swift test in SaneApps repo', raw_swift_status.exitstatus == 2)
  t('Raw swift test block explains stale proof risk', raw_swift_err.include?('stale checkouts'))

  _, list_err, list_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "xcodebuild -list -project #{File.join(project_dir, 'SaneBar.xcodeproj')}"
      }
    }
  )
  t('Launch guard allows read-only xcodebuild list', list_status.exitstatus == 0)
  t('Read-only xcodebuild list stays quiet', list_err.empty?)

  _, cleanup_err, cleanup_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => 'rm -rf ~/Library/Developer/Xcode/DerivedData/*'
      }
    }
  )
  t('Launch guard blocks raw destructive DerivedData cleanup', cleanup_status.exitstatus == 2)
  t('Cleanup block points to machine_cleanup', cleanup_err.include?('machine_cleanup'))

  _, killall_err, killall_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => 'killall SaneBar xcodebuild'
      }
    }
  )
  t('Launch guard blocks broad SaneApps killall cleanup', killall_status.exitstatus == 2)
  t('Killall block explains cleanup route', killall_err.include?('Non-canonical destructive cleanup'))

  _, canonical_cleanup_err, canonical_cleanup_status = run_ruby_hook(
    'sane_launch_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => 'ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply'
      }
    }
  )
  t('Launch guard allows canonical machine_cleanup route', canonical_cleanup_status.exitstatus == 0)
  t('Canonical cleanup route stays quiet', canonical_cleanup_err.empty?)
end

Dir.mktmpdir('release-guard-app-') do |project_dir|
  File.write(File.join(project_dir, '.saneprocess'), "name: SaneBar\n")
  _, pages_generic_err, pages_generic_status = run_ruby_hook(
    'sane_release_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{project_dir} && npx wrangler pages deploy ./website"
      }
    }
  )
  t('Release guard blocks generic Pages deploy in SaneApps repo', pages_generic_status.exitstatus == 2)
  t('Generic Pages block names manual website deploy', pages_generic_err.include?('Manual website deploy'))

  _, notary_generic_err, notary_generic_status = run_ruby_hook(
    'sane_release_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{project_dir} && xcrun notarytool submit outputs/release.zip --keychain-profile notarytool"
      }
    }
  )
  t('Release guard blocks generic notarytool submit in SaneApps repo', notary_generic_status.exitstatus == 2)
  t('Generic notary block names manual notarization', notary_generic_err.include?('Manual notarization'))

  _, altool_generic_err, altool_generic_status = run_ruby_hook(
    'sane_release_guard.rb',
    {
      'tool_name' => 'Bash',
      'tool_input' => {
        'command' => "cd #{project_dir} && xcrun altool --upload-app -f outputs/release.ipa --apiKey KEY --apiIssuer ISSUER"
      }
    }
  )
  t('Release guard blocks generic altool upload in SaneApps repo', altool_generic_status.exitstatus == 2)
  t('Generic altool block names manual App Store upload', altool_generic_err.include?('Manual App Store upload'))
end

_, email_chain_err, email_chain_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'check-inbox.sh check; curl -X POST https://email-api.saneapps.com/api/reply -d "{}"' }
  }
)
t('Email guard blocks direct API write after check-inbox chain', email_chain_status.exitstatus == 2)
t('Email chain block names direct write', email_chain_err.include?('Direct write to email API'))

_, email_direct_err, email_direct_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'curl -X POST https://email-api.saneapps.com/api/reply -d "{}"' }
  }
)
t('Email guard blocks standalone direct Worker API write', email_direct_status.exitstatus == 2)
t('Standalone Worker API block names direct write', email_direct_err.include?('Direct write to email API'))

_, resend_direct_err, resend_direct_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'curl -X POST https://api.resend.com/emails -d "{}"' }
  }
)
t('Email guard blocks standalone Resend API send', resend_direct_status.exitstatus == 2)
t('Standalone Resend block names tracking bypass', resend_direct_err.include?('bypasses the Worker tracking system'))

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
  'github_post_approval', '--body', 'I fixed this.', '--user-approval', 'post it',
  chdir: SANEPROCESS_DIR
)
gh_approval_payload = JSON.parse(File.read(gh_approval_path))
t('SaneMaster github_post_approval writes structured JSON approval', gh_approval_payload['user_approval'] == 'post it')
t('SaneMaster github_post_approval stores exact body hash', gh_approval_payload['body_hash'] == Digest::SHA256.hexdigest('I fixed this.'))
_, gh_approved_err, gh_approved_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue comment 123 --repo sane-apps/SaneBar --body "I fixed this."' }
  }
)
t('GitHub guard accepts structured approval', gh_approved_status.exitstatus == 0)
t('Approved GitHub guard stays quiet', gh_approved_err.empty?)

Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'github_post_approval', '--body', 'I fixed this.', '--user-approval', 'post it',
  chdir: SANEPROCESS_DIR
)
_, gh_mismatch_err, gh_mismatch_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue comment 123 --repo sane-apps/SaneBar --body "Different text."' }
  }
)
t('GitHub guard blocks approved token when final body differs', gh_mismatch_status.exitstatus == 2)
t('GitHub body mismatch block names exact final text', gh_mismatch_err.include?('exact final public text'))

_, gh_api_err, gh_api_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh api repos/sane-apps/SaneBar/issues/123/comments -f body="I fixed this."' }
  }
)
t('GitHub guard blocks gh api public comment without approval', gh_api_status.exitstatus == 2)

# Metadata-only edits (labels/assignees) post no public text. They still require a recorded
# approval, but cannot hash-match (nothing to match) — the old guard made them un-approvable.
_, _gh_label_noapp_err, gh_label_noapp_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue edit 160 --repo sane-apps/SaneBar --add-label "release:patched-pending"' }
  }
)
t('GitHub guard blocks label-only edit without approval', gh_label_noapp_status.exitstatus == 2)

Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'github_post_approval', '--body', 'Label #160 release:patched-pending', '--user-approval', 'label it',
  chdir: SANEPROCESS_DIR
)
_, _gh_label_ok_err, gh_label_ok_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue edit 160 --repo sane-apps/SaneBar --add-label "release:patched-pending"' }
  }
)
t('GitHub guard accepts label-only edit with a recorded approval', gh_label_ok_status.exitstatus.zero?)

# The carve-out is metadata-ONLY: an edit that carries --body still requires the hash match,
# so public text can never slip through `gh issue edit` unapproved.
Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'github_post_approval', '--body', 'Label only', '--user-approval', 'label it',
  chdir: SANEPROCESS_DIR
)
_, _gh_bodyedit_err, gh_bodyedit_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue edit 160 --repo sane-apps/SaneBar --body "Sneaky public text"' }
  }
)
t('GitHub guard still hash-matches an edit that carries body text', gh_bodyedit_status.exitstatus == 2)

# A git commit whose MESSAGE merely mentions gh commands must not be treated as a gh post.
_, _gh_mention_err, gh_mention_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'git commit -m "fix: gh issue edit was un-approvable" -m "details"' }
  }
)
t('GitHub guard ignores gh mentioned inside a quoted commit message', gh_mention_status.exitstatus.zero?)

# But a real (unquoted) gh public comment is still gated.
_, _gh_real_err, gh_real_status = run_ruby_hook(
  'sane_release_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'gh issue comment 123 --repo sane-apps/SaneBar --body "real post"' }
  }
)
t('GitHub guard still gates a real unquoted gh comment', gh_real_status.exitstatus == 2)
t('GitHub gh api block names user approval', gh_api_err.include?('Public GitHub interaction'))
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

email_force_path = '/tmp/.email_force_approved.json'
FileUtils.rm_f(email_force_path)
_, force_email_err, force_email_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'check-inbox.sh resolve 123 --force' }
  }
)
t('Email guard blocks check-inbox --force without scoped approval', force_email_status.exitstatus == 2)
t('Email force block names SaneMaster approval command', force_email_err.include?('email_force_approval'))

Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'email_force_approval', '--action', 'resolve', '--id', '123', '--reason', 'test override', '--user-approval', 'force it',
  chdir: SANEPROCESS_DIR
)
_, force_email_ok_err, force_email_ok_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'check-inbox.sh resolve 123 --force' }
  }
)
t('Email guard allows check-inbox --force with matching scoped approval', force_email_ok_status.exitstatus == 0)
t('Approved check-inbox force route stays quiet', force_email_ok_err.empty?)

Open3.capture3(
  'ruby', File.join(SANEPROCESS_DIR, 'scripts/SaneMaster.rb'),
  'email_force_approval', '--action', 'resolve', '--id', '123', '--reason', 'test override', '--user-approval', 'force it',
  chdir: SANEPROCESS_DIR
)
_, force_email_mismatch_err, force_email_mismatch_status = run_ruby_hook(
  'sane_email_guard.rb',
  {
    'tool_name' => 'Bash',
    'tool_input' => { 'command' => 'check-inbox.sh resolve 456 --force' }
  }
)
t('Email guard blocks check-inbox --force when approval id differs', force_email_mismatch_status.exitstatus == 2)
t('Email force mismatch explains id mismatch', force_email_mismatch_err.include?('id mismatch'))
FileUtils.rm_f(email_force_path)

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
    'SANE_SECURITY_REPEAT_COOLDOWN_SECONDS' => '300',
    # When this suite runs inside a Claude session, the guard's process-ancestry
    # walk finds the real Claude app and would exempt the spoofed lookup.
    'SANE_SECURITY_IGNORE_CLAUDE_CALLER' => '1'
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
