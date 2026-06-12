#!/usr/bin/env ruby
# frozen_string_literal: true

# Shared Mini-first local-UI guard pieces used by both the gated PreToolUse
# chain (sanetools_checks.rb) and the ungated sane_launch_guard.rb. One copy,
# so the two enforcement planes cannot drift on what counts as local UI.
require 'socket'

module SaneLocalUIGuard
  # Live MCP servers register hyphenated names (mcp__computer-use__*,
  # mcp__Claude_in_Chrome__*); match both spellings or the block never fires.
  LOCAL_UI_TOOL_PATTERN = Regexp.union(
    /^mcp__computer[-_]use__/i,
    /^computer-use\./,
    /^mcp__browser__/,
    /^mcp__[A-Za-z_]*chrome[A-Za-z_]*__/i,
    /^browser\./
  ).freeze

  LOCAL_UI_APPROVAL = 'MR. SANE APPROVES LOCAL UI ON AIR'
  MINI_UNAVAILABLE_APPROVAL = 'MR. SANE CONFIRMS MINI UNAVAILABLE'
  MINI_SCREENSHOT_WRAPPER = '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh'

  module_function

  def local_ui_tool?(tool_name)
    tool_name.to_s.match?(LOCAL_UI_TOOL_PATTERN)
  end

  def approved_local_ui?
    ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] == LOCAL_UI_APPROVAL ||
      ENV['SANE_MINI_UNAVAILABLE'] == MINI_UNAVAILABLE_APPROVAL
  end

  def running_on_macbook_air?
    return true if ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] == '1'
    return false if ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] == '1'

    !Socket.gethostname.to_s.downcase.include?('mini')
  rescue StandardError
    true
  end

  # Strip quoted regions so tool names inside string arguments (grep patterns,
  # commit messages, echoed prose) cannot trigger build/cleanup blocks.
  def strip_quoted(command)
    command.gsub(/"(?:[^"\\]|\\.)*"/m, '').gsub(/'[^']*'/m, '')
  end
end
