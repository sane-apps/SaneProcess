#!/usr/bin/env ruby
# frozen_string_literal: true

# Session Start Hook - Bootstraps the .claude/ directory for a new session
#
# Actions:
# - Creates .claude/ directory if missing
# - Resets circuit breaker state (fresh session = fresh start)
# - Cleans up stale failure tracking
# - Outputs session context reminder
#
# This is a SessionStart hook that runs once when Claude Code starts.
#
# Exit codes:
# - 0: Always (bootstrap should never fail)

require 'json'
require 'fileutils'
require 'time'
require_relative 'state_signer'

PROJECT_DIR = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
CLAUDE_DIR = File.join(PROJECT_DIR, '.claude')
BREAKER_FILE = File.join(CLAUDE_DIR, 'circuit_breaker.json')
FAILURE_FILE = File.join(CLAUDE_DIR, 'failure_state.json')

# Satisfaction/enforcement state files to clear on fresh session
SATISFACTION_FILE = File.join(CLAUDE_DIR, 'process_satisfaction.json')
RESEARCH_PROGRESS_FILE = File.join(CLAUDE_DIR, 'research_progress.json')
REQUIREMENTS_FILE = File.join(CLAUDE_DIR, 'prompt_requirements.json')
SANELOOP_STATE_FILE = File.join(CLAUDE_DIR, 'saneloop-state.json')
SANELOOP_ARCHIVE_DIR = File.join(CLAUDE_DIR, 'saneloop-archive')
EDIT_STATE_FILE = File.join(CLAUDE_DIR, 'edit_state.json')
SUMMARY_VALIDATED_FILE = File.join(CLAUDE_DIR, 'summary_validated.json')

# SaneLoop is stale if older than this (hours)
STALE_SANELOOP_HOURS = 4

def ensure_claude_dir
  FileUtils.mkdir_p(CLAUDE_DIR)

  # Create .gitignore if missing
  gitignore = File.join(CLAUDE_DIR, '.gitignore')
  unless File.exist?(gitignore)
    File.write(gitignore, <<~GITIGNORE)
      # Claude Code state files (session-specific, don't commit)
      circuit_breaker.json
      failure_state.json
      audit.jsonl

      # Keep rules and settings
      !rules/
      !settings.json
    GITIGNORE
  end
end

def reset_session_state
  # VULN-007 FIX: Do NOT auto-reset tripped breaker
  # A tripped breaker indicates repeated failures that need human review
  # Claude should not be able to bypass by starting a new session

  # VULN-003 FIX: Use signed state files
  breaker = StateSigner.read_verified(BREAKER_FILE)

  if breaker && breaker['tripped']
    # Mark that reset is pending user approval
    breaker['pending_user_reset'] = true
    breaker['session_started_while_tripped'] = Time.now.utc.iso8601
    StateSigner.write_signed(BREAKER_FILE, breaker)

    # Warn user - breaker stays tripped
    warn ''
    warn '🔴 CIRCUIT BREAKER STILL TRIPPED'
    warn "   Tripped at: #{breaker['tripped_at']}"
    warn "   Reason: #{breaker['trip_reason']}"
    warn ''
    warn '   Say "reset breaker" or "approve breaker reset" to clear.'
    warn '   This prevents Claude from bypassing failures by restarting.'
    warn ''
    return # Don't reset failure tracking either
  end

  # Only reset failure tracking if breaker is NOT tripped
  if File.exist?(FAILURE_FILE)
    File.delete(FAILURE_FILE)
  end
end

def find_sop_file
  candidates = %w[DEVELOPMENT.md CONTRIBUTING.md SOP.md docs/SOP.md]
  candidates.find { |f| File.exist?(File.join(PROJECT_DIR, f)) }
end

