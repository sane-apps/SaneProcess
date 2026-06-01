#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_email_guard.rb — PreToolUse hook
# Blocks manual curl to email APIs. Forces use of check-inbox.sh.
# Enforces draft-review-approve-send cycle for all customer emails.
#
# SEND GATE (the important part):
#   - Every reply/compose MUST have an approval flag that:
#     1. Contains the SHA-256 hash of the exact email body being sent
#     2. Was created at least 3 seconds before the send (can't be same command chain)
#   - This means Claude MUST: write draft → show user → wait for "send" → set flag → send
#   - Claude CANNOT: write draft + set flag + send in one shot
#
# FORMAT CHECK:
#   - Checks email format (thanks, signoff, etc.)
#   - Can be overridden with /tmp/.email_format_override when user explicitly approves
#
# BLOCKS:
#   - Direct curl POST/PUT to email-api.saneapps.com
#   - Direct curl POST to api.resend.com
#
# ALLOWS:
#   - check-inbox.sh subcommands (the proper way)
#   - GET requests to email-api.saneapps.com (reads are fine)

require 'json'
require 'shellwords'
require 'digest'

EMAIL_APPROVAL_FLAG = '/tmp/.email_post_approved'
EMAIL_BATCH_APPROVAL_FLAG = '/tmp/.email_batch_post_approved.json'
EMAIL_FORMAT_OVERRIDE = '/tmp/.email_format_override'
EMAIL_APPROVAL_TTL_SECONDS = 300
EMAIL_BATCH_APPROVAL_TTL_SECONDS = 43_200
EMAIL_APPROVAL_MIN_AGE_SECONDS = 3
CORPORATE_WE_PATTERN = /\b(?:we|we['']re|we['']ll|we['']ve|our|us)\b/i
APPRECIATION_PATTERN = /\b(?:thank(s| you)?|appreciat(e|ion|ing)|grateful)\b/i
HELPING_MAKE_PATTERN = /\bhelping make\b.*\bbetter\b/i
MR_SANE_SIGNOFF_PATTERN = /\bMr\.?\s+Sane\b/
STANDARD_EMAIL_SIGNOFF_PATTERN = /(?:^|\n)Mr\.?\s+Sane\s*(?:\nhttps:\/\/saneapps\.com)?\s*\z/i

def email_format_valid?(body)
  text = body.to_s
  stripped = text.strip
  return false if stripped.empty?

  first_chunk = stripped[0, 260] || ''
  last_chunk = stripped[-320, 320] || stripped

  opens_with_appreciation = first_chunk.match?(APPRECIATION_PATTERN)
  closes_with_appreciation = last_chunk.match?(APPRECIATION_PATTERN)
  has_signoff = stripped.match?(STANDARD_EMAIL_SIGNOFF_PATTERN)

  opens_with_appreciation && closes_with_appreciation && has_signoff
end

# Verify the approval flag exists, matches the body hash, and is old enough
# that it couldn't have been created in the same command chain as the send.
def verify_approval(body)
  return [false, 'No approval flag found'] unless File.exist?(EMAIL_APPROVAL_FLAG)

  age = Time.now - File.mtime(EMAIL_APPROVAL_FLAG)
  if age > EMAIL_APPROVAL_TTL_SECONDS
    cleanup_flag(EMAIL_APPROVAL_FLAG)
    return [false, 'Approval flag expired (>5 min old)']
  end

  if age < EMAIL_APPROVAL_MIN_AGE_SECONDS
    return [false, "Approval flag too fresh (#{age.round(1)}s old, need #{EMAIL_APPROVAL_MIN_AGE_SECONDS}s). Cannot approve and send in the same step."]
  end

  stored_hash = File.read(EMAIL_APPROVAL_FLAG).strip
  body_hash = Digest::SHA256.hexdigest(body.strip)

  if stored_hash != body_hash
    cleanup_flag(EMAIL_APPROVAL_FLAG)
    return [false, 'Draft was modified after approval. Must re-approve.']
  end

  # Valid — do NOT consume here; let check-inbox.sh handle cleanup.
  # The flag has a 5-minute TTL so it won't linger.
  [true, nil]
end

