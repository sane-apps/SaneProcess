#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'
require_relative '../SaneMaster'

class ProcessMetricsHarness
  include SaneMasterModules::ProcessMetrics

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

exit(run_tests('SaneMaster Process Metrics Tests') do
  test_category('JSONL recording') do
    test('records structured verify evidence without external services') do
      Dir.mktmpdir('process-metrics-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        subject = ProcessMetricsHarness.new(path)
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path

        begin
          assert(subject.record_process_metric('verify', success: true, tests_run: 12))
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
        end

        rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
        assert_eq(rows.length, 1)
        assert_eq(rows.first['type'], 'verify')
        assert_eq(rows.first['success'], true)
        assert_eq(rows.first['tests_run'], 12)
        assert_eq(rows.first['project'], 'SaneProcess')
        assert(rows.first['timestamp'].match?(/\A\d{4}-\d{2}-\d{2}T/), 'expected ISO timestamp')
      end
      true
    end

    test('records audit-grade v2 workflow receipts for wrapped commands') do
      Dir.mktmpdir('workflow-receipt-v2-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path

        begin
          exit_status = nil
          begin
            SaneMaster.new.send(:run_external_command_with_workflow_receipt, 'unit_test', 'ruby', '-e', 'exit 0')
          rescue SystemExit => e
            exit_status = e.status
          end

          assert_eq(exit_status, 0)
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
        end

        rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
        receipt = rows.find { |row| row['type'] == 'workflow_receipt' }
        assert(receipt, 'expected workflow_receipt metric')
        assert_eq(receipt['schema_version'], 2)
        assert_eq(receipt['workflow'], 'unit_test')
        assert_eq(receipt['success'], true)
        assert_eq(receipt['exit_status'], 0)
        assert(receipt['duration_ms'].is_a?(Integer), 'expected duration_ms integer')
        assert(receipt['command_sha256'].match?(/\A[0-9a-f]{64}\z/), 'expected command hash')
        assert(receipt['started_at'].match?(/\A\d{4}-\d{2}-\d{2}T/), 'expected started_at timestamp')
        assert(receipt['completed_at'].match?(/\A\d{4}-\d{2}-\d{2}T/), 'expected completed_at timestamp')
        assert(!receipt['host'].to_s.empty?, 'expected host')
      end
      true
    end

    test('records v2 workflow receipts for SaneMaster commands by default') do
      Dir.mktmpdir('sanemaster-command-receipt-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        previous_disable_routing = ENV['SANEMASTER_DISABLE_MINI_ROUTING']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path
        ENV['SANEMASTER_DISABLE_MINI_ROUTING'] = '1'

        begin
          SaneMaster.new.run(%w[process_metrics --json])
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
          if previous_disable_routing
            ENV['SANEMASTER_DISABLE_MINI_ROUTING'] = previous_disable_routing
          else
            ENV.delete('SANEMASTER_DISABLE_MINI_ROUTING')
          end
        end

        rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
        receipt = rows.find { |row| row['type'] == 'workflow_receipt' && row['workflow'] == 'sanemaster:process_metrics' }
        assert(receipt, 'expected default SaneMaster workflow_receipt metric')
        assert_eq(receipt['schema_version'], 2)
        assert_eq(receipt['success'], true)
        assert_eq(receipt['exit_status'], 0)
        assert(receipt['duration_ms'].is_a?(Integer), 'expected duration_ms integer')
        assert(receipt['command_sha256'].match?(/\A[0-9a-f]{64}\z/), 'expected command hash')
        assert(!receipt['host'].to_s.empty?, 'expected host')
      end
      true
    end

    test('records hook block metrics from the actual sanetools hook') do
      Dir.mktmpdir('process-metrics-hook-') do |dir|
        project_dir = File.join(dir, 'Project')
        FileUtils.mkdir_p(File.join(project_dir, '.claude'))
        metrics_path = File.join(dir, 'metrics.jsonl')
        hook_path = File.expand_path('../hooks/sanetools.rb', __dir__)
        env = {
          'CLAUDE_PROJECT_DIR' => project_dir,
          'CLAUDE_HOOK_SECRET' => 'process-metrics-test-secret',
          'SANEMASTER_PROCESS_METRICS_PATH' => metrics_path
        }
        payload = {
          tool_name: 'Read',
          tool_input: { file_path: File.expand_path('~/.ssh/id_rsa') }
        }

        _stdout, stderr, status = Open3.capture3(env, 'ruby', hook_path, stdin_data: JSON.generate(payload))

        assert_eq(status.exitstatus, 2)
        assert_includes(stderr, 'SANETOOLS BLOCKED')
        rows = File.readlines(metrics_path, chomp: true).map { |line| JSON.parse(line) }
        metric = rows.find { |row| row['type'] == 'hook_block' }
        assert(metric, 'expected hook_block metric')
        assert_eq(metric['tool'], 'Read')
        assert_eq(metric['rule'], 'Rule #1')
        assert_includes(metric['reason'], 'BLOCKED PATH')
        trajectory = rows.find { |row| row['type'] == 'trajectory_event' }
        assert(trajectory, 'expected trajectory_event metric')
        assert_eq(trajectory['source'], 'PreToolUse')
        assert_eq(trajectory['blocked'], true)
      end
      true
    end

    test('summarizes verify churn and session quality for dashboard output') do
      Dir.mktmpdir('process-metrics-dashboard-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-04T10:00:00Z', project: 'SaneBar', type: 'verify', success: false, tests_run: 0 },
          { timestamp: '2026-05-04T10:05:00Z', project: 'SaneBar', type: 'verify', success: true, tests_run: 10 },
          { timestamp: '2026-05-04T10:05:30Z', project: 'SaneClip', type: 'verify', success: true, tests_run: 0 },
          { timestamp: '2026-05-04T10:06:00Z', project: 'SaneProcess', type: 'session_end', success: true, sop_score: 8, edits: 2, verify_failures: 1 },
          { timestamp: '2026-05-04T10:07:00Z', project: 'SaneProcess', type: 'hook_block', rule: 'Rule #4' },
          { timestamp: '2026-05-04T10:08:00Z', project: 'SaneProcess', type: 'process_eval', success: true },
          { timestamp: '2026-05-04T10:09:00Z', project: 'SaneProcess', type: 'visual_smoke', success: true, status: 'passed', host: 'mini' },
          { timestamp: '2026-05-04T10:10:00Z', project: 'SaneProcess', type: 'visual_smoke', success: true, status: 'planned', host: 'mini', dry_run: true },
          { timestamp: '2026-05-04T10:11:00Z', project: 'SaneProcess', type: 'visual_smoke', success: false, status: 'failed', host: 'local' }
        ]
        File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessMetricsHarness.new(path)
        summary = subject.send(:process_metrics_summary, subject.send(:read_process_metric_events))

        assert_eq(summary[:verify][:attempts], 3)
        assert_eq(summary[:verify][:passes], 1)
        assert_eq(summary[:verify][:build_only_successes], 1)
        assert_eq(summary[:verify][:pass_rate], 33.3)
        assert_eq(summary[:verify][:zero_test_failures], 1)
        assert_eq(summary[:verify][:zero_test_successes], 1)
        assert_eq(summary[:sessions][:recovered_green], 1)
        assert_eq(summary[:hook_blocks][:by_rule]['Rule #4'], 1)
        assert_eq(summary[:workflow_events][:by_type]['process_eval'], 1)
        assert_eq(summary[:visual_smoke][:attempts], 2)
        assert_eq(summary[:visual_smoke][:passes], 1)
        assert_eq(summary[:visual_smoke][:failures], 1)
        assert_eq(summary[:visual_smoke][:mini_passes], 1)
      end
      true
    end

    test('exports JSON, HTML, and OpenTelemetry review artifacts from metrics summary') do
      Dir.mktmpdir('process-metrics-export-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        json_out = File.join(dir, 'metrics.json')
        html_out = File.join(dir, 'metrics.html')
        otel_out = File.join(dir, 'metrics-otel.json')
        rows = [
          { timestamp: '2026-05-04T10:00:00Z', project: 'SaneBar', type: 'verify', success: true, tests_run: 10 },
          {
            timestamp: '2026-05-04T10:01:00Z',
            project: 'SaneProcess',
            type: 'workflow_receipt',
            workflow: 'status',
            success: true,
            command_sha256: 'a' * 64,
            started_at: '2026-05-04T10:01:00Z',
            completed_at: '2026-05-04T10:01:02Z',
            duration_ms: 2000,
            exit_status: 0,
            host: 'mini'
          }
        ]
        File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessMetricsHarness.new(path)
        subject.process_metrics_dashboard(['--export-json', json_out, '--export-html', html_out, '--export-otel', otel_out])

        exported = JSON.parse(File.read(json_out))
        html = File.read(html_out)
        otel = JSON.parse(File.read(otel_out))
        assert_eq(exported['verify']['attempts'], 1)
        assert_includes(html, '<!doctype html>')
        assert_includes(html, 'SaneProcess Metrics')
        assert_includes(html, 'SaneBar')
        assert_includes(html, 'Session Quality')
        assert_includes(html, 'Hook Blocks')
        assert_includes(html, 'Workflow Events')
        spans = otel.dig('resourceSpans', 0, 'scopeSpans', 0, 'spans')
        assert_eq(spans.length, 2)
        workflow_span = spans.find { |span| span['name'] == 'workflow_receipt status' }
        assert(workflow_span, 'expected workflow receipt span')
        assert_eq(workflow_span['status']['code'], 'STATUS_CODE_OK')
        assert(workflow_span['traceId'].match?(/\A[0-9a-f]{32}\z/), 'expected 16-byte trace id hex')
        assert(workflow_span['spanId'].match?(/\A[0-9a-f]{16}\z/), 'expected 8-byte span id hex')
        keys = workflow_span['attributes'].map { |entry| entry['key'] }
        assert_includes(keys, 'saneprocess.command_sha256')
        assert_includes(keys, 'saneprocess.duration_ms')
      end
      true
    end

    test('detects stale QA snapshots without running app QA') do
      Dir.mktmpdir('qa-snapshot-targets-') do |dir|
        app_dir = File.join(dir, 'SaneBar')
        FileUtils.mkdir_p(File.join(app_dir, 'scripts'))
        FileUtils.mkdir_p(File.join(app_dir, 'outputs'))
        File.write(File.join(app_dir, 'scripts', 'qa.rb'), 'puts "qa"')
        File.write(File.join(app_dir, 'outputs', 'qa_status.json'), JSON.pretty_generate(
          'generatedAt' => '2000-01-01T00:00:00Z',
          'status' => 'passed'
        ))

        system('git', 'init', '-q', chdir: app_dir)
        system('git', 'config', 'user.email', 'test@example.com', chdir: app_dir)
        system('git', 'config', 'user.name', 'Test', chdir: app_dir)
        File.write(File.join(app_dir, 'README.md'), 'test')
        system('git', 'add', '.', chdir: app_dir)
        system('git', 'commit', '-q', '-m', 'init', chdir: app_dir)

        subject = ProcessMetricsHarness.new(File.join(dir, 'metrics.jsonl'))
        targets = subject.send(:qa_snapshot_targets, dir)

        assert_eq(targets.length, 1)
        assert_eq(targets.first[:app], 'SaneBar')
        assert(targets.first[:stale])
        assert(targets.first[:stale_reasons].include?('snapshot predates current HEAD commit'))
      end
      true
    end
  end
end)
