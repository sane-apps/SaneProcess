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
  SANE_APP_PATTERN = /
    \b(?:SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneScan|SaneSync|SaneVideo)\b
  /x.freeze
  PASTEBOARD_PATTERN = /\b(?:pbcopy|pbpaste)\b/
  AIR_GUI_PATTERN = Regexp.union(
    /\bosascript\b/,
    /\bpeekaboo\b/,
    /\bCGEventPost\b/,
    /clip-hid\.py/,
    /clip-cmdkey\.py/
  ).freeze
  MINI_REMOTE_PATTERN = Regexp.union(
    /\bssh\s+\S*mini\b/i,
    /mini-gui-run\.sh/,
    /capture-mini-screenshot\.sh/
  ).freeze

  # Agents cannot set PreToolUse hook ENV from inside a Shell call. Honor the
  # same approval phrases when prefixed on the command itself so
  #   SANE_APPROVE_LOCAL_UI_ON_AIR='…' peekaboo …
  # unlocks Air-local UI after explicit owner approval (phrase must be exact).
  LOCAL_UI_APPROVAL_ASSIGNMENT = /
    (?:^|[\s;|&])(?:export\s+)?
    SANE_APPROVE_LOCAL_UI_ON_AIR=
    (?:'#{Regexp.escape(LOCAL_UI_APPROVAL)}'|"#{Regexp.escape(LOCAL_UI_APPROVAL)}")
  /x.freeze
  MINI_UNAVAILABLE_APPROVAL_ASSIGNMENT = /
    (?:^|[\s;|&])(?:export\s+)?
    SANE_MINI_UNAVAILABLE=
    (?:'#{Regexp.escape(MINI_UNAVAILABLE_APPROVAL)}'|"#{Regexp.escape(MINI_UNAVAILABLE_APPROVAL)}")
  /x.freeze

  module_function

  def local_ui_tool?(tool_name)
    tool_name.to_s.match?(LOCAL_UI_TOOL_PATTERN)
  end

  def command_approves_local_ui?(command)
    cmd = command.to_s
    cmd.match?(LOCAL_UI_APPROVAL_ASSIGNMENT) || cmd.match?(MINI_UNAVAILABLE_APPROVAL_ASSIGNMENT)
  end

  def approved_local_ui?(command = nil)
    ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] == LOCAL_UI_APPROVAL ||
      ENV['SANE_MINI_UNAVAILABLE'] == MINI_UNAVAILABLE_APPROVAL ||
      (!command.nil? && command_approves_local_ui?(command))
  end

  def running_on_macbook_air?
    return true if ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] == '1'
    return false if ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] == '1'

    !Socket.gethostname.to_s.downcase.include?('mini')
  rescue StandardError
    true
  end

  def host_identity
    {
      hostname: Socket.gethostname.to_s,
      user: (ENV['USER'].to_s.empty? ? ENV.fetch('LOGNAME', '') : ENV['USER']),
      home: Dir.home.to_s,
      role: running_on_macbook_air? ? 'air-controller' : 'mini'
    }
  rescue StandardError
    { hostname: 'unknown', user: '', home: '', role: 'air-controller' }
  end

  def host_identity_line
    id = host_identity
    "This process is #{id[:hostname]} (user=#{id[:user]}, #{id[:role]})."
  end

  def air_saneapps_app_path?(path)
    return false unless running_on_macbook_air?
    return false if approved_local_ui?

    text = path.to_s.strip
    return false if text.empty?

    return true if text.match?(%r{(?:~|/Users/[^/]+)/SaneApps/apps(?:/|\z)}i)

    expanded = File.expand_path(text.sub(/\A~(?=\/|\z)/, Dir.home))
    expanded.match?(%r{/SaneApps/apps(?:/|\z)})
  rescue StandardError
    false
  end

  def air_app_edit_reason(path)
    return nil unless air_saneapps_app_path?(path)

    "AIR CONTROLLER APP EDIT BLOCKED. #{host_identity_line} " \
      "Path #{path} is SaneApps app source. Mini is canonical. " \
      'Edit it on the Mini via ssh mini, not this Air checkout. ' \
      "ONLY FALLBACK after explicit owner approval: " \
      "SANE_APPROVE_LOCAL_UI_ON_AIR='#{LOCAL_UI_APPROVAL}'."
  end

  def pasteboard_reason(command)
    return nil unless running_on_macbook_air?
    return nil if approved_local_ui?(command)
    return nil unless command.to_s.match?(PASTEBOARD_PATTERN)

    "AIR/UNIVERSAL CLIPBOARD BLOCKED. #{host_identity_line} " \
      'pbcopy/pbpaste writes the general pasteboard. Mini pasteboard still ' \
      'syncs to Air Clip via Universal Clipboard, so this contaminates the ' \
      'controller machine. Do not seed test clips that way. ' \
      "ONLY FALLBACK after explicit owner approval: prefix the shell command with " \
      "SANE_APPROVE_LOCAL_UI_ON_AIR='#{LOCAL_UI_APPROVAL}' " \
      '(or set that env for the hook process).'
  end

  def air_local_gui_reason(command)
    return nil unless running_on_macbook_air?
    return nil if approved_local_ui?(command)

    cmd = command.to_s
    return nil if cmd.match?(MINI_REMOTE_PATTERN)
    return nil unless cmd.match?(AIR_GUI_PATTERN)
    return nil unless cmd.match?(SANE_APP_PATTERN) ||
                      cmd.match?(/\bpeekaboo\b/) ||
                      cmd.match?(/clip-hid\.py|clip-cmdkey\.py|CGEventPost/)

    "AIR LOCAL GUI BLOCKED. #{host_identity_line} " \
      'This would drive SaneApps UI, Peekaboo, or HID on the Air. ' \
      'Use ssh mini and mini-gui-run.sh on the Mini. ' \
      "ONLY FALLBACK after explicit owner approval: prefix the shell command with " \
      "SANE_APPROVE_LOCAL_UI_ON_AIR='#{LOCAL_UI_APPROVAL}' " \
      '(or set that env for the hook process).'
  end

  # Strip quoted regions so tool names inside string arguments (grep patterns,
  # commit messages, echoed prose) cannot trigger build/cleanup blocks.
  def strip_quoted(command)
    command.gsub(/"(?:[^"\\]|\\.)*"/m, '').gsub(/'[^']*'/m, '')
  end
end
