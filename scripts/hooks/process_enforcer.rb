#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Process Enforcer Hook
# ==============================================================================
# BLOCKS tool calls when Claude tries to bypass required processes.
# This is the "no shortcuts" enforcement layer.
#
# Enforces:
# 1. SaneLoop started when user requested it
# 2. Research done before using unfamiliar APIs
# 3. Plan shown for approval before implementation
# 4. Proper commit workflow (not just "git commit")
# 5. Bug logging to memory (not just mentioned)
# 6. Proper session summary format (not casual self-rating)
# 7. Verify cycle run before claiming "done"
#
# Hook Type: PreToolUse (Edit, Write, Bash)
# Exit 0 = Allow, Exit 1 = BLOCK
# ==============================================================================

require 'json'
require 'fileutils'
require 'time'
require_relative 'state_signer'

PROJECT_DIR = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
REQUIREMENTS_FILE = File.join(PROJECT_DIR, '.claude/prompt_requirements.json')
SANELOOP_STATE_FILE = File.join(PROJECT_DIR, '.claude/saneloop-state.json')
SATISFACTION_FILE = File.join(PROJECT_DIR, '.claude/process_satisfaction.json')
ENFORCEMENT_LOG = File.join(PROJECT_DIR, '.claude/enforcement_log.jsonl')
MEMORY_CHECK_FILE = File.join(PROJECT_DIR, '.claude/memory_checked.json')
BYPASS_FILE = File.join(PROJECT_DIR, '.claude/bypass_active.json')
RESEARCH_PROGRESS_FILE = File.join(PROJECT_DIR, '.claude/research_progress.json')
HYPOTHESIS_FILE = File.join(PROJECT_DIR, '.claude/research_hypotheses.json')
READ_HISTORY_FILE = File.join(PROJECT_DIR, '.claude/read_history.json')
EDIT_STATE_FILE = File.join(PROJECT_DIR, '.claude/edit_state.json')
SUMMARY_VALIDATED_FILE = File.join(PROJECT_DIR, '.claude/summary_validated.json')

# Session summary required after this many edits
SUMMARY_REQUIRED_AFTER_EDITS = 25

# 5 mandatory research categories - ALL must be satisfied
RESEARCH_CATEGORIES = {
  memory: {
    name: 'Memory',
    tools: ['mcp__memory__read_graph'],
    desc: 'Check past bugs/patterns'
  },
  docs: {
    name: 'API Docs',
    tools: ->(t) { t.start_with?('mcp__apple-docs__') || t.start_with?('mcp__context7__') },
    desc: 'Verify APIs exist'
  },
  web: {
    name: 'Web Search',
    tools: %w[WebSearch WebFetch],
    desc: 'Find patterns/solutions'
  },
  local: {
    name: 'Local Codebase',
    tools: %w[Read Grep Glob],
    desc: 'Understand existing code'
  },
  github: {
    name: 'GitHub',
    tools: ->(t) { t.start_with?('mcp__github__') },
    desc: 'Check issues/PRs/prior work'
  }
}.freeze

# Early exit if bypass mode is active
exit 0 if File.exist?(BYPASS_FILE)

# ═══════════════════════════════════════════════════════════════════════════════
# SATISFACTION CHECKS - How to verify each requirement is met
# ═══════════════════════════════════════════════════════════════════════════════

def saneloop_active?
  return false unless File.exist?(SANELOOP_STATE_FILE)

  state = JSON.parse(File.read(SANELOOP_STATE_FILE), symbolize_names: true)
  state[:active] == true
rescue StandardError
  false
end

def load_satisfaction
  # VULN-003 FIX: Use signed state files
  data = StateSigner.read_verified(SATISFACTION_FILE)
  return {} if data.nil?

  # Symbolize keys for compatibility
  data.transform_keys(&:to_sym).transform_values do |v|
    v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v
  end
rescue StandardError
  {}
