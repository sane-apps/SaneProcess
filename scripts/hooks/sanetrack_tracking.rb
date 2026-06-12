#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack Tracking Functions
# ==============================================================================
# Per-tool result tracking (edits, visual requirements/evidence, MCP
# verification, session-doc reads, failures, error signatures, action log) —
# extracted in place from sanetrack.rb per Rule #10 (file size limit).
#
# Bare top-level defs (matching sanetrack.rb's script style): required from
# sanetrack.rb at the original position so they stay Object-private methods and
# load order is unchanged. Shared constants (EDIT_TOOLS, FAILURE_TOOLS,
# ERROR_PATTERN, ERROR_SIGNATURES, MAX_ACTION_LOG, ...) remain defined in
# sanetrack.rb and resolve here via top-level constant fallback.
# ==============================================================================

require 'json'
require 'time'
require 'fileutils'
require 'open3'
require_relative 'core/mandatory_workflows'
require_relative 'core/state_manager'
require_relative 'core/process_metrics'

# === TRACKING FUNCTIONS ===

def track_edit(tool_name, tool_input, tool_response)
  return unless EDIT_TOOLS.include?(tool_name)

  file_path = tool_input['file_path'] || tool_input[:file_path]
  return unless file_path

  StateManager.update(:edits) do |e|
    e[:count] = (e[:count] || 0) + 1
    e[:unique_files] ||= []
    e[:unique_files] << file_path unless e[:unique_files].include?(file_path)
    e[:last_file] = file_path
    e[:last_edit_at] = Time.now.iso8601
    e
  end

  # Track edits-since-last-test for Rule #4
  StateManager.update(:verification) do |v|
    v[:edits_before_test] = (v[:edits_before_test] || 0) + 1
    v
  end

  track_visual_requirement_from_edit(file_path)
  track_visual_audit_note(tool_name, tool_input, file_path)
rescue StandardError
  # Don't fail on verification tracking
end

def track_bash_mutation(tool_name, tool_input, tool_response)
  return unless tool_name == 'Bash'
  return if detect_actual_failure(tool_name, tool_response)

  command = (tool_input['command'] || tool_input[:command]).to_s
  return unless bash_mutation_command?(command)

  changed_files = git_changed_files_after_bash
  return if changed_files.empty?

  StateManager.update(:edits) do |e|
    e[:count] = (e[:count] || 0) + changed_files.length
    e[:unique_files] ||= []
    changed_files.each { |path| e[:unique_files] << path unless e[:unique_files].include?(path) }
    e[:last_file] = changed_files.last
    e[:last_edit_at] = Time.now.iso8601
    e
  end

  StateManager.update(:verification) do |v|
    v[:edits_before_test] = (v[:edits_before_test] || 0) + changed_files.length
    v
  end

  changed_files.each do |path|
    track_visual_requirement_from_edit(path)
    track_visual_audit_note('Bash', { 'content' => command }, path)
  end
rescue StandardError => e
  warn "⚠️  Bash mutation tracking error: #{e.message}" if ENV['DEBUG']
end

def bash_mutation_command?(command)
  command.match?(
    Regexp.union(
      />\s*[^&]/,
      />>/,
      /\bsed\s+-i\b/,
      /\btee\b/,
      /\bcp\s+/,
      /\bmv\s+/,
      /\bgit\s+apply\b/,
      /\b(?:python3?|ruby|node|perl)\s+-e\b/,
      /\bSaneMaster(?:_standalone)?\.rb\s+(?:gen_|template|enable_ci_tests|restore_ci_tests|fix_mocks|bootstrap|setup)\b/
    )
  )
end

def git_changed_files_after_bash
  root_out, root_status = Open3.capture2e('git', 'rev-parse', '--show-toplevel')
  return [] unless root_status.success?

  root = root_out.strip
  status_out, status = Open3.capture2e('git', '-C', root, 'status', '--porcelain=v1', '--untracked-files=all')
  return [] unless status.success?

  status_out.each_line.filter_map do |line|
    path = line[3..]&.strip
    next if path.to_s.empty?

    path = path.split(' -> ', 2).last if path.include?(' -> ')
    File.expand_path(path, root)
  end.uniq
