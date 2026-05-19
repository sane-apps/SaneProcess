#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../test/test_framework'
require_relative 'sop_score'

include TestFramework

exit(run_tests('SaneProcess SOP Score Tests') do
  test_category('shared scorer') do
    test('scores block friction with the shared rubric') do
      assert_eq(SaneSOPScore.base_score(0), 10)
      assert_eq(SaneSOPScore.base_score(2), 9)
      assert_eq(SaneSOPScore.base_score(4), 8)
      assert_eq(SaneSOPScore.base_score(7), 7)
      assert_eq(SaneSOPScore.base_score(10), 6)
      assert_eq(SaneSOPScore.base_score(11), 5)
      true
    end

    test('caps recovered verification failures at 8 with a reason') do
      receipt = SaneSOPScore.score(
        block_count: 0,
        verify_status: { attempts: 2, failures: 1, last_success: true }
      )

      assert_eq(receipt[:score], 8)
      assert_eq(receipt[:base_score], 10)
      assert_eq(receipt[:cap_reason], 'recovered_verify_failure')
      true
    end

    test('caps unrecovered verification failures at 6 with a reason') do
      receipt = SaneSOPScore.score(
        block_count: 0,
        verify_status: { attempts: 1, failures: 1, last_success: false }
      )

      assert_eq(receipt[:score], 6)
      assert_eq(receipt[:cap_score], 6)
      assert_eq(receipt[:cap_reason], 'unrecovered_verify_failure')
      true
    end

    test('caps green zero-test verification as weak evidence') do
      receipt = SaneSOPScore.score(
        block_count: 0,
        verify_status: { attempts: 1, failures: 0, last_success: true, last_tests_run: 0 }
      )

      assert_eq(receipt[:score], 8)
      assert_eq(receipt[:cap_score], 8)
      assert_eq(receipt[:cap_reason], 'zero_test_success_weak_evidence')
      true
    end

    test('does not cap clean counted verification') do
      receipt = SaneSOPScore.score(
        block_count: 0,
        verify_status: { attempts: 1, failures: 0, last_success: true, last_tests_run: 12 }
      )

      assert_eq(receipt[:score], 10)
      assert_eq(receipt[:cap_score], nil)
      assert_eq(receipt[:cap_reason], nil)
      true
    end
  end
end)
