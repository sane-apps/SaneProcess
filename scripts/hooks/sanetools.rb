#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools - PreToolUse Hook
# ==============================================================================
# Enforces all requirements before tool execution.
#
# Exit codes:
#   0 = allow
#   2 = BLOCK (tool does NOT execute)
#
# What this enforces:
#   1. Blocked paths (/.ssh, /.aws, secrets, system dirs)
#   2. Research before editing (5 categories via Task agents)
#   3. Circuit breaker (3 failures = blocked)
#   4. Bash file write bypass detection
#   5. Subagent bypass detection
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'core/state_manager'

# === SAFEMODE BYPASS ===
BYPASS_FILE = File.expand_path('../../.claude/bypass_active.json', __dir__)
BYPASS_ACTIVE = File.exist?(BYPASS_FILE)

LOG_FILE = File.expand_path('../../.claude/sanetools.log', __dir__)

# === TOOL CLASSIFICATION ===

EDIT_TOOLS = %w[Edit Write NotebookEdit].freeze
RESEARCH_TOOLS = %w[Read Grep Glob WebSearch WebFetch Task].freeze
MEMORY_TOOLS = %w[mcp__memory__read_graph mcp__memory__search_nodes].freeze

# === INTELLIGENCE: Bootstrap Whitelist ===
# These tools ALWAYS allowed to prevent circular blocking (e.g., can't research because research is blocked)
#
# CRITICAL: Categorize by DAMAGE POTENTIAL, not by name!
#   - Read-only: No damage possible → always allow
#   - Local mutation: Affects this project → require research
#   - Global mutation: Affects ALL projects (MCP memory) → require research
#   - External mutation: Affects outside systems (GitHub) → require research
#
# Learned from LIVE FAILURE: Claude nuked global MCP memory without understanding
# it's shared across all projects. Only READ-ONLY operations are bootstrap tools.
BOOTSTRAP_TOOL_PATTERN = Regexp.union(
  # Read-only memory ops (global but safe)
  /^mcp__memory__read_graph$/,
  /^mcp__memory__search_nodes$/,
  /^mcp__memory__open_nodes$/,
  # Read-only local ops
  /^Read$/,
  /^Grep$/,
  /^Glob$/,
  # Read-only web ops
  /^WebSearch$/,
  /^WebFetch$/,
  # Read-only doc ops
  /^mcp__apple-docs__/,
  /^mcp__context7__/,
  # Read-only GitHub ops (search, get, list)
  /^mcp__github__search_/,
  /^mcp__github__get_/,
  /^mcp__github__list_/,
  # Task agents (for research delegation)
  /^Task$/
).freeze

# === MUTATION PATTERNS (require research) ===

# Global mutations - affect ALL projects via shared MCP memory
GLOBAL_MUTATION_PATTERN = Regexp.union(
  /^mcp__memory__delete_/,
  /^mcp__memory__create_/,
  /^mcp__memory__add_/
).freeze

# External mutations - affect systems outside this project
EXTERNAL_MUTATION_PATTERN = Regexp.union(
  /^mcp__github__create_/,      # create_issue, create_pr, create_branch, create_repository
  /^mcp__github__push_/,        # push_files
  /^mcp__github__update_/,      # update_issue, update_pull_request_branch
  /^mcp__github__merge_/,       # merge_pull_request
  /^mcp__github__fork_/,        # fork_repository
  /^mcp__github__add_/          # add_issue_comment
).freeze

# === INTELLIGENCE: Requirement Satisfaction ===
# Requirements detected by saneprompt must be satisfied before editing
REQUIREMENT_SATISFACTION = {
  'saneloop' => {
    satisfied_by: [/saneloop/i, /start.*loop/i],
    requires_tool: 'Task'  # Must use Task agent
  },
  'commit' => {
    satisfied_by: [/git commit/i],
    requires_tool: 'Bash'
  },
  'plan' => {
    satisfied_by: [/plan/i, /approach/i, /strategy/i],
    output_pattern: true  # Satisfied when Claude outputs plan
  },
  'research' => {
    satisfied_by: [:all_research_complete]  # Special marker
  }
}.freeze

# === BLOCKED PATHS ===

