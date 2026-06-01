#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneStop Finalize
# ==============================================================================
# Session-end checks (Rule #4 verification, visual verification, handoff),
# validation metrics, and session learnings/receipt persistence — extracted
# from sanestop.rb per Rule #10 (file size limit).
#
# These are bare top-level definitions (matching sanestop.rb's script style):
# required by sanestop.rb, they become Object-private methods so process_stop
# and the self-test's method(:...) handles continue to resolve. All shared
# constants (LOG_FILE, SOP_CSV, SESSION_LEARNINGS_FILE, ...) remain defined in
# sanestop.rb and resolve here via top-level constant fallback.
# ==============================================================================

require 'json'
require 'time'
require 'date'
require 'digest'
require 'open3'
require 'socket'
require 'fileutils'
require 'rbconfig'
require_relative 'core/mandatory_workflows'
require_relative 'core/process_metrics'
require_relative 'core/state_manager'
require_relative 'core/visual_receipt'

# === RULE #4 ENFORCEMENT ===
# Block session end if edits were made but no tests/verification ran.
# This closes the gap where config changes, code changes, etc. go untested.

# Files that don't require test verification (docs, config that's read-only, etc.)
DOC_ONLY_EXTENSIONS = %w[.md .txt .mdx .rst .adoc].freeze

def check_verification_required
  edits = StateManager.get(:edits)

  edit_count = edits[:count] || 0
  unique_files = edits[:unique_files] || []

  # No edits = nothing to verify
  return nil if edit_count.zero?

  # A boolean hook flag is not enough. Require a counted verify metric that
  # matches the current source fingerprint and occurred after the latest edit.
  return nil if strong_session_verify_success?

  # Check if ALL edits were doc-only (markdown, txt) — don't require tests for pure docs
  non_doc_edits = unique_files.reject { |f| DOC_ONLY_EXTENSIONS.include?(File.extname(f).downcase) }
  return nil if non_doc_edits.empty?

  # Edits to non-doc files with no structured verification = BLOCK
  "   #{edit_count} edit(s) across #{non_doc_edits.length} file(s), no fresh structured verify metric.\n" \
  "   Files changed: #{non_doc_edits.map { |f| File.basename(f) }.join(', ')}\n" \
  "   \n" \
  "   Acceptable verification:\n" \
  "   • Run ./scripts/SaneMaster.rb verify so a counted verify metric is recorded\n" \
  "   • The metric must have tests_run > 0, tested evidence, and matching source fingerprint"
rescue StandardError => e
  warn "⚠️  Verification check error: #{e.message}" if ENV['DEBUG']
  nil  # Don't block on errors in the check itself
end

# === VISUAL VERIFICATION ENFORCEMENT ===
# Customer-facing UI work requires screenshot-backed inspection, not just green
# functional tests.

def check_visual_verification_required
  visual = StateManager.get(:visual_verification)
  return nil unless visual[:required]

  receipt_paths = SaneVisualReceipt.valid_receipt_paths(
    cwd: Dir.pwd,
    candidate_paths: visual[:audit_files] || [],
    started_at: session_start_time
  )

  return nil if receipt_paths.any?

  files = (visual[:required_files] || []).first(10)
  reason = visual[:reason] || 'visual verification required'

  "   Visual verification is required (#{reason}).\n" \
  "   Missing: structured Mini visual receipt.\n" \
  "#{files.empty? ? '' : "   UI files/states touched: #{files.join(', ')}\n"}" \
  "   Required proof:\n" \
  "   • Capture clean Mini screenshots for every customer-facing view/state touched.\n" \
  "   • Store a JSON receipt at outputs/customer_ui_action_receipt.json or outputs/visual-audit*/.\n" \
  "   • Receipt must show Mini host, passed status, inspected=true, and existing PNG/JPEG screenshots."
rescue StandardError => e
  warn "⚠️  Visual verification check error: #{e.message}" if ENV['DEBUG']
  nil
end

# === VALIDATION METRICS (Q1, Q2-missed, Q4) ===
# Populates the :validation state section that validation_report.rb reads.
# This data persists across sessions to measure if SaneProcess actually works.

RESET_AUDIT_LOG = File.expand_path('../../.claude/reset_audit.log', __dir__)

