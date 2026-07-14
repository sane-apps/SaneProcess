#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack Research Module
# ==============================================================================
# Extracted from sanetrack.rb per Rule #10 (file size limit)
# Research protocol enforcement: write validation + active-cache size cap
#
# Two checks:
#   1. validate_research_write - After Task completes, verify research.md changed
#   2. check_research_size - After Edit/Write to research.md, warn if > active-cache cap
# ==============================================================================

require_relative 'core/state_manager'
require_relative 'core/project_root'

module SaneTrackResearch
  RESEARCH_SOFT_CAP = 160
  RESEARCH_SIZE_CAP = 200

  # Called after Task completions. Checks if a pending research write actually happened.
  # sanetools.rb sets :pending_research_write before Task agents that mention research.md.
  # If the file mtime didn't change, the agent didn't write — warn.
  def self.validate_research_write(tool_name)
    return unless tool_name == 'Task'

    research = StateManager.get(:research)
    pending = research[:pending_research_write]
    return unless pending

    # Clear the pending marker regardless of outcome
    StateManager.update(:research) do |r|
      r.delete(:pending_research_write)
      r
    end

    project_dir = SaneProjectRoot.resolve
    research_md = File.join(project_dir, '.claude', 'research.md')

    pre_mtime = pending[:pre_mtime]
    post_mtime = File.exist?(research_md) ? File.mtime(research_md).iso8601 : nil

    # If file didn't exist before and still doesn't, or mtime unchanged → missed write
    if pre_mtime == post_mtime
      warn ''
      warn 'RESEARCH WRITE MISSED'
      warn "   Task prompt mentioned research.md but file was not updated."
      warn "   Snippet: #{pending[:task_prompt_snippet]}"
      warn '   Fix: Ensure research agents actually write findings to .claude/research.md'
      warn ''
    end
  rescue StandardError => e
    warn "  Research write validation error: #{e.message}" if ENV['DEBUG']
  end

  # Called after Edit/Write to research.md. Warns if file exceeds size cap.
  def self.check_research_size(tool_name, tool_input)
    return unless %w[Edit Write].include?(tool_name)

    file_path = tool_input['file_path'] || tool_input[:file_path] || ''
    return unless file_path.end_with?('research.md')

    return unless File.exist?(file_path)

    line_count = File.readlines(file_path).length
    return unless line_count > RESEARCH_SOFT_CAP

    warn ''
    if line_count > RESEARCH_SIZE_CAP
      warn 'RESEARCH CACHE OVERFLOW'
      warn "   research.md is #{line_count} lines (hard cap: #{RESEARCH_SIZE_CAP})"
      warn '   Do not append new raw research until stale topics are expired or verified findings are promoted.'
    else
      warn 'RESEARCH CACHE NEAR CAP'
      warn "   research.md is #{line_count} lines (soft cap: #{RESEARCH_SOFT_CAP}, hard cap: #{RESEARCH_SIZE_CAP})"
    end
    warn '   research.md is a rolling index/scratchpad, not an archive.'
    warn '   Never delete verified research just to satisfy the cap; first promote durable conclusions to ARCHITECTURE.md, DEVELOPMENT.md, AGENTS.md, SESSION_HANDOFF.md, Serena, or AgentMemory.'
    warn ''
  rescue StandardError => e
    warn "  Research size check error: #{e.message}" if ENV['DEBUG']
  end
end
