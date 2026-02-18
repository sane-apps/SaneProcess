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
require 'open3'
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
XCODE_AUTOMATION_STATE_FILE = File.join(CLAUDE_DIR, 'xcode_automation_state.json')
XCODE_AUTOMATION_RETRY_SECONDS = 600
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

  # Check memory staging (uses official @modelcontextprotocol/server-memory)
  if File.exist?(MEMORY_STAGING_FILE)
    begin
      staging = JSON.parse(File.read(MEMORY_STAGING_FILE))
      if staging['needs_memory_update']
        pending << {
          type: 'memory_staging',
          message: "Memory staging needs saving: #{staging['suggested_entity']&.dig('name') || 'learnings'}",
          action: 'Save via Memory MCP add_observations tool, then delete memory_staging.json'
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
# Clean up truly orphaned processes — those whose parent Claude session is DEAD.
# CRITICAL: Never kill processes belonging to OTHER living Claude sessions.
# The user may intentionally run multiple Claude instances in parallel.

# Build parent→children map from ps output (cached for reuse across cleanup functions)
def build_process_maps
  return @process_maps if @process_maps

  ps_lines = `ps -eo pid,ppid,command 2>/dev/null`.lines rescue []
  children_map = Hash.new { |h, k| h[k] = [] }
  command_map = {}

  ps_lines.each do |line|
    parts = line.strip.split(/\s+/, 3)
    next if parts.length < 2
    pid = parts[0].to_i
    ppid = parts[1].to_i
    cmd = parts[2] || ''
    next unless pid.positive? && ppid.positive?
    children_map[ppid] << pid
    command_map[pid] = cmd
  end

  @process_maps = { children: children_map, commands: command_map }
end

# Check if a process is alive
def process_alive?(pid)
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true # exists but we can't signal it
end

# Check if a process has a living Claude ancestor (meaning it's NOT an orphan)
def has_living_claude_ancestor?(pid)
  maps = build_process_maps
  current = pid
  10.times do
    ppid = `ps -o ppid= -p #{current} 2>/dev/null`.strip.to_i rescue 0
    break if ppid <= 1 # Reached init/launchd — no Claude ancestor found
    cmd = maps[:commands][ppid] || ''
    # A Claude session parent process
    if cmd.include?('claude') && !cmd.include?('grep')
      return process_alive?(ppid)
    end
    current = ppid
  end
  false # No Claude ancestor found — this is an orphan
end

# Get all PIDs in a process's descendant tree
def get_process_tree(root_pid)
  maps = build_process_maps
  tree = [root_pid]
  queue = [root_pid]
  while queue.any?
    current = queue.shift
    children = maps[:children][current] || []
    children.each do |child|
      tree << child
      queue << child
    end
  end
  tree
end

# Find all living Claude session PIDs (all instances, not just current)
def find_all_claude_session_pids
  maps = build_process_maps
  pids = []
  maps[:commands].each do |pid, cmd|
    # Claude Code sessions: look for the main CLI process
    if cmd.include?('claude') && !cmd.include?('--resume') && !cmd.include?('grep')
      pids << pid if process_alive?(pid)
    end
  end
  # Always include current session's parent
  pids << Process.ppid
  pids.uniq
end

# Build combined tree of ALL living Claude sessions
def get_all_claude_trees
  all_pids = find_all_claude_session_pids
  combined = {}
  all_pids.each do |pid|
    get_process_tree(pid).each { |p| combined[p] = true }
  end
  log_debug("all_claude_trees: #{all_pids.length} sessions, #{combined.size} total PIDs")
  combined
end

# Cleanup orphaned Claude parent sessions
# Only kills Claude processes that are truly orphaned (PPID=1, re-parented to launchd)
def cleanup_orphaned_claude_processes
  my_ancestors = []
  current = Process.pid
  10.times do
    ppid = `ps -o ppid= -p #{current} 2>/dev/null`.strip.to_i rescue 0
    break if ppid <= 1
    my_ancestors << ppid
    current = ppid
  end

  log_debug("cleanup: my ancestors=#{my_ancestors.inspect}")

  maps = build_process_maps
  orphans_killed = 0

  maps[:commands].each do |pid, cmd|
    next unless cmd.include?('--dangerously-skip-permissions')
    next if cmd.include?('grep')
    next if my_ancestors.include?(pid) || pid == Process.pid

    # Only kill if truly orphaned (parent is launchd/init, PID 1)
    ppid = `ps -o ppid= -p #{pid} 2>/dev/null`.strip.to_i rescue 0
    unless ppid <= 1
      log_debug("cleanup: SKIP #{pid} (ppid=#{ppid}, not orphaned)")
      next
    end

    log_debug("cleanup: KILL #{pid} (orphaned, ppid=1)")
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

  # Detect stale sessions in other terminals (not orphaned, but old)
  # >24h = auto-kill (almost certainly accidental), 6-24h = warn
  stale_warned = []
  stale_killed = 0
  maps[:commands].each do |pid, cmd|
    next unless cmd.include?('--dangerously-skip-permissions')
    next if cmd.include?('grep')
    next if my_ancestors.include?(pid) || pid == Process.pid

    ppid = `ps -o ppid= -p #{pid} 2>/dev/null`.strip.to_i rescue 0
    next if ppid <= 1 # Already handled above as orphan

    # Check how old this process is
    elapsed = `ps -o etime= -p #{pid} 2>/dev/null`.strip rescue ''
    next if elapsed.empty?

    # Parse etime format: [[dd-]hh:]mm:ss
    parts = elapsed.split(/[-:]/).map(&:to_i)
    total_hours = case parts.length
                  when 4 then parts[0] * 24 + parts[1] # dd-hh:mm:ss
                  when 3 then parts[0]                   # hh:mm:ss
                  else 0                                  # mm:ss
                  end

    tty = `ps -o tty= -p #{pid} 2>/dev/null`.strip rescue '?'

    if total_hours >= 24
      # Auto-kill: >24h is almost certainly accidental
      log_debug("cleanup: KILL stale session #{pid} (#{total_hours}h old, tty=#{tty})")
      begin
        Process.kill('TERM', pid)
        sleep 0.5
        Process.kill('KILL', pid) if process_alive?(pid)
        stale_killed += 1
      rescue Errno::ESRCH, Errno::EPERM => e
        log_debug("cleanup: failed to kill stale #{pid}: #{e.message}")
      end
    elsif total_hours >= 6
      stale_warned << { pid: pid, hours: total_hours, tty: tty }
    end
  end

  if stale_killed.positive?
    warn "🧹 Auto-killed #{stale_killed} stale Claude session#{stale_killed == 1 ? '' : 's'} (>24h old)"
  end

  if stale_warned.any?
    warn ''
    warn "⚠️  STALE CLAUDE SESSIONS (#{stale_warned.length}):"
    stale_warned.each do |s|
      warn "   PID #{s[:pid]} — running #{s[:hours]}h — terminal #{s[:tty]}"
    end
    warn '   Close them to free resources. To kill: kill <PID>'
    warn ''
  end
rescue StandardError => e
  log_debug("Orphan cleanup error: #{e.class}: #{e.message}")
end

# Cleanup orphaned MCP daemon processes
# Fixed 2026-02-09: Only kills MCPs not in ANY living Claude session's tree
def cleanup_orphaned_mcp_daemons
  all_trees = get_all_claude_trees

  # Comprehensive list of MCP patterns
  mcp_patterns = [
    'chroma-mcp', 'worker-service.cjs', 'mcp-server.cjs',
    'mcpbridge', 'context7-mcp', 'apple-docs-mcp',
    'mcp-server-github', 'server-memory', 'macos-automator',
    'serena', 'nvidia_mcp_server'
  ]
  mcp_regex_patterns = ['npx/.*/mcp']

  maps = build_process_maps
  daemons_killed = 0

  maps[:commands].each do |pid, cmd|
    matched = mcp_patterns.find { |p| cmd.include?(p) }
    matched ||= mcp_regex_patterns.find { |p| cmd.match?(Regexp.new(p)) }
    next unless matched

    if all_trees[pid]
      log_debug("mcp_cleanup: SKIP #{pid} (#{matched}) - belongs to a living session")
      next
    end

    # Double-check: walk ancestors to find a living Claude parent
    if has_living_claude_ancestor?(pid)
      log_debug("mcp_cleanup: SKIP #{pid} (#{matched}) - has living Claude ancestor")
      next
    end

    log_debug("mcp_cleanup: KILL #{pid} (#{matched}) - truly orphaned")
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
# Only kills subagents not in ANY living Claude session's tree
def cleanup_orphaned_subagents
  all_trees = get_all_claude_trees
  maps = build_process_maps
  subagents_killed = 0

  maps[:commands].each do |pid, cmd|
    next unless cmd.include?('claude') && cmd.include?('--resume')
    next if cmd.include?('--dangerously-skip-permissions')
    next if cmd.include?('grep')

    if all_trees[pid]
      log_debug("subagent_cleanup: SKIP #{pid} - belongs to a living session")
      next
    end

    if has_living_claude_ancestor?(pid)
      log_debug("subagent_cleanup: SKIP #{pid} - has living Claude ancestor")
      next
    end

    log_debug("subagent_cleanup: KILL #{pid} - truly orphaned")
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


# === SALES INFRASTRUCTURE CHECK ===
# Launch Xcode if the project has an .xcodeproj and Xcode isn't running.
# The Xcode MCP server requires Xcode to be open.
def launch_xcode_if_needed
  xcodeproj = Dir.glob(File.join(PROJECT_DIR, '*.xcodeproj')).first
  return unless xcodeproj

  running = system('pgrep -x Xcode >/dev/null 2>&1')
  if running
    log_debug "Xcode already running"
  else
    system('open', '-a', 'Xcode', xcodeproj)
    warn "🔨 Launched Xcode with #{File.basename(xcodeproj)}"
  end
rescue StandardError => e
  log_debug "launch_xcode error: #{e.message}"
end

def load_xcode_automation_state
  return {} unless File.exist?(XCODE_AUTOMATION_STATE_FILE)

  JSON.parse(File.read(XCODE_AUTOMATION_STATE_FILE))
rescue StandardError
  {}
end

def save_xcode_automation_state(state)
  File.write(XCODE_AUTOMATION_STATE_FILE, JSON.pretty_generate(state))
rescue StandardError => e
  log_debug "xcode automation state write failed: #{e.message}"
end

def xcode_automation_recently_checked?
  state = load_xcode_automation_state
  checked_at = state['checked_at']
  return false unless checked_at

  Time.now - Time.parse(checked_at) < XCODE_AUTOMATION_RETRY_SECONDS
rescue StandardError
  false
end

# Prime one AppleEvent to Xcode at session start so the permission prompt is
# handled once up front, instead of repeated runtime prompts.
def prime_xcode_automation_permission
  xcodeproj = Dir.glob(File.join(PROJECT_DIR, '*.xcodeproj')).first
  return unless xcodeproj
  return if xcode_automation_recently_checked?

  _out, err, status = Open3.capture3('osascript', '-e', 'tell application id "com.apple.dt.Xcode" to id')
  state = {
    'checked_at' => Time.now.iso8601,
    'ok' => status.success?
  }
  state['error'] = err.strip unless status.success?
  save_xcode_automation_state(state)

  return if status.success?

  warn ''
  warn '⚠️  Xcode automation permission not granted yet.'
  warn '   Open System Settings → Privacy & Security → Automation'
  warn '   Enable automation for Claude/Codex → Xcode'
  warn ''
rescue StandardError => e
  log_debug "prime_xcode_automation_permission error: #{e.message}"
end

# Read link monitor state and alert if checkout links are broken
LINK_MONITOR_STATE = File.expand_path('~/SaneApps/infra/SaneProcess/outputs/link_monitor_state.json')

def check_sales_infrastructure
  return unless File.exist?(LINK_MONITOR_STATE)

  state = JSON.parse(File.read(LINK_MONITOR_STATE))
  consec_failures = state['consecutive_failures'] || 0
  last_failure_details = state['last_failure_details'] || []

  if consec_failures > 0
    warn ''
    warn '🔴 SALES INFRASTRUCTURE: BROKEN LINKS DETECTED'
    warn "   Consecutive failures: #{consec_failures}"
    warn "   Last failure: #{state['last_failure']}"
    last_failure_details.each { |d| warn "   → #{d}" }
    warn ''
    warn '   Revenue is being lost. Fix immediately.'
    warn '   Run: ruby ~/SaneApps/infra/SaneProcess/scripts/link_monitor.rb'
    warn ''
  end

  # Also check if monitor hasn't run recently (stale state = no monitoring)
  last_success = state['last_success']
  if last_success
    hours_since = (Time.now - Time.parse(last_success)) / 3600.0
    if hours_since > 2
      warn ''
      warn "⚠️  Link monitor hasn't reported success in #{hours_since.round(1)}h"
      warn '   Check: launchctl list | grep link-monitor'
      warn ''
    end
  end
rescue StandardError => e
  log_debug "Sales infrastructure check error: #{e.message}"
end

# === MODEL ROUTING SYNC ===
# Pull latest model_routing.json from Mini if it's newer than local copy.
# Non-blocking: 3s SSH timeout. If Mini is asleep or unreachable, skip silently.
ROUTING_LOCAL = File.expand_path('~/SaneApps/infra/outputs/model_routing.json')
ROUTING_REMOTE = 'mini:~/SaneApps/infra/outputs/model_routing.json'

def sync_model_routing
  # Skip if local file is fresh (updated today)
  if File.exist?(ROUTING_LOCAL)
    local_age_hours = (Time.now - File.mtime(ROUTING_LOCAL)) / 3600.0
    if local_age_hours < 24
      log_debug "model_routing: local file is #{local_age_hours.round(1)}h old, skipping sync"
      return
    end
  end

  # Try SCP with short timeout (Mini may be asleep)
  result = `scp -o ConnectTimeout=3 -o BatchMode=yes #{ROUTING_REMOTE} #{ROUTING_LOCAL} 2>&1`
  status = $?.success?

  if status
    warn '🔄 Synced model_routing.json from Mini'
  else
    log_debug "model_routing sync skipped: #{result.strip}"
  end
rescue StandardError => e
  log_debug "Model routing sync error: #{e.message}"
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
    # Fallback for projects without .saneprocess manifest
    context_parts << "# [SaneProcess] Session Started"
    context_parts << "Project: #{project_name}"
    sop_file = find_sop_file
    context_parts << "SOP: #{sop_file}" if sop_file
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

  # Recent session learnings (replaces old external memory health briefing)
  learnings = load_recent_learnings(5)
  if learnings.any?
    context_parts << ""
    context_parts << "Recent session learnings:"
    learnings.each do |l|
      context_parts << "  - [#{l['date']}] #{l['project']}: #{l['summary']}"
    end
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
  log_debug "session learnings briefing loaded (replaces legacy memory briefing)"

  # Launch Xcode if project has .xcodeproj and Xcode isn't running
  launch_xcode_if_needed
  log_debug "launch_xcode_if_needed done"
  prime_xcode_automation_permission
  log_debug "prime_xcode_automation_permission done"

  # Check sales infrastructure health (link monitor state)
  check_sales_infrastructure
  log_debug "check_sales_infrastructure done"

  # Sync model routing from Mini (non-blocking, 3s timeout)
  sync_model_routing
  log_debug "sync_model_routing done"

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