# Block sensitive directories (with OR without trailing content)
BLOCKED_PATH_PATTERN = Regexp.union(
  %r{^/var(/|$)},           # /var or /var/...
  %r{^/etc(/|$)},           # /etc or /etc/...
  %r{^/usr(/|$)},           # /usr or /usr/...
  %r{^/System(/|$)},        # /System or /System/...
  %r{\.ssh(/|$)},           # ~/.ssh or ~/.ssh/...
  %r{\.aws(/|$)},           # ~/.aws or ~/.aws/...
  %r{\.claude_hook_secret},
  %r{/\.git/objects/},
  %r{\.netrc},
  %r{credentials\.json},
  %r{\.env$}
).freeze

# === BYPASS DETECTION ===

BASH_FILE_WRITE_PATTERN = Regexp.union(
  />\s*[^&]/,           # redirect (but not 2>&1)
  />>/,                 # append
  /\bsed\s+-i/,         # sed in-place
  /\btee\b/,            # tee command
  /\bdd\b.*\bof=/,      # dd output file
  /<<[A-Z_]+/,          # heredoc
  /\bcat\b.*>/          # cat redirect
).freeze

EDIT_KEYWORDS = %w[edit write create modify change update add remove delete fix patch].freeze

# === RESEARCH CATEGORIES ===

RESEARCH_CATEGORIES = {
  memory: {
    tools: %w[mcp__memory__read_graph mcp__memory__search_nodes],
    task_patterns: [/memory/i, /past bugs/i, /previous/i, /history/i]
  },
  docs: {
    tools: %w[mcp__apple-docs__* mcp__context7__*],
    task_patterns: [/docs/i, /documentation/i, /apple-docs/i, /context7/i, /api/i]
  },
  web: {
    tools: %w[WebSearch WebFetch],
    task_patterns: [/web/i, /search online/i, /google/i, /internet/i]
  },
  github: {
    tools: %w[mcp__github__*],
    task_patterns: [/github/i, /external.*example/i, /other.*repo/i]
  },
  local: {
    tools: %w[Read Grep Glob],
    task_patterns: [/codebase/i, /local/i, /existing/i, /current.*code/i, /file/i]
  }
}.freeze

# === CHECK FUNCTIONS ===

def check_blocked_path(tool_input)
  path = tool_input['file_path'] || tool_input['path'] || tool_input[:file_path] || tool_input[:path]
  return nil unless path

  # URL-decode the path to catch encoded bypass attempts (%2e%2e = ..)
  require 'uri'
  decoded_path = URI.decode_www_form_component(path) rescue path

  # Expand both original and decoded paths
  expanded_path = File.expand_path(path) rescue path
  expanded_decoded = File.expand_path(decoded_path) rescue decoded_path

  # Check both versions against blocked patterns
  [path, decoded_path, expanded_path, expanded_decoded].each do |p|
    if p.match?(BLOCKED_PATH_PATTERN)
      return "BLOCKED PATH: #{path}\nRule #1: Stay in your lane"
    end
  end

  nil
end

# === INTELLIGENCE: Bootstrap Check ===

def is_bootstrap_tool?(tool_name)
  tool_name.match?(BOOTSTRAP_TOOL_PATTERN)
end

# === INTELLIGENCE: Requirement Enforcement ===

def check_requirements(tool_name, tool_input)
  # Bootstrap tools always allowed
  return nil if is_bootstrap_tool?(tool_name)

  # Only enforce on edit tools
  return nil unless EDIT_TOOLS.include?(tool_name)

  reqs = StateManager.get(:requirements)
  requested = reqs[:requested] || []
  satisfied = reqs[:satisfied] || []

  return nil if requested.empty?

  unsatisfied = requested - satisfied

  return nil if unsatisfied.empty?

  # Check if 'research' is unsatisfied and research is complete
  if unsatisfied.include?('research')
    research = StateManager.get(:research)
    if research_complete?(research)
      mark_requirement_satisfied('research')
      unsatisfied.delete('research')
    end
  end

  return nil if unsatisfied.empty?

  "REQUIREMENTS NOT MET\n" \
  "User requested: #{requested.join(', ')}\n" \
  "Unsatisfied: #{unsatisfied.join(', ')}\n" \
  "Complete these before editing."
end

def mark_requirement_satisfied(requirement)
  StateManager.update(:requirements) do |reqs|
    reqs[:satisfied] ||= []
    reqs[:satisfied] << requirement unless reqs[:satisfied].include?(requirement)
    reqs
  end
end

