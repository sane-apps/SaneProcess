#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

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
require 'rbconfig'
require_relative 'state_signer'
require_relative 'session_start_cleanup'
require_relative 'core/project_root'

PROJECT_DIR = SaneProjectRoot.resolve
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
include SessionStartCleanup

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

  require_relative 'core/state_manager'
  StateManager.update(:circuit_breaker) do |cb|
    next cb if cb[:tripped]

    cb[:failures] = 0
    cb[:last_error] = nil
    cb[:error_signatures] = {}
    cb
  end
end

def find_sop_file
  candidates = %w[DEVELOPMENT.md CONTRIBUTING.md SOP.md docs/SOP.md]
  candidates.find { |f| File.exist?(File.join(PROJECT_DIR, f)) }
end

def current_git_dirty_files
  root_out, root_status = Open3.capture2e('git', '-C', PROJECT_DIR, 'rev-parse', '--show-toplevel')
  return [] unless root_status.success?

  root = root_out.strip
  status_out, status = Open3.capture2e('git', '-C', root, 'status', '--porcelain=v1', '--untracked-files=all')
  return [] unless status.success?

  status_out.each_line.map do |line|
    path = line[3..-1]&.strip
    next if path.to_s.empty?

    path = path.split(' -> ', 2).last if path.include?(' -> ')
    expanded = File.expand_path(path.delete_prefix('"').delete_suffix('"'), root)
    File.realdirpath(expanded)
  rescue StandardError
    expanded
  end.compact.uniq
rescue StandardError
  []
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
  StateManager.reset(:visual_verification)

  # Per-session work/requirement counters must NOT bleed across sessions, or a
  # new session inherits stale state and fires false gates:
  #   - :edits        → Stop-hook Rule #4 blocks a read-only session for edits
  #                     made (and possibly already verified/committed) yesterday.
  #   - :requirements → a prior prompt's requirement (e.g. "commit") blocks every
  #                     edit in an unrelated session, with no reset command to clear it.
  #   - :handoff_tracking → stale significant-edit counts trigger handoff blocks.
  #   - :skill        → a prior session's required/invoked skill leaks into the
  #                     Stop-hook skill validation.
  # saneprompt re-populates :requirements and :skill on the first prompt of the
  # session, so resetting here is safe.
  StateManager.reset(:edits)
  StateManager.update(:edits) do |edits|
    # A session owns only changes made after it starts. Keeping the initial
    # working-tree dirt separate prevents unrelated/pre-existing files from
    # being attributed to a later Bash command or completion gate.
    edits[:baseline_dirty_files] = current_git_dirty_files
    edits
  end
  StateManager.reset(:requirements)
  StateManager.reset(:handoff_tracking)
  StateManager.reset(:skill)

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

  state = JSON.parse(File.read(SANELOOP_STATE_FILE, encoding: Encoding::UTF_8), symbolize_names: true)
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
      staging = JSON.parse(File.read(MEMORY_STAGING_FILE, encoding: Encoding::UTF_8))
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
# Reset verification for new session and prompt Claude to verify MCPs.
# The authoritative required-MCP list lives in
# sanetools_research.rb MCP_VERIFICATION_INFO (currently Apple Docs only).

def reset_mcp_verification
  require_relative 'core/state_manager'

  # Reset verification flag for new session (MCPs must re-verify)
  StateManager.update(:mcp_health) do |health|
    health[:verified_this_session] = false
    health[:gate_block_attempts] = 0
    health[:degraded] = false
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
  required_paths = found.each_with_object({}) { |file, memo| memo[file] = File.join(PROJECT_DIR, file) }

  StateManager.update(:session_docs) do |sd|
    sd[:required] = found
    sd[:required_paths] = required_paths
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

  JSON.parse(File.read(XCODE_AUTOMATION_STATE_FILE, encoding: Encoding::UTF_8))
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

  state = JSON.parse(File.read(LINK_MONITOR_STATE, encoding: Encoding::UTF_8))
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
def codex_runtime?
  ENV['CODEX_SHELL'] == '1' || ENV['CODEX_INTERNAL_ORIGINATOR_OVERRIDE'].to_s.include?('Codex')
