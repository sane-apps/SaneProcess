#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor afterShellExecution adapter → SaneProcess GUI feedback loop.
# Fail open on any error so a broken hook never blocks the agent loop.
# State is scoped by conversation_id so chats cannot steal each other's pending.

require 'json'

HELPER = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks/core/gui_feedback.rb')

begin
  require HELPER
rescue LoadError
  puts '{}'
  exit 0
end

payload = begin
  JSON.parse(STDIN.read.to_s)
rescue JSON::ParserError
  {}
end

command = payload['command'] ||
          payload.dig('input', 'command') ||
          payload.dig('toolInput', 'command') ||
          payload.dig('tool_input', 'command') ||
          ''
output = payload['output'] ||
         payload['stdout'] ||
         payload['toolResult'] ||
         payload['tool_result'] ||
         ''
conversation_id = payload['conversation_id'] || payload['conversationId']

result = begin
  SaneGuiFeedback.cursor_after_shell_payload(
    command: command,
    output: output,
    conversation_id: conversation_id
  )
rescue StandardError
  nil
end
puts((result || {}).to_json)
exit 0