def track_requirement_satisfaction(tool_name, tool_input)
  reqs = StateManager.get(:requirements)
  requested = reqs[:requested] || []

  return if requested.empty?

  requested.each do |req|
    config = REQUIREMENT_SATISFACTION[req]
    next unless config

    # Check if tool matches
    next if config[:requires_tool] && tool_name != config[:requires_tool]

    # Check if patterns match in input
    input_text = [
      tool_input['command'],
      tool_input['prompt'],
      tool_input[:command],
      tool_input[:prompt]
    ].compact.join(' ')

    if config[:satisfied_by].is_a?(Array) && config[:satisfied_by].first != :all_research_complete
      if config[:satisfied_by].any? { |p| input_text.match?(p) }
        mark_requirement_satisfied(req)
      end
    end
  end
end

def check_circuit_breaker
  cb = StateManager.get(:circuit_breaker)
  return nil unless cb[:tripped]

  "CIRCUIT BREAKER TRIPPED\n" \
  "#{cb[:failures]} consecutive failures detected.\n" \
  "Last error: #{cb[:last_error]}\n" \
  "User must say 'reset breaker' to continue."
end

def check_enforcement_halted
  enf = StateManager.get(:enforcement)
  return nil unless enf[:halted]

  # Allow through but warn - enforcement was halted due to loop detection
  warn "Enforcement halted: #{enf[:halted_reason]}"
  nil
end

# Allowed targets for bash redirects (safe destinations)
# NOTE: Comments break alternation in extended mode, so keep them outside
SAFE_REDIRECT_TARGETS = Regexp.union(
  '/dev/null',        # discard output
  %r{^/tmp/},         # temp files
  %r{^/var/tmp/},     # temp files
  %r{DerivedData/},   # Xcode build output
  %r{\.build/},       # Swift build output
  %r{^build/}         # generic build output
).freeze

def check_bash_bypass(tool_name, tool_input)
  return nil unless tool_name == 'Bash'

  command = tool_input['command'] || tool_input[:command] || ''

  # Check for file write patterns
  if command.match?(BASH_FILE_WRITE_PATTERN)
    # Extract the redirect target if present
    target_match = command.match(/(?:>|>>|tee\s+)\s*([^\s|&;]+)/)
    target = target_match ? target_match[1] : nil

    # Allow safe redirect targets
    if target && target.match?(SAFE_REDIRECT_TARGETS)
      return nil
    end

    # Allow pure stderr redirects (2>&1, 2>/dev/null)
    if command.match?(/^\s*\S+.*2>&1\s*$/) || command.match?(/2>\/dev\/null/)
      # Only if no other dangerous redirects
      unless command.match?(/[^2]>\s*[^&]/) || command.match?(/>>/)
        return nil
      end
    end

    # ALWAYS block file writes to source files - this is a BYPASS attempt
    # Claude should use Edit/Write tools which have proper tracking
    return "BASH FILE WRITE BLOCKED\n" \
           "Command appears to write files: #{command[0..80]}...\n" \
           "Use Edit or Write tool instead - bash writes bypass tracking.\n" \
           "Allowed: /tmp/, /dev/null, build dirs, stderr redirects (2>&1)"
  end

  nil
end

def check_subagent_bypass(tool_name, tool_input)
  return nil unless tool_name == 'Task'

  prompt = tool_input['prompt'] || tool_input[:prompt] || ''
  prompt_lower = prompt.downcase

  # Check if this Task is for editing
  is_edit_task = EDIT_KEYWORDS.any? { |kw| prompt_lower.include?(kw) }
  return nil unless is_edit_task

  # Check if research is complete
  research = StateManager.get(:research)
  complete = research_complete?(research)

  unless complete
    return "SUBAGENT BYPASS BLOCKED\n" \
           "Task appears to be for editing: #{prompt[0..50]}...\n" \
           "Complete research first (5 categories)."
  end

  nil
end

def check_research_before_edit(tool_name, tool_input)
  return nil unless EDIT_TOOLS.include?(tool_name)

  research = StateManager.get(:research)
  complete = research_complete?(research)

  return nil if complete

  missing = research_missing(research)
  "RESEARCH INCOMPLETE\n" \
  "Cannot edit until research is complete.\n" \
  "Missing: #{missing.join(', ')}\n" \
  "Use Task agents for each category."
end

# === MUTATION CHECKS (global & external) ===

