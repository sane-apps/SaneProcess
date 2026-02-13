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

require_relative 'core/state_manager'

module SaneToolsStartup
  # Tools that are always allowed during startup (needed to complete startup steps)
  STARTUP_ALLOWED_TOOLS = %w[
    Read Grep Glob WebSearch WebFetch
    AskUserQuestion ToolSearch ListMcpResourcesTool ReadMcpResourceTool
  ].freeze

  # MCP tools are read-only during startup — allow all MCP reads
  MCP_READ_PATTERN = /^mcp__/.freeze

  # Bash commands that are part of startup itself
  STARTUP_BASH_PATTERNS = [
    /validation_report\.rb/,
    /SaneMaster\.rb\s+clean_system/,
    /pgrep|pkill|ps\s+/,                # Orphan cleanup
    /kill\s+/,                           # Orphan cleanup
    # Read-only commands always safe
    /\A\s*(ls|cat|head|tail|wc|file|stat|which|type|echo|printf|git\s+(status|log|diff|branch|remote)|pwd|date|whoami|hostname|uname)\b/
  ].freeze

  # Tools that require the gate to be open before use
  GATED_TOOLS = %w[Task Edit Write NotebookEdit Bash Skill].freeze

  class << self
    # Returns nil if allowed, or a block message string if blocked.
    def check_startup_gate(tool_name, tool_input)
      # Only enforce in SaneProcess projects
      project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
      return nil unless File.exist?(File.join(project_dir, '.saneprocess'))

      gate = StateManager.get(:startup_gate)
      return nil if gate[:open]

      # Always allow startup-safe tools
      return nil if STARTUP_ALLOWED_TOOLS.include?(tool_name)
      return nil if tool_name.match?(MCP_READ_PATTERN)

      # Not a gated tool? Allow it
      return nil unless GATED_TOOLS.include?(tool_name)

      # Bash: allow startup-specific commands
      if tool_name == 'Bash'
        command = tool_input['command'] || tool_input[:command] || ''
        return nil if startup_bash?(command)
      end

      # Gate is closed and tool is gated — block
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
      when :session_docs    then 'Read session docs (SESSION_HANDOFF.md, DEVELOPMENT.md)'
      when :skills_registry then 'Read ~/.claude/SKILLS_REGISTRY.md'
      when :validation_report then 'Run: ruby scripts/validation_report.rb'
      when :orphan_cleanup  then 'Kill orphaned Claude processes'
      when :system_clean    then 'Run: ./scripts/SaneMaster.rb clean_system'
      else step.to_s.tr('_', ' ')
      end
    end
  end
end
