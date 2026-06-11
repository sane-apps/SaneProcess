# frozen_string_literal: true

# ==============================================================================
# SanePrompt Output
# ==============================================================================
# Context/warning rendering for saneprompt.rb (UserPromptSubmit hook).
# Split out of saneprompt.rb to keep the hook under the Rule #10 size limit.
# Expects saneprompt.rb's constants (SANEUI_SOURCE_OF_TRUTH_PATTERN) and the
# intelligence formatters (saneprompt_intelligence.rb) to be loaded.
# ==============================================================================

def output_context(prompt_type, rules, triggers, prompt, frustrations = [], detected_reqs = [], learning_warning = nil, patterns = nil, memory_staging = nil)
  lines = []

  # Only show context for tasks
  return if [:passthrough, :question].include?(prompt_type)

  lines << '---'
  lines << "Task type: #{prompt_type}"

  # AUTO-SANELOOP: Inject structured workflow for ALL tasks
  # This is the core of the unified workflow system
  # Learned from 700+ iteration failure: guardrails prevent spirals
  # User insight: "ANY code change is a big task" - no more "no big deal" syndrome
  lines << ''
  lines << 'WORKFLOW STRUCTURE (auto-injected):'
  lines << '  1. Use the smallest evidence set that makes the task defensible'
  lines << '     - local inspection before edits'
  lines << '     - docs for uncertain APIs/libraries'
  lines << '     - web for current external facts'
  lines << '     - GitHub for upstream/repo/issue state'
  lines << '  2. Define acceptance criteria: what does "done" look like?'
  lines << '  3. Edits blocked until research complete (sanetools enforces)'
  lines << '  4. If you touch hooks, tools, skills, templates, or durable docs, update handoff + memory'
  lines << '  5. Before saying a tool is missing, choosing a new canonical tool path, or using a repeated tool-deficiency workaround, run: ruby scripts/SaneMaster.rb tool_discovery --query "..."'
  lines << '  6. If a recurring tool is truly missing, install it, document it, and make it the standard path'
  lines << '  7. Self-rate SOP compliance when done'
  lines << ''
  lines << 'GUARDRAILS ACTIVE (all code tasks):'
  lines << '  - Max 3 edit attempts before mandatory research pause (ENFORCED)'
  lines << '  - If stuck after 2 tries: STOP and investigate, do not guess'
  lines << '  - Circuit breaker trips at 2 consecutive failures'
  lines << '  - Tooling/docs work is persistent work, not optional cleanup'
  if prompt.match?(SANEUI_SOURCE_OF_TRUTH_PATTERN)
    lines << '  - Settings/About/license/update UI work MUST start from SaneUI Catalog and shared components, not app-local clones'
    lines << '  - SaneUI source of truth: ~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift'
  end
  if prompt_type == :big_task
    lines << ''
    lines << 'BIG TASK - Additional guardrails:'
    lines << '  - SaneLoop iterations tracked'
    lines << '  - Max 20 iterations before human check-in'
  end

  # INTELLIGENCE: memory update needed from previous session
  memory_context = format_memory_staging_context(memory_staging)
  if memory_context
    lines << ''
    lines << memory_context
  end

  # INTELLIGENCE: Show learned patterns from previous sessions
  pattern_context = format_patterns_for_claude(patterns)
  if pattern_context
    lines << ''
    lines << pattern_context
  end

  # INTELLIGENCE: Learning pattern warning
  if learning_warning
    lines << ''
    lines << "LEARNING WARNING: #{learning_warning}"
  end

  # INTELLIGENCE: Frustration detected
  if frustrations.any?
    lines << ''
    lines << 'FRUSTRATION DETECTED:'
    frustrations.each do |f|
      lines << "  Type: #{f[:type]} - User may be correcting you. Read carefully."
    end
  end

  # INTELLIGENCE: Requirements extracted
  if detected_reqs.any?
    lines << ''
    lines << 'REQUIREMENTS DETECTED:'
    detected_reqs.each do |r|
      lines << "  #{r} - Must be satisfied before editing"
    end
  end

  if triggers.any?
    lines << ''
    lines << 'PATTERN ALERT:'
    triggers.each do |t|
      lines << "  #{t[:word]}: #{t[:warning]}"
    end
  end

  if rules.any?
    lines << ''
    lines << 'Applicable rules:'
    rules.each { |r| lines << "  #{r}" }
  end

  lines << '---'

  # Output to stdout - this becomes context for Claude
  puts lines.join("\n")
end

def output_warning(prompt_type, rules, triggers, frustrations = [], detected_reqs = [], patterns = nil)
  # Only show warnings for tasks (stderr shown to user)
  return if [:passthrough, :question].include?(prompt_type)

  warn '---'
  warn "SanePrompt: #{prompt_type.to_s.gsub('_', ' ').upcase}"

  # INTELLIGENCE: Show pattern summary to user
  pattern_summary = format_patterns_for_user(patterns)
  if pattern_summary
    warn ''
    warn pattern_summary
  end

  # INTELLIGENCE: Show frustration warning to user
  if frustrations.any?
    warn ''
    warn 'Frustration detected - Claude will read carefully'
  end

  # INTELLIGENCE: Show detected requirements
  if detected_reqs.any?
    warn ''
    warn "Requirements: #{detected_reqs.join(', ')}"
  end

  if triggers.any?
    warn ''
    warn 'Pattern triggers detected:'
    triggers.each { |t| warn "  #{t[:word]} -> #{t[:warning]}" }
  end

  if rules.any?
    warn ''
    warn 'Rules to follow:'
    rules.first(3).each { |r| warn "  #{r}" }
  end

  warn '---'
end