def verify_batch_approval(body, to_addr, subject)
  return [false, 'No batch approval flag found'] unless File.exist?(EMAIL_BATCH_APPROVAL_FLAG)

  begin
    payload = JSON.parse(File.read(EMAIL_BATCH_APPROVAL_FLAG))
  rescue JSON::ParserError
    return [false, 'Batch approval file is invalid']
  end

  created_at = payload['created_at'].to_i
  return [false, 'Batch approval is malformed'] if created_at <= 0

  age = Time.now.to_i - created_at
  return [false, 'Batch approval expired'] if age > EMAIL_BATCH_APPROVAL_TTL_SECONDS
  return [false, "Batch approval too fresh (#{age}s old, need #{EMAIL_APPROVAL_MIN_AGE_SECONDS}s)"] if age < EMAIL_APPROVAL_MIN_AGE_SECONDS

  remaining = payload['remaining']
  return [false, 'Batch approval entries missing'] unless remaining.is_a?(Array)

  body_hash = Digest::SHA256.hexdigest(body.strip)
  match = remaining.any? do |item|
    item['to'].to_s.strip.downcase == to_addr.to_s.strip.downcase &&
      item['subject'].to_s == subject.to_s &&
      item['body_hash'].to_s == body_hash
  end

  return [false, 'Email not in approved batch'] unless match

  [true, nil]
end

def cleanup_flag(path)
  File.delete(path)
rescue Errno::ENOENT
  # already gone
end

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

# Block Claude from touching the approval flag directly in a send command chain.
# The flag must be set in a SEPARATE tool call from the send.
if command.include?('.email_post_approved') && command.include?('check-inbox.sh')
  warn '🔴 BLOCKED: Cannot set approval flag and send in the same command'
  warn '   The approval flag must be set in a separate step from sending.'
  warn '   Step 1: Show the user the final draft'
  warn '   Step 2: User says "send"'
  warn '   Step 3: Set approval flag (separate command)'
  warn '   Step 4: Send the email (separate command)'
  exit 2
end

