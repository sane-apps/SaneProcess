#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneStop - Stop Hook
# ==============================================================================
# Fires when Claude finishes responding. Validates session and saves learnings.
#
# Exit codes:
#   0 = allow Claude to stop
#   2 = block with reason (Claude must address it)
#
# What this does:
#   1. Checks if session summary is needed (significant edits made)
#   2. Validates summary format if present
#   3. Saves session learnings
#   4. Reports to user
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'core/state_manager'

LOG_FILE = File.expand_path('../../.claude/sanestop.log', __dir__)
SOP_CSV = File.expand_path('../../outputs/sop_ratings.csv', __dir__)
SESSION_LEARNINGS_FILE = File.expand_path('~/.claude/session_learnings.jsonl')
SESSION_LEARNINGS_ARCHIVE = File.expand_path('~/.claude/session_learnings_archive.jsonl')
SESSION_LEARNINGS_MAX_LINES = 200

# === CONFIGURATION ===

MIN_EDITS_FOR_SUMMARY = 3  # Require summary after 3+ edits
MIN_UNIQUE_FILES_FOR_SUMMARY = 2  # Or 2+ unique files edited

# === SOP SCORE CALCULATION ===

def session_start_time
  enforcement = StateManager.get(:enforcement)
  started_at = enforcement[:session_started_at] || enforcement['session_started_at']
  started_at ? Time.parse(started_at) : (Time.now - 3600)
rescue ArgumentError
  Time.now - 3600  # Fallback if timestamp is unparseable
end

def count_session_violations
  enforcement = StateManager.get(:enforcement)
  blocks = enforcement[:blocks] || []
  return {} if blocks.empty?

  session_start = session_start_time
  violations = Hash.new(0)

  blocks.each do |block|
    begin
      block_time = Time.parse(block[:timestamp] || block['timestamp'])
      next if block_time < session_start
    rescue ArgumentError
      next
    end

    rule = block[:rule] || block['rule'] || 'unknown'
    violations[rule] += 1
  end

  violations
end

def calculate_sop_score(violations)
  # Q3 redesign: Measure blocks-before-compliance (friction), not violations.
  # Hooks prevent violations (so violations ~= 0 always = rubber-stamp 10/10).
  # Instead: more blocks in session = AI needed more pushback = lower score.
  enforcement = StateManager.get(:enforcement)
  blocks = enforcement[:blocks] || []
  session_start = session_start_time

  session_block_count = blocks.count do |b|
    begin
      Time.parse(b[:timestamp] || b['timestamp']) >= session_start
    rescue ArgumentError
      false
    end
  end

  case session_block_count
  when 0 then 10      # Perfect — no blocks needed
  when 1..2 then 9    # Minor friction
  when 3..4 then 8    # Moderate friction
  when 5..7 then 7    # Significant friction
  when 8..10 then 6   # Heavy friction
  else 5              # Excessive friction — process fought the AI hard
  end
end

# === SOP SCORE VARIANCE DETECTION ===
# Suspicious consistency: if scores are always 8+ with low variance,
# the self-rating is probably inflated

def check_score_variance(sop_score)
  patterns = StateManager.get(:patterns)
  # NOTE: current score already added by update_session_patterns() before this call
  scores = patterns[:session_scores] || []

  return nil if scores.length < 5

  mean = scores.sum.to_f / scores.length
  variance = scores.map { |s| (s - mean)**2 }.sum / scores.length
  stdev = Math.sqrt(variance)

  if stdev < 0.8 && mean >= 8.0
    # Log suspicion
    StateManager.update(:patterns) do |p|
      p[:weak_spots] ||= {}
      p[:weak_spots]['score_gaming'] = (p[:weak_spots]['score_gaming'] || 0) + 1
      p
    end

    warn ''
    warn "SCORE VARIANCE WARNING: stdev=#{stdev.round(2)} over #{scores.length} sessions"
    warn "  Mean: #{mean.round(1)}/10, scores: #{scores.last(5).inspect}"
    warn "  Consistent 8+/10 is statistically unlikely."
    warn "  Consider: did you actually follow the full process?"
    warn ''
  end
rescue StandardError
  # Don't fail on variance check
end

# === WEASEL WORD DETECTION ===
# Detect vague language in session summaries that masks actual work

WEASEL_PATTERNS = [
  /\bused tools?\b/i,
  /\bfollowed (?:the )?process\b/i,
  /\bdid it right\b/i,
  /\bvarious\b/i,
  /\betc\.?\b/i,
  /\bseveral\b(?!.*\d)/i,          # "several" without a number
  /\bsome (?:changes|updates|fixes)\b/i,
  /\bmade (?:changes|updates|improvements)\b/i,
  /\bworked on\b/i,
  /\bcleaned up\b(?!.*\bfile|\bfunction|\bclass)/i  # "cleaned up" without specifics
].freeze

