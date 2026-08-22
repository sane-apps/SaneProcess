# frozen_string_literal: true

module SaneMasterModules
  module CommandRegistry
    COMMAND_REGISTRY_ALIASES = {
      'tm' => 'test_mode',
      'crash_report' => 'crashes',
      'check-inbox' => 'check_inbox',
      'inbox' => 'check_inbox',
      'sync-mini' => 'sync_mini',
      'sync-grok' => 'sync_grok',
      'sync-control-plane' => 'sync_control_plane',
      'keep-current' => 'keep_current',
      'operator-brief' => 'operator_brief',
      'brief' => 'operator_brief',
      'business-appointment' => 'business_appointment',
      'appointment' => 'business_appointment',
      'runtime_snapshot' => 'runtime_evidence',
      'runtime-evidence' => 'runtime_evidence',
      'lldb_snapshot' => 'runtime_evidence',
      'visual-smoke' => 'visual_smoke',
      'resource-soak' => 'resource_soak',
      'customer-ui-sweep' => 'customer_ui_sweep',
      'release-readiness' => 'release_readiness',
      'upgrade-path-proof' => 'upgrade_path_proof',
      'route-cost-review' => 'route_cost_review',
      'rcr' => 'route_cost_review',
      'near-miss-review' => 'near_miss_review',
      'nmr' => 'near_miss_review',
      'verify-failure-review' => 'verify_failure_review',
      'vfr' => 'verify_failure_review',
      'process-eval' => 'process_eval',
      'trace-eval' => 'trace_eval',
      'sop-review' => 'sop_review',
      'proof-plan' => 'proof_plan',
      'context-bundle' => 'context_bundle',
      'ponytail-audit' => 'ponytail_audit',
      'agent-eval' => 'agent_eval',
      'skill-lint' => 'skill_lint',
      'tool_receipt' => 'tool_discovery',
      'tool-receipt' => 'tool_discovery'
    }.freeze

    def command_aliases
      COMMAND_REGISTRY_ALIASES
    end

    def canonical_command_name(command)
      COMMAND_REGISTRY_ALIASES.fetch(command, command)
    end
  end
end