end

def track_visual_requirement_from_edit(file_path)
  return unless UI_FILE_PATTERNS.any? { |pattern| file_path.match?(pattern) }

  StateManager.update(:visual_verification) do |visual|
    visual[:required] = true
    visual[:reason] ||= 'customer_facing_ui_file_edited'
    visual[:required_files] ||= []
    basename = File.basename(file_path)
    visual[:required_files] << basename unless visual[:required_files].include?(basename)
    visual[:required_files] = visual[:required_files].last(20)
    visual
  end
rescue StandardError
  # Don't fail on visual tracking
end

def track_visual_audit_note(tool_name, tool_input, file_path)
  return unless EDIT_TOOLS.include?(tool_name)

  content = tool_input['new_string'] || tool_input[:new_string] ||
            tool_input['content'] || tool_input[:content] || ''
  return if content.to_s.empty?
  return unless VISUAL_AUDIT_NOTE_PATTERNS.any? { |pattern| content.match?(pattern) }

  StateManager.update(:visual_verification) do |visual|
    visual[:audit_recorded] = true
    visual[:last_audit_at] = Time.now.iso8601
    visual[:audit_files] ||= []
    visual[:audit_files] << file_path unless visual[:audit_files].include?(file_path)
    visual[:audit_files] = visual[:audit_files].last(10)
    visual
  end
rescue StandardError
  # Don't fail on visual tracking
end

# === VERIFICATION TRACKING (Rule #4) ===
# Detect test/verification commands in Bash tool calls
def track_verification(tool_name, tool_input)
  return unless tool_name == 'Bash'

  command = tool_input['command'] || tool_input[:command] || ''
  return if command.empty?

  matched = TEST_COMMAND_PATTERNS.find { |p| command.match?(p) }
  return unless matched

  cmd_summary = command.gsub(/\s+/, ' ').strip[0..80]

  StateManager.update(:verification) do |v|
    v[:tests_run] = true
    v[:verification_run] = true
    v[:tests_passed] = false
    v[:verification_succeeded] = false
    v[:last_test_at] = Time.now.iso8601
    v[:test_commands] ||= []
    v[:test_commands] << cmd_summary unless v[:test_commands].include?(cmd_summary)
    v[:test_commands] = v[:test_commands].last(10) # Keep last 10
    v[:edits_before_test] = 0
    v[:requires_structured_verify_metric] = true
    v
  end
rescue StandardError
  # Don't fail on verification tracking
end