# Opposite: specific language that shows real work
SPECIFIC_PATTERNS = [
  /\b\w+\.(swift|rb|py|ts|js|md)\b/,  # File names
  /line \d+/i,                         # Line references
  /\b(function|method|class|struct|module)\s+\w+/i,  # Named elements
  /\b\d+\s+(test|file|line|edit|commit)/i  # Quantified work
].freeze

def check_weasel_words
  action_log = StateManager.get(:action_log) || []
  return if action_log.length < 3

  # Check recent actions for edit content that looks like session summary
  recent_edits = action_log.last(10).select { |a| (a[:tool] || a['tool']) == 'Edit' }
  return if recent_edits.empty?

  # Check the last few edit summaries for weasel words
  weasels_found = []
  recent_edits.each do |edit|
    summary = edit[:input_summary] || edit['input_summary'] || ''
    WEASEL_PATTERNS.each do |pattern|
      weasels_found << pattern.source if summary.match?(pattern)
    end
  end

  return if weasels_found.empty?

  specifics = recent_edits.count do |edit|
    summary = edit[:input_summary] || edit['input_summary'] || ''
    SPECIFIC_PATTERNS.any? { |p| summary.match?(p) }
  end

  if specifics < recent_edits.length / 2
    warn ''
    warn 'WEASEL WORD WARNING: Session summary uses vague language'
    warn "  Found: #{weasels_found.uniq.first(3).join(', ')}"
    warn '  Prefer: specific file names, line numbers, function names'
    warn ''
  end
rescue StandardError
  # Don't fail on weasel detection
end

# === PATTERN UPDATES ===

def update_session_patterns(violations, sop_score)
  StateManager.update(:patterns) do |patterns|
    patterns ||= { weak_spots: {}, triggers: {}, strengths: [], session_scores: [] }

    # Update weak spots (rules violated this session)
    violations.each do |rule, count|
      rule_key = rule.to_s
      patterns[:weak_spots] ||= {}
      patterns[:weak_spots][rule_key] = (patterns[:weak_spots][rule_key] || 0) + count
    end

    # Track session score for trend analysis
    patterns[:session_scores] ||= []
    patterns[:session_scores] << sop_score
    patterns[:session_scores] = patterns[:session_scores].last(10)  # Keep last 10

    patterns
  end
rescue StandardError
  # Don't fail on state errors
end

# === TODO ENFORCEMENT (inspired by jarrodwatts/claude-code-config) ===
# Warns when session ends with incomplete todos

TRANSCRIPT_CACHE = {}  # Cache transcript reads

def check_incomplete_todos(transcript_path)
  return nil unless transcript_path && File.exist?(transcript_path)

  begin
    # Parse transcript to find last TodoWrite call
    # Use cached if available and file unchanged
    mtime = File.mtime(transcript_path)
    if TRANSCRIPT_CACHE[:path] == transcript_path && TRANSCRIPT_CACHE[:mtime] == mtime
      todos = TRANSCRIPT_CACHE[:todos]
    else
      content = File.read(transcript_path)
      # Find all TodoWrite tool uses and get the last one
      todos_json = content.scan(/\{"type":\s*"tool_use".*?"name":\s*"TodoWrite".*?"input":\s*(\{[^}]+\})/m).flatten.last

      if todos_json
        input = JSON.parse(todos_json)
        todos = input['todos'] || []
      else
        todos = []
      end

      # Cache for future calls
      TRANSCRIPT_CACHE[:path] = transcript_path
      TRANSCRIPT_CACHE[:mtime] = mtime
      TRANSCRIPT_CACHE[:todos] = todos
    end

    return nil if todos.empty?

    # Count incomplete
    pending = todos.count { |t| t['status'] == 'pending' }
    in_progress = todos.count { |t| t['status'] == 'in_progress' }
    incomplete = pending + in_progress

    return nil if incomplete.zero?

    # Build warning
    {
      pending: pending,
      in_progress: in_progress,
      total: incomplete,
      items: todos.select { |t| %w[pending in_progress].include?(t['status']) }
    }
  rescue StandardError => e
    warn "⚠️  Todo check error: #{e.message}" if ENV['DEBUG']
    nil
  end
end

# === SKILL VALIDATION ===
# Check if required skill was properly executed

