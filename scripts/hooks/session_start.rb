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
  # Silently clear stale files - this is routine cleanup, not an error
  [SATISFACTION_FILE, RESEARCH_PROGRESS_FILE, REQUIREMENTS_FILE,
   EDIT_STATE_FILE, SUMMARY_VALIDATED_FILE].each do |file|
    File.delete(file) if File.exist?(file)
  end

  # Reset verification and planning tracking for fresh session
  require_relative 'core/state_manager'
  StateManager.reset(:verification)
  StateManager.reset(:planning)
  StateManager.reset(:deployment)

  # Record session start time (used by sanestop.rb for session boundary)
  StateManager.update(:enforcement) do |e|
    e[:session_started_at] = Time.now.iso8601
    # Cap blocks array to last 50 entries (prevent unbounded growth)
    e[:blocks] = (e[:blocks] || []).last(50)
    e
  end

  # Clear context compact warning so new session gets fresh warning
  context_warned = File.join(CLAUDE_DIR, 'context_warned_size.txt')
  File.delete(context_warned) if File.exist?(context_warned)
rescue StandardError
  # Don't fail on state errors
end

# Detect and handle SaneLoop from previous session
# User requirement: saneloops do NOT persist across sessions - always archive
def handle_stale_saneloop
  return unless File.exist?(SANELOOP_STATE_FILE)

  state = JSON.parse(File.read(SANELOOP_STATE_FILE), symbolize_names: true)
  return unless state[:active]

  started_at = Time.parse(state[:started_at]) rescue nil
  hours_old = started_at ? ((Time.now - started_at) / 3600.0).round(1) : 0

  # Archive ANY saneloop from previous session - no persistence allowed
  FileUtils.mkdir_p(SANELOOP_ARCHIVE_DIR)
  task_slug = (state[:task] || 'unknown').gsub(/[^a-zA-Z0-9]+/, '_')[0..30]
  archive_name = "#{Time.now.strftime('%Y%m%d_%H%M%S')}_SESSION_END_#{task_slug}.json"
  archive_path = File.join(SANELOOP_ARCHIVE_DIR, archive_name)

  state[:archived_at] = Time.now.iso8601
  state[:completed] = false
  state[:completion_note] = "SESSION ENDED: Archived on new session start (was #{hours_old}h old)"
  File.write(archive_path, JSON.pretty_generate(state))
  File.delete(SANELOOP_STATE_FILE)

  warn ''
  warn '⚠️  PREVIOUS SESSION SANELOOP ARCHIVED'
  warn "   Task: #{state[:task]}"
  warn "   Age: #{hours_old} hours"
  warn "   Status: Never completed (session ended)"
  warn ''
  warn '   SaneLoops do not persist across sessions.'
  warn '   Start fresh: ./Scripts/SaneMaster.rb saneloop start "Task" --promise "Done"'
  warn ''
rescue StandardError => e
  warn "⚠️  Error checking SaneLoop state: #{e.message}"
end

def output_session_context
  # Only warn if there's an actual problem (no SOP)
  sop_file = find_sop_file
  unless sop_file
    warn '⚠️  No SOP file found (DEVELOPMENT.md, CONTRIBUTING.md)'
  end
end

# Check for pending MCP actions that need resolution
MEMORY_STAGING_FILE = File.join(CLAUDE_DIR, 'memory_staging.json')

def check_pending_mcp_actions
  pending = []

  # Check memory staging (now uses Sane-Mem at localhost:37777)
  if File.exist?(MEMORY_STAGING_FILE)
    begin
      staging = JSON.parse(File.read(MEMORY_STAGING_FILE))
      if staging['needs_memory_update']
        pending << {
          type: 'memory_staging',
          message: "Memory staging needs saving: #{staging['suggested_entity']&.dig('name') || 'learnings'}",
          action: 'Save to Sane-Mem: curl -X POST localhost:37777/observations -d \'...\' then delete memory_staging.json'
        }
      end
    rescue StandardError
      # Ignore parse errors
    end
  end

  if pending.any?
    warn ''
    warn '🚨 PENDING MCP ACTIONS - MUST RESOLVE BEFORE WORK'
    warn ''
    pending.each do |p|
      warn "   ⚠️  #{p[:message]}"
      warn "      Action: #{p[:action]}"
    end
    warn ''
    warn '   EDITS WILL BE BLOCKED until these are resolved.'
    warn ''
  end

  pending
