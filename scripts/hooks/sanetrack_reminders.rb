#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack Reminders Module
# ==============================================================================
# Feature reminders that suggest underutilized Claude Code features at
# appropriate moments. Extracted from sanetrack.rb per Rule #10 (file size).
#
# Usage:
#   require_relative 'sanetrack_reminders'
# ==============================================================================

require 'time'
require 'json'
require 'fileutils'
require_relative 'core/state_manager'

REMINDER_COOLDOWN = 300 # 5 minutes in seconds

def should_remind?(reminder_type)
  reminders = StateManager.get(:reminders) || {}
  last_at = reminders["#{reminder_type}_at".to_sym]
  return true unless last_at

  begin
    time_since = Time.now - Time.parse(last_at)
    time_since >= REMINDER_COOLDOWN
  rescue ArgumentError
    true # If timestamp is invalid, allow reminder
  end
end

def record_reminder(reminder_type)
  StateManager.update(:reminders) do |r|
    r ||= {}
    r["#{reminder_type}_at".to_sym] = Time.now.iso8601
    r["#{reminder_type}_count".to_sym] = (r["#{reminder_type}_count".to_sym] || 0) + 1
    r
  end
end

def emit_rewind_reminder(error_count)
  return unless should_remind?(:rewind)

  record_reminder(:rewind)

  warn ''
  if error_count >= 2
    warn '🔄 CONSIDER /rewind - Multiple errors suggest research before retry'
    warn '   Press Esc+Esc to rollback code AND conversation to last checkpoint'
  else
    warn '💡 TIP: /rewind can rollback this change if needed (Esc+Esc shortcut)'
  end
  warn ''
end

def emit_context_reminder(edit_count)
  return unless edit_count % 5 == 0 && edit_count > 0 # Every 5 edits
  return unless should_remind?(:context)

  record_reminder(:context)

  warn ''
  warn "💡 TIP: After #{edit_count} edits - try /context to visualize token usage"
  warn '   Helps identify what\'s consuming your context window'
  warn ''
end

def emit_explore_reminder(tool_name, tool_input)
  return unless %w[Grep Glob].include?(tool_name)

  pattern = tool_input['pattern'] || tool_input[:pattern] || ''
  return unless pattern.include?('**') || pattern.length > 30 # Complex search

  return unless should_remind?(:explore)

  record_reminder(:explore)

  warn ''
  warn '💡 TIP: Quick lookup? → Task(subagent_type: "Explore") — fast, disposable'
  warn '   Real research? → Task(subagent_type: "general-purpose", model: "gpt-5.2" or "gpt-5.4") — persists to .claude/research.md'
  warn ''
end

# === LOGGING ===

def log_action(tool_name, result_type)
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
  entry = {
    timestamp: Time.now.iso8601,
    tool: tool_name,
    result: result_type,
    pid: Process.pid
  }
  File.open(LOG_FILE, 'a') { |f| f.puts(entry.to_json) }
rescue StandardError
  # Don't fail on logging errors
end
