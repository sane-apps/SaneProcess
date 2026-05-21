#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'tool_discovery_receipt'

include TestFramework

exit(run_tests('Tool discovery receipt tests') do
  test_category('Health status') do
    test('mcp health check uses watchdog plus live active-session probe') do
      receipt = ToolDiscoveryReceipt.new(['--query', 'mcp health', '--skip-validation'])
      commands = []
      receipt.define_singleton_method(:capture_command) do |command, chdir:, timeout_seconds:|
        commands << command
        if command.include?('mcp_watchdog')
          {
            stdout: JSON.generate({
              doctor: {
                configured_servers: %w[apple-docs memory],
                running_servers: %w[apple-docs memory],
                missing_runtime: [],
                duplicate_servers: [],
                duplicate_codex_servers: [],
                orphan_count: 0,
                stale_sidecars: [],
                recent_errors: [],
                session_transport: { total: 0 }
              }
            }),
            stderr: '',
            exit_code: 0,
            timed_out: false,
            success: true
          }
        else
          {
            stdout: "[PASS] apple-docs - ok\n[PASS] memory - ok\n",
            stderr: '',
            exit_code: 0,
            timed_out: false,
            success: true
          }
        end
      end

      result = receipt.send(:run_doctor_check)

      assert_eq(result[:status], 'ok')
      assert(commands.any? { |command| command.include?('mcp_watchdog') }, commands.inspect)
      assert(commands.any? { |command| command.join(' ').include?('check-mcps') }, commands.inspect)
      assert_eq(result.dig(:live_probe, :pass_count), 2)
      true
    end

    test('mcp health check fails on live probe failures') do
      receipt = ToolDiscoveryReceipt.new(['--query', 'mcp health', '--skip-validation'])
      receipt.define_singleton_method(:capture_command) do |command, chdir:, timeout_seconds:|
        if command.include?('mcp_watchdog')
          {
            stdout: JSON.generate({
              doctor: {
                missing_runtime: [],
                duplicate_servers: [],
                duplicate_codex_servers: [],
                orphan_count: 0,
                stale_sidecars: [],
                recent_errors: [],
                session_transport: { total: 0 }
              }
            }),
            stderr: '',
            exit_code: 0,
            timed_out: false,
            success: true
          }
        else
          {
            stdout: "[FAIL] central-memory - database unavailable\n",
            stderr: '',
            exit_code: 1,
            timed_out: false,
            success: false
          }
        end
      end

      result = receipt.send(:run_doctor_check)

      assert_eq(result[:status], 'failed')
      assert_includes(result.dig(:live_probe, :failures).join("\n"), 'central-memory')
      true
    end

    test('treats blocked validation verdict as not ok even when command exits zero') do
      receipt = ToolDiscoveryReceipt.new(['--query', 'missing tool', '--skip-doctor', '--skip-validation'])
      result = { timed_out: false, success: true, exit_code: 0 }
      payload = {
        'verdict' => {
          'status' => 'PROCESS HEALTH BLOCKED',
          'detail' => '1 system-health issue'
        },
        'issues' => ['Q0 CONFIG: stale'],
        'warnings' => []
      }

      assert_eq(receipt.send(:validation_health_status, result, payload), 'blocked')
      true
    end

    test('does not collapse skipped health checks into false failures') do
      receipt = ToolDiscoveryReceipt.new(['--query', 'missing tool', '--skip-doctor', '--skip-validation'])
      summary = receipt.send(
        :build_summary,
        {
          checks: {
            canonical_paths: [],
            skills_registry: { matches: [] },
            global_skills: { matches: [] },
            local_code: { matches: [] },
            project_docs: { matches: [] },
            doctor: { skipped: true, status: 'skipped' },
            validation_report: { skipped: true, status: 'skipped' }
          }
        }
      )

      assert_eq(summary[:doctor_status], 'skipped')
      assert_eq(summary[:validation_status], 'skipped')
      assert_eq(summary[:doctor_ok], nil)
      assert_eq(summary[:validation_ok], nil)
      true
    end

    test('blocked project validation is separated from mcp health') do
      receipt = ToolDiscoveryReceipt.new(['--query', 'missing tool', '--skip-doctor', '--skip-validation'])
      summary = receipt.send(
        :build_summary,
        {
          checks: {
            canonical_paths: [],
            skills_registry: { matches: [] },
            global_skills: { matches: [] },
            local_code: { matches: [] },
            project_docs: { matches: [] },
            doctor: { status: 'ok' },
            validation_report: { status: 'blocked' }
          }
        }
      )

      assert_eq(summary[:doctor_ok], true)
      assert_eq(summary[:validation_ok], false)
      assert_eq(summary[:validation_blocks_tool_use], false)
      true
    end

    test('recommends optional cloudflare central memory and xcodebuildmcp paths') do
      cloudflare = ToolDiscoveryReceipt.new(['--query', 'cloudflare pages r2 appcast drift', '--skip-doctor', '--skip-validation'])
      central = ToolDiscoveryReceipt.new(['--query', 'central memory semantic recall', '--skip-doctor', '--skip-validation'])
      xcode = ToolDiscoveryReceipt.new(['--query', 'ios simulator proof xcodebuildmcp', '--skip-doctor', '--skip-validation'])

      assert_includes(cloudflare.send(:canonical_path_matches).map { |entry| entry[:name] }, 'Cloudflare release surface checks')
      assert_includes(central.send(:canonical_path_matches).map { |entry| entry[:name] }, 'Semantic cross-session recall')
      assert_includes(xcode.send(:canonical_path_matches).map { |entry| entry[:name] }, 'iOS simulator proof with XcodeBuildMCP')
      true
    end
  end
end)
