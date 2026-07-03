#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

# ==============================================================================
# SaneTools - PreToolUse Hook
# ==============================================================================
# Enforces all requirements before tool execution.
#
# Exit codes:
#   0 = allow
#   2 = BLOCK (tool does NOT execute)
#
# Structure (per Rule #10 - file size limit):
#   sanetools.rb        - Main entry, constants, processing (~350 lines)
#   sanetools_checks.rb - All check_* functions (~280 lines)
#   sanetools_test.rb   - Self-test suite (~230 lines)
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'core/state_manager'
require_relative 'core/process_metrics'
require_relative 'sanetools_checks'
require_relative 'sanetools_startup'
require_relative 'core/project_root'

# === SAFEMODE BYPASS ===
BYPASS_FILE = File.join(SaneProjectRoot.resolve, '.claude', 'bypass_active.json')
BYPASS_ACTIVE = File.exist?(BYPASS_FILE)

LOG_FILE = File.expand_path('../../.claude/sanetools.log', __dir__)

# === TOOL CLASSIFICATION ===

EDIT_TOOLS = %w[Edit Write NotebookEdit].freeze
RESEARCH_TOOLS = %w[Read Grep Glob WebSearch WebFetch Task].freeze

# === INTELLIGENCE: Bootstrap Whitelist ===
# These tools ALWAYS allowed to prevent circular blocking
# CRITICAL: Categorize by DAMAGE POTENTIAL, not by name!
BOOTSTRAP_TOOL_PATTERN = Regexp.union(
  /^Read$/,
  /^Grep$/,
  /^Glob$/,
  /^WebSearch$/,
  /^WebFetch$/,
  SaneToolsChecks.mcp_tool_pattern('apple-docs'),
  SaneToolsChecks.mcp_tool_pattern('context7'),
  SaneToolsChecks.mcp_tool_pattern('github', /(?:search_|get_|list_)/),
  /^Task$/
).freeze

# === MUTATION PATTERNS (require research) ===
# GLOBAL_MUTATION_PATTERN is empty — no global mutation tools to gate
GLOBAL_MUTATION_PATTERN = /(?!)/.freeze  # Matches nothing

EXTERNAL_MUTATION_PATTERN = Regexp.union(
  SaneToolsChecks.mcp_tool_pattern('github', /(?:create_|push_|update_|merge_|fork_|add_)/)
).freeze

# === INTELLIGENCE: Requirement Satisfaction ===
REQUIREMENT_SATISFACTION = {
  'saneloop' => {
    satisfied_by: [/saneloop/i, /start.*loop/i],
    requires_tool: 'Task'
  },
  'commit' => {
    satisfied_by: [/git commit/i],
    requires_tool: 'Bash'
  },
  'plan' => {
    satisfied_by: [/plan/i, /approach/i, /strategy/i],
    output_pattern: true
  },
  'research' => {
    satisfied_by: [:all_research_complete]
  }
}.freeze

# === BYPASS DETECTION ===

BASH_FILE_WRITE_PATTERN = Regexp.union(
  # Output redirection
  />\s*[^&]/,
  />>/,
  # In-place editing
  /\bsed\s+-i/,
  # Pipe to file
  /\btee\b/,
  # Direct disk write
  /\bdd\b.*\bof=/,
  # Heredoc
  /<<[A-Z_]+/,
  # Cat redirect (ignore fd duplication like 2>&1)
  /\bcat\b.*(?<![0-9])>(?!&)/,
  # File copy (M8 addition)
  /\bcp\s+/,
  # Download to file (M8 addition); scoped to curl's own segment so a
  # downstream `| grep -o` does not read as a curl output flag
  /\bcurl\b[^|;&]*\s-[oO]\b/,
  /\bwget\b[^|;&]*\s-O\b/,
  # Patch application (M8 addition)
  /\bgit\s+apply\b/,
  # Bulk file operations (M8 addition)
  /\bxargs\b.*\b(touch|rm|mv|cp)\b/,
  # Move/overwrite (M8 addition)
  /\bmv\s+/
  # NOTE: inline-script execution (`ruby -e`, `python -c`, `node -e`, `perl -e`,
  # `swift -e`, `ruby /tmp/foo.rb`) is deliberately NOT matched here. Those
  # invocations are overwhelmingly read-only diagnostics, and firing on every one
  # of them blocked legitimate reads (e.g. `ruby -e 'puts File.read(...)'`) and
  # /tmp-only scratch writes. A genuine bash file write still gets caught by the
  # redirect/tee/cp/mv patterns above, which already honor SAFE_REDIRECT_TARGETS
  # (so redirecting an inline script to a non-/tmp path is still blocked).
).freeze

