#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneStop Test Suite
# ==============================================================================
# Extracted from sanestop.rb per Rule #10 (file size limit)
# Run: ruby sanestop.rb --self-test
# ==============================================================================

require 'stringio'
require_relative 'core/state_manager'

module SaneStopTest
  def self.run(process_stop_proc, check_score_variance_proc, check_weasel_words_proc, log_file)
    warn 'SaneStop Self-Test'
    warn '=' * 40

    # Reset state
    StateManager.reset(:edits)
    StateManager.reset(:research)
    StateManager.reset(:circuit_breaker)

    passed = 0
    failed = 0

    # Test 1: No edits = no reminder
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: No edits -> allow stop'
    else
      failed += 1
      warn '  FAIL: Should allow stop with no edits'
    end

    # Test 2: With edits + NO verification = BLOCK (Rule #4)
    StateManager.update(:edits) do |e|
      e[:count] = 5
      e[:unique_files] = ['/a.swift', '/b.swift', '/c.swift']
      e
    end
    StateManager.reset(:verification)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 2
      passed += 1
      warn '  PASS: Edits without verification -> BLOCK (exit 2)'
    else
      failed += 1
      warn "  FAIL: Should block unverified edits, got exit #{exit_code}"
    end

    # Test 2b: With edits + verification = allow stop
    StateManager.update(:verification) do |v|
      v[:tests_run] = true
      v[:last_test_at] = Time.now.iso8601
      v[:test_commands] = ['xcodebuild test']
      v
    end

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Edits with verification -> allow stop'
    else
      failed += 1
      warn "  FAIL: Verified edits should allow stop, got exit #{exit_code}"
    end

    # Test 2c: Doc-only edits = allow stop without verification
    StateManager.update(:edits) do |e|
      e[:count] = 2
      e[:unique_files] = ['/docs/README.md', '/CHANGELOG.md']
      e
    end
    StateManager.reset(:verification)

    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    exit_code = process_stop_proc.call(false)
    $stderr.reopen(original_stderr)

    if exit_code == 0
      passed += 1
      warn '  PASS: Doc-only edits -> allow stop without verification'
    else
      failed += 1
      warn "  FAIL: Doc-only edits should allow stop, got exit #{exit_code}"
    end

    # Test 3: stop_hook_active = skip processing
    exit_code = process_stop_proc.call(true)
    if exit_code == 0
      passed += 1
      warn '  PASS: stop_hook_active -> skip processing'
    else
      failed += 1
      warn '  FAIL: Should skip when stop_hook_active'
    end

    # Test 4: Session logging works
    if File.exist?(log_file)
      last_line = File.readlines(log_file).last
      entry = JSON.parse(last_line)
      if entry['edits'].is_a?(Integer)
        passed += 1
        warn '  PASS: Session logging'
      else
        failed += 1
        warn '  FAIL: Session logging incorrect'
      end
    else
      failed += 1
      warn '  FAIL: Log file not created'
    end

    # === SCORE VARIANCE DETECTION TESTS ===
    warn ''
    warn 'Testing score variance detection:'

    # Test: Low variance + high mean fires warning
    StateManager.update(:patterns) do |p|
      p[:session_scores] = [9, 9, 9, 9, 9, 9]
      p
    end
    original_stderr = $stderr.clone
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_score_variance_proc.call(9)
    $stderr = original_stderr
    if captured_stderr.string.include?('SCORE VARIANCE WARNING')
      passed += 1
      warn '  PASS: Score variance fires on suspicious consistency'
    else
      failed += 1
      warn '  FAIL: Score variance should warn on all-9s'
    end

    # Test: Normal variance passes silently
    StateManager.update(:patterns) do |p|
      p[:session_scores] = [6, 8, 7, 9, 5, 8]
      p
    end
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_score_variance_proc.call(7)
    $stderr = original_stderr
    if !captured_stderr.string.include?('SCORE VARIANCE WARNING')
      passed += 1
      warn '  PASS: Normal variance passes silently'
    else
      failed += 1
      warn '  FAIL: Normal variance should not warn'
    end

    # === WEASEL WORD DETECTION TESTS ===
    warn ''
    warn 'Testing weasel word detection:'

    StateManager.update(:action_log) do |_|
      [
        { tool: 'Edit', input_summary: 'used tools to fix various issues', success: true },
        { tool: 'Edit', input_summary: 'made changes and followed process', success: true },
        { tool: 'Edit', input_summary: 'cleaned up some code etc', success: true }
      ]
    end
    captured_stderr = StringIO.new
    $stderr = captured_stderr
    check_weasel_words_proc.call
    $stderr = original_stderr
    if captured_stderr.string.include?('WEASEL WORD WARNING')
      passed += 1
      warn '  PASS: Weasel word detection fires on vague language'
    else
      failed += 1
      warn '  FAIL: Weasel words should be detected'
    end

    # Cleanup
    StateManager.update(:action_log) { |_| [] }
    StateManager.update(:patterns) { |p| p[:session_scores] = []; p }

    # === Q4 VALIDATION: SESSION TRACKING TESTS ===
    warn ''
    warn 'Testing validation metrics (Q1/Q4):'

    # Reset for clean test
    StateManager.reset(:validation)
    StateManager.reset(:edits)
    StateManager.reset(:verification)
    StateManager.reset(:circuit_breaker)
    StateManager.update(:enforcement) { |e| e[:blocks] = []; e }

    # Test: Session end increments sessions_total
    original_stderr = $stderr.clone
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    validation = StateManager.get(:validation)
    if validation[:sessions_total] == 1
      passed += 1
      warn '  PASS: sessions_total incremented on session end'
    else
      failed += 1
      warn "  FAIL: Expected sessions_total=1, got #{validation[:sessions_total]}"
    end

    # Test: Session with tests marks sessions_with_tests_passing
    StateManager.update(:verification) do |v|
      v[:tests_run] = true
      v[:last_test_at] = Time.now.iso8601
      v
    end
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    validation = StateManager.get(:validation)
    if validation[:sessions_with_tests_passing] == 1
      passed += 1
      warn '  PASS: sessions_with_tests_passing incremented when tests ran'
    else
      failed += 1
      warn "  FAIL: Expected sessions_with_tests_passing=1, got #{validation[:sessions_with_tests_passing]}"
    end

    # Test: Session with tripped breaker tracks sessions_with_breaker_trip
    StateManager.update(:circuit_breaker) do |cb|
      cb[:tripped] = true
      cb[:tripped_at] = Time.now.iso8601
      cb
    end
    $stderr.reopen('/dev/null', 'w')
    process_stop_proc.call(false)
    $stderr.reopen(original_stderr)
    validation = StateManager.get(:validation)
    if validation[:sessions_with_breaker_trip] == 1
      passed += 1
      warn '  PASS: sessions_with_breaker_trip incremented'
    else
      failed += 1
      warn "  FAIL: Expected sessions_with_breaker_trip=1, got #{validation[:sessions_with_breaker_trip]}"
    end

    # Test: first_tracked and last_updated are set
    if validation[:first_tracked] && validation[:last_updated]
      passed += 1
      warn '  PASS: Timestamps set (first_tracked, last_updated)'
    else
      failed += 1
      warn "  FAIL: Timestamps missing: first=#{validation[:first_tracked]}, last=#{validation[:last_updated]}"
    end

    # Cleanup validation state
    StateManager.reset(:validation)
    StateManager.reset(:circuit_breaker)
    StateManager.reset(:verification)

    # === JSON INTEGRATION TESTS ===
    warn ''
    warn 'Testing JSON parsing (integration):'

    require 'open3'

    # Reset state for integration tests
    StateManager.reset(:edits)
    StateManager.reset(:verification)

    script_path = File.expand_path('sanestop.rb', __dir__)

    # Test valid JSON (no edits = exit 0)
    json_input = '{"stop_hook_active":false}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: Valid JSON parsed correctly (exit 0)'
    else
      failed += 1
      warn "  FAIL: Valid JSON should return exit 0, got #{status.exitstatus}"
    end

    # Test JSON with stop_hook_active = true
    json_input = '{"stop_hook_active":true}'
    _stdout, _stderr, status = Open3.capture3("ruby #{script_path}", stdin_data: json_input)
    if status.exitstatus == 0
      passed += 1
      warn '  PASS: stop_hook_active=true skips processing (exit 0)'
    else
      failed += 1
      warn "  FAIL: stop_hook_active=true should exit 0, got #{status.exitstatus}"
    end

    # Test invalid JSON doesn't crash
    json_input = 'definitely not json'
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
