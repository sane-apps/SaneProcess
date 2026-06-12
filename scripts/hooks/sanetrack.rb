#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

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
require 'shellwords'
require 'time'
require_relative 'core/mandatory_workflows'
require_relative 'core/state_manager'
require_relative 'core/process_metrics'
require_relative 'core/context_compact'
require_relative 'sanetrack_research'
require_relative 'sanetrack_proofs'
require_relative 'sanetrack_state_updates'
require_relative 'sanetools_checks'

LOG_FILE = File.expand_path('../../.claude/sanetrack.log', __dir__)

# === TOOL CLASSIFICATION ===

EDIT_TOOLS = %w[Edit Write NotebookEdit].freeze
FAILURE_TOOLS = %w[Bash Edit Write].freeze  # Tools that can fail and trigger circuit breaker

# === MCP VERIFICATION TOOLS ===
# Map MCP names to their read-only verification tools. Each pattern matches
# both the bare prefix (mcp__<server>__) and the plugin-loaded form
# (mcp__plugin_<plugin>_<server>__) — see SaneToolsResearch#mcp_tool_pattern.
MCP_VERIFICATION_PATTERNS = {
  apple_docs: SaneToolsChecks.mcp_tool_pattern('apple-docs'),
  context7: SaneToolsChecks.mcp_tool_pattern('context7'),
  github: SaneToolsChecks.mcp_tool_pattern('github', /(?:search_|get_|list_)/)
}.freeze

# === RESEARCH TRACKING ===
# Patterns to detect which research category a Task agent is completing
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

