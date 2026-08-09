#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_release_guard.rb — PreToolUse hook
# Blocks ad-hoc release operations. Forces use of release.sh.
#
# BLOCKS:
#   - Direct `create-dmg` invocations (bypasses background, signing, notarization)
#   - Direct `hdiutil create` for SaneApps (bypasses entire release pipeline)
#   - Direct `hdiutil convert` on SaneApp DMGs (manual DMG manipulation)
#   - Direct `codesign --sign` on .dmg files (signing should go through release.sh)
#   - Direct `xcrun notarytool submit` on SaneApp DMGs (manual notarization)
#   - Direct `wrangler r2 object put` to SaneApp buckets (manual R2 upload)
#   - ANY wrangler r2 command touching SaneApp buckets (get, delete, list, etc.)
#   - Direct `wrangler pages deploy` for SaneApp sites (manual website deploy)
#   - Direct `swift.*set_dmg_icon` (manual icon setting)
#   - Direct `swift.*fix_dmg_apps_icon` (manual alias fixing)
#   - Direct `swift.*sign_update` (manual Sparkle signing)
#   - Direct `altool --upload-app` for production/release.ipa (bypasses release.sh)
#   - Direct ASC review-submission mutations (bypasses appstore_submit.rb)
#
# ALLOWS:
#   - release.sh invocations (the proper way)
#   - full_release.sh invocations
#   - SaneMaster.rb invocations
#   - TestFlight artifact IPA uploads with an exact adjacent package proof
#   - ASC GET polls + betaGroups attach + betaBuildLocalizations (Dealer Preview lane)
#   - hdiutil for info/attach/detach (non-creation operations)
#   - Non-SaneApp commands

require 'digest'
require 'json'
require 'shellwords'
require_relative '../testflight_artifact_proof'

SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneScan SaneSync SaneVideo].freeze
SANE_APP_PATTERN = Regexp.new(SANE_APPS.join('|'), Regexp::IGNORECASE)
# R2 bucket pattern — all apps use shared bucket (sanebar-downloads) but match any *-downloads to catch mistakes
SANE_BUCKET_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-downloads" }.join('|'))
# Cloudflare Pages project names (e.g. sanebar-site, saneclip-site)
SANE_PAGES_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-site" }.join('|'))
# dist.*.com domains
SANE_DIST_PATTERN = Regexp.new(SANE_APPS.map { |a| "dist\\.#{a.downcase}\\.com" }.join('|'))
# Team/company "we" only — flags presenting SaneApps as a multi-person org (a room of
# coders), NOT the natural "you and I" we ("since we last talked"). SaneApps is one person.
CORPORATE_WE_PATTERN = /\b(?:our\s+(?:team|teams|engineers?|developers?|devs?|coders?|programmers?|staff|crew|company|companies|organi[sz]ation|org|support\s+team|engineering|qa|squad|department)|the\s+(?:whole\s+|entire\s+|rest\s+of\s+the\s+)?team|my\s+team|the\s+(?:devs?|developers?|engineers)|we(?:['’]re|\s+are)\s+(?:a|an|the)\s+(?:[a-z]+\s+)?(?:team|company|startup|business|group|studio|crew|squad)|we(?:['’]ve|\s+have)?\s+(?:built|build|developed|develop|engineered|engineer|coded|programmed|architected|designed|design|shipped|ship|released|release|created|create)\b)/i
COMMAND_CHAIN_PATTERN = /(?:;|&&|\|\||\n)/
APPROVAL_FLAG = '/tmp/.gh_post_approved.json'
GITHUB_APPROVAL_TTL_SECONDS = 300

def single_canonical_command?(command, pattern)
  stripped = command.strip
  return false if stripped.match?(COMMAND_CHAIN_PATTERN)

  stripped.match?(pattern)
end

def shell_unquote(value)
  text = value.to_s.strip
  if (text.start_with?('"') && text.end_with?('"')) ||
     (text.start_with?("'") && text.end_with?("'"))
    text[1..-2]
  else
    text
  end
end

