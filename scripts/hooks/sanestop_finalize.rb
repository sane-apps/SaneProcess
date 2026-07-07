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
require_relative 'sanestop_learnings'

TRANSCRIPT_TOKEN_KEYS = %w[
  input_tokens output_tokens total_tokens cached_tokens cache_read_input_tokens
  cache_creation_input_tokens reasoning_tokens
].freeze unless defined?(TRANSCRIPT_TOKEN_KEYS)
TRANSCRIPT_TOKEN_TOTAL_COMPONENTS = %w[
  input_tokens output_tokens cached_tokens cache_read_input_tokens
  cache_creation_input_tokens
].freeze unless defined?(TRANSCRIPT_TOKEN_TOTAL_COMPONENTS)

# === RULE #4 ENFORCEMENT ===
# Block session end if edits were made but no tests/verification ran.
# This closes the gap where config changes, code changes, etc. go untested.

# Files that don't require test verification (docs, config that's read-only, etc.)
DOC_ONLY_EXTENSIONS = %w[.md .txt .mdx .rst .adoc].freeze

# Net uncommitted source state. Returns the list of changed working-tree paths
# (modified, staged, or untracked), or nil when the directory is not a git repo
# or git is unavailable. RULE #4 keys off THIS, not the cumulative session edit
# counter: work that was committed+pushed (or where the tree was reset to
# origin) leaves a clean tree and must not re-fire the verify block on every
# turn-end. The old counter could only be satisfied by a fresh build, so a
# published release looped here forever.
def uncommitted_working_tree_files(cwd = Dir.pwd)
  out, status = Open3.capture2e('git', '-C', cwd, 'status', '--porcelain', '--untracked-files=all')
  return nil unless status.success?

  # map+compact, not filter_map: hooks run under the system ruby (2.6), where
  # filter_map does not exist — it raised NoMethodError into the rescue below,
  # silently reverting RULE #4 to the counter behavior it replaces.
  out.each_line.map do |line|
    path = line[3..-1]&.strip
    next nil if path.nil? || path.empty?

    # Rename entries are "old -> new"; the new path is what currently exists.
    path.include?(' -> ') ? path.split(' -> ').last : path
  end.compact
rescue StandardError
  nil
end

def verification_block_message(count, files)
  "   #{count} uncommitted non-doc change(s) across #{files.length} file(s), no fresh structured verify metric.\n" \
  "   Files changed: #{files.map { |f| File.basename(f) }.join(', ')}\n" \
  "   \n" \
  "   Acceptable verification:\n" \
  "   • Run ./scripts/SaneMaster.rb verify so a counted verify metric is recorded\n" \
  "   • The metric must have tests_run > 0, tested evidence, and matching source fingerprint\n" \
  "   (Committed + pushed work — a clean working tree — is already treated as resolved.)"
end

def check_verification_required
  edits = StateManager.get(:edits)

  edit_count = edits[:count] || 0
  unique_files = edits[:unique_files] || []

  # No edits this session = nothing to verify
  return nil if edit_count.zero?

  # A boolean hook flag is not enough. Require a counted verify metric that
  # matches the current source fingerprint and occurred after the latest edit.
  return nil if strong_session_verify_success?

  # Pure-doc sessions never need a verify metric.
  non_doc_edits = unique_files.reject { |f| DOC_ONLY_EXTENSIONS.include?(File.extname(f).downcase) }
  return nil if non_doc_edits.empty?

  # Judge NET state, not the cumulative session counter: of the non-doc files
  # this session edited, which are STILL uncommitted in the working tree? Work
  # that was committed+pushed (or reset to origin) is clean and must not re-fire
  # this gate every turn-end — that infinite loop, satisfiable only by a fresh
  # build, is what trapped the 2.1.81 release session. Unrelated dirty files do
  # not count, so this stays scoped to the session's own edits.
  dirty = uncommitted_working_tree_files
  unless dirty.nil?
    dirty_basenames = dirty.map { |f| File.basename(f) }.to_set
    still_uncommitted = non_doc_edits.select { |f| dirty_basenames.include?(File.basename(f)) }
    return nil if still_uncommitted.empty?

    return verification_block_message(still_uncommitted.length, still_uncommitted)
  end

  # Fallback when git state is unknown (not a repo / git unavailable): keep the
  # original cumulative-counter behavior so coverage is not lost.
  verification_block_message(edit_count, non_doc_edits)
