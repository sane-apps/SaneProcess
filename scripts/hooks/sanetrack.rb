#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack - PostToolUse Hook
# ==============================================================================
# Tracks tool results after execution. Updates state based on outcomes.
#
# Exit codes:
#   0 = success (tool already executed)
#   2 = error message for Claude (tool already executed)
#
# What this tracks:
#   1. Edit counts and unique files
#   2. Tool failures (for circuit breaker)
#   3. Research quality (meaningful output validation)
#   4. Patterns for learning
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'core/state_manager'
require_relative 'core/context_compact'
require_relative 'sanetrack_research'

LOG_FILE = File.expand_path('../../.claude/sanetrack.log', __dir__)

# === TOOL CLASSIFICATION ===

EDIT_TOOLS = %w[Edit Write NotebookEdit].freeze
FAILURE_TOOLS = %w[Bash Edit Write].freeze  # Tools that can fail and trigger circuit breaker

# === MCP VERIFICATION TOOLS ===
# Map MCP names to their read-only verification tools
# NOTE: Memory MCP removed Jan 2026 - using Sane-Mem (localhost:37777) instead
MCP_VERIFICATION_PATTERNS = {
  apple_docs: /^mcp__apple-docs__/,
  context7: /^mcp__context7__/,
  github: /^mcp__github__(search_|get_|list_)/
}.freeze

# === RESEARCH TRACKING ===
# Patterns to detect which research category a Task agent is completing
# NOTE: Memory category removed - past learnings auto-captured by Sane-Mem
RESEARCH_PATTERNS = {
  docs: /context7|apple-docs|documentation|mcp__context7|mcp__apple-docs/i,
  web: /web.*search|websearch|mcp__.*web/i,
  github: /github|mcp__github/i,
  local: /grep|glob|read|explore|codebase/i
}.freeze

# === TAUTOLOGY PATTERNS (Rule #7 - consolidated from test_quality_checker.rb) ===
# Detects tests that always pass (useless tests)
TAUTOLOGY_PATTERNS = [
  # Literal boolean assertions
  /#expect\s*\(\s*true\s*\)/i,
  /#expect\s*\(\s*false\s*\)/i,
  /XCTAssertTrue\s*\(\s*true\s*\)/i,
  /XCTAssertFalse\s*\(\s*false\s*\)/i,
  /XCTAssert\s*\(\s*true\s*\)/i,
  # Boolean tautology (always true)
  /#expect\s*\([^)]+==\s*true\s*\|\|\s*[^)]+==\s*false\s*\)/i,
  # TODO placeholders
  /XCTAssert.*TODO/i,
  /#expect.*TODO/i,
  # M9 additions: Self-comparison (always true)
  /#expect\s*\(\s*(\w+)\s*==\s*\1\s*\)/,
  /XCTAssertEqual\s*\(\s*(\w+)\s*,\s*\1\s*\)/,
  # M9: Trivial non-nil check (need context to be sure, but flag for review)
  /#expect\s*\([^)]+\s*!=\s*nil\s*\)\s*$/, # Standalone != nil often tautology
  /XCTAssertNotNil\s*\(\s*\w+\s*\)\s*$/,  # Just variable, no setup context
  # M9: Always-true comparisons
  /#expect\s*\([^)]+\.count\s*>=\s*0\s*\)/i,      # count >= 0 always true
  /XCTAssertGreaterThanOrEqual\s*\([^,]+\.count\s*,\s*0\s*\)/i,
  # M9: Empty assertion (no actual check)
  /#expect\s*\(\s*\)/,
  /XCTAssert\s*\(\s*\)/
].freeze

# === TEST FILE PATTERN ===
TEST_FILE_PATTERN = %r{(Tests?/|Specs?/|_test\.|_spec\.|Tests?\.swift|Spec\.swift)}i.freeze