end

def save_satisfaction(sat)
  # VULN-003 FIX: Sign state files to prevent tampering
  string_sat = sat.transform_keys(&:to_s).transform_values do |v|
    v.is_a?(Hash) ? v.transform_keys(&:to_s) : v
  end
  StateSigner.write_signed(SATISFACTION_FILE, string_sat)
end

def mark_satisfied(requirement)
  sat = load_satisfaction
  sat[requirement.to_sym] = { satisfied_at: Time.now.iso8601 }
  save_satisfaction(sat)
end

def is_satisfied?(requirement)
  sat = load_satisfaction
  sat[requirement.to_sym] && sat[requirement.to_sym][:satisfied_at]
end

# Research progress tracking - 5 mandatory categories
def load_research_progress
  # VULN-003 FIX: Use signed state files
  data = StateSigner.read_verified(RESEARCH_PROGRESS_FILE)
  return {} if data.nil?

  # Symbolize keys for compatibility
  data.transform_keys(&:to_sym).transform_values do |v|
    v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v
  end
rescue StandardError
  {}
end

def save_research_progress(progress)
  # VULN-003 FIX: Sign state files to prevent tampering
  string_progress = progress.transform_keys(&:to_s).transform_values do |v|
    v.is_a?(Hash) ? v.transform_keys(&:to_s) : v
  end
  StateSigner.write_signed(RESEARCH_PROGRESS_FILE, string_progress)
end

def mark_research_category(category, tool_name)
  progress = load_research_progress
  progress[category] ||= { completed_at: nil, tool: nil, skipped: false, skip_reason: nil }
  return if progress[category][:completed_at] # Already done

  progress[category][:completed_at] = Time.now.iso8601
  progress[category][:tool] = tool_name
  save_research_progress(progress)
end

def research_category_for_tool(tool_name)
  RESEARCH_CATEGORIES.each do |cat, config|
    matcher = config[:tools]
    matched = if matcher.is_a?(Proc)
                matcher.call(tool_name)
              else
                matcher.include?(tool_name)
              end
    return cat if matched
  end
  nil
end

def research_status
  progress = load_research_progress
  done = []
  missing = []

  RESEARCH_CATEGORIES.each do |cat, config|
    if progress[cat] && (progress[cat][:completed_at] || progress[cat][:skipped])
      done << cat
    else
      missing << cat
    end
  end

  { done: done, missing: missing, all_done: missing.empty? }
end

def log_enforcement(action, details)
  FileUtils.mkdir_p(File.dirname(ENFORCEMENT_LOG))
  entry = {
    timestamp: Time.now.iso8601,
    action: action,
    details: details
  }
  File.open(ENFORCEMENT_LOG, 'a') { |f| f.puts entry.to_json }
end

def load_requirements
  return { requested: [], satisfied: [], modifiers: [] } unless File.exist?(REQUIREMENTS_FILE)

  JSON.parse(File.read(REQUIREMENTS_FILE), symbolize_names: true)
rescue StandardError
  { requested: [], satisfied: [], modifiers: [] }
end

# Check if session summary is required (based on edit count)
def session_summary_required?
  return false unless File.exist?(EDIT_STATE_FILE)

  edit_state = JSON.parse(File.read(EDIT_STATE_FILE), symbolize_names: true)
  edit_count = edit_state[:edit_count] || 0

  # Check if summary was validated after the edit count threshold
  if File.exist?(SUMMARY_VALIDATED_FILE)
    summary_data = JSON.parse(File.read(SUMMARY_VALIDATED_FILE), symbolize_names: true)
    validated_at = Time.parse(summary_data[:validated_at]) rescue nil
    edit_state_updated = Time.parse(edit_state[:updated] || edit_state['updated']) rescue nil

    # If summary was validated AFTER current edit state started, we're good
    return false if validated_at && edit_state_updated && validated_at > edit_state_updated
  end

  # Require summary after threshold
  edit_count >= SUMMARY_REQUIRED_AFTER_EDITS