end

# === MCP VERIFICATION SYSTEM ===
# Reset verification for new session and prompt Claude to verify MCPs

MCP_VERIFICATION_TOOLS = {
  apple_docs: 'mcp__apple-docs__search_apple_docs',
  context7: 'mcp__context7__resolve-library-id',
  github: 'mcp__github__search_repositories'
}.freeze

def reset_mcp_verification
  require_relative 'core/state_manager'

  # Reset verification flag for new session (MCPs must re-verify)
  StateManager.update(:mcp_health) do |health|
    health[:verified_this_session] = false
    # Keep historical data but reset per-session verification
    health[:mcps].each do |_mcp, data|
      data[:verified] = false if data.is_a?(Hash)
    end
    health
  end
rescue StandardError => e
  warn "⚠️  Could not reset MCP verification: #{e.message}"
end

# === SESSION DOC ENFORCEMENT ===
# Scan for docs that must be read before edits are allowed
SESSION_DOC_CANDIDATES = %w[SESSION_HANDOFF.md DEVELOPMENT.md CONTRIBUTING.md].freeze

def populate_session_docs
  require_relative 'core/state_manager'

  found = SESSION_DOC_CANDIDATES.select { |f| File.exist?(File.join(PROJECT_DIR, f)) }

  StateManager.update(:session_docs) do |sd|
    sd[:required] = found
    sd[:read] = []
    sd[:enforced] = true
    sd
  end

  if found.any?
    warn ''
    warn "📖 SESSION DOCS: Read before editing:"
    found.each { |f| warn "   → #{f}" }
    warn ''
  end
rescue StandardError => e
  warn "⚠️  Could not populate session docs: #{e.message}"
end

def show_mcp_verification_status
  require_relative 'core/state_manager'

  health = StateManager.get(:mcp_health)
  mcps = health[:mcps] || {}

  # Check for any previous failures
  failures = mcps.select { |_, data| data.is_a?(Hash) && data[:failure_count].to_i > 0 }

  # Only warn if there were previous MCP failures - otherwise silent
  # The enforcement still happens via PreToolUse hook, we just don't spam stderr
  if failures.any?
    warn '⚠️  MCPs with previous failures (verify before editing):'
    failures.each do |mcp, data|
      warn "   #{mcp}: #{data[:failure_count]} failures"
    end
  end
end

# Debug logging for troubleshooting startup issues
DEBUG_LOG = File.join(CLAUDE_DIR, 'session_start_debug.log')

def log_debug(msg)
  File.open(DEBUG_LOG, 'a') { |f| f.puts "[#{Time.now.iso8601}] #{msg}" }
rescue StandardError
  # Ignore logging errors
end

# === LOG FILE ROTATION ===
# Rotate log files that exceed size limit to prevent unbounded growth

LOG_FILES_TO_ROTATE = %w[
  sanetools.log
  sanetrack.log
  saneprompt.log
  saneprompt_debug.log
  sanestop.log
  session_start_debug.log
].freeze

LOG_MAX_SIZE = 100 * 1024  # 100KB

def rotate_log_files
  rotated = []

  LOG_FILES_TO_ROTATE.each do |log_name|
    log_path = File.join(CLAUDE_DIR, log_name)
    next unless File.exist?(log_path)

    size = File.size(log_path)
    next if size < LOG_MAX_SIZE

    # Rotate: rename to .old (overwriting previous .old)
    old_path = "#{log_path}.old"
    File.rename(log_path, old_path)
    rotated << { name: log_name, size_kb: (size / 1024.0).round }
  end

  if rotated.any?
    warn ''
    warn "📜 Rotated #{rotated.length} log file#{rotated.length > 1 ? 's' : ''}:"
    rotated.each { |r| warn "   #{r[:name]} (#{r[:size_kb]}KB → .old)" }
    warn ''
  end

  rotated.length
rescue StandardError => e
  log_debug "Log rotation error: #{e.message}"
  0
end

# === ORPHANED PROCESS CLEANUP ===
# Clean up orphaned Claude processes from previous sessions

