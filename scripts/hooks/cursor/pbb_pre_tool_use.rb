#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor preToolUse → SanePBBGuard for translations build_book.py anti-patterns.

require 'json'

GUARD = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks/sane_pbb_guard.rb')
require GUARD

payload = begin
  JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue JSON::ParserError
  {}
end

tool = (payload['tool_name'] || payload['toolName'] || payload.dig('tool', 'name') || '').to_s
input = payload['tool_input'] || payload['input'] || payload['arguments'] || {}
path = (input['file_path'] || input['path'] || input['target_notebook'] || '').to_s

edit_like = tool.match?(/\A(?:Write|Edit|NotebookEdit|write|edit|StrReplace|WriteFile|search_replace)\z/i)
unless edit_like && !path.strip.empty?
  puts({ permission: 'allow' }.to_json)
  exit 0
end

content = [
  input['contents'],
  input['content'],
  input['new_string'],
  input['new_str'],
  input['old_string'] # catch replacements that reintroduce banned text
].compact.join("\n")

if (reason = SanePBBGuard.violation_for(path, content))
  puts({
    permission: 'deny',
    user_message: "🔴 BLOCKED: Logos PBB markup guard\n#{reason}\nSee clients/translations/docs/LOGOS_MARKUP.md"
  }.to_json)
  exit 0
end

puts({ permission: 'allow' }.to_json)
exit 0