rescue StandardError => e
  warn "⚠️  Verification check error: #{e.message}" if ENV['DEBUG']
  nil  # Don't block on errors in the check itself
end

# === VISUAL VERIFICATION ENFORCEMENT ===
# Customer-facing UI work requires screenshot-backed inspection, not just green
# functional tests.

# Returns the still-real customer-facing UI files that genuinely require a
# visual receipt. A path qualifies only when BOTH hold:
#   1. it still exists on disk, and
#   2. it was edited by THIS session's own Edit/Write/bash-mutation tracking
#      (i.e. it appears in edits[:unique_files] — subagent-internal edits and
#      merely-read/referenced files never land there).
# This drops the phantom-file false positives (e.g. scraped names for files that
# were never edited or no longer exist) without weakening the real gate.
def live_customer_facing_ui_files(visual)
  candidate_paths = visual[:required_files_paths] || []
  return [] if candidate_paths.empty?

  edited_paths = (StateManager.get(:edits)[:unique_files] || [])

  candidate_paths.select do |path|
    next false unless edited_paths.include?(path)

    File.exist?(File.expand_path(path.to_s, Dir.pwd))
  end
rescue StandardError => e
  warn "⚠️  Visual UI file reconciliation error: #{e.message}" if ENV['DEBUG']
  []
end

def check_visual_verification_required
  visual = StateManager.get(:visual_verification)
  return nil unless visual[:required]

  # Only genuine, still-present customer-facing UI edits require a receipt.
  # Drop phantom entries: files that no longer exist on disk (deleted, reverted,
  # renamed, or carried over from a different checkout) and any path that was not
  # actually edited by THIS session's own Edit/Write/bash-mutation tracking.
  real_ui_files = live_customer_facing_ui_files(visual)
  return nil if real_ui_files.empty?

  receipt_paths = SaneVisualReceipt.valid_receipt_paths(
    cwd: Dir.pwd,
    candidate_paths: visual[:audit_files] || [],
    started_at: session_start_time
  )

  return nil if receipt_paths.any?

  files = real_ui_files.map { |path| File.basename(path) }.uniq.first(10)
  reason = visual[:reason] || 'visual verification required'

  "   Visual verification is required (#{reason}).\n" \
  "   Missing: structured Mini visual receipt.\n" \
  "#{files.empty? ? '' : "   UI files/states touched: #{files.join(', ')}\n"}" \
  "   Required proof:\n" \
  "   • Capture clean Mini screenshots for every customer-facing view/state touched.\n" \
  "   • Store a JSON receipt at outputs/customer_ui_action_receipt.json or outputs/visual-audit*/.\n" \
  "   • Receipt must show Mini host, passed status, inspected=true, and existing PNG/JPEG screenshots.\n" \
  "\n" \
  "   THE TOOLS EXIST — this is never \"not possible\". See scripts/mini/SCREENSHOT_TOOLS.md.\n" \
  "   • Website/URL: scripts/mini/capture-web-screenshot.sh <url> <outputs/visual-audit-DIR> --label NAME --app APP\n" \
  "     (Playwright headless on the Mini: no GUI session, no window contamination), then OPEN the\n" \
  "     PNG and set inspected=true in the receipt.\n" \
  "   • App UI window/desktop: scripts/mini/capture-mini-screenshot.sh --app APP --window-name NAME --mode temp --copy-to DIR"
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
    File.readlines(RESET_AUDIT_LOG, encoding: Encoding::UTF_8).each do |line|
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

def transcript_token_summary(transcript_path)
  counts = Hash.new(0)
  return empty_transcript_token_summary if transcript_path.to_s.strip.empty?
  return empty_transcript_token_summary unless File.file?(transcript_path)

  File.foreach(transcript_path, encoding: Encoding::UTF_8) do |line|
    next if line.strip.empty?

    collect_transcript_tokens(JSON.parse(line), counts)
  rescue JSON::ParserError
    next
  end

  total = counts['total_tokens']
  total = TRANSCRIPT_TOKEN_TOTAL_COMPONENTS.sum { |key| counts[key].to_i } if total.to_i.zero?
  {
    transcript_total_tokens: total.to_i,
    transcript_input_tokens: counts['input_tokens'].to_i,
    transcript_output_tokens: counts['output_tokens'].to_i,
    transcript_cached_tokens: counts['cached_tokens'].to_i,
    transcript_cache_read_tokens: counts['cache_read_input_tokens'].to_i,
    transcript_cache_creation_tokens: counts['cache_creation_input_tokens'].to_i,
    transcript_reasoning_tokens: counts['reasoning_tokens'].to_i
  }