EDIT_KEYWORDS = %w[edit write create modify change update add remove delete fix patch].freeze

# === RESEARCH CATEGORIES ===
# High-value categories for SaneApps' actual work (native macOS Swift: Apple
# frameworks dominate). docs = Apple Docs. Context7 is intentionally NOT listed:
# the plugin is toggled off (context7@claude-plugins-official: false) so it is
# not callable, and it is low value for native macOS anyway — re-add a
# mcp__context7__* tool here only if the plugin is re-enabled. web covers current
# best practices AND real-world code examples — WebSearch surfaces GitHub, and
# the `gh` skill replaced the retired GitHub MCP, so there is no separate
# mandatory `github` category (it was unsatisfiable friction).
RESEARCH_CATEGORIES = {
  docs: {
    tools: %w[mcp__apple-docs__*],
    task_patterns: [/docs/i, /documentation/i, /apple-docs/i, /api/i]
  },
  web: {
    tools: %w[WebSearch WebFetch mcp__github__*],
    task_patterns: [/web/i, /search online/i, /google/i, /internet/i, /github/i, /external.*example/i, /other.*repo/i]
  },
  local: {
    tools: %w[Read Grep Glob],
    task_patterns: [/codebase/i, /local/i, /existing/i, /current.*code/i, /file/i]
  }
}.freeze

# === HELPER FUNCTIONS ===

# Commands that research, prove, or clear a tripped breaker. Blocking these
# while tripped creates an unrecoverable deadlock with the verification gates.
BREAKER_RECOVERY_PATTERN = Regexp.union(
  /SaneMaster(?:_standalone)?\.rb\s+(?:verify|status|validation_report)\b/,
  /validation_report\.rb/,
  %r{scripts/hooks/\S+\.rb\s+--(?:self-test|reset|status)\b},
  /test_hooks\.rb|_test\.rb\b/,
  /\A\s*(?:ls|cat|head|tail|wc|file|stat|which|pwd|date|grep|rg)\b[^|;&]*\z/,
  /\A\s*git\s+(?:status|log|diff|branch|remote|show)\b[^|;&]*\z/
).freeze

def breaker_recovery_call?(tool_name, tool_input)
  return false unless tool_name == 'Bash'

  command = SaneLocalUIGuard.strip_quoted((tool_input['command'] || tool_input[:command]).to_s)
  command.match?(BREAKER_RECOVERY_PATTERN)
end

def is_bootstrap_tool?(tool_name)
  tool_name.match?(BOOTSTRAP_TOOL_PATTERN)
end

def research_complete?(research)
  SaneToolsChecks.effective_research_categories(RESEARCH_CATEGORIES).all? { |cat| research[cat] }
end

def research_missing(research)
  SaneToolsChecks.effective_research_categories(RESEARCH_CATEGORIES).reject { |cat| research[cat] }
end

# === RESEARCH TRACKING ===

def track_research(tool_name, tool_input)
  research_done = false

  RESEARCH_CATEGORIES.each do |category, config|
    if config[:tools].any? { |t| SaneToolsChecks.research_tool_match?(tool_name, t) }
      mark_research_done(category, tool_name, false)
      research_done = true
    end
  end

  if tool_name == 'Task'
    prompt = tool_input['prompt'] || tool_input[:prompt] || ''
    RESEARCH_CATEGORIES.each do |category, config|
      if config[:task_patterns].any? { |p| prompt.match?(p) }
        mark_research_done(category, 'Task', true)
        research_done = true
      end
    end
  end

  # WebSearch/WebFetch satisfy any category whose task_patterns match the query,
  # not just :web. This honors the gate's own help text ("WebSearch for examples"
  # satisfies github) and keeps the github category satisfiable even when the
  # github MCP is unreachable — otherwise a down github MCP blocks all edits.
  if %w[WebSearch WebFetch].include?(tool_name)
    query = tool_input['query'] || tool_input[:query] ||
            tool_input['url'] || tool_input[:url] ||
            tool_input['prompt'] || tool_input[:prompt] || ''
    RESEARCH_CATEGORIES.each do |category, config|
      next if category == :web # already marked via the tools list above

      if config[:task_patterns].any? { |p| query.match?(p) }
        mark_research_done(category, tool_name, false)
        research_done = true
      end
    end
  end

  if research_done
    research = StateManager.get(:research)
    all_complete = SaneToolsChecks.effective_research_categories(RESEARCH_CATEGORIES).all? { |cat| research[cat] }
    if all_complete
      SaneToolsChecks.reward_correct_behavior(:research_done)
    end
  end