# === VERIFICATION DETECTION (Rule #4 enforcement) ===
# Commands that count as "testing" or "verifying" work
TEST_COMMAND_PATTERNS = [
  /xcodebuild\s+test/i,
  /swift\s+test/i,
  /ruby\s+.*test/i,
  /pytest|python.*-m\s+test/i,
  /npm\s+test|yarn\s+test|bun\s+test/i,
  /rspec|minitest/i,
  /ruby\s+.*tier_tests/i,
  /ruby\s+.*qa\.rb/i,
  /ruby\s+.*validation_report/i,
  /ruby\s+.*self[_-]test/i,
  /--self-test/i,
  /curl\s+.*health|curl\s+.*status|curl\s+.*readiness/i,
  /sqlite3.*SELECT.*count|sqlite3.*SELECT.*FROM/i,
  /wrangler\s+(deploy|publish)/i,
  /gh\s+pr\s+checks/i
].freeze

# === TAUTOLOGY DETECTION (Rule #7) ===
def check_tautologies(tool_name, tool_input)
  return nil unless EDIT_TOOLS.include?(tool_name)

  file_path = tool_input['file_path'] || tool_input[:file_path] || ''
  return nil unless file_path.match?(TEST_FILE_PATTERN)

  new_string = tool_input['new_string'] || tool_input[:new_string] || ''
  return nil if new_string.empty?

  matches = TAUTOLOGY_PATTERNS.select { |pattern| new_string.match?(pattern) }
  return nil if matches.empty?

  # Build warning message
  "RULE #7 WARNING: Test contains tautology (always passes)\n" \
  "   File: #{File.basename(file_path)}\n" \
  "   Found: #{matches.length} suspicious pattern(s)\n" \
  "   Fix: Replace with meaningful assertions that test actual behavior"
end

# === FEATURE REMINDER COOLDOWNS ===
# Don't spam reminders - minimum time between same reminder type
REMINDER_COOLDOWN = 300  # 5 minutes in seconds

# === ERROR PATTERNS ===

ERROR_PATTERN = Regexp.union(
  /error/i,
  /failed/i,
  /exception/i,
  /cannot/i,
  /unable/i,
  /denied/i,
  /not found/i,
  /no such/i
).freeze

# === INTELLIGENCE: Error Signature Normalization ===
# Same underlying error should have same signature

