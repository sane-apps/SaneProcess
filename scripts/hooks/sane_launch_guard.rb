#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

# sane_launch_guard.rb — PreToolUse hook
# Blocks improper app launches. Forces use of sane_test.rb.
#
# BLOCKS:
#   - Direct binary execution (Contents/MacOS/<SaneApp>)
#   - Manual `open *.app` for SaneApps without sane_test.rb
#
# ALLOWS:
#   - `ruby scripts/sane_test.rb <AppName>` (the proper way)
#   - Non-SaneApp commands

require 'json'
require 'socket'

SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo].freeze
SANE_APP_PATTERN = Regexp.new(SANE_APPS.join('|'))
LOCAL_UI_TOOL_PATTERN = Regexp.union(
  /^mcp__computer_use__/,
  /^computer-use\./,
  /^mcp__browser__/,
  /^browser\./
).freeze
LOCAL_UI_APPROVAL = 'MR. SANE APPROVES LOCAL UI ON AIR'
MINI_UNAVAILABLE_APPROVAL = 'MR. SANE CONFIRMS MINI UNAVAILABLE'
LOCAL_DASHBOARD_OPEN_PATTERN = Regexp.union(
  %r{\bopen\b.*https?://(?:app|auth)\.lemonsqueezy\.com}i,
  %r{\bopen\b.*https?://(?:appstoreconnect|developer|idmsa)\.apple\.com}i,
  %r{\bopen\b.*LemonSqueezy-Uploads}i
).freeze

def running_on_macbook_air?
  return true if ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] == '1'
  return false if ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] == '1'

  !Socket.gethostname.to_s.downcase.include?('mini')
rescue StandardError
  true
end

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name']

if tool_name.to_s.match?(LOCAL_UI_TOOL_PATTERN) &&
   running_on_macbook_air? &&
   ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] != LOCAL_UI_APPROVAL &&
   ENV['SANE_MINI_UNAVAILABLE'] != MINI_UNAVAILABLE_APPROVAL
  target = (input['tool_input'] || {})['app'] ||
           (input['tool_input'] || {})['application'] ||
           (input['tool_input'] || {})['url'] ||
           'local UI'
  warn '🔴 BLOCKED: Local MacBook UI control'
  warn "   Tool: #{tool_name}"
  warn "   Target: #{target}"
  warn ''
  warn '   ✅ Use the Mac Mini for SaneApps UI/browser/release work.'
  warn '   Use ssh mini, SaneMaster, sane_test.rb, or Mini-side automation.'
  warn ''
  warn "   Fallback requires explicit approval via SANE_MINI_UNAVAILABLE='#{MINI_UNAVAILABLE_APPROVAL}'"
  exit 2
end

exit 0 unless tool_name == 'Bash'

command = (input['tool_input'] || {})['command'].to_s
exit 0 if command.empty?

if command.match?(LOCAL_DASHBOARD_OPEN_PATTERN) &&
   running_on_macbook_air? &&
   ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] != LOCAL_UI_APPROVAL &&
   ENV['SANE_MINI_UNAVAILABLE'] != MINI_UNAVAILABLE_APPROVAL
  warn '🔴 BLOCKED: Mini-first SaneApps dashboard/file open'
  warn "   Command: #{command}"
  warn ''
  warn '   ✅ Use Mini Safari/Finder for Lemon Squeezy, App Store Connect, and release upload artifacts.'
  warn '   Examples:'
  warn '     ~/SaneApps/infra/SaneProcess/scripts/mini/mini-safari.sh open-current <url>'
  warn "     ssh mini 'open -R /path/on/mini'"
  exit 2
end

# Always allow sane_test.rb invocations
exit 0 if command.include?('sane_test.rb')

# Block 1: Direct binary execution (breaks TCC)
if command.match?(%r{Contents/MacOS/(#{SANE_APP_PATTERN})})
  warn '🔴 BLOCKED: Direct binary execution of SaneApp'
  warn '   Running the binary directly breaks TCC permission grants.'
  warn ''
  warn '   ✅ Use instead: ruby scripts/sane_test.rb <AppName>'
  warn '   This resets TCC, builds fresh, deploys to mini, and launches via `open`.'
  exit 2
end

# Block 2: Manual `open` of a SaneApp .app bundle
# Matches: open ~/Applications/SaneBar.app, open /tmp/SaneClip.app, ssh mini 'open ...'
if command.match?(/open\s+.*\b(#{SANE_APP_PATTERN})\.app\b/)
  warn '🔴 BLOCKED: Manual launch of SaneApp'
  warn '   Launching without TCC reset causes stale permissions.'
  warn ''
  warn '   ✅ Use instead: ruby scripts/sane_test.rb <AppName>'
  warn '   Handles: kill → clean → TCC reset → build → deploy → launch → logs'
  exit 2
end

exit 0
