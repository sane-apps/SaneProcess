#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Test Suite
# ==============================================================================
# Extracted from sanetools.rb per Rule #10 (file size limit)
# Run: ruby sanetools.rb --self-test
# ==============================================================================

require_relative 'core/state_manager'
require_relative 'core/mandatory_workflows'
require_relative 'sanetools_test_scenarios'

module SaneToolsTest
  def self.run(process_tool_proc, research_categories)
    warn 'SaneTools Self-Test'
    warn '=' * 40

    # Reset state for clean test
    StateManager.reset(:research)
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) do |e|
      e[:halted] = false
      e[:blocks] = []
      e
    end

    # Open startup gate for non-gate tests (gate tests will close it)
    StateManager.update(:startup_gate) do |g|
      g[:open] = true
      g[:opened_at] = Time.now.iso8601
      g[:steps] = {
        session_docs: true, skills_registry: true, validation_report: true,
        orphan_cleanup: true, system_clean: true
      }
      g
    end

    passed = 0
    failed = 0

    # === CIRCUIT BREAKER TEST ===
    warn ''
    warn 'Testing circuit breaker:'

    # Trip the circuit breaker
    StateManager.update(:circuit_breaker) do |cb|
      cb[:tripped] = true
      cb[:failures] = 5
      cb[:last_error] = 'Test error'
      cb
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Circuit breaker blocks edits when tripped'
    else
      failed += 1
      warn '  FAIL: Circuit breaker should block when tripped'
    end

    # Reset circuit breaker for remaining tests
    StateManager.reset(:circuit_breaker)

    # === BASH FILE WRITE BYPASS TEST ===
    warn ''
    warn 'Testing bash file write bypass:'

    # Ensure research is incomplete
    StateManager.reset(:research)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    # Use source file path (not /tmp/ which is in safe list)
    exit_code = process_tool_proc.call('Bash', { 'command' => 'echo "test" > ~/SaneProcess/src/file.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Bash file writes blocked to source files'
    else
      failed += 1
      warn '  FAIL: Bash file writes should be blocked to source files'
    end

    # === STANDARD TESTS ===
    warn ''
    warn 'Testing tool blocking:'

    tests = [
      # Blocked paths
      { tool: 'Read', input: { 'file_path' => '~/.ssh/id_rsa' }, expect_block: true, name: 'Block ~/.ssh/' },
      { tool: 'Edit', input: { 'file_path' => '/etc/passwd' }, expect_block: true, name: 'Block /etc/' },
      { tool: 'Write', input: { 'file_path' => '/var/log/test' }, expect_block: true, name: 'Block /var/' },

      # Edit without research (should block)
      { tool: 'Edit', input: { 'file_path' => '/Users/sj/SaneProcess/test.swift' }, expect_block: true, name: 'Block edit without research' },

      # Research tools (should allow and track)
      { tool: 'Read', input: { 'file_path' => '/Users/sj/SaneProcess/test.swift' }, expect_block: false, name: 'Allow Read (tracks local)' },
      { tool: 'Grep', input: { 'pattern' => 'test' }, expect_block: false, name: 'Allow Grep' },
      { tool: 'WebSearch', input: { 'query' => 'swift patterns' }, expect_block: false, name: 'Allow WebSearch (tracks web)' },

      # Task agents (should allow and track)
      { tool: 'Task', input: { 'prompt' => 'Search documentation for this API' }, expect_block: false, name: 'Allow Task (tracks docs)' },
      { tool: 'Task', input: { 'prompt' => 'Search GitHub for external examples' }, expect_block: false, name: 'Allow Task (tracks github)' }
    ]

    tests.each do |test|
      # Suppress output
      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')

      exit_code = process_tool_proc.call(test[:tool], test[:input])

      $stderr.reopen(original_stderr)

      blocked = exit_code == 2
      expected = test[:expect_block]

      if blocked == expected
        passed += 1
        warn "  PASS: #{test[:name]}"
      else
        failed += 1
        warn "  FAIL: #{test[:name]} - expected #{expected ? 'BLOCK' : 'ALLOW'}, got #{blocked ? 'BLOCK' : 'ALLOW'}"
      end
    end

    # Check research tracking
    research = StateManager.get(:research)
    tracked_count = research_categories.keys.count { |cat| research[cat] }

    warn ''
    warn "Research tracked: #{tracked_count}/4 categories"
    research.each do |cat, info|
      status = info ? "done (#{info[:tool]})" : 'pending'
      warn "  #{cat}: #{status}"
    end

    # Now edit should work (all research done)
    # Setup remaining state so this test actually runs (was always skipped before memory removal)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }

    if tracked_count == 4
      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
      $stderr.reopen(original_stderr)

      if exit_code == 0
        passed += 1
        warn '  PASS: Edit allowed after research'
      else
        failed += 1
        warn '  FAIL: Edit still blocked after research'
      end
    else
      warn '  SKIP: Not all research categories tracked'
    end

    # === PLANNING ENFORCEMENT TESTS ===
    warn ''
    warn 'Testing planning enforcement:'

    # Reset state for planning tests (must clear ALL blocking conditions)
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }

    # Test: Planning required blocks edits
    StateManager.update(:planning) { |p| p[:required] = true; p[:plan_approved] = false; p }
    # Complete all research so planning is the only blocker
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Planning required blocks edits'
    else
      failed += 1
      warn "  FAIL: Planning required should block edits, got exit #{exit_code}"
    end

    # Test: Planning required allows research tools
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Read', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Planning required allows Read'
    else
      failed += 1
      warn "  FAIL: Planning required should allow Read, got exit #{exit_code}"
    end

    # Test: Plan approval unblocks edits
    StateManager.update(:planning) { |p| p[:plan_approved] = true; p }

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Plan approval unblocks edits'
    else
      failed += 1
      warn "  FAIL: Plan approval should unblock edits, got exit #{exit_code}"
    end

    # Test: Edit limit triggers re-planning
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.reset(:research)
    StateManager.update(:planning) { |p| p[:required] = true; p[:plan_approved] = true; p }
    StateManager.update(:edit_attempts) { |a| a[:count] = 3; a }
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    # Research must be complete for edit limit to be the blocker
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    planning_after = StateManager.get(:planning)
    if exit_code == 2 && planning_after[:plan_approved] == false && planning_after[:replan_count] == 1
      passed += 1
      warn '  PASS: Edit limit triggers re-planning'
    else
      failed += 1
      warn "  FAIL: Edit limit replan - exit=#{exit_code}, approved=#{planning_after[:plan_approved]}, replan=#{planning_after[:replan_count]}"
    end

    # Cleanup planning tests
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.reset(:research)

    # === TOOL DISCOVERY ENFORCEMENT TESTS ===
    warn ''
    warn 'Testing tool discovery enforcement:'

    StateManager.reset(:skill)
    StateManager.reset(:research)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    StateManager.update(:skill) do |s|
      s[:required] = 'evolve'
      s[:required_prompt] = 'missing screenshot diff tool'
      s[:runner_used] = false
      s[:runner_commands] = []
      s
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Missing tool-discovery receipt blocks edits'
    else
      failed += 1
      warn "  FAIL: Missing tool-discovery receipt should block edits, got #{exit_code}"
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', { 'command' => 'ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: tool_discovery receipt command is allowed'
    else
      failed += 1
      warn "  FAIL: tool_discovery receipt command should be allowed, got #{exit_code}"
    end

    {
      'status' => 'ruby scripts/SaneMaster.rb status',
      'verify' => 'ruby scripts/SaneMaster.rb verify',
      'ship' => 'ruby scripts/SaneMaster.rb release_preflight',
      'check_inbox' => 'ruby scripts/SaneMaster.rb check_inbox'
    }.each do |workflow, runner_command|
      StateManager.reset(:skill)
      StateManager.update(:skill) do |s|
        s[:required] = workflow
        s[:required_prompt] = "workflow #{workflow}"
        s[:runner_used] = false
        s[:runner_commands] = []
        s
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
      $stderr.reopen(original_stderr)

      if exit_code == 2
        passed += 1
        warn "  PASS: Missing #{workflow} runner proof blocks edits"
      else
        failed += 1
        warn "  FAIL: Missing #{workflow} runner proof should block edits, got #{exit_code}"
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w')
      exit_code = process_tool_proc.call('Bash', { 'command' => runner_command })
      $stderr.reopen(original_stderr)

      if exit_code == 0
        passed += 1
        warn "  PASS: #{workflow} runner command is allowed"
      else
        failed += 1
        warn "  FAIL: #{workflow} runner command should be allowed, got #{exit_code}"
      end
    end

    StateManager.reset(:skill)

    # === SENSITIVE FILE PROTECTION TESTS ===
    warn ''
    warn 'Testing sensitive file protection:'

    # Setup: clean state, research done, plan approved, MCP verified
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.reset(:sensitive_approvals)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    # Test: First edit to .github/workflows blocks
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/.github/workflows/ci.yml' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: First edit to .github/workflows/ blocked'
    else
      failed += 1
      warn "  FAIL: First edit to .github/workflows/ should block, got exit #{exit_code}"
    end

    # Test: Retry same file passes (auto-approved)
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/.github/workflows/ci.yml' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Retry same workflow file allowed (auto-approved)'
    else
      failed += 1
      warn "  FAIL: Retry should allow after first block, got exit #{exit_code}"
    end

    # Test: Dockerfile blocks on first attempt
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Write', { 'file_path' => '/Users/sj/SaneProcess/Dockerfile', 'content' => 'FROM ruby:3.2' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: First edit to Dockerfile blocked'
    else
      failed += 1
      warn "  FAIL: First edit to Dockerfile should block, got exit #{exit_code}"
    end

    # Test: .entitlements blocks on first attempt
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/App.entitlements' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: First edit to .entitlements blocked'
    else
      failed += 1
      warn "  FAIL: First edit to .entitlements should block, got exit #{exit_code}"
    end

    # Test: Normal Swift file NOT blocked
    StateManager.reset(:sensitive_approvals)
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/Sources/App.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Normal .swift file not affected by sensitive check'
    else
      failed += 1
      warn "  FAIL: Normal .swift file should not be blocked, got exit #{exit_code}"
    end

    # Cleanup
    StateManager.reset(:sensitive_approvals)
    StateManager.reset(:edit_attempts)

    # === STARTUP GATE TESTS ===
    warn ''
    warn 'Testing startup gate enforcement:'

    # Setup: close the gate with pending steps
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    StateManager.update(:startup_gate) do |g|
      g[:open] = false
      g[:opened_at] = nil
      g[:steps] = {
        session_docs: true,
        skills_registry: true,
        validation_report: false,  # One pending step
        orphan_cleanup: true,
        system_clean: true
      }
      g[:step_timestamps] = {}
      g
    end

    # Test: Task blocked before gate opens
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Task', { 'prompt' => 'Search for something', 'subagent_type' => 'Explore' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Task blocked before startup gate opens'
    else
      failed += 1
      warn "  FAIL: Task should be blocked before gate opens, got exit #{exit_code}"
    end

    # Test: Read allowed before gate opens
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Read', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Read allowed before startup gate opens'
    else
      failed += 1
      warn "  FAIL: Read should be allowed before gate opens, got exit #{exit_code}"
    end

    # Test: Startup Bash (validation_report.rb) allowed before gate opens
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', { 'command' => 'ruby scripts/validation_report.rb' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Startup Bash (validation_report.rb) allowed before gate opens'
    else
      failed += 1
      warn "  FAIL: Startup Bash should be allowed before gate opens, got exit #{exit_code}"
    end

    # Test: Non-startup Bash blocked before gate opens
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', { 'command' => 'npm install express' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Non-startup Bash blocked before gate opens'
    else
      failed += 1
      warn "  FAIL: Non-startup Bash should be blocked before gate opens, got exit #{exit_code}"
    end

    # Test: All tools allowed after gate opens
    StateManager.update(:startup_gate) do |g|
      g[:open] = true
      g[:opened_at] = Time.now.iso8601
      g[:steps] = {
        session_docs: true, skills_registry: true, validation_report: true,
        orphan_cleanup: true, system_clean: true
      }
      g
    end
    # Complete research so edit isn't blocked for other reasons
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Edit allowed after startup gate opens'
    else
      failed += 1
      warn "  FAIL: Edit should be allowed after gate opens, got exit #{exit_code}"
    end

    # Cleanup startup gate tests
    StateManager.update(:startup_gate) do |g|
      g[:open] = true
      g[:opened_at] = Time.now.iso8601
      g[:steps] = {
        session_docs: true, skills_registry: true, validation_report: true,
        orphan_cleanup: true, system_clean: true
      }
      g
    end
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)

    # === GITHUB POST GUARD TESTS ===
    warn ''
    warn 'Testing GitHub post guard:'

    approval_flag = '/tmp/.gh_post_approved'
    File.delete(approval_flag) if File.exist?(approval_flag)

    # Setup: all non-GitHub guards satisfied
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    # Test 1: Block public GitHub post without approval
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'sane-apps',
      'repo' => 'SaneBar',
      'issue_number' => 1,
      'body' => 'I fixed this in the latest release.'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: GitHub post without approval blocked'
    else
      failed += 1
      warn "  FAIL: GitHub post without approval should block, got exit #{exit_code}"
    end

    # Test 2: Allow post with fresh approval flag
    FileUtils.touch(approval_flag)
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'sane-apps',
      'repo' => 'SaneBar',
      'issue_number' => 1,
      'body' => 'I fixed this in v2.1.6.'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: GitHub post with approval flag allowed'
    else
      failed += 1
      warn "  FAIL: GitHub post with approval flag should pass, got exit #{exit_code}"
    end

    # Test 3: Block corporate "we" language even with approval flag
    FileUtils.touch(approval_flag)
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'sane-apps',
      'repo' => 'SaneBar',
      'issue_number' => 1,
      'body' => 'We fixed this and our team verified it.'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Corporate language blocked for public GitHub post'
    else
      failed += 1
      warn "  FAIL: Corporate language should block, got exit #{exit_code}"
    end

    # Test 4: Non-SaneApps owner is not gated by this rule
    File.delete(approval_flag) if File.exist?(approval_flag)
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'octocat',
      'repo' => 'Hello-World',
      'issue_number' => 1,
      'body' => 'we can keep this wording in non-SaneApps repos'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Non-SaneApps GitHub post not blocked by Sane voice rule'
    else
      failed += 1
      warn "  FAIL: Non-SaneApps owner should bypass this guard, got exit #{exit_code}"
    end

    File.delete(approval_flag) if File.exist?(approval_flag)

    scenario_passed, scenario_failed = SaneToolsTestScenarios.run_deployment_safety_tests(process_tool_proc, research_categories)
    passed += scenario_passed
    failed += scenario_failed

    scenario_passed, scenario_failed = SaneToolsTestScenarios.run_json_integration_tests
    passed += scenario_passed
    failed += scenario_failed

    # === CLEANUP ===
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:sensitive_approvals)
    StateManager.update(:enforcement) do |e|
      e[:halted] = false
      e[:blocks] = []
      e
    end

    warn ''
    warn "#{passed}/#{passed + failed} tests passed"

    if failed == 0
      warn ''
      warn 'ALL TESTS PASSED'
      0
    else
      warn ''
      warn "#{failed} TESTS FAILED"
      1
    end
  end

  def self.show_status(research_categories)
    research = StateManager.get(:research)
    cb = StateManager.get(:circuit_breaker)
    enf = StateManager.get(:enforcement)

    warn 'SaneTools Status'
    warn '=' * 40

    warn ''
    warn 'Research:'
    research_categories.keys.each do |cat|
      info = research[cat]
      status = info ? "done (#{info[:tool]}, via_task=#{info[:via_task]})" : 'pending'
      warn "  #{cat}: #{status}"
    end

    warn ''
    warn 'Circuit Breaker:'
    warn "  failures: #{cb[:failures]}"
    warn "  tripped: #{cb[:tripped]}"

    warn ''
    warn 'Enforcement:'
    warn "  halted: #{enf[:halted]}"
    warn "  blocks: #{enf[:blocks]&.length || 0}"

    0
  end

  def self.reset_state
    StateManager.reset(:research)
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) do |e|
      e[:halted] = false
      e[:blocks] = []
      e
    end
    warn 'State reset'
    0
  end
end