rescue StandardError
  empty_transcript_token_summary
end

def empty_transcript_token_summary
  {
    transcript_total_tokens: 0,
    transcript_input_tokens: 0,
    transcript_output_tokens: 0,
    transcript_cached_tokens: 0,
    transcript_cache_read_tokens: 0,
    transcript_cache_creation_tokens: 0,
    transcript_reasoning_tokens: 0
  }
end

def collect_transcript_tokens(value, counts)
  case value
  when Hash
    value.each do |key, child|
      key = key.to_s
      token_value = transcript_token_value(child)
      counts[key] += token_value if token_value && TRANSCRIPT_TOKEN_KEYS.include?(key)
      collect_transcript_tokens(child, counts) if child.is_a?(Hash) || child.is_a?(Array)
    end
  when Array
    value.each { |child| collect_transcript_tokens(child, counts) }
  end
end

def transcript_token_value(value)
  return value if value.is_a?(Integer)
  return value.to_i if value.is_a?(Float)
  return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

  nil
end

def build_session_stats(transcript_path: nil, outcome: 'completed', block_family: nil, block_reason: nil)
  edits = StateManager.get(:edits)
  research = StateManager.get(:research)
  cb = StateManager.get(:circuit_breaker)
  enf = StateManager.get(:enforcement)

  # Calculate violations and SOP score
  violations = count_session_violations
  sop_receipt = build_sop_receipt(violations)
  sop_score = sop_receipt[:sop_score]

  verify_status = session_verify_status
  {
    timestamp: Time.now.iso8601,
    session_id: sop_receipt[:session_id],
    client: sop_receipt[:client],
    outcome: outcome,
    stop_blocked: outcome.to_s == 'blocked',
    block_family: block_family,
    block_reason: block_reason,
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
    final_verify_timestamp: verify_status[:last_timestamp],
    final_verify_source_fingerprint: verify_status[:last_source_fingerprint]
  }.merge(transcript_token_summary(transcript_path))
end

def record_session_accounting(transcript_path: nil, outcome: 'completed', block_family: nil, block_reason: nil, update_validation: true)
  stats = build_session_stats(
    transcript_path: transcript_path,
    outcome: outcome,
    block_family: block_family,
    block_reason: block_reason
  )
  SaneProcessMetrics.record(
    'session_end',
    session_id: stats[:session_id],
    client: stats[:client],
    outcome: stats[:outcome],
    stop_blocked: stats[:stop_blocked],
    block_family: stats[:block_family],
    block_reason: stats[:block_reason],
    success: stats[:final_verify_success],
    sop_score: stats[:sop_score],
    base_score: stats[:base_score],
    block_count: stats[:block_count],
    cap_score: stats[:cap_score],
    cap_reason: stats[:cap_reason],
    edits: stats[:edits],
    unique_files: stats[:unique_files],
    verify_attempts: stats[:verify_attempts],
    verify_failures: stats[:verify_failures],
    verify_zero_test_failures: stats[:verify_zero_test_failures],
    verify_zero_test_successes: stats[:verify_zero_test_successes],
    final_verify_success: stats[:final_verify_success],
    final_verify_tests_run: stats[:final_verify_tests_run],
    final_verify_evidence_strength: stats[:final_verify_evidence_strength],
    final_verify_timestamp: stats[:final_verify_timestamp],
    final_verify_source_fingerprint: stats[:final_verify_source_fingerprint],
    transcript_total_tokens: stats[:transcript_total_tokens],
    transcript_input_tokens: stats[:transcript_input_tokens],
    transcript_output_tokens: stats[:transcript_output_tokens],
    transcript_cached_tokens: stats[:transcript_cached_tokens],
    transcript_cache_read_tokens: stats[:transcript_cache_read_tokens],
    transcript_cache_creation_tokens: stats[:transcript_cache_creation_tokens],
    transcript_reasoning_tokens: stats[:transcript_reasoning_tokens]
  )
  SaneProcessMetrics.record('session_receipt', build_client_neutral_session_receipt(stats))
  record_block_outcomes(stats)

  update_validation_metrics if update_validation
  stats
end

def record_blocked_stop_accounting(transcript_path, block_family, block_reason)
  record_session_accounting(
    transcript_path: transcript_path,
    outcome: 'blocked',
    block_family: block_family,
    block_reason: block_reason,
    update_validation: false
  )