def check_global_mutations(tool_name, _tool_input)
  return nil unless tool_name.match?(GLOBAL_MUTATION_PATTERN)

  research = StateManager.get(:research)
  complete = research_complete?(research)

  return nil if complete

  missing = research_missing(research)
  "GLOBAL MUTATION BLOCKED\n" \
  "Tool '#{tool_name}' affects ALL projects (MCP memory is shared).\n" \
  "Complete research first. Missing: #{missing.join(', ')}\n" \
  "Use mcp__memory__read_graph to understand current state before mutating."
end

def check_external_mutations(tool_name, _tool_input)
  return nil unless tool_name.match?(EXTERNAL_MUTATION_PATTERN)

  research = StateManager.get(:research)
  complete = research_complete?(research)

  return nil if complete

  missing = research_missing(research)
  "EXTERNAL MUTATION BLOCKED\n" \
  "Tool '#{tool_name}' affects external systems (GitHub).\n" \
  "Complete research first. Missing: #{missing.join(', ')}\n" \
  "Use mcp__github__get_* or mcp__github__list_* to understand state first."
end

def research_complete?(research)
  RESEARCH_CATEGORIES.keys.all? { |cat| research[cat] }
end

def research_missing(research)
  RESEARCH_CATEGORIES.keys.reject { |cat| research[cat] }
end

# === RESEARCH TRACKING ===

def track_research(tool_name, tool_input)
  # Check direct tool matches
  RESEARCH_CATEGORIES.each do |category, config|
    if config[:tools].any? { |t| tool_name.start_with?(t.sub('*', '')) }
      mark_research_done(category, tool_name, false)
    end
  end

  # Check Task agent prompts
  if tool_name == 'Task'
    prompt = tool_input['prompt'] || tool_input[:prompt] || ''

    RESEARCH_CATEGORIES.each do |category, config|
      if config[:task_patterns].any? { |p| prompt.match?(p) }
        mark_research_done(category, 'Task', true)
      end
    end
  end
end

def mark_research_done(category, tool, via_task)
  current = StateManager.get(:research, category)

  # Task agents can upgrade non-Task entries, but not downgrade them
  return if current && current[:via_task] && !via_task

  StateManager.update(:research) do |r|
    r[category] = {
      completed_at: Time.now.iso8601,
      tool: tool,
      via_task: via_task
    }
    r
  end
end

# === LOGGING ===

def log_action(tool_name, blocked, reason = nil)
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
  entry = {
    timestamp: Time.now.iso8601,
    tool: tool_name,
    blocked: blocked,
    reason: reason&.lines&.first&.strip,
    pid: Process.pid
  }
  File.open(LOG_FILE, 'a') { |f| f.puts(entry.to_json) }
rescue StandardError
  # Don't fail on logging errors
end

# === MAIN ENFORCEMENT ===

