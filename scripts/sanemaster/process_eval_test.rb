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

exit(run_tests('SaneMaster Process Eval Tests') do
  test_category('trace eval') do
    test('default fixture covers general workflow receipts') do
      subject = ProcessEvalHarness.new('/tmp/saneprocess-process-eval-test.jsonl')
      result = subject.run_trace_eval_fixture(File.expand_path('../process_eval_fixtures.json', __dir__))

      assert(result[:passed], result[:traces].reject { |entry| entry[:passed] }.inspect)
      assert_eq(result[:trace_count], 9)
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
        File.write(metrics_path, JSON.generate(
          type: 'session_end',
          success: true,
          sop_score: 9,
          session_id: 'abc123',
          client: 'test',
          base_score: 9,
          block_count: 1,
          verify_attempts: 1,
          verify_failures: 0,
          final_verify_success: true,
          edits: 1
        ) + "\n")
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, 'outputs', 'sop_ratings.csv'), "date,sop_score,notes\n2026-05-14,9,1 hook block\n")

        old_pwd = Dir.pwd
        Dir.chdir(dir)
        begin
          subject = ProcessEvalHarness.new(metrics_path)
          result = subject.build_process_eval(fixture: File.expand_path('../process_eval_fixtures.json', __dir__))

          assert(result[:passed], result.inspect)
          assert_eq(result.dig(:trace_eval, :trace_count), 9)
          assert_eq(result.dig(:sop_review, :sessions, :total), 1)
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
  end
end)