# Q1: Block accuracy — compare blocks vs user resets within this session
def count_session_blocks_and_resets
  enforcement = StateManager.get(:enforcement)
  blocks = enforcement[:blocks] || []
  session_start = session_start_time

  session_blocks = blocks.count do |b|
    begin
      Time.parse(b[:timestamp] || b['timestamp']) >= session_start
    rescue ArgumentError
      false
    end
  end

  session_resets = 0
  if File.exist?(RESET_AUDIT_LOG)
    File.readlines(RESET_AUDIT_LOG).each do |line|
      entry = JSON.parse(line) rescue next
      begin
        reset_time = Time.parse(entry['timestamp'])
        session_resets += 1 if reset_time >= session_start
      rescue ArgumentError
        next
      end
    end
  end

  { blocks: session_blocks, resets: session_resets }
rescue StandardError
  { blocks: 0, resets: 0 }
end

# Q2-missed: 3+ trailing consecutive failures without breaker trip
def count_missed_doom_loops
  action_log = StateManager.get(:action_log) || []
  return 0 if action_log.length < 3

  cb = StateManager.get(:circuit_breaker)
  return 0 if cb[:tripped] # Breaker caught it — not missed

  # Count consecutive failures at end of action log
  trailing_failures = 0
  action_log.reverse_each do |action|
    success = action[:success].nil? ? action['success'] : action[:success]
    if success == false
      trailing_failures += 1
    else
      break
    end
  end

  trailing_failures >= 3 ? 1 : 0
rescue StandardError
  0
end

# Update all validation metrics at session end
def update_validation_metrics
  cb = StateManager.get(:circuit_breaker)
  block_stats = count_session_blocks_and_resets
  missed_loops = count_missed_doom_loops

  StateManager.update(:validation) do |v|
    # Q4: Session tracking
    v[:sessions_total] = (v[:sessions_total] || 0) + 1
    if strong_session_verify_success?
      v[:sessions_with_tests_passing] = (v[:sessions_with_tests_passing] || 0) + 1
    end
    if cb[:tripped]
      v[:sessions_with_breaker_trip] = (v[:sessions_with_breaker_trip] || 0) + 1
    end

    # Q1: Block accuracy (resets = user disagreed with block)
    blocks_wrong = [block_stats[:resets], block_stats[:blocks]].min
    blocks_correct = block_stats[:blocks] - blocks_wrong
    v[:blocks_that_were_correct] = (v[:blocks_that_were_correct] || 0) + blocks_correct
    v[:blocks_that_were_wrong] = (v[:blocks_that_were_wrong] || 0) + blocks_wrong

    # Q2: Missed doom loops (trailing failures without breaker trip)
    v[:doom_loops_missed] = (v[:doom_loops_missed] || 0) + missed_loops

    # Timestamps
    v[:first_tracked] ||= Time.now.iso8601
    v[:last_updated] = Time.now.iso8601

    v
  end
rescue StandardError => e
  warn "⚠️  Validation metrics error: #{e.message}" if ENV['DEBUG']
end

# === HANDOFF ENFORCEMENT ===
# Block session end when significant edits were made but SESSION_HANDOFF.md
# and/or memory files were NOT updated. Some paths (hooks/tooling/durable docs)
# bypass the normal threshold and always require persistence.

MIN_EDITS_FOR_HANDOFF = 2  # At least 2 significant edits to trigger
MIN_FILES_FOR_HANDOFF = 1  # At least 1 significant file to trigger

def check_handoff_required
  tracking = StateManager.get(:handoff_tracking)

  sig_edits = tracking[:significant_edits] || 0
  sig_files = tracking[:significant_files] || []
  always_persist_required = tracking[:always_persist_required] || false
  always_persist_files = tracking[:always_persist_files] || []
  handoff_updated = tracking[:handoff_updated] || false
  memory_updated = tracking[:memory_updated] || false

  threshold_hit = sig_edits >= MIN_EDITS_FOR_HANDOFF && sig_files.length >= MIN_FILES_FOR_HANDOFF

  # No tracked work = nothing to report
  return nil unless always_persist_required || threshold_hit

  # Both updated = good
  return nil if handoff_updated && memory_updated

  # Build block message
  missing = []
  missing << 'SESSION_HANDOFF.md' unless handoff_updated
  missing << 'memory (MEMORY.md or Serena write_memory)' unless memory_updated
  file_list = always_persist_required ? always_persist_files : sig_files
  why = if always_persist_required
          "These files are tooling or durable docs and must be persisted even for a single edit."
        else
          "These edits crossed the normal significant-edit threshold."
        end

  "   #{sig_edits} tracked edit(s) to #{file_list.length} file(s):\n" \
  "   #{file_list.first(10).join(', ')}\n" \
  "   \n" \
  "   Why this blocks:\n" \
  "   • #{why}\n" \
  "   \n" \
  "   Missing updates: #{missing.join(' AND ')}\n" \
  "   \n" \
  "   What to do:\n" \
  "   • Update SESSION_HANDOFF.md with what was done + what's pending\n" \
  "   • Update memory with the reusable tooling/docs learnings or decisions\n" \
  "   • Both must be updated before the session can end"