end

def active_skills_registry_path
  codex_registry = File.expand_path('~/.codex/SKILLS_REGISTRY.md')
  claude_registry = File.expand_path('~/.claude/SKILLS_REGISTRY.md')
  preferred = codex_runtime? ? codex_registry : claude_registry
  fallback = codex_runtime? ? claude_registry : codex_registry

  return preferred if File.exist?(preferred)
  return fallback if File.exist?(fallback)

  preferred
end

SKILLS_REGISTRY = active_skills_registry_path
SKILLS_REGISTRY_LABEL = SKILLS_REGISTRY.sub(File.expand_path('~'), '~')
VALIDATION_SCRIPT = File.join(PROJECT_DIR, 'scripts', 'validation_report.rb')
SANEMASTER_SCRIPT = File.join(PROJECT_DIR, 'scripts', 'SaneMaster.rb')

# Name every required session doc in the checklist, not a hardcoded subset.
# populate_session_docs discovers the real set (which includes CONTRIBUTING.md and
# SKILLS_REGISTRY.md when present), so a fixed 2-doc label leaves the agent blocked
# on an unnamed file.
def session_docs_required_label
  require_relative 'core/state_manager'
  required = StateManager.get(:session_docs)[:required] || []
  required.empty? ? 'SESSION_HANDOFF.md, DEVELOPMENT.md' : required.join(', ')
rescue StandardError
  'SESSION_HANDOFF.md, DEVELOPMENT.md'
end

def initialize_startup_gate
  require_relative 'core/state_manager'

  steps = {
    session_docs: false,
    skills_registry: false,
    validation_report: false,
    orphan_cleanup: true,  # Already ran in session_start
    system_clean: ENV['SANE_REQUIRE_SYSTEM_CLEAN'] != '1'
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
      sd[:required_paths] ||= {}
      sd[:required] << 'SKILLS_REGISTRY.md' unless sd[:required].include?('SKILLS_REGISTRY.md')
      sd[:required_paths]['SKILLS_REGISTRY.md'] = SKILLS_REGISTRY
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
      when :session_docs    then warn "   [ ] Read session docs (#{session_docs_required_label})"
      when :skills_registry then warn "   [ ] Read #{SKILLS_REGISTRY_LABEL}"
      when :validation_report then warn '   [ ] Run: ruby scripts/validation_report.rb'
      when :system_clean    then warn '   [ ] Run: ./scripts/SaneMaster.rb machine_cleanup --host mini --apply (only when explicitly required)'
      end
    end
    warn ''
    warn '   Substantive mutation is blocked until complete. Small read-only answers do not need the full gate.'
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
    context_parts << "Serena activate reminder: run Serena activate for the current project before symbol-level edits"
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
  run_mcp_watchdog_cleanup            # Enforce daemon cap and clear duplicates
  log_debug "run_mcp_watchdog_cleanup done"
  cleanup_orphaned_subagents          # Clean up orphan --resume subagents
  log_debug "cleanup_orphaned_subagents done"
  cleanup_orphaned_dev_servers        # Reap leaked agent dev/test servers (RAM discipline)
  log_debug "cleanup_orphaned_dev_servers done"
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

  if ENV['SANE_STARTUP_LAUNCH_XCODE'] == '1'
    # Launch Xcode only for explicit local IDE work. SaneApps app work is Mini-first.
    launch_xcode_if_needed
    log_debug "launch_xcode_if_needed done"
    prime_xcode_automation_permission
    log_debug "prime_xcode_automation_permission done"
  else
    log_debug "launch_xcode_if_needed skipped (SANE_STARTUP_LAUNCH_XCODE != 1)"
  end

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
