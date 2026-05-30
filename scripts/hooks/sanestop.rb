#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast no-op under Grok (Claude compatibility hooks are merged and can produce
# visible Pre/PostToolUse annotations on every tool even when guarded).
# Grok users rely on AGENTS.md + explicit SaneMaster calls; native hooks are Claude-only.
if ENV["GROK_HOOK_EVENT"].to_s != ""
  exit 0
end

# ==============================================================================
# SaneStop - Stop Hook
# ==============================================================================
# Fires when Claude finishes responding. Validates session and saves learnings.
#
# Exit codes: 0 = allow Claude to stop, 2 = block with reason.
# Checks summary need/format, saves session learnings, and reports stats.
# ==============================================================================
require 'json'
require 'fileutils'
require 'time'
require 'date'
require 'digest'
require 'open3'
require 'rbconfig'
require 'socket'
require_relative 'core/mandatory_workflows'
require_relative 'core/process_metrics'
require_relative 'core/state_manager'
require_relative 'core/sop_score'
require_relative 'core/visual_receipt'
require_relative 'sanestop_finalize'
LOG_FILE = File.expand_path('../../.claude/sanestop.log', __dir__)
SOP_CSV = File.expand_path('../../outputs/sop_ratings.csv', __dir__)
SOP_JSONL = File.expand_path('../../outputs/sop_ratings.jsonl', __dir__)
SESSION_LEARNINGS_FILE = File.expand_path('~/.claude/session_learnings.jsonl')
SESSION_LEARNINGS_ARCHIVE = File.expand_path('~/.claude/session_learnings_archive.jsonl')
SESSION_LEARNINGS_MAX_LINES = 200
MIN_EDITS_FOR_SUMMARY = 3  # Require summary after 3+ edits
MIN_UNIQUE_FILES_FOR_SUMMARY = 2  # Or 2+ unique files edited
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
  build_sop_receipt(violations)[:sop_score]
end

def session_blocks
  enforcement = StateManager.get(:enforcement)
  blocks = enforcement[:blocks] || []
  session_start = session_start_time

  blocks.select do |block|
    begin
      Time.parse(block[:timestamp] || block['timestamp']) >= session_start
    rescue ArgumentError
      false
    end
  end
end

def build_sop_receipt(violations)
  verify_status = session_verify_status
  block_count = session_blocks.length
  score = SaneSOPScore.score(block_count: block_count, verify_status: verify_status)
  {
    session_id: session_id,
    client: session_client,
    sop_score: score[:score],
    base_score: score[:base_score],
    block_count: block_count,
    cap_score: score[:cap_score],
    cap_reason: score[:cap_reason],
    violations: violations,
    verify_attempts: verify_status[:attempts],
    verify_failures: verify_status[:failures],
    verify_zero_test_failures: verify_status[:zero_test_failures],
    verify_zero_test_successes: verify_status[:zero_test_successes],
    final_verify_success: verify_status[:last_success],
    final_verify_tests_run: verify_status[:last_tests_run],
    final_verify_evidence_strength: verify_status[:last_evidence_strength],
    final_verify_timestamp: verify_status[:last_timestamp]
  }
end

def session_verify_events
  path = SaneProcessMetrics.metrics_path
  return [] unless File.exist?(path)

  started = session_start_time
  File.readlines(path).map do |line|
    event = JSON.parse(line)
    next unless event['type'] == 'verify'

    timestamp = Time.parse(event['timestamp'])
    timestamp >= started ? event : nil
  rescue JSON::ParserError, ArgumentError
    nil
  end.compact.sort_by { |event| event['timestamp'].to_s }
rescue StandardError
  []
end

def session_verify_status
  events = session_verify_events
  failures = events.count { |event| event['success'] != true }
  zero_test_failures = events.count { |event| event['success'] != true && event['tests_run'].to_i.zero? }
  zero_test_successes = events.count { |event| event['success'] == true && event.key?('tests_run') && event['tests_run'].to_i.zero? }
  last = events.last
  {
    attempts: events.length,
    failures: failures,
    zero_test_failures: zero_test_failures,
    zero_test_successes: zero_test_successes,
    last_success: last ? last['success'] == true : nil,
    last_tests_run: last && last['tests_run'],
    last_evidence_strength: last && last['evidence_strength'],
    last_timestamp: last && last['timestamp'],
    last_source_fingerprint: last && last['source_fingerprint']
  }
end

def current_source_fingerprint(cwd = Dir.pwd)
  root_out, root_status = Open3.capture2e('git', '-C', cwd, 'rev-parse', '--show-toplevel')
  return 'unknown' unless root_status.success?

  root = root_out.strip
  parts = []
  [
    %w[rev-parse HEAD],
    %w[status --porcelain=v1 --untracked-files=all],
    %w[diff --binary],
    %w[diff --cached --binary]
  ].each do |command|
    out, = Open3.capture2e('git', '-C', root, *command)
    parts << out
  end
  Digest::SHA256.hexdigest(parts.join("\n---\n"))