def command_project_dir(command)
  if command =~ /\bcd\s+((?:"[^"]+"|'[^']+'|\S+))\s*(?:&&|;|\n)/
    return File.expand_path(shell_unquote(Regexp.last_match(1)))
  end

  if command =~ /--project\s+((?:"[^"]+"|'[^']+'|\S+))/
    return File.expand_path(shell_unquote(Regexp.last_match(1)))
  end

  Dir.pwd
end

def saneprocess_command_context?(command)
  File.exist?(File.join(command_project_dir(command), '.saneprocess'))
end

def shell_tokens(command)
  Shellwords.split(command)
rescue ArgumentError
  command.to_s.split(/\s+/)
end

def token_value(tokens, *flags)
  flags.each do |flag|
    index = tokens.index(flag)
    return tokens[index + 1] if index && tokens[index + 1]

    prefix = "#{flag}="
    match = tokens.find { |token| token.start_with?(prefix) }
    return match[prefix.length..] if match
  end
  nil
end

# --- TestFlight lane (intelligent allow) ------------------------------------
# Owner SOP 2026-08-05: hooks that blanket-block altool/ASC broke the proven
# iOS Dealer Preview lane (archive → export → altool → betaGroups attach).
# Full App Store *submission* still goes through release.sh + /ship.
# TestFlight packaging uploads are allowed only when an exact private receipt
# beside the IPA still matches live pushed source and every package input.

def testflight_altool_upload?(command)
  bare = command.to_s
  return false unless bare.match?(/\baltool\b/) && bare.match?(/--upload-(?:app|package)\b/)

  ipa = TestflightArtifactProof.upload_ipa_path(bare)
  return false unless ipa

  project_dir = command_project_dir(command)
  return false unless File.exist?(File.join(project_dir, '.saneprocess'))
  valid, = TestflightArtifactProof.validate(project_dir: project_dir, ipa: File.expand_path(ipa, project_dir))
  return false unless valid

  true
rescue StandardError
  false
end

def app_store_review_asc_mutation?(command)
  text = command.to_s
  text.match?(%r{/v1/appStoreVersionSubmissions\b}) ||
    text.match?(%r{/v1/reviewSubmissions\b}) ||
    text.match?(%r{appStoreVersionSubmission}) ||
    text.match?(%r{/v1/appStoreVersions\b.+\bPOST\b}i) ||
    (text.match?(/\b(?:curl|asc\.rb)\b/i) && text.match?(/\bPOST\b/i) && text.match?(%r{/v1/appStoreVersions\b}))
end

def testflight_asc_api_allowed?(command)
  text = command.to_s
  return false unless text.match?(/api\.appstoreconnect\.apple\.com/) || text.match?(/\basc\.rb\b/)

  return false if app_store_review_asc_mutation?(text)

  # Explicit reads.
  return true if text.match?(/\basc\.rb\s+GET\b/)

  curl_write = text.match?(/\bcurl\b/) && (
    text.match?(/\s-X\s*(POST|PATCH|PUT|DELETE)\b/i) ||
    text.match?(/\s-[dF]\b/) ||
    text.match?(/--data(?:-binary|-raw|-urlencode)?\b/)
  )
  # curl without write flags is treated as GET/HEAD poll.
  return true if text.match?(/\bcurl\b/) && !curl_write

  # Dealer Preview / Internal attach + What to Test.
  text.match?(%r{/v1/betaGroups/[^/\s"'\\]+/relationships/builds\b}) ||
    text.match?(%r{/v1/builds/[^/\s"'\\]+/relationships/betaGroups\b}) ||
    text.match?(%r{/v1/betaBuildLocalizations\b}) ||
    text.match?(%r{/v1/buildBetaDetails\b})
end

def gh_public_command?(command)
  # Blank quoted strings first so a command that merely MENTIONS gh inside a quoted
  # argument (e.g. `git commit -m "fix: gh issue edit ..."`) is not mistaken for an
  # actual gh invocation. A real gh command has its verb OUTSIDE quotes, so it still matches.
  scan = command.gsub(/'[^']*'/, "''").gsub(/"[^"]*"/, '""')
  scan.match?(/\bgh\s+(?:issue|pr)\s+(?:comment|close|review|create|edit)\b/) ||
    scan.match?(/\bgh\s+api\b.*(?:^|[\s\/])repos\/(?:sane-apps|mrsaneapps)\//i)
end

def extract_gh_public_text(command)
  tokens = shell_tokens(command)
  pieces = []
  %w[--body --comment --title].each do |flag|
    value = token_value(tokens, flag)
    pieces << value.to_s unless value.to_s.empty?
  end
  body_file = token_value(tokens, '--body-file', '--comment-file')
  if body_file && File.file?(body_file)
    pieces << File.read(body_file, encoding: Encoding::UTF_8)
  end

  tokens.each do |token|
    pieces << Regexp.last_match(1) if token =~ /\A(?:body|title|comment)=(.*)\z/
  end

  pieces.join("\n").strip
rescue StandardError
  ''
end

# A `gh issue/pr edit` that only changes metadata (labels, assignees, milestone, projects)
# and carries NO public text flag. These post no comment text — there is nothing to draft
# or hash-match — but they still require a recorded user approval (consent).
def gh_metadata_only_edit?(command)
  return false unless command.match?(/\bgh\s+(?:issue|pr)\s+edit\b/)
  return false if command.match?(/--(?:body|comment|title)\b|--body-file\b|--comment-file\b/)

  command.match?(/--(?:add|remove)-(?:label|assignee|project)\b|--milestone\b|--add-reviewer\b/)
end

def consume_github_approval(public_text, metadata_only: false)
  return :missing unless File.exist?(APPROVAL_FLAG)

  payload = JSON.parse(File.read(APPROVAL_FLAG, encoding: Encoding::UTF_8))
  File.delete(APPROVAL_FLAG)
  age = Time.now.to_i - payload['created_at'].to_i
  approval_present = payload['created_at'].to_i.positive? &&
                     age >= 0 &&
                     age < GITHUB_APPROVAL_TTL_SECONDS &&
                     !payload['user_approval'].to_s.strip.empty?
  return :stale unless approval_present

  # Metadata-only edits (labels/assignees/milestone) and admin API calls (repo
  # settings, branch protection) post NO public text, so there is nothing to
  # hash-match — a fresh, user-approved token is sufficient consent. Admin
  # tokens must be recorded explicitly via `github_post_approval --admin`.
  # Without this, such calls were un-approvable (empty text => permanent mismatch).
  return :valid if public_text.to_s.strip.empty? && (metadata_only || payload['admin'] == true)

  expected = payload['body_hash'].to_s
  actual = Digest::SHA256.hexdigest(public_text.to_s.strip)
  return :body_mismatch if expected.empty? || public_text.to_s.strip.empty? || expected != actual

  :valid
rescue JSON::ParserError, SystemCallError
  File.delete(APPROVAL_FLAG) if File.exist?(APPROVAL_FLAG)
  :missing
end

begin
  input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

canonical_release_command = single_canonical_command?(command, /\A\s*(?:bash\s+|sh\s+)?(?:\S+\/)?(?:full_)?release\.sh\b/)
canonical_sanemaster_command = single_canonical_command?(command, /\A\s*(?:ruby\s+)?(?:\S+\/)?SaneMaster(?:_standalone)?\.rb\b/)

# Block 1: Direct create-dmg (bypasses background, icon fix, signing chain)
if command.match?(/\bcreate-dmg\b/) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Ad-hoc DMG creation for SaneApp'
  warn '   create-dmg without release.sh skips: background generation,'
  warn '   Applications icon fix, proper signing chain, notarization.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  warn '   The release script handles the complete pipeline.'
  exit 2
end

# Block 2: Direct hdiutil create for SaneApps
if command.match?(/\bhdiutil\s+create\b/) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Ad-hoc DMG creation via hdiutil for SaneApp'
  warn '   Direct hdiutil create bypasses the entire release pipeline.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 3: Direct codesign on SaneApp .dmg files
if command.match?(/\bcodesign\b.*--sign/) && command.match?(/\.dmg\b/i) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Manual DMG codesigning for SaneApp'
  warn '   DMG signing should go through the release pipeline.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 4: Direct hdiutil convert on SaneApp DMGs
if command.match?(/\bhdiutil\s+convert\b/) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Manual DMG conversion for SaneApp'
  warn '   hdiutil convert should only happen inside release.sh.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 5: Direct notarytool submit on SaneApp DMGs
if command.match?(/\bnotarytool\s+submit\b/) && (command.match?(SANE_APP_PATTERN) || saneprocess_command_context?(command))
  warn '🔴 BLOCKED: Manual notarization of SaneApp DMG'
  warn '   Notarization should go through the release pipeline.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 6: ANY wrangler r2 command touching SaneApp buckets
# Catches: wrangler r2 object put/get/delete, npx wrangler r2 ..., etc.
# Matches by BOTH app name pattern AND bucket name pattern for maximum coverage.
if command.match?(/\bwrangler\s+r2\b/)
  if command.match?(SANE_APP_PATTERN) || command.match?(SANE_BUCKET_PATTERN)
    warn '🔴 BLOCKED: Manual R2 operation for SaneApp'
    warn '   ALL R2 operations should go through release.sh --deploy.'
    warn '   Manual uploads risk: wrong R2 key path, missing --remote flag,'
    warn '   uploading to local dev bucket instead of production.'
    warn ''
    warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
    exit 2
  end
end

# Block 6b: Wrangler pages deploy for SaneApp sites
if command.match?(/\bwrangler\s+pages\s+deploy\b/)
  if command.match?(SANE_APP_PATTERN) || command.match?(SANE_PAGES_PATTERN) || command.match?(SANE_DIST_PATTERN) || saneprocess_command_context?(command)
    warn '🔴 BLOCKED: Manual website deploy for SaneApp'
    warn '   Website deploys should go through release.sh --deploy.'
    warn ''
    warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
    exit 2
  end
end

# Block 7: Direct set_dmg_icon.swift execution
if command.match?(/\bswift\b.*\bset_dmg_icon\b/)
  warn '🔴 BLOCKED: Manual DMG icon setting'
  warn '   DMG file icons are set automatically by release.sh.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 8: Direct fix_dmg_apps_icon.swift execution
if command.match?(/\bswift\b.*\bfix_dmg_apps_icon\b/)
  warn '🔴 BLOCKED: Manual Applications alias icon fixing'
  warn '   The Applications folder icon is fixed automatically by release.sh.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 9: Direct sign_update.swift execution (Sparkle signing)
if command.match?(/\bswift\b.*\bsign_update\b/)
  warn '🔴 BLOCKED: Manual Sparkle signing'
  warn '   Sparkle EdDSA signing is handled automatically by release.sh.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path>'
  exit 2
end

# Block 10: Sparkle key generation (ONE shared key for all SaneApps)
if command.match?(/\bgenerate_keys\b/) || command.match?(/setup_sparkle_keys/)
  warn '🔴 BLOCKED: Sparkle key generation'
  warn '   There is ONE shared Sparkle EdDSA key for ALL SaneApps.'
  warn '   It lives in Keychain: account "EdDSA Private Key"'
  warn '   Public: 7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU='
  warn ''
  warn '   NEVER generate new keys. The release script reads the existing key from Keychain.'
  exit 2
end

# Block 11: Direct curl/wget UPLOADS to SaneApp dist domains
# Allow read-only checks (HEAD requests, download-to-null, wget --spider) for diagnostics.
is_dist_command = command.match?(/\b(?:curl|wget)\b/) && command.match?(SANE_DIST_PATTERN)
is_readonly = command.match?(/\bcurl\b.*(?:-[a-zA-Z]*I[a-zA-Z]*\b|--head\b|-o\s*\/dev\/null\b|-w\b)/) ||
              command.match?(/\bwget\b.*--spider\b/)
if is_dist_command && !is_readonly
  warn '🔴 BLOCKED: Manual upload to SaneApp distribution domain'
  warn '   Distribution uploads should go through release.sh --deploy.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
  exit 2
end

# Block 12: Manual altool uploads for SaneApps.
# Intelligent allow: TestFlight artifact IPA (`outputs/artifacts/<build>/export/*.ipa`)
# after an exact adjacent package proof. Still block generic/production release.ipa uploads
# that should go through release.sh + /ship.
if command.match?(/\baltool\s+--upload-(?:app|package)\b/) && (command.match?(SANE_APP_PATTERN) || saneprocess_command_context?(command))
  if testflight_altool_upload?(command)
    warn '🟢 ALLOWED: TestFlight artifact upload (exact source/archive/export/IPA proof)'
    warn '   Reminder: App Store *review submission* still requires /ship → release.sh --deploy.'
  else
    warn '🔴 BLOCKED: Manual App Store upload for SaneApp'
    warn '   Production/App Store uploads should go through the release pipeline.'
    warn '   TestFlight uploads need:'
    warn '     1) IPA under outputs/artifacts/<build>/export/*.ipa'
    warn '     2) exact adjacent mode-0600 proof from SaneProcess/scripts/testflight_artifact_proof.rb'
    warn ''
    warn '   ✅ App Store: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
    warn '   ✅ TestFlight: verify → archive/export → SaneProcess testflight_artifact_proof.rb → altool that IPA'
    exit 2
  end
end

# Block 13: Manual App Store Connect API calls for SaneApps.
# Allow TF beta attach / localization / read-backs. Block review submission mutations
# and other write traffic that should go through release.sh.
if (command.match?(/\bcurl\b[^\n]*api\.appstoreconnect\.apple\.com/) || command.match?(/\basc\.rb\b/)) &&
   (command.match?(SANE_APP_PATTERN) || saneprocess_command_context?(command))
  unless testflight_asc_api_allowed?(command)
    warn '🔴 BLOCKED: Manual App Store Connect API call for SaneApp'
    warn '   App Store *review* mutations go through appstore_submit.rb via release.sh.'
    warn '   Allowed without /ship: GET polls, betaGroups build attach, betaBuildLocalizations.'
    warn ''
    warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
    exit 2
  end
end

# Block 15: External repo submissions require reading contribution guidelines first
# Before creating PRs, commenting, or opening issues on repos that aren't sane-apps/*,
# Claude must prove it read the repo's contribution guidelines by:
#   1. Fetching CONTRIBUTING.md (or equivalent) from the target repo
#   2. Explaining the key formatting/submission rules to the user
#   3. Touching /tmp/.contrib_read_<owner>_<repo> flag file
# Flag persists for the session (guidelines don't change mid-session).
if command.match?(/\bgh\s+(?:issue|pr)\s+(?:comment|close|review|create)\b/)
  repo = command[/--repo\s+(\S+)/, 1]
  if repo
    owner, name = repo.split('/', 2)
    unless owner&.downcase == 'sane-apps' || owner&.downcase == 'mrsaneapps'
      flag = "/tmp/.contrib_read_#{owner}_#{name}".gsub(/[^a-zA-Z0-9_\-\/.]/, '_')
      unless File.exist?(flag)
        warn '🔴 BLOCKED: Submission to external repo without reading contribution guidelines'
        warn "   Target: #{repo}"
        warn ''
        warn '   Before submitting to external repos, you MUST:'
        warn '   1. Fetch and READ their CONTRIBUTING.md (or contribution guidelines)'
        warn '   2. Explain the key formatting rules to the user'
        warn '   3. Verify your submission complies with EVERY rule'
        warn "   4. touch #{flag}"
        warn ''
        warn '   This prevents sloppy submissions that waste maintainer time.'
        exit 2
      end
    end
  end
end

exit 0 if canonical_release_command || canonical_sanemaster_command

# Block 14: Public GitHub interactions (comments, close, review) require user approval
# gh issue comment, gh issue close --comment, gh pr comment, gh pr review — all post publicly
# as MrSaneApps. NEVER post without showing the user a draft first.
# Read-only operations (gh issue view, gh issue list, gh pr view) are allowed.
#
# Approval flow:
#   1. Claude shows draft text to user in conversation
#   2. User approves (edits or says "post it")
#   3. Claude records that approval with SaneMaster github_post_approval
#   4. Claude runs gh command — hook sees the structured approval, allows it, deletes it
#   5. If no approval → block and remind Claude to show draft first
if gh_public_command?(command)
  if command.include?('github_post_approval') || command.include?(APPROVAL_FLAG)
    warn '🔴 BLOCKED: Cannot approve and post publicly in the same command'
    warn '   Approval capture and the public GitHub post must be separate steps.'
    exit 2
  end

  public_text = extract_gh_public_text(command)
  if public_text.match?(CORPORATE_WE_PATTERN)
    warn '🔴 BLOCKED: "we/us/our" language in public GitHub post'
    warn '   SaneApps is one person. Use: I/me/my.'
    warn ''
    warn '   ✅ Rewrite draft in first-person singular, then retry.'
    exit 2
  end

  approval_status = consume_github_approval(public_text, metadata_only: gh_metadata_only_edit?(command))
  if approval_status == :valid
    exit 0  # Approved — allow the post
  end
  warn '🔴 BLOCKED: Public GitHub interaction without user approval'
  warn '   Approval must match the exact final public text.' if approval_status == :body_mismatch
  warn '   This posts publicly as MrSaneApps. Show the user a draft first.'
  warn ''
  warn '   ✅ Show the draft text to the user, get explicit approval, then post.'
  warn '   Then run: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb github_post_approval --body-file <draft_file> --user-approval "<quote>"'
  warn '   For admin API calls with no post body (repo settings, branch protection):'
  warn '   describe the action to the user, get approval, then run:'
  warn '   ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb github_post_approval --admin --user-approval "<quote>"'
  exit 2
end

exit 0
