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
#   - Direct `generate_keys` or Sparkle key generation (ONE shared key, never generate)
#   - Manual appcast.xml editing (must go through release.sh)
#   - GitHub submissions to external repos without reading their contribution guidelines
#
# ALLOWS:
#   - release.sh invocations (the proper way)
#   - full_release.sh invocations
#   - SaneMaster.rb invocations
#   - hdiutil for info/attach/detach (non-creation operations)
#   - Non-SaneApp commands

require 'json'

SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo].freeze
SANE_APP_PATTERN = Regexp.new(SANE_APPS.join('|'), Regexp::IGNORECASE)
# R2 bucket pattern — all apps use shared bucket (sanebar-downloads) but match any *-downloads to catch mistakes
SANE_BUCKET_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-downloads" }.join('|'))
# Cloudflare Pages project names (e.g. sanebar-site, saneclip-site)
SANE_PAGES_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-site" }.join('|'))
# dist.*.com domains
SANE_DIST_PATTERN = Regexp.new(SANE_APPS.map { |a| "dist\\.#{a.downcase}\\.com" }.join('|'))
CORPORATE_WE_PATTERN = /\b(?:we|we['’]re|we['’]ll|we['’]ve|our|us)\b/i

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

# Always allow commands that are primarily release.sh, full_release.sh, or SaneMaster.rb.
# Match: the command starts with (optionally bash/sh/ruby) the script name.
# This prevents bypass via "echo release.sh && codesign --sign ..."
exit 0 if command.match?(/\A\s*(?:bash\s+|sh\s+)?(?:\S+\/)?(?:full_)?release\.sh\b/)
exit 0 if command.match?(/\A\s*(?:ruby\s+)?(?:\S+\/)?SaneMaster\.rb\b/)
exit 0 if command.match?(/\A\s*(?:ruby\s+)?(?:\S+\/)?SaneMaster_standalone\.rb\b/)

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
if command.match?(/\bnotarytool\s+submit\b/) && command.match?(SANE_APP_PATTERN)
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
  if command.match?(SANE_APP_PATTERN) || command.match?(SANE_PAGES_PATTERN) || command.match?(SANE_DIST_PATTERN)
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

# Block 12: Manual altool uploads for SaneApps (must go through release.sh)
if command.match?(/\baltool\s+--upload-app/) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Manual App Store upload for SaneApp'
  warn '   App Store uploads should go through the release pipeline.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
  exit 2
end

# Block 13: Manual App Store Connect API calls for SaneApps
if command.match?(/\bcurl\b.*api\.appstoreconnect\.apple\.com/) && command.match?(SANE_APP_PATTERN)
  warn '🔴 BLOCKED: Manual App Store Connect API call for SaneApp'
  warn '   ASC API operations should go through appstore_submit.rb via release.sh.'
  warn ''
  warn '   ✅ Use instead: bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <path> --deploy'
  exit 2
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

# Block 14: Public GitHub interactions (comments, close, review) require user approval
# gh issue comment, gh issue close --comment, gh pr comment, gh pr review — all post publicly
# as MrSaneApps. NEVER post without showing the user a draft first.
# Read-only operations (gh issue view, gh issue list, gh pr view) are allowed.
#
# Approval flow:
#   1. Claude shows draft text to user in conversation
#   2. User approves (edits or says "post it")
#   3. Claude writes /tmp/.gh_post_approved (touch file)
#   4. Claude runs gh command — hook sees flag, allows it, deletes flag
#   5. If no flag → block and remind Claude to show draft first
APPROVAL_FLAG = '/tmp/.gh_post_approved'
if command.match?(/\bgh\s+(?:issue|pr)\s+(?:comment|close|review|create)\b/)
  if command.match?(CORPORATE_WE_PATTERN)
    warn '🔴 BLOCKED: "we/us/our" language in public GitHub post'
    warn '   SaneApps is one person. Use: I/me/my.'
    warn ''
    warn '   ✅ Rewrite draft in first-person singular, then retry.'
    exit 2
  end

  if File.exist?(APPROVAL_FLAG)
    # Check flag is recent (within 5 minutes) to prevent stale approvals
    age = Time.now - File.mtime(APPROVAL_FLAG)
    if age < 300
      File.delete(APPROVAL_FLAG)
      exit 0  # Approved — allow the post
    else
      File.delete(APPROVAL_FLAG)
      # Fall through to block — stale approval
    end
  end
  warn '🔴 BLOCKED: Public GitHub interaction without user approval'
  warn '   This posts publicly as MrSaneApps. Show the user a draft first.'
  warn ''
  warn '   ✅ Show the draft text to the user, get explicit approval, then post.'
  warn '   Then touch /tmp/.gh_post_approved before running the command.'
  exit 2
end

exit 0