# Get all ancestor PIDs of a process
def get_ancestor_pids(pid)
  ancestors = []
  current = pid
  10.times do # Max depth to prevent infinite loop
    ppid = `ps -o ppid= -p #{current} 2>/dev/null`.strip.to_i rescue 0
    break if ppid <= 1
    ancestors << ppid
    current = ppid
  end
  ancestors
end

# Get all PIDs in a process's descendant tree
def get_process_tree(root_pid)
  tree = [root_pid]

  # Build parent->children map
  ps_output = `ps -eo pid,ppid 2>/dev/null`.lines rescue []
  children_map = Hash.new { |h, k| h[k] = [] }

  ps_output.each do |line|
    parts = line.split
    next if parts.length < 2
    pid = parts[0].to_i
    ppid = parts[1].to_i
    children_map[ppid] << pid if pid.positive? && ppid.positive?
  end

  # BFS to find all descendants
  queue = [root_pid]
  while queue.any?
    current = queue.shift
    children = children_map[current]
    children.each do |child|
      tree << child
      queue << child
    end
  end

  tree
end

# Cleanup orphaned Claude parent sessions
def cleanup_orphaned_claude_processes
  my_session_pid = Process.ppid
  ancestors = get_ancestor_pids(Process.pid)

  log_debug("cleanup: my_session_pid=#{my_session_pid}, ancestors=#{ancestors.inspect}")

  ps_output = `ps aux 2>/dev/null`.lines rescue []

  orphans_killed = 0
  ps_output.each do |line|
    next unless line.include?('--dangerously-skip-permissions')
    next if line.include?('grep')

    parts = line.split
    pid = parts[1].to_i
    next unless pid.positive?

    log_debug("cleanup: evaluating PID #{pid}")

    if pid == my_session_pid || ancestors.include?(pid)
      log_debug("cleanup: SKIP #{pid} (current session or ancestor)")
      next
    end

    log_debug("cleanup: KILL #{pid}")
    begin
      Process.kill('KILL', pid)
      orphans_killed += 1
    rescue Errno::ESRCH, Errno::EPERM => e
      log_debug("cleanup: failed to kill #{pid}: #{e.message}")
    end
  end

  if orphans_killed.positive?
    warn "🧹 Cleaned up #{orphans_killed} orphaned Claude session#{orphans_killed == 1 ? '' : 's'}"
  end
rescue StandardError => e
  log_debug("Orphan cleanup error: #{e.class}: #{e.message}")
end

# Cleanup orphaned MCP daemon processes
# Fixed 2026-01-11: Now catches ALL orphaned MCPs, not just detached ones
def cleanup_orphaned_mcp_daemons
  my_session_pid = Process.ppid
  session_tree = get_process_tree(my_session_pid)
  log_debug("mcp_cleanup: session_tree size=#{session_tree.size}")

  # Comprehensive list of MCP patterns - add new MCPs here as needed
  mcp_patterns = [
    # claude-mem plugin
    'chroma-mcp',
    'worker-service.cjs',
    'mcp-server.cjs',
    # Standard MCPs (both npm and local dev paths)
    'xcodebuildmcp',
    'xcodebuild-mcp',           # Local dev path variant
    'context7-mcp',
    'apple-docs-mcp',
    'mcp-server-github',
    'server-memory',            # @modelcontextprotocol/server-memory
    'macos-automator',          # @steipete/macos-automator-mcp
    'serena',                   # Serena MCP
    # Generic catch-all for npm-spawned MCPs
    'npx/.*/mcp'
  ]

  ps_output = `ps aux 2>/dev/null`.lines rescue []
  daemons_killed = 0

  ps_output.each do |line|
    # REMOVED: next unless line.include?('??')  # Was only catching detached processes
    # Now catches ALL orphaned MCPs regardless of TTY attachment

    matched_pattern = mcp_patterns.find { |p| line.include?(p) || line.match?(Regexp.new(p)) }
    next unless matched_pattern

    parts = line.split
    pid = parts[1].to_i
    next unless pid.positive?

    if session_tree.include?(pid)
      log_debug("mcp_cleanup: SKIP #{pid} (#{matched_pattern}) - part of current session")
      next
    end

    log_debug("mcp_cleanup: KILL #{pid} (#{matched_pattern})")
    begin
      Process.kill('KILL', pid)
      daemons_killed += 1
    rescue Errno::ESRCH, Errno::EPERM => e
      log_debug("mcp_cleanup: failed to kill #{pid}: #{e.message}")
    end
  end

  if daemons_killed.positive?
    warn "🧹 Cleaned up #{daemons_killed} orphaned MCP daemon#{daemons_killed == 1 ? '' : 's'}"
  end
