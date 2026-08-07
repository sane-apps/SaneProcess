#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor stop adapter → force one follow-up when GUI click lacked a feedback poll.
# Must be conversation-scoped — global/workspace pending leaked across chats.

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

followup = SaneGuiFeedback.cursor_stop_followup(
  status: payload['status'],
  loop_count: payload['loop_count'],
  conversation_id: payload['conversation_id'] || payload['conversationId']
)

if followup
  puts({ followup_message: followup }.to_json)
else
  puts '{}'
end
exit 0