# === MOCK-PASSTHROUGH DETECTION ===
# Detects tests that only verify mock return values (testing the mock, not real code).
# Pattern: mock sets up Handler to return X, then test asserts X came back.
# These tests always pass regardless of real implementation correctness.
MOCK_HANDLER_PATTERN = /Handler\s*[=:]\s*\{/i.freeze
MOCK_VARIABLE_PATTERN = /\b(mock\w*|stub\w*|fake\w*|spy\w*)\b/i.freeze

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

UI_FILE_PATTERNS = [
  %r{/Views?/.*\.(swift|tsx|jsx|ts|js|html|css)$}i,
  %r{/Screens?/.*\.(swift|tsx|jsx|ts|js|html|css)$}i,
  %r{/Components?/.*\.(swift|tsx|jsx|ts|js|html|css)$}i,
  %r{/website/.*\.(html|css|js|tsx|jsx)$}i,
  %r{/Assets?\.xcassets/}i,
  %r{/Preview Content/}i,
  /ContentView\.swift$/i,
  /App\.swift$/i,
  /index\.html$/i,
  /privacy\.html$/i
].freeze

VISUAL_EVIDENCE_COMMAND_PATTERNS = [
  /SaneMaster\.rb\s+visual[_-]smoke/i,
  /SaneMaster\.rb\s+customer[_-]ui[_-](?:sweep|contract)/i,
  /capture-mini-screenshot\.sh/i,
  /xcrun\s+simctl\s+io\s+\S+\s+screenshot/i,
  /\bscreencapture\b/i,
  /take_screenshot\.(?:py|ps1)/i,
  /\bXCUIScreen\.main\.screenshot\b/i,
  /SANESCAN_SCREENSHOT_DIR/i,
  /visual-audit/i
].freeze

VISUAL_AUDIT_NOTE_PATTERNS = [
  /visual\s+audit/i,
  /screenshot\s+audit/i,
  /balanced/i,
  /clear/i,
  /not\s+confusing/i,
  /beautiful/i,
  /dark[- ]mode/i,
  /customer[- ]facing/i
].freeze

# === TAUTOLOGY DETECTION (Rule #7) ===
def check_tautologies(tool_name, tool_input)
  return nil unless EDIT_TOOLS.include?(tool_name)

  file_path = tool_input['file_path'] || tool_input[:file_path] || ''
  return nil unless file_path.match?(TEST_FILE_PATTERN)

  new_string = tool_input['new_string'] || tool_input[:new_string] || ''
  return nil if new_string.empty?

  warnings = []

  # Check syntactic tautology patterns
  matches = TAUTOLOGY_PATTERNS.select { |pattern| new_string.match?(pattern) }
  unless matches.empty?
    warnings << "#{matches.length} syntactic tautology pattern(s) (always-true assertions)"
  end

  # Check mock-passthrough: tests that only verify mock return values
  mock_warning = check_mock_passthrough(new_string)
  warnings << mock_warning if mock_warning

  return nil if warnings.empty?

  "RULE #7 WARNING: Test quality issue detected\n" \
  "   File: #{File.basename(file_path)}\n" \
  "   #{warnings.join("\n   ")}\n" \
  "   Fix: Tests must assert real behavior via real code paths, not mock return values"
end

# Detects mock-passthrough tests: mock handler set up, then assertions only verify
# the mock returned what it was told to. These tests always pass regardless of
# whether the real code works.
def check_mock_passthrough(code)
  handler_count = code.scan(MOCK_HANDLER_PATTERN).length
  return nil if handler_count.zero?

  # Count real assertions (not tautologies)
  assertion_count = code.scan(/#expect\s*\(|XCTAssert/).length
  return nil if assertion_count.zero?

  # If code has mock handlers but no call to a real (non-mock) service/method,
  # it's likely testing the mock, not real code.
  has_mock_vars = code.match?(MOCK_VARIABLE_PATTERN)
  lines = code.lines

  # Check if any assertion references real code (not just mock variables)
  assertion_lines = lines.select { |l| l.match?(/#expect|XCTAssert/) }
  mock_only_assertions = assertion_lines.all? do |line|
    # Assertion only references mock variables, handler results, or literal values
    line.match?(/mock\w*\.|stub\w*\.|fake\w*\.|\.count\s*==\s*\d|\.isEmpty|\.first\??\s*==|== \[/)
  end

  if has_mock_vars && mock_only_assertions
    "Mock-passthrough: #{handler_count} handler(s) set up, all #{assertion_count} assertion(s) only verify mock return values"
  elsif has_mock_vars && handler_count >= assertion_count
    "Suspicious: #{handler_count} mock handler(s) vs #{assertion_count} assertion(s) — likely testing mock, not real code"
  end
end

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
include SaneTrackStateUpdates

# === SKILL TRACKING ===
# Track Skill tool invocations and Task tool calls (subagents)

SKILL_RUNNER_PATTERNS = MandatoryWorkflows.skill_requirements.each_with_object({}) do |(name, config), acc|
  patterns = MandatoryWorkflows.runner_patterns_for(name)
  next if patterns.empty? || !config[:requires_runner]

  acc[name.to_s] = patterns
end.freeze

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
  return unless ['Task', 'spawn_agent', 'multi_agent_v1.spawn_agent'].include?(tool_name)

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

def track_skill_runner(tool_name, tool_input, tool_response)
  return unless tool_name == 'Bash'

  skill_state = StateManager.get(:skill)
  required_skill = skill_state[:required]
  return unless required_skill

  command = tool_input['command'] || tool_input[:command] || ''
  return if command.empty?

  patterns = SKILL_RUNNER_PATTERNS[required_skill] || []
  return unless patterns.any? { |pattern| command.match?(pattern) }

  proof = runner_proof_for(required_skill, command, tool_response)
  StateManager.update(:skill) do |s|
    s[:runner_started] = true
    s[:runner_attempts] ||= []
    s[:runner_attempts] << {
      command: command.strip,
      at: Time.now.iso8601,
      success: bash_response_successful?(tool_response)
    }
    s[:runner_attempts] = s[:runner_attempts].last(10)
    s[:runner_commands] ||= []
    trimmed = command.strip
    s[:runner_commands] << trimmed unless s[:runner_commands].include?(trimmed)
    s[:runner_commands] = s[:runner_commands].last(10)
    if proof
      s[:runner_proved] = true
      s[:runner_used] = true
      s[:runner_proof] = proof
    else
      s[:runner_proved] = false unless s[:runner_proved]
      s[:runner_used] = false unless s[:runner_used]
    end
    s
  end
rescue StandardError => e
  warn "⚠️  Skill runner tracking error: #{e.message}" if ENV['DEBUG']
end

def bash_response_successful?(tool_response)
  error = tool_response['error'] || tool_response[:error]
  return false unless error.to_s.strip.empty?

  exit_code = tool_response['exit_code'] || tool_response[:exit_code]
  return exit_code.to_i.zero? unless exit_code.nil?

  output = tool_response['output'] || tool_response[:output] || tool_response['stdout'] || tool_response[:stdout]
  output.to_s.strip.match?(/\b(ok|pass(?:ed)?|success(?:ful)?|complete(?:d)?)\b/i)
end

def runner_proof_for(required_skill, command, tool_response)
  return nil unless bash_response_successful?(tool_response)

  case required_skill.to_s
  when 'evolve'
    latest_authoritative_tool_discovery_receipt(command)
  when 'verify'
    latest_recent_process_metric('verify') do |event|
      event['success'] == true
    end&.then { |event| { type: 'process_metric', metric: 'verify', timestamp: event['timestamp'], tests_run: event['tests_run'] } }
  when 'ship'
    release_preflight_proof
  when 'status'
    latest_recent_process_metric('workflow_receipt') do |event|
      event['workflow'].to_s == 'status' && event['success'] == true
    end&.then { |event| { type: 'process_metric', metric: 'workflow_receipt', workflow: 'status', timestamp: event['timestamp'] } }
  when 'check_inbox'
    latest_recent_process_metric('workflow_receipt') do |event|
      event['workflow'].to_s == 'check_inbox' && event['success'] == true
    end&.then { |event| { type: 'process_metric', metric: 'workflow_receipt', workflow: 'check_inbox', timestamp: event['timestamp'] } }
  else
    { type: 'command_success', command: command.strip }
  end
end

# === RELEASE/VERIFICATION PROOF HELPERS (in sanetrack_proofs.rb) ===

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

# Map tool names to their research category. MCP entries are patterns that
# also match the plugin-loaded prefix (mcp__plugin_<plugin>_<server>__).
TOOL_TO_RESEARCH_CATEGORY = {
  SaneToolsChecks.mcp_tool_pattern('apple-docs') => :docs,
  SaneToolsChecks.mcp_tool_pattern('context7') => :docs,
  'WebSearch' => :web,
  'WebFetch' => :web,
  SaneToolsChecks.mcp_tool_pattern('github', /(?:search_|get_|list_)/) => :github,
  'Read' => :local,
  'Grep' => :local,
  'Glob' => :local
}.freeze

def invalidate_empty_research(tool_name, tool_response)
  # Find which research category this tool belongs to
  category = nil
  TOOL_TO_RESEARCH_CATEGORY.each do |prefix, cat|
    matched = prefix.is_a?(Regexp) ? tool_name.match?(prefix) : (tool_name == prefix || tool_name.start_with?(prefix))
    if matched
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
# Extracted to sanetrack_tracking.rb per Rule #10 (file size limit)
require_relative 'sanetrack_tracking'

# === FEATURE REMINDERS + LOGGING ===
# Extracted to sanetrack_reminders.rb per Rule #10
require_relative 'sanetrack_reminders'

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
  track_skill_runner(tool_name, tool_input, tool_response)

  # === RESEARCH PROTOCOL: Validate research agent writes ===
  SaneTrackResearch.validate_research_write(tool_name)

  # === INTELLIGENCE: Detect actual failures, not text matching ===
  error_sig = detect_actual_failure(tool_name, tool_response)
  # Sibling-hook enforcement feedback is the process talking, not the work
  # failing. Exclude it BEFORE both counters (consecutive AND signature) —
  # the 2026-06-12 re-trip came through the signature path, which the
  # original track_failure-only exclusion missed.
  error_sig = nil if error_sig && tool_response.to_s.match?(/hook feedback|SANETOOLS BLOCKED|TaskCompleted hook|completed without recent test verification/i)
  is_error = !error_sig.nil?

  if is_error
    # Track failure (legacy count)
    track_failure(tool_name, tool_response)

    # === MCP VERIFICATION: Track failures for MCP tools ===
    track_mcp_verification(tool_name, false)

    # === INTELLIGENCE: Track by signature (2x same = trip, even with successes) ===
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
    untrip_breaker_on_green_verify(tool_name, tool_input)
    track_edit(tool_name, tool_input, tool_response)
    track_bash_mutation(tool_name, tool_input, tool_response)

    # === RESEARCH PROTOCOL: Check research.md size cap ===
    SaneTrackResearch.check_research_size(tool_name, tool_input)

    # === DEPLOYMENT SAFETY: Track signing and stapling ===
    track_deployment_actions(tool_name, tool_input, tool_response)

    # === HANDOFF TRACKING: Track significant edits and handoff/memory updates ===
    track_handoff_status(tool_name, tool_input)

    # === RULE #4: Track test/verification commands ===
    track_verification(tool_name, tool_input)

    # === VISUAL VERIFICATION: Track screenshot/audit evidence commands ===
    track_visual_evidence(tool_name, tool_input)

    # === MCP VERIFICATION: Track successes for MCP tools ===
    track_mcp_verification(tool_name, true)

    # === SESSION DOC TRACKING ===
    track_session_doc_read(tool_name, tool_input)

    # === STARTUP GATE STEP TRACKING ===
    track_startup_gate_step(tool_name, tool_input)

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
    require_relative 'self_test_environment'
    exit SelfTestEnvironment.run_isolated(__FILE__)
  elsif ARGV.include?('--self-test-internal')
    self_test
  elsif ARGV.include?('--status')
    show_status
  else
    begin
      input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
      tool_name = input['tool_name'] || 'unknown'
      tool_input = input['tool_input'] || {}
      tool_response = input['tool_response'] || {}
      exit process_result(tool_name, tool_input, tool_response)
    rescue JSON::ParserError, Errno::ENOENT
      exit 0  # Don't fail on parse errors
    end
  end
end