rescue StandardError => e
  log_debug("MCP daemon cleanup error: #{e.class}: #{e.message}")
end

# Cleanup orphaned Claude subagents (Task tool agents with --resume)
def cleanup_orphaned_subagents
  my_session_pid = Process.ppid
  session_tree = get_process_tree(my_session_pid)
  log_debug("subagent_cleanup: session_tree size=#{session_tree.size}")

  ps_output = `ps aux 2>/dev/null`.lines rescue []
  subagents_killed = 0

  ps_output.each do |line|
    next unless line.include?('claude') && line.include?('--resume')
    next if line.include?('--dangerously-skip-permissions')  # Parent session
    next if line.include?('grep')

    parts = line.split
    pid = parts[1].to_i
    next unless pid.positive?

    if session_tree.include?(pid)
      log_debug("subagent_cleanup: SKIP #{pid} - part of current session")
      next
    end

    log_debug("subagent_cleanup: KILL #{pid}")
    begin
      Process.kill('KILL', pid)
      subagents_killed += 1
    rescue Errno::ESRCH, Errno::EPERM => e
      log_debug("subagent_cleanup: failed to kill #{pid}: #{e.message}")
    end
  end

  if subagents_killed.positive?
    warn "🧹 Cleaned up #{subagents_killed} orphaned subagent#{subagents_killed == 1 ? '' : 's'}"
  end
rescue StandardError => e
  log_debug("Subagent cleanup error: #{e.class}: #{e.message}")
end

# === MEMORY HEALTH CHECK ===
# Catches silent memory failures: Gemini 429s, queue backlog, worker down
# Added after Jan 28-Feb 1 2026 incident where observations stopped silently
CLAUDE_MEM_PORT = 37777
CLAUDE_MEM_DB = File.expand_path('~/.claude-mem/claude-mem.db')
CLAUDE_MEM_LOGS_DIR = File.expand_path('~/.claude-mem/logs')

def check_memory_health
  issues = []

  # 1. Worker responding? (2s timeout to avoid blocking hook)
  begin
    require 'net/http'
    uri = URI("http://127.0.0.1:#{CLAUDE_MEM_PORT}/api/health")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 2
    http.read_timeout = 2
    response = http.request(Net::HTTP::Get.new(uri))
    unless response.code == '200'
      issues << "Worker not healthy (HTTP #{response.code})"
    end
  rescue StandardError => e
    issues << "Worker unreachable on port #{CLAUDE_MEM_PORT}: #{e.message}"
  end

  # 2. Recent observations being saved? (any in last 48h)
  if File.exist?(CLAUDE_MEM_DB)
    begin
      count = `sqlite3 "#{CLAUDE_MEM_DB}" "SELECT count(*) FROM observations WHERE created_at >= datetime('now', '-48 hours');" 2>/dev/null`.strip.to_i
      if count.zero?
        issues << "No observations saved in last 48h (memory capture broken)"
      end
    rescue StandardError => e
      issues << "Cannot query observations DB: #{e.message}"
    end
  else
    issues << "Observations database not found at #{CLAUDE_MEM_DB}"
  end

  # 3. Gemini 429 errors in recent logs? (crash-loop indicator)
  today = Time.now.strftime('%Y-%m-%d')
  yesterday = (Time.now - 86400).strftime('%Y-%m-%d')
  [today, yesterday].each do |day|
    log_file = File.join(CLAUDE_MEM_LOGS_DIR, "claude-mem-#{day}.log")
    next unless File.exist?(log_file)

    # Check last 500 lines for 429 errors (don't read whole 44MB file)
    recent_lines = `tail -500 "#{log_file}" 2>/dev/null`
    error_count = recent_lines.scan(/429|RESOURCE_EXHAUSTED/).length
    if error_count > 10
      issues << "Gemini rate-limited: #{error_count} 429 errors in recent #{day} log (queue likely backed up)"
    end

    # Check for crash-recovery loops
    crash_count = recent_lines.scan(/crash-recovery/).length
    if crash_count > 5
      issues << "Worker crash-looping: #{crash_count} crash-recovery attempts in #{day} log"
    end
  end

  # 4. Check for invalid model config
  settings_file = File.expand_path('~/.claude-mem/settings.json')
  if File.exist?(settings_file)
    begin
      settings = JSON.parse(File.read(settings_file))
      model = settings['CLAUDE_MEM_GEMINI_MODEL'] || ''
      if model.include?('preview')
        issues << "Gemini model '#{model}' may be invalid (preview models expire)"
      end
      if settings['CLAUDE_MEM_GEMINI_RATE_LIMITING_ENABLED'] == 'false'
        issues << "Rate limiting disabled — will hammer API on 429s"
      end
    rescue StandardError
      # Non-critical
    end
  end

  # Report
  if issues.any?
    warn ''
    warn '🧠 MEMORY HEALTH: ISSUES DETECTED'
    issues.each { |i| warn "   🔴 #{i}" }
    warn ''
    warn '   Memory capture may be broken. Fix before doing significant work.'
    warn ''
  else
    log_debug "Memory health: OK"
  end

  issues