SKILL_REQUIREMENTS = {
  'docs_audit' => { min_subagents: 3, description: 'Multi-perspective documentation audit' },
  'evolve' => { min_subagents: 0, description: 'Technology scouting' },
  'outreach' => { min_subagents: 0, description: 'GitHub competitor monitoring' }
}.freeze

def validate_skill_execution
  skill_state = StateManager.get(:skill)
  return nil unless skill_state[:required]

  required_skill = skill_state[:required]
  invoked = skill_state[:invoked]
  subagents_spawned = skill_state[:subagents_spawned] || 0

  requirements = SKILL_REQUIREMENTS[required_skill] || {}
  min_subagents = requirements[:min_subagents] || 0

  issues = []

  # Check if skill was invoked at all
  unless invoked
    issues << "Skill '#{required_skill}' was required but NOT invoked"
    issues << "  You should have used the Skill tool to invoke it"
  end

  # Check if enough subagents were spawned
  if min_subagents > 0 && subagents_spawned < min_subagents
    issues << "Skill '#{required_skill}' requires #{min_subagents}+ subagents, only #{subagents_spawned} spawned"
    issues << "  You should have used Task tool to spawn subagents for heavy work"
  end

  return nil if issues.empty?

  # Update skill state with validation result
  StateManager.update(:skill) do |s|
    s[:satisfied] = false
    s[:satisfaction_reason] = issues.join('; ')
    s
  end

  # Return warning (not blocking - just informational)
  issues
rescue StandardError => e
  warn "⚠️  Skill validation error: #{e.message}" if ENV['DEBUG']
  nil
end

# === RULE #4 ENFORCEMENT ===
# Block session end if edits were made but no tests/verification ran.
# This closes the gap where config changes, code changes, etc. go untested.

# Files that don't require test verification (docs, config that's read-only, etc.)
DOC_ONLY_EXTENSIONS = %w[.md .txt .mdx .rst .adoc].freeze

def check_verification_required
  edits = StateManager.get(:edits)
  verification = StateManager.get(:verification)

  edit_count = edits[:count] || 0
  unique_files = edits[:unique_files] || []

  # No edits = nothing to verify
  return nil if edit_count.zero?

  # If tests were run, we're good
  return nil if verification[:tests_run] || verification[:verification_run]

  # Check if ALL edits were doc-only (markdown, txt) — don't require tests for pure docs
  non_doc_edits = unique_files.reject { |f| DOC_ONLY_EXTENSIONS.include?(File.extname(f).downcase) }
  return nil if non_doc_edits.empty?

  # Edits to non-doc files with no verification = BLOCK
  "   #{edit_count} edit(s) across #{non_doc_edits.length} file(s), 0 test/verification commands.\n" \
  "   Files changed: #{non_doc_edits.map { |f| File.basename(f) }.join(', ')}\n" \
  "   \n" \
  "   Acceptable verification:\n" \
  "   • Run project tests (xcodebuild test, swift test, ruby test, etc.)\n" \
  "   • Run validation (ruby scripts/validation_report.rb, --self-test)\n" \
  "   • Health check (curl localhost:PORT/health)\n" \
  "   • Any command that proves the change works"
rescue StandardError => e
  warn "⚠️  Verification check error: #{e.message}" if ENV['DEBUG']
  nil  # Don't block on errors in the check itself
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
  verification = StateManager.get(:verification)
  cb = StateManager.get(:circuit_breaker)
  block_stats = count_session_blocks_and_resets
  missed_loops = count_missed_doom_loops

  StateManager.update(:validation) do |v|
    # Q4: Session tracking
    v[:sessions_total] = (v[:sessions_total] || 0) + 1
    if verification[:tests_run] || verification[:verification_run]
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
  sop_score = calculate_sop_score(violations)

  # Calculate session stats
  stats = {
    timestamp: Time.now.iso8601,
    edits: edits[:count] || 0,
    unique_files: edits[:unique_files]&.length || 0,
    research_done: research.compact.keys.length,
    failures: cb[:failures] || 0,
    blocks: enf[:blocks]&.length || 0,
    halted: enf[:halted] || false,
    violations: violations,
    sop_score: sop_score
  }

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
  append_sop_csv(stats[:sop_score], stats[:violations])
rescue StandardError
  # Don't fail on logging errors
end

