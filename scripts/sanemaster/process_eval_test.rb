#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative 'process_eval'

class ProcessEvalHarness
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::ProcessEval

  def initialize(metrics_path)
    @metrics_path = metrics_path
  end

  def process_metrics_path
    @metrics_path
  end
end

include TestFramework

def complete_session_receipt(overrides = {})
  {
    timestamp: '2026-05-14T10:00:00Z',
    type: 'session_receipt',
    schema_version: 2,
    receipt_id: 'receipt123',
    session_id: 'session123',
    client_name: 'codex',
    client_kind: 'codex',
    host: 'mini',
    git_root: '/tmp/repo',
    git_head: 'a' * 40,
    source_fingerprint: 'b' * 64,
    started_at: '2026-05-14T09:55:00Z',
    completed_at: '2026-05-14T10:00:00Z',
    duration_ms: 300_000,
    success: true,
    edits: 1,
    unique_files: 1,
    changed_file_count: 1,
    block_count: 0,
    verify_attempts: 1,
    verify_failures: 0,
    final_verify_success: true,
    final_verify_tests_run: 12,
    final_verify_evidence_strength: 'tested',
    final_verify_timestamp: '2026-05-14T09:59:00Z',
    sop_score: 9,
    base_score: 9,
    scorer_version: 'sane_sop_score_v1'
  }.merge(overrides)
end