rescue StandardError => e
  log_debug "Memory health check error: #{e.message}"
  []
end

# === STARTUP GATE INITIALIZATION ===
# Sets up the gate that blocks substantive work until startup steps complete.
# Auto-completes steps where required files don't exist (cross-project safety).
SKILLS_REGISTRY = File.expand_path('~/.claude/SKILLS_REGISTRY.md')
VALIDATION_SCRIPT = File.join(PROJECT_DIR, 'scripts', 'validation_report.rb')
SANEMASTER_SCRIPT = File.join(PROJECT_DIR, 'scripts', 'SaneMaster.rb')

def initialize_startup_gate
  require_relative 'core/state_manager'

  steps = {
    session_docs: false,
    skills_registry: false,
    validation_report: false,
    sanemem_check: false,
    orphan_cleanup: true,  # Already ran in session_start
    system_clean: false
  }
  timestamps = { orphan_cleanup: Time.now.iso8601 }

  # Auto-complete steps where required files don't exist
  unless File.exist?(SKILLS_REGISTRY)
    steps[:skills_registry] = true
    timestamps[:skills_registry] = Time.now.iso8601
  end

  unless File.exist?(VALIDATION_SCRIPT)
    steps[:validation_report] = true
    timestamps[:validation_report] = Time.now.iso8601
  end

  unless File.exist?(SANEMASTER_SCRIPT)
    steps[:system_clean] = true
    timestamps[:system_clean] = Time.now.iso8601
  end

  # If session_docs has no required docs, auto-complete that step
  session_docs = StateManager.get(:session_docs)
  if (session_docs[:required] || []).empty?
    steps[:session_docs] = true
    timestamps[:session_docs] = Time.now.iso8601
  end

  # Add SKILLS_REGISTRY.md to session_docs.required if it exists
  if File.exist?(SKILLS_REGISTRY)
    StateManager.update(:session_docs) do |sd|
      sd[:required] ||= []
      sd[:required] << 'SKILLS_REGISTRY.md' unless sd[:required].include?('SKILLS_REGISTRY.md')
      sd
    end
  end

  # Check if gate is already open (all steps done)
  all_done = steps.values.all?
  gate = {
    open: all_done,
    opened_at: all_done ? Time.now.iso8601 : nil,
    steps: steps,
    step_timestamps: timestamps
  }

  StateManager.update(:startup_gate) { |_| gate }

  # Print checklist
  pending = steps.reject { |_, v| v }
  if pending.any?
    warn ''
    warn '🚦 STARTUP GATE: Complete these steps before working:'
    pending.each_key do |step|
      case step
      when :session_docs    then warn '   [ ] Read session docs (SESSION_HANDOFF.md, DEVELOPMENT.md)'
      when :skills_registry then warn '   [ ] Read ~/.claude/SKILLS_REGISTRY.md'
      when :validation_report then warn '   [ ] Run: ruby scripts/validation_report.rb'
      when :sanemem_check   then warn '   [ ] Check Sane-Mem: curl localhost:37777/api/health'
      when :system_clean    then warn '   [ ] Run: ./scripts/SaneMaster.rb clean_system'
      end
    end
    warn ''
    warn '   Task, Edit, Write, Bash blocked until complete.'
    warn ''
  else
    warn '🚦 STARTUP GATE: All steps auto-completed — gate open'
  end
