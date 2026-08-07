#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor preToolUse → SaneLayoutGuard for Write/Edit path fragmentation.

require 'json'

GUARD = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks/sane_layout_guard.rb')
require GUARD

payload = begin
  JSON.parse($stdin.read.to_s)
rescue JSON::ParserError
  {}
end

tool = (payload['tool_name'] || payload['toolName'] || payload.dig('tool', 'name') || '').to_s
input = payload['tool_input'] || payload['input'] || payload['arguments'] || {}
path = input['file_path'] || input['path'] || input['target_notebook'] || ''

edit_like = tool.match?(/\A(?:Write|Edit|NotebookEdit|write|edit|StrReplace|WriteFile)\z/i) ||
            path.to_s.strip != '' && tool.match?(/write|edit|replace/i)

unless edit_like && !path.to_s.strip.empty?
  puts({ permission: 'allow' }.to_json)
  exit 0
end

if (reason = SaneLayoutGuard.violation_for_path(path))
  puts({
    permission: 'deny',
    user_message: "🔴 BLOCKED: Project layout violation\n#{reason}"
  }.to_json)
  exit 0
end

puts({ permission: 'allow' }.to_json)
exit 0
