#!/usr/bin/env ruby
# frozen_string_literal: true

# sane_launch_guard.rb — PreToolUse hook
# Blocks improper app launch/build/test paths. Forces canonical SaneMaster paths.
#
# BLOCKS:
#   - Direct binary execution (Contents/MacOS/<SaneApp>)
#   - Manual `open *.app` for SaneApps without sane_test.rb
#   - Raw build/test commands inside SaneApps app repos
#
# ALLOWS:
#   - `ruby scripts/sane_test.rb <AppName>` (the proper way)
#   - `ruby scripts/SaneMaster.rb verify|test_mode|launch`
#   - Non-SaneApp commands

require 'json'
require 'socket'
require_relative 'core/hook_payload'
require_relative 'core/local_ui_guard'

SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneScan SaneSync SaneVideo].freeze
SANE_APP_PATTERN = Regexp.new(SANE_APPS.join('|'))
# Shared with sanetools_checks.rb via core/local_ui_guard.rb
LOCAL_UI_TOOL_PATTERN = SaneLocalUIGuard::LOCAL_UI_TOOL_PATTERN
LOCAL_UI_APPROVAL = SaneLocalUIGuard::LOCAL_UI_APPROVAL
MINI_UNAVAILABLE_APPROVAL = SaneLocalUIGuard::MINI_UNAVAILABLE_APPROVAL
LOCAL_DASHBOARD_OPEN_PATTERN = Regexp.union(
  %r{\bopen\b.*https?://(?:app|auth)\.lemonsqueezy\.com}i,
  %r{\bopen\b.*https?://(?:appstoreconnect|developer|idmsa)\.apple\.com}i,
  %r{\bopen\b.*LemonSqueezy-Uploads}i
).freeze
COMMAND_CHAIN_PATTERN = /(?:;|&&|\|\||\n)/
READ_ONLY_XCODEBUILD_PATTERN = /
  \bxcodebuild\b
  (?=.*\s-(?:list|version|showsdks|showBuildSettings)\b)
/ix
RAW_APP_BUILD_TEST_PATTERN = Regexp.union(
  /\bxcodebuild\b/i,
  /\bswift\s+(?:build|test|run)\b/i,
  /\bfastlane\s+(?:scan|test|gym|build|beta|release)\b/i
).freeze
# Proven iOS TestFlight packaging lane (archive/export into outputs/artifacts/<N>/).
# Still blocks raw `xcodebuild test` / generic build — those stay on SaneMaster verify.
TESTFLIGHT_PACKAGING_PATTERN = /
  \bxcodebuild\b
  .*
  (?:\barchive\b|-exportArchive\b)
  .*
  outputs\/artifacts\/\d+
/ix
DESTRUCTIVE_CLEANUP_PATTERN = Regexp.union(
  /\brm\s+(?:-[^\s]*r[^\s]*f|-[^\s]*f[^\s]*r)\b.*(?:SaneApps|DerivedData|CoreSimulator|Simulator|\.saneprocess)/i,
  /\bkillall\b.*\b(?:Simulator|CoreSimulator|xcodebuild|SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneScan|SaneSync|SaneVideo)\b/i,
  /\bpkill\b.*\b(?:Simulator|CoreSimulator|xcodebuild|SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneScan|SaneSync|SaneVideo)\b/i
).freeze

def single_sane_test_command?(command)
  stripped = command.strip
  return false if stripped.match?(COMMAND_CHAIN_PATTERN)

  stripped.match?(/\A\s*(?:ruby\s+)?(?:\S+\/)?sane_test\.rb\b/)
end

def shell_unquote(value)
  text = value.to_s.strip
  if (text.start_with?('"') && text.end_with?('"')) ||
     (text.start_with?("'") && text.end_with?("'"))
    text[1..-2]
  else
    text
  end
end

def command_project_dir(command)
  if command =~ /\bcd\s+((?:"[^"]+"|'[^']+'|\S+))\s*(?:&&|;|\n)/
    return File.expand_path(shell_unquote(Regexp.last_match(1)))
  end

  if command =~ /\b-project\s+((?:"[^"]+\.xcodeproj"|'[^']+\.xcodeproj'|\S+\.xcodeproj))/
    return File.expand_path(File.dirname(shell_unquote(Regexp.last_match(1))))
  end

  Dir.pwd
rescue StandardError
  Dir.pwd
end

def saneapps_project?(project_dir)
  File.exist?(File.join(project_dir, '.saneprocess'))
end

def raw_app_build_test_command?(command)
  # Match against the unquoted command so tool names inside string arguments
  # (grep patterns, commit messages) cannot trigger the block.
  bare = SaneLocalUIGuard.strip_quoted(command)
  return false unless bare.match?(RAW_APP_BUILD_TEST_PATTERN)
  return false if bare.match?(READ_ONLY_XCODEBUILD_PATTERN)
  # Allow the iOS TestFlight packaging lane (archive/export → artifacts/<build>/).
  return false if bare.match?(TESTFLIGHT_PACKAGING_PATTERN)

  saneapps_project?(command_project_dir(command))
end

def canonical_cleanup_command?(command)
  stripped = command.strip
  return false if stripped.match?(COMMAND_CHAIN_PATTERN)

  stripped.match?(/\bSaneMaster(?:_standalone)?\.rb\s+(?:machine_cleanup|machine-cleanup|cleanup_machine|cleanup-machine)\b/) ||
    stripped.match?(/\btrash\b/)
end

def destructive_cleanup_command?(command)
  return false if canonical_cleanup_command?(command)

  SaneLocalUIGuard.strip_quoted(command).match?(DESTRUCTIVE_CLEANUP_PATTERN)
end

def running_on_macbook_air?
  SaneLocalUIGuard.running_on_macbook_air?
end

begin
  parsed = SaneHookPayload.parse($stdin.read.force_encoding(Encoding::UTF_8))
rescue Errno::ENOENT
  exit 0
end

tool_name = parsed['tool_name']

if tool_name.to_s.match?(LOCAL_UI_TOOL_PATTERN) &&
   running_on_macbook_air? &&
   ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] != LOCAL_UI_APPROVAL &&
   ENV['SANE_MINI_UNAVAILABLE'] != MINI_UNAVAILABLE_APPROVAL
  target = parsed['tool_input']['app'] ||
           parsed['tool_input']['application'] ||
           parsed['tool_input']['url'] ||
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

exit 0 unless SaneHookPayload.shell?(tool_name) || (tool_name.empty? && !parsed['command'].empty?)

command = parsed['command']
exit 0 if command.empty?

if command.match?(LOCAL_DASHBOARD_OPEN_PATTERN) &&
   running_on_macbook_air? &&
   ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] != LOCAL_UI_APPROVAL &&
   ENV['SANE_MINI_UNAVAILABLE'] != MINI_UNAVAILABLE_APPROVAL
  warn '🔴 BLOCKED: Mini-first SaneApps dashboard/file open'
  warn "   Command: #{command}"
  warn ''
  warn '   ✅ Use Brave on the Mini (Claude-in-Chrome widget / Codex Chrome lane) for Lemon Squeezy,'
  warn '      App Store Connect, and other dashboards; Mini Finder for release upload artifacts.'
  warn '      Never script Safari (owner retired the ASC Safari exception 2026-07-15).'
  warn "     ssh mini 'open -R /path/on/mini'"
  exit 2
end

# Always allow a single sane_test.rb invocation. Do not allow command chains
# that merely mention sane_test.rb before a manual app launch.
exit 0 if single_sane_test_command?(command)

if destructive_cleanup_command?(command)
  warn '🔴 BLOCKED: Non-canonical destructive cleanup path'
  warn "   Command: #{command}"
  warn ''
  warn '   Broad cleanup can kill active app/test work or permanently delete recoverable state.'
  warn '   ✅ Use instead: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb machine_cleanup --host mini --apply'
  warn '   For a single disposable path, use trash instead of rm -rf.'
  exit 2
end

if raw_app_build_test_command?(command)
  warn '🔴 BLOCKED: Non-canonical SaneApps build/test path'
  warn "   Command: #{command}"
  warn ''
  warn '   Raw xcodebuild/swift/fastlane commands can test stale checkouts or leave untracked runtime proof.'
  warn '   ✅ Use instead: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb verify'
  warn '   For runtime launch proof: ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb test_mode'
  warn '   These paths sync to the Mini, rebuild when needed, kill stale app instances, and write workflow receipts.'
  exit 2
end

# Block 1: Direct binary execution (breaks TCC)
if command.match?(%r{Contents/MacOS/(#{SANE_APP_PATTERN})})
  warn '🔴 BLOCKED: Direct binary execution of SaneApp'
  warn '   Running the binary directly breaks TCC permission grants.'
  warn ''
  warn '   ✅ Use instead: ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb <AppName>'
  warn '   This resets TCC, builds fresh, deploys to mini, and launches via `open`.'
  exit 2
end

# Block 2: Manual `open` of a SaneApp .app bundle
# Matches: open ~/Applications/SaneBar.app, open /tmp/SaneClip.app, ssh mini 'open ...'
if command.match?(/open\s+.*\b(#{SANE_APP_PATTERN})\.app\b/)
  warn '🔴 BLOCKED: Manual launch of SaneApp'
  warn '   Launching without TCC reset causes stale permissions.'
  warn ''
  warn '   ✅ Use instead: ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb <AppName>'
  warn '   Handles: kill → clean → TCC reset → build → deploy → launch → logs'
  exit 2
end

exit 0
