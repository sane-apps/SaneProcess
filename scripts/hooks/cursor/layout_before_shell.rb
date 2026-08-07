#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor beforeShellExecution → SaneLayoutGuard / sane_bash_guards layout checks.
# Blocks Mini path fragmentation from shell mutations.

require 'json'
require 'open3'

HOOK = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks/sane_bash_guards.rb')

payload = begin
  JSON.parse($stdin.read.to_s)
rescue JSON::ParserError
  {}
end

command = payload['command'] || payload.dig('input', 'command') || payload.dig('tool_input', 'command') || ''
if command.to_s.strip.empty?
  puts({ permission: 'allow' }.to_json)
  exit 0
end

claude_payload = {
  'tool_name' => 'Bash',
  'tool_input' => { 'command' => command }
}

_out, err, status = Open3.capture3('ruby', HOOK, stdin_data: JSON.generate(claude_payload))
if status.exitstatus == 2
  puts({
    permission: 'deny',
    user_message: err.to_s.strip.empty? ? 'Blocked by SaneApps layout / bash guards.' : err.to_s.strip
  }.to_json)
  exit 0
end

puts({ permission: 'allow' }.to_json)
exit 0