ERROR_SIGNATURES = {
  'COMMAND_NOT_FOUND' => [/command not found/i, /not recognized as.*command/i],
  'PERMISSION_DENIED' => [/permission denied/i, /access denied/i, /not permitted/i],
  'FILE_NOT_FOUND' => [/no such file/i, /file not found/i, /doesn't exist/i],
  'BUILD_FAILED' => [/build failed/i, /compilation error/i, /compile error/i],
  'SYNTAX_ERROR' => [/syntax error/i, /parse error/i, /unexpected token/i],
  'TYPE_ERROR' => [/type.*error/i, /cannot convert/i, /type mismatch/i],
  'NETWORK_ERROR' => [/connection refused/i, /timeout/i, /network error/i],
  'MEMORY_ERROR' => [/out of memory/i, /memory error/i, /allocation failed/i],
}.freeze

# === INTELLIGENCE: Action Log for Pattern Learning ===
MAX_ACTION_LOG = 20

# === SKILL TRACKING ===
# Track Skill tool invocations and Task tool calls (subagents)

def track_skill_invocation(tool_name, tool_input)
  return unless tool_name == 'Skill'

  skill_name = tool_input['skill'] || tool_input[:skill]
  return unless skill_name

  StateManager.update(:skill) do |s|
    s[:invoked] = true
    s[:invoked_at] = Time.now.iso8601
    s[:invoked_skill] = skill_name
    s
  end
rescue StandardError => e
  warn "⚠️  Skill tracking error: #{e.message}" if ENV['DEBUG']
end

def track_subagent_spawn(tool_name, tool_input)
  return unless tool_name == 'Task'

  # Only count if a skill is required
  skill_state = StateManager.get(:skill)
  return unless skill_state[:required]

  StateManager.update(:skill) do |s|
    s[:subagents_spawned] = (s[:subagents_spawned] || 0) + 1
    s
  end
rescue StandardError => e
  warn "⚠️  Subagent tracking error: #{e.message}" if ENV['DEBUG']
end

# === RESEARCH OUTPUT VALIDATION ===
# Revoke a research category if the output was empty/meaningless
# Prevents gaming where you search for something impossible and claim "done"

EMPTY_RESEARCH_PATTERNS = [
  /^0$/,                           # Zero results
  /no results? found/i,
  /0 match(es)?/i,
  /nothing found/i,
  /no (?:files|documents|repos|results)/i,
  /could not find/i,
  /did not find/i
].freeze

# Map tool names to their research category
TOOL_TO_RESEARCH_CATEGORY = {
  'mcp__apple-docs__' => :docs,
  'mcp__context7__' => :docs,
  'WebSearch' => :web,
  'WebFetch' => :web,
  'mcp__github__search_' => :github,
  'mcp__github__get_' => :github,
  'mcp__github__list_' => :github,
  'Read' => :local,
  'Grep' => :local,
  'Glob' => :local
}.freeze

def invalidate_empty_research(tool_name, tool_response)
  # Find which research category this tool belongs to
  category = nil
  TOOL_TO_RESEARCH_CATEGORY.each do |prefix, cat|
    if tool_name == prefix || tool_name.start_with?(prefix)
      category = cat
      break
    end
  end
  return unless category

  # Check if the response is empty/meaningless
  response_str = extract_response_text(tool_response)
  return if response_str.nil? || response_str.empty?

  is_empty = EMPTY_RESEARCH_PATTERNS.any? { |p| response_str.match?(p) }
  # Also check for very short responses (likely empty results)
  is_empty ||= response_str.strip.length < 5 && !response_str.match?(/\S{3,}/)

  return unless is_empty

  # Revoke this research category
  current = StateManager.get(:research, category)
  return unless current # Nothing to revoke

  StateManager.update(:research) do |r|
    r[category] = nil
    r
  end

  warn "RESEARCH INVALIDATED: #{category} (empty output from #{tool_name})"
  warn "  Re-do this research with a meaningful query."
rescue StandardError
  # Don't fail on validation errors
end

def extract_response_text(tool_response)
  return '' unless tool_response.is_a?(Hash)

  # Try common response fields
  tool_response['content'] || tool_response[:content] ||
    tool_response['output'] || tool_response[:output] ||
    tool_response['stdout'] || tool_response[:stdout] ||
    tool_response['result'] || tool_response[:result] ||
    tool_response.to_s[0..500]
end

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
    e
  end

  # Track edits-since-last-test for Rule #4
  StateManager.update(:verification) do |v|
    v[:edits_before_test] = (v[:edits_before_test] || 0) + 1
    v
  end
rescue StandardError
  # Don't fail on verification tracking
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
    v[:last_test_at] = Time.now.iso8601
    v[:test_commands] ||= []
    v[:test_commands] << cmd_summary unless v[:test_commands].include?(cmd_summary)
    v[:test_commands] = v[:test_commands].last(10) # Keep last 10
    v[:edits_before_test] = 0 # Reset — tests cover prior edits
    v
  end
rescue StandardError
  # Don't fail on verification tracking
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

      # Check if ALL MCPs are now verified
      all_verified = MCP_VERIFICATION_PATTERNS.keys.all? do |mcp|
        health[:mcps][mcp] && health[:mcps][mcp][:verified]
      end

      if all_verified && !health[:verified_this_session]
        health[:verified_this_session] = true
        health[:last_verified] = Time.now.iso8601
        warn '✅ ALL MCPs VERIFIED - edits now allowed'
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

def track_failure(tool_name, tool_response)
  return unless FAILURE_TOOLS.include?(tool_name)

  # Check if response indicates failure
  response_str = tool_response.to_s
  is_failure = response_str.match?(ERROR_PATTERN)

  return unless is_failure

  doom_loop_caught = false

  StateManager.update(:circuit_breaker) do |cb|
    cb[:failures] = (cb[:failures] || 0) + 1
    cb[:last_error] = response_str[0..200]

    # Trip breaker at 3 failures
    if cb[:failures] >= 3 && !cb[:tripped]
      cb[:tripped] = true
      cb[:tripped_at] = Time.now.iso8601
      doom_loop_caught = true
    end

    cb
  end

  # Q2 validation: track doom loop catch (separate update avoids nested lock)
  track_validation_doom_loop if doom_loop_caught
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

    # Trip if same signature 3x (even with other successes between)
    if cb[:error_signatures][sig_key] >= 3 && !cb[:tripped]
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

# === FEATURE REMINDERS ===
# Suggest underutilized features at appropriate moments

def should_remind?(reminder_type)
  reminders = StateManager.get(:reminders) || {}
  last_at = reminders["#{reminder_type}_at".to_sym]
  return true unless last_at

  begin
    time_since = Time.now - Time.parse(last_at)
    time_since >= REMINDER_COOLDOWN
  rescue ArgumentError
    true  # If timestamp is invalid, allow reminder
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
  return unless edit_count % 5 == 0 && edit_count > 0  # Every 5 edits
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
  return unless pattern.include?('**') || pattern.length > 30  # Complex search

  return unless should_remind?(:explore)

  record_reminder(:explore)

  warn ''
  warn '💡 TIP: Quick lookup? → Task(subagent_type: "Explore") — fast, disposable'
  warn '   Real research? → Task(subagent_type: "general-purpose", model: "sonnet") — persists to .claude/research.md'
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

# === MAIN PROCESSING ===

# Detect actual tool failure vs text that just contains error-like words
# Key insight: "No such file" from ls is informational, not a failure
# Key insight: File content containing "type error" is NOT a tool error
def detect_actual_failure(tool_name, tool_response)
  return nil unless tool_response.is_a?(Hash)

  # Check for explicit error fields first (most reliable)
  if tool_response['error'] || tool_response[:error]
    error_text = (tool_response['error'] || tool_response[:error]).to_s
    return normalize_error(error_text) || 'GENERIC_ERROR'
  end

  # Check for stderr with actual error content
  stderr = tool_response['stderr'] || tool_response[:stderr]
  if stderr.is_a?(String) && !stderr.empty?
    sig = normalize_error(stderr)
    return sig if sig
  end

  # For Bash: check exit code and be smart about stdout
  if tool_name == 'Bash'
    exit_code = tool_response['exit_code'] || tool_response[:exit_code]
    return 'COMMAND_FAILED' if exit_code && exit_code != 0

    stdout = tool_response['stdout'] || tool_response[:stdout] || ''
    # "No such file" from ls/cat is informational when checking existence
    # Only flag if it's a command interpreter error (bash:, ruby:, etc.)
    if stdout.match?(/no such file|not found/i)
      return nil unless stdout.match?(/^(bash|sh|ruby|python|node):\s/i)
    end
  end

  # For Read: file not found comes through error field, not content
  # File content containing words like "error" is NOT a tool failure
  return nil if tool_name == 'Read'

  # For Edit/Write: actual errors come through error field
  return nil if %w[Edit Write].include?(tool_name)

  # For MCP tools: check error field only
  return nil if tool_name.start_with?('mcp__')

  # For Task: agent errors come through error field
  return nil if tool_name == 'Task'

  nil
end

def process_result(tool_name, tool_input, tool_response)
  # === SKILL TRACKING (before error detection) ===
  track_skill_invocation(tool_name, tool_input)
  track_subagent_spawn(tool_name, tool_input)

  # === RESEARCH PROTOCOL: Validate research agent writes ===
  SaneTrackResearch.validate_research_write(tool_name)

  # === INTELLIGENCE: Detect actual failures, not text matching ===
  error_sig = detect_actual_failure(tool_name, tool_response)
  is_error = !error_sig.nil?

  if is_error
    # Track failure (legacy count)
    track_failure(tool_name, tool_response)

    # === MCP VERIFICATION: Track failures for MCP tools ===
    track_mcp_verification(tool_name, false)

    # === INTELLIGENCE: Track by signature (3x same = trip, even with successes) ===
    response_str = tool_response.to_s[0..200]
    track_error_signature(error_sig, tool_name, response_str)

    # === INTELLIGENCE: Log action for pattern learning ===
    log_action_for_learning(tool_name, tool_input, false, error_sig)

    log_action(tool_name, 'failure')

    # === FEATURE REMINDER: Suggest /rewind on errors ===
    cb = StateManager.get(:circuit_breaker)
    emit_rewind_reminder(cb[:failures] || 0) if cb[:failures] && cb[:failures] >= 1
  else
    reset_failure_count(tool_name)
    track_edit(tool_name, tool_input, tool_response)

    # === RESEARCH PROTOCOL: Check research.md size cap ===
    SaneTrackResearch.check_research_size(tool_name, tool_input)

    # === RULE #4: Track test/verification commands ===
    track_verification(tool_name, tool_input)

    # === MCP VERIFICATION: Track successes for MCP tools ===
    track_mcp_verification(tool_name, true)

    # === SESSION DOC TRACKING ===
    track_session_doc_read(tool_name, tool_input)

    # === RESEARCH OUTPUT VALIDATION ===
    # Revoke research category if output was empty/meaningless
    invalidate_empty_research(tool_name, tool_response)

    # === RULE #7: Tautology detection for test files ===
    tautology_warning = check_tautologies(tool_name, tool_input)
    warn tautology_warning if tautology_warning

    # === INTELLIGENCE: Log action for pattern learning ===
    log_action_for_learning(tool_name, tool_input, true, nil)

    log_action(tool_name, 'success')

    # === GIT PUSH REMINDER ===
    # After successful git commit, check if push is needed
    if tool_name == 'Bash'
      command = tool_input['command'] || tool_input[:command] || ''
      if command.match?(/git\s+commit/i) && !command.match?(/git\s+push/i)
        # Check for unpushed commits
        ahead_check = `git status 2>/dev/null | grep -o "ahead of.*by [0-9]* commit"`
        unless ahead_check.empty?
          warn ''
          warn '🚨 GIT PUSH REMINDER 🚨'
          warn "   You committed but haven't pushed!"
          warn "   Status: #{ahead_check.strip}"
          warn ''
          warn '   → Run: git push'
          warn '   → READ ALL DOCUMENTATION before claiming done'
          warn '   → Verify README is accurate and up to date'
          warn ''
        end
      end
    end

    # === FEATURE REMINDER: Suggest /context after edits ===
    if EDIT_TOOLS.include?(tool_name)
      edits = StateManager.get(:edits)
      emit_context_reminder(edits[:count] || 0)
    end

    # === FEATURE REMINDER: Suggest Explore subagent for complex searches ===
    emit_explore_reminder(tool_name, tool_input)

    # === CONTEXT WARNING: Check transcript size, warn before auto-compact ===
    ContextCompact.check_and_warn
  end

  0  # PostToolUse always returns 0 (tool already executed)
end

# === SELF-TEST ===

def self_test
  require_relative 'sanetrack_test'
  exit SaneTrackTest.run(
    method(:process_result),
    method(:detect_actual_failure),
    method(:normalize_error),
    method(:check_tautologies),
    method(:invalidate_empty_research),
    __FILE__
  )
end

def show_status
  edits = StateManager.get(:edits)
  cb = StateManager.get(:circuit_breaker)

  warn 'SaneTrack Status'
  warn '=' * 40
  warn ''
  warn 'Edits:'
  warn "  count: #{edits[:count]}"
  warn "  unique_files: #{edits[:unique_files]&.length || 0}"
  warn ''
  warn 'Circuit Breaker:'
  warn "  failures: #{cb[:failures]}"
  warn "  tripped: #{cb[:tripped]}"
  warn "  last_error: #{cb[:last_error]&.[](0..50)}" if cb[:last_error]

  exit 0
end

# === MAIN ===

if __FILE__ == $PROGRAM_NAME
  if ARGV.include?('--self-test')
    self_test
  elsif ARGV.include?('--status')
    show_status
  else
    begin
      input = JSON.parse($stdin.read)
      tool_name = input['tool_name'] || 'unknown'
      tool_input = input['tool_input'] || {}
      tool_response = input['tool_response'] || {}
      exit process_result(tool_name, tool_input, tool_response)
    rescue JSON::ParserError, Errno::ENOENT
      exit 0  # Don't fail on parse errors
    end
  end
end