rescue StandardError => e
  warn "⚠️  Could not initialize startup gate: #{e.message}"
end

# Build context for Claude (injected via stdout JSON)
def build_session_context
  require_relative 'core/state_manager'
  require_relative 'session_briefing'

  context_parts = []
  project_name = File.basename(PROJECT_DIR)

  # Manifest-based briefing (deterministic, compact)
  briefing = build_manifest_briefing(PROJECT_DIR)
  if briefing
    context_parts << "# [SaneProcess] Session Started"
    context_parts << briefing
  else
    # Fallback for projects without .saneprocess
    context_parts << "# [SaneProcess] Session Started"
    context_parts << "Project: #{project_name}"
    sop_file = find_sop_file
    context_parts << "SOP: #{sop_file}" if sop_file
    context_parts << "⚠️  No .saneprocess manifest — run SaneMaster.rb bootstrap"
  end

  # Pattern rules count
  rules_dir = File.join(CLAUDE_DIR, 'rules')
  if Dir.exist?(rules_dir)
    rule_count = Dir.glob(File.join(rules_dir, '*.md')).count
    context_parts << "Pattern rules: #{rule_count} loaded" if rule_count.positive?
  end

  # MCP verification reminder
  health = StateManager.get(:mcp_health) rescue {}
  unless health.dig(:verified_this_session)
    context_parts << ""
    context_parts << "MCP verification: Required before editing"
    context_parts << "Verify by calling: apple-docs search, context7 resolve, github search"
  end

  # Manifest compliance warnings
  manifest_path = File.join(PROJECT_DIR, '.saneprocess')
  if File.exist?(manifest_path)
    issues = validate_manifest(manifest_path)
    if issues.any?
      context_parts << ""
      context_parts << "⚠️  Compliance issues: #{issues.join(', ')}"
    end
  end

  context_parts.join("\n")
end

# Main execution
begin
  log_debug "Starting session_start hook"
  cleanup_orphaned_claude_processes  # Clean up orphan Claude sessions
  log_debug "cleanup_orphaned_claude_processes done"
  cleanup_orphaned_mcp_daemons        # Clean up orphan MCP daemons
  log_debug "cleanup_orphaned_mcp_daemons done"
  cleanup_orphaned_subagents          # Clean up orphan --resume subagents
  log_debug "cleanup_orphaned_subagents done"
  ensure_claude_dir
  log_debug "ensure_claude_dir done"
  rotate_log_files                  # Prevent unbounded log growth
  log_debug "rotate_log_files done"
  reset_session_state
  log_debug "reset_session_state done"
  clear_stale_satisfaction
  log_debug "clear_stale_satisfaction done"
  handle_stale_saneloop
  log_debug "handle_stale_saneloop done"
  reset_mcp_verification      # Reset MCP verification for new session
  log_debug "reset_mcp_verification done"
  populate_session_docs       # Discover required docs for enforcement
  log_debug "populate_session_docs done"
  initialize_startup_gate     # Block substantive work until startup steps done
  log_debug "initialize_startup_gate done"
  output_session_context      # User-facing messages to stderr
  log_debug "output_session_context done"
  check_pending_mcp_actions   # Alert user to pending actions
  log_debug "check_pending_mcp_actions done"
  show_mcp_verification_status # Show MCP status and prompt
  log_debug "show_mcp_verification_status done"
  check_memory_health           # Catch silent memory failures early
  log_debug "check_memory_health done"

  # Output JSON to stdout for Claude Code to inject into context
  # Must use hookSpecificOutput format for SessionStart hooks
  result = {
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext: build_session_context
    }
  }
  puts JSON.generate(result)
  log_debug "JSON output written - SUCCESS"
rescue StandardError => e
  log_debug "ERROR: #{e.class}: #{e.message}"
  log_debug e.backtrace&.first(5)&.join("\n") || "No backtrace"
  warn "⚠️  Session start error: #{e.message}"
  # Still output valid JSON even on error so Claude Code doesn't show "error"
  puts JSON.generate({
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext: "Session start encountered an error: #{e.message}"
    }
  })
end

exit 0
