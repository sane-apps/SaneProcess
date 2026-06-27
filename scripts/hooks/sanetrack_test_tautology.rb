#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneTrack Self-Test — Tautology Detection (Rule #7)
# ==============================================================================
# Extracted from sanetrack_test.rb per Rule #10 (file size limit). Reopens
# SaneTrackTest with one section runner; returns [passed, failed] so the main
# run() accumulates the counts.
# ==============================================================================

module SaneTrackTest
  def self.run_tautology_tests(check_tautologies_proc)
    passed = 0
    failed = 0

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

    # Test: Detects mock-passthrough (handler set up, assertion only checks mock)
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/BadTests.swift',
      'new_string' => <<~SWIFT
        @Test func testHidden() {
            mockSearch.cachedHiddenAppsHandler = { return [app1, app2] }
            let result = mockSearch.cachedHiddenApps()
            #expect(result.count == 2)
        }
      SWIFT
    })
    if result&.include?('RULE #7 WARNING') && result&.match?(/[Mm]ock/)
      passed += 1
      warn '  PASS: Detects mock-passthrough test'
    else
      failed += 1
      warn "  FAIL: Should detect mock-passthrough, got #{result.inspect}"
    end

    # Test: Allows tests that use real objects (not mock-passthrough)
    result = check_tautologies_proc.call('Edit', {
      'file_path' => '/path/Tests/GoodTests.swift',
      'new_string' => <<~SWIFT
        @Test func classifiesZone() {
            let zone = service.classifyZone(itemX: 200, itemWidth: 22, separatorX: 500, alwaysHiddenSeparatorX: nil)
            #expect(zone == .hidden)
        }
      SWIFT
    })
    if result.nil?
      passed += 1
      warn '  PASS: Allows real service call test'
    else
      failed += 1
      warn "  FAIL: Real service test should be allowed, got #{result.inspect}"
    end

    [passed, failed]
  end
end
