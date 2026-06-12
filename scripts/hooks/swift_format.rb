#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

# PostToolUse hook: auto-format Swift files after Write/Edit
# Inspired by Boris Cherny's bun format hook - fixes the last 10% that causes CI failures

require 'json'

begin
  input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
  tool_input = input['tool_input'] || {}
  file_path = tool_input['file_path']

  if file_path && file_path.end_with?('.swift') && File.exist?(file_path)
    # swiftformat is fast on single files (~50ms), won't slow down the hook
    system('swiftformat', file_path, '--quiet', '--swiftversion', '5.9')
    # Also run swiftlint autocorrect for fixable violations
    system('swiftlint', 'lint', '--fix', '--quiet', file_path)
  end
rescue StandardError
  # Never block on format errors
end

exit 0
