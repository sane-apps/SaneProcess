#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack Gate Module
# ==============================================================================
# Startup gate step tracking for PostToolUse.
# Detects completion of each mandatory startup step and opens the gate
# when all are done.
#
# Extracted from sanetrack.rb per Rule #10 (file size limit).
#
# Usage:
#   require_relative 'sanetrack_gate'
# ==============================================================================

require 'time'
require_relative 'core/state_manager'

SKILLS_REGISTRY_BASENAME = 'SKILLS_REGISTRY.md'

def track_startup_gate_step(tool_name, tool_input)
  gate = StateManager.get(:startup_gate)
  return if gate[:open]

  steps = gate[:steps] || {}
  changed = false

  case tool_name
  when 'Read'
    file_path = tool_input['file_path'] || tool_input[:file_path] || ''
    basename = File.basename(file_path)

    # SKILLS_REGISTRY.md read
    if basename == SKILLS_REGISTRY_BASENAME && !steps[:skills_registry]
      steps[:skills_registry] = true
      gate[:step_timestamps][:skills_registry] = Time.now.iso8601
      changed = true
    end

    # Session docs: check if all required docs now read
    unless steps[:session_docs]
      session_docs = StateManager.get(:session_docs)
      required = session_docs[:required] || []
      already_read = session_docs[:read] || []
      # Include current file being read (sanetrack runs after tool executes)
      all_read = already_read | [basename]
      if (required - all_read).empty?
        steps[:session_docs] = true
        gate[:step_timestamps][:session_docs] = Time.now.iso8601
        changed = true
      end
    end

  when 'Bash'
    command = tool_input['command'] || tool_input[:command] || ''

    if command.match?(/validation_report\.rb/) && !steps[:validation_report]
      steps[:validation_report] = true
      gate[:step_timestamps][:validation_report] = Time.now.iso8601
      changed = true
    end

    if command.match?(/SaneMaster\.rb\s+clean_system/) && !steps[:system_clean]
      steps[:system_clean] = true
      gate[:step_timestamps][:system_clean] = Time.now.iso8601
      changed = true
    end
  end

  return unless changed

  # Check if all steps are now done
  all_done = steps.values.all?
  if all_done
    gate[:open] = true
    gate[:opened_at] = Time.now.iso8601
    warn '🚦 STARTUP GATE OPEN — all startup steps complete'
  end

  gate[:steps] = steps
  StateManager.update(:startup_gate) { |_| gate }
rescue StandardError => e
  warn "⚠️  Startup gate tracking error: #{e.message}" if ENV['DEBUG']
end
