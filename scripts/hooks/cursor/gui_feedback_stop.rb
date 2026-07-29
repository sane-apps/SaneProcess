#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor stop adapter → force one follow-up when GUI click lacked a feedback poll.

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

followup = SaneGuiFeedback.cursor_stop_followup(
  status: payload['status'],
  loop_count: payload['loop_count']
)

if followup
  puts({ followup_message: followup }.to_json)
else
  puts '{}'
end
exit 0