end

def record_block_outcomes(stats)
  rows = stats[:violations].each_with_object({}) do |(rule, count), memo|
    memo[rule.to_s] = count.to_i
  end
  rows[stats[:block_family].to_s] ||= 1 if stats[:stop_blocked] && stats[:block_family]
  rows.each do |rule, count|
    SaneProcessMetrics.record(
      'block_outcome',
      session_id: stats[:session_id],
      outcome: stats[:outcome],
      stop_blocked: stats[:stop_blocked],
      rule_family: rule,
      count: count,
      block_family: stats[:block_family],
      block_reason: stats[:block_reason]
    )
  end
end

def save_session_learnings(transcript_path = nil)
  stats = record_session_accounting(transcript_path: transcript_path, outcome: 'completed')

  # Update patterns for future sessions
  update_session_patterns(stats[:violations], stats[:sop_score])

  # Check score variance (warns if suspiciously consistent)
  check_score_variance(stats[:sop_score])

  # Check weasel words in recent edits
  check_weasel_words

  log_session(stats)
  capture_session_learnings
  stats
end

def build_client_neutral_session_receipt(stats, violations = nil, verify_status = nil)
  violations ||= stats[:violations] || {}
  verify_status ||= {
    attempts: stats[:verify_attempts],
    failures: stats[:verify_failures],
    zero_test_failures: stats[:verify_zero_test_failures],
    zero_test_successes: stats[:verify_zero_test_successes],
    last_success: stats[:final_verify_success],
    last_tests_run: stats[:final_verify_tests_run],
    last_evidence_strength: stats[:final_verify_evidence_strength],
    last_timestamp: stats[:final_verify_timestamp],
    last_source_fingerprint: stats[:final_verify_source_fingerprint]
  }
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
    outcome: stats[:outcome],
    stop_blocked: stats[:stop_blocked],
    block_family: stats[:block_family],
    block_reason: stats[:block_reason],
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
    transcript_total_tokens: stats[:transcript_total_tokens],
    transcript_input_tokens: stats[:transcript_input_tokens],
    transcript_output_tokens: stats[:transcript_output_tokens],
    transcript_cached_tokens: stats[:transcript_cached_tokens],
    transcript_cache_read_tokens: stats[:transcript_cache_read_tokens],
    transcript_cache_creation_tokens: stats[:transcript_cache_creation_tokens],
    transcript_reasoning_tokens: stats[:transcript_reasoning_tokens],
    workflow_receipt_ids: recent_workflow_receipt_ids,
    visual_receipt_paths: current_visual_receipt_paths,
    handoff_updated: handoff_updated_since?(started_at),
    memory_updated: StateManager.get(:handoff_tracking)[:memory_updated] == true,
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
  File.readlines(path, encoding: Encoding::UTF_8).map do |line|
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
  started_at = last_edit_time || session_start_time
  SaneVisualReceipt.valid_receipt_paths(
    cwd: Dir.pwd,
    candidate_paths: visual[:audit_files] || [],
    started_at: started_at
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
# capture_session_learnings / enforce_learnings_cap live in sanestop_learnings.rb
# (extracted per Rule #10). Required at the top of this file.

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

  csv_path = sop_csv_path
  jsonl_path = sop_jsonl_path
  csv_dir = File.dirname(csv_path)
  FileUtils.mkdir_p(csv_dir)

  # Create header if file doesn't exist or is empty
  unless File.exist?(csv_path) && File.size(csv_path) > 0
    File.write(csv_path, "date,sop_score,session_id,client,block_count,cap_reason,verify_attempts,verify_failures,final_verify_success,edits,unique_files,notes_json\n")
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
  File.open(csv_path, 'a') { |f| f.puts(row) }
  File.open(jsonl_path, 'a') { |f| f.puts(JSON.generate(stats)) }
rescue StandardError
  # Don't fail on CSV errors
end

def sop_csv_path
  ENV['SANE_SOP_CSV_PATH'] || ENV['SOP_CSV'] || SOP_CSV
end

def sop_jsonl_path
  ENV['SANE_SOP_JSONL_PATH'] || ENV['SOP_JSONL'] || SOP_JSONL
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
    { 'SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT' => '1' },
    RbConfig.ruby, sane_master, 'mcp_watchdog', 'clean',
    '--quiet', '--max', '4', '--grace', '0',
    out: File::NULL, err: File::NULL
  )
rescue StandardError
  # Never block stop hook on cleanup.
end