rescue StandardError => e
  warn "⚠️  Handoff check error: #{e.message}" if ENV['DEBUG']
  nil  # Don't block on errors in the check itself
end

# === CHECKS ===

def check_summary_needed
  edits = StateManager.get(:edits)
  edit_count = edits[:count] || 0
  unique_count = edits[:unique_files]&.length || 0

  # Summary needed if significant work was done
  return nil if edit_count < MIN_EDITS_FOR_SUMMARY && unique_count < MIN_UNIQUE_FILES_FOR_SUMMARY

  # Check if this stop hook already fired (prevent loop)
  # Just warn, don't block
  if edit_count >= MIN_EDITS_FOR_SUMMARY || unique_count >= MIN_UNIQUE_FILES_FOR_SUMMARY
    warn '---'
    warn 'Session Summary Reminder'
    warn ''
    warn "You made #{edit_count} edits to #{unique_count} files."
    warn 'Consider ending with a Session Summary per SOP.'
    warn '---'
  end

  nil  # Don't block, just remind
end

def save_session_learnings
  edits = StateManager.get(:edits)
  research = StateManager.get(:research)
  cb = StateManager.get(:circuit_breaker)
  enf = StateManager.get(:enforcement)

  # Calculate violations and SOP score
  violations = count_session_violations
  sop_receipt = build_sop_receipt(violations)
  sop_score = sop_receipt[:sop_score]

  # Calculate session stats
  verify_status = session_verify_status
  stats = {
    timestamp: Time.now.iso8601,
    session_id: sop_receipt[:session_id],
    client: sop_receipt[:client],
    edits: edits[:count] || 0,
    unique_files: edits[:unique_files]&.length || 0,
    research_done: research.compact.keys.length,
    failures: cb[:failures] || 0,
    blocks: enf[:blocks]&.length || 0,
    halted: enf[:halted] || false,
    violations: violations,
    sop_score: sop_score,
    base_score: sop_receipt[:base_score],
    block_count: sop_receipt[:block_count],
    cap_score: sop_receipt[:cap_score],
    cap_reason: sop_receipt[:cap_reason],
    verify_attempts: verify_status[:attempts],
    verify_failures: verify_status[:failures],
    verify_zero_test_failures: verify_status[:zero_test_failures],
    verify_zero_test_successes: verify_status[:zero_test_successes],
    final_verify_success: verify_status[:last_success],
    final_verify_tests_run: verify_status[:last_tests_run],
    final_verify_evidence_strength: verify_status[:last_evidence_strength],
    final_verify_timestamp: verify_status[:last_timestamp]
  }

  SaneProcessMetrics.record(
    'session_end',
    session_id: stats[:session_id],
    client: stats[:client],
    success: verify_status[:last_success],
    sop_score: sop_score,
    base_score: stats[:base_score],
    block_count: stats[:block_count],
    cap_score: stats[:cap_score],
    cap_reason: stats[:cap_reason],
    edits: stats[:edits],
    unique_files: stats[:unique_files],
    verify_attempts: verify_status[:attempts],
    verify_failures: verify_status[:failures],
    verify_zero_test_failures: verify_status[:zero_test_failures],
    verify_zero_test_successes: verify_status[:zero_test_successes],
    final_verify_success: verify_status[:last_success],
    final_verify_tests_run: verify_status[:last_tests_run],
    final_verify_evidence_strength: verify_status[:last_evidence_strength],
    final_verify_timestamp: verify_status[:last_timestamp]
  )
  SaneProcessMetrics.record('session_receipt', build_client_neutral_session_receipt(stats, violations, verify_status))

  # Update patterns for future sessions
  update_session_patterns(violations, sop_score)

  # Check score variance (warns if suspiciously consistent)
  check_score_variance(sop_score)

  # Check weasel words in recent edits
  check_weasel_words

  # Update validation metrics (Q1 block accuracy, Q2 missed doom loops, Q4 session counts)
  update_validation_metrics

  log_session(stats)
  capture_session_learnings
  stats
