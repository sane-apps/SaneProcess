#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
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
  end
end)
