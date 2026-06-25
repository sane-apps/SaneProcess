#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Startup Gate Module
# ==============================================================================
# Blocks substantive work (Task, Bash, Edit, Write) until all mandatory startup
# steps are complete. Allows only tools needed to complete startup itself.
#
# The gate is initialized by session_start.rb and tracked by sanetrack.rb.
# Steps auto-complete when required files don't exist (cross-project safety).
# ==============================================================================

require 'time'
require_relative 'core/state_manager'
require_relative 'core/project_root'

module SaneToolsStartup
  # Tools that are always allowed during startup (needed to complete startup steps)
  STARTUP_ALLOWED_TOOLS = %w[
    Read Grep Glob WebSearch WebFetch
    AskUserQuestion ToolSearch ListMcpResourcesTool ReadMcpResourceTool
  ].freeze

  # MCP tools are allowed during startup only when read-only. Mutations can
  # affect GitHub, memory, or external state and must wait until startup context
  # is loaded.
  MCP_READ_PATTERN = /^mcp__/.freeze
  MCP_MUTATION_PATTERN = /^mcp__.*__(?:add|create|delete|fork|merge|push|update|write)_/i.freeze

  # Bash commands that are part of startup itself
  STARTUP_BASH_PATTERNS = [
    /validation_report\.rb/,
    /SaneMaster\.rb\s+machine_cleanup\b/,
    # Hook self-management / unblock path must always run, even mid-startup. The
    # documented remedy for a wedged gate is `ruby scripts/hooks/<hook>.rb
    # --reset|--status|--self-test`; if the startup gate blocked it, the agent
    # had no working reset and the wedge became unrecoverable.
    %r{scripts/hooks/\S+\.rb\s+--(?:self-test|reset|status)\b},
    /pgrep|pkill|ps\s+/,                # Orphan cleanup
    /kill\s+/,                           # Orphan cleanup
    # Read-only inspection is never gated — searching/listing the code to load
    # context is the whole point of startup. grep/rg/find belong here next to
    # ls/cat; gating them just blocks the agent from doing startup at all.
    /\A\s*(ls|cat|head|tail|wc|file|stat|which|type|echo|printf|git\s+(status|log|diff|branch|remote)|pwd|date|whoami|hostname|uname|grep|rg|find|sed\s+-n|awk)\b/
  ].freeze

  # Tools that require the gate to be open before use
  GATED_TOOLS = %w[Task Edit Write NotebookEdit Bash Skill].freeze

  # A closed startup gate degrades after this many blocks instead of walling off
  # all work forever. A gate can become unsatisfiable from a given session — e.g.
  # cross-project read tracking lands the required-doc reads in a DIFFERENT
  # project's state, so the `session_docs` step never flips even though the docs
  # were read. The MCP-verification gate already self-degrades for the same
  # reason (MCP_GATE_MAX_BLOCKS); the startup gate must too, or it is a hard
  # deadlock. Loading context is valuable, but an unsatisfiable wall is worse.
  STARTUP_GATE_MAX_BLOCKS = 3

  class << self
    # Returns nil if allowed, or a block message string if blocked.
    def check_startup_gate(tool_name, tool_input)
      # Only enforce in SaneProcess projects
      project_dir = SaneProjectRoot.resolve
      return nil unless File.exist?(File.join(project_dir, '.saneprocess'))

      # No startup gate when developing SaneProcess itself — you cannot require
      # "read the session docs / run validation_report" before editing the very
      # hooks that implement the gate.
      return nil if SaneProjectRoot.self_development?

      gate = StateManager.get(:startup_gate)
      return nil if gate[:open]

      # Always allow startup-safe tools
      return nil if STARTUP_ALLOWED_TOOLS.include?(tool_name)
      return nil if tool_name.match?(MCP_READ_PATTERN) && !tool_name.match?(MCP_MUTATION_PATTERN)

      return build_block_message(gate) if tool_name.match?(MCP_MUTATION_PATTERN)

      # Not a gated tool? Allow it
      return nil unless GATED_TOOLS.include?(tool_name)

      # Bash: allow startup-specific commands
      if tool_name == 'Bash'
        command = tool_input['command'] || tool_input[:command] || ''
        return nil if startup_bash?(command)
      end

      # Gate is closed and tool is gated — block, but never permanently. Count
      # blocks; once past STARTUP_GATE_MAX_BLOCKS, degrade: open the gate with a
      # warning so an unsatisfiable gate (broken cross-project read tracking,
      # etc.) can't deadlock the whole session.
      block_attempts = (gate[:block_attempts] || 0) + 1
      StateManager.update(:startup_gate) { |g| g[:block_attempts] = block_attempts; g }

      if block_attempts > STARTUP_GATE_MAX_BLOCKS
        StateManager.update(:startup_gate) do |g|
          g[:open] = true
          g[:degraded] = true
          g[:opened_at] = Time.now.iso8601
          g
        end
        warn "⚠️  Startup gate degraded: not satisfied after #{STARTUP_GATE_MAX_BLOCKS} blocks — opening so work can proceed. Load any missing session context manually."
        return nil
      end

      build_block_message(gate)
    end

    private

    def startup_bash?(command)
      STARTUP_BASH_PATTERNS.any? { |pattern| command.match?(pattern) }
    end

    def build_block_message(gate)
      steps = gate[:steps] || {}
      pending = steps.select { |_k, v| v == false }.keys
      done = steps.select { |_k, v| v == true }.keys

      msg = "STARTUP GATE: Complete startup steps before working\n"
      msg += "\n"
      msg += "Pending steps:\n"
      pending.each { |s| msg += "  [ ] #{format_step(s)}\n" }
      msg += "\n"
      if done.any?
        msg += "Completed:\n"
        done.each { |s| msg += "  [x] #{format_step(s)}\n" }
        msg += "\n"
      end
      msg += "Allowed now: Read, Grep, Glob, WebSearch, MCP tools, startup Bash\n"
      msg += "Blocked until gate opens: Task, Edit, Write, Bash (non-startup)\n"
      msg += "\n"
      msg += "WHY: Skipping startup leads to rediscovering known issues,\n"
      msg += "missing context, and wasted effort. Complete these steps first."
      msg
    end

    def format_step(step)
      case step
      when :session_docs    then session_docs_step_label
      when :skills_registry then "Read #{skills_registry_label}"
      when :validation_report then 'Run: ruby scripts/validation_report.rb'
      when :orphan_cleanup  then 'Kill orphaned Claude processes'
      when :system_clean    then 'Run: ./scripts/SaneMaster.rb machine_cleanup --host mini --apply'
      else step.to_s.tr('_', ' ')
      end
    end

    # List the docs that still need reading, not a hardcoded subset. The required
    # set (SESSION_HANDOFF.md, DEVELOPMENT.md, CONTRIBUTING.md, SKILLS_REGISTRY.md,
    # ...) is discovered at session start, so a fixed label silently hides which
    # file is actually blocking the gate and sends the agent hunting through state.
    def session_docs_step_label
      sd = StateManager.get(:session_docs)
      pending = (sd[:required] || []) - (sd[:read] || [])
      list = pending.empty? ? 'SESSION_HANDOFF.md, DEVELOPMENT.md' : pending.join(', ')
      "Read session docs (#{list})"
    end

    def skills_registry_label
      active_skills_registry_path.sub(File.expand_path('~'), '~')
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

    def codex_runtime?
      ENV['CODEX_SHELL'] == '1' || ENV['CODEX_INTERNAL_ORIGINATOR_OVERRIDE'].to_s.include?('Codex')
    end
  end
end