end

def build_client_neutral_session_receipt(stats, violations, verify_status)
  started_at = session_start_time
  completed_at = Time.now.utc
  git_root = current_git_value('rev-parse', '--show-toplevel')
  client = stats[:client].to_s
  {
    schema_version: 2,
    receipt_id: Digest::SHA256.hexdigest("#{stats[:session_id]}|#{completed_at.iso8601}")[0, 16],
    session_id: stats[:session_id],
    client: client,
    client_name: client,
    client_kind: client_kind(client),
    host: Socket.gethostname,
    git_root: git_root,
    git_head: current_git_value('rev-parse', 'HEAD'),
    git_branch: current_git_value('rev-parse', '--abbrev-ref', 'HEAD'),
    source_fingerprint: current_source_fingerprint,
    started_at: started_at.utc.iso8601,
    completed_at: completed_at.iso8601,
    duration_ms: ((completed_at - started_at) * 1000).round,
    success: verify_status[:last_success],
    edits: stats[:edits],
    unique_files: stats[:unique_files],
    changed_file_count: stats[:unique_files],
    block_count: stats[:block_count],
    violations: violations,
    verify_attempts: verify_status[:attempts],
    verify_failures: verify_status[:failures],
    verify_zero_test_failures: verify_status[:zero_test_failures],
    verify_zero_test_successes: verify_status[:zero_test_successes],
    final_verify_success: verify_status[:last_success],
    final_verify_tests_run: verify_status[:last_tests_run],
    final_verify_evidence_strength: verify_status[:last_evidence_strength],
    final_verify_timestamp: verify_status[:last_timestamp],
    final_verify_source_fingerprint: verify_status[:last_source_fingerprint],
    workflow_receipt_ids: recent_workflow_receipt_ids,
    visual_receipt_paths: current_visual_receipt_paths,
    handoff_updated: handoff_updated_since?(started_at),
    memory_updated: false,
    research_topics_captured: 0,
    sop_score: stats[:sop_score],
    base_score: stats[:base_score],
    cap_score: stats[:cap_score],
    cap_reason: stats[:cap_reason],
    scorer_version: 'sane_sop_score_v1'
  }
end

def current_git_value(*args)
  output, status = Open3.capture2e('git', *args)
  status.success? ? output.strip : nil
rescue StandardError
  nil
end

def client_kind(client)
  value = client.to_s.downcase
  return 'codex' if value.include?('codex')
  return 'claude' if value.include?('claude')

  value.empty? ? 'unknown' : value
end

def recent_workflow_receipt_ids
  path = SaneProcessMetrics.metrics_path
  return [] unless File.exist?(path)

  started = session_start_time
  File.readlines(path).map do |line|
    event = JSON.parse(line)
    next unless event['type'] == 'workflow_receipt'

    timestamp = Time.parse(event['timestamp'].to_s)
    next if timestamp < started

    event['receipt_id'] || event['command_sha256']
  rescue JSON::ParserError, ArgumentError
    nil
  end.compact.uniq
rescue StandardError
  []
end

def current_visual_receipt_paths
  visual = StateManager.get(:visual_verification)
  SaneVisualReceipt.valid_receipt_paths(
    cwd: Dir.pwd,
    candidate_paths: visual[:audit_files] || [],
    started_at: session_start_time
  )
rescue StandardError
  []
end

def handoff_updated_since?(started_at)
  ['SESSION_HANDOFF.md', '.claude/SESSION_HANDOFF.md'].any? do |path|
    File.exist?(path) && File.mtime(path) >= started_at
  end
rescue StandardError
  false
end

# === SESSION LEARNINGS CAPTURE ===
# Writes structured session learnings to ~/.claude/session_learnings.jsonl
# when the session had significant work. No external dependencies.

