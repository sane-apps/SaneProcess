# frozen_string_literal: true

# ==============================================================================
# SaneTrack Self-Tests (extracted from sanetrack.rb)
# ==============================================================================

require 'open3'
require_relative 'core/state_manager'

module SaneTrackTest
  def self.run(process_result_proc, detect_actual_failure_proc, normalize_error_proc,
               check_tautologies_proc, invalidate_empty_research_proc, source_file)
    warn 'SaneTrack Self-Test'
    warn '=' * 40

    # Reset state
    StateManager.reset(:edits)
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) { |e| e[:halted] = false; e[:blocks] = []; e }

    passed = 0
    failed = 0

    # Test 1: Track edit
    process_result_proc.call('Edit', { 'file_path' => '/test/file1.swift' }, { 'success' => true })
    edits = StateManager.get(:edits)
    if edits[:count] == 1 && edits[:unique_files].include?('/test/file1.swift')
      passed += 1
      warn '  PASS: Edit tracking'
    else
      failed += 1
      warn '  FAIL: Edit tracking'
    end

    # Test 2: Track multiple edits to same file
    process_result_proc.call('Edit', { 'file_path' => '/test/file1.swift' }, { 'success' => true })
    edits = StateManager.get(:edits)
    if edits[:count] == 2 && edits[:unique_files].length == 1
      passed += 1
      warn '  PASS: Unique file tracking'
    else
      failed += 1
      warn '  FAIL: Unique file tracking'
    end

    # Test 3: Track failure
    process_result_proc.call('Bash', {}, { 'error' => 'command not found' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:failures] == 1
      passed += 1
      warn '  PASS: Failure tracking'
    else
      failed += 1
      warn '  FAIL: Failure tracking'
    end

    # Test 4: Reset failure on success
    process_result_proc.call('Bash', {}, { 'output' => 'success' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:failures] == 0
      passed += 1
      warn '  PASS: Failure reset on success'
    else
      failed += 1
      warn '  FAIL: Failure reset on success'
    end

    # Test 5: Circuit breaker trips at 3 failures
    StateManager.reset(:circuit_breaker)
    process_result_proc.call('Bash', {}, { 'error' => 'fail 1' })
    process_result_proc.call('Bash', {}, { 'error' => 'fail 2' })
    process_result_proc.call('Bash', {}, { 'error' => 'fail 3' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:tripped]
      passed += 1
      warn '  PASS: Circuit breaker trips at 3 failures'
    else
      failed += 1
      warn '  FAIL: Circuit breaker should trip at 3 failures'
    end

    # === INTELLIGENCE TESTS ===

    # Test 6: Error signature normalization
    StateManager.reset(:circuit_breaker)
    sig1 = normalize_error_proc.call('ruby: command not found')
    sig2 = normalize_error_proc.call('bash: npm: command not found')
    if sig1 == 'COMMAND_NOT_FOUND' && sig2 == 'COMMAND_NOT_FOUND'
      passed += 1
      warn '  PASS: Error signature normalization (COMMAND_NOT_FOUND)'
    else
      failed += 1
      warn "  FAIL: Expected COMMAND_NOT_FOUND, got #{sig1}, #{sig2}"
    end

    # Test 7: Per-signature trip (3x same with successes between)
    StateManager.reset(:circuit_breaker)
    process_result_proc.call('Bash', {}, { 'error' => 'command not found: ruby' })
    process_result_proc.call('Bash', {}, { 'output' => 'success' })  # Success resets legacy, not signature
    process_result_proc.call('Bash', {}, { 'error' => 'command not found: npm' })
    process_result_proc.call('Bash', {}, { 'output' => 'success' })  # Success again
    process_result_proc.call('Bash', {}, { 'error' => 'command not found: python' })
    cb = StateManager.get(:circuit_breaker)
    if cb[:tripped] && cb[:error_signatures] && cb[:error_signatures][:COMMAND_NOT_FOUND] == 3
      passed += 1
      warn '  PASS: Per-signature trip at 3x same (with successes between)'
    else
      failed += 1
      warn "  FAIL: Per-signature trip - tripped=#{cb[:tripped]}, signatures=#{cb[:error_signatures]}"
    end

    # Test 8: Action log for learning
    StateManager.update(:action_log) { |_| [] }  # Initialize empty
    process_result_proc.call('Edit', { 'file_path' => '/test/file.swift' }, { 'success' => true })
    process_result_proc.call('Bash', { 'command' => 'ruby test.rb' }, { 'error' => 'syntax error' })
    log = StateManager.get(:action_log)
    if log.is_a?(Array) && log.length >= 2
      first = log[-2]  # Second to last (Edit)
      last = log[-1]   # Last (Bash with error)
      if first && last && first[:tool] == 'Edit' && last[:error_sig] == 'SYNTAX_ERROR'
        passed += 1
        warn '  PASS: Action log for learning'
      else
        failed += 1
        warn "  FAIL: Action log content - first=#{first}, last=#{last}"
      end
    else
      failed += 1
      warn "  FAIL: Action log - got #{log.inspect[0..100]}"
    end

    # === Q2 VALIDATION: DOOM LOOP TRACKING ===
    warn ''
    warn 'Testing doom loop validation tracking:'

    # Test: Breaker trip on repeated signature increments doom_loops_caught
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:validation)
    process_result_proc.call('Bash', {}, { 'error' => 'permission denied on /etc/hosts' })
    process_result_proc.call('Bash', {}, { 'output' => 'ok' })
    process_result_proc.call('Bash', {}, { 'error' => 'access denied to file' })
    process_result_proc.call('Bash', {}, { 'output' => 'ok' })
    process_result_proc.call('Bash', {}, { 'error' => 'not permitted to write' })
    validation = StateManager.get(:validation)
    if validation[:doom_loops_caught] == 1
      passed += 1
      warn '  PASS: Doom loop caught on 3x same signature'
    else
      failed += 1
      warn "  FAIL: Expected doom_loops_caught=1, got #{validation[:doom_loops_caught]}"
    end

    # Test: Breaker trip on 3 consecutive failures also counts
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:validation)
    process_result_proc.call('Bash', {}, { 'error' => 'fail 1' })
    process_result_proc.call('Bash', {}, { 'error' => 'fail 2' })
    process_result_proc.call('Bash', {}, { 'error' => 'fail 3' })
    validation = StateManager.get(:validation)
    if validation[:doom_loops_caught] >= 1
      passed += 1
      warn '  PASS: Doom loop caught on 3 consecutive failures'
    else
      failed += 1
      warn "  FAIL: Expected doom_loops_caught>=1, got #{validation[:doom_loops_caught]}"
    end

    # === JSON INTEGRATION TESTS ===
    warn ''
    warn 'Testing JSON parsing (integration):'

    # Test valid JSON with success response
    json_input = '{"tool_name":"Edit","tool_input":{"file_path":"/test/integrated.swift"},"tool_response":{"success":true}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Valid JSON parsed correctly (exit 0)'
    else
      failed += 1
      warn "  FAIL: Valid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test JSON with error response (still returns 0 - PostToolUse is tracking only)
    json_input = '{"tool_name":"Bash","tool_input":{"command":"test"},"tool_response":{"error":"command failed"}}'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Error response still returns exit 0 (PostToolUse is passive)'
    else
      failed += 1
      warn "  FAIL: PostToolUse should always exit 0, got #{status.exitstatus}"
    end

    # Test invalid JSON doesn't crash
    json_input = 'this is not valid json'
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Invalid JSON returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Invalid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test empty input doesn't crash
    _stdout, _stderr, status = Open3.capture3("ruby #{source_file}", stdin_data: '')
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Empty input returns exit 0 (fail safe)'
    else
      failed += 1
      warn "  FAIL: Empty input should return exit 0, got #{status.exitstatus}"
    end

    # === DETECT ACTUAL FAILURE TESTS ===
    warn ''
    warn 'Testing failure detection (no false positives):'

    # Test: Read file content with error-like text is NOT a failure
    result = detect_actual_failure_proc.call('Read', { 'content' => 'def handle_error: raise TypeError' })
    if result.nil?
      passed += 1
      warn '  PASS: Read file content with error text is not a failure'
    else
      failed += 1
      warn "  FAIL: Read content should not be flagged - got #{result}"
    end

    # Test: Bash with non-zero exit code IS a failure
    result = detect_actual_failure_proc.call('Bash', { 'exit_code' => 1, 'stdout' => '' })
    if result == 'COMMAND_FAILED'
      passed += 1
      warn '  PASS: Bash non-zero exit code is a failure'
    else
      failed += 1
      warn "  FAIL: Expected COMMAND_FAILED, got #{result.inspect}"
    end

    # Test: MCP tool success is not a failure
    result = detect_actual_failure_proc.call('mcp__memory__read_graph', { 'entities' => [] })
    if result.nil?
      passed += 1
      warn '  PASS: MCP success is not a failure'
    else
      failed += 1
      warn "  FAIL: MCP success should return nil, got #{result}"
    end

    # === TAUTOLOGY DETECTION TESTS (Rule #7) ===
    warn ''
    warn 'Testing tautology detection (Rule #7):'

    # Test: Detects #expect(true) in test file
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/MyTests.swift',
      'new_string' => '@Test func bad() { #expect(true) }'
    })
    if result&.include?('RULE #7 WARNING')
      passed += 1
      warn '  PASS: Detects #expect(true) in test file'
    else
      failed += 1
      warn "  FAIL: Should detect tautology, got #{result.inspect}"
    end

    # Test: Ignores tautology in non-test file
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Sources/Main.swift',
      'new_string' => 'let x = true; #expect(true)'
    })
    if result.nil?
      passed += 1
      warn '  PASS: Ignores tautology in non-test file'
    else
      failed += 1
      warn "  FAIL: Should ignore non-test file, got #{result.inspect}"
    end

    # Test: Allows real assertions
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/ValidTests.swift',
      'new_string' => '@Test func good() { #expect(result == 42) }'
    })
    if result.nil?
      passed += 1
      warn '  PASS: Allows real assertions in test file'
    else
      failed += 1
      warn "  FAIL: Real assertion should be allowed, got #{result.inspect}"
    end

    # === RESEARCH OUTPUT VALIDATION TESTS ===
    warn ''
    warn 'Testing research output validation:'

    # Test: Empty research output gets invalidated
    StateManager.update(:research) do |r|
      r[:web] = { completed_at: Time.now.iso8601, tool: 'WebSearch', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('WebSearch', { 'content' => 'no results found' })
    research_after = StateManager.get(:research)
    if research_after[:web].nil?
      passed += 1
      warn '  PASS: Empty research output invalidated (web)'
    else
      failed += 1
      warn "  FAIL: Empty research should be invalidated, got #{research_after[:web].inspect}"
    end

    # Test: Meaningful research output is kept
    StateManager.update(:research) do |r|
      r[:local] = { completed_at: Time.now.iso8601, tool: 'Read', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('Read', { 'content' => 'class StateManager\n  def get(section)\n    ...' })
    research_after = StateManager.get(:research)
    if research_after[:local]
      passed += 1
      warn '  PASS: Meaningful research output kept (local)'
    else
      failed += 1
      warn '  FAIL: Meaningful research should be kept'
    end

    # Test: Zero-result count gets invalidated
    StateManager.update(:research) do |r|
      r[:github] = { completed_at: Time.now.iso8601, tool: 'mcp__github__search_repositories', via_task: false }
      r
    end
    invalidate_empty_research_proc.call('mcp__github__search_repositories', { 'content' => '0 matches' })
    research_after = StateManager.get(:research)
    if research_after[:github].nil?
      passed += 1
      warn '  PASS: Zero-result research invalidated (github)'
    else
      failed += 1
      warn "  FAIL: Zero-result research should be invalidated"
    end

    # === CLEANUP: Reset circuit breaker only (don't reset research - breaks normal ops) ===
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) { |e| e[:halted] = false; e[:blocks] = []; e }

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
end