end

def mark_research_done(category, tool, via_task)
  current = StateManager.get(:research, category)
  return if current.is_a?(Hash) && current[:via_task] && !via_task

  StateManager.update(:research) do |r|
    r[category] = {
      completed_at: Time.now.iso8601,
      tool: tool,
      via_task: via_task
    }
    r
  end
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
    next if config[:requires_tool] && tool_name != config[:requires_tool]

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
  SaneProcessMetrics.record(
    'trajectory_event',
    source: 'PreToolUse',
    tool: tool_name,
    blocked: blocked,
    rule: reason ? detect_rule_from_reason(reason) : nil,
    reason: reason&.lines&.first&.strip,
    pid: Process.pid
  )

  # Track violations in StateManager for SOP scoring
  track_violation(tool_name, reason) if blocked && reason
rescue StandardError
  # Don't fail on logging errors
end

def track_violation(tool_name, reason)
  rule = detect_rule_from_reason(reason)
  StateManager.update(:enforcement) do |e|
    e[:blocks] ||= []
    e[:blocks] << {
      tool: tool_name,
      rule: rule,
      reason: reason.lines.first&.strip,
      timestamp: Time.now.iso8601
    }
    e[:blocks] = e[:blocks].last(50)
    e
  end
rescue StandardError
  # Don't fail on tracking errors
end

def detect_rule_from_reason(reason)
  case reason
  when /Rule #1|BLOCKED PATH|STAY IN YOUR LANE|STAY IN LANE/i then 'Rule #1'
  when /Rule #2|RESEARCH.*INCOMPLETE|VERIFY/i then 'Rule #2'
  when /Rule #3|CIRCUIT BREAKER/i then 'Rule #3'
  when /Rule #10|FILE SIZE|lines.*limit/i then 'Rule #10'
  when /SENSITIVE FILE/i then 'sensitive_file'
  when /TABLE BLOCKED/i then 'no_tables'
  when /BASH.*WRITE|STATE.*BYPASS/i then 'bypass_attempt'
  when /SUBAGENT.*BLOCKED/i then 'subagent_bypass'
  when /MUTATION.*BLOCKED/i then 'mutation_blocked'
  when /REQUIREMENTS NOT MET/i then 'requirements'
  when /SANELOOP REQUIRED/i then 'saneloop_required'
  when /READ REQUIRED DOCS/i then 'session_docs'
  when /STARTUP GATE/i then 'startup_gate'
  when /MCP ACTIONS PENDING/i then 'mcp_actions_pending'
  when /DEPLOYMENT SAFETY/i then 'deployment_safety'
  when /MINI-FIRST|LOCAL UI/i then 'mini_first'
  else 'unknown'
  end
end

