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
    test('authoritative verify proof requires tested Mini or approved fallback evidence') do
      strong = {
        'type' => 'verify',
        'success' => true,
        'tests_run' => 12,
        'evidence_strength' => 'tested',
        'host' => 'mini',
        'source_fingerprint' => 'a' * 64
      }
      local = strong.merge('host' => 'local')
      build_only = strong.merge('evidence_strength' => 'build_only')
      fallback = local.merge(
        'fallback_approval' => {
          'approved' => true,
          'approved_by' => 'user',
          'reason' => 'Mini unavailable',
          'user_quote' => 'use local for this run'
        }
      )

      assert(SaneProcessMetrics.authoritative_verify_event?(strong))
      assert(!SaneProcessMetrics.authoritative_verify_event?(local))
      assert(!SaneProcessMetrics.authoritative_verify_event?(build_only))
      assert(SaneProcessMetrics.authoritative_verify_event?(fallback))
      assert(SaneProcessMetrics.authoritative_verify_event?(strong, require_source_fingerprint: true))
      assert(!SaneProcessMetrics.authoritative_verify_event?(strong.merge('source_fingerprint' => 'unknown'), require_source_fingerprint: true))
      true
    end

    test('SaneMaster exposes validation_report as a receipt-backed command') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))

      assert_includes(source, "'validation_report' =>")
      assert_includes(source, "when 'validation_report', 'validation-report'")
      assert_includes(source, "run_external_command_with_workflow_receipt(\n        'validation_report'")
      true
    end

    test('SaneMaster exposes route_cost_review as Mini-first process telemetry') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
      mini_first_block = source[/MINI_FIRST_COMMANDS = Set\.new\(%w\[(.*?)\]\)\.freeze/m, 1]

      assert_includes(source, "'route_cost_review' =>")
      assert_includes(source, "when 'route_cost_review', 'route-cost-review', 'rcr'")
      assert(mini_first_block, 'expected MINI_FIRST_COMMANDS block')
      assert_includes(mini_first_block, 'route_cost_review')
      assert_includes(mini_first_block, 'route-cost-review')
      assert_includes(mini_first_block, 'rcr')
      true
    end

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

    test('rotates process_metrics.jsonl when it exceeds the configured size cap') do
      Dir.mktmpdir('process-metrics-rotate-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        previous_max = ENV['SANEMASTER_PROCESS_METRICS_MAX_BYTES']
        previous_keep = ENV['SANEMASTER_PROCESS_METRICS_ROTATE_KEEP']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path
        ENV['SANEMASTER_PROCESS_METRICS_MAX_BYTES'] = '32'
        ENV['SANEMASTER_PROCESS_METRICS_ROTATE_KEEP'] = '2'
        File.write(path, "#{'x' * 64}\n")

        begin
          assert(SaneProcessMetrics.record('unit_event', ok: true))
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
          previous_max ? ENV['SANEMASTER_PROCESS_METRICS_MAX_BYTES'] = previous_max : ENV.delete('SANEMASTER_PROCESS_METRICS_MAX_BYTES')
          previous_keep ? ENV['SANEMASTER_PROCESS_METRICS_ROTATE_KEEP'] = previous_keep : ENV.delete('SANEMASTER_PROCESS_METRICS_ROTATE_KEEP')
        end

        rows = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
        assert(File.exist?("#{path}.1"), 'expected previous ledger to rotate to .1')
        assert_eq(rows.length, 1)
        assert_eq(rows.first['type'], 'unit_event')
      end
      true
    end

    test('workflow receipt suppression skips internal watchdog cleanup telemetry') do
      Dir.mktmpdir('workflow-receipt-suppress-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        previous_suppression = ENV['SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path
        ENV['SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT'] = '1'

        begin
          SaneMaster.new.send(:record_sanemaster_workflow_receipt, 'mcp_watchdog', %w[mcp_watchdog clean], Time.now.utc, 0)
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
          previous_suppression ? ENV['SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT'] = previous_suppression : ENV.delete('SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT')
        end

        assert(!File.exist?(path) || File.zero?(path), 'expected suppression to avoid writing workflow_receipt')
      end
      true
    end

    test('records audit-grade v3 workflow receipts for wrapped commands') do
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
        assert_eq(receipt['schema_version'], 3)
        assert_eq(receipt['workflow'], 'unit_test')
        assert_eq(receipt['success'], true)
        assert_eq(receipt['exit_status'], 0)
        assert(receipt['duration_ms'].is_a?(Integer), 'expected duration_ms integer')
        assert(receipt['command_sha256'].match?(/\A[0-9a-f]{64}\z/), 'expected command hash')
        assert(receipt['started_at'].match?(/\A\d{4}-\d{2}-\d{2}T/), 'expected started_at timestamp')
        assert(receipt['completed_at'].match?(/\A\d{4}-\d{2}-\d{2}T/), 'expected completed_at timestamp')
        assert(!receipt['host'].to_s.empty?, 'expected host')
        assert_eq(receipt['event_version'], 3)
        assert_eq(receipt['task_family'], 'general')
        assert_eq(receipt['claim_scope'], 'code')
        assert_eq(receipt['proof_scope_actual'], 'diagnostic')
        assert_eq(receipt['outcome_strength'], 'diagnostic')
      end
      true
    end

    test('records v3 workflow receipts for SaneMaster commands by default') do
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
        assert_eq(receipt['schema_version'], 3)
        assert_eq(receipt['success'], true)
        assert_eq(receipt['exit_status'], 0)
        assert(receipt['duration_ms'].is_a?(Integer), 'expected duration_ms integer')
        assert(receipt['command_sha256'].match?(/\A[0-9a-f]{64}\z/), 'expected command hash')
        assert(!receipt['host'].to_s.empty?, 'expected host')
        assert_eq(receipt['task_family'], 'process_health')
        assert_eq(receipt['claim_scope'], 'diagnostic')
        assert_eq(receipt['proof_scope_actual'], 'diagnostic')
      end
      true
    end

    test('workflow receipt route metadata carries latest proof plan scope') do
      Dir.mktmpdir('workflow-route-metadata-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        previous_metrics_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = path
        subject = ProcessMetricsHarness.new(path)

        begin
          subject.record_process_metric(
            'proof_plan',
            proof_scope_planned: 'focused_mini',
            route_reason: 'Scoped proof uses focused tests plus exact Mini runtime proof'
          )
          metadata = subject.send(:workflow_receipt_route_metadata, 'sanemaster:verify', success: true)

          assert_eq(metadata[:schema_version], nil)
          assert_eq(metadata[:event_version], 3)
          assert_eq(metadata[:task_family], 'verification')
          assert_eq(metadata[:claim_scope], 'code')
          assert_eq(metadata[:proof_scope_planned], 'focused_mini')
          assert_eq(metadata[:proof_scope_actual], 'full_canonical')
          assert_eq(metadata[:outcome_strength], 'authoritative')
          assert_includes(metadata[:route_reason], 'Scoped proof')
        ensure
          if previous_metrics_path
            ENV['SANEMASTER_PROCESS_METRICS_PATH'] = previous_metrics_path
          else
            ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
          end
        end
      end
      true
    end

    test('failed workflow receipt route metadata classifies expected red state') do
      subject = ProcessMetricsHarness.new('/tmp/saneprocess-route-failure-state-test.jsonl')

      launch = subject.send(:workflow_receipt_route_metadata, 'sanemaster:launch_readiness', success: false)
      ui = subject.send(:workflow_receipt_route_metadata, 'sanemaster:customer_ui_sweep', success: false)
      verify = subject.send(:workflow_receipt_route_metadata, 'sanemaster:verify', success: false)
      green = subject.send(:workflow_receipt_route_metadata, 'sanemaster:verify', success: true)

      assert_eq(launch[:failure_state], 'launch_precondition_blocked')
      assert_eq(ui[:failure_state], 'runtime_proof_failed')
      assert_eq(verify[:failure_state], 'verification_failed')
      assert_eq(green[:failure_state], nil)
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

    test('route cost review ranks expensive proof paths and ignores bookkeeping by default') do
      Dir.mktmpdir('route-cost-review-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        rows = [
          {
            timestamp: '2026-06-12T10:00:00Z',
            project: 'SaneVideo',
            type: 'workflow_receipt',
            workflow: 'sanemaster:release_preflight',
            success: false,
            exit_status: 1,
            duration_ms: 900_000
          },
          {
            timestamp: '2026-06-12T10:20:00Z',
            project: 'SaneVideo',
            type: 'workflow_receipt',
            workflow: 'sanemaster:release_preflight',
            success: true,
            exit_status: 0,
            duration_ms: 420_000
          },
          {
            timestamp: '2026-06-12T10:30:00Z',
            project: 'SaneVideo',
            type: 'workflow_receipt',
            workflow: 'sanemaster:verify',
            success: false,
            exit_status: 1,
            duration_ms: 300_000,
            proof_scope_planned: 'focused_mini',
            proof_scope_actual: 'full_canonical',
            outcome_strength: 'authoritative'
          },
          {
            timestamp: '2026-06-12T10:35:00Z',
            project: 'SaneVideo',
            type: 'workflow_receipt',
            workflow: 'sanemaster:verify',
            success: true,
            exit_status: 0,
            duration_ms: 45_000
          },
          {
            timestamp: '2026-06-12T10:40:00Z',
            project: '/',
            type: 'workflow_receipt',
            workflow: 'sanemaster:mcp_watchdog',
            success: true,
            exit_status: 0,
            duration_ms: 30
          },
          {
            timestamp: '2026-06-12T10:45:00Z',
            project: 'SaneProcess',
            type: 'workflow_receipt',
            workflow: 'validation_report',
            success: true,
            exit_status: 0,
            duration_ms: 200_000
          },
          {
            timestamp: '2026-06-12T10:50:00Z',
            project: 'SaneProcess',
            type: 'workflow_receipt',
            workflow: 'sanemaster:validation_report',
            success: true,
            exit_status: 0,
            duration_ms: 210_000
          }
        ]
        File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessMetricsHarness.new(path)
        result = subject.send(:build_route_cost_review, subject.send(:read_route_cost_events_from_path, path), options: { metrics_path: path, min_count: 1 })
        release = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:release_preflight' }
        verify = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:verify' }
        validation = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:validation_report' }

        assert_eq(result[:workflow_receipts], 7)
        assert_eq(result[:ignored_bookkeeping_receipts], 1)
        assert_eq(result.dig(:summary, :planned_focused_ran_broad_count), 1)
        assert(!result[:workflows].any? { |entry| entry[:workflow] == 'sanemaster:mcp_watchdog' })
        assert_eq(release[:cost_class], 'high')
        assert_eq(release[:route_guard], 'release_only')
        assert_eq(release[:failure_states]['release_precondition_blocked'], 1)
        assert_eq(release[:expected_red_failures], 1)
        assert_includes(release[:proof_guidance], 'proof_plan')
        assert_eq(verify[:route_guard], 'proof_scope_sensitive')
        assert_eq(verify[:planned_focused_ran_broad_count], 1)
        assert_eq(verify[:failure_states]['verification_failed'], 1)
        assert_eq(verify[:expected_red_failures], 0)
        assert_eq(validation[:count], 2)
        assert_includes(validation[:raw_workflows], 'validation_report')
        assert_includes(validation[:raw_workflows], 'sanemaster:validation_report')
        assert_includes(result[:recommended_actions].join(' '), 'release-only workflow')
        assert_includes(result[:recommended_actions].join(' '), 'broad proof before focused proof')
        assert_includes(result[:recommended_actions].join(' '), 'expected precondition blockers')
      end
      true
    end

    test('route cost review separates expected precondition red from runtime proof failure') do
      Dir.mktmpdir('route-cost-failure-states-') do |dir|
        path = File.join(dir, 'metrics.jsonl')
        rows = [
          {
            timestamp: '2026-06-12T10:00:00Z',
            project: 'SaneBar',
            type: 'workflow_receipt',
            workflow: 'sanemaster:launch_readiness',
            success: false,
            exit_status: 1,
            duration_ms: 1_000
          },
          {
            timestamp: '2026-06-12T10:01:00Z',
            project: 'SaneBar',
            type: 'workflow_receipt',
            workflow: 'sanemaster:setapp_upload',
            success: false,
            exit_status: 1,
            duration_ms: 1_000
          },
          {
            timestamp: '2026-06-12T10:02:00Z',
            project: 'SaneBar',
            type: 'workflow_receipt',
            workflow: 'sanemaster:customer_ui_sweep',
            success: false,
            exit_status: 1,
            duration_ms: 1_000
          }
        ]
        File.write(path, rows.map { |row| JSON.generate(row) }.join("\n") + "\n")

        subject = ProcessMetricsHarness.new(path)
        result = subject.send(:build_route_cost_review, subject.send(:read_route_cost_events_from_path, path), options: { metrics_path: path, min_count: 1 })
        launch = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:launch_readiness' }
        setapp = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:setapp_upload' }
        ui = result[:workflows].find { |entry| entry[:workflow] == 'sanemaster:customer_ui_sweep' }

        assert_eq(launch[:failure_states], { 'launch_precondition_blocked' => 1 })
        assert_eq(setapp[:failure_states], { 'distribution_precondition_blocked' => 1 })
        assert_eq(ui[:failure_states], { 'runtime_proof_failed' => 1 })
        assert_eq(launch[:expected_red_failures], 1)
        assert_eq(setapp[:expected_red_failures], 1)
        assert_eq(ui[:expected_red_failures], 0)
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