def append_sop_csv(score, violations)
  return unless score

  csv_dir = File.dirname(SOP_CSV)
  FileUtils.mkdir_p(csv_dir)

  # Create header if file doesn't exist or is empty
  unless File.exist?(SOP_CSV) && File.size(SOP_CSV) > 0
    File.write(SOP_CSV, "date,sop_score,notes\n")
  end

  violation_count = violations.is_a?(Hash) ? violations.values.sum : violations.to_i
  notes = violation_count > 0 ? "#{violation_count} violations" : 'clean session'
  File.open(SOP_CSV, 'a') { |f| f.puts("#{Date.today},#{score},#{notes}") }
rescue StandardError
  # Don't fail on CSV errors
end

# === MAIN PROCESSING ===

def process_stop(stop_hook_active, transcript_path = nil)
  # Don't loop if already in a stop hook
  return 0 if stop_hook_active

  # Context compact warning now lives in PostToolUse (sanetrack.rb via core/context_compact.rb)
  # so it fires DURING the session, not just at session end.

  # === SKILL VALIDATION (warn if skill was required but not properly executed) ===
  skill_issues = validate_skill_execution
  if skill_issues&.any?
    warn ''
    warn '=' * 50
    warn 'SKILL EXECUTION WARNING'
    warn ''
    skill_issues.each { |issue| warn "  #{issue}" }
    warn ''
    warn 'This is logged but NOT blocking.'
    warn 'Consider re-running with proper skill invocation.'
    warn '=' * 50
    warn ''
  end

  # Check for incomplete todos (non-blocking warning)
  incomplete_todos = check_incomplete_todos(transcript_path)
  if incomplete_todos
    warn '---'
    warn 'INCOMPLETE TODOS DETECTED'
    warn ''
    warn "  #{incomplete_todos[:total]} incomplete task(s):"
    incomplete_todos[:items].each do |todo|
      status_icon = todo['status'] == 'in_progress' ? '→' : '○'
      warn "  #{status_icon} [#{todo['status']}] #{todo['content']}"
    end
    warn ''
    warn '  Consider completing these tasks or marking done.'
    warn '---'
  end

  # === RULE #4 ENFORCEMENT: Edits require verification ===
  verification_block = check_verification_required
  if verification_block
    warn ''
    warn '=' * 50
    warn '🔴 RULE #4 BLOCK: EDITS WITHOUT VERIFICATION'
    warn ''
    warn verification_block
    warn ''
    warn '   You made changes but never ran tests or verified.'
    warn '   Run tests, a health check, or verification before finishing.'
    warn '=' * 50
    warn ''
    return 2  # BLOCK — Claude must address this
  end

  # Check if summary needed (non-blocking reminder)
  check_summary_needed

  # Save learnings
  stats = save_session_learnings

  # Report to user
  if stats[:edits] > 0 || stats[:violations].any?
    warn '---'
    warn 'Session Stats'
    warn "  Edits: #{stats[:edits]} (#{stats[:unique_files]} unique files)"
    warn "  Research: #{stats[:research_done]}/4 categories"
    warn "  Failures: #{stats[:failures]}"
    warn "  Blocks: #{stats[:blocks]}"

    # Show SOP score and violations
    warn ''
    warn "  Auto SOP Score: #{stats[:sop_score]}/10"
    if stats[:violations].any?
      warn '  Violations this session:'
      stats[:violations].each do |rule, count|
        warn "    #{rule}: #{count}x"
      end
    else
      warn '  No rule violations detected'
    end

    # Show patterns learned
    patterns = StateManager.get(:patterns)
    if patterns && patterns[:weak_spots]&.any?
      weak = patterns[:weak_spots].sort_by { |_k, v| -v.to_i }.first(3)
      if weak.any?
        warn ''
        warn '  Cumulative weak spots (across sessions):'
        weak.each { |rule, count| warn "    #{rule}: #{count} total violations" }
      end
    end

    # Show score trend
    scores = patterns&.dig(:session_scores) || []
    if scores.length >= 3
      recent_avg = scores.last(3).sum.to_f / 3
      warn ''
      warn "  Score trend: #{recent_avg.round(1)} avg (last 3 sessions)"
    end

    warn '---'
  end

  0  # Allow stop
end

# === MAIN ===

if ARGV.include?('--self-test')
  require_relative 'sanestop_test'
  exit SaneStopTest.run(
    method(:process_stop),
    method(:check_score_variance),
    method(:check_weasel_words),
    LOG_FILE
  )
else
  begin
    input = JSON.parse($stdin.read)
    stop_hook_active = input['stop_hook_active'] || false
    transcript_path = input['transcript_path']  # Path to session transcript
    exit process_stop(stop_hook_active, transcript_path)
  rescue JSON::ParserError, Errno::ENOENT
    exit 0  # Don't fail on parse errors
  end
end
