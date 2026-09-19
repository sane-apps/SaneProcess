#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'verify_failure_review'
require_relative 'verify'
require_relative 'diagnostics'

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
  test_category('Current run diagnostic artifacts') do
    test('failed phase retains its exact result bundle and command log') do
      harness = Object.new.extend(SaneMasterModules::Verify)
      phases = [
        { label: 'unit', cmd: ['unit'], xcresult_path: '/fixture/unit.xcresult', log_path: '/fixture/unit.log' },
        { label: 'ui', cmd: ['ui'], xcresult_path: '/fixture/ui.xcresult', log_path: '/fixture/ui.log' }
      ]
      harness.define_singleton_method(:run_verify_preflight) {}
      harness.define_singleton_method(:build_test_commands) { |*_args, **_options| phases }
      harness.define_singleton_method(:cleanup_test_processes) {}
      harness.define_singleton_method(:execute_with_logging) do |cmd, *_args, **_options|
        { success: cmd == ['unit'], timeout: false, output: 'current phase output', exit_status: 65 }
      end
      harness.define_singleton_method(:verify_xcresult_phase_summary) do |*_args|
        { ok: true, matched_test_count: 2 }
      end
      result = nil
      capture_stdout { result = harness.send(:run_tests_with_progress, timeout_seconds: 10) }
      assert_eq(result[:success], false)
      assert_eq(result[:xcresult_path], '/fixture/ui.xcresult')
      assert_eq(result[:log_path], '/fixture/ui.log')
      assert_eq(result[:failure_output], 'current phase output')
    end

    test('standalone discovery includes canonical verify and monitor output bundles') do
      Dir.mktmpdir('diagnostic-results-') do |dir|
        Dir.chdir(dir) do
          harness = Object.new.extend(SaneMasterModules::Diagnostics)
          harness.define_singleton_method(:project_name) { 'DiagnosticFixtureNoRealProject' }
          cutoff = Time.now
          paths = ['outputs/verify/run/test.xcresult', 'outputs/monitor-tests/run/test.xcresult']
          paths.each_with_index do |path, index|
            FileUtils.mkdir_p(path)
            File.utime(cutoff + index + 1, cutoff + index + 1, path)
            assert_eq(harness.send(:find_latest_xcresult, since: cutoff), path)
          end
          assert_eq(harness.send(:find_latest_xcresult, since: cutoff + 3), nil)
        end
      end
    end

    test('missing current bundle names its command log without selecting another run') do
      Dir.mktmpdir('diagnostic-missing-') do |dir|
        harness = Object.new.extend(SaneMasterModules::Diagnostics)
        harness.define_singleton_method(:project_name) { 'DiagnosticFixtureNoRealProject' }
        harness.define_singleton_method(:cleanup_old_exports) {}
        harness.define_singleton_method(:find_latest_xcresult) { |**_options| raise 'Unrelated run discovery reached' }
        [File.join(dir, 'missing.xcresult'), nil].each do |bundle|
          output = capture_stdout do
            harness.diagnose(bundle, since: Time.now, log_path: File.join(dir, 'build.log'))
          end
          assert_includes(output, File.join(dir, 'build.log'))
          assert(!output.include?('test_output.txt'), 'must not suggest a stale legacy log')
        end
      end
    end
  end

  test_category('zero-test failure drilldown') do
    test('clusters explicit and inferred zero-test failure buckets') do
      events = [
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => false, 'tests_run' => 0, 'failure_bucket' => 'timeout', 'reason' => 'verify timeout' },
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => false, 'tests_run' => 0, 'reason' => 'verify timeout after 300s' },
        { 'type' => 'verify', 'project' => 'SaneBar', 'success' => false, 'tests_run' => 0, 'message' => 'timed out waiting for simulator boot' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => false, 'tests_run' => 0, 'failure_hint' => 'permission prompt timed out blocked Accessibility' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => false, 'tests_run' => 0, 'reason' => '** BUILD FAILED ** timeout error:' },
        { 'type' => 'verify', 'project' => 'SaneClip', 'success' => true, 'tests_run' => 0, 'evidence_strength' => 'build_only' },
        { 'type' => 'verify', 'project' => 'SaneClick', 'success' => false, 'tests_run' => 3, 'failure_bucket' => 'test_failure' },
        { 'type' => 'verify', 'project' => 'SaneVideo', 'success' => false, 'tests_run' => 0, 'timeout_actual' => true, 'reason' => 'verify timeout' }
      ]

      subject = VerifyFailureReviewHarness.new('/tmp/verify-failure-review-test.jsonl')
      result = subject.send(:build_verify_failure_review, events, min_count: 1)
      buckets = result[:buckets].each_with_object({}) { |bucket, memo| memo[bucket[:bucket]] = bucket }

      assert_eq(result[:verify_attempts], 8)
      assert_eq(result[:zero_test_failures], 6)
      assert_eq(result[:weak_green_successes], 1)
      assert_eq(buckets['pre_test_timeout_signal'][:count], 2)
      assert_eq(buckets['timeout'][:count], 1)
      assert_eq(buckets['permission_prompt'][:count], 1)
      assert_eq(buckets['build_failure'][:count], 1)
      assert_eq(buckets['pre_test_process_timeout'][:count], 1)
      assert_eq(buckets['pre_test_timeout_signal'][:projects]['SaneBar'], 2)
      assert_eq(result[:hotspots].first[:project], 'SaneBar')
      assert_eq(result[:hotspots].first[:bucket], 'pre_test_timeout_signal')
      assert_eq(result[:hotspots].first[:count], 2)
      assert_includes(result[:recommended_actions].join(' '), 'Fix the top zero-test bucket first: pre_test_timeout_signal')
      assert_includes(result[:recommended_actions].join(' '), 'SaneBar / pre_test_timeout_signal')
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