def process_tool(tool_name, tool_input)
    # === BYPASS MODE: Still track, but do not block ===
    if BYPASS_ACTIVE
      track_research(tool_name, tool_input)
      track_requirement_satisfaction(tool_name, tool_input)
      log_action(tool_name, false)
      return 0
    end
  # === INTELLIGENCE: Bootstrap tools always allowed (except blocked paths) ===
  is_bootstrap = is_bootstrap_tool?(tool_name)

  # Always check blocked paths first (even for bootstrap)
  if (reason = check_blocked_path(tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Bootstrap tools skip most checks (prevents circular blocking)
  if is_bootstrap
    track_research(tool_name, tool_input)
    track_requirement_satisfaction(tool_name, tool_input)
    log_action(tool_name, false)
    return 0
  end

  # Check circuit breaker
  if (reason = check_circuit_breaker)
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Check if enforcement is halted (warn but allow)
  check_enforcement_halted

  # Track research progress BEFORE checking requirements
  track_research(tool_name, tool_input)

  # === INTELLIGENCE: Track requirement satisfaction ===
  track_requirement_satisfaction(tool_name, tool_input)

  # Check bash bypass
  if (reason = check_bash_bypass(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Check subagent bypass
  if (reason = check_subagent_bypass(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Check research before edit
  if (reason = check_research_before_edit(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Check global mutations (MCP memory affects ALL projects)
  if (reason = check_global_mutations(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # Check external mutations (GitHub affects outside systems)
  if (reason = check_external_mutations(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # === INTELLIGENCE: Check requirements from saneprompt ===
  if (reason = check_requirements(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason)
    return 2
  end

  # All checks passed
  log_action(tool_name, false)
  0
end

def output_block(reason)
  warn '---'
  warn 'SANETOOLS BLOCKED'
  warn ''
  warn reason
  warn '---'
end

# === SELF-TEST ===

def self_test
  warn 'SaneTools Self-Test'
  warn '=' * 40

  # Reset state for clean test
  StateManager.reset(:research)
  StateManager.reset(:circuit_breaker)
  StateManager.update(:enforcement) do |e|
    e[:halted] = false
    e[:blocks] = []
    e
  end

  passed = 0
  failed = 0

  # === CIRCUIT BREAKER TEST ===
  warn ''
  warn 'Testing circuit breaker:'

  # Trip the circuit breaker
  StateManager.update(:circuit_breaker) do |cb|
    cb[:tripped] = true
    cb[:failures] = 5
    cb[:last_error] = 'Test error'
    cb
  end

  original_stderr = $stderr.clone
  $stderr.reopen('/dev/null', 'w')
  exit_code = process_tool('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
  $stderr.reopen(original_stderr)

  if exit_code == 2
    passed += 1
    warn '  PASS: Circuit breaker blocks edits when tripped'
  else
    failed += 1
    warn '  FAIL: Circuit breaker should block when tripped'
  end

  # Reset circuit breaker for remaining tests
  StateManager.reset(:circuit_breaker)

  # === BASH FILE WRITE BYPASS TEST ===
  warn ''
  warn 'Testing bash file write bypass:'

  # Ensure research is incomplete
  StateManager.reset(:research)

  original_stderr = $stderr.clone
  $stderr.reopen('/dev/null', 'w')
  exit_code = process_tool('Bash', { 'command' => 'echo "test" > /tmp/test.txt' })
  $stderr.reopen(original_stderr)

  if exit_code == 2
    passed += 1
    warn '  PASS: Bash file writes blocked without research'
  else
    failed += 1
    warn '  FAIL: Bash file writes should be blocked without research'
  end

  # === STANDARD TESTS ===
  warn ''
  warn 'Testing tool blocking:'

  tests = [
    # Blocked paths
    { tool: 'Read', input: { 'file_path' => '~/.ssh/id_rsa' }, expect_block: true, name: 'Block ~/.ssh/' },
    { tool: 'Edit', input: { 'file_path' => '/etc/passwd' }, expect_block: true, name: 'Block /etc/' },
    { tool: 'Write', input: { 'file_path' => '/var/log/test' }, expect_block: true, name: 'Block /var/' },

    # Edit without research (should block)
    { tool: 'Edit', input: { 'file_path' => '/Users/sj/SaneProcess/test.swift' }, expect_block: true, name: 'Block edit without research' },

    # Research tools (should allow and track)
    { tool: 'Read', input: { 'file_path' => '/Users/sj/SaneProcess/test.swift' }, expect_block: false, name: 'Allow Read (tracks local)' },
    { tool: 'Grep', input: { 'pattern' => 'test' }, expect_block: false, name: 'Allow Grep' },
    { tool: 'WebSearch', input: { 'query' => 'swift patterns' }, expect_block: false, name: 'Allow WebSearch (tracks web)' },
    { tool: 'mcp__memory__read_graph', input: {}, expect_block: false, name: 'Allow memory read (tracks memory)' },

    # Task agents (should allow and track)
    { tool: 'Task', input: { 'prompt' => 'Search documentation for this API' }, expect_block: false, name: 'Allow Task (tracks docs)' },
    { tool: 'Task', input: { 'prompt' => 'Search GitHub for external examples' }, expect_block: false, name: 'Allow Task (tracks github)' },
  ]

  tests.each do |test|
    # Suppress output
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')

    exit_code = process_tool(test[:tool], test[:input])

    $stderr.reopen(original_stderr)

    blocked = exit_code == 2
    expected = test[:expect_block]

    if blocked == expected
      passed += 1
      warn "  PASS: #{test[:name]}"
    else
      failed += 1
      warn "  FAIL: #{test[:name]} - expected #{expected ? 'BLOCK' : 'ALLOW'}, got #{blocked ? 'BLOCK' : 'ALLOW'}"
    end
  end

  # Check research tracking
  research = StateManager.get(:research)
  tracked_count = RESEARCH_CATEGORIES.keys.count { |cat| research[cat] }

  warn ''
  warn "Research tracked: #{tracked_count}/5 categories"
  research.each do |cat, info|
    status = info ? "done (#{info[:tool]})" : 'pending'
    warn "  #{cat}: #{status}"
  end

  # Now edit should work (all research done)
  if tracked_count == 5
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Edit allowed after research'
    else
      failed += 1
      warn '  FAIL: Edit still blocked after research'
    end
  else
    warn '  SKIP: Not all research categories tracked'
  end

  # === JSON INTEGRATION TESTS ===
  warn ''
  warn 'Testing JSON parsing (integration):'

  require 'open3'

  # Test valid JSON with tool_name and tool_input
  json_input = '{"tool_name":"Read","tool_input":{"file_path":"/Users/sj/SaneProcess/test.swift"}}'
  stdout, stderr, status = Open3.capture3("ruby #{__FILE__}", stdin_data: json_input)
  if status.exitstatus == 0
    passed += 1
    warn '  PASS: Valid JSON parsed correctly (Read tool allowed)'
  else
    failed += 1
    warn "  FAIL: Valid JSON parsing - exit #{status.exitstatus}"
  end

  # Test blocked path via JSON
  json_input = '{"tool_name":"Read","tool_input":{"file_path":"~/.ssh/id_rsa"}}'
  stdout, stderr, status = Open3.capture3("ruby #{__FILE__}", stdin_data: json_input)
  if status.exitstatus == 2
    passed += 1
    warn '  PASS: Blocked path correctly blocked via JSON'
  else
    failed += 1
    warn "  FAIL: Blocked path should return exit 2, got #{status.exitstatus}"
  end

  # Test invalid JSON doesn't crash
  json_input = 'not valid json at all'
  stdout, stderr, status = Open3.capture3("ruby #{__FILE__}", stdin_data: json_input)
  if status.exitstatus == 0
    passed += 1
    warn '  PASS: Invalid JSON returns exit 0 (fail safe)'
  else
    failed += 1
    warn "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}"
  end

  # Test empty input doesn't crash
  stdout, stderr, status = Open3.capture3("ruby #{__FILE__}", stdin_data: '')
  if status.exitstatus == 0
    passed += 1
    warn '  PASS: Empty input returns exit 0 (fail safe)'
  else
    failed += 1
    warn "  FAIL: Empty input should return exit 0, got #{status.exitstatus}"
  end

  # === CLEANUP: Reset circuit breaker only (don't reset research - breaks normal ops) ===
  StateManager.reset(:circuit_breaker)
  StateManager.update(:enforcement) do |e|
    e[:halted] = false
    e[:blocks] = []
    e
  end

  warn ''
  warn "#{passed}/#{passed + failed} tests passed"

  if failed == 0
    warn ''
    warn 'ALL TESTS PASSED'
    exit 0
  else
    warn ''
    warn "#{failed} TESTS FAILED"
    exit 1
  end
end

def show_status
  research = StateManager.get(:research)
  cb = StateManager.get(:circuit_breaker)
  enf = StateManager.get(:enforcement)

  warn 'SaneTools Status'
  warn '=' * 40

  warn ''
  warn 'Research:'
  RESEARCH_CATEGORIES.keys.each do |cat|
    info = research[cat]
    status = info ? "done (#{info[:tool]}, via_task=#{info[:via_task]})" : 'pending'
    warn "  #{cat}: #{status}"
  end

  warn ''
  warn 'Circuit Breaker:'
  warn "  failures: #{cb[:failures]}"
  warn "  tripped: #{cb[:tripped]}"

  warn ''
  warn 'Enforcement:'
  warn "  halted: #{enf[:halted]}"
  warn "  blocks: #{enf[:blocks]&.length || 0}"

  exit 0
end

def reset_state
  StateManager.reset(:research)
  StateManager.reset(:circuit_breaker)
  StateManager.update(:enforcement) do |e|
    e[:halted] = false
    e[:blocks] = []
    e
  end
  warn 'State reset'
  exit 0
end

# === MAIN ===

if ARGV.include?('--self-test')
  self_test
elsif ARGV.include?('--status')
  show_status
elsif ARGV.include?('--reset')
  reset_state
else
  begin
    input = JSON.parse($stdin.read)
    tool_name = input['tool_name'] || 'unknown'
    tool_input = input['tool_input'] || {}
    exit process_tool(tool_name, tool_input)
  rescue JSON::ParserError, Errno::ENOENT
    exit 0  # Don't block on parse errors
  end
end
