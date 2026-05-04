#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'process_metrics'

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
      end
      true
    end

    test('summarizes verify churn and session quality for dashboard output') do
      Dir.mktmpdir('process-metrics-dashboard-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        rows = [
          { timestamp: '2026-05-04T10:00:00Z', project: 'SaneBar', type: 'verify', success: false, tests_run: 0 },
          { timestamp: '2026-05-04T10:05:00Z', project: 'SaneBar', type: 'verify', success: true, tests_run: 10 },
          { timestamp: '2026-05-04T10:06:00Z', project: 'SaneProcess', type: 'session_end', success: true, sop_score: 8, edits: 2, verify_failures: 1 },
          { timestamp: '2026-05-04T10:07:00Z', project: 'SaneProcess', type: 'hook_block', rule: 'Rule #4' }
        ]
        File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessMetricsHarness.new(path)
        summary = subject.send(:process_metrics_summary, subject.send(:read_process_metric_events))

        assert_eq(summary[:verify][:attempts], 2)
        assert_eq(summary[:verify][:pass_rate], 50.0)
        assert_eq(summary[:verify][:zero_test_failures], 1)
        assert_eq(summary[:sessions][:recovered_green], 1)
        assert_eq(summary[:hook_blocks][:by_rule]['Rule #4'], 1)
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
