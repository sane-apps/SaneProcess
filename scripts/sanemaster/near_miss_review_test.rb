#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'near_miss_review'

class NearMissReviewHarness
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::NearMissReview

  def initialize(metrics_path)
    @metrics_path = metrics_path
  end

  def process_metrics_path
    @metrics_path
  end
end

include TestFramework

def write_metrics(path, rows)
  File.write(path, rows.map { |row| row.is_a?(String) ? row : JSON.generate(row) }.join("\n") + "\n")
end

def capture_stdout
  original = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original
end

exit(run_tests('SaneMaster Near-Miss Review Tests') do
  test_category('candidate mining') do
    test('backtests real workflow hazards into actionable candidates') do
      Dir.mktmpdir('near-miss-review-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-14T10:00:00Z', type: 'hook_block', project: 'SaneProcess', rule: 'Rule #2', tool: 'Edit', reason: 'RESEARCH INCOMPLETE' },
          { timestamp: '2026-05-14T10:01:00Z', type: 'hook_block', project: 'SaneProcess', rule: 'Rule #2', tool: 'Edit', reason: 'RESEARCH INCOMPLETE' },
          { timestamp: '2026-05-14T10:02:00Z', type: 'hook_block', project: 'SaneProcess', rule: 'Rule #4', tool: 'Bash', reason: 'DIFFERENT BLOCK' },
          { timestamp: '2026-05-14T10:03:00Z', type: 'verify', project: 'SaneClip', success: false, tests_run: 0 },
          { timestamp: '2026-05-14T10:04:00Z', type: 'verify', project: 'SaneClip', success: false, tests_run: 0 },
          { timestamp: '2026-05-14T10:05:00Z', type: 'verify', project: 'SaneBar', success: true, tests_run: 0, host: 'MacBook-Air' },
          { timestamp: '2026-05-14T10:06:00Z', type: 'verify', project: 'SaneBar', success: true, tests_run: 0, host: 'local' },
          { timestamp: '2026-05-14T10:07:00Z', type: 'visual_smoke', project: 'SaneBar', success: true, host: 'local' },
          { timestamp: '2026-05-14T10:08:00Z', type: 'visual_smoke', project: 'SaneBar', success: true, host: 'MacBook-Air' },
          { timestamp: '2026-05-14T10:09:00Z', type: 'session_end', project: 'SaneBar', success: true, sop_score: 9, edits: 2, verify_attempts: 0 },
          { timestamp: '2026-05-14T10:10:00Z', type: 'session_end', project: 'SaneBar', success: true, sop_score: 9, edits: 1, verify_attempts: 0 },
          { timestamp: '2026-05-14T10:11:00Z', type: 'support_send', project: 'check-inbox', channel: 'reply', success: false, delivery_event: 'unconfirmed' },
          { timestamp: '2026-05-14T10:12:00Z', type: 'support_send', project: 'check-inbox', channel: 'reply', success: false, delivery_event: 'bounced' }
        ]
        write_metrics(metrics_path, rows)

        subject = NearMissReviewHarness.new(metrics_path)
        result = subject.build_near_miss_review(subject.send(:read_near_miss_events_from_path, metrics_path), options: { min_count: 2 })
        by_category = result[:candidates].group_by { |candidate| candidate[:category] }

        assert(by_category.key?('hook_block_recurrence'), 'expected repeated hook blocks to become a candidate')
        assert_eq(by_category['hook_block_recurrence'].first[:evidence_count], 2)
        assert_includes(by_category['hook_block_recurrence'].first[:title], 'Rule #2 / Edit / RESEARCH INCOMPLETE')
        assert(by_category.key?('weak_verification'), 'expected zero-test failures to be reported')
        assert(by_category.key?('weak_test_evidence'), 'expected green zero-test evidence to be reported')
        assert(by_category.key?('missing_mini_proof'), 'expected local host evidence to be reported')
        assert(by_category.key?('compliance_theater'), 'expected edited sessions without verify attempts to be reported')
        assert(by_category.key?('support_delivery'), 'expected failed support delivery proof to be reported')
        assert(result[:candidates].first[:severity] == 'high', 'high severity candidates should sort first')
      end
      true
    end

    test('does not flag clean Mini-backed proof') do
      Dir.mktmpdir('near-miss-clean-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-14T10:00:00Z', type: 'verify', project: 'SaneBar', success: true, tests_run: 42, host: 'mini' },
          { timestamp: '2026-05-14T10:01:00Z', type: 'visual_smoke', project: 'SaneBar', success: true, host: 'mini' },
          {
            timestamp: '2026-05-14T10:02:00Z',
            type: 'session_end',
            project: 'SaneBar',
            success: true,
            sop_score: 9,
            edits: 1,
            session_id: 'abc123',
            client: 'codex',
            base_score: 9,
            block_count: 0,
            verify_attempts: 1,
            verify_failures: 0,
            final_verify_success: true
          }
        ]
        write_metrics(metrics_path, rows)

        subject = NearMissReviewHarness.new(metrics_path)
        result = subject.build_near_miss_review(subject.send(:read_near_miss_events_from_path, metrics_path), options: { min_count: 2 })

        assert_eq(result.dig(:summary, :candidate_count), 0)
        assert_eq(result[:candidates], [])
      end
      true
    end

    test('consolidates one hook failure family across tools and progress counters') do
      Dir.mktmpdir('near-miss-hook-family-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-06-11T10:00:00Z', type: 'hook_block', project: 'SaneBar', rule: 'session_docs', tool: 'Edit', reason: 'READ REQUIRED DOCS FIRST [0/1 read]' },
          { timestamp: '2026-06-11T10:01:00Z', type: 'hook_block', project: 'SaneBar', rule: 'session_docs', tool: 'Write', reason: 'READ REQUIRED DOCS FIRST [1/2 read]' },
          { timestamp: '2026-06-11T10:02:00Z', type: 'hook_block', project: 'SaneBar', rule: 'session_docs', tool: 'NotebookEdit', reason: 'READ REQUIRED DOCS FIRST [0/2 read]' }
        ]
        write_metrics(metrics_path, rows)

        subject = NearMissReviewHarness.new(metrics_path)
        result = subject.build_near_miss_review(subject.send(:read_near_miss_events_from_path, metrics_path), options: { min_count: 2 })
        candidates = result[:candidates].select { |candidate| candidate[:category] == 'hook_block_recurrence' }

        assert_eq(candidates.length, 1)
        assert_eq(candidates.first[:evidence_count], 3)
        assert_includes(candidates.first[:title], 'session_docs / 3 tools:')
        assert_includes(candidates.first[:title], 'READ REQUIRED DOCS FIRST')
        assert(!candidates.first[:title].include?('[0/1 read]'), 'progress counters should not fragment the candidate')
      end
      true
    end

    test('report command is read-only and tolerates malformed JSONL rows') do
      Dir.mktmpdir('near-miss-json-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          '{not json',
          { timestamp: '2026-05-14T10:00:00Z', type: 'verify', project: 'SaneBar', success: false, tests_run: 0 },
          { timestamp: '2026-05-14T10:01:00Z', type: 'verify', project: 'SaneBar', success: false, tests_run: 0 }
        ]
        write_metrics(metrics_path, rows)
        before = File.read(metrics_path)

        subject = NearMissReviewHarness.new(File.join(dir, 'unused.jsonl'))
        output = capture_stdout { subject.near_miss_review(['--json', '--metrics', metrics_path, '--min-count', '2']) }
        parsed = JSON.parse(output)

        assert_eq(File.read(metrics_path), before)
        assert_eq(parsed['lookback_events'], 2)
        assert_eq(parsed['candidates'].first['category'], 'weak_verification')
        assert_includes(parsed['candidates'].first['proposed_test'], 'verify_guard_test')
      end
      true
    end

    test('lookback limit changes the backtest window') do
      Dir.mktmpdir('near-miss-limit-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-14T10:00:00Z', type: 'hook_block', project: 'SaneProcess', rule: 'Rule #2', tool: 'Edit', reason: 'RESEARCH INCOMPLETE' },
          { timestamp: '2026-05-14T10:01:00Z', type: 'hook_block', project: 'SaneProcess', rule: 'Rule #2', tool: 'Edit', reason: 'RESEARCH INCOMPLETE' },
          { timestamp: '2026-05-14T10:02:00Z', type: 'verify', project: 'SaneBar', success: true, tests_run: 12, host: 'mini' }
        ]
        write_metrics(metrics_path, rows)

        subject = NearMissReviewHarness.new(metrics_path)
        output = capture_stdout { subject.near_miss_review(['--json', '--metrics', metrics_path, '--limit', '1', '--min-count', '2']) }
        parsed = JSON.parse(output)

        assert_eq(parsed['lookback_events'], 1)
        assert_eq(parsed['summary']['candidate_count'], 0)
      end
      true
    end

    test('default report suppresses SaneProcess test-harness noise') do
      Dir.mktmpdir('near-miss-test-filter-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-14T10:00:00Z', type: 'hook_block', project: 'saneprocess-tier-tests-abc', rule: 'session_docs', tool: 'Edit', reason: 'READ REQUIRED DOCS FIRST' },
          { timestamp: '2026-05-14T10:01:00Z', type: 'hook_block', project: 'saneprocess-tier-tests-abc', rule: 'session_docs', tool: 'Edit', reason: 'READ REQUIRED DOCS FIRST' },
          { timestamp: '2026-05-14T10:02:00Z', type: 'verify', project: 'SaneBar', success: false, tests_run: 0 },
          { timestamp: '2026-05-14T10:03:00Z', type: 'verify', project: 'SaneBar', success: false, tests_run: 0 }
        ]
        write_metrics(metrics_path, rows)

        subject = NearMissReviewHarness.new(metrics_path)
        output = capture_stdout { subject.near_miss_review(['--json', '--metrics', metrics_path, '--all', '--min-count', '2']) }
        parsed = JSON.parse(output)
        categories = parsed['candidates'].map { |candidate| candidate['category'] }

        assert_eq(parsed['ignored_test_events'], 2)
        assert(!categories.include?('hook_block_recurrence'), 'test harness hook blocks should not pollute the default report')
        assert_includes(categories, 'weak_verification')
      end
      true
    end
  end
end)