def track_visual_evidence(tool_name, tool_input)
  return unless tool_name == 'Bash'

  command = tool_input['command'] || tool_input[:command] || ''
  return if command.empty?
  return unless VISUAL_EVIDENCE_COMMAND_PATTERNS.any? { |pattern| command.match?(pattern) }

  StateManager.update(:visual_verification) do |visual|
    visual[:evidence_commands] ||= []
    summary = command.gsub(/\s+/, ' ').strip[0..180]
    visual[:evidence_commands] << summary unless visual[:evidence_commands].include?(summary)
    visual[:evidence_commands] = visual[:evidence_commands].last(10)
    visual[:last_evidence_at] = Time.now.iso8601

    visual[:screenshot_paths] ||= []
    command.scan(%r{(?:^|\s)([/~.\w-][^\s'"]*\.(?:png|jpg|jpeg))}i).flatten.each do |path|
      visual[:screenshot_paths] << path unless visual[:screenshot_paths].include?(path)
    end
    visual[:screenshot_paths] = visual[:screenshot_paths].last(20)
    visual
  end
rescue StandardError
  # Don't fail on visual tracking
end

# === MCP VERIFICATION TRACKING ===
# Track successful MCP tool calls to verify connectivity

def track_mcp_verification(tool_name, success)
  # Find which MCP this tool belongs to
  mcp_name = nil
  MCP_VERIFICATION_PATTERNS.each do |mcp, pattern|
    if tool_name.match?(pattern)
      mcp_name = mcp
      break
    end
  end

  return unless mcp_name

  StateManager.update(:mcp_health) do |health|
    health[:mcps] ||= {}
    health[:mcps][mcp_name] ||= { verified: false, last_success: nil, last_failure: nil, failure_count: 0 }

    if success
      health[:mcps][mcp_name][:verified] = true
      health[:mcps][mcp_name][:last_success] = Time.now.iso8601
      # Don't reset failure_count - it's historical data

      # Only require verification for MCPs that are actually configured.
      configured_mcps = SaneToolsChecks.configured_mcp_verification_info.keys
      all_verified = configured_mcps.any? && configured_mcps.all? do |mcp|
        health[:mcps][mcp] && health[:mcps][mcp][:verified]
      end

      if all_verified && !health[:verified_this_session]
        health[:verified_this_session] = true
        health[:last_verified] = Time.now.iso8601
        warn '✅ ALL CONFIGURED MCPs VERIFIED - edits now allowed'
      end
    else
      health[:mcps][mcp_name][:last_failure] = Time.now.iso8601
      health[:mcps][mcp_name][:failure_count] = (health[:mcps][mcp_name][:failure_count] || 0) + 1
    end

    health
  end
rescue StandardError => e
  warn "⚠️  MCP tracking error: #{e.message}"
end

# === SESSION DOC READ TRACKING ===
# When a Read tool reads a required session doc, mark it as read

def track_session_doc_read(tool_name, tool_input)
  return unless tool_name == 'Read'

  file_path = tool_input['file_path'] || tool_input[:file_path]
  return unless file_path

  basename = File.basename(file_path)
  session_docs = StateManager.get(:session_docs)
  required = session_docs[:required] || []
  already_read = session_docs[:read] || []

  return unless required.include?(basename)
  return if already_read.include?(basename)

  StateManager.update(:session_docs) do |sd|
    sd[:read] ||= []
    sd[:read] << basename unless sd[:read].include?(basename)
    sd
  end

  remaining = required - already_read - [basename]
  if remaining.empty?
    warn '✅ ALL SESSION DOCS READ - edits now allowed'
  else
    warn "📖 Read #{basename}. Remaining: #{remaining.join(', ')}"
  end
rescue StandardError => e
  warn "⚠️  Session doc tracking error: #{e.message}" if ENV['DEBUG']
end

# === STARTUP GATE STEP TRACKING ===
# Extracted to sanetrack_gate.rb per Rule #10
require_relative 'sanetrack_gate'

def track_failure(tool_name, tool_response)
  return unless FAILURE_TOOLS.include?(tool_name)

  # Check if response indicates failure
  response_str = tool_response.to_s
  is_failure = response_str.match?(ERROR_PATTERN)

  return unless is_failure
  # Sibling-hook enforcement feedback is the process talking, not the work
  # failing. Counting it as failures tripped the breaker on task-completion
  # paperwork (2026-06-11 deadlock: breaker then blocked the very verify
  # command the completion gate demanded).
  return if response_str.match?(/hook feedback|SANETOOLS BLOCKED|TaskCompleted hook|completed without recent test verification/i)

  doom_loop_caught = false

  StateManager.update(:circuit_breaker) do |cb|
    cb[:failures] = (cb[:failures] || 0) + 1
    cb[:last_error] = response_str[0..200]

    # Rule #3: two strikes means stop and research before trying again.
    if cb[:failures] >= 2 && !cb[:tripped]
      cb[:tripped] = true
      cb[:tripped_at] = Time.now.iso8601
      doom_loop_caught = true
    end

    cb
  end

  # Q2 validation: track doom loop catch (separate update avoids nested lock)
  track_validation_doom_loop if doom_loop_caught
end

# A successful canonical verify is proof the root cause is fixed — clear the
# trip on evidence instead of requiring a human rb- (2026-06-12: trips from
# transient tool errors deadlocked sessions a green verify should have freed).
def untrip_breaker_on_green_verify(tool_name, tool_input)
  return unless tool_name == 'Bash'

  command = (tool_input['command'] || tool_input[:command]).to_s
  return unless command.match?(/SaneMaster(?:_standalone)?\.rb\s+verify\b/)

  cb = StateManager.get(:circuit_breaker)
  return unless cb[:tripped]

  StateManager.update(:circuit_breaker) do |c|
    c[:tripped] = false
    c[:tripped_at] = nil
    c[:error_signatures] = {}
    c[:last_error] = nil
    c
  end
  warn '✅ Circuit breaker cleared by green canonical verify.'
end

def reset_failure_count(tool_name)
  # Successful tool use resets failure count for that tool type
  return unless FAILURE_TOOLS.include?(tool_name)

  cb = StateManager.get(:circuit_breaker)
  return if cb[:failures] == 0

  StateManager.update(:circuit_breaker) do |c|
    c[:failures] = 0
    # Don't clear last_error if breaker is already tripped (preserves context)
    c[:last_error] = nil unless c[:tripped]
    c
  end
end

# === INTELLIGENCE: Error Signature Normalization ===

def normalize_error(response_str)
  return nil unless response_str.is_a?(String)

  ERROR_SIGNATURES.each do |signature, patterns|
    if patterns.any? { |p| response_str.match?(p) }
      return signature
    end
  end

  # Generic error if no specific signature
  return 'GENERIC_ERROR' if response_str.match?(ERROR_PATTERN)

  nil
end

def track_error_signature(signature, tool_name, response_str)
  return unless signature

  sig_key = signature.to_sym  # Use symbol for consistent hash access after JSON symbolize
  doom_loop_caught = false

  StateManager.update(:circuit_breaker) do |cb|
    cb[:error_signatures] ||= {}
    cb[:error_signatures][sig_key] = (cb[:error_signatures][sig_key] || 0) + 1

    # Rule #3: repeated same-root-cause failures require research after two strikes.
    if cb[:error_signatures][sig_key] >= 2 && !cb[:tripped]
      cb[:tripped] = true
      cb[:tripped_at] = Time.now.iso8601
      cb[:last_error] = "#{signature} x#{cb[:error_signatures][sig_key]}: #{response_str[0..100]}"
      doom_loop_caught = true
    end

    cb
  end

  # Q2 validation: track doom loop catch (separate update avoids nested lock)
  track_validation_doom_loop if doom_loop_caught
end

# === Q2 VALIDATION: Doom Loop Tracking ===
# Called when circuit breaker trips (from either consecutive failures or same-signature)
# Separate function to avoid nested StateManager locks

def track_validation_doom_loop
  StateManager.update(:validation) do |v|
    v[:doom_loops_caught] = (v[:doom_loops_caught] || 0) + 1
    v[:last_updated] = Time.now.iso8601
    v
  end
rescue StandardError
  # Don't fail on validation tracking
end

# === INTELLIGENCE: Action Logging for Pattern Learning ===

def log_action_for_learning(tool_name, tool_input, success, error_sig = nil)
  StateManager.update(:action_log) do |log|
    log ||= []
    log << {
      tool: tool_name,
      timestamp: Time.now.iso8601,
      success: success,
      error_sig: error_sig,
      input_summary: summarize_input(tool_input)
    }
    log.last(MAX_ACTION_LOG)
  end
rescue StandardError
  # Don't fail on logging errors
end

def summarize_input(input)
  return nil unless input.is_a?(Hash)

  file_path = input['file_path'] || input[:file_path]
  if file_path
    # Include content preview for markdown files (enables weasel word detection)
    if file_path.end_with?('.md')
      content = input['new_string'] || input[:new_string] || input['content'] || input[:content]
      return "#{file_path}: #{content[0..120]}" if content
    end
    return file_path
  end

  input['command']&.to_s&.slice(0, 50) || input[:command]&.to_s&.slice(0, 50) ||
    input['prompt']&.to_s&.slice(0, 50) || input[:prompt]&.to_s&.slice(0, 50)
end
