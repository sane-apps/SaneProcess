#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Prompt Analyzer Hook (UserPromptSubmit)
# ==============================================================================
# Analyzes user prompts to:
# 1. Detect trigger words that require specific actions
# 2. Track user patterns and corrections for learning
# 3. Detect frustration signals (indicates Claude missed something)
#
# Hook Type: UserPromptSubmit
# Runs: When user submits a prompt, before Claude processes it
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'rule_tracker'
require_relative 'state_signer'

REQUIREMENTS_FILE = '.claude/prompt_requirements.json'
PATTERNS_FILE = '.claude/user_patterns.json'
PROMPT_LOG_FILE = '.claude/prompt_log.jsonl'
BYPASS_FILE = '.claude/bypass_active.json'

# ═══════════════════════════════════════════════════════════════════════════════
# TRIGGER DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

TRIGGERS = {
  saneloop: {
    patterns: [/\bsaneloop\b/i, /\bsane.?loop\b/i, /\bdo a.*loop\b/i],
    action: 'Start SaneLoop with acceptance criteria',
    satisfaction: 'saneloop_started'
  },
  research: {
    patterns: [/\bresearch this\b/i, /\bresearch first\b/i, /\bdo research\b/i],
    action: 'Use research protocol: mcp__memory__read_graph FIRST, then docs/web',
    satisfaction: 'research_done'
  },
  bypass: {
    patterns: [
      /\bbypass\s+on\b/i,
      /\bbypass\s+off\b/i,
      /\benable\s+bypass\b/i,
      /\bturn\s+off\s+enforcement\b/i
    ],
    action: 'USER OVERRIDE - Toggle enforcement (user-only keyword)',
    satisfaction: 'bypassed',
    clears_all: true
  },
  plan: {
    patterns: [/\bmake a plan\b/i, /\bplan this\b/i, /\bplan first\b/i, /\bcreate a plan\b/i],
    action: 'Show plan in plain english for approval (not just reference a file)',
    satisfaction: 'plan_shown'
  },
  explain: {
    patterns: [/\bexplain\b/i, /\bwhat does.*mean\b/i, /\bwhy\b.*\?/i],
    action: 'Use plain english, define technical terms',
    satisfaction: 'explanation_given'
  },
  commit: {
    patterns: [/\bcommit\b/i, /\bpush\b/i, /\bgit commit\b/i],
    action: 'Pull first, status, diff, add, commit, update README',
    satisfaction: 'commit_done'
  },
  bug_note: {
    patterns: [/\bmake note.*bug\b/i, /\bnote this bug\b/i, /\blog.*bug\b/i, /\bcheck bug\b/i],
    action: 'Update bug logs + memory + check for patterns',
    satisfaction: 'bug_logged'
  },
  test_mode: {
    patterns: [/\btest mode\b/i],
    action: 'Kill → Build → Launch → Stream logs',
    satisfaction: 'test_cycle_done'
  },
  verify: {
    patterns: [/\bverify everything\b/i, /\bmake sure everything\b/i, /\bcheck everything\b/i],
    action: 'Full verification with checklist',
    satisfaction: 'verification_done'
  },
  show: {
    patterns: [/\bshow me\b/i, /\blet me see\b/i, /\bdisplay\b/i],
    action: 'Display content directly, do not just describe it',
    satisfaction: 'content_shown'
  },
  remember: {
    patterns: [/\bremember\b/i, /\bsave this\b/i, /\bstore this\b/i, /\bdon'?t forget\b/i],
    action: 'Store in memory MCP',
    satisfaction: 'memory_stored'
  },
  stop: {
    patterns: [/\bstop\b/i, /\bwait\b/i, /\bhold on\b/i, /\bhang on\b/i],
    action: 'Interrupt current action immediately',
    satisfaction: 'stopped',
    immediate: true
  },
  session_end: {
    patterns: [/\bwrap up\b/i, /\bend session\b/i, /\bwrap up session\b/i, /\bclose.*session\b/i, /\bfinish up\b/i],
    action: 'Run compliance report → proper summary (SOP Compliance + Performance) → session_end',
    satisfaction: 'session_ended'
  },
  skip_research: {
    patterns: [
      /\bskip\s+(memory|docs|web|local|github)\b/i,
      /\bapprove\s+skip\s+(memory|docs|web|local|github)\b/i,
      /\b(memory|docs|web|local|github)\s+not\s+(needed|applicable|relevant)\b/i
    ],
    action: 'User approves skipping a research category',
    satisfaction: 'skip_approved',
    is_skip: true
  },
  reset_breaker: {
    patterns: [
      /\breset\s+breaker\b/i,
      /\bapprove\s+breaker\s+reset\b/i,
      /\bclear\s+breaker\b/i,
      /\breset\s+circuit\s*breaker\b/i
    ],
    action: 'User approves resetting the circuit breaker (VULN-007)',
    satisfaction: 'breaker_reset',
    is_breaker_reset: true
  }
}.freeze

# Research categories that can be skipped (with user approval only)
RESEARCH_CATEGORIES_MAP = {
  'memory' => :memory,
  'docs' => :docs,
  'web' => :web,
  'local' => :local,
  'github' => :github
}.freeze

# ═══════════════════════════════════════════════════════════════════════════════
# MODIFIER PATTERNS (change how triggers are interpreted)
# ═══════════════════════════════════════════════════════════════════════════════

MODIFIERS = {
  first: {
    patterns: [/first\b/i, /\bbefore anything\b/i, /\bbefore you\b/i],
    meaning: 'Do this BEFORE any other action'
  },
  just: {
    patterns: [/\bjust\b/i, /\bonly\b/i, /\bminimal\b/i],
    meaning: 'Minimal scope - do not over-engineer'
  },
  quick: {
    patterns: [/\bquick\b/i, /\bquickly\b/i, /\bfast\b/i],
    meaning: 'Speed matters but do not skip verification'
  },
  everything: {
    patterns: [/\beverything\b/i, /\babsolutely\b/i, /\ball\b/i, /\bcomprehensive\b/i],
    meaning: 'Leave no stone unturned'
  },
  careful: {
    patterns: [/\bcareful\b/i, /\bcarefully\b/i, /\bthoroughly\b/i],
    meaning: 'Extra attention required'
  },
  again: {
    patterns: [/\bagain\b/i, /\btry again\b/i, /\bone more time\b/i],
    meaning: 'Previous attempt failed - use DIFFERENT approach (Rule #3)'
  }
}.freeze

# ═══════════════════════════════════════════════════════════════════════════════
# FRUSTRATION SIGNALS (Claude missed something)
# ═══════════════════════════════════════════════════════════════════════════════

FRUSTRATION_SIGNALS = {
  correction: {
    patterns: [/^no[,.]?\s/i, /\bthat'?s not\b/i, /\bi said\b/i, /\bi already\b/i, /\bi meant\b/i],
    meaning: 'Claude misunderstood - log for learning'
  },
  impatience: {
    patterns: [/\bidiot\b/i, /\buse your head\b/i, /\bthink\b/i, /\bstop rushing\b/i],
    meaning: 'Claude being careless - slow down'
  },
  skepticism: {
    patterns: [/\.\.\.$/, /\breally\?\b/i, /\bare you sure\b/i, /\bhmm\b/i],
    meaning: 'User doubts response - verify before continuing'
  },
  repetition: {
    patterns: [/\bi just said\b/i, /\blike i said\b/i, /\bas i mentioned\b/i],
    meaning: 'Claude ignored previous instruction - check history'
  }
}.freeze

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

def load_requirements
  return { requested: [], satisfied: [], modifiers: [], timestamp: nil } unless File.exist?(REQUIREMENTS_FILE)

  JSON.parse(File.read(REQUIREMENTS_FILE), symbolize_names: true)
rescue StandardError
  { requested: [], satisfied: [], modifiers: [], timestamp: nil }
end

def save_requirements(reqs)
  FileUtils.mkdir_p(File.dirname(REQUIREMENTS_FILE))
  File.write(REQUIREMENTS_FILE, JSON.pretty_generate(reqs))
end

def load_patterns
  return { learned: [], corrections: 0, last_updated: nil } unless File.exist?(PATTERNS_FILE)

  JSON.parse(File.read(PATTERNS_FILE), symbolize_names: true)
rescue StandardError
  { learned: [], corrections: 0, last_updated: nil }
end

def save_patterns(patterns)
  FileUtils.mkdir_p(File.dirname(PATTERNS_FILE))
  File.write(PATTERNS_FILE, JSON.pretty_generate(patterns))
end

def log_prompt(prompt, detected_triggers, detected_modifiers, frustration)
  FileUtils.mkdir_p(File.dirname(PROMPT_LOG_FILE))
  entry = {
    timestamp: Time.now.iso8601,
    prompt: prompt[0..500], # Truncate long prompts
    triggers: detected_triggers,
    modifiers: detected_modifiers,
    frustration: frustration
  }
  File.open(PROMPT_LOG_FILE, 'a') { |f| f.puts entry.to_json }
end

def detect_patterns(text, pattern_hash)
  detected = []
  pattern_hash.each do |name, config|
    config[:patterns].each do |pattern|
      if text.match?(pattern)
        detected << { name: name, action: config[:action], meaning: config[:meaning] }.compact
        break
      end
    end
  end
  detected
end

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

prompt = input['prompt'] || ''
exit 0 if prompt.empty?

# Detect triggers, modifiers, and frustration
detected_triggers = detect_patterns(prompt, TRIGGERS)
detected_modifiers = detect_patterns(prompt, MODIFIERS)
detected_frustration = detect_patterns(prompt, FRUSTRATION_SIGNALS)

# Log the prompt for pattern learning
log_prompt(prompt, detected_triggers.map { |t| t[:name] }, detected_modifiers.map { |m| m[:name] }, detected_frustration.map { |f| f[:name] })

# Update requirements
reqs = load_requirements

# HIGH-PRIORITY triggers that reset the enforcement context (new task)
# These indicate user wants a fresh workflow, not a continuation
FRESH_START_TRIGGERS = %w[saneloop test_mode commit].freeze

# ADDITIVE triggers that layer onto existing requirements
# These don't reset - they add to what's already required
ADDITIVE_TRIGGERS = %w[explain show remember research plan verify bug_note].freeze

if detected_triggers.any?
  trigger_names = detected_triggers.map { |t| t[:name].to_s }

  # USER-ONLY BYPASS ON/OFF
  if trigger_names.include?('bypass')
    if prompt.match?(/\bbypass\s+off\b/i)
      # Turn enforcement back ON
      FileUtils.rm_f(BYPASS_FILE)
      warn ''
      warn '🔒 BYPASS OFF: Enforcement re-enabled'
      warn ''
      exit 0
    else
      # Turn enforcement OFF (persistent)
      FileUtils.mkdir_p(File.dirname(BYPASS_FILE))
      File.write(BYPASS_FILE, { activated_at: Time.now.iso8601 }.to_json)
      FileUtils.rm_f(REQUIREMENTS_FILE)
      warn ''
      warn '🔓 BYPASS ON: Enforcement disabled. Say "bypass off" to re-enable.'
      warn ''
      exit 0
    end
  end

  # SKIP RESEARCH CATEGORY (user approval required)
  # RULE: Can only skip categories that were ATTEMPTED first
  if trigger_names.include?('skip_research')
    # Extract which category to skip
    skip_match = prompt.match(/\b(skip|approve\s+skip)\s+(memory|docs|web|local|github)\b/i) ||
                 prompt.match(/\b(memory|docs|web|local|github)\s+not\s+(needed|applicable|relevant)\b/i)

    if skip_match
      category_name = skip_match.captures.find { |c| RESEARCH_CATEGORIES_MAP.key?(c&.downcase) }
      category_name = category_name&.downcase

      if category_name && RESEARCH_CATEGORIES_MAP[category_name]
        category_sym = RESEARCH_CATEGORIES_MAP[category_name]

        # CHECK: Was this category actually attempted?
        findings_file = '.claude/research_findings.jsonl'
        was_attempted = false
        attempt_proof = nil

        if File.exist?(findings_file)
          File.readlines(findings_file).each do |line|
            finding = JSON.parse(line, symbolize_names: true) rescue next
            if finding[:category].to_sym == category_sym
              was_attempted = true
              attempt_proof = "#{finding[:tool]}: #{finding[:output_stats]}"
              break
            end
          end
        end

        unless was_attempted
          warn ''
          warn "🛑 SKIP REJECTED: #{category_name} was never attempted"
          warn '   Rule: You must TRY a research category before asking to skip it.'
          warn '   Claude cannot skip something it never looked at.'
          warn ''
          exit 0
        end

        # Category was attempted - allow skip
        progress_file = '.claude/research_progress.json'
        progress = if File.exist?(progress_file)
                     JSON.parse(File.read(progress_file), symbolize_names: true)
                   else
                     {}
                   end

        progress[category_sym] ||= {}
        progress[category_sym][:skipped] = true
        progress[category_sym][:skip_reason] = 'User approved after attempt'
        progress[category_sym][:skipped_at] = Time.now.iso8601
        progress[category_sym][:attempt_proof] = attempt_proof

        FileUtils.mkdir_p(File.dirname(progress_file))
        File.write(progress_file, JSON.pretty_generate(progress))

        # Log for audit
        RuleTracker.log_enforcement(
          rule: :research_skip,
          hook: 'prompt_analyzer',
          action: 'user_approved_skip',
          details: "User approved skipping #{category_name} after attempt: #{attempt_proof}"
        )

        warn ''
        warn "✅ SKIP APPROVED: #{category_name} (attempted: #{attempt_proof})"
        warn ''
        exit 0
      end
    end
  end

  # RESET CIRCUIT BREAKER (VULN-007: user approval required)
  if trigger_names.include?('reset_breaker')
    breaker_file = '.claude/circuit_breaker.json'

    # VULN-003 FIX: Use signed state files
    breaker = StateSigner.read_verified(breaker_file)

    unless breaker
      warn ''
      warn '⚠️  No valid circuit breaker file found - nothing to reset'
      warn ''
      exit 0
    end

    unless breaker['tripped']
      warn ''
      warn '⚠️  Circuit breaker is not tripped - nothing to reset'
      warn ''
      exit 0
    end

    trip_reason = breaker['trip_reason']

    # User explicitly approved - reset the breaker
    breaker['failures'] = 0
    breaker['tripped'] = false
    breaker['tripped_at'] = nil
    breaker['trip_reason'] = nil
    breaker['pending_user_reset'] = false
    breaker['reset_at'] = Time.now.iso8601
    breaker['reset_reason'] = 'user_approved'
    breaker['reset_by'] = 'prompt_analyzer'

    StateSigner.write_signed(breaker_file, breaker)

    # Also clear failure tracking
    failure_file = '.claude/failure_state.json'
    FileUtils.rm_f(failure_file)

    # Log for audit
    RuleTracker.log_enforcement(
      rule: :circuit_breaker,
      hook: 'prompt_analyzer',
      action: 'user_approved_reset',
      details: "User approved breaker reset (was tripped: #{trip_reason})"
    )

    warn ''
    warn '✅ CIRCUIT BREAKER RESET: User approved'
    warn '   Failure tracking cleared. Fresh start.'
    warn ''
    exit 0
  end

  # Check if this is a fresh start (user starting new task)
  is_fresh_start = (trigger_names & FRESH_START_TRIGGERS).any?

  if is_fresh_start
    # Fresh start: replace all requirements
    reqs[:requested] = trigger_names
    reqs[:satisfied] = []
    warn ''
    warn '🔄 FRESH START: New task detected, resetting requirements'
    warn ''
  else
    # Additive: MERGE new triggers with existing (union, no duplicates)
    existing = reqs[:requested] || []
    reqs[:requested] = (existing + trigger_names).uniq
    # DON'T reset satisfaction - we're continuing, not starting over
  end

  reqs[:modifiers] = ((reqs[:modifiers] || []) + detected_modifiers.map { |m| m[:name].to_s }).uniq
  reqs[:timestamp] = Time.now.iso8601
  save_requirements(reqs)
end

# Handle frustration signals - this is learning data
if detected_frustration.any?
  patterns = load_patterns
  patterns[:corrections] += 1
  patterns[:last_updated] = Time.now.iso8601

  # Log the correction for learning
  RuleTracker.log_violation(
    rule: :user_correction,
    hook: 'prompt_analyzer',
    reason: "User correction detected: #{detected_frustration.map { |f| f[:name] }.join(', ')}"
  )

  save_patterns(patterns)

  # Warn Claude about the frustration
  warn ''
  warn '⚠️  USER CORRECTION DETECTED'
  detected_frustration.each do |f|
    warn "   #{f[:name]}: #{f[:meaning]}"
  end
  warn '   → Slow down, check what you missed'
  warn ''
end

# Output detected triggers as context for Claude
if detected_triggers.any?
  warn ''
  warn 'TRIGGERS: ' + detected_triggers.map { |t| t[:name] }.join(', ')
  detected_triggers.each { |t| warn "  #{t[:name]}: #{t[:action]}" }
  detected_modifiers.each { |m| warn "  +#{m[:name]}: #{m[:meaning]}" } if detected_modifiers.any?
  warn ''
end

exit 0
