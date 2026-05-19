#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'tool_discovery_receipt'

include TestFramework

exit(run_tests('Tool discovery receipt tests') do
  test_category('Health status') do
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
  end
end)
