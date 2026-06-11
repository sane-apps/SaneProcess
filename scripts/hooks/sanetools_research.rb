#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Research + MCP Verification Module
# ==============================================================================
# MCP-aware research-gate logic and the MCP verification preflight, extracted
# from sanetools_checks.rb per Rule #10 (file size limit).
#
# Included into SaneToolsChecks' singleton class:
#   include SaneToolsResearch
# ==============================================================================

require 'json'
require_relative 'core/state_manager'

module SaneToolsResearch
  # Categories that require specific MCPs — auto-satisfy if those MCPs aren't available.
  # :web and :local use built-in tools (WebSearch, Read/Grep/Glob) so always required.
  MCP_DEPENDENT_CATEGORIES = {
    docs: [:apple_docs, :context7],
    github: [:github]
  }.freeze

  MCP_SERVER_NAME_MAP = {
    apple_docs: 'apple-docs',
    context7: 'context7',
    github: 'github'
  }.freeze

  def configured_mcp_keys(project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd)
    server_names = configured_mcp_server_names(project_dir)

    MCP_SERVER_NAME_MAP.each_with_object([]) do |(key, server_name), configured|
      configured << key if server_names.include?(server_name)
    end
  end

  def configured_mcp_server_names(project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd)
    configured_mcp_config_paths(project_dir).each_with_object([]) do |path, names|
      next unless File.exist?(path)

      contents = File.read(path, encoding: Encoding::UTF_8)
      if path.end_with?('.json')
        names.concat(mcp_names_from_json_config(contents))
      elsif path.end_with?('.toml')
        names.concat(mcp_names_from_toml_config(contents))
      end
    rescue StandardError
      next
    end.uniq
  end

  def configured_mcp_config_paths(project_dir)
    [
      File.expand_path('~/.mcp.json'),
      File.join(project_dir, '.mcp.json'),
      File.expand_path('~/.claude/settings.json'),
      File.expand_path('~/.config/claude/mcp-config.json'),
      File.join(project_dir, '.claude', 'settings.json'),
      File.expand_path('~/.codex/config.toml'),
      File.join(project_dir, '.codex', 'config.toml'),
      File.expand_path('~/.gemini/settings.json'),
      File.join(project_dir, '.gemini', 'settings.json'),
      File.expand_path('~/.grok/config.toml'),
      File.join(project_dir, '.grok', 'config.toml')
    ].uniq
  end

  def mcp_names_from_json_config(contents)
    config = JSON.parse(contents)
    names = (config['mcpServers'] || {}).keys
    permissions = Array(config.dig('permissions', 'allow')) + Array(config.dig('permissions', 'ask'))
    permissions.each do |permission|
      name = permission.to_s[/\Amcp__(.+?)__/, 1]
      names << name if name
    end
    names
  rescue JSON::ParserError
    []
  end

  def mcp_names_from_toml_config(contents)
    contents.scan(/^\s*\[mcp_servers\.([^\]]+)\]/).flatten.reject do |name|
      name.include?('.')
    end.map do |name|
      name.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
    end
  end

  def configured_mcp_verification_info(project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd)
    configured = configured_mcp_keys(project_dir)
    MCP_VERIFICATION_INFO.select { |key, _info| configured.include?(key) }
  end

  # Returns only the research categories that should be enforced,
  # skipping MCP-dependent ones if those MCPs aren't configured.
  def effective_research_categories(research_categories)
    research = StateManager.get(:research)
    configured = configured_mcp_keys

    research_categories.keys.select do |cat|
      if MCP_DEPENDENT_CATEGORIES.key?(cat) && !research[cat]
        (MCP_DEPENDENT_CATEGORIES[cat] & configured).any?
      else
        true
      end
    end
  end

  def check_research_before_edit(tool_name, edit_tools, research_categories)
    return nil unless edit_tools.include?(tool_name)

    research = StateManager.get(:research)
    effective_categories = effective_research_categories(research_categories)

    total = effective_categories.length
    done = effective_categories.count { |cat| research[cat] }
    complete = done == total

    return nil if complete

    missing = effective_categories.reject { |cat| research[cat] }

    # Build specific instructions for each missing category
    missing_instructions = missing.map do |cat|
      case cat
      when :docs then "  1. DOCS: mcp__apple-docs, mcp__context7, or WebSearch for docs (verify APIs exist)"
      when :web then "  2. WEB: WebSearch (current best practices)"
      when :github then "  3. GITHUB: mcp__github__search_* or WebSearch for examples (real-world code)"
      when :local then "  4. LOCAL: Read/Grep/Glob (understand existing code)"
      else "  #{cat}: Complete this research category"
      end
    end.join("\n")

    "RESEARCH INCOMPLETE [#{done}/#{total} complete: missing #{missing.join(', ')}]\n" \
    "Cannot edit until ALL #{total} research categories are done.\n" \
    "MISSING (do these NOW):\n" \
    "#{missing_instructions}\n" \
    "Rule #2: VERIFY, THEN TRY. Research once, succeed once.\n" \
    "Reset: rr- (clear research to start over)"
  end

  def check_external_mutations(tool_name, external_mutation_pattern, research_categories)
    return nil unless tool_name.match?(external_mutation_pattern)

    research = StateManager.get(:research)
    effective = effective_research_categories(research_categories)
    complete = effective.all? { |cat| research[cat] }

    return nil if complete

    missing = effective.reject { |cat| research[cat] }
    "EXTERNAL MUTATION BLOCKED\n" \
    "Tool '#{tool_name}' affects external systems. Research first.\n" \
    "Missing: #{missing.join(', ')}. Use read-only tools to understand state first.\n" \
    "Reset: rr- (clear research to start over)"
  end


  # === PREFLIGHT: MCP Verification System ===
  # Block edits until ALL MCPs have been verified this session
  # User insight: "how can you make sure all systems are go before work begins?"

  CLAUDE_DIR = File.join(ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd, '.claude')
  MEMORY_STAGING_FILE = File.join(CLAUDE_DIR, 'memory_staging.json')

  def memory_staging_file(project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd)
    File.join(project_dir, '.claude', 'memory_staging.json')
  end

  # MCP verification tools (read-only operations to prove connectivity)
  # NOTE: Official Memory MCP (@modelcontextprotocol/server-memory) is global, not project-verified
  MCP_VERIFICATION_INFO = {
    apple_docs: { name: 'Apple Docs', tool: 'mcp__apple-docs__search_apple_docs' },
    context7: { name: 'Context7', tool: 'mcp__context7__resolve-library-id' },
    github: { name: 'GitHub', tool: 'mcp__github__search_repositories' }
  }.freeze

  # Graceful-degradation threshold: how many times the MCP-verification gate
  # may block before treating still-unverified MCPs as unreachable this
  # session. The research gate auto-completes when an MCP is absent; this
  # mirrors that so a down/mis-scoped MCP cannot brick every edit.
  MCP_GATE_MAX_BLOCKS = 2

  def check_pending_mcp_actions(tool_name, edit_tools)
    return nil unless edit_tools.include?(tool_name)

    # Only enforce MCP verification for projects with .saneprocess manifest
    project_dir = ENV['CLAUDE_PROJECT_DIR'] || Dir.pwd
    return nil unless File.exist?(File.join(project_dir, '.saneprocess'))

    configured_mcps = configured_mcp_verification_info(project_dir)

    # Also check for memory staging (pending MCP action)
    pending_actions = []
    staging_file = memory_staging_file(project_dir)
    if File.exist?(staging_file)
      begin
        staging = JSON.parse(File.read(staging_file, encoding: Encoding::UTF_8))
        if staging['needs_memory_update']
          entity_name = staging.dig('suggested_entity', 'name') || 'learnings'
          pending_actions << "Memory staging needs saving: #{entity_name}"
        end
      rescue StandardError
        pending_actions << 'Memory staging file needs review'
      end
    end

    if pending_actions.any?
      return "MCP ACTIONS PENDING\n" \
             "Cannot edit until pending MCP/memory actions are handled.\n" \
             "#{pending_actions.map { |a| "  ⚠️  #{a}" }.join("\n")}\n" \
             "\n" \
             "Use the memory MCP to save the staged learning, then remove #{staging_file}."
    end

    return nil if configured_mcps.empty?

    # Get MCP health state
    health = StateManager.get(:mcp_health)

    # If all verified, allow edits
    return nil if health[:verified_this_session]

    # Check which MCPs are still unverified
    mcps = health[:mcps] || {}
    unverified = configured_mcps.select do |key, _info|
      mcp_data = mcps[key]
      !mcp_data || !mcp_data[:verified]
    end

    # If all verified (but flag not set), allow and fix state
    if unverified.empty?
      StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
      return nil
    end

    # Graceful degradation: a configured MCP that never connects this session
    # (down, mis-scoped, or removed) must not brick every edit. Count gate
    # blocks; once past the threshold, treat the still-unverified MCPs as
    # unreachable, allow edits, and warn once so the user can reconnect them.
    block_attempts = (health[:gate_block_attempts] || 0) + 1
    StateManager.update(:mcp_health) { |h| h[:gate_block_attempts] = block_attempts; h }
    if block_attempts > MCP_GATE_MAX_BLOCKS
      names = unverified.map { |_key, info| info[:name] }.join(', ')
      warn "⚠️  MCP verification degraded: #{names} unreachable after " \
           "#{MCP_GATE_MAX_BLOCKS} attempt(s) — allowing edits. " \
           "Reconnect/check MCPs in the active client, then rerun the session start."
      StateManager.update(:mcp_health) do |h|
        h[:verified_this_session] = true
        h[:degraded] = true
        h
      end
      return nil
    end

    # Build comprehensive error message
    total_mcps = configured_mcps.length
    verified_count = total_mcps - unverified.length
    unverified_list = unverified.map do |key, info|
      "  ⬜ #{info[:name]}: #{info[:tool]}"
    end.join("\n")

    msg = "MCP VERIFICATION INCOMPLETE [#{verified_count}/#{total_mcps} verified]\n" \
          "Cannot edit until all #{total_mcps} configured MCPs are verified this session.\n" \
          "\n" \
          "Unverified MCPs (run each tool once to verify):\n" \
          "#{unverified_list}\n"

    msg += "\nCall each unverified MCP tool once to proceed."
    msg
  end

end
