#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# Verify two-strike escalation tests
# ==============================================================================
# The two-strike rule escalates on repeated failures of the SAME problem. It
# used to count ANY two failures, so an iterate-on-red session (fix one
# pre-existing failure, surface the next) kept re-arming the gate — it
# certifier-self-flagged unfair on 2026-07-07 after three overrides. These
# tests lock the fix: a changed failing-test fingerprint restarts the streak;
# a repeated or unknown fingerprint still escalates.
# ==============================================================================

require 'json'
require 'time'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'sop_loop'
require_relative 'verify'

class VerifyEscalationHarness
  include SaneMasterModules::SOPLoop
  include SaneMasterModules::Verify
end

include TestFramework

def with_state_dir
  Dir.mktmpdir('verify-escalation-') do |dir|
    Dir.chdir(dir) { yield VerifyEscalationHarness.new }
  end
end

exit(run_tests('Verify Escalation Tests') do
  test_category('failure fingerprint') do
    test('failing-test lines produce a stable fingerprint') do
      h = VerifyEscalationHarness.new
      a = h.verify_failure_fingerprint("ok\n  ❌ test one failed\nFAILED (failures=1)\n")
      b = h.verify_failure_fingerprint("noise differs\n  ❌ test one failed\nFAILED (failures=1)\n")
      assert_eq(a, b)
      assert(!a.nil?, 'fingerprint should not be nil when failures are present')
    end

    test('different failing tests produce different fingerprints') do
      h = VerifyEscalationHarness.new
      a = h.verify_failure_fingerprint("❌ test one failed\n")
      b = h.verify_failure_fingerprint("❌ test two failed\n")
      assert(a != b, 'distinct failures must not collide')
    end

    test('no failure markers yields nil (unknown problem)') do
      h = VerifyEscalationHarness.new
      assert_eq(nil, h.verify_failure_fingerprint("all good\n1000 tests passed\n"))
    end

    test('survives invalid encodings') do
      h = VerifyEscalationHarness.new
      raw = "❌ boom\n\xFFbinary noise\n".dup.force_encoding(Encoding::BINARY)
      assert(!h.verify_failure_fingerprint(raw).nil?)
    end
  end

  test_category('two-strike streak semantics') do
    test('same fingerprint twice escalates') do
      with_state_dir do |h|
        h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: 'aaaa')
        state = h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: 'aaaa')
        assert_eq(2, state[:consecutive_failures])
        assert(!state[:escalated_at].nil?, 'same problem twice must escalate')
      end
    end

    test('changed fingerprint restarts the streak instead of escalating') do
      with_state_dir do |h|
        h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: 'aaaa')
        state = h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: 'bbbb')
        assert_eq(1, state[:consecutive_failures])
        assert_eq(nil, state[:escalated_at])
      end
    end

    test('unknown fingerprint keeps the conservative escalation') do
      with_state_dir do |h|
        h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: nil)
        state = h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: nil)
        assert_eq(2, state[:consecutive_failures])
        assert(!state[:escalated_at].nil?)
      end
    end

    test('success clears the streak and the stored fingerprint') do
      with_state_dir do |h|
        h.record_verify_attempt(success: false, message: 'verify failure', fingerprint: 'aaaa')
        state = h.record_verify_attempt(success: true, message: 'verify')
        assert_eq(0, state[:consecutive_failures])
        assert_eq(nil, state[:last_failure_fingerprint])
        assert_eq(nil, state[:escalated_at])
      end
    end
  end
end)
