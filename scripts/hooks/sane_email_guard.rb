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

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']
exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

# Always allow check-inbox.sh invocations
exit 0 if command.include?('check-inbox.sh')

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
