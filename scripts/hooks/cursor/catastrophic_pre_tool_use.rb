#!/usr/bin/env ruby
# frozen_string_literal: true

# Cursor preToolUse → catastrophic guard for MCP/tool names and shell commands.

require 'json'
require 'open3'

HOOK = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks/sane_catastrophic_guard.rb')

payload = $stdin.read.to_s
_out, err, status = Open3.capture3('ruby', HOOK, stdin_data: payload)
if status.exitstatus == 2
  puts({
    permission: 'deny',
    user_message: err.to_s.strip.empty? ? 'Blocked by SaneApps catastrophic guard.' : err.to_s.strip
  }.to_json)
  exit 0
end

puts({ permission: 'allow' }.to_json)
exit 0