# Clear stale satisfaction from previous sessions
# New session = fresh slate, must re-earn compliance
def clear_stale_satisfaction
  cleared = []

  [SATISFACTION_FILE, RESEARCH_PROGRESS_FILE, REQUIREMENTS_FILE,
   EDIT_STATE_FILE, SUMMARY_VALIDATED_FILE].each do |file|
    if File.exist?(file)
      File.delete(file)
      cleared << File.basename(file)
    end
  end

  if cleared.any?
    warn ''
    warn '🧹 Cleared stale satisfaction from previous session'
    warn "   Removed: #{cleared.join(', ')}"
    warn '   Fresh session = fresh compliance requirements'
    warn ''
  end
end

# Detect and handle stale SaneLoop
def handle_stale_saneloop
  return unless File.exist?(SANELOOP_STATE_FILE)

  state = JSON.parse(File.read(SANELOOP_STATE_FILE), symbolize_names: true)
  return unless state[:active]

  # Check if SaneLoop is stale (started more than STALE_SANELOOP_HOURS ago)
  started_at = Time.parse(state[:started_at]) rescue nil
  return unless started_at

  hours_old = (Time.now - started_at) / 3600.0

  if hours_old > STALE_SANELOOP_HOURS
    # Archive the stale SaneLoop
    FileUtils.mkdir_p(SANELOOP_ARCHIVE_DIR)
    task_slug = (state[:task] || 'unknown').gsub(/[^a-zA-Z0-9]+/, '_')[0..30]
    archive_name = "#{Time.now.strftime('%Y%m%d_%H%M%S')}_STALE_#{task_slug}.json"
    archive_path = File.join(SANELOOP_ARCHIVE_DIR, archive_name)

    state[:archived_at] = Time.now.iso8601
    state[:completed] = false
    state[:completion_note] = "STALE: Abandoned after #{hours_old.round(1)} hours - archived on new session start"
    File.write(archive_path, JSON.pretty_generate(state))
    File.delete(SANELOOP_STATE_FILE)

    warn ''
    warn '⚠️  STALE SANELOOP DETECTED AND ARCHIVED'
    warn "   Task: #{state[:task]}"
    warn "   Started: #{hours_old.round(1)} hours ago"
    warn "   Status: Never completed (no rating presented)"
    warn ''
    warn '   Starting fresh. Use SaneMaster saneloop start for new tasks.'
    warn ''
  else
    # SaneLoop is recent but from different session - warn but keep
    warn ''
    warn '📋 ACTIVE SANELOOP FROM PREVIOUS SESSION'
    warn "   Task: #{state[:task]}"
    warn "   Iteration: #{state[:iteration]}/#{state[:max_iterations]}"
    warn ''
    warn '   Continue with: ./Scripts/SaneMaster.rb saneloop status'
    warn '   Or cancel with: ./Scripts/SaneMaster.rb saneloop cancel'
    warn ''
  end
rescue StandardError => e
  warn "⚠️  Error checking SaneLoop state: #{e.message}"
end

def output_session_context
  project_name = File.basename(PROJECT_DIR)
  sop_file = find_sop_file

  warn ''
  warn "✅ #{project_name} session started"

  if sop_file
    warn "📋 SOP: #{sop_file}"
  else
    warn '⚠️  No SOP file found (DEVELOPMENT.md, CONTRIBUTING.md)'
  end

  # Check for pattern rules
  rules_dir = File.join(CLAUDE_DIR, 'rules')
  if Dir.exist?(rules_dir)
    rule_count = Dir.glob(File.join(rules_dir, '*.md')).count
    warn "📁 Pattern rules: #{rule_count} loaded" if rule_count.positive?
  end

  # Check for memory file and remind to load
  memory_file = File.join(CLAUDE_DIR, 'memory.json')
  if File.exist?(memory_file)
    warn '🧠 Memory available - run mcp__memory__read_graph at session start'
  end

  warn ''
end

# Main execution
begin
  ensure_claude_dir
  reset_session_state
  clear_stale_satisfaction
  handle_stale_saneloop
  output_session_context
rescue StandardError => e
  warn "⚠️  Session start error: #{e.message}"
end

exit 0
