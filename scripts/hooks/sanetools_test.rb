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
require_relative 'sanetools_gate_test'
require 'fileutils'
require 'json'

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

    # === MINI-FIRST LOCAL UI GUARD TEST ===
    warn ''
    warn 'Testing Mini-first local UI guard:'

    old_force_air = ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST']
    old_force_mini = ENV['SANE_FORCE_MAC_MINI_FOR_TEST']
    old_local_approval = ENV['SANE_APPROVE_LOCAL_UI_ON_AIR']
    old_mini_unavailable = ENV['SANE_MINI_UNAVAILABLE']

    ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] = '1'
    ENV.delete('SANE_FORCE_MAC_MINI_FOR_TEST')
    ENV.delete('SANE_APPROVE_LOCAL_UI_ON_AIR')
    ENV.delete('SANE_MINI_UNAVAILABLE')

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('mcp__computer_use__get_app_state', { 'app' => 'Safari' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: computer-use blocks on MacBook Air'
    else
      failed += 1
      warn "  FAIL: computer-use should block on MacBook Air, got exit #{exit_code}"
    end

    ENV.delete('SANE_FORCE_MACBOOK_AIR_FOR_TEST')
    ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] = '1'

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('mcp__computer_use__get_app_state', { 'app' => 'Safari' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: computer-use allowed when running on Mini'
    else
      failed += 1
      warn "  FAIL: computer-use should be allowed on Mini, got exit #{exit_code}"
    end

    ENV['SANE_FORCE_MACBOOK_AIR_FOR_TEST'] = old_force_air
    ENV['SANE_FORCE_MAC_MINI_FOR_TEST'] = old_force_mini
    ENV['SANE_APPROVE_LOCAL_UI_ON_AIR'] = old_local_approval
    ENV['SANE_MINI_UNAVAILABLE'] = old_mini_unavailable

    # === CANONICAL ACTION PATH TEST ===
    warn ''
    warn 'Testing canonical action path guard:'

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Bash', { 'command' => "ssh mini 'screencapture -x /tmp/sanebar.png'" })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: raw Mini screencapture is blocked'
    else
      failed += 1
      warn "  FAIL: raw Mini screencapture should be blocked, got exit #{exit_code}"
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call(
      'Bash',
      { 'command' => '~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh --app "SaneBar" --mode temp' }
    )
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: canonical Mini screenshot wrapper is allowed'
    else
      failed += 1
      warn "  FAIL: canonical Mini screenshot wrapper should be allowed, got exit #{exit_code}"
    end

    # === SECRET STARTUP AUTOLOAD GUARD TEST ===
    warn ''
    warn 'Testing secret startup autoload guard:'

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', {
      'file_path' => File.expand_path('~/.zshenv'),
      'old_string' => '# empty',
      'new_string' => 'export CLOUDFLARE_API_TOKEN="$(security find-generic-password -s cloudflare -a api_token -w 2>/dev/null)"'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: shell startup secret autoload is blocked'
    else
      failed += 1
      warn "  FAIL: shell startup secret autoload should block, got exit #{exit_code}"
    end

    # === CIRCUIT BREAKER TEST ===
    warn ''
    warn 'Testing circuit breaker:'

    # Trip the circuit breaker
    StateManager.update(:circuit_breaker) do |cb|
      cb[:tripped] = true
      cb[:failures] = 2
      cb[:last_error] = 'Test error'
      cb
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Circuit breaker blocks edits when tripped'
    else
      failed += 1
      warn '  FAIL: Circuit breaker should block when tripped'
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    read_exit = process_tool_proc.call('Read', { 'file_path' => '/Users/sj/SaneApps/infra/SaneProcess/README.md' })
    grep_exit = process_tool_proc.call('Grep', { 'pattern' => 'Circuit breaker' })
    web_exit = process_tool_proc.call('WebSearch', { 'query' => 'ruby circuit breaker pattern' })
    $stderr.reopen(original_stderr)

    if [read_exit, grep_exit, web_exit].all?(&:zero?)
      passed += 1
      warn '  PASS: Circuit breaker still allows research tools'
    else
      failed += 1
      warn "  FAIL: Circuit breaker should allow research tools, got Read=#{read_exit} Grep=#{grep_exit} WebSearch=#{web_exit}"
    end

    StateManager.update(:circuit_breaker) do |cb|
      cb[:tripped] = true
      cb[:failures] = 0
      cb[:error_signatures] = { COMMAND_NOT_FOUND: 2 }
      cb[:last_error] = 'COMMAND_NOT_FOUND x2'
      cb
    end
    message = SaneToolsChecks.check_circuit_breaker
    if message.include?('same signature 2x') && !message.include?('0 consecutive failures')
      passed += 1
      warn '  PASS: Signature-trip breaker message avoids 0 consecutive failures copy'
    else
      failed += 1
      warn "  FAIL: Signature-trip breaker message should name same signature, got #{message.inspect}"
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    quoted_pipe_exit = process_tool_proc.call('Bash', { 'command' => "grep -R 'foo|bar' scripts/hooks" })
    $stderr.reopen(original_stderr)
    if quoted_pipe_exit == 0
      passed += 1
      warn '  PASS: Breaker recovery allows quoted grep pipe patterns'
    else
      failed += 1
      warn "  FAIL: Quoted grep pipe should not block breaker recovery, got exit #{quoted_pipe_exit}"
    end

    # Reset circuit breaker for remaining tests
    StateManager.reset(:circuit_breaker)

    # === BASH FILE WRITE BYPASS TEST ===
    warn ''
    warn 'Testing bash file write bypass:'

    # Ensure research is incomplete
    StateManager.reset(:research)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
      $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']

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
      $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Plan approval unblocks edits'
    else
      failed += 1
      warn "  FAIL: Plan approval should unblock edits, got exit #{exit_code}"
    end

    # Test: Successful edits do not trigger re-planning loops
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift' })
    $stderr.reopen(original_stderr)

    planning_after = StateManager.get(:planning)
    if exit_code == 0 && planning_after[:plan_approved] == true && planning_after[:replan_count].to_i.zero?
      passed += 1
      warn '  PASS: Successful edit history does not trigger re-planning'
    else
      failed += 1
      warn "  FAIL: Successful edit history should not replan - exit=#{exit_code}, approved=#{planning_after[:plan_approved]}, replan=#{planning_after[:replan_count]}"
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
      s[:runner_proved] = false
      s[:runner_commands] = []
      s
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
        s[:runner_proved] = false
        s[:runner_commands] = []
        s
      end

      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
      $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/Sources/App.swift' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Normal .swift file not affected by sensitive check'
    else
      failed += 1
      warn "  FAIL: Normal .swift file should not be blocked, got exit #{exit_code}"
    end

    scenario_passed, scenario_failed = SaneToolsTestScenarios.run_structure_guard_tests(process_tool_proc)
    passed += scenario_passed
    failed += scenario_failed

    # === TABLE BAN TESTS ===
    warn ''
    warn 'Testing table ban markdown exemption:'

    table_markdown = "| Name | Value |\n| --- | --- |\n| Sane | Process |\n"
    [
      ['/Users/sj/SaneProcess/README.md', 'Markdown .md table allowed'],
      ['/Users/sj/SaneProcess/docs/release-notes.markdown', 'Markdown .markdown table allowed']
    ].each do |path, label|
      original_stderr = $stderr.clone
      $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
      exit_code = process_tool_proc.call('Edit', {
                                           'file_path' => path,
                                           'old_string' => '',
                                           'new_string' => table_markdown
                                         })
      $stderr.reopen(original_stderr)

      if exit_code == 0
        passed += 1
        warn "  PASS: #{label}"
      else
        failed += 1
        warn "  FAIL: #{label}, got exit #{exit_code}"
      end
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Edit', {
                                         'file_path' => '/Users/sj/SaneProcess/website/index.html',
                                         'old_string' => '',
                                         'new_string' => table_markdown
                                       })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Non-markdown table edit remains blocked'
    else
      failed += 1
      warn "  FAIL: Non-markdown table edit should block, got exit #{exit_code}"
    end

    # Cleanup
    StateManager.reset(:sensitive_approvals)
    StateManager.reset(:edit_attempts)

    gate_passed, gate_failed = SaneToolsGateTest.run(process_tool_proc, research_categories)
    passed += gate_passed
    failed += gate_failed
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
