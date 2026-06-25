#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'core/state_manager'
require_relative 'sanetools_test_scenarios'

module SaneToolsGateTest
  def self.run(process_tool_proc, research_categories)
    passed = 0
    failed = 0
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Bash', { 'command' => 'npm install express' })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Non-startup Bash blocked before gate opens'
    else
      failed += 1
      warn "  FAIL: Non-startup Bash should be blocked before gate opens, got exit #{exit_code}"
    end

    # Test (Fix #1c): the documented unblock path — a hook --reset/--status/
    # --self-test command — must run even while the startup gate is closed.
    # Previously the gate blocked it, so a wedged session had no working reset.
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('Bash', { 'command' => 'ruby scripts/hooks/sanetools.rb --reset' })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Hook --reset unblock command allowed even while startup gate is closed'
    else
      failed += 1
      warn "  FAIL: Hook --reset should be allowed during startup gate, got exit #{exit_code}"
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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

    approval_flag = '/tmp/.gh_post_approved.json'
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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

    # Test 2: Allow post with fresh structured approval for exact body
    approved_body = 'I fixed this in v2.1.6.'
    File.write(
      approval_flag,
      JSON.generate(
        'created_at' => Time.now.to_i,
        'user_approval' => 'post it',
        'body_hash' => Digest::SHA256.hexdigest(approved_body)
      )
    )
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'sane-apps',
      'repo' => 'SaneBar',
      'issue_number' => 1,
      'body' => approved_body
    })
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: GitHub post with approval allowed'
    else
      failed += 1
      warn "  FAIL: GitHub post with approval should pass, got exit #{exit_code}"
    end

    # Test 2b: Block if approval body does not match final text
    File.write(
      approval_flag,
      JSON.generate(
        'created_at' => Time.now.to_i,
        'user_approval' => 'post it',
        'body_hash' => Digest::SHA256.hexdigest('I fixed this in v2.1.6.')
      )
    )
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    exit_code = process_tool_proc.call('mcp__github__add_issue_comment', {
      'owner' => 'sane-apps',
      'repo' => 'SaneBar',
      'issue_number' => 1,
      'body' => 'Different final text.'
    })
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: GitHub post with mismatched approval body blocked'
    else
      failed += 1
      warn "  FAIL: GitHub mismatched approval should block, got exit #{exit_code}"
    end

    # Test 3: Block corporate "we" language even with approval
    corporate_body = 'We fixed this and our team verified it.'
    File.write(
      approval_flag,
      JSON.generate(
        'created_at' => Time.now.to_i,
        'user_approval' => 'post it',
        'body_hash' => Digest::SHA256.hexdigest(corporate_body)
      )
    )
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
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

    # === WEB SEARCH RESEARCH CATEGORY MAPPING ===
    warn ''
    warn 'Testing WebSearch research category mapping:'

    StateManager.reset(:research)
    process_tool_proc.call('WebSearch', { 'query' => 'github mcp server real-world code examples' })
    ws_research = StateManager.get(:research)
    if ws_research[:github] && ws_research[:web]
      passed += 1
      warn '  PASS: github-focused WebSearch satisfies github (and web) research'
    else
      failed += 1
      warn "  FAIL: github WebSearch should satisfy github research, got web=#{!ws_research[:web].nil?} github=#{!ws_research[:github].nil?}"
    end

    StateManager.reset(:research)
    process_tool_proc.call('WebSearch', { 'query' => 'swift concurrency best practices' })
    ws_research = StateManager.get(:research)
    if ws_research[:web] && ws_research[:github].nil?
      passed += 1
      warn '  PASS: generic WebSearch satisfies only web, not github'
    else
      failed += 1
      warn "  FAIL: generic WebSearch should not satisfy github, got web=#{!ws_research[:web].nil?} github=#{!ws_research[:github].nil?}"
    end

    # === MCP VERIFICATION GRACEFUL DEGRADATION ===
    warn ''
    warn 'Testing MCP verification graceful degradation:'

    deg_project_dir = File.join(Dir.pwd, '.sanetools-test')
    FileUtils.rm_rf(deg_project_dir) if Dir.exist?(deg_project_dir)
    FileUtils.mkdir_p(deg_project_dir)
    codex_config_dir = File.join(deg_project_dir, '.codex')
    claude_config_dir = File.join(deg_project_dir, '.claude')
    gemini_config_dir = File.join(deg_project_dir, '.gemini')
    grok_config_dir = File.join(deg_project_dir, '.grok')
    codex_config = File.join(codex_config_dir, 'config.toml')
    claude_settings = File.join(claude_config_dir, 'settings.json')
    gemini_settings = File.join(gemini_config_dir, 'settings.json')
    grok_config = File.join(grok_config_dir, 'config.toml')

    FileUtils.mkdir_p(codex_config_dir)
    FileUtils.mkdir_p(claude_config_dir)
    FileUtils.mkdir_p(gemini_config_dir)
    FileUtils.mkdir_p(grok_config_dir)
    File.write(codex_config, "[mcp_servers.context7]\ncommand = \"context7\"\n")
    File.write(claude_settings, '{"permissions":{"allow":["mcp__apple-docs__*"]}}')
    File.write(gemini_settings, '{"mcpServers":{"github":{}}}')
    File.write(grok_config, "[mcp_servers.github]\ncommand = \"github\"\n[mcp_servers.github.env]\nTOKEN = \"redacted\"\n")
    configured_keys = SaneToolsChecks.configured_mcp_keys(deg_project_dir)
    configured_names = SaneToolsChecks.configured_mcp_server_names(deg_project_dir)
    if configured_keys.include?(:apple_docs) && configured_keys.include?(:context7) &&
       configured_keys.include?(:github) && !configured_names.include?('github.env')
      passed += 1
      warn '  PASS: MCP discovery reads active Claude, Codex, Gemini, and Grok client configs'
    else
      failed += 1
      warn "  FAIL: MCP discovery missed client configs, got keys=#{configured_keys.inspect} names=#{configured_names.inspect}"
    end
    deg_mcp_config = File.join(deg_project_dir, '.mcp.json')
    File.write(deg_mcp_config, '{"mcpServers":{"github":{},"apple-docs":{}}}')
    File.write(File.join(deg_project_dir, '.saneprocess'), "name: SaneToolsTest\n")
    StateManager.update(:mcp_health) do |h|
      h[:verified_this_session] = false
      h[:degraded] = false
      h[:gate_block_attempts] = 0
      h[:mcps] = { apple_docs: { verified: true }, github: { verified: false } }
      h
    end

    old_project_dir = ENV['CLAUDE_PROJECT_DIR']
    ENV['CLAUDE_PROJECT_DIR'] = deg_project_dir
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w') unless ENV['SANE_TEST_DEBUG']
    deg_results = nil
    Dir.chdir(deg_project_dir) do
      deg_results = Array.new(3) { SaneToolsChecks.check_pending_mcp_actions('Edit', %w[Edit Write]) }
    end
    $stderr.reopen(original_stderr)
    ENV['CLAUDE_PROJECT_DIR'] = old_project_dir

    if !deg_results[0].nil? && !deg_results[1].nil? && deg_results[2].nil?
      passed += 1
      warn '  PASS: Unreachable MCP blocks twice then degrades (allows edits)'
    else
      failed += 1
      warn "  FAIL: Expected [block, block, allow], got #{deg_results.map { |r| r.nil? ? 'allow' : 'block' }.inspect}"
    end

    mcp_pending_reason = "MCP ACTIONS PENDING\nCannot edit until pending MCP/memory actions are handled."
    if detect_rule_from_reason(mcp_pending_reason) == 'mcp_actions_pending'
      passed += 1
      warn '  PASS: MCP actions pending block records a specific rule'
    else
      failed += 1
      warn "  FAIL: MCP actions pending block should not be recorded as unknown, got #{detect_rule_from_reason(mcp_pending_reason).inspect}"
    end

    StateManager.reset(:refusal_tracking)
    SaneToolsChecks.check_refusal_to_read('Edit', mcp_pending_reason)
    tracking = StateManager.get(:refusal_tracking)
    if tracking.key?(:mcp_actions_pending) || tracking.key?('mcp_actions_pending')
      passed += 1
      warn '  PASS: MCP actions pending refusal tracking uses a specific bucket'
    else
      failed += 1
      warn "  FAIL: MCP actions pending refusal tracking should not use other, got #{tracking.keys.inspect}"
    end

    repeat_message = SaneToolsChecks.check_refusal_to_read('Edit', mcp_pending_reason)
    if repeat_message.to_s.include?('SAME BLOCK TWICE: mcp_actions_pending') &&
       repeat_message.to_s.include?('Resolve the pending MCP/memory action') &&
       !repeat_message.to_s.include?('Each block message told you')
      passed += 1
      warn '  PASS: Repeated blocks use compact remedial message'
    else
      failed += 1
      warn "  FAIL: Repeated block message should be compact, got #{repeat_message.inspect}"
    end

    FileUtils.rm_rf(deg_project_dir) if Dir.exist?(deg_project_dir)
    StateManager.update(:mcp_health) do |h|
      h[:verified_this_session] = true
      h[:degraded] = false
      h[:gate_block_attempts] = 0
      h
    end

    # === REFUSAL TRACKER ISOLATION (Fix #1) ===
    warn ''
    warn 'Testing refusal tracker isolation:'

    # #1a: a non-specific block ('other') is never tracked and never escalates,
    # so unrelated gates can't pool into one counter that then MASKS the reason.
    StateManager.reset(:refusal_tracking)
    unmatched = "TABLE BLOCKED: markdown tables are not allowed here"
    m1 = SaneToolsChecks.check_refusal_to_read('Edit', unmatched)
    m2 = SaneToolsChecks.check_refusal_to_read('Edit', unmatched)
    other_tracking = StateManager.get(:refusal_tracking)
    if m1.nil? && m2.nil? && !other_tracking.key?(:other) && !other_tracking.key?('other')
      passed += 1
      warn '  PASS: non-specific block is never tracked or escalated as "other"'
    else
      failed += 1
      warn "  FAIL: 'other' block should not track/escalate, got #{m2.inspect} / #{other_tracking.keys.inspect}"
    end

    # #1b: the repeat note never contains the old accusatory/masking language.
    StateManager.reset(:refusal_tracking)
    research_reason = "RESEARCH INCOMPLETE [0/4 complete: missing docs, web, github, local]"
    SaneToolsChecks.check_refusal_to_read('Edit', research_reason)
    repeat = SaneToolsChecks.check_refusal_to_read('Edit', research_reason).to_s
    if repeat.include?('research_incomplete') && !repeat.include?('REFUSAL TO READ DETECTED')
      passed += 1
      warn '  PASS: repeat note is a compact remedy, not an accusatory "REFUSAL TO READ"'
    else
      failed += 1
      warn "  FAIL: repeat note should be compact and non-accusatory, got #{repeat.inspect}"
    end

    # #1c: a stale counter (e.g. left by a finished subagent long ago) decays
    # instead of instantly ambushing a later, unrelated block with escalation.
    StateManager.reset(:refusal_tracking)
    StateManager.update(:refusal_tracking) do |b|
      b[:research_incomplete] = { count: 12, last_tool: 'Edit',
                                  last_at: (Time.now - SaneToolsRefusal::REFUSAL_DECAY_SECONDS - 60).iso8601 }
      b
    end
    decay_msg = SaneToolsChecks.check_refusal_to_read('Edit', research_reason)
    decayed = StateManager.get(:refusal_tracking)[:research_incomplete]
    if decay_msg.nil? && decayed[:count] == 1
      passed += 1
      warn '  PASS: stale repeat counter decays to a fresh count (no instant escalation)'
    else
      failed += 1
      warn "  FAIL: stale counter should decay to 1 with no message, got #{decay_msg.inspect} / #{decayed.inspect}"
    end

    # === --reset CLEARS REFUSAL, PRESERVES RESEARCH (Fix #2) ===
    warn ''
    warn 'Testing --reset semantics:'
    StateManager.update(:refusal_tracking) { |b| b[:research_incomplete] = { count: 5 }; b }
    StateManager.reset(:research)
    StateManager.update(:research) { |r| r[:local] = { tool: 'Read', via_task: false }; r }
    # perform_reset is a top-level method defined in sanetools.rb (loaded for the
    # self-test), available as a private method on every object including here.
    perform_reset
    after_refusal = StateManager.get(:refusal_tracking)
    after_research = StateManager.get(:research)
    if (after_refusal.nil? || after_refusal.empty?) && after_research[:local]
      passed += 1
      warn '  PASS: --reset clears the refusal tracker but preserves research evidence'
    else
      failed += 1
      warn "  FAIL: --reset should clear refusal + keep research, got refusal=#{after_refusal.inspect} research=#{after_research.inspect}"
    end

    # === SUBAGENT POISON NO LONGER MASKS/BLOCKS THE ORCHESTRATOR (Fix #4) ===
    # A subagent that retried the research gate used to drive the SHARED refusal
    # counter to double digits, so the orchestrator's very next block surfaced as
    # an escalated "REFUSAL TO READ" that replaced the real reason. Now the
    # counter only appends a compact note and never changes the decision, so the
    # orchestrator always sees its true block reason.
    warn ''
    warn 'Testing subagent refusal poison is defused:'
    StateManager.update(:startup_gate) do |g|
      g[:open] = true
      g[:steps] = { session_docs: true, skills_registry: true, validation_report: true,
                    orphan_cleanup: true, system_clean: true }
      g
    end
    StateManager.update(:mcp_health) { |h| h[:verified_this_session] = true; h }
    StateManager.update(:session_docs) { |sd| sd[:required] = []; sd[:read] = []; sd[:enforced] = false; sd }
    StateManager.reset(:research) # orchestrator research incomplete -> real reason is RESEARCH INCOMPLETE
    StateManager.update(:refusal_tracking) do |b|
      b[:research_incomplete] = { count: 20, last_tool: 'Edit', last_at: Time.now.iso8601 }
      b
    end

    require 'tempfile'
    captured = Tempfile.new('sane-poison')
    begin
      original_stderr = $stderr.clone
      $stderr.reopen(captured.path, 'w')
      exit_code = process_tool_proc.call('Edit', { 'file_path' => '/Users/sj/SaneProcess/test.swift', 'old_string' => 'a', 'new_string' => 'b' })
      $stderr.flush
      $stderr.reopen(original_stderr)
      captured.rewind
      stderr_text = File.read(captured.path)
    ensure
      captured.close!
    end

    if exit_code == 2 &&
       stderr_text.include?('RESEARCH INCOMPLETE') &&
       !stderr_text.include?('REFUSAL TO READ DETECTED')
      passed += 1
      warn '  PASS: poisoned counter does not mask the real reason or change the block decision'
    else
      failed += 1
      warn "  FAIL: orchestrator block should show real reason, got exit #{exit_code}, masked=#{stderr_text.include?('REFUSAL TO READ DETECTED')}"
    end

    # === STARTUP GATE DEGRADES INSTEAD OF DEADLOCKING (unsatisfiable gate) ===
    warn ''
    warn 'Testing startup gate degradation:'
    StateManager.update(:startup_gate) do |g|
      g[:open] = false
      g[:degraded] = false
      g[:block_attempts] = SaneToolsStartup::STARTUP_GATE_MAX_BLOCKS
      g[:steps] = { session_docs: false, skills_registry: true, validation_report: true,
                    orphan_cleanup: true, system_clean: true }
      g
    end
    degrade_msg = SaneToolsStartup.check_startup_gate('Edit', { 'file_path' => '/tmp/x/y.swift' })
    gate_after = StateManager.get(:startup_gate)
    if degrade_msg.nil? && gate_after[:open] && gate_after[:degraded]
      passed += 1
      warn '  PASS: startup gate degrades (opens) after repeated blocks instead of deadlocking'
    else
      failed += 1
      warn "  FAIL: startup gate should degrade past #{SaneToolsStartup::STARTUP_GATE_MAX_BLOCKS} blocks, got msg=#{degrade_msg.inspect} open=#{gate_after[:open]} degraded=#{gate_after[:degraded]}"
    end
    StateManager.update(:startup_gate) { |g| g[:block_attempts] = 0; g[:degraded] = false; g }

    # === RULE #10 GRANDFATHERING (oversized files stay editable) ===
    warn ''
    warn 'Testing Rule #10 grandfathering:'
    require 'tempfile'
    # A file already over the 800-line hard limit must accept a small bug-fix edit
    # (warn, not block) — you can't fix or split a big file without editing it.
    over = Tempfile.new(['rule10-over', '.rb'])
    over.write(("# line\n" * 1200))
    over.flush
    add_lines = "anchor\nnew1\nnew2\nnew3\n"
    over_result = SaneToolsChecks.check_file_size('Edit', { 'file_path' => over.path, 'old_string' => 'anchor', 'new_string' => add_lines }, %w[Edit Write NotebookEdit])
    # A within-limit file that an edit pushes OVER the limit must still be blocked.
    under = Tempfile.new(['rule10-under', '.rb'])
    under.write(("# line\n" * 790))
    under.flush
    crossing = "anchor\n" + ("x\n" * 30)
    under_result = SaneToolsChecks.check_file_size('Edit', { 'file_path' => under.path, 'old_string' => 'anchor', 'new_string' => crossing }, %w[Edit Write NotebookEdit])
    if over_result.nil? && under_result.to_s.include?('FILE SIZE BLOCKED')
      passed += 1
      warn '  PASS: oversized file stays editable; only a within-limit file crossing 800 is blocked'
    else
      failed += 1
      warn "  FAIL: Rule #10 grandfathering wrong — over=#{over_result.inspect} under=#{under_result.inspect}"
    end
    over.close!
    under.close!

    # === CLEANUP ===
    StateManager.reset(:research)
    StateManager.reset(:refusal_tracking)
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:sensitive_approvals)
    StateManager.update(:enforcement) do |e|
      e[:halted] = false
      e[:blocks] = []
      e
    end


      [passed, failed]
    end
  end