# check-inbox.sh reply/compose must be explicitly approved and validated.
if command.include?('check-inbox.sh')
  tokens = Shellwords.split(command)
  script_idx = tokens.index { |t| t.end_with?('check-inbox.sh') }
  subcommand = script_idx ? tokens[script_idx + 1] : nil

  if %w[reply compose].include?(subcommand)
    body_file_idx = subcommand == 'reply' ? script_idx + 3 : script_idx + 4
    body_file = tokens[body_file_idx]

    if body_file.nil? || body_file.strip.empty?
      warn '🔴 BLOCKED: Missing email body file'
      warn '   check-inbox.sh reply/compose requires a real body file path.'
      exit 2
    end

    # Strip --force flag from body file path
    body_file = body_file.sub(/\A--force\z/, '')
    if body_file.empty?
      body_file = tokens[body_file_idx + 1] if tokens[body_file_idx + 1]
    end

    unless File.exist?(body_file)
      warn '🔴 BLOCKED: Email body file not found'
      warn "   Could not read: #{body_file}"
      exit 2
    end

    body = File.read(body_file)

    # === CHECK 1: No corporate "we" language ===
    if body.match?(CORPORATE_WE_PATTERN)
      warn '🔴 BLOCKED: "we/us/our" language in customer email'
      warn '   Use first-person singular only: I/me/my.'
      exit 2
    end

    # === CHECK 1b: UI paths must be verified against actual code ===
    # If the email mentions a UI navigation path (Settings > X), the hook itself
    # greps the project's Swift code for tab/case enums to verify the label exists.
    # NO flag-based self-certification — Claude will just bullshit past flags.
    ui_path_pattern = /(?:Settings|Preferences|Menu|Options)\s*[>→›»]\s*(\w+)/i
    ui_matches = body.scan(ui_path_pattern).flatten.map(&:strip)
    unless ui_matches.empty?
      # Find the project's Swift files by walking up from cwd or checking known app paths
      app_roots = Dir.glob(File.expand_path('~/SaneApps/apps/*/'))
      all_tab_labels = []
      app_roots.each do |root|
        # Look for SettingsView, tab enums, sidebar labels — the ACTUAL UI labels
        settings_files = Dir.glob(File.join(root, '**/*Settings*.swift')) +
                         Dir.glob(File.join(root, '**/SettingsView.swift'))
        settings_files.uniq.each do |f|
          content = File.read(f) rescue next
          # Match: case xxx = "Label" (enum raw values — these are what users see)
          content.scan(/case\s+\w+\s*=\s*"([^"]+)"/).flatten.each { |label| all_tab_labels << label }
          # Match: .navigationTitle("Label")
          content.scan(/\.navigationTitle\("([^"]+)"\)/).flatten.each { |label| all_tab_labels << label }
          # Match: Text("Label") inside tab/sidebar context
          content.scan(/Label\("([^"]+)"/).flatten.each { |label| all_tab_labels << label }
        end
      end
      all_tab_labels.uniq!

      ui_matches.each do |mentioned|
        unless all_tab_labels.any? { |real| real.casecmp(mentioned) == 0 }
          warn '🔴 BLOCKED: Email mentions UI path that does not exist in code'
          warn "   \"#{mentioned}\" not found in any SettingsView tab/enum across SaneApps"
          warn ''
          warn "   Actual tab labels found: #{all_tab_labels.sort.join(', ')}"
          warn ''
          warn '   Fix the path in your draft before sending.'
          warn '   This hook greps real code — you cannot flag your way past it.'
          exit 2
        end
      end
    end

    # === CHECK 2: Email format (can be overridden) ===
    format_override = File.exist?(EMAIL_FORMAT_OVERRIDE) &&
                      (Time.now - File.mtime(EMAIL_FORMAT_OVERRIDE)) < EMAIL_APPROVAL_TTL_SECONDS
    if format_override
      # Do NOT consume here — the send may still fail downstream (reconciliation, etc.).
      # Let TTL handle expiry, same as the approval flag (line 78-80).
      warn '⚠️  Email format override: user approved non-standard format'
    elsif !email_format_valid?(body)
      warn '🔴 BLOCKED: Email format must match your standard'
      warn '   Required structure:'
      warn '   1) Open with thanks or appreciation'
      warn '   2) Close with thanks or appreciation'
      warn '   3) End with "Mr. Sane"'
      warn '      Optional final line: "https://saneapps.com"'
      warn ''
      warn '   User can override: touch /tmp/.email_format_override'
      exit 2
    end

    # === CHECK 3: Approval gate (the big one) ===
    # The approval flag must:
    #   - Exist
    #   - Contain SHA-256 hash of the exact body being sent
    #   - Be at least 3 seconds old (proves it wasn't set in same command chain)
    #   - Be less than 5 minutes old (not stale)
    approved, reason = verify_approval(body)
    unless approved
      # Fall back to batch approval if individual approval absent
      compose_to = subcommand == 'compose' ? tokens[script_idx + 2] : nil
      compose_subject = subcommand == 'compose' ? tokens[script_idx + 3] : nil

      if compose_to && compose_subject
        batch_approved, _batch_reason = verify_batch_approval(body, compose_to, compose_subject)
      end

      unless batch_approved
        warn '🔴 BLOCKED: Email not approved for sending'
        warn "   #{reason}"
        warn ''
        warn '   Required workflow:'
        warn '   1. Write the draft to a file'
        warn '   2. Show the EXACT final text to the user'
        warn '   3. User says "send"'
        warn '   4. Set approval: echo "<sha256 of body>" > /tmp/.email_post_approved'
        warn '   5. Send (separate command)'
        exit 2
      end
    end
  end

  exit 0
end

# Block 1: Direct curl WRITE operations to email Worker API
if command.match?(/curl\s.*email-api\.saneapps\.com/) && command.match?(/-X\s*(POST|PUT|DELETE)|--data|-d\s/)
  warn '🔴 BLOCKED: Direct write to email API'
  warn '   Sending/modifying via curl directly bypasses check-inbox.sh tracking.'
  warn ''
  warn '   ✅ Use instead:'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh reply <id> <body_file>'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh compose <to> <subject> <body_file>'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh resolve <id>'
  warn ''
  warn '   Read operations (GET) are allowed — this only blocks writes.'
  exit 2
end

# Block 2: Direct curl to Resend API for sending emails
if command.match?(/curl\s.*api\.resend\.com\/emails/) && command.match?(/-X\s*POST|--data|-d\s/)
  warn '🔴 BLOCKED: Direct email send via Resend API'
  warn '   Sending via Resend directly bypasses the Worker tracking system.'
  warn '   Replies won\'t be recorded in D1 and the email will show as unresolved.'
  warn ''
  warn '   ✅ Use instead:'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh reply <id> <body_file>'
  warn '   This sends via the Worker API which tracks the reply in D1.'
  exit 2
end

exit 0
