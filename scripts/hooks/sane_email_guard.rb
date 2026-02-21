#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_email_guard.rb — PreToolUse hook
# Blocks manual curl to email APIs. Forces use of check-inbox.sh.
#
# BLOCKS:
#   - Direct curl POST/PUT to email-api.saneapps.com (send-reply, compose, status changes)
#   - Direct curl POST to api.resend.com (sending emails bypasses Worker tracking)
#
# ALLOWS:
#   - check-inbox.sh subcommands (the proper way)
#   - GET requests to email-api.saneapps.com (reads are fine)
#   - Non-email curl commands

require 'json'
require 'shellwords'

EMAIL_APPROVAL_FLAG = '/tmp/.email_post_approved'
EMAIL_APPROVAL_TTL_SECONDS = 300
CORPORATE_WE_PATTERN = /\b(?:we|we['’]re|we['’]ll|we['’]ve|our|us)\b/i
THANK_PATTERN = /\bthank(s| you)?\b/i
HELPING_MAKE_PATTERN = /\bhelping make\b.*\bbetter\b/i
MR_SANE_SIGNOFF_PATTERN = /\bMr\.?\s+Sane\b/

def email_format_valid?(body)
  text = body.to_s
  stripped = text.strip
  return false if stripped.empty?

  first_chunk = stripped[0, 260] || ''
  last_chunk = stripped[-320, 320] || stripped

  opens_with_thanks = first_chunk.match?(THANK_PATTERN)
  has_two_thanks = text.scan(THANK_PATTERN).length >= 2
  closes_with_thanks = last_chunk.match?(THANK_PATTERN)
  has_helping_make_better = text.match?(HELPING_MAKE_PATTERN)
  has_signoff = last_chunk.match?(MR_SANE_SIGNOFF_PATTERN)

  opens_with_thanks && has_two_thanks && closes_with_thanks && has_signoff
end

def consume_email_approval_flag
  return false unless File.exist?(EMAIL_APPROVAL_FLAG)

  age = Time.now - File.mtime(EMAIL_APPROVAL_FLAG)
  begin
    File.delete(EMAIL_APPROVAL_FLAG)
  rescue Errno::ENOENT
    return false
  end
  age < EMAIL_APPROVAL_TTL_SECONDS
rescue StandardError
  false
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

    unless File.exist?(body_file)
      warn '🔴 BLOCKED: Email body file not found'
      warn "   Could not read: #{body_file}"
      exit 2
    end

    body = File.read(body_file)

    if body.match?(CORPORATE_WE_PATTERN)
      warn '🔴 BLOCKED: "we/us/our" language in customer email'
      warn '   Use first-person singular only: I/me/my.'
      exit 2
    end

    unless email_format_valid?(body)
      warn '🔴 BLOCKED: Email format must match your standard'
      warn '   Required structure:'
      warn '   1) Open with thanks'
      warn '   2) Two thank-you mentions'
      warn '   3) Close with thanks'
      warn '   4) End with "Mr. Sane"'
      exit 2
    end

    # Approval flag check lives in check-inbox.sh only.
    # Do NOT consume the flag here — double-consumption bug
    # causes check-inbox.sh to fail even when flag is set.
  end

  exit 0
end

# Block 1: Direct curl WRITE operations to email Worker API
# GET/read is fine — only block POST/PUT/DELETE (sending, composing, status changes)
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
# (Reading from Resend is fine, but sending bypasses the Worker's tracking)
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