def capture_session_learnings
  edits = StateManager.get(:edits)
  cb = StateManager.get(:circuit_breaker)

  edit_count = edits[:count] || 0
  unique_files = edits[:unique_files] || []
  tripped = cb[:tripped] || false

  # Only capture if significant work happened
  return unless edit_count >= 3 || tripped

  project = File.basename(Dir.pwd)

  session_type = if tripped
                   'recovery'
                 elsif edit_count >= 5
                   'feature'
                 else
                   'maintenance'
                 end

  file_names = unique_files.map { |f| File.basename(f) }.uniq.first(5)
  summary = "#{edit_count} edits across #{unique_files.length} files: #{file_names.join(', ')}"

  entry = {
    date: Date.today.to_s,
    project: project,
    type: session_type,
    summary: summary,
    files: unique_files.first(10),
    failures: cb[:failures] || 0,
    breaker_tripped: tripped
  }

  FileUtils.mkdir_p(File.dirname(SESSION_LEARNINGS_FILE))
  File.open(SESSION_LEARNINGS_FILE, 'a') { |f| f.puts(entry.to_json) }
  enforce_learnings_cap
rescue StandardError => e
  warn "⚠️  Session learnings capture error: #{e.message}" if ENV['DEBUG']
end

def enforce_learnings_cap
  return unless File.exist?(SESSION_LEARNINGS_FILE)

  lines = File.readlines(SESSION_LEARNINGS_FILE)
  return if lines.length <= SESSION_LEARNINGS_MAX_LINES

  overflow = lines.length - SESSION_LEARNINGS_MAX_LINES
  archived = lines.first(overflow)
  kept = lines.last(SESSION_LEARNINGS_MAX_LINES)

  File.open(SESSION_LEARNINGS_ARCHIVE, 'a') { |f| archived.each { |l| f.write(l) } }
  File.write(SESSION_LEARNINGS_FILE, kept.join)
rescue StandardError
  # Don't fail on cap enforcement
end

def log_session(stats)
  FileUtils.mkdir_p(File.dirname(LOG_FILE))
  File.open(LOG_FILE, 'a') { |f| f.puts(stats.to_json) }

  # Append SOP score to CSV for validation_report.rb trend tracking
  append_sop_receipts(stats)
rescue StandardError
  # Don't fail on logging errors
end

def append_sop_receipts(stats)
  return unless stats[:sop_score]

  csv_dir = File.dirname(SOP_CSV)
  FileUtils.mkdir_p(csv_dir)

  # Create header if file doesn't exist or is empty
  unless File.exist?(SOP_CSV) && File.size(SOP_CSV) > 0
    File.write(SOP_CSV, "date,sop_score,session_id,client,block_count,cap_reason,verify_attempts,verify_failures,final_verify_success,edits,unique_files,notes_json\n")
  end

  notes = JSON.generate(
    violations: stats[:violations],
    base_score: stats[:base_score],
    cap_score: stats[:cap_score],
    cap_reason: stats[:cap_reason],
    verify_zero_test_failures: stats[:verify_zero_test_failures],
    verify_zero_test_successes: stats[:verify_zero_test_successes],
    final_verify_tests_run: stats[:final_verify_tests_run],
    final_verify_evidence_strength: stats[:final_verify_evidence_strength],
    final_verify_timestamp: stats[:final_verify_timestamp]
  )
  row = [
    Date.today,
    stats[:sop_score],
    stats[:session_id],
    stats[:client],
    stats[:block_count],
    stats[:cap_reason],
    stats[:verify_attempts],
    stats[:verify_failures],
    stats[:final_verify_success],
    stats[:edits],
    stats[:unique_files],
    notes
  ].map { |value| csv_escape(value) }.join(',')
  File.open(SOP_CSV, 'a') { |f| f.puts(row) }
  File.open(SOP_JSONL, 'a') { |f| f.puts(JSON.generate(stats)) }
rescue StandardError
  # Don't fail on CSV errors
end

def csv_escape(value)
  text = value.nil? ? '' : value.to_s
  return text unless text.match?(/[",\n]/)

  %("#{text.gsub('"', '""')}")
end

def session_id
  Digest::SHA256.hexdigest("#{Dir.pwd}|#{session_start_time.utc.iso8601}")[0, 12]
end

def session_client
  ENV['SANE_AGENT_CLIENT'] || ENV['SANE_CLIENT'] || 'claude-hook'
end

def run_mcp_watchdog_cleanup
  return if ENV['SANE_SKIP_MCP_WATCHDOG_CLEANUP'] == '1'

  sane_master = File.expand_path('../SaneMaster.rb', __dir__)
  return unless File.exist?(sane_master)

  system(
    RbConfig.ruby, sane_master, 'mcp_watchdog', 'clean',
    '--quiet', '--max', '4', '--grace', '0',
    out: File::NULL, err: File::NULL
  )
rescue StandardError
  # Never block stop hook on cleanup.
end
