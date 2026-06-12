#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'verify_failure_review'

class VerifyFailureReviewHarness
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::VerifyFailureReview

  def initialize(path)
    @path = path
  end

  def process_metrics_path
    @path
  end

  def project_name
    'SaneProcess'
  end
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

exit(run_tests('SaneMaster Verify Failure Review Tests') do
  test_category('zero-test failure drilldown') do
    test('clusters explicit and inferred zero-test failure buckets') do
      events = [
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => false, 'tests_run' => 0, 'failure_bucket' => 'timeout', 'reason' => 'verify timeout' },
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => false, 'tests_run' => 0, 'reason' => 'verify timeout after 300s' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => false, 'tests_run' => 0, 'failure_hint' => 'permission prompt blocked Accessibility' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => false, 'tests_run' => 0, 'reason' => '** BUILD FAILED ** error:' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => true, 'tests_run' => 0, 'evidence_strength' => 'build_only' },
        { 'type' => 'verify', 'project' => 'SaneClick', 'success' => false, 'tests_run' => 3, 'failure_bucket' => 'test_failure' }
      ]

      subject = VerifyFailureReviewHarness.new('/tmp/verify-failure-review-test.jsonl')
      result = subject.send(:build_verify_failure_review, events, min_count: 1)
      buckets = result[:buckets].each_with_object({}) { |bucket, memo| memo[bucket[:bucket]] = bucket }

      assert_eq(result[:verify_attempts], 6)
      assert_eq(result[:zero_test_failures], 4)
      assert_eq(result[:weak_green_successes], 1)
      assert_eq(buckets['timeout'][:count], 2)
      assert_eq(buckets['permission_prompt'][:count], 1)
      assert_eq(buckets['build_failure'][:count], 1)
      assert_eq(buckets['timeout'][:projects]['SaneBar'], 2)
      assert_eq(result[:hotspots].first[:project], 'SaneBar')
      assert_eq(result[:hotspots].first[:bucket], 'timeout')
      assert_eq(result[:hotspots].first[:count], 2)
      assert_includes(result[:recommended_actions].join(' '), 'Fix the top zero-test bucket first: timeout')
      assert_includes(result[:recommended_actions].join(' '), 'SaneBar / timeout')
      true
    end

    test('reads JSONL fixtures and ignores harness-generated process test rows by default') do
      Dir.mktmpdir('verify-failure-review-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        rows = [
          { type: 'verify', project: 'SaneBar', success: false, tests_run: 0, failure_bucket: 'timeout' },
          { type: 'verify', project: 'near-miss-review-fixture', success: false, tests_run: 0, failure_bucket: 'timeout' },
          { type: 'verify', project: 'SaneClip', success: true, tests_run: 12 },
          'not-json'
        ]
        File.write(path, rows.map { |row| row.is_a?(Hash) ? JSON.generate(row) : row }.join("\n") + "\n")

        subject = VerifyFailureReviewHarness.new('/tmp/verify-failure-review-unused.jsonl')
        result = nil
        capture_stdout do
          result = subject.verify_failure_review(['--json', '--metrics', path, '--all', '--min-count', '1'])
        end

        assert_eq(result[:verify_attempts], 2)
        assert_eq(result[:zero_test_failures], 1)
        assert_eq(result[:buckets].first[:projects]['SaneBar'], 1)
      end
      true
    end

    test('reports clean counted verification without false action pressure') do
      events = [
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => true, 'tests_run' => 42 },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => false, 'tests_run' => 3, 'failure_bucket' => 'test_failure' }
      ]

      subject = VerifyFailureReviewHarness.new('/tmp/verify-failure-review-test.jsonl')
      result = subject.send(:build_verify_failure_review, events, min_count: 1)

      assert_eq(result[:zero_test_failures], 0)
      assert_eq(result[:weak_green_successes], 0)
      assert_eq(result[:buckets], [])
      assert_includes(result[:recommended_actions].join(' '), 'No repeated zero-test failure bucket met the threshold')
      true
    end
  end
end)
