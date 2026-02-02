#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTools Test Suite
# ==============================================================================
# Extracted from sanetools.rb per Rule #10 (file size limit)
# Run: ruby sanetools.rb --self-test
# ==============================================================================

require_relative 'core/state_manager'

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
        sanemem_check: true, orphan_cleanup: true, system_clean: true
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
        sanemem_check: true,
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
        sanemem_check: true, orphan_cleanup: true, system_clean: true
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
        sanemem_check: true, orphan_cleanup: true, system_clean: true
      }
      g
    end
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)

    # === DEPLOYMENT SAFETY TESTS ===
    warn ''
    warn 'Testing deployment safety:'

    # Setup: clean state for deployment tests
    StateManager.reset(:research)
    StateManager.reset(:planning)
    StateManager.reset(:edit_attempts)
    StateManager.reset(:deployment)
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd }
    StateManager.update(:requirements) { |r| r[:is_big_task] = false; r[:is_research_only] = false; r[:requested] = []; r[:satisfied] = []; r }
    StateManager.update(:startup_gate) do |g|
      g[:open] = true; g[:opened_at] = Time.now.iso8601
      g[:steps] = { session_docs: true, skills_registry: true, validation_report: true, sanemem_check: true, orphan_cleanup: true, system_clean: true }
      g
    end
    research_categories.keys.each do |cat|
      StateManager.update(:research) { |r| r[cat] = { completed_at: Time.now.iso8601, tool: 'test', via_task: false }; r }
    end

    # Test 1: R2 upload with wrong bucket → BLOCKED
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', {
      'command' => 'npx wrangler r2 object put saneclick-dist/SaneClick-1.0.2.dmg --file="build/SaneClick-1.0.2.dmg"'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: R2 upload with wrong bucket blocked'
    else
      failed += 1
      warn "  FAIL: R2 upload with wrong bucket should block, got exit #{exit_code}"
    end

    # Test 2: R2 upload with path prefix in key → BLOCKED
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', {
      'command' => 'npx wrangler r2 object put sanebar-downloads/updates/SaneBar-1.0.17.dmg --file="build/SaneBar-1.0.17.dmg"'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: R2 upload with path prefix in key blocked'
    else
      failed += 1
      warn "  FAIL: R2 upload with path prefix should block, got exit #{exit_code}"
    end

    # Test 3: Correct R2 upload (signed + stapled) → ALLOWED
    # First, simulate that the DMG was signed and stapled
    StateManager.update(:deployment) do |d|
      d[:sparkle_signed_dmgs] = ['SaneBar-1.0.17.dmg']
      d[:staple_verified_dmgs] = ['SaneBar-1.0.17.dmg']
      d
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    # Use a non-existent file path so staple check falls through to state lookup
    exit_code = process_tool_proc.call('Bash', {
      'command' => 'npx wrangler r2 object put sanebar-downloads/SaneBar-1.0.17.dmg --file="/nonexistent/SaneBar-1.0.17.dmg"'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Correct R2 upload allowed (signed + stapled)'
    else
      failed += 1
      warn "  FAIL: Correct R2 upload should be allowed, got exit #{exit_code}"
    end

    # Test 4: R2 upload without Sparkle signature → BLOCKED
    StateManager.reset(:deployment)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', {
      'command' => 'npx wrangler r2 object put sanebar-downloads/SaneBar-1.0.17.dmg --file="/nonexistent/SaneBar-1.0.17.dmg"'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: R2 upload without Sparkle signature blocked'
    else
      failed += 1
      warn "  FAIL: R2 upload without signature should block, got exit #{exit_code}"
    end

    # Test 5: Appcast edit with empty edSignature → BLOCKED
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', {
      'file_path' => '/Users/sj/SaneApps/apps/SaneBar/docs/appcast.xml',
      'old_string' => 'old content',
      'new_string' => '<enclosure url="https://dist.sanebar.com/SaneBar-1.0.17.dmg" edSignature="" length="12345" />'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Appcast edit with empty edSignature blocked'
    else
      failed += 1
      warn "  FAIL: Appcast edit with empty signature should block, got exit #{exit_code}"
    end

    # Test 6: Appcast edit with GitHub URL → BLOCKED
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', {
      'file_path' => '/Users/sj/SaneApps/apps/SaneBar/docs/appcast.xml',
      'old_string' => 'old content',
      'new_string' => '<enclosure url="https://github.com/user/repo/releases/download/v1.0/SaneBar.dmg" edSignature="abc123" length="12345" />'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Appcast edit with GitHub URL blocked'
    else
      failed += 1
      warn "  FAIL: Appcast edit with GitHub URL should block, got exit #{exit_code}"
    end

    # Test 7: Valid appcast edit → ALLOWED
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Edit', {
      'file_path' => '/Users/sj/SaneApps/apps/SaneBar/docs/appcast.xml',
      'old_string' => 'old content',
      'new_string' => '<enclosure url="https://dist.sanebar.com/SaneBar-1.0.17.dmg" edSignature="validSig123==" length="12345" />'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Valid appcast edit allowed'
    else
      failed += 1
      warn "  FAIL: Valid appcast edit should be allowed, got exit #{exit_code}"
    end

    # Test 8: Pages deploy with bad appcast → BLOCKED
    # Create a temp directory with a bad appcast for this test
    require 'tmpdir'
    test_deploy_dir = Dir.mktmpdir('deploy_test')
    File.write(File.join(test_deploy_dir, 'appcast.xml'), '<enclosure edSignature="" />')

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_tool_proc.call('Bash', {
      'command' => "npx wrangler pages deploy #{test_deploy_dir} --project-name=sanebar-site"
    })
    $stderr.reopen(original_stderr)

    # Cleanup temp dir
    FileUtils.rm_rf(test_deploy_dir) rescue nil

    if exit_code == 2
      passed += 1
      warn '  PASS: Pages deploy with bad appcast blocked'
    else
      failed += 1
      warn "  FAIL: Pages deploy with bad appcast should block, got exit #{exit_code}"
    end

    # Cleanup deployment tests
    StateManager.reset(:deployment)
    StateManager.reset(:edit_attempts)

    # === JSON INTEGRATION TESTS ===
    warn ''
    warn 'Testing JSON parsing (integration):'

    require 'open3'
    script_path = File.expand_path('sanetools.rb', __dir__)

    # Test valid JSON with tool_name and tool_input
    json_input = '{"tool_name":"Read","tool_input":{"file_path":"/Users/sj/SaneProcess/test.swift"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Valid JSON parsed correctly (Read tool allowed)'
    else
      failed += 1
      warn "  FAIL: Valid JSON parsing - exit #{status.exitstatus}"
    end

    # Test blocked path via JSON
    json_input = '{"tool_name":"Read","tool_input":{"file_path":"~/.ssh/id_rsa"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 2
      passed += 1
      warn '  PASS: Blocked path correctly blocked via JSON'
    else
      failed += 1
      warn "  FAIL: Blocked path should return exit 2, got #{status.exitstatus}"
    end

    # Test invalid JSON doesn't crash
    json_input = 'not valid json at all'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Invalid JSON returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test empty input doesn't crash
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: '')
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Empty input returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Empty input should return exit 0, got #{status.exitstatus}"
    end

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
