#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SanePrompt Commands Module
# ==============================================================================
# Safemode, circuit breaker, research, and planning user commands — extracted
# from saneprompt.rb per Rule #10 (file size limits).
#
# Usage:
#   require_relative 'saneprompt_commands'
#   include SanePromptCommands
# ==============================================================================

require 'json'
require 'fileutils'
require_relative 'core/state_manager'

module SanePromptCommands
  BYPASS_FILE = File.expand_path('../../.claude/bypass_active.json', __dir__)
  SANEMASTER_PATH = File.expand_path('../../Scripts/SaneMaster.rb', __dir__)
  CLAUDE_DIR = File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.claude')

  # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def handle_safemode_command(prompt)
    cmd = prompt.strip.downcase

    # === SANELOOP COMMANDS (requires SaneMaster.rb — SaneApps internal tool) ===
    if cmd.start_with?('sl+') || cmd.start_with?('saneloop on') || cmd.start_with?('saneloop start')
      unless File.exist?(SANEMASTER_PATH)
        warn ''
        warn 'SANELOOP: Not available (SaneMaster.rb not found)'
        warn '  Saneloop is an internal tool for SaneApps projects.'
        warn ''
        return true
      end
      task_match = prompt.match(/sl\+\s+(.+)/i) || prompt.match(/saneloop\s+(?:on|start)\s+(.+)/i)
      if task_match
        task = task_match[1].strip
        result = `#{SANEMASTER_PATH} saneloop start "#{task}" 2>&1`
        warn ''
        warn result
        warn ''
      else
        warn ''
        warn 'SANELOOP: Provide a task description'
        warn '  Usage: sl+ <task description>'
        warn '  Example: sl+ Fix the authentication bug'
        warn ''
      end
      true
    elsif cmd.start_with?('sl-') || cmd.start_with?('saneloop off') || cmd.start_with?('saneloop stop')
      unless File.exist?(SANEMASTER_PATH)
        warn 'SANELOOP: Not available (SaneMaster.rb not found)'
        return true
      end
      result = `#{SANEMASTER_PATH} saneloop cancel 2>&1`
      warn ''
      warn result
      warn ''
      true
    elsif cmd.start_with?('sl?') || cmd == 'saneloop' || cmd.start_with?('saneloop status')
      unless File.exist?(SANEMASTER_PATH)
        warn 'SANELOOP: Not available (SaneMaster.rb not found)'
        return true
      end
      result = `#{SANEMASTER_PATH} saneloop status 2>&1`
      warn ''
      warn result
      warn ''
      true
    elsif cmd.start_with?('s+') || cmd.start_with?('safemode on')
      if File.exist?(BYPASS_FILE)
        File.delete(BYPASS_FILE)
        warn ''
        warn 'SAFEMODE ON - enforcement active'
        warn ''
      else
        warn ''
        warn 'SAFEMODE already on'
        warn ''
      end
      true
    elsif cmd.start_with?('s-') || cmd.start_with?('safemode off')
      FileUtils.mkdir_p(File.dirname(BYPASS_FILE))
      File.write(BYPASS_FILE, '{}')
      warn ''
      warn 'SAFEMODE OFF - enforcement bypassed'
      warn ''
      true
    elsif cmd.start_with?('s?') || cmd == 'safemode' || cmd.start_with?('safemode status')
      status = File.exist?(BYPASS_FILE) ? 'OFF (bypassed)' : 'ON (enforcing)'
      warn ''
      warn "SAFEMODE: #{status}"
      warn ''
      true
    elsif cmd.start_with?('reset breaker') || cmd.start_with?('reset circuit') || cmd.start_with?('rb-') || cmd.start_with?('rb+')
      debug_log("RESET BREAKER: cmd='#{cmd}'") rescue nil
      debug_log("BEFORE RESET: #{StateManager.get(:circuit_breaker).inspect}") rescue nil
      StateManager.reset(:circuit_breaker)
      log_reset('circuit_breaker', 'User reset circuit breaker')
      debug_log("AFTER RESET: #{StateManager.get(:circuit_breaker).inspect}") rescue nil
      warn ''
      warn 'CIRCUIT BREAKER RESET'
      warn '  Failures: 0'
      warn '  Tripped: false'
      warn '  Error signatures: cleared'
      warn '  (logged to reset_audit.log)'
      warn ''
      true
    elsif cmd.start_with?('rb?') || cmd == 'breaker status'
      cb = StateManager.get(:circuit_breaker)
      warn ''
      warn 'CIRCUIT BREAKER STATUS'
      warn "  Tripped: #{cb[:tripped] || false}"
      warn "  Failures: #{cb[:failures] || 0}"
      if cb[:error_signatures]&.any?
        warn '  Error signatures:'
        cb[:error_signatures].each { |sig, count| warn "    #{sig}: #{count}" }
      end
      warn ''
      true
    elsif cmd.start_with?('reset blocks') || cmd == 'unblock'
      StateManager.reset(:refusal_tracking)
      log_reset('refusal_tracking', 'User reset block counters')
      warn ''
      warn 'BLOCK COUNTERS RESET'
      warn '  All block type counters cleared.'
      warn '  You may now retry - but READ the block messages this time.'
      warn '  Next block of same type starts fresh at count=1.'
      warn ''
      true
    elsif cmd.start_with?('reset research') || cmd == 'rr-'
      # NOTE: Changed from 5 to 4 (Jan 2026) - memory MCP removed
      StateManager.reset(:research)
      log_reset('research', 'User reset research requirements')
      warn ''
      warn 'RESEARCH RESET'
      warn '  All 4 research categories cleared.'
      warn '  Must complete: docs, web, github, local'
      warn '  This is NOT a bypass - you must actually do the research.'
      warn ''
      true
    elsif cmd == 'pa+' || cmd == 'plan approved'
      StateManager.update(:planning) do |p|
        p[:plan_approved] = true
        p
      end
      log_reset('planning', 'User manually approved plan (pa+)')
      warn ''
      warn 'PLAN APPROVED - edits now allowed'
      warn ''
      true
    elsif cmd == 'pa?' || cmd == 'plan status'
      planning = StateManager.get(:planning)
      warn ''
      warn 'PLANNING STATUS'
      warn "  Required: #{planning[:required]}"
      warn "  Plan shown: #{planning[:plan_shown]}"
      warn "  Plan approved: #{planning[:plan_approved]}"
      warn "  Re-plan count: #{planning[:replan_count]}"
      warn "  Forced at: #{planning[:forced_at] || 'n/a'}"
      warn ''
      true
    elsif cmd == 'reset?' || cmd == 'resets?'
      warn ''
      warn 'AVAILABLE RESET COMMANDS'
      warn ''
      warn '  rb-  / reset breaker   → Clear circuit breaker (after 3+ failures)'
      warn '  reset blocks / unblock → Clear block counters (after repeated blocks)'
      warn '  rr- / reset research   → Clear research (forces redo all 4 categories)'
      warn '  pa+ / plan approved    → Approve plan (unlock edits)'
      warn '  pa? / plan status      → Show planning state'
      warn ''
      warn 'Resets are LOGGED and do NOT disable hooks.'
      warn 'They allow retry - the hooks still enforce rules.'
      warn ''
      true
    else
      false
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Log all resets for audit trail
  def log_reset(what, reason)
    log_file = File.join(CLAUDE_DIR, 'reset_audit.log')
    entry = {
      timestamp: Time.now.iso8601,
      reset_type: what,
      reason: reason,
      pid: Process.pid
    }
    File.open(log_file, 'a') { |f| f.puts(entry.to_json) }
  rescue StandardError
    # Don't fail on logging errors
  end
end