def output_block(reason, tool_name = nil)
  # Refusal tracking adds a compact remedy note for a repeated same-type block.
  # It is APPENDED below the real reason — never substituted for it. Masking the
  # true cause (showing "REFUSAL TO READ: other" instead of "STARTUP GATE") is
  # exactly what trapped past sessions fighting the wrong gate.
  remedy_note = tool_name ? SaneToolsChecks.check_refusal_to_read(tool_name, reason) : nil

  warn '---'
  warn 'SANETOOLS BLOCKED'
  warn ''
  warn reason
  if remedy_note
    warn ''
    warn remedy_note
  end

  SaneProcessMetrics.record(
    'hook_block',
    tool: tool_name,
    rule: detect_rule_from_reason(reason),
    reason: reason.lines.first&.strip,
    escalated: !remedy_note.nil?
  )

  warn '---'
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

  is_bootstrap = is_bootstrap_tool?(tool_name)

  # Always check blocked paths first (pass tool_name to allow reads of state files)
  if (reason = SaneToolsChecks.check_blocked_path(tool_input, tool_name, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Mini-first guard must run before bootstrap allowances. Local UI tools bypass
  # shell launch checks, so block them at the generic PreToolUse boundary.
  if (reason = SaneToolsChecks.check_local_ui_tool_guard(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  if (reason = SaneToolsChecks.check_canonical_action_path(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Startup gate: block substantive work until startup steps complete
  if (reason = SaneToolsStartup.check_startup_gate(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  if (reason = SaneToolsChecks.check_secret_startup_autoload(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Bootstrap tools skip most checks
  if is_bootstrap
    track_research(tool_name, tool_input)
    track_requirement_satisfaction(tool_name, tool_input)
    log_action(tool_name, false)
    return 0
  end

  # Check circuit breaker. Recovery paths stay open while tripped: Rule #3
  # demands research + a verified fix, so the canonical verify/test/reset
  # commands and read-only startup-class bash must never be blocked by the
  # breaker itself (2026-06-11 deadlock: the breaker blocked the exact verify
  # command the Stop gate required, with no agent-side way out).
  if (reason = SaneToolsChecks.check_circuit_breaker) && !breaker_recovery_call?(tool_name, tool_input)
    if EDIT_TOOLS.include?(tool_name)
      # Remediation edits stay possible while tripped — blocking them made a
      # trip unrecoverable without the user (2026-06-12 deadlock: the fix for
      # the breaker was itself blocked by the breaker). Verification gates
      # still prevent claiming done without a green verify.
      warn '⚠️  CIRCUIT BREAKER TRIPPED — edit allowed as remediation only. Fix the root cause, then run: ruby scripts/SaneMaster.rb verify, then rb-.'
    else
      log_action(tool_name, true, reason)
      output_block(reason, tool_name)
      return 2
    end
  end

  # PREFLIGHT: Check pending MCP actions (memory staging, etc.)
  if (reason = SaneToolsChecks.check_pending_mcp_actions(tool_name, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check session docs read before editing
  if (reason = SaneToolsChecks.check_session_docs_read(tool_name, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check planning required (must show plan before editing)
  if (reason = SaneToolsChecks.check_planning_required(tool_name, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check research-only mode
  if (reason = SaneToolsChecks.check_research_only_mode(tool_name, EDIT_TOOLS, GLOBAL_MUTATION_PATTERN, EXTERNAL_MUTATION_PATTERN))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  if (reason = SaneToolsChecks.check_tool_discovery_required(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Public GitHub posting guard: requires explicit user approval and "I/me/my" voice.
  if (reason = SaneToolsChecks.check_github_post_guard(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check if enforcement is halted
  SaneToolsChecks.check_enforcement_halted

  # Track research progress BEFORE checking requirements
  track_research(tool_name, tool_input)
  track_requirement_satisfaction(tool_name, tool_input)

  # Capture research.md mtime before Task agents that might write to it
  store_research_mtime_if_needed(tool_name, tool_input)

  # Check bash bypass
  if (reason = SaneToolsChecks.check_bash_bypass(tool_name, tool_input, BASH_FILE_WRITE_PATTERN))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # === DEPLOYMENT SAFETY (SaneApps-specific — only enforce for .saneprocess projects) ===
  if File.exist?(File.join(SaneProjectRoot.resolve, '.saneprocess'))
    if (reason = SaneToolsChecks.check_r2_upload(tool_name, tool_input))
      log_action(tool_name, true, reason)
      output_block(reason, tool_name)
      return 2
    end

    if (reason = SaneToolsChecks.check_appcast_edit(tool_name, tool_input, EDIT_TOOLS))
      log_action(tool_name, true, reason)
      output_block(reason, tool_name)
      return 2
    end

    if (reason = SaneToolsChecks.check_pages_deploy(tool_name, tool_input))
      log_action(tool_name, true, reason)
      output_block(reason, tool_name)
      return 2
    end
  end

  # Check subagent bypass
  if (reason = SaneToolsChecks.check_subagent_bypass(tool_name, tool_input, EDIT_KEYWORDS, RESEARCH_CATEGORIES))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check research before edit
  if (reason = SaneToolsChecks.check_research_before_edit(tool_name, EDIT_TOOLS, RESEARCH_CATEGORIES))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check sensitive file protection (CI/CD, entitlements, build config)
  if (reason = SaneToolsChecks.check_sensitive_file_edit(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check SaneLoop required for big tasks
  if (reason = SaneToolsChecks.check_saneloop_required(tool_name, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check file size (Rule #10)
  if (reason = SaneToolsChecks.check_file_size(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check new file / orphan doc policy (Rules #9 and #16)
  if (reason = SaneToolsChecks.check_new_file_policy(tool_name, tool_input))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check component owner aggregate size (Rule #10)
  if (reason = SaneToolsChecks.check_component_owner_size(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check table ban
  if (reason = SaneToolsChecks.check_table_ban(tool_name, tool_input, EDIT_TOOLS))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # NOTE: memory is a persistence target, not a pre-edit research category

  # Check external mutations
  if (reason = SaneToolsChecks.check_external_mutations(tool_name, EXTERNAL_MUTATION_PATTERN, RESEARCH_CATEGORIES))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check requirements
  if (reason = SaneToolsChecks.check_requirements(tool_name, BOOTSTRAP_TOOL_PATTERN, EDIT_TOOLS, RESEARCH_CATEGORIES))
    log_action(tool_name, true, reason)
    output_block(reason, tool_name)
    return 2
  end

  # Check for gaming patterns (non-blocking, logs for future detection)
  SaneToolsChecks.check_gaming_patterns(tool_name, EDIT_TOOLS, RESEARCH_CATEGORIES)

  # Check README on commit (non-blocking reminder)
  SaneToolsChecks.check_readme_on_commit(tool_name, tool_input)

  # All checks passed
  log_action(tool_name, false)
  0
end

# === RESEARCH WRITE TRACKING ===

def store_research_mtime_if_needed(tool_name, tool_input)
  return unless tool_name == 'Task'

  prompt = tool_input['prompt'] || tool_input[:prompt] || ''
  return unless prompt.match?(/research\.md/i)

  project_dir = SaneProjectRoot.resolve
  research_md = File.join(project_dir, '.claude', 'research.md')
  mtime = File.exist?(research_md) ? File.mtime(research_md).iso8601 : nil

  StateManager.update(:research) do |r|
    r[:pending_research_write] = {
      task_prompt_snippet: prompt[0..100],
      pre_mtime: mtime,
      started_at: Time.now.iso8601
    }
    r
  end
rescue StandardError
  nil # Don't block on tracking errors
end

# === CLI UTILITIES ===

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

# Mutating half of --reset, separated from the exit so it is unit-testable.
# Clears the things that actually wedge a session: a tripped breaker, halted
# enforcement, recorded blocks, and the refusal/repeat-block counter. The
# refusal tracker was previously NOT cleared here, so the documented remedy
# ("run --reset") left the very counter that masked the block in place.
#
# Does NOT reset :research. Wiping research evidence drops an already onboarded
# session back to "no research", which re-arms the research-before-edit gate so
# the next edit re-blocks and re-feeds the refusal counter — running the remedy
# used to make things worse. Research is reset deliberately via the rr- token.
def perform_reset
  StateManager.reset(:circuit_breaker)
  StateManager.update(:enforcement) do |e|
    e[:halted] = false
    e[:blocks] = []
    e
  end
  SaneToolsChecks.reset_refusal_tracking
end

def reset_state
  perform_reset
  warn 'State reset (breaker, enforcement, refusal tracker cleared; research evidence preserved — use rr- to reset research)'
  exit 0
end

# === MAIN ===

if ARGV.include?('--self-test')
  require_relative 'self_test_environment'
  exit SelfTestEnvironment.run_isolated(__FILE__)
elsif ARGV.include?('--self-test-internal')
  require_relative 'sanetools_test'
  exit SaneToolsTest.run(method(:process_tool), RESEARCH_CATEGORIES)
elsif ARGV.include?('--status')
  show_status
elsif ARGV.include?('--reset')
  reset_state
else
  begin
    input = JSON.parse($stdin.read.force_encoding(Encoding::UTF_8))
    tool_name = input['tool_name'] || 'unknown'
    tool_input = input['tool_input'] || {}
    exit process_tool(tool_name, tool_input)
  rescue JSON::ParserError, Errno::ENOENT
    exit 0  # Don't block on parse errors
  end
end