rescue StandardError
  false
end

def edits_since_summary
  return 0 unless File.exist?(EDIT_STATE_FILE)

  edit_state = JSON.parse(File.read(EDIT_STATE_FILE), symbolize_names: true)
  edit_state[:edit_count] || 0
rescue StandardError
  0
end

# ═══════════════════════════════════════════════════════════════════════════════
# SHORTCUT DETECTION - Catch Claude trying to bypass
# ═══════════════════════════════════════════════════════════════════════════════

def detect_casual_self_rating(content)
  # Catch patterns like "Self-Rating: 8/10" or "Rating: 7/10" without proper format
  casual_patterns = [
    /Self-Rating:\s*\d+\/10/i,
    /Rating:\s*\d+\/10/i,
    /\*\*Self-rating:\s*\d+\/10\*\*/i,
    /My rating:\s*\d+\/10/i
  ]

  proper_format = content.include?('SOP Compliance:') && content.include?('Performance:')

  casual_patterns.any? { |p| content.match?(p) } && !proper_format
end

def detect_lazy_commit(command)
  # Catch simple "git commit" without full workflow
  return false unless command.match?(/git commit/i)

  # Full workflow should include: status, diff, add
  has_status = command.include?('status')
  has_diff = command.include?('diff')
  has_add = command.include?('add')

  # If it's just "git commit -m" without the workflow, it's lazy
  command.match?(/git commit\s+-m/i) && !has_status && !has_diff
end

