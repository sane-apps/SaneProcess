#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_email_guard.rb — PreToolUse hook
# Blocks manual curl to email APIs. Forces use of check-inbox.sh.
#
# BLOCKS:
#   - Direct curl to email-api.saneapps.com
#   - Direct curl to api.resend.com for email operations
#   - Direct curl to email-api.saneapps.com/api/send-reply
#
# ALLOWS:
#   - check-inbox.sh subcommands (the proper way)
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

# Block 1: Direct curl to email Worker API
if command.match?(/curl\s.*email-api\.saneapps\.com/)
  warn '🔴 BLOCKED: Direct curl to email API'
  warn '   Manual curl to the email API is error-prone and misses emails.'
  warn ''
  warn '   ✅ Use instead:'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh           # Full inbox report'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh read <id> # Read one email'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh reply <id> <body_file>'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh resolve <id>'
  warn '      ~/SaneApps/infra/scripts/check-inbox.sh resolve-batch <id1,id2,...>'
  warn ''
  warn '   Or use the /check-inbox command for the full workflow.'
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
