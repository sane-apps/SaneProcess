#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Refusal Tracking Module
# ==============================================================================
# Detects repeated blocks of the same type so the second+ block can be compact
# and remedial instead of echoing the full original wall of text.
#
# Included into SaneToolsChecks' singleton class.
# ==============================================================================

require 'time'
require_relative 'core/state_manager'

module SaneToolsRefusal
  # A repeat-block counter only ages out after this long with no same-type block.
  # A stale counter left behind by a finished subagent (or an earlier unrelated
  # phase) must not silently ambush a later block by jumping straight to the
  # escalated message. 30 minutes is well past any real retry loop.
  REFUSAL_DECAY_SECONDS = 1800

  # Map a block reason to a specific, repeatable block type. Returns 'other' for
  # anything not specifically classified — those are intentionally NOT tracked
  # (see check_refusal_to_read) so unrelated gates never pool into one counter.
  def classify_block_type(block_reason)
    case block_reason
    when /RESEARCH INCOMPLETE/i then 'research_incomplete'
    when /BLOCKED PATH/i then 'blocked_path'
    when /FILE SIZE/i then 'file_size'
    when /BASH.*WRITE/i then 'bash_write'
    when /STATE.*BYPASS|STATE.*PROTECTED/i then 'state_bypass'
    when /MCP.*VERIFICATION/i then 'mcp_verification'
    when /MCP ACTIONS PENDING/i then 'mcp_actions_pending'
    when /SANELOOP REQUIRED/i then 'saneloop_required'
    when /READ REQUIRED DOCS/i then 'session_docs'
    when /STARTUP GATE/i then 'startup_gate'
    else 'other'
    end
  end

  def check_refusal_to_read(tool_name, block_reason)
    return nil unless block_reason

    block_type = classify_block_type(block_reason)

    # Do NOT track non-specific blocks. The old catch-all 'other' bucket pooled
    # unrelated gates (startup gate, blocked path, file size, ...) into a single
    # escalating counter whose message then REPLACED the real block reason — so a
    # plain startup-gate block on `grep` surfaced as "REFUSAL TO READ: other 23x"
    # and the session fought a phantom instead of the real gate. Untracked types
    # always show their true reason.
    return nil if block_type == 'other'

    blocks = StateManager.get(:refusal_tracking) || {}
    block_key = block_type.to_sym
    current = blocks[block_key] || blocks[block_type] || { count: 0, last_tool: nil }
    current = { count: 0, last_tool: nil } if refusal_counter_stale?(current)

    current[:count] += 1
    current[:last_tool] = tool_name
    current[:last_at] = Time.now.iso8601

    StateManager.update(:refusal_tracking) do |b|
      b.delete(block_type)
      b[block_key] = current
      b
    end

    # The note is appended BELOW the real reason by output_block — it never
    # replaces it — and it never changes the exit code. It only offers a compact
    # remedy on a genuine same-type repeat. No accusatory "refusal" language: a
    # repeated gate hit is usually a missing prerequisite, not defiance.
    case current[:count]
    when 1
      nil
    when 2
      "⚠️  SAME BLOCK TWICE: #{block_type}\n" \
      "#{refusal_remedy(block_type)}"
    else
      "⚠️  REPEAT BLOCK (#{current[:count]}x): #{block_type}\n" \
      "#{refusal_remedy(block_type)}"
    end
  end

  def refusal_counter_stale?(current)
    return false unless current[:last_at]

    (Time.now - Time.parse(current[:last_at].to_s)) > REFUSAL_DECAY_SECONDS
  rescue ArgumentError
    false
  end

  def refusal_remedy(block_type)
    case block_type.to_s
    when 'research_incomplete'
      'Run the missing research named in the first block, or use rr- only if restarting research.'
    when 'mcp_actions_pending'
      'Resolve the pending MCP/memory action named in the first block, then retry.'
    when 'session_docs'
      'Read the required docs named in the first block, then retry.'
    when 'startup_gate'
      'Complete the startup gate command named in the first block, then retry.'
    when 'saneloop_required'
      'Start or continue the required SaneLoop command named in the first block.'
    else
      'Follow the first block remedy. Use reset? only when a logged reset is intentional.'
    end
  end

  def reset_refusal_tracking(block_type = nil)
    if block_type
      StateManager.update(:refusal_tracking) do |b|
        b.delete(block_type)
        b.delete(block_type.to_sym)
        b
      end
    else
      StateManager.reset(:refusal_tracking)
    end
  end

  def reward_correct_behavior(action_type)
    case action_type
    when :research_done
      reset_refusal_tracking('research_incomplete')
      warn '✅ Research complete. You may now edit.'
    when :used_correct_tool
      warn '✅ Correct tool used. Proceeding.'
    when :read_sop
      warn "✅ SOP acknowledged. You're following the process."
    end
  end
end