def detect_bash_file_write(command)
  # VULN-002 FIX: Detect Bash commands that write to files
  # These bypass Edit/Write tool hooks!
  file_write_patterns = [
    />(?!&)/,                           # redirect: echo "x" > file (but not >&)
    />>/,                               # append: echo "x" >> file
    /\bsed\s+(-[a-zA-Z]*i|-i)/,         # sed in-place: sed -i 's/x/y/' file
    /\btee\b/,                          # tee: echo "x" | tee file
    /\bcat\s*>(?!&)/,                   # cat redirect: cat > file
    /<<\s*['"]?EOF/i,                   # heredoc: cat << EOF
    /\bdd\b.*\bof=/,                    # dd: dd if=x of=file
    /\bcp\b.*[^|]$/,                    # cp: cp source dest (not in pipeline)
    /\bmv\b.*[^|]$/,                    # mv: mv source dest
    /\btouch\b/,                        # touch: creates files
    /\binstall\b.*-[a-zA-Z]*[mM]/,      # install with mode
  ]

  # Whitelist: safe file operations (VULN-002 FIX: removed .claude/ blanket allow)
  safe_patterns = [
    /\/dev\/null/,                      # Allow redirect to null
    /\bgit\b/,                          # Allow git operations
    /\|.*>/,                            # Allow pipeline output (usually logging)
    # NOTE: .claude/ removed - hooks write via Ruby, not Bash
    # If Claude uses Bash to write .claude/*.json, that's a bypass attempt
  ]

  return false if safe_patterns.any? { |p| command.match?(p) }

  file_write_patterns.any? { |p| command.match?(p) }
end

def detect_bash_table_bypass(command)
  # VULN-004 FIX: Detect sed/echo inserting markdown tables
  # Tables are banned (render terribly in terminal) - can't bypass with sed
  return false unless command.match?(/\bsed\b|\becho\b|>>|>/)

  # Look for table patterns in the command content
  table_patterns = [
    /\|[-:]+\|/,           # |---|---| header separator
    /\|.*\|.*\|/,          # | col | col | rows
  ]

  table_patterns.any? { |p| command.match?(p) }
end

def detect_bash_size_bypass(command)
  # VULN-005 FIX: Detect sed editing large files that would be blocked by Edit
  # If Edit would block due to 800-line limit, sed shouldn't be allowed either
  return nil unless command.match?(/\bsed\s+(-[a-zA-Z]*i|-i)/)

  # Extract target file from sed command
  # Pattern: sed -i '' 's/.../.../g' <filename>
  file_match = command.match(/sed\s+(?:-[a-zA-Z]*i|-i)\s+(?:''|"")?\s*'[^']*'\s+(.+)$/)
  file_match ||= command.match(/sed\s+(?:-[a-zA-Z]*i|-i)\s+(?:''|"")?\s*"[^"]*"\s+(.+)$/)
  return nil unless file_match

  file_path = file_match[1].strip.gsub(/['"]/, '')
  return nil unless File.exist?(file_path)

  line_count = File.readlines(file_path).count
  is_markdown = file_path.end_with?('.md')
  limit = is_markdown ? 1500 : 800

  return { file: file_path, lines: line_count, limit: limit } if line_count > limit
  nil
end

def detect_skipped_verification(content, tool_name)
  # Catch "done" claims without running verify
  done_patterns = [
    /\bdone\b/i,
    /\bcomplete\b/i,
    /\bfinished\b/i,
    /\ball set\b/i,
    /\bthat'?s it\b/i
  ]

  return false unless done_patterns.any? { |p| content.match?(p) }

  # Check if verify was run recently (within last 5 tool calls)
  return false unless File.exist?('.claude/audit.jsonl')

  recent_calls = File.readlines('.claude/audit.jsonl').last(10)
  recent_calls.any? { |line| line.include?('verify') || line.include?('qa.rb') }
rescue StandardError
  false
end

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN ENFORCEMENT LOGIC
# ═══════════════════════════════════════════════════════════════════════════════

begin
  input = JSON.parse($stdin.read)
rescue JSON::ParserError, Errno::ENOENT
  exit 0
end

tool_name = input['tool_name'] || ''
tool_input = input['tool_input'] || {}

# Get the content being written/edited
content = tool_input['new_string'] || tool_input['content'] || tool_input['command'] || ''
file_path = tool_input['file_path'] || ''

# Load requirements set by prompt_analyzer
reqs = load_requirements
requested = reqs[:requested] || []

blocks = []

# ═══════════════════════════════════════════════════════════════════════════════
# BOOTSTRAP FIX: Never block commands needed to SATISFY requirements
# ═══════════════════════════════════════════════════════════════════════════════

# These commands are ALWAYS allowed because they satisfy requirements:
is_bootstrap_command = false

if tool_name == 'Bash'
  bootstrap_patterns = [
    /saneloop\s+start/i,           # Starts a saneloop
    /SaneMaster\.rb\s+saneloop/i,  # SaneMaster saneloop commands
    /SaneMaster\.rb\s+verify/i,    # Verification commands
    /qa\.rb/i,                     # QA verification
  ]
  is_bootstrap_command = bootstrap_patterns.any? { |p| content.match?(p) }
end

# Research tools are NEVER blocked - you can ALWAYS investigate
is_research_tool = %w[Read Grep Glob WebFetch WebSearch].include?(tool_name) ||
                   tool_name.start_with?('mcp__')

# Task tool needs special handling - it's research UNLESS used for editing
if tool_name == 'Task'
  task_prompt = tool_input['prompt'] || ''
  edit_keywords = %w[edit write create modify change update add append remove delete fix patch]
  is_edit_task = edit_keywords.any? { |kw| task_prompt.downcase.include?(kw) }
  is_research_tool = !is_edit_task  # Only research if NOT editing
end

# Read-only Bash commands are also research
if tool_name == 'Bash'
  readonly_patterns = [
    /^\s*ls\b/,                    # List files
    /^\s*cat\s/,                   # Read files
    /^\s*head\b/,                  # Read file start
    /^\s*tail\b/,                  # Read file end
    /^\s*wc\b/,                    # Word count
    /^\s*find\b/,                  # Find files
    /^\s*grep\b/,                  # Search content
    /^\s*rg\b/,                    # Ripgrep
    /^\s*which\b/,                 # Find command
    /^\s*pwd\b/,                   # Current directory
    /^\s*git\s+(status|log|diff|show|branch)/i,  # Read-only git
    /^\s*ruby\s+-c\b/,             # Syntax check
  ]
  is_research_tool = true if readonly_patterns.any? { |p| content.match?(p) }
end

# Skip ALL enforcement for bootstrap commands - they're how you GET compliant
if is_bootstrap_command
  exit 0
end

# CRITICAL: Skip ALL enforcement for research - you can ALWAYS investigate
if is_research_tool
  # Track memory check - mandatory before project work
  if tool_name == 'mcp__memory__read_graph'
    FileUtils.mkdir_p(File.dirname(MEMORY_CHECK_FILE))
    File.write(MEMORY_CHECK_FILE, { checked_at: Time.now.iso8601 }.to_json)
  end

  # Track research progress by category (MUST be before exit 0)
  if requested.include?('research')
    category = research_category_for_tool(tool_name)
    if category
      mark_research_category(category, tool_name)
      status = research_status

      if status[:all_done]
        mark_satisfied(:research)
        warn '✅ All 5 research categories complete - research satisfied'
      elsif status[:done].any?
        remaining = status[:missing].map { |c| RESEARCH_CATEGORIES[c][:name] }.join(', ')
        warn "📊 Research: #{status[:done].length}/5 | Missing: #{remaining}"
      end
    end
  end

  exit 0
end

# MEMORY CHECK: Warn if Edit/Write without checking memory first
if %w[Edit Write].include?(tool_name) && !File.exist?(MEMORY_CHECK_FILE)
  warn ''
  warn '⚠️  MEMORY NOT CHECKED - Run mcp__memory__read_graph first'
  warn '   Past bugs often repeat. Check memory before project work.'
  warn ''
  # Warn only, don't block (yet)
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 1: SaneLoop Required
# ═══════════════════════════════════════════════════════════════════════════════

if requested.include?('saneloop') && !saneloop_active?
  blocks << {
    rule: 'SANELOOP_REQUIRED',
    message: 'User requested SaneLoop but none is active.',
    fix: 'Run: ./Scripts/SaneMaster.rb saneloop start "task" --criteria "..." --promise "..."'
  }
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 1.5: VULN-003 FIX - Subagent Bypass Detection
# ═══════════════════════════════════════════════════════════════════════════════

if tool_name == 'Task'
  # Check if spawning an editing subagent to bypass enforcement
  task_prompt = tool_input['prompt'] || ''
  edit_keywords = %w[edit write create modify change update add append remove delete fix patch]

  is_edit_task = edit_keywords.any? { |kw| task_prompt.downcase.include?(kw) }

  # Only block if there are unsatisfied requirements
  has_blocking_requirements = (
    (requested.include?('saneloop') && !saneloop_active?) ||
    (requested.include?('plan') && !is_satisfied?(:plan))
  )

  if is_edit_task && has_blocking_requirements
    blocks << {
      rule: 'SUBAGENT_BYPASS',
      message: 'Nice try! Spawning a subagent to do your editing is still cheating.',
      fix: 'Complete the required process (saneloop, plan approval) before ANY code changes.'
    }
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 2: Research Required Before Implementation (5 MANDATORY CATEGORIES)
# VULN-FIX: Research is now MANDATORY by default for Edit/Write (opt-OUT, not opt-IN)
# ═══════════════════════════════════════════════════════════════════════════════

# Research is mandatory for Edit/Write unless already satisfied
research_required = %w[Edit Write].include?(tool_name) && !is_satisfied?(:research)

if research_required
  # Check actual research progress (tracked by research_tracker.rb PostToolUse)
  status = research_status

  if status[:all_done]
    # Auto-mark satisfaction when all 5 categories complete
    # (research_tracker tracks this but process_enforcer wasn't triggered for MCP tools)
    mark_satisfied(:research)
    warn '✅ Research: All 5 categories complete - now satisfied'
  else
    # Allow research tools through - they're being tracked by research_tracker
    research_tools = %w[Read Grep Glob WebFetch WebSearch Task]
    is_doing_research = research_tools.include?(tool_name) || tool_name.start_with?('mcp__')

    unless is_doing_research
      missing_names = status[:missing].map { |c| RESEARCH_CATEGORIES[c][:name] }
      missing_keys = status[:missing].map(&:to_s)
      done_count = status[:done].length

      blocks << {
        rule: 'RESEARCH_FIRST',
        message: "#{done_count}/5 research categories complete. Missing: #{missing_names.join(', ')}",
        fix: "Complete ALL 5: Memory, Docs, Web, Local, GitHub. Track competing hypotheses with confidence levels as you go. If output is not applicable, TRY FIRST then ask user: 'skip #{missing_keys.first}'"
      }
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 3: Plan Approval Required
# ═══════════════════════════════════════════════════════════════════════════════

if requested.include?('plan') && !is_satisfied?(:plan)
  # Block Edit/Write until plan is shown and approved
  if %w[Edit Write].include?(tool_name)
    blocks << {
      rule: 'PLAN_APPROVAL_REQUIRED',
      message: 'User requested a plan before implementation.',
      fix: 'Show the plan in plain english for user approval first. Do NOT just reference a file.'
    }
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 4: Casual Self-Rating Detection
# ═══════════════════════════════════════════════════════════════════════════════

if %w[Edit Write].include?(tool_name) && detect_casual_self_rating(content)
  blocks << {
    rule: 'PROPER_RATING_FORMAT',
    message: 'Detected casual self-rating without proper format.',
    fix: 'Use: SOP Compliance: X/10 (auto from compliance report) + Performance: X/10 (with gaps)'
  }
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 5: Lazy Commit Detection
# ═══════════════════════════════════════════════════════════════════════════════

if tool_name == 'Bash' && detect_lazy_commit(content)
  blocks << {
    rule: 'FULL_COMMIT_WORKFLOW',
    message: 'Detected simple "git commit" without full workflow.',
    fix: 'Full workflow: git pull → status → diff → add → commit (with README update if needed)'
  }
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 5.5: VULN-002 FIX - Bash File Write Bypass Detection
# ═══════════════════════════════════════════════════════════════════════════════

if tool_name == 'Bash' && detect_bash_file_write(content)
  # Only block if there are unsatisfied requirements that would block Edit/Write
  has_blocking_requirements = (
    (requested.include?('saneloop') && !saneloop_active?) ||
    (requested.include?('plan') && !is_satisfied?(:plan)) ||
    (requested.include?('research') && !is_satisfied?(:research))
  )

  if has_blocking_requirements
    blocks << {
      rule: 'BASH_FILE_WRITE_BYPASS',
      message: 'Detected Bash command that writes to files. Nice try!',
      fix: 'You cannot bypass Edit/Write restrictions with echo/sed/cat. Complete the required process first.'
    }
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 5.6: VULN-004 FIX - Bash Table Bypass Detection
# ═══════════════════════════════════════════════════════════════════════════════

if tool_name == 'Bash' && detect_bash_table_bypass(content)
  blocks << {
    rule: 'BASH_TABLE_BYPASS',
    message: 'Detected markdown table in sed/echo command. Tables are banned.',
    fix: 'Tables render terribly in terminal. Use plain lists instead. No bypassing with sed!'
  }
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 5.7: VULN-005 FIX - Bash File Size Bypass Detection
# ═══════════════════════════════════════════════════════════════════════════════

if tool_name == 'Bash'
  size_violation = detect_bash_size_bypass(content)
  if size_violation
    blocks << {
      rule: 'BASH_SIZE_BYPASS',
      message: "sed target #{size_violation[:file]} is #{size_violation[:lines]} lines (limit: #{size_violation[:limit]}). Nice try!",
      fix: 'Cannot bypass file size limits with sed. Split the file first.'
    }
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 6: Bug Note Must Update Memory
# ═══════════════════════════════════════════════════════════════════════════════

if requested.include?('bug_note') && !is_satisfied?(:bug_note)
  # If not using memory MCP, block
  unless tool_name.start_with?('mcp__memory')
    # Allow research tools, but block implementation until memory is updated
    if %w[Edit Write Bash].include?(tool_name)
      blocks << {
        rule: 'BUG_TO_MEMORY',
        message: 'Bug note requested but memory not updated.',
        fix: 'Use mcp__memory__create_entities or mcp__memory__add_observations to log the bug pattern.'
      }
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 7: Verify Before Done
# ═══════════════════════════════════════════════════════════════════════════════

if requested.include?('verify') && !is_satisfied?(:verify)
  # Check if claiming done without verification
  if %w[Edit Write].include?(tool_name) && content.match?(/\b(done|complete|finished)\b/i)
    # Check recent audit log for verify/qa.rb
    verified_recently = false
    if File.exist?('.claude/audit.jsonl')
      recent = File.readlines('.claude/audit.jsonl').last(20).join
      verified_recently = recent.include?('verify') || recent.include?('qa.rb')
    end

    unless verified_recently
      blocks << {
        rule: 'VERIFY_BEFORE_DONE',
        message: 'Claiming "done" but verification not run.',
        fix: 'Run: ./Scripts/SaneMaster.rb verify (or ruby scripts/qa.rb) before claiming done.'
      }
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK 8: Session Summary Required After 25+ Edits
# ═══════════════════════════════════════════════════════════════════════════════

if session_summary_required? && %w[Edit Write].include?(tool_name)
  edit_count = edits_since_summary
  blocks << {
    rule: 'SESSION_SUMMARY_REQUIRED',
    message: "#{edit_count} edits without session summary. Time to wrap up and document.",
    fix: 'Write session summary to .claude/SESSION_HANDOFF.md with format: ## Session Summary, SOP Compliance: X/10, Performance: X/10'
  }
end

# ═══════════════════════════════════════════════════════════════════════════════
# ENFORCEMENT OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════

if blocks.any?
  log_enforcement('BLOCKED', blocks.map { |b| b[:rule] })

  warn ''
  warn '🛑 BLOCKED'
  blocks.each do |b|
    warn "  ❌ #{b[:rule]}: #{b[:message]}"
    warn "     Fix: #{b[:fix]}"
  end
  warn ''

  exit 2 # Exit code 2 = BLOCK in Claude Code
end

# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-SATISFACTION DETECTION & POSITIVE FEEDBACK
# ═══════════════════════════════════════════════════════════════════════════════

satisfied_now = []

# NOTE: Research auto-satisfaction now tracked in early-exit block (lines 326-351)
# using 5 mandatory categories system. Old "3 operations" logic removed.

# If using memory MCP for bug, mark satisfied
if requested.include?('bug_note') && tool_name.start_with?('mcp__memory')
  mark_satisfied(:bug_note)
  satisfied_now << 'bug_note'
end

# ═══════════════════════════════════════════════════════════════════════════════
# POSITIVE FEEDBACK - Make compliance feel GOOD
# ═══════════════════════════════════════════════════════════════════════════════

if satisfied_now.any?
  warn "✅ #{satisfied_now.join(', ')} satisfied"
end

# Show progress toward full compliance
sat = load_satisfaction
satisfied_count = sat.keys.count
required_count = requested.count

if satisfied_count > 0 && required_count > 0 && satisfied_count >= required_count
  warn '✅ All requirements satisfied'
end

exit 0