rescue StandardError
  'unknown'
end

def last_edit_time
  edits = StateManager.get(:edits)
  raw = edits[:last_edit_at] || edits['last_edit_at']
  raw ? Time.parse(raw.to_s) : nil
rescue ArgumentError
  nil
end

def strong_session_verify_success?
  after_edit = last_edit_time
  fingerprint = current_source_fingerprint

  session_verify_events.reverse_each do |event|
    next unless event['success'] == true
    next unless event['tests_run'].to_i.positive?
    next if event['evidence_strength'].to_s == 'build_only'

    timestamp = Time.parse(event['timestamp'].to_s) rescue nil
    next if after_edit && timestamp && timestamp < after_edit

    receipt_fingerprint = event['source_fingerprint'].to_s
    next if receipt_fingerprint.empty? || receipt_fingerprint == 'unknown'
    next if fingerprint == 'unknown'

    return true if receipt_fingerprint == fingerprint
  end

  false
end

def verification_score_cap
  cap = SaneSOPScore.verification_cap(session_verify_status)
  cap && cap[:score]
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

SKILL_REQUIREMENTS = MandatoryWorkflows.skill_requirements.transform_keys(&:to_s).freeze

def runner_block_message(skill_name, skill_state)
  runner_command = MandatoryWorkflows.runner_command_for(skill_name)
  description = SKILL_REQUIREMENTS.dig(skill_name.to_s, :description).to_s

  if skill_name.to_s == 'evolve'
    prompt = skill_state[:required_prompt].to_s.strip
    query = prompt.empty? ? 'describe the missing tool or workaround' : prompt
    escaped_query = query.gsub('"', '\"')
    runner_command = "ruby scripts/SaneMaster.rb tool_discovery --query \"#{escaped_query}\""
  end

  "Runner-backed workflow proof is missing.\n" \
  "   Required workflow: #{skill_name}#{description.empty? ? '' : " (#{description})"}\n" \
  "   Run: #{runner_command}\n" \
  "   Then use that proof before continuing."
end

def check_tool_discovery_required
  skill_state = StateManager.get(:skill)
  required_skill = skill_state[:required].to_s
  requirements = SKILL_REQUIREMENTS[required_skill]
  return nil unless requirements && requirements[:requires_runner]
  return nil if skill_state[:runner_proved] || skill_state[:runner_used]

  runner_block_message(required_skill, skill_state)
rescue StandardError => e
  warn "⚠️  Tool discovery enforcement error: #{e.message}" if ENV['DEBUG']
  nil
end

def validate_skill_execution
  skill_state = StateManager.get(:skill)
  return nil unless skill_state[:required]

  required_skill = skill_state[:required]
  invoked = skill_state[:invoked]
  subagents_spawned = skill_state[:subagents_spawned] || 0
  runner_started = skill_state[:runner_started] || false
  runner_used = skill_state[:runner_proved] || skill_state[:runner_used] || false

  requirements = SKILL_REQUIREMENTS[required_skill] || {}
  min_subagents = requirements[:min_subagents] || 0
  requires_runner = requirements[:requires_runner] || false

  issues = []

  # Check if skill was invoked at all. For runner-backed workflows (status, evolve,
  # verify, ship, check_inbox) the canonical proof is the runner receipt, not the
  # Skill tool — and the startup gate frequently BLOCKS the Skill call itself, so
  # `invoked` stays false even when the workflow ran correctly. A valid runner
  # receipt therefore counts as invocation.
  unless invoked || (requires_runner && runner_used)
    issues << "Skill '#{required_skill}' was required but NOT invoked"
    issues << "  You should have used the Skill tool to invoke it"
  end

  # Check if enough subagents were spawned
  if min_subagents > 0 && subagents_spawned < min_subagents
    issues << "Skill '#{required_skill}' requires #{min_subagents}+ subagents, only #{subagents_spawned} spawned"
    issues << "  You should have used Task tool to spawn subagents for heavy work"
  end

  if requires_runner && !runner_used
    if runner_started
      issues << "Skill '#{required_skill}' runner command was attempted but no successful proof/receipt was recorded"
    else
      issues << "Skill '#{required_skill}' requires the approved runner/proof command and none was detected"
    end
    issues << "  Run #{MandatoryWorkflows.runner_command_for(required_skill)}" if MandatoryWorkflows.runner_command_for(required_skill)
  end

  if required_skill == 'docs_audit' && runner_used && subagents_spawned < min_subagents
    issues << "Skill '#{required_skill}' no longer accepts runner-only execution"
    issues << "  Spawn GPT subagents for the audit swarm instead of using gpt_audit.py"
  end

  issues.concat(validate_sane_audit_artifact) if required_skill == 'sane_audit'

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

def validate_sane_audit_artifact
  required_files = %w[
    q0-config.md
    q6-release.md
    q7-website.md
    q8-signing.md
    q9-support.md
    q10-docs.md
    q11-tooling.md
    q12-runtime-resources.md
    q13-historical-regression.md
  ]
  output_dir = '/tmp/sane_audit_outputs'
  summary_path = '/tmp/sane_audit_outputs/summary.md'
  issues = []

  missing_files = required_files.reject { |file| File.exist?(File.join(output_dir, file)) }
  if missing_files.any?
    issues << "Skill 'sane_audit' is missing required perspective reports: #{missing_files.join(', ')}"
  end

  present_files = required_files - missing_files
  incomplete_reports = present_files.select do |file|
    report_content = File.read(File.join(output_dir, file))
    !sane_audit_report_content_complete?(report_content)
  rescue StandardError
    true
  end
  if incomplete_reports.any?
    issues << "Skill 'sane_audit' reports are missing required audit sections: #{incomplete_reports.join(', ')}"
  end

  unless File.exist?(summary_path)
    issues << "Skill 'sane_audit' requires consolidated summary artifact: #{summary_path}"
    return issues
  end

  content = File.read(summary_path)
  required_sections = [
    'Per-Perspective Scores',
    'Root-Cause Matrix',
    'Current Coverage',
    'Would Catch Today?',
    'Checked Evidence'
  ]
  missing = required_sections.reject { |section| content.include?(section) }
  issues << "Skill 'sane_audit' summary is missing required proof sections: #{missing.join(', ')}" if missing.any?

  missing_mentions = required_files.reject { |file| content.include?(file) }
  if missing_mentions.any?
    issues << "Skill 'sane_audit' summary does not mention all perspective reports: #{missing_mentions.join(', ')}"
  end

  issues
rescue StandardError => e
  ["Skill 'sane_audit' summary could not be validated: #{e.message}"]
end

def sane_audit_report_content_complete?(content)
  required_terms = ['Score', 'Critical', 'Warning', 'Passed', 'Checked Evidence']
  required_terms.all? { |term| content.include?(term) } && content.lines.length >= 20
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
    required_skill = StateManager.get(:skill)[:required]
    warn ''
    warn '=' * 50
    blocking_skill = %w[docs_audit sane_audit].include?(required_skill)
    warn blocking_skill ? '🔴 SKILL EXECUTION BLOCK' : 'SKILL EXECUTION WARNING'
    warn ''
    skill_issues.each { |issue| warn "  #{issue}" }
    warn ''
    if blocking_skill
      warn "This is blocking because #{required_skill} is required for this session."
      warn 'Re-run the audit with the required GPT subagent swarm and summary artifact, then try again.'
      warn '=' * 50
      warn ''
      return 2
    end
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

  # === HANDOFF ENFORCEMENT: Significant edits require handoff + memory update ===
  tool_discovery_block = check_tool_discovery_required
  if tool_discovery_block
    warn ''
    warn '=' * 50
    warn '🔴 TOOL DISCOVERY BLOCK'
    warn ''
    warn tool_discovery_block
    warn ''
    warn '   No workaround claim without a receipt.'
    warn '=' * 50
    warn ''
    return 2
  end

  # === HANDOFF ENFORCEMENT: Significant edits require handoff + memory update ===
  handoff_block = check_handoff_required
  if handoff_block
    warn ''
    warn '=' * 50
    warn '🔴 HANDOFF BLOCK: Changes made without updating handoff/memory'
    warn ''
    warn handoff_block
    warn ''
    warn '   Every significant change must be recorded before session ends.'
    warn '   Update SESSION_HANDOFF.md and/or memory, then try again.'
    warn '=' * 50
    warn ''
    return 2  # BLOCK — Claude must address this
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

  # === VISUAL VERIFICATION ENFORCEMENT: UI work requires screenshot audit ===
  visual_block = check_visual_verification_required
  if visual_block
    warn ''
    warn '=' * 50
    warn '🔴 VISUAL VERIFICATION BLOCK: Screenshots/audit missing'
    warn ''
    warn visual_block
    warn ''
    warn '   Do not claim customer-facing UI work is done from functional tests alone.'
    warn '=' * 50
    warn ''
    return 2
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

  # Best-effort daemon cleanup at session end.
  run_mcp_watchdog_cleanup

  0  # Allow stop
end

# === MAIN ===

if ARGV.include?('--self-test')
  require_relative 'self_test_environment'
  exit SelfTestEnvironment.run_isolated(__FILE__)
elsif ARGV.include?('--self-test-internal')
  run_internal_self_test = lambda do
    require_relative 'sanestop_test'
    SaneStopTest.run(
      method(:process_stop),
      method(:check_score_variance),
      method(:check_weasel_words),
      method(:calculate_sop_score),
      LOG_FILE
    )
  end

  require 'tmpdir'
  Dir.mktmpdir('sanestop-self-test-metrics-') do |dir|
    ENV['SANEMASTER_PROCESS_METRICS_PATH'] = File.join(dir, 'process_metrics.jsonl')
    exit run_internal_self_test.call
  end
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
