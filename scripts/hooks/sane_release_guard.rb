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

require 'digest'
require 'json'
require 'shellwords'

SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneScan SaneSync SaneVideo].freeze
SANE_APP_PATTERN = Regexp.new(SANE_APPS.join('|'), Regexp::IGNORECASE)
# R2 bucket pattern — all apps use shared bucket (sanebar-downloads) but match any *-downloads to catch mistakes
SANE_BUCKET_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-downloads" }.join('|'))
# Cloudflare Pages project names (e.g. sanebar-site, saneclip-site)
SANE_PAGES_PATTERN = Regexp.new(SANE_APPS.map { |a| "#{a.downcase}-site" }.join('|'))
# dist.*.com domains
SANE_DIST_PATTERN = Regexp.new(SANE_APPS.map { |a| "dist\\.#{a.downcase}\\.com" }.join('|'))
CORPORATE_WE_PATTERN = /\b(?:we|we['’]re|we['’]ll|we['’]ve|our|us)\b/i
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

def scrub_quoted_literals(command)
  command.to_s.gsub(/'[^']*'/, "''").gsub(/"[^"]*"/, '""')
end

def gh_public_command_direct?(command)
  # Blank quoted strings first so a command that merely MENTIONS gh inside a quoted
  # argument (e.g. `git commit -m "fix: gh issue edit ..."`) is not mistaken for an
  # actual gh invocation. A real gh command has its verb OUTSIDE quotes, so it still matches.
  scan = scrub_quoted_literals(command)
  scan.match?(/\bgh\s+(?:issue|pr)\s+(?:comment|close|review|create|edit)\b/) ||
    scan.match?(/\bgh\s+api\b.*(?:^|[\s\/])repos\/(?:sane-apps|mrsaneapps)\//i)
end

def shell_wrapper_payloads(command)
  tokens = shell_tokens(command)
  return [] if tokens.empty?

  command_name = File.basename(tokens.first.to_s)
  case command_name
  when 'bash', 'sh', 'zsh'
    command_index = nil
    tokens[1..].to_a.each_with_index do |token, offset|
      if token.start_with?('-')
        if token.include?('c')
          command_index = offset + 2
          break
        end
      else
        break
      end
    end
    command_index && tokens[command_index] ? [tokens[command_index]] : []
  when 'ssh'
    index = 1
    options_with_values = %w[-b -c -D -E -F -I -i -J -L -l -m -O -o -p -R -S -W].freeze
    while index < tokens.length
      token = tokens[index].to_s
      if token == '--'
        index += 1
        break
      elsif token.start_with?('-')
        index += options_with_values.include?(token) ? 2 : 1
      else
        index += 1 # host
        break
      end
    end
    payload = tokens[index..].to_a.join(' ').strip
    payload.empty? ? [] : [payload]
  else
    []
  end
rescue StandardError
  []
end

def public_gh_command_for(command, depth = 0)
  return nil if depth > 4
  return command if gh_public_command_direct?(command)

  shell_wrapper_payloads(command).each do |payload|
    match = public_gh_command_for(payload, depth + 1)
    return match if match
  end

  nil
end

def gh_public_command?(command)
  !public_gh_command_for(command).nil?
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

def normalized_gh_metadata_command(command)
  return nil unless gh_metadata_only_edit?(command)

  tokens = shell_tokens(command)
  gh_index = tokens.index('gh')
  return nil unless gh_index

  gh_tokens = tokens[gh_index..]
  Digest::SHA256.hexdigest(gh_tokens.join("\0"))
end

def consume_github_approval(public_text, metadata_command_hash: nil)
  return :missing unless File.exist?(APPROVAL_FLAG)

  payload = JSON.parse(File.read(APPROVAL_FLAG, encoding: Encoding::UTF_8))
  File.delete(APPROVAL_FLAG)
  age = Time.now.to_i - payload['created_at'].to_i
  approval_present = payload['created_at'].to_i.positive? &&
                     age >= 0 &&
                     age < GITHUB_APPROVAL_TTL_SECONDS &&
                     !payload['user_approval'].to_s.strip.empty?
  return :stale unless approval_present

  # Metadata-only edits (labels/assignees/milestone) post NO public text, so there is
  # nothing to body-hash. Scope approval to the exact normalized gh edit command so a
  # token for one issue/label cannot authorize another metadata mutation in the TTL.
  if metadata_command_hash
    expected = payload['metadata_command_hash'].to_s
    return :valid if payload['approval_type'] == 'github_metadata' &&
                     !expected.empty? &&
                     expected == metadata_command_hash
    return :body_mismatch
  end

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

# Block 12: Manual altool uploads for SaneApps (must go through release.sh)
if command.match?(/\baltool\s+--upload-app/) && (command.match?(SANE_APP_PATTERN) || saneprocess_command_context?(command))
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

  public_command = public_gh_command_for(command) || command
  public_text = extract_gh_public_text(public_command)
  if public_text.match?(CORPORATE_WE_PATTERN)
    warn '🔴 BLOCKED: "we/us/our" language in public GitHub post'
    warn '   SaneApps is one person. Use: I/me/my.'
    warn ''
    warn '   ✅ Rewrite draft in first-person singular, then retry.'
    exit 2
  end

  metadata_command_hash = normalized_gh_metadata_command(public_command)
  approval_status = consume_github_approval(public_text, metadata_command_hash: metadata_command_hash)
  if approval_status == :valid
    exit 0  # Approved — allow the post
  end
  warn '🔴 BLOCKED: Public GitHub interaction without user approval'
  warn '   Approval must match the exact final public text.' if approval_status == :body_mismatch
  warn '   This posts publicly as MrSaneApps. Show the user a draft first.'
  warn ''
  warn '   ✅ Show the draft text to the user, get explicit approval, then post.'
  if metadata_command_hash
    warn '   For metadata-only edits, run: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb github_post_approval --metadata-command "<exact gh issue/pr edit command>" --user-approval "<quote>"'
  else
    warn '   Then run: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb github_post_approval --body-file <draft_file> --user-approval "<quote>"'
  end
  exit 2
end

exit 0
