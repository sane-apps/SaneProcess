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
  def check_refusal_to_read(tool_name, block_reason)
    return nil unless block_reason

    block_type = case block_reason
                 when /RESEARCH INCOMPLETE/i then 'research_incomplete'
                 when /BLOCKED PATH/i then 'blocked_path'
                 when /FILE SIZE/i then 'file_size'
                 when /BASH.*WRITE/i then 'bash_write'
                 when /STATE.*BYPASS|STATE.*PROTECTED/i then 'state_bypass'
                 when /MCP.*VERIFICATION/i then 'mcp_verification'
                 when /MCP ACTIONS PENDING/i then 'mcp_actions_pending'
                 when /SANELOOP REQUIRED/i then 'saneloop_required'
                 when /READ REQUIRED DOCS/i then 'session_docs'
                 else 'other'
                 end

    blocks = StateManager.get(:refusal_tracking) || {}
    block_key = block_type.to_sym
    current = blocks[block_key] || blocks[block_type] || { count: 0, last_tool: nil }

    current[:count] += 1
    current[:last_tool] = tool_name
    current[:last_at] = Time.now.iso8601

    StateManager.update(:refusal_tracking) do |b|
      b.delete(block_type)
      b[block_key] = current
      b
    end

    case current[:count]
    when 1
      nil
    when 2
      "⚠️  SAME BLOCK TWICE: #{block_type}\n" \
      "#{refusal_remedy(block_type)}"
    else
      "REFUSAL TO READ DETECTED: #{block_type}\n" \
      "You've been blocked #{current[:count]}x for: #{block_type}\n" \
      "#{refusal_remedy(block_type)}"
    end
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