exit(run_tests('SaneMaster Process Eval Tests') do
  test_category('trace eval') do
    test('default fixture covers general workflow receipts') do
      subject = ProcessEvalHarness.new('/tmp/saneprocess-process-eval-test.jsonl')
      result = subject.run_trace_eval_fixture(File.expand_path('../process_eval_fixtures.json', __dir__))

      assert(result[:passed], result[:traces].reject { |entry| entry[:passed] }.inspect)
      assert_eq(result[:trace_count], 12)
      true
    end

    test('trace eval catches missing and forbidden receipt events') do
      Dir.mktmpdir('trace-eval-') do |dir|
        fixture = File.join(dir, 'fixture.json')
        File.write(fixture, JSON.pretty_generate(
          'traces' => [
            {
              'id' => 'bad_support_reply',
              'events' => [
                { 'type' => 'command', 'name' => 'gmail reply 123' }
              ],
              'expect' => {
                'required_events' => ['check_inbox review', 'check_inbox reply'],
                'forbidden_events' => ['gmail']
              }
            }
          ]
        ))

        subject = ProcessEvalHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.run_trace_eval_fixture(fixture)

        assert(!result[:passed], 'expected trace eval to fail')
        issues = result[:traces].first[:issues].join(' ')
        assert_includes(issues, 'missing required event check_inbox review')
        assert_includes(issues, 'forbidden event gmail')
      end
      true
    end

    test('trace eval catches shipped support fixes without release-note promise audit') do
      Dir.mktmpdir('support-promise-trace-') do |dir|
        fixture = File.join(dir, 'fixture.json')
        File.write(fixture, JSON.pretty_generate(
          'traces' => [
            {
              'id' => 'support_promise_missing_release_note_audit',
              'events' => [
                { 'type' => 'command', 'name' => 'check_inbox review 123' },
                { 'type' => 'artifact', 'name' => 'support_promise_logged issue=SaneBar-drag-recovery' },
                { 'type' => 'artifact', 'name' => 'fix_shipped issue=SaneBar-drag-recovery' },
                { 'type' => 'command', 'name' => 'check_inbox check-reply 123' }
              ],
              'expect' => {
                'required_events' => [
                  'support_promise_logged',
                  'fix_shipped',
                  'release_notes_audited',
                  'check_inbox check-reply'
                ],
                'ordered_events' => ['support_promise_logged', 'fix_shipped', 'release_notes_audited']
              }
            }
          ]
        ))

        subject = ProcessEvalHarness.new(File.join(dir, 'metrics.jsonl'))
        result = subject.run_trace_eval_fixture(fixture)

        assert(!result[:passed], 'expected trace eval to fail')
        issues = result[:traces].first[:issues].join(' ')
        assert_includes(issues, 'missing required event release_notes_audited')
        assert_includes(issues, 'cannot validate order fix_shipped before release_notes_audited')
      end
      true
    end
  end

  test_category('sop review') do
    test('sop review flags score cap mismatches and inflation risk') do
      Dir.mktmpdir('sop-review-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-14T10:00:00Z', type: 'verify', success: false, tests_run: 0 },
          { timestamp: '2026-05-14T10:05:00Z', type: 'verify', success: true, tests_run: 12 },
          { timestamp: '2026-05-14T10:10:00Z', type: 'session_end', success: true, sop_score: 10, verify_failures: 1, edits: 2 },
          { timestamp: '2026-05-14T10:15:00Z', type: 'session_end', success: true, sop_score: 10, verify_failures: 0, edits: 1 },
          { timestamp: '2026-05-14T10:20:00Z', type: 'session_end', success: true, sop_score: 10, verify_failures: 0, edits: 1 },
          { timestamp: '2026-05-14T10:25:00Z', type: 'session_end', success: true, sop_score: 10, verify_failures: 0, edits: 1 },
          { timestamp: '2026-05-14T10:30:00Z', type: 'session_end', success: true, sop_score: 10, verify_failures: 0, edits: 1 }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,10,clean session\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_sop_review(subject.send(:read_process_metric_events))

          assert_eq(result.dig(:sessions, :cap_mismatches), 1)
          assert(result[:blockers].any? { |item| item.include?('exceed objective verification cap') })
          assert(result[:warnings].any? { |item| item.include?('very high with low variance') })
          assert_eq(result.dig(:sessions, :recent_average_sop_score), 10.0)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('process eval passes trace fixtures while surfacing SOP warnings as review data') do
      Dir.mktmpdir('process-eval-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(complete_session_receipt(
          sop_score: 9,
          block_count: 1
        )) + "\n" + JSON.generate(
          type: 'workflow_receipt',
          schema_version: 2,
          workflow: 'process_eval',
          success: true,
          command: 'ruby scripts/SaneMaster.rb process_eval',
          command_sha256: 'c' * 64,
          started_at: '2026-05-14T10:00:00Z',
          completed_at: '2026-05-14T10:00:02Z',
          duration_ms: 2000,
          exit_status: 0,
          host: 'mini'
        ) + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,9,1 hook block\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_process_eval(fixture: File.expand_path('../process_eval_fixtures.json', __dir__))

          assert(result[:passed], result.inspect)
          assert_eq(result.dig(:trace_eval, :trace_count), 12)
          assert_eq(result.dig(:sop_review, :sessions, :total), 1)
          assert_eq(result.dig(:live_telemetry, :event_count), 2)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('sop review warns when recent session metrics are too thin') do
      Dir.mktmpdir('sop-thin-receipts-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(type: 'session_end', success: true, sop_score: 9, verify_failures: 0, edits: 1) + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,9,old row\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_sop_review(subject.send(:read_process_metric_events))

          assert(result[:warnings].any? { |item| item.include?('missing receipt fields') })
          assert(result.dig(:sessions, :receipt_field_gaps)['session_id'].positive?)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('sop review ignores legacy clean-session CSV rows as score evidence') do
      Dir.mktmpdir('sop-legacy-csv-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, '')
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), [
          'date,sop_score,notes',
          '2026-05-14,10,clean session',
          '2026-05-14,10,clean session'
        ].join("\n") + "\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_sop_review(subject.send(:read_process_metric_events))

          assert_eq(result.dig(:sop_csv, :rows), 2)
          assert_eq(result.dig(:sop_csv, :trusted_rows), 0)
          assert_eq(result.dig(:sop_csv, :legacy_rows_ignored), 2)
          assert(result[:warnings].any? { |item| item.include?('ignored 2 legacy SOP CSV row') })
          assert(result.dig(:sessions, :average_sop_score).nil?)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('sop review blocks high-score thin session receipts') do
      Dir.mktmpdir('sop-thin-session-receipt-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(type: 'session_receipt', schema_version: 2, success: true, sop_score: 9.5, edits: 1) + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,9.5,thin\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_sop_review(subject.send(:read_process_metric_events))

          assert(result[:blockers].any? { |item| item.include?('high-score session receipt') })
          assert(result.dig(:sessions, :receipt_field_gaps)['receipt_id'].positive?)
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('sop review caps green zero-test verify receipts at weak evidence') do
      Dir.mktmpdir('sop-zero-test-cap-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(
          type: 'session_end',
          success: true,
          sop_score: 10,
          session_id: 'zero123',
          client: 'test',
          base_score: 10,
          block_count: 0,
          verify_attempts: 1,
          verify_failures: 0,
          verify_zero_test_failures: 0,
          final_verify_success: true,
          final_verify_tests_run: 0,
          final_verify_evidence_strength: 'build_only',
          final_verify_timestamp: '2026-05-14T10:00:00Z',
          edits: 1
        ) + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,10,zero test green\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_sop_review(subject.send(:read_process_metric_events))

          assert_eq(result.dig(:sessions, :cap_mismatches), 1)
          assert(result[:blockers].any? { |item| item.include?('exceed objective verification cap') })
        ensure
          Dir.chdir(old_pwd)
        end
      end
      true
    end

    test('live telemetry review catches malformed workflow receipts') do
      Dir.mktmpdir('live-telemetry-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { type: 'workflow_receipt', success: true, command: 'ruby scripts/SaneMaster.rb status' },
          { type: 'process_eval', success: true, failed: 0 }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert_eq(result[:event_count], 2)
        assert(result[:blockers].any? { |item| item.include?('workflow_receipt missing workflow') })
        assert(result[:blockers].any? { |item| item.include?('process_eval metric missing trace count') })
      end
      true
    end

    test('live telemetry review blocks session-only fake green proof') do
      Dir.mktmpdir('live-telemetry-session-only-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        File.write(metrics_path, JSON.generate(type: 'session_end', success: true, sop_score: 10) + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert(result[:blockers].any? { |item| item.include?('runner-backed telemetry') })
      end
      true
    end

    test('live telemetry review blocks malformed v2 workflow receipts') do
      Dir.mktmpdir('live-telemetry-v2-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          {
            type: 'workflow_receipt',
            schema_version: 2,
            workflow: 'status',
            success: true,
            command: 'ruby scripts/SaneMaster.rb status',
            started_at: '2026-05-04T10:00:00Z',
            completed_at: '2026-05-04T10:00:01Z',
            duration_ms: 1000
          }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert(result[:blockers].any? { |item| item.include?('workflow_receipt v2 missing exit_status') })
        assert(result[:blockers].any? { |item| item.include?('workflow_receipt v2 missing host') })
        assert(result[:blockers].any? { |item| item.include?('workflow_receipt v2 missing command_sha256') })
      end
      true
    end

    test('live telemetry review blocks malformed v2 session receipts') do
      Dir.mktmpdir('live-telemetry-session-receipt-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          complete_session_receipt(receipt_id: nil, final_verify_tests_run: nil),
          { type: 'process_eval', success: true, traces: 12, failed: 0 }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert(result[:blockers].any? { |item| item.include?('session_receipt v2 missing receipt_id') })
        assert(result[:blockers].any? { |item| item.include?('session_receipt v2 missing final_verify_tests_run') })
      end
      true
    end

    test('live telemetry review accepts complete runtime process metrics') do
      Dir.mktmpdir('live-telemetry-ok-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          {
            type: 'workflow_receipt',
            schema_version: 2,
            workflow: 'status',
            success: true,
            command: 'ruby scripts/SaneMaster.rb status',
            command_sha256: 'b' * 64,
            started_at: '2026-05-04T10:00:00Z',
            completed_at: '2026-05-04T10:00:01Z',
            duration_ms: 1000,
            exit_status: 0,
            host: 'mini'
          },
          complete_session_receipt,
          { type: 'agent_eval', success: true, cases: 17, failed: 0 },
          { type: 'process_eval', success: true, traces: 12, failed: 0 },
          { type: 'visual_smoke', success: true, status: 'passed', host: 'mini', app: 'SaneBar' }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert_eq(result[:blockers], [])
        assert_eq(result.dig(:workflow_receipts, :successful), 1)
        assert_eq(result.dig(:workflow_receipts, :enriched), 1)
        assert_eq(result.dig(:workflow_receipts, :thin), 0)
        assert(!result[:warnings].any? { |item| item.include?('fixture-only') })
        assert_eq(result.dig(:visual_smoke, :mini_successful), 1)
      end
      true
    end

    test('live telemetry review warns on local-only visual smoke success') do
      Dir.mktmpdir('live-telemetry-local-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { type: 'visual_smoke', success: true, status: 'passed', host: 'local', app: 'SaneBar' }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert(result[:warnings].any? { |item| item.include?('not Mini-host proof') })
      end
      true
    end

    test('live telemetry review warns on failed visual smoke') do
      Dir.mktmpdir('live-telemetry-failed-') do |dir|
        metrics_path = File.join(dir, 'metrics.jsonl')
        rows = [
          { type: 'visual_smoke', success: false, status: 'failed', host: 'mini', app: 'SaneBar', reason: 'dirty workspace' }
        ]
        File.write(metrics_path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessEvalHarness.new(metrics_path)
        result = subject.build_live_telemetry_review(subject.send(:read_process_metric_events))

        assert(result[:warnings].any? { |item| item.include?('recent visual_smoke failure') })
        assert_eq(result.dig(:visual_smoke, :failed), 1)
      end
      true
    end
  end
end)
