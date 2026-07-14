# frozen_string_literal: true

require 'time'
require_relative 'core/state_manager'

# Focused SaneTrack self-tests for bare and plugin-prefixed MCP tool tracking.
module SaneTrackMcpVerificationTest
  def self.run(process_result_proc, invalidate_empty_research_proc)
    passed = 0
    failed = 0

    warn ''
    warn 'Testing MCP verification tracking (bare + plugin-loaded prefixes):'

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__context7__resolve-library-id', {}, { 'content' => 'Library ID: /vercel/next.js' })
    health = StateManager.get(:mcp_health)
    if health[:mcps] && health[:mcps][:context7] && health[:mcps][:context7][:verified]
      passed += 1
      warn '  PASS: bare context7 tool marks context7 verified'
    else
      failed += 1
      warn "  FAIL: bare context7 tool should verify context7, got #{health.inspect[0..150]}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_context7_context7__resolve-library-id', {}, { 'content' => 'Library ID: /vercel/next.js' })
    health = StateManager.get(:mcp_health)
    if health[:mcps] && health[:mcps][:context7] && health[:mcps][:context7][:verified]
      passed += 1
      warn '  PASS: plugin-loaded context7 tool marks context7 verified'
    else
      failed += 1
      warn "  FAIL: plugin-loaded context7 tool should verify context7, got #{health.inspect[0..150]}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_apple-docs_apple-docs__search_apple_docs', {}, { 'content' => 'FileManager documentation found' })
    process_result_proc.call('mcp__plugin_gh-tools_github__search_repositories', {}, { 'content' => 'Found 3 repositories' })
    health = StateManager.get(:mcp_health)
    apple_ok = health[:mcps] && health[:mcps][:apple_docs] && health[:mcps][:apple_docs][:verified]
    github_ok = health[:mcps] && health[:mcps][:github] && health[:mcps][:github][:verified]
    if apple_ok && github_ok
      passed += 1
      warn '  PASS: plugin-loaded apple-docs/github tools mark their MCPs verified'
    else
      failed += 1
      warn "  FAIL: plugin-loaded apple-docs/github should verify, got apple=#{apple_ok.inspect} github=#{github_ok.inspect}"
    end

    StateManager.reset(:mcp_health)
    process_result_proc.call('mcp__plugin_serena_serena__read_memory', {}, { 'content' => 'memory body with details' })
    health = StateManager.get(:mcp_health)
    verified_any = (health[:mcps] || {}).any? { |_mcp, data| data[:verified] }
    if !verified_any
      passed += 1
      warn '  PASS: unrelated plugin MCP tool verifies nothing'
    else
      failed += 1
      warn "  FAIL: unrelated plugin tool should verify nothing, got #{health.inspect[0..150]}"
    end

    # Plugin-prefixed research tools must still be revoked on empty output.
    StateManager.update(:research) do |research|
      research[:github] = {
        completed_at: Time.now.iso8601,
        tool: 'mcp__plugin_gh-tools_github__search_repositories',
        via_task: false
      }
      research
    end
    invalidate_empty_research_proc.call(
      'mcp__plugin_gh-tools_github__search_repositories',
      { 'content' => '0 matches' }
    )
    research_after = StateManager.get(:research)
    if research_after[:github].nil?
      passed += 1
      warn '  PASS: plugin-loaded github empty result invalidates research'
    else
      failed += 1
      warn "  FAIL: plugin-loaded github empty result should invalidate research, got #{research_after[:github].inspect}"
    end

    [passed, failed]
  end
end
