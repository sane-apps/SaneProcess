#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor afterShellExecution adapter → SaneProcess GUI feedback loop.
# Fail open on any error so a broken hook never blocks the agent loop.
# State is scoped by conversation_id so chats cannot steal each other's pending.

require 'json'
require_relative 'runtime_paths'

HELPER = SaneCursorRuntimePaths.hook('core/gui_feedback.rb')

begin
  raise LoadError unless HELPER && File.file?(HELPER)
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

command = payload['command'] || payload.dig('input', 'command') || ''
output = payload['output'] || payload['stdout'] || ''
conversation_id = payload['conversation_id'] || payload['conversationId']

result = SaneGuiFeedback.cursor_after_shell_payload(
  command: command,
  output: output,
  conversation_id: conversation_id
)
puts((result || {}).to_json)
exit 0
