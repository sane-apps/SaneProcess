#!/usr/bin/env ruby
# frozen_string_literal: true

# Hook/launchd/ssh shells often run with a C locale, which makes Ruby default
# to US-ASCII and raise "invalid byte sequence" when xcodebuild/tool output
# containing UTF-8 hits a regex (see sanemaster/quality.rb build captures).
# Force UTF-8 before any module reads command output.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'rbconfig'

SANEMASTER_REQUIRED_RUBY_VERSION = ENV.fetch('SANEPROCESS_REQUIRED_RUBY_VERSION', '4.0.0')
SANEMASTER_HOMEBREW_RUBY = ENV.fetch('SANEPROCESS_HOMEBREW_RUBY', '/opt/homebrew/opt/ruby/bin/ruby')

def sanemaster_version_at_least?(current, required)
  current_parts = current.to_s.split('.').map(&:to_i)
  required_parts = required.to_s.split('.').map(&:to_i)
  max = [current_parts.length, required_parts.length].max

  (0...max).each do |index|
    current_part = current_parts[index] || 0
    required_part = required_parts[index] || 0
    return true if current_part > required_part
    return false if current_part < required_part
  end

  true
end

if RUBY_PLATFORM.include?('darwin') &&
   ENV['SANEMASTER_SKIP_RUBY_REEXEC'] != '1' &&
   File.executable?(SANEMASTER_HOMEBREW_RUBY) &&
   !sanemaster_version_at_least?(RUBY_VERSION, SANEMASTER_REQUIRED_RUBY_VERSION)
  warn "SaneMaster needs Ruby #{SANEMASTER_REQUIRED_RUBY_VERSION}+; re-running with #{SANEMASTER_HOMEBREW_RUBY}."
  ENV['SANEMASTER_SKIP_RUBY_REEXEC'] = '1'
  exec(SANEMASTER_HOMEBREW_RUBY, $PROGRAM_NAME, *ARGV)
end

# ==============================================================================
# SaneMaster: Professional Automation Suite for SaneApps
# ==============================================================================
# Modular architecture - see Scripts/sanemaster/ for implementations:
#   base.rb        - Shared constants and utilities
#   memory.rb      - Legacy memory-command compatibility stubs
#   dependencies.rb - Version checking, dependency graphs
#   generation.rb   - Test/mock generation, templates
#   diagnostics.rb  - Crash analysis, xcresult diagnosis
#   runtime_snapshot.rb - LLDB runtime evidence snapshots
#   bootstrap.rb    - Environment setup, auto-update
#   test_mode.rb    - Interactive debugging workflow
#   verify.rb       - Build, test execution, permissions
#   quality.rb      - Dead code, deprecations, Swift 6 compliance
#   release.rb      - Release pipeline, preflight checks, App Store preflight
#   ci_helpers.rb   - CI/CD test helpers (enable_ci_tests, fix_mocks, etc.)
#   sales.rb        - LemonSqueezy sales reporting (daily/monthly/products)
# ==============================================================================

require 'open3'
require 'json'
require 'time'
require 'tempfile'
require 'shellwords'
require 'socket'
require 'digest'
require 'fileutils'
require 'digest'
require 'securerandom'
require 'English'
require 'yaml'

# Load all modules
require_relative 'sanemaster/base'
require_relative 'sanemaster/memory'
require_relative 'sanemaster/dependencies'
require_relative 'sanemaster/generation'
require_relative 'sanemaster/diagnostics'
require_relative 'sanemaster/runtime_snapshot'
require_relative 'sanemaster/visual_smoke'
require_relative 'sanemaster/customer_ui_contract'
require_relative 'sanemaster/bootstrap'
require_relative 'sanemaster/test_mode'
require_relative 'sanemaster/process_metrics'
require_relative 'sanemaster/near_miss_review'
require_relative 'sanemaster/verify_failure_review'
require_relative 'sanemaster/process_eval'
require_relative 'sanemaster/agent_workflow'
require_relative 'sanemaster/agent_context'
require_relative 'sanemaster/ponytail_audit'
require_relative 'sanemaster/operator_brief'
require_relative 'sanemaster/command_registry'
require_relative 'sanemaster/machine_cleanup'
require_relative 'sanemaster/verify'
require_relative 'sanemaster/quality'
require_relative 'sanemaster/secret_scan'
require_relative 'sanemaster/sop_loop'
require_relative 'sanemaster/export'
require_relative 'sanemaster/md_export'
require_relative 'sanemaster/meta'
require_relative 'sanemaster/tool_discovery'
require_relative 'sanemaster/gate_review'
require_relative 'sanemaster/universal_control'
require_relative 'sanemaster/session'
require_relative 'sanemaster/circuit_breaker_state'
require_relative 'sanemaster/structural_compliance'
require_relative 'sanemaster/saneui_guard'
require_relative 'sanemaster/upgrade_path_proof'
require_relative 'sanemaster/release'
require_relative 'sanemaster/release_readiness'
require_relative 'sanemaster/ci_helpers'
require_relative 'sanemaster/sales'
require_relative 'sanemaster/downloads'

class SaneMaster
  ROUTE_CONTEXT_UNTRACKED_SWIFT_MAX_BYTES = 2 * 1024 * 1024
  include SaneMasterModules::Base
  include SaneMasterModules::Memory
  include SaneMasterModules::Dependencies
  include SaneMasterModules::Generation
  include SaneMasterModules::Diagnostics
  include SaneMasterModules::RuntimeSnapshot
  include SaneMasterModules::VisualSmoke
  include SaneMasterModules::CustomerUIContract
  include SaneMasterModules::Bootstrap
  include SaneMasterModules::TestMode
  include SaneMasterModules::ProcessMetrics
  include SaneMasterModules::NearMissReview
  include SaneMasterModules::VerifyFailureReview
  include SaneMasterModules::ProcessEval
  include SaneMasterModules::AgentWorkflow
  include SaneMasterModules::AgentContext
  include SaneMasterModules::PonytailAudit
  include SaneMasterModules::OperatorBrief
  include SaneMasterModules::CommandRegistry
  include SaneMasterModules::MachineCleanup
  include SaneMasterModules::Verify
  include SaneMasterModules::Quality
  include SaneMasterModules::SecretScan
  include SaneMasterModules::SOPLoop
  include SaneMasterModules::Export
  include SaneMasterModules::MdExport
  include SaneMasterModules::Meta
  include SaneMasterModules::ToolDiscovery
  include SaneMasterModules::GateReview
  include SaneMasterModules::UniversalControl
  include SaneMasterModules::Session
  include SaneMasterModules::StructuralCompliance
  include SaneMasterModules::UpgradePathProof
  include SaneMasterModules::Release
  include SaneMasterModules::ReleaseReadiness
  include SaneMasterModules::CIHelpers
  include SaneMasterModules::Sales
  include SaneMasterModules::Downloads

  # ═══════════════════════════════════════════════════════════════════════════
  # COMMAND REFERENCE - Organized by category for easy discovery
  # ═══════════════════════════════════════════════════════════════════════════
  COMMANDS = {
    build: {
      desc: 'Build, test, and validate code',
      commands: {
        'verify' => { args: '[--ui|--ui-only] [--clean] [--no-grant-permissions] [--signed-tests] [--skip-test-validation] [--quiet] [--timeout positive_seconds]', desc: 'Build and run tests with strict arguments, one global Xcode deadline, and scope-matched xcresult evidence' },
        'clean' => { args: '[--nuclear]', desc: 'Wipe build cache and test states' },
        'lint' => { args: '', desc: 'Run SwiftLint and auto-fix issues' },
        'release' => { args: '[--full|--deploy|--no-deploy|--skip-notarize|--version X.Y.Z|--notes "..."]', desc: 'Build, sign, notarize, package, and optionally deploy' },
        'upgrade_path_proof' => { args: '', desc: 'Run the configured behavioral upgrade test and write signed Mini proof' },
        'release_preflight' => { args: '', desc: 'Run all pre-release safety checks without building' },
        'appstore_preflight' => { args: '[--platform macos|ios] [--pkg PATH]', desc: 'Run App Store submission checks and bind authorization to an exact fresh package' }
      }
    },
    gen: {
      desc: 'Generate code, mocks, and assets',
      commands: {
        'gen_test' => { args: '[options]', desc: 'Generate test file from template' },
        'gen_mock' => { args: '', desc: 'Generate mocks using Mockolo' },
        'gen_assets' => { args: '', desc: 'Generate test video assets' },
        'template' => { args: '[save|apply|list] [name]', desc: 'Manage configuration templates' }
      }
    },
    check: {
      desc: 'Static analysis and validation',
      commands: {
        'verify_api' => { args: '<API> [Framework]', desc: 'Verify API exists in SDK' },
        'dead_code' => { args: '', desc: 'Find unused code (Periphery)' },
        'deprecations' => { args: '', desc: 'Scan for deprecated API usage' },
        'swift6' => { args: '', desc: 'Verify Swift 6 concurrency compliance' },
        'saneui_guard' => { args: '[path]', desc: 'Scan app settings UI for shared SaneUI drift' },
        'secret_scan' => { args: '[--path PATH] [--scanner PATH] [--json] [--strict]', desc: 'Run redacted Automic Vault secret scan with SaneProcess policy' },
        'check_docs' => { args: '', desc: 'Check docs are in sync with code' },
        'check_binary' => { args: '', desc: 'Audit binary for security issues' },
        'test_scan' => { args: '[-v]', desc: 'Scan tests for tautologies and hardcoded values' },
        'validation_report' => { args: '[args...]', desc: 'Run SaneProcess validation report with workflow receipt' },
        'release_readiness' => { args: '[--json] [--app APP] [--scope candidate|portfolio]', desc: 'Report candidate patch readiness separately from portfolio health' },
        'launch_readiness' => { args: '[--json] [--max-age-days N]', desc: 'Validate launch gates for new launch actions while treating already-live product proof drift as advisory' },
        'process_metrics' => { args: '[--json] [--export-json PATH] [--export-html PATH] [--export-otel PATH]', desc: 'Summarize verify churn, session quality, hook blocks, and export audit traces' },
        'route_cost_review' => { args: '[--json] [--metrics PATH] [--limit N|--all] [--min-count N] [--include-bookkeeping]', desc: 'Rank expensive workflow receipts and proof-scope misroute risks' },
        'near_miss_review' => { args: '[--json] [--metrics PATH] [--limit N|--all] [--min-count N] [--include-test-events]', desc: 'Mine process telemetry for useful near-miss guard/eval candidates' },
        'verify_failure_review' => { args: '[--json] [--metrics PATH] [--limit N|--all] [--min-count N]', desc: 'Cluster zero-test verify failures by likely root cause' },
        'process_eval' => { args: '[--fixture PATH] [--abtest-dir PATH] [--json] [--require-ui-proof]', desc: 'Evaluate workflow receipt traces, real A/B evidence, and SOP self-assessment health' },
        'trace_eval' => { args: '[--fixture PATH] [--json]', desc: 'Evaluate multi-step workflow receipt trace fixtures' },
        'sop_review' => { args: '[--json]', desc: 'Review SOP score history, caps, and inflation signals' },
        'proof_plan' => { args: '--task "TEXT" [--json]', desc: 'Choose focused Mini proof vs full canonical verify for a task' },
        'context_bundle' => { args: '--task "TEXT" [--output PATH.md] [--max-research N] [--max-memory N] [--json] [--dry-run]', desc: 'Package compact local agent/review context with research and Serena memory indexes' },
        'ponytail_audit' => { args: '[--target PATH] [--output DIR] [--diff] [--model NAME] [--timeout seconds] [--json]', desc: 'Run Ponytail over-engineering audit and write markdown/JSON receipts' },
        'agent_eval' => { args: '[--fixture PATH] [--json]', desc: 'Evaluate prompt-to-workflow routing fixtures' },
        'skill_lint' => { args: '[--path PATH] [--json]', desc: 'Lint skill descriptions for reliable routing' },
        'refresh_qa_snapshots' => { args: '[--dry-run|--run] [--json]', desc: 'List or refresh stale app QA snapshots' },
        'gate_review' => { args: '<fixture.json> [--json]', desc: 'Review candidate prevention gates against seed/block/allow fixtures' },
        'structural' => { args: '[path]', desc: 'Structural compliance check (sc)' },
        'compliance' => { args: '[path]', desc: 'Structural + session compliance (cr)' }
      }
    },
    debug: {
      desc: 'Debugging and crash analysis',
      commands: {
        'test_mode' => { args: '(or tm)', desc: 'Kill → Build → Launch → Logs workflow' },
        'logs' => { args: '[--follow]', desc: 'Show application logs' },
        'launch' => { args: '', desc: 'Launch the app' },
        'crashes' => { args: '[--recent]', desc: 'Analyze crash reports' },
        'diagnose' => { args: '[path]', desc: 'Analyze .xcresult bundle' },
        'runtime_evidence' => { args: '[--executable PATH|--pid PID] [--break File.swift:LINE] [--expr EXPR]', desc: 'Capture LLDB runtime evidence without launching apps' },
        'visual_smoke' => { args: '[--app NAME] [--require-peekaboo] [--json] [--dry-run]', desc: 'Capture Peekaboo visual/AX evidence receipt' },
        'resource_soak' => { args: '[--adaptive|--fixed] [--duration-seconds N] [--interval-seconds N] [--json]', desc: 'Run the Mini release-candidate resource check proof' },
        'customer_ui_sweep' => { args: '[--json] [--dry-run] [--no-exit]', desc: 'Run the app customer workflow runner, then validate the release UI contract' },
        'customer_ui_contract' => { args: '[--json] [--no-exit] [--strict-visual]', desc: 'Validate release-required customer UI action QA manifest and fresh receipt' },
        'menu_scan' => { args: '[--json] [--owners bundle1,bundle2]', desc: 'Menu bar diagnostics (detected/normalized/excluded)' },
        'mode' => { args: '[<AppName>] <pro|basic|free|status|owner-check|owner-install|owner-pro|owner-verify|list> [--launch] [--host local|mini]', desc: 'Set/query test mode or owner-mode install/license state' }
      }
    },
    env: {
      desc: 'Environment and setup',
      commands: {
        'doctor' => { args: '', desc: 'Check environment health' },
        'tool_discovery' => { args: '--query "TEXT"', desc: 'Generate a proof receipt before workarounds or new tools' },
        'agent_env_review' => { args: '[--json]', desc: 'Review agent environment drift from metrics, skills, and research cache' },
        'health' => { args: '', desc: 'Quick health check (< 100ms)' },
        'bootstrap' => { args: '[--check-only]', desc: 'Full environment setup' },
        'setup' => { args: '', desc: 'Install gems and dependencies' },
        'versions' => { args: '', desc: 'Check tool versions' },
        'reset' => { args: '', desc: 'Reset TCC permissions' },
        'restore' => { args: '', desc: 'Fix Xcode/Launch Services issues' },
        'install_provisioning_profiles' => { args: '[--delete-source] [glob ...]', desc: 'Install downloaded provisioning profiles deterministically by UUID' },
        'dedupe_apps' => { args: '[--host local|mini] [--apps App1,App2] [--dry-run] [--json]', desc: 'Keep one canonical app bundle per Sane app' },
        'machine_cleanup' => { args: '[--host local|mini] [--server] [--apply] [--json] [--preserve-apps A,B]', desc: 'Prune disposable caches and generated build/test artifacts without touching active app work' },
        'mcp_watchdog' => { args: '[status|doctor|clean|install|uninstall] [--max N] [--interval SEC] [--json] [--quiet]', desc: 'Detect and clean duplicate MCP daemons' },
        'universal_control_reset' => { args: '[--status] [--dry-run] [--local-only|--mini-only] [--cleanup-mini] [--reboot-mini]', desc: 'Recover Air↔Mini Universal Control / pointer handoff' },
        'work_session_on' => { args: '', desc: 'Start keep-awake + no-lock work session guard' },
        'work_session_off' => { args: '', desc: 'Restore previous lock settings and stop work-session guard' },
        'work_session_status' => { args: '', desc: 'Show current work-session guard state' },
        'server_acceptance' => { args: '[--mini HOST] [--skip-sync] [--json] [--plan] [--output DIR]', desc: 'Prove Air-to-Mini server, access, dependency, and sync invariants without production mutation' }
      }
    },
    meta: {
      desc: 'SaneProcess tooling and release hygiene',
      commands: {
        'meta' => { args: '', desc: 'Audit SaneMaster tooling itself' },
        'audit' => { args: '', desc: 'Scan for missing accessibility identifiers' },
        'system_check' => { args: '', desc: 'Verify unified hook system across all projects' }
      }
    },
    ops: {
      desc: 'Status, support, and Mini control-plane workflows',
      commands: {
        'status' => { args: '[--fast|--full]', desc: 'Run truthful status coverage; full is default and exits 3 when any selected lane is unavailable' },
        'operator_brief' => { args: '[--nightly-report PATH] [--morning-report PATH] [--handoff PATH] [--output PATH] [--json]', desc: 'Summarize current SaneApps receipts into a prioritized operator brief' },
        'business_appointment' => { args: 'add --title TITLE --start "YYYY-MM-DD HH:MM" --attendee EMAIL [--apply] [--json]', desc: 'Create SaneApps-owned business calendar appointments; refuses personal Gmail/calendar routes' },
        'check_inbox' => { args: '[check|review <id>|read <id>|reply ...]', desc: 'Forward to the canonical support inbox workflow' },
        'sync_mini' => { args: '[mini] [--quiet] [--no-restart]', desc: 'Sync the Codex control-plane profile to the Mini (see also: sync_grok)' },
        'sync_grok' => { args: '[mini] [--quiet]', desc: 'Sync the Grok control-plane profile (grok-bin, config, .agents/skills) to the Mini' },
        'setapp_status' => { args: '[--json] [--soft]', desc: 'Check Setapp review status for submitted SaneApps builds' },
        'setapp_package' => { args: '[--project PATH] [--app-name NAME] [--scheme NAME] [--version X.Y.Z]', desc: 'Build, sign, notarize, zip, and validate a Setapp review package' },
        'setapp_upload' => { args: '--zip ZIP --release-notes-file PATH --review-comments-file PATH [--portal-fallback --app-id ID --version-id ID]', desc: 'Upload or replace a Setapp review build using the standard Setapp lane' },
        'setapp_media_sync' => { args: '[--app NAME] [--dry-run] [--json] [--public-page-proof-file PATH]', desc: 'Sync Setapp listing screenshots from .saneprocess to the developer portal and optionally attach public setapp.com proof' }
      }
    },
    session: {
      desc: 'Session state, approvals, and loop controls',
      commands: {
        'github_post_approval' => { args: '--body|--body-file <TEXT|PATH>|--admin --user-approval "QUOTE"', desc: 'Record exact-text approval before public GitHub posting (--admin for no-body settings API calls)' },
        'email_force_approval' => { args: '--action ACTION --id ID --reason TEXT --user-approval "QUOTE"', desc: 'Record scoped approval for check-inbox --force' },
        'session_end' => { args: '[--skip-prompts]', desc: 'End session with insight extraction' },
        'reset_breaker' => { args: '', desc: 'Reset circuit breaker (unblock tools)' },
        'breaker_status' => { args: '', desc: 'Show circuit breaker status' },
        'breaker_errors' => { args: '', desc: 'Show recent failure messages' },
        'research_status' => { args: '', desc: 'Show active research gates and locks' },
        'research_lock' => { args: '<slug> [reason]', desc: 'Require fresh research before more work on an issue family' },
        'research_unlock' => { args: '<slug|--all>', desc: 'Clear a manual research lock' },
        'saneloop' => { args: '<cmd> [opts]', desc: 'Native task loop (start|status|check|log|complete)' }
      }
    },
    sales: {
      desc: 'Sales and revenue reporting',
      commands: {
        'sales' => { args: '[--daily|--month|--products|--fees|--find-customer-orders --email E --name N --product P|--license-status KEY|--disable-license-key KEY|--refund-order ID|--refund-order-number N|--refund-duplicate-license-key KEY --keep-license-key KEY --approval-note PATH|--include-refunded|--json]', desc: 'LemonSqueezy sales report and guarded order refunds (default: daily breakdown)' },
        'downloads' => { args: '[--daily|--days N|--app NAME|--json]', desc: 'Download analytics from dist Worker (default: daily breakdown)' },
        'events' => { args: '[--days N|--app NAME|--json]', desc: 'User-type event analytics (new_free, early_adopter, activated)' },
        'leads' => { args: '--query "TEXT" [--site-limit N] [--page-limit N] [--domain example.com]', desc: 'Lead discovery with Exa + Firecrawl site dossiers' }
      }
    },
    ci: {
      desc: 'CI/CD test helpers',
      commands: {
        'enable_ci_tests' => { args: '', desc: 'Enable test targets in project.yml for CI' },
        'restore_ci_tests' => { args: '', desc: 'Restore project.yml from CI backup' },
        'fix_mocks' => { args: '', desc: 'Add @testable import to generated mocks' },
        'monitor_tests' => { args: '[--scheme NAME] [--test SELECTOR] [--timeout POSITIVE_SECONDS]', desc: 'Run tests with progress and require parsed xcresult proof of at least one passed selected test case' },
        'image_info' => { args: '<path>', desc: 'Extract image info and base64' }
      }
    },
    export: {
      desc: 'Export and documentation',
      commands: {
        'export' => { args: '[--highlight]', desc: 'Export code to PDF (~/Downloads)' },
        'md_export' => { args: '<file.md>', desc: 'Convert markdown to PDF' },
        'listing_actions' => { args: '[--json|--json-out PATH|--xlsx PATH|--max-pages N]', desc: 'Export listing/setup action tracker from inbox history (XLSX)' },
        'hosted_file_actions' => { args: '[--json|--json-out PATH|--xlsx PATH|--evidence-out PATH]', desc: 'Export Lemon Squeezy hosted-file dashboard actions (XLSX)' },
        'deps' => { args: '[--dot]', desc: 'Show dependency graph' },
        'quality' => { args: '', desc: 'Generate Ruby quality report' }
      }
    }
  }.freeze

  QUICK_START = [
    { cmd: 'status [--fast|--full]', desc: 'Truthful status coverage (full by default)' },
    { cmd: 'verify', desc: 'Build + run tests' },
    { cmd: 'check_inbox', desc: 'Support inbox status and review' },
    { cmd: 'test_mode', desc: 'Kill → Build → Launch → Logs' },
    { cmd: 'doctor', desc: 'Check environment health' },
    { cmd: 'tool_discovery', desc: 'Prove existing-tool checks before workarounds' }
  ].freeze

  KNOWN_SANE_APPS = %w[SaneBar SaneClip SaneClick SaneHosts SaneSales SaneSync SaneVideo].freeze
  AUTO_DEDUPE_COMMANDS = Set.new(%w[
    verify
    launch
    run
    test_mode
    tm
    mode
    test_mode_switch
    license_mode
    release_preflight
  ]).freeze

  MINI_FIRST_COMMANDS = Set.new(%w[
                                  verify
                                  clean
                                  lint
                                  quality
                                  audit
                                  system_check
                                  release
                                  upgrade_path_proof
                                  release_preflight
                                  appstore_preflight
                                  asp
                                  setapp_status
                                  setapp-status
                                  setapp_package
                                  setapp-package
                                  setapp_upload
                                  setapp-upload
                                  setapp_media_sync
                                  setapp-media-sync
                                  launch
                                  run
                                  logs
                                  test_mode
                                  tm
                                  qa
                                  validate_test_references
                                  validate-tests
                                  doctor
                                  health
                                  reset
                                  check_permissions
                                  dead_code
                                  find_dead_code
                                  check_deprecations
                                  deprecations
                                  swift6_check
                                  swift6
                                  concurrency_check
                                  test_suite
                                  suite
                                  test_scan
                                  scan_tests
                                  test_quality
                                  check_binary
                                  diagnose
                                  runtime_snapshot
                                  runtime_evidence
                                  runtime-evidence
                                  lldb_snapshot
                                  resource_soak
                                  resource-soak
                                  visual_smoke
                                  visual-smoke
                                  customer_ui_sweep
                                  customer-ui-sweep
                                  release_readiness
                                  release-readiness
                                  launch_readiness
                                  launch-readiness
                                  crash_report
                                  crashes
                                  menu_scan
                                  validation_report
                                  validation-report
                                  process_metrics
                                  sop_metrics
                                  route_cost_review
                                  route-cost-review
                                  rcr
                                  near_miss_review
                                  near-miss-review
                                  nmr
                                  verify_failure_review
                                  verify-failure-review
                                  vfr
                                  process_eval
                                  process-eval
                                  trace_eval
                                  trace-eval
                                  sop_review
                                  sop-review
                                  agent_env_review
                                  agent-env-review
                                  refresh_qa_snapshots
	                                  qa_refresh
	                                ]).freeze
  SETAPP_ROUTE_COMMANDS = Set.new(%w[
                                    setapp_status
                                    setapp-status
                                    setapp_package
                                    setapp-package
                                    setapp_upload
                                    setapp-upload
                                    setapp_media_sync
                                    setapp-media-sync
                                  ]).freeze

  def initialize
    @bundle_id = detect_bundle_id
  end

  # C4 FIX: Dynamically detect bundle ID from project.yml or xcodeproj
  def detect_bundle_id
    config_bundle = saneprocess_config['bundle_id'] || saneprocess_config.dig('release', 'bundle_id')
    return config_bundle if config_bundle && !config_bundle.to_s.empty?

    # Try to read from project.yml first (XcodeGen projects)
    if File.exist?('project.yml')
      begin
        require 'yaml'
        config = YAML.safe_load(File.read('project.yml'))
        # Look for PRODUCT_BUNDLE_IDENTIFIER in settings
        if config.dig('settings', 'PRODUCT_BUNDLE_IDENTIFIER')
          return config.dig('settings', 'PRODUCT_BUNDLE_IDENTIFIER')
        end
        # Look in targets
        config['targets']&.each do |_name, target|
          bundle_id = target.dig('settings', 'PRODUCT_BUNDLE_IDENTIFIER')
          return bundle_id if bundle_id && !bundle_id.include?('Tests')
        end
      rescue StandardError
        # Fall through to xcodeproj detection
      end
    end

    # Try to detect from xcodeproj files
    xcodeprojs = Dir.glob('*.xcodeproj')
    if xcodeprojs.any?
      project_path = xcodeprojs.first
      scheme = detect_scheme(project_path)
      if scheme
        output, status = Open3.capture2e('xcodebuild', '-project', project_path, '-scheme', scheme, '-showBuildSettings')
        if status.success? && output =~ /PRODUCT_BUNDLE_IDENTIFIER\s*=\s*(\S+)/
          return $1
        end
      end
    end

    # Fallback: derive from project directory name
    project_dir = File.basename(Dir.pwd)
    "com.sanevideo.#{project_dir.downcase}"
  end

  def detect_scheme(project_path)
    output, status = Open3.capture2e('xcodebuild', '-list', '-json', '-project', project_path)
    return File.basename(project_path, '.xcodeproj') unless status.success?

    json = JSON.parse(output)
    schemes = json.dig('project', 'schemes') || []
    schemes.find { |name| !name.include?('Tests') } || schemes.first || File.basename(project_path, '.xcodeproj')
  rescue JSON::ParserError, StandardError
    File.basename(project_path, '.xcodeproj')
  end

  def run(args)
    started_at = Time.now.utc
    command = nil
    workflow_args = args.dup
    exit_status = 0
    if args.empty? || ['--help', '-h'].include?(args.first)
      print_help
      return
    end

    command = args.shift

    # Handle 'help <category>' specially
    if command == 'help'
      topic = args.shift
      if topic
        if COMMANDS.key?(topic.to_sym)
          print_category_help(topic.to_sym)
        else
          print_command_detail(topic)
        end
      else
        print_help
      end
      return
    end

    reject_retired_appstore_reuse!(command, args)
    ensure_work_session_ready!(command)
    maybe_route_to_mini!(command, args)

    dispatch_command(command, args)
  rescue SystemExit => e
    exit_status = e.status.is_a?(Integer) ? e.status : (e.success? ? 0 : 1)
    raise
  rescue StandardError
    exit_status = 1
    raise
  ensure
    # Help is read-only discovery, not workflow evidence. Keeping it receipt-free
    # prevents help consumers from receiving telemetry markers on stderr.
    record_sanemaster_workflow_receipt(command, workflow_args, started_at, exit_status) if command && command != 'help'
    auto_dedupe_runtime_apps!(command) if exit_status.to_i.zero?
  end

  private

  def reject_retired_appstore_reuse!(command, args)
    return unless %w[appstore_preflight asp].include?(command.to_s)

    retired = %w[--asc-build-id --build-number].select do |flag|
      Array(args).any? { |arg| arg == flag || arg.start_with?("#{flag}=") }
    end
    return if retired.empty?

    warn "❌ Retired App Store preflight option(s): #{retired.join(', ')}"
    warn 'Existing ASC build reuse is disabled because exact remote bytes cannot be proven.'
    warn 'Increment the build number, create a fresh package, then run appstore_preflight --platform PLATFORM --pkg PATH.'
    exit 2
  end

  def auto_dedupe_runtime_apps!(command)
    return if command.nil?
    return unless AUTO_DEDUPE_COMMANDS.include?(command)
    return if ENV['SANEMASTER_SKIP_AUTO_DEDUPE'] == '1'

    app = project_name
    return unless KNOWN_SANE_APPS.include?(app)

    dedupe_script = File.join(__dir__, 'dedupe_sane_apps.rb')
    return unless File.exist?(dedupe_script)

    puts "🧹 Auto-deduping runtime app copies for #{app}..."
    system('ruby', dedupe_script, '--apps', app)
  end

  def maybe_route_to_mini!(command, args)
    routed_appstore_binding_dir = nil
    return if ENV['SANEMASTER_DISABLE_MINI_ROUTING'] == '1'
    return if running_on_mini_host?
    return unless MINI_FIRST_COMMANDS.include?(command)

    @route_logs_to_stderr = machine_json_output_requested?(args)

    if ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1' && %w[launch run test_mode tm].include?(command)
      route_log('⚠️  Unsigned fallback active; running locally to honor Debug fallback.')
      return
    end

    if args.include?('--local') || ENV['SANEMASTER_FORCE_LOCAL'] == '1'
      route_log('⚠️  Mini-first bypass active (--local or SANEMASTER_FORCE_LOCAL=1); running locally.')
      return
    end

    unless mini_reachable?
      route_log('⚠️  Mac mini is unreachable. Falling back to local execution.')
      return
    end

    remote_repo = map_local_path_to_mini(Dir.pwd)
    unless remote_repo
      route_log("⚠️  Could not map local path to mini: #{Dir.pwd}")
      route_log('   Falling back to local execution.')
      return
    end

    unless mini_path_exists?(remote_repo)
      route_log("⚠️  Repo not found on mini: #{remote_repo}")
      route_log('   Falling back to local execution.')
      return
    end

    remote_saneprocess_repo = map_local_path_to_mini(saneprocess_repo_root)
    unless remote_saneprocess_repo
      abort "❌ Could not map SaneProcess to mini: #{saneprocess_repo_root}"
    end

    with_mini_route_lock(remote_repo, command) do
      release_routed = release_routed_command?(command)
      preserve_release_artifacts = release_artifact_resume_requested?(command, args)
      routed_webhook_repo = nil
      remote_saneui_repo = nil
      execution_repo = if release_routed
                         prepare_release_workspace_on_mini!(Dir.pwd, remote_repo, preserve_release_artifacts: preserve_release_artifacts)
                       else
                         # Non-release routes execute in a persistent scratch
                         # workspace; the canonical Mini repo stays clean so the
                         # release dirty-peer gate can never be tripped by our
                         # own verify/sweep overlays again.
                         prepare_verify_workspace_on_mini!(Dir.pwd, remote_repo)
                       end
      execution_saneprocess_repo = release_routed ? routed_release_path_for_local(saneprocess_repo_root) : routed_verify_path_for_local(saneprocess_repo_root)
      if workspace_uses_saneui?(Dir.pwd) && Dir.exist?(saneui_repo_root)
        remote_saneui_repo = map_local_path_to_mini(saneui_repo_root)
        unless remote_saneui_repo
          abort "❌ Could not map SaneUI to mini: #{saneui_repo_root}"
        end
        remote_saneui_repo = release_routed ? routed_release_path_for_local(saneui_repo_root) : routed_verify_path_for_local(saneui_repo_root)
        sync_local_dir_to_mini!(saneui_repo_root, remote_saneui_repo, label: 'SaneUI')
      end
      sync_local_dir_to_mini!(saneprocess_repo_root, execution_saneprocess_repo, label: 'SaneProcess')
      sync_setapp_app_workspaces_to_mini!(release_routed: release_routed) if setapp_route_command?(command)
      sync_release_artifacts_to_mini!(Dir.pwd, execution_repo) if preserve_release_artifacts
      routed_args, routed_appstore_binding_dir = route_appstore_preflight_package_to_mini(
        command,
        args,
        execution_repo
      )
      if release_routed
        routed_webhook_repo = sync_release_support_repos_to_mini!(release_routed: true, command: command)
        sync_cktool_auth_to_mini!
        write_route_context_to_mini!(execution_repo, command, webhook_remote_repo: routed_webhook_repo)
      end
      prepare_remote_repo_for_command!(execution_repo)

      forwarded_env_keys = %w[
        APPSTORE_PLATFORMS
        SANEMASTER_APPSTORE_PREFLIGHT
        SANEMASTER_BUILD_CONFIG
        SANEMASTER_UNSIGNED_FALLBACK_ACTIVE
        SANEMASTER_ALLOW_UNSIGNED_FALLBACK
        SANEMASTER_ALLOW_REPLACE_DEVELOPER_ID
        SANEMASTER_ALLOW_STAGE_APPLE_DEVELOPMENT_TO_SYSTEM
        SANEMASTER_ALLOW_TCC_IDENTITY_DRIFT
        SANEAPPS_FORCE_LICENSE_CHECK
        SANEHOSTS_USE_LOCAL_SANEUI
        SANEMASTER_SKIP_AUTO_DEDUPE
        SANEBAR_BUILD_CONFIG
        SANEMASTER_CANONICAL_APP_PATH
        SANEPROCESS_APPROVE_FAST_RELEASE
        SANEPROCESS_APPROVE_OPEN_REGRESSION_RELEASE
        SANEPROCESS_APPROVE_UNCONFIRMED_REGRESSION_CLOSE
        SANEBAR_APPROVE_FAST_RELEASE
        SANEBAR_APPROVE_OPEN_REGRESSION_RELEASE
        SANEBAR_APPROVE_UNCONFIRMED_REGRESSION_CLOSE
        SANEBAR_RELEASE_SMOKE_SCREENSHOTS
        PEEKABOO_BIN
        AUTOMATION_BUILD_COMMENTARY_REEL
        AUTOMATION_EXPORT_PATH
        AUTOMATION_QUIT_AFTER_EXPORT
        AUTOMATION_REFINE_CAPTIONS
        AUTOMATION_TRANSCRIPT_PATH
        OPEN_PROJECT_PATH
        PROJECT_DIR
        TEST_ASSET_NAME
        TEST_PROJECT_PATH
        VERIFY_PIP
      ]
      routed_release_env = release_routed ? routed_release_env_context(Dir.pwd) : {}
      forwarded_env = forwarded_env_keys.map do |key|
        value = ENV[key]
        next if value.nil? || value.empty?

        "#{key}=#{Shellwords.escape(value)}"
      end.compact
      routed_release_env.each do |key, value|
        next if value.nil? || value.empty?

        forwarded_env << "#{key}=#{Shellwords.escape(value)}"
      end
      remote_env_prefix = forwarded_env.empty? ? '' : "#{forwarded_env.join(' ')} "
      remote_script = File.join(execution_saneprocess_repo, 'scripts', 'SaneMaster.rb')
      remote_cmd = "#{remote_env_prefix}ruby #{Shellwords.escape(remote_script)} #{([command] + routed_args).map { |arg| Shellwords.escape(arg) }.join(' ')}"
      route_log("📍 Mini-first routing: #{command} -> mini (#{execution_repo})")
      $stdout.flush
      route_started_at = Time.now.utc
      remote_ok = ssh_system('mini', "cd #{Shellwords.escape(execution_repo)} && #{remote_cmd}")
      remote_status = $?.respond_to?(:exitstatus) ? $?.exitstatus : (remote_ok ? 0 : 1)
      mirror_routed_verify_metrics!('mini', route_started_at) if command == 'verify'
      sync_outputs_from_mini!(Dir.pwd, execution_repo)
      cleanup_bulk_outputs_on_mini!(execution_repo)
      sync_release_artifacts_from_mini!(Dir.pwd, execution_repo, warn_only: true) if release_routed
      sync_release_support_repos_from_origin! if release_routed && remote_status.zero? &&
                                                routed_command_requires_support_repo_sync?(command)
      if !release_routed && remote_status.zero?
        normalize_mini_repo_after_route!(Dir.pwd, execution_repo, label: 'workspace')
        normalize_mini_repo_after_route!(saneprocess_repo_root, execution_saneprocess_repo, label: 'SaneProcess')
        normalize_mini_repo_after_route!(saneui_repo_root, remote_saneui_repo, label: 'SaneUI') if remote_saneui_repo
      end
      exit remote_status
    end
  ensure
    cleanup_routed_appstore_preflight_package(routed_appstore_binding_dir) if routed_appstore_binding_dir
    @route_logs_to_stderr = false
  end

  def machine_json_output_requested?(args)
    args.any? { |arg| arg == '--json' || arg.start_with?('--json=') }
  end

  def route_log(message)
    if @route_logs_to_stderr
      warn message
    else
      puts message
    end
  end

  def route_system(*command)
    options = command.last.is_a?(Hash) ? command.pop : {}
    if @route_logs_to_stderr
      options = options.merge(out: $stderr, err: $stderr)
    end
    # Skip the splat for empty options: under ruby 2.6 `system(*cmd, **{})`
    # appends a literal {} argument (pre-3.0 kwargs), which corrupts the
    # command args (seen as a phantom rsync target in release_route tests).
    return system(*command) if options.empty?

    system(*command, **options)
  end

  def with_mini_route_lock(remote_repo, command)
    digest = Digest::SHA256.hexdigest(remote_repo)[0, 16]
    lock_path = File.join(Dir.tmpdir, "sanemaster-mini-route-#{digest}.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))

    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
      waited = !lock_file.flock(File::LOCK_EX | File::LOCK_NB)
      if waited
        route_log("⏳ Waiting for mini workspace lock: #{command} @ #{remote_repo}")
        lock_file.flock(File::LOCK_EX)
      end
      yield
    ensure
      begin
        lock_file.flock(File::LOCK_UN)
      rescue StandardError
        nil
      end
    end
  end

  def running_on_mini_host?
    host = Socket.gethostname.to_s.downcase
    return true if host.include?('mini')

    if RUBY_PLATFORM.include?('darwin')
      computer_name, status = Open3.capture2('/usr/sbin/scutil', '--get', 'ComputerName')
      return true if status.success? && computer_name.to_s.downcase.include?('mac mini')
    end

    false
  rescue StandardError
    false
  end

  def ssh_system(*args, tty: false, **options)
    ssh_args = ['ssh', '-n']
    ssh_args << '-tt' if tty && $stdout.tty?
    # See route_system: empty **options under ruby 2.6 appends a literal {}.
    return system(*ssh_args, *args) if options.empty?

    system(*ssh_args, *args, **options)
  end

  def mini_reachable?
    ssh_system('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=2', 'mini', 'true', out: File::NULL, err: File::NULL)
  end

  def map_local_path_to_mini(local_path)
    return local_path if local_path.start_with?('/Users/stephansmac/')
    return nil unless local_path.start_with?('/Users/sj/')

    "/Users/stephansmac/#{local_path.delete_prefix('/Users/sj/')}"
  end

  def mini_path_exists?(remote_path)
    ssh_system('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', 'mini',
               "test -d #{Shellwords.escape(remote_path)}", out: File::NULL, err: File::NULL)
  end

  def repo_has_uncommitted_changes?
    return false unless system('git', 'rev-parse', '--is-inside-work-tree', out: File::NULL, err: File::NULL)
    return true unless system('git', 'diff', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)
    return true unless system('git', 'diff', '--cached', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)

    false
  rescue StandardError
    false
  end

  def repo_has_uncommitted_changes_at?(repo_dir)
    return false unless system('git', '-C', repo_dir, 'rev-parse', '--is-inside-work-tree', out: File::NULL, err: File::NULL)
    return true unless system('git', '-C', repo_dir, 'diff', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)
    return true unless system('git', '-C', repo_dir, 'diff', '--cached', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)

    false
  rescue StandardError
    false
  end

  def prepare_release_workspace_on_mini!(local_repo, remote_repo, preserve_release_artifacts: false)
    branch = current_git_branch(local_repo)
    head = current_git_head(local_repo)
    origin_url = git_remote_url(local_repo)
    remote_sync = local_repo_remote_sync_context(local_repo, branch, head)

    if branch.empty? || branch == 'HEAD'
      abort '❌ Routed release requires a named git branch. Check out the release branch locally and retry.'
    end
    if head.empty?
      abort '❌ Routed release could not resolve the local git HEAD.'
    end
    if origin_url.empty?
      abort '❌ Routed release requires an origin remote URL.'
    end
    unless remote_sync['status'] == 'matches'
      abort "❌ Routed release requires local #{branch} to match origin/#{branch}. Current status: #{remote_sync['status']}. Push/pull locally first, then rerun."
    end

    scratch_root = mini_release_workspace_root(local_repo)
    scratch_repo = routed_release_path_for_local(local_repo)
    prune_stale_mini_release_workspaces!(local_repo, current_workspace_root: scratch_root)
    sync_release_artifacts_from_mini!(local_repo, scratch_repo, warn_only: true) if preserve_release_artifacts
    remote_bundle_path = File.join('/tmp', "sanemaster-route-#{Digest::SHA256.hexdigest("#{File.expand_path(local_repo)}:#{head}")[0, 16]}.bundle")
    sync_git_bundle_to_mini!(local_repo, branch, remote_bundle_path) unless mini_repo_has_commit?(remote_repo, head)
    remote_cmd = <<~SH
      set -e
      bundle_path=#{Shellwords.escape(remote_bundle_path)}
      scratch_root=#{Shellwords.escape(scratch_root)}
      cleanup() {
        rm -f "$bundle_path"
      }
      trap cleanup EXIT
      python3 - <<'PY'
import os
import shutil
import time

scratch_root = #{scratch_root.dump}
if not os.path.exists(scratch_root):
    raise SystemExit(0)

for attempt in range(3):
    try:
        shutil.rmtree(scratch_root, ignore_errors=False)
        raise SystemExit(0)
    except FileNotFoundError:
        raise SystemExit(0)
    except OSError:
        if attempt == 2:
            break
        time.sleep(0.5)

stale_root = f"{scratch_root}.stale.{os.getpid()}.{int(time.time())}"
os.replace(scratch_root, stale_root)
shutil.rmtree(stale_root, ignore_errors=True)
PY
      [ ! -e "$scratch_root" ]
      mkdir -p #{Shellwords.escape(File.dirname(scratch_repo))}
      git clone --no-checkout #{Shellwords.escape(remote_repo)} #{Shellwords.escape(scratch_repo)} >/dev/null
      cd #{Shellwords.escape(scratch_repo)}
      git remote set-url origin #{Shellwords.escape(origin_url)} >/dev/null 2>&1 || true
      if ! git rev-parse --verify #{Shellwords.escape("#{head}^{commit}")} >/dev/null 2>&1; then
        if [ -f "$bundle_path" ]; then
          git fetch "$bundle_path" #{Shellwords.escape(branch)} >/dev/null 2>&1 || true
        fi
      fi
      if ! git rev-parse --verify #{Shellwords.escape("#{head}^{commit}")} >/dev/null 2>&1; then
        GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git fetch --tags origin >/dev/null 2>&1
      fi
      git rev-parse --verify #{Shellwords.escape("#{head}^{commit}")} >/dev/null 2>&1
      git checkout #{Shellwords.escape(branch)} >/dev/null 2>&1 || git checkout -B #{Shellwords.escape(branch)} #{Shellwords.escape(head)} >/dev/null 2>&1
      git branch --set-upstream-to #{Shellwords.escape("origin/#{branch}")} #{Shellwords.escape(branch)} >/dev/null 2>&1 || true
      git reset --hard #{Shellwords.escape(head)} >/dev/null 2>&1
      git clean -fdx >/dev/null 2>&1
    SH
    ok = ssh_system('mini', remote_cmd)
    abort '❌ Failed to prepare a clean routed release workspace on the mini.' unless ok

    route_log("🔄 Syncing local workspace snapshot to mini (#{scratch_repo})")
    sync_local_dir_to_mini!(local_repo, scratch_repo, label: nil)
    apply_git_deleted_paths_to_mini!(local_repo, scratch_repo)
    scratch_repo
  end

  def prune_stale_mini_release_workspaces!(local_repo, current_workspace_root: nil, keep_days: 3, min_keep: 2)
    workspace_parent = File.dirname(mini_release_workspace_root(local_repo))
    remote_cmd = <<~SH
      set -e
      root=#{Shellwords.escape(workspace_parent)}
      current=#{Shellwords.escape(current_workspace_root.to_s)}
      keep_days=#{keep_days.to_i}
      min_keep=#{min_keep.to_i}
      [ -d "$root" ] || exit 0
      kept=0
      for dir in $(ls -1dt "$root"/* 2>/dev/null); do
        [ -d "$dir" ] || continue
        [ -n "$current" ] && [ "$dir" = "$current" ] && continue
        kept=$((kept + 1))
        if [ "$kept" -le "$min_keep" ]; then
          continue
        fi
        if [ -n "$(find "$dir" -maxdepth 0 -mtime +$keep_days -print -quit 2>/dev/null)" ]; then
          rm -rf "$dir"
        fi
      done
    SH
    ok = ssh_system('mini', remote_cmd)
    warn '⚠️  Failed to prune stale routed workspaces on the mini.' unless ok
    ok
  end

  def release_artifact_resume_requested?(command, args)
    command == 'release' && args.include?('--skip-build')
  end

  def mini_repo_has_commit?(remote_repo, commit)
    ssh_system(
      '-o', 'BatchMode=yes',
      '-o', 'ConnectTimeout=3',
      'mini',
      "git -C #{Shellwords.escape(remote_repo)} rev-parse --verify #{Shellwords.escape("#{commit}^{commit}")} >/dev/null 2>&1",
      out: File::NULL,
      err: File::NULL
    )
  end

  def sync_git_bundle_to_mini!(local_repo, branch, remote_bundle_path)
    Tempfile.create(['sanemaster-route', '.bundle']) do |tmp|
      ok = system('git', '-C', local_repo, 'bundle', 'create', tmp.path, branch, '--tags')
      abort '❌ Failed to create the routed release git bundle.' unless ok

      remote_parent = File.dirname(remote_bundle_path)
      ok = ssh_system('mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
      abort '❌ Failed to prepare the routed release bundle path on the mini.' unless ok

      ok = system('rsync', '-az', tmp.path, "mini:#{remote_bundle_path}")
      abort '❌ Failed to sync the routed release git bundle to the mini.' unless ok
    end
  end

  def apply_git_deleted_paths_to_mini!(local_repo, remote_repo)
    deleted_paths = git_deleted_paths_for_routed_workspace(local_repo)
    return if deleted_paths.empty?

    payload = JSON.generate(deleted_paths)
    remote_cmd = <<~SH
      set -e
      cd #{Shellwords.escape(remote_repo)}
      SANEMASTER_DELETED_PATHS=#{Shellwords.escape(payload)} python3 - <<'PY'
import json
import os
import subprocess

root = os.getcwd()
deleted_paths = json.loads(os.environ.get("SANEMASTER_DELETED_PATHS", "[]"))
safe_paths = []
for rel_path in deleted_paths:
    normalized = os.path.normpath(rel_path)
    if normalized in ("", ".") or normalized.startswith("../") or os.path.isabs(normalized):
        raise SystemExit(f"unsafe routed deletion path: {rel_path}")
    safe_paths.append(normalized)
if safe_paths:
    subprocess.run(["git", "rm", "--cached", "-q", "--ignore-unmatch", "--", *safe_paths], check=True)
PY
    SH
    ok = ssh_system('mini', remote_cmd)
    abort '❌ Failed to apply staged deletions to the routed release workspace on the mini.' unless ok
  end

  def git_deleted_paths_for_routed_workspace(local_repo)
    paths = []
    [
      %w[diff --name-only --diff-filter=D],
      %w[diff --cached --name-only --diff-filter=D]
    ].each do |args|
      output, status = Open3.capture2e('git', '-C', local_repo, *args)
      next unless status.success?

      paths.concat(output.lines.map(&:strip).reject(&:empty?))
    end
    paths.uniq.sort
  rescue StandardError
    []
  end

  def mini_release_workspace_root(local_repo)
    digest = Digest::SHA256.hexdigest(File.expand_path(local_repo))[0, 12]
    File.join('/Users/stephansmac', '.sanemaster', 'routed-workspaces', digest)
  end

  # Persistent (per-repo, reused across runs for incremental build speed)
  # scratch root for NON-release routed commands. Verify/sweep overlays used to
  # rsync straight onto the canonical Mini repo, leaving it permanently dirty —
  # the root cause of the recurring dirty-peer release blocks, wrong-branch
  # commits on the Mini, and the months-old auto-reconcile stash pile.
  def mini_verify_workspace_root(local_repo)
    digest = Digest::SHA256.hexdigest(File.expand_path(local_repo))[0, 12]
    File.join('/Users/stephansmac', '.sanemaster', 'verify-workspaces', digest)
  end

  def routed_verify_path_for_local(local_path, local_repo = Dir.pwd)
    absolute_path = File.expand_path(local_path)
    relative_path = if absolute_path.start_with?('/Users/sj/')
                      absolute_path.delete_prefix('/Users/sj/')
                    elsif absolute_path.start_with?('/Users/stephansmac/')
                      absolute_path.delete_prefix('/Users/stephansmac/')
                    else
                      abort "❌ Could not mirror path into routed verify workspace: #{absolute_path}"
                    end
    File.join(mini_verify_workspace_root(local_repo), relative_path)
  end

  # Prepare the scratch workspace for a non-release routed command: align its
  # git state to the local HEAD (so receipt source fingerprints match by
  # construction), then let the caller overlay the working tree. The canonical
  # Mini repo is never written. Unlike the release path this tolerates
  # unpushed branches (verify's whole point is pre-push proof) and skips
  # `clean -fdx` so incremental build caches survive between runs.
  def prepare_verify_workspace_on_mini!(local_repo, remote_repo)
    branch = current_git_branch(local_repo)
    head = current_git_head(local_repo)
    scratch_repo = routed_verify_path_for_local(local_repo, local_repo)
    bundle_branch = branch
    branch = 'sanemaster-route-verify' if branch.empty? || branch == 'HEAD'

    remote_bundle_path = File.join(
      '/tmp',
      "sanemaster-verify-#{Digest::SHA256.hexdigest("#{File.expand_path(local_repo)}:#{head}")[0, 16]}.bundle"
    )
    needs_bundle = !head.empty? &&
                   !bundle_branch.empty? && bundle_branch != 'HEAD' &&
                   !mini_repo_has_commit?(scratch_repo, head)
    sync_git_bundle_to_mini!(local_repo, bundle_branch, remote_bundle_path) if needs_bundle

    remote_cmd = <<~SH
      set -e
      scratch=#{Shellwords.escape(scratch_repo)}
      canonical=#{Shellwords.escape(remote_repo)}
      bundle_path=#{Shellwords.escape(remote_bundle_path)}
      cleanup() { rm -f "$bundle_path"; }
      trap cleanup EXIT
      if [ ! -d "$scratch/.git" ]; then
        mkdir -p "$(dirname "$scratch")"
        rm -rf "$scratch"
        if [ -d "$canonical/.git" ]; then
          git clone --no-checkout "$canonical" "$scratch" >/dev/null 2>&1
        else
          mkdir -p "$scratch"
          git -C "$scratch" init -q
        fi
      fi
      cd "$scratch"
      if [ -n #{Shellwords.escape(head)} ] && ! git rev-parse --verify #{Shellwords.escape("#{head}^{commit}")} >/dev/null 2>&1; then
        if [ -f "$bundle_path" ]; then
          git fetch "$bundle_path" #{Shellwords.escape(branch)} >/dev/null 2>&1 || true
        fi
        if [ -d "$canonical/.git" ]; then
          git fetch "$canonical" >/dev/null 2>&1 || true
        fi
      fi
      if [ -n #{Shellwords.escape(head)} ] && git rev-parse --verify #{Shellwords.escape("#{head}^{commit}")} >/dev/null 2>&1; then
        git checkout -q -B #{Shellwords.escape(branch)} #{Shellwords.escape(head)} 2>/dev/null || true
        git reset -q --hard #{Shellwords.escape(head)} 2>/dev/null || true
      fi
    SH
    ok = ssh_system('mini', remote_cmd)
    abort '❌ Failed to prepare the routed verify workspace on the mini.' unless ok

    route_log("🔄 Syncing local workspace snapshot to mini (#{scratch_repo})")
    sync_local_dir_to_mini!(local_repo, scratch_repo, label: nil)
    apply_git_deleted_paths_to_mini!(local_repo, scratch_repo)
    scratch_repo
  end

  def routed_release_path_for_local(local_path, local_repo = Dir.pwd)
    absolute_path = File.expand_path(local_path)
    relative_path = if absolute_path.start_with?('/Users/sj/')
                      absolute_path.delete_prefix('/Users/sj/')
                    elsif absolute_path.start_with?('/Users/stephansmac/')
                      absolute_path.delete_prefix('/Users/stephansmac/')
                    else
                      abort "❌ Could not mirror path into routed release workspace: #{absolute_path}"
                    end
    File.join(mini_release_workspace_root(local_repo), relative_path)
  end

  def routed_release_env_context(local_repo)
    {
      'RELEASE_PEER_HOST' => 'Stephans-MacBook-Air.local',
      'RELEASE_PEER_REPO_PATH' => File.expand_path(local_repo),
      'RELEASE_PEER_BRANCH' => current_git_branch(local_repo)
    }
  end

  def current_git_branch(repo_dir)
    branch, status = Open3.capture2('git', '-C', repo_dir, 'rev-parse', '--abbrev-ref', 'HEAD')
    status.success? ? branch.to_s.strip : ''
  rescue StandardError
    ''
  end

  def current_git_head(repo_dir)
    head, status = Open3.capture2('git', '-C', repo_dir, 'rev-parse', 'HEAD')
    status.success? ? head.to_s.strip : ''
  rescue StandardError
    ''
  end

  def git_remote_url(repo_dir, remote = 'origin')
    remote_url, status = Open3.capture2('git', '-C', repo_dir, 'remote', 'get-url', remote)
    status.success? ? remote_url.to_s.strip : ''
  rescue StandardError
    ''
  end

  def release_routed_command?(command)
    %w[release upgrade_path_proof release_preflight appstore_preflight asp].include?(command)
  end

  def routed_command_requires_support_repo_sync?(command)
    command == 'release'
  end

  def setapp_route_command?(command)
    SETAPP_ROUTE_COMMANDS.include?(command)
  end

  def saneprocess_repo_root
    File.expand_path('..', __dir__)
  end

  def saneapps_root
    File.expand_path('../..', saneprocess_repo_root)
  end

  def infra_scripts_root
    File.expand_path('../scripts', saneprocess_repo_root)
  end

  def saneui_repo_root
    File.expand_path('../../SaneUI', __dir__)
  end

  def workspace_uses_saneui?(local_dir)
    system(
      'rg',
      '-q',
      '\bimport\s+SaneUI\b',
      File.expand_path(local_dir),
      out: File::NULL,
      err: File::NULL
    )
  rescue StandardError
    false
  end

  def sane_email_automation_repo_root
    File.expand_path('~/SaneApps/infra/sane-email-automation')
  end

  # Setapp app workspaces must land where the EXECUTING SaneProcess copy will
  # look for them. Non-release routes execute SaneProcess from the scratch
  # verify workspace, so the app repos mirror into the same scratch root
  # (relative ../../apps/<App> lookups stay consistent); release routes keep
  # their own routed-release mapping via the caller. Canonical Mini repos are
  # never written either way.
  def sync_setapp_app_workspaces_to_mini!(release_routed: false)
    setapp_enabled_app_dirs.each do |app_dir|
      local_repo = File.join(saneapps_root, 'apps', app_dir)
      next unless Dir.exist?(local_repo)

      remote_repo = if release_routed
                      routed_release_path_for_local(local_repo)
                    else
                      routed_verify_path_for_local(local_repo)
                    end
      abort "❌ Could not map Setapp app #{app_dir} to mini: #{local_repo}" unless remote_repo

      sync_local_dir_to_mini!(local_repo, remote_repo, label: "#{app_dir} Setapp app")
    end
  end

  def setapp_enabled_app_dirs
    apps_root = File.join(saneapps_root, 'apps')
    return [] unless Dir.exist?(apps_root)

    Dir.children(apps_root).sort.select do |entry|
      app_dir = File.join(apps_root, entry)
      manifest_path = File.join(app_dir, '.saneprocess')
      next false unless File.directory?(app_dir) && File.file?(manifest_path)

      data = YAML.safe_load(File.read(manifest_path), aliases: true) || {}
      data.dig('setapp', 'enabled') == true
    rescue Psych::Exception => e
      abort "❌ Setapp manifest could not be parsed before Mini sync: #{manifest_path} (#{e.message})"
    end
  end

  def run_external_command(*command)
    success = system(*command)
    exit($CHILD_STATUS&.exitstatus || (success ? 0 : 1))
  end

  def run_external_command_with_workflow_receipt(workflow, *command)
    started_at = Time.now.utc
    success = system(*command)
    completed_at = Time.now.utc
    exit_status = $CHILD_STATUS&.exitstatus || (success ? 0 : 1)
    route_metadata = respond_to?(:workflow_receipt_route_metadata, true) ? workflow_receipt_route_metadata(workflow, success: success) : {}
    unless ENV['SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT'] == '1'
      receipt_id = SecureRandom.hex(16)
      recorded = record_process_metric(
        'workflow_receipt',
        {
          schema_version: 3,
          receipt_id: receipt_id,
          workflow: workflow,
          success: success,
          command: command.join(' '),
          command_sha256: Digest::SHA256.hexdigest(command.join("\0")),
          started_at: started_at.iso8601,
          completed_at: completed_at.iso8601,
          duration_ms: ((completed_at - started_at) * 1000).round,
          exit_status: exit_status,
          host: Socket.gethostname
        }.merge(route_metadata)
      ) if respond_to?(:record_process_metric)
      warn "SANEMASTER_WORKFLOW_RECEIPT=#{receipt_id}" if recorded
    end
    exit(exit_status)
  end

  def record_sanemaster_workflow_receipt(command, args, started_at, exit_status)
    return if ENV['SANEMASTER_SUPPRESS_WORKFLOW_RECEIPT'] == '1'

    completed_at = Time.now.utc
    command_parts = ['ruby', File.join(saneprocess_repo_root, 'scripts', 'SaneMaster.rb'), *Array(args)]
    workflow = "sanemaster:#{command}"
    route_metadata = respond_to?(:workflow_receipt_route_metadata, true) ? workflow_receipt_route_metadata(workflow, success: exit_status.to_i.zero?) : {}
    if command.to_s == 'release_preflight' && exit_status.to_i.zero? && respond_to?(:release_status_source_fingerprint, true)
      route_metadata = route_metadata.merge(source_fingerprint: release_status_source_fingerprint(Dir.pwd))
    end
    receipt_id = SecureRandom.hex(16)
    recorded = record_process_metric(
      'workflow_receipt',
      {
        schema_version: 3,
        receipt_id: receipt_id,
        workflow: workflow,
        success: exit_status.to_i.zero?,
        command: command_parts.join(' '),
        command_sha256: Digest::SHA256.hexdigest(command_parts.join("\0")),
        started_at: started_at.iso8601,
        completed_at: completed_at.iso8601,
        duration_ms: ((completed_at - started_at) * 1000).round,
        exit_status: exit_status.to_i,
        host: Socket.gethostname,
        client: ENV['CLAUDECODE'] || ENV['CLAUDE_CODE'] ? 'claude' : (ENV['CODEX_HOME'] ? 'codex' : 'unknown')
      }.merge(route_metadata)
    )
    warn "SANEMASTER_WORKFLOW_RECEIPT=#{receipt_id}" if recorded
  rescue StandardError => e
    warn "⚠️  Could not record workflow receipt: #{e.message}" if ENV['DEBUG']
  end

  def run_status(args = [])
    script = File.join(saneprocess_repo_root, 'scripts', 'automation', 'sane-status-crossref.sh')
    run_external_command_with_workflow_receipt('status', 'bash', script, *args)
  end

  def run_check_inbox(args = [])
    script = File.join(infra_scripts_root, 'check-inbox.sh')
    forwarded_args = args.empty? ? ['check'] : args
    run_external_command_with_workflow_receipt('check_inbox', script, *forwarded_args)
  end

  def run_business_appointment(args = [])
    script = File.join(saneprocess_repo_root, 'scripts', 'automation', 'business_appointment.rb')
    run_external_command_with_workflow_receipt('business_appointment', 'ruby', script, *args)
  end

  def run_python_automation_script(script_name, args)
    script = File.join(saneprocess_repo_root, 'scripts', 'automation', script_name)
    unless File.exist?(script)
      puts "❌ #{script_name} not found at #{script}"
      exit 1
    end

    system('python3', script, *args)
    exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
  end

  def run_sync_mini(args = [])
    run_mini_sync_script('sync-codex-mini.sh', args)
  end

  def run_sync_grok(args = [])
    run_mini_sync_script('sync-grok-mini.sh', args)
  end

  def run_mini_sync_script(script_name, args)
    script = File.join(saneprocess_repo_root, 'scripts', 'automation', script_name)
    forwarded_args = if args.empty? || args.first.start_with?('-')
                       ['mini', *args]
                     else
                       args
                     end
    run_external_command('bash', script, *forwarded_args)
  end

  def sync_release_support_repos_to_mini!(release_routed: false, command: nil)
    webhook_repo = sane_email_automation_repo_root
    return unless Dir.exist?(webhook_repo)

    remote_webhook_repo = map_local_path_to_mini(webhook_repo)
    abort "❌ Could not map sane-email-automation to mini: #{webhook_repo}" unless remote_webhook_repo

    if release_routed
      return nil unless routed_command_requires_support_repo_sync?(command)

      prepare_release_support_repo_on_mini!(webhook_repo, remote_webhook_repo)
    else
      sync_local_dir_to_mini!(webhook_repo, remote_webhook_repo, label: 'sane-email-automation')
      remote_webhook_repo
    end
  end

  def prepare_release_support_repo_on_mini!(local_repo, remote_repo)
    branch = current_git_branch(local_repo)
    branch = 'main' if branch.empty? || branch == 'HEAD'
    head = current_git_head(local_repo)
    remote_sync = local_repo_remote_sync_context(local_repo, branch, head)

    if !repo_has_uncommitted_changes_at?(local_repo) && remote_sync['status'] == 'matches'
      return prepare_release_workspace_on_mini!(local_repo, remote_repo)
    end

    route_log("⚠️  sane-email-automation local #{branch} is #{remote_sync['status']}; using a clean mini/origin checkout for routed release support.")
    scratch_root = mini_release_workspace_root(local_repo)
    scratch_repo = routed_release_path_for_local(local_repo)
    prune_stale_mini_release_workspaces!(local_repo, current_workspace_root: scratch_root)
    remote_cmd = <<~SH
      set -e
      scratch_root=#{Shellwords.escape(scratch_root)}
      scratch_repo=#{Shellwords.escape(scratch_repo)}
      remote_repo=#{Shellwords.escape(remote_repo)}
      branch=#{Shellwords.escape(branch)}
      python3 - <<'PY'
import os
import shutil

scratch_root = #{scratch_root.dump}
if os.path.exists(scratch_root):
    shutil.rmtree(scratch_root, ignore_errors=False)
PY
      [ ! -e "$scratch_root" ]
      mkdir -p #{Shellwords.escape(File.dirname(scratch_repo))}
      git clone --no-checkout "$remote_repo" "$scratch_repo" >/dev/null
      cd "$scratch_repo"
      GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git fetch --tags origin >/dev/null 2>&1 || true
      if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git checkout -B "$branch" "origin/$branch" >/dev/null 2>&1
        git branch --set-upstream-to "origin/$branch" "$branch" >/dev/null 2>&1 || true
        git reset --hard "origin/$branch" >/dev/null 2>&1
      else
        git checkout "$(git rev-parse HEAD)" >/dev/null 2>&1
      fi
      git clean -fdx >/dev/null 2>&1
    SH
    ok = ssh_system('mini', remote_cmd)
    abort '❌ Failed to prepare a clean routed sane-email-automation workspace on the mini.' unless ok

    scratch_repo
  end

  def sync_release_support_repos_from_origin!
    webhook_repo = sane_email_automation_repo_root
    return unless Dir.exist?(webhook_repo)

    fast_forward_local_repo_from_origin!(webhook_repo, label: 'sane-email-automation')
  end

  def fast_forward_local_repo_from_origin!(repo_dir, label:)
    status_output, status = Open3.capture2('git', '-C', repo_dir, 'status', '--porcelain')
    unless status.success?
      warn "⚠️  Could not inspect #{label} status after routed release; skipping local sync."
      return
    end

    unless status_output.to_s.strip.empty?
      warn "⚠️  #{label} has local changes after routed release; skipping automatic local sync from origin."
      return
    end

    branch_output, branch_status = Open3.capture2('git', '-C', repo_dir, 'rev-parse', '--abbrev-ref', 'HEAD')
    branch = branch_output.to_s.strip
    unless branch_status.success? && !branch.empty? && branch != 'HEAD'
      warn "⚠️  Could not determine #{label} branch after routed release; skipping local sync."
      return
    end

    fetch_ok = system('git', '-C', repo_dir, 'fetch', 'origin', branch)
    unless fetch_ok
      warn "⚠️  Failed to fetch #{label} from origin after routed release."
      return
    end

    pull_ok = system('git', '-C', repo_dir, 'pull', '--ff-only', 'origin', branch)
    warn "⚠️  Failed to fast-forward #{label} from origin after routed release." unless pull_ok
  end

  def normalize_mini_repo_after_route!(local_repo, remote_repo, label:)
    return if remote_repo.nil? || remote_repo.empty?
    return if repo_has_uncommitted_changes_at?(local_repo)

    branch = current_git_branch(local_repo)
    head = current_git_head(local_repo)
    remote_sync = local_repo_remote_sync_context(local_repo, branch, head)
    return unless remote_sync['status'] == 'matches'

    remote_cmd = <<~SH
      set -e
      cd #{Shellwords.escape(remote_repo)}
      branch=#{Shellwords.escape(branch)}
      git fetch origin "$branch" >/dev/null 2>&1 || exit 0
      current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      [ "$current_branch" = "$branch" ] || exit 0
      counts=$(git rev-list --left-right --count "$branch...origin/$branch" 2>/dev/null || echo "0 0")
      ahead=$(printf '%s' "$counts" | awk '{print $1}')
      [ "${ahead:-0}" = "0" ] || exit 0
      git reset --mixed "origin/$branch" >/dev/null 2>&1 || exit 0
    SH

    ok = ssh_system('mini', remote_cmd, out: File::NULL, err: File::NULL)
    warn "⚠️  Failed to normalize #{label} on the mini after routed sync." unless ok
    ok
  end

  def sync_cktool_auth_to_mini!
    local_cktool_path = File.expand_path('~/.config/cktool')
    return unless File.exist?(local_cktool_path)

    remote_cktool_path = map_local_path_to_mini(local_cktool_path)
    abort "❌ Could not map cktool config to mini: #{local_cktool_path}" unless remote_cktool_path

    remote_parent = File.dirname(remote_cktool_path)
    ok = ssh_system('mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
    abort '❌ Failed to prepare cktool auth parent on the mini.' unless ok

    if File.directory?(local_cktool_path)
      route_log("⚠️ Local cktool auth path is a directory; syncing legacy contents to mini (#{remote_cktool_path})")
      ok = ssh_system(
        'mini',
        "if [ -f #{Shellwords.escape(remote_cktool_path)} ]; then /usr/bin/trash #{Shellwords.escape(remote_cktool_path)}; fi && mkdir -p #{Shellwords.escape(remote_cktool_path)}"
      )
      abort '❌ Failed to prepare legacy cktool auth directory on the mini.' unless ok

      ok = route_system(
        'rsync',
        '-az',
        '--delete',
        "#{local_cktool_path}/",
        "mini:#{remote_cktool_path}/"
      )
      abort '❌ Failed to sync legacy cktool auth directory to the mini.' unless ok
      return
    end

    ok = ssh_system(
      'mini',
      "if [ -d #{Shellwords.escape(remote_cktool_path)} ]; then /usr/bin/trash #{Shellwords.escape(remote_cktool_path)} 2>/dev/null || [ ! -e #{Shellwords.escape(remote_cktool_path)} ]; fi"
    )
    abort '❌ Failed to clear stale cktool auth directory on the mini.' unless ok

    route_log("🔄 Syncing cktool auth to mini (#{remote_cktool_path})")
    ok = route_system(
      'rsync',
      '-az',
      local_cktool_path,
      "mini:#{remote_cktool_path}"
    )
    abort '❌ Failed to sync cktool auth file to the mini.' unless ok
  end

  def sync_local_dir_to_mini!(local_dir, remote_dir, label: nil)
    route_log("🔄 Syncing #{label} to mini (#{remote_dir})") if label
    remote_parent = File.dirname(remote_dir)
    ok = ssh_system('mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
    abort "❌ Failed to prepare mini destination for #{label || 'the current workspace snapshot'}." unless ok

    ok = route_system(
      'rsync',
      '-az',
      '--delete',
      '--exclude', '.git',
      '--exclude', '.worktrees',
      '--exclude', '.build',
      '--exclude', 'build',
      '--include', 'outputs/',
      '--include', 'outputs/customer_ui_action_receipt.json',
      '--include', 'outputs/upgrade_path_behavioral_receipt.json',
      '--include', 'outputs/upgrade-path-proof/',
      '--include', 'outputs/upgrade-path-proof/***',
      '--include', 'outputs/customer-ui/',
      '--include', 'outputs/customer-ui/***',
      '--include', 'outputs/runtime-preflight/',
      '--include', 'outputs/runtime-preflight/***',
      '--exclude', 'outputs/***',
      '--exclude', 'DerivedData',
      '--exclude', 'node_modules',
      '--exclude', 'vendor/bundle',
      '--exclude', 'test_output.txt',
      "#{File.expand_path(local_dir)}/",
      "mini:#{remote_dir}/"
    )
    abort "❌ Failed to sync #{label || 'the current workspace snapshot'} to the mini." unless ok

    sync_ignored_test_assets_to_mini!(local_dir, remote_dir)
  end

  def sync_ignored_test_assets_to_mini!(local_dir, remote_dir)
    assets_dir = File.join(File.expand_path(local_dir), 'Tests', 'Assets')
    return unless Dir.exist?(assets_dir)

    remote_assets_dir = File.join(remote_dir, 'Tests', 'Assets')
    ok = route_system(
      'rsync',
      '-az',
      '--delete',
      "#{assets_dir}/",
      "mini:#{remote_assets_dir}/"
    )
    abort "❌ Failed to sync ignored test assets to the mini." unless ok
  end

  def prepare_remote_repo_for_command!(remote_repo)
    remote_cmd = <<~SH
      set -e
      cd #{Shellwords.escape(remote_repo)}
      if [ -f project.yml ] && ! ls *.xcodeproj >/dev/null 2>&1; then
        xcodegen generate >/dev/null
      fi
    SH
    ok = ssh_system('mini', remote_cmd)
    return if ok

    abort '❌ Failed to prepare the mini workspace after sync.'
  end

  def write_route_context_to_mini!(remote_repo, command, webhook_remote_repo: nil)
    context = build_route_context(command, webhook_remote_repo: webhook_remote_repo)
    remote_context_dir = File.join(remote_repo, '.sanemaster')
    remote_context_path = File.join(remote_context_dir, 'mini_route_context.json')
    ok = ssh_system('mini', "mkdir -p #{Shellwords.escape(remote_context_dir)}")
    abort '❌ Failed to prepare the mini route-context directory.' unless ok

    Tempfile.create(['sanemaster-route-context', '.json']) do |tmp|
      tmp.write(JSON.pretty_generate(context))
      tmp.flush
      ok = system('rsync', '-az', tmp.path, "mini:#{remote_context_path}")
      abort '❌ Failed to sync Mini route context.' unless ok
    end
  end

  def build_route_context(command, webhook_remote_repo: nil)
    context = {
      'created_at' => Time.now.utc.iso8601,
      'source_host' => Socket.gethostname,
      'command' => command,
      'workspace' => local_repo_route_context(Dir.pwd)
    }
    webhook_repo = sane_email_automation_repo_root
    if Dir.exist?(webhook_repo)
      context['webhook'] = webhook_route_context(webhook_repo, remote_repo_path: webhook_remote_repo)
    end
    context
  end

  def local_repo_route_context(repo_dir)
    dirty_output, = Open3.capture2('git', '-C', repo_dir, 'status', '--porcelain')
    branch, = Open3.capture2('git', '-C', repo_dir, 'rev-parse', '--abbrev-ref', 'HEAD')
    head, = Open3.capture2('git', '-C', repo_dir, 'rev-parse', 'HEAD')
    # The last reachable release tag is the release boundary. Comparing it
    # directly to the working tree includes every unreleased commit plus staged
    # and unstaged changes; repos without a release tag compare to the empty tree.
    swift_diff_range = release_unreleased_history_base(repo_dir)
    changed_files_output, changed_files_status = Open3.capture2(
      'git', '-C', repo_dir, 'diff', swift_diff_range, '--name-only', '--', '*.swift'
    )
    changed_diff_output, changed_diff_status = Open3.capture2(
      'git', '-C', repo_dir, 'diff', swift_diff_range, '--unified=3', '--no-color', '--no-ext-diff', '--', '*.swift'
    )
    untracked_output, untracked_status = Open3.capture2(
      'git', '-C', repo_dir, 'ls-files', '-z', '--others', '--exclude-standard', '--', '*.swift'
    )
    untracked_swift_files = untracked_status.success? ? untracked_output.split("\0").reject(&:empty?) : []
    untracked_swift_diff, untracked_error = route_context_untracked_swift_diff(repo_dir, untracked_swift_files)
    diff_errors = []
    diff_errors << 'git diff --name-only failed' unless changed_files_status.success?
    diff_errors << 'git diff failed' unless changed_diff_status.success?
    diff_errors << 'git ls-files for untracked Swift failed' unless untracked_status.success?
    diff_errors << untracked_error if untracked_error
    stash_reports = if respond_to?(:auto_reconcile_stash_reports)
                      auto_reconcile_stash_reports(repo_path: repo_dir).map do |report|
                        {
                          'ref' => report[:ref].to_s,
                          'stash_sha' => report[:stash_sha].to_s,
                          'subject' => report[:subject].to_s,
                          'blocking_files' => Array(report[:blocking_files]).map(&:to_s)
                        }
                      end
                    else
                      []
                    end

    {
      'path' => repo_dir,
      'branch' => branch.to_s.strip,
      'head' => head.to_s.strip,
      'dirty_count' => dirty_output.to_s.lines.reject { |line| line.strip.empty? }.count,
      'dirty_files' => dirty_output.to_s.lines.map(&:chomp).reject(&:empty?),
      'auto_reconcile_stash_reports' => stash_reports,
      'recent_changed_swift_files' => if changed_files_status.success?
                                        (changed_files_output.to_s.lines.map(&:strip) + untracked_swift_files).reject(&:empty?).uniq.sort
                                      else
                                        untracked_swift_files.uniq.sort
                                      end,
      'recent_swift_diff' => changed_diff_status.success? ? changed_diff_output.to_s + untracked_swift_diff : '',
      'recent_swift_diff_error' => diff_errors.join('; '),
      'remote_sync' => local_repo_remote_sync_context(repo_dir, branch.to_s.strip, head.to_s.strip)
    }
  rescue StandardError => e
    {
      'path' => repo_dir,
      'branch' => '',
      'head' => '',
      'dirty_count' => 0,
      'dirty_files' => [],
      'auto_reconcile_stash_reports' => [],
      'recent_changed_swift_files' => [],
      'recent_swift_diff' => '',
      'recent_swift_diff_error' => "route context failed: #{e.class}: #{e.message}",
      'remote_sync' => { 'status' => 'unavailable' }
    }
  end

  def route_context_untracked_swift_diff(repo_dir, paths)
    chunks = paths.map do |relative_path|
      absolute_path = File.expand_path(relative_path, repo_dir)
      repo_root = File.realpath(repo_dir)
      metadata = File.lstat(absolute_path)
      raise "symlink or non-regular untracked Swift path: #{relative_path}" unless metadata.file?
      raise "untracked Swift file exceeds #{ROUTE_CONTEXT_UNTRACKED_SWIFT_MAX_BYTES} bytes: #{relative_path}" if metadata.size > ROUTE_CONTEXT_UNTRACKED_SWIFT_MAX_BYTES

      real_path = File.realpath(absolute_path)
      unless real_path.start_with?("#{repo_root}/")
        raise "untracked Swift path escapes repository: #{relative_path}"
      end

      contents = File.binread(real_path, ROUTE_CONTEXT_UNTRACKED_SWIFT_MAX_BYTES + 1)
      raise "untracked Swift file grew beyond size limit: #{relative_path}" if contents.bytesize > ROUTE_CONTEXT_UNTRACKED_SWIFT_MAX_BYTES
      contents = contents.force_encoding(Encoding::UTF_8)
      contents = contents.scrub('?') unless contents.valid_encoding?
      source = JSON.generate("a/#{relative_path}")
      destination = JSON.generate("b/#{relative_path}")
      added = contents.each_line.map { |line| "+#{line}" }.join
      added << "\n" unless added.empty? || added.end_with?("\n")
      "diff --git #{source} #{destination}\n--- /dev/null\n+++ #{destination}\n#{added}"
    end
    [chunks.join, nil]
  rescue StandardError => e
    ['', "unable to include untracked Swift: #{e.message}"]
  end

  def local_repo_remote_sync_context(repo_dir, branch, head)
    return { 'status' => 'detached', 'branch' => branch } if branch.empty? || branch == 'HEAD'

    remote_ref_out, remote_ref_status = Open3.capture2('git', '-C', repo_dir, 'ls-remote', '--heads', 'origin', branch)
    remote_ref = remote_ref_out.to_s.split.first.to_s.strip
    unless remote_ref_status.success? && !remote_ref.empty?
      return { 'status' => 'unavailable', 'branch' => branch }
    end

    remote_is_ancestor = system('git', '-C', repo_dir, 'merge-base', '--is-ancestor', remote_ref, head,
                                out: File::NULL, err: File::NULL)
    local_is_ancestor = system('git', '-C', repo_dir, 'merge-base', '--is-ancestor', head, remote_ref,
                               out: File::NULL, err: File::NULL)

    return { 'status' => 'matches', 'branch' => branch, 'remote_ref' => remote_ref } if head == remote_ref

    if remote_is_ancestor && !local_is_ancestor
      ahead_count, = Open3.capture2('git', '-C', repo_dir, 'rev-list', '--count', "#{remote_ref}..#{head}")
      return {
        'status' => 'ahead',
        'branch' => branch,
        'remote_ref' => remote_ref,
        'ahead_count' => ahead_count.to_s.strip
      }
    end

    if local_is_ancestor && !remote_is_ancestor
      return { 'status' => 'behind', 'branch' => branch, 'remote_ref' => remote_ref }
    end

    { 'status' => 'diverged', 'branch' => branch, 'remote_ref' => remote_ref }
  rescue StandardError
    { 'status' => 'unavailable', 'branch' => branch }
  end

  def webhook_route_context(repo_dir, remote_repo_path: nil)
    webhook_file = File.join(repo_dir, 'src', 'handlers', 'webhook-lemonsqueezy.js')
    remote_root = remote_repo_path || repo_dir
    content = File.exist?(webhook_file) ? File.read(webhook_file) : ''
    product_versions = {}
    content.scan(/'([^']+)':\s*\{\s*file:\s*'[^']+-([^']+)\.(?:zip|dmg)'/).each do |product_name, version|
      product_versions[product_name] = version
    end

    last_commit_epoch, status = Open3.capture2(
      'git', '-C', repo_dir, 'log', '-1', '--format=%ct', '--', 'src/handlers/webhook-lemonsqueezy.js'
    )

    {
      'path' => repo_dir,
      'file_path' => webhook_file,
      'remote_path' => remote_root,
      'remote_file_path' => File.join(remote_root, 'src', 'handlers', 'webhook-lemonsqueezy.js'),
      'product_versions' => product_versions,
      'last_commit_epoch' => status.success? ? last_commit_epoch.to_s.strip.to_i : 0
    }
  rescue StandardError
    {
      'path' => repo_dir,
      'file_path' => File.join(repo_dir, 'src', 'handlers', 'webhook-lemonsqueezy.js'),
      'remote_path' => remote_repo_path || repo_dir,
      'remote_file_path' => File.join(remote_repo_path || repo_dir, 'src', 'handlers', 'webhook-lemonsqueezy.js'),
      'product_versions' => {},
      'last_commit_epoch' => 0
    }
  end

  def sync_outputs_from_mini!(local_repo, remote_repo)
    remote_outputs_dir = File.join(remote_repo, 'outputs')
    return unless mini_path_exists_fast?(remote_outputs_dir)

    local_outputs_dir = File.join(File.expand_path(local_repo), 'outputs')
    FileUtils.mkdir_p(local_outputs_dir)
    ok = route_system(
      'rsync',
      '-az',
      '--no-links',
      *mini_output_receipt_rsync_filters,
      "mini:#{remote_outputs_dir}/",
      "#{local_outputs_dir}/"
    )
    warn '⚠️  Failed to sync Mini outputs back to the local workspace.' unless ok
    sync_sane_receipts_from_mini!(local_repo, remote_repo)
  end

  def sync_sane_receipts_from_mini!(local_repo, remote_repo)
    remote_receipt = File.join(remote_repo, '.sane', 'customer_ui_action_receipt.json')
    return unless mini_path_exists_fast?(remote_receipt)

    local_sane_dir = File.join(File.expand_path(local_repo), '.sane')
    FileUtils.mkdir_p(local_sane_dir)
    ok = route_system(
      'rsync',
      '-az',
      '--no-links',
      "mini:#{remote_receipt}",
      "#{local_sane_dir}/customer_ui_action_receipt.json"
    )
    warn '⚠️  Failed to sync Mini .sane customer UI receipt back to the local workspace.' unless ok
  end

  def mini_output_receipt_rsync_filters
    [
      '--include', 'qa_status.json',
      '--include', 'release_preflight_status.json',
      '--include', 'appstore_preflight_status.json',
      '--include', 'upgrade_path_behavioral_receipt.json',
      '--include', 'upgrade-path-proof/',
      '--include', 'upgrade-path-proof/***',
      '--include', 'customer_ui_action_receipt.json',
      '--include', 'validation/',
      '--include', 'validation/qa_status.json',
      '--include', 'customer-ui/',
      '--include', 'customer-ui/***',
      '--include', 'runtime-preflight/',
      '--include', 'runtime-preflight/***',
      '--include', 'visual_smoke/',
      '--include', 'visual_smoke/***',
      '--include', 'process-abtest/',
      '--include', 'process-abtest/***',
      '--exclude', '*'
    ]
  end

  def cleanup_bulk_outputs_on_mini!(remote_repo)
    remote_outputs_dir = File.join(remote_repo, 'outputs')
    return unless mini_path_exists_fast?(remote_outputs_dir)

    remote_cmd = <<~SH
      set -e
      out=#{Shellwords.escape(remote_outputs_dir)}
      [ -d "$out" ] || exit 0
      find "$out" -mindepth 1 -maxdepth 1 -print | while IFS= read -r path; do
        base=${path##*/}
        case "$base" in
          qa_status.json|release_preflight_status.json|appstore_preflight_status.json|upgrade_path_behavioral_receipt.json|upgrade-path-proof|customer_ui_action_receipt.json|validation|customer-ui|runtime-preflight|visual_smoke|process-abtest) continue ;;
        esac
        /usr/bin/trash "$path" 2>/dev/null || trash "$path" 2>/dev/null || true
      done
    SH
    ok = ssh_system('mini', remote_cmd, out: File::NULL, err: File::NULL)
    warn '⚠️  Failed to prune bulk Mini outputs after routed run.' unless ok
  end

  def sync_release_artifacts_to_mini!(local_repo, remote_repo)
    release_artifact_relative_paths.each do |relative_path|
      local_path = File.join(File.expand_path(local_repo), relative_path)
      next unless File.exist?(local_path)

      remote_path = File.join(remote_repo, relative_path)
      remote_parent = File.dirname(remote_path)
      ok = ssh_system('mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
      abort "❌ Failed to prepare mini destination for routed release artifacts (#{relative_path})." unless ok

      route_log("🔄 Syncing routed release artifacts to mini (#{remote_path})")
      if File.directory?(local_path)
        ok = route_system('rsync', '-az', '--delete', "#{local_path}/", "mini:#{remote_path}/")
      else
        ok = route_system('rsync', '-az', local_path, "mini:#{remote_path}")
      end
      abort "❌ Failed to sync routed release artifacts for #{relative_path} to the mini." unless ok
    end
  end

  def route_appstore_preflight_package_to_mini(command, args, execution_repo)
    routed_args = Array(args).dup
    return [routed_args, nil] unless %w[appstore_preflight asp].include?(command.to_s)

    package_index = routed_args.index('--pkg')
    return [routed_args, nil] unless package_index

    package_argument = routed_args[package_index + 1].to_s
    abort '❌ appstore_preflight --pkg requires a package path.' if package_argument.empty?

    local_package = File.expand_path(package_argument, Dir.pwd)
    abort "❌ App Store preflight package not found: #{local_package}" unless File.file?(local_package)

    digest = Digest::SHA256.file(local_package).hexdigest
    binding_root = File.join(execution_repo, 'outputs', 'appstore-preflight-bindings')
    binding_dir = File.join(binding_root, digest)
    remote_package = File.join(binding_dir, File.basename(local_package))
    ok = ssh_system(
      'mini',
      "mkdir -p #{Shellwords.escape(binding_dir)} && chmod 700 #{Shellwords.escape(binding_root)} #{Shellwords.escape(binding_dir)}"
    )
    abort '❌ Failed to prepare Mini App Store preflight package binding directory.' unless ok

    ok = route_system('rsync', '-az', '--no-links', local_package, "mini:#{remote_package}")
    abort '❌ Failed to sync exact App Store preflight package to the Mini.' unless ok
    ok = ssh_system('mini', "chmod 400 #{Shellwords.escape(remote_package)}")
    abort '❌ Failed to lock exact App Store preflight package on the Mini.' unless ok

    routed_args[package_index + 1] = remote_package
    [routed_args, binding_dir]
  end

  def cleanup_routed_appstore_preflight_package(binding_dir)
    return if binding_dir.to_s.empty?

    parent = File.dirname(binding_dir)
    command = <<~SH
      /usr/bin/trash #{Shellwords.escape(binding_dir)} 2>/dev/null || trash #{Shellwords.escape(binding_dir)} 2>/dev/null || true
      rmdir #{Shellwords.escape(parent)} 2>/dev/null || true
    SH
    ssh_system('mini', command, out: File::NULL, err: File::NULL)
  end

  def sync_release_artifacts_from_mini!(local_repo, remote_repo, warn_only: false)
    release_artifact_relative_paths.each do |relative_path|
      remote_path = File.join(remote_repo, relative_path)
      next unless mini_path_exists_fast?(remote_path)

      local_path = File.join(File.expand_path(local_repo), relative_path)
      FileUtils.mkdir_p(File.dirname(local_path))
      ok = if mini_directory?(remote_path)
             FileUtils.mkdir_p(local_path)
             route_system('rsync', '-az', '--delete', "mini:#{remote_path}/", "#{local_path}/")
           else
             route_system('rsync', '-az', "mini:#{remote_path}", "#{local_path}")
           end
      next if ok

      message = "⚠️  Failed to sync routed release artifacts for #{relative_path} back from the mini."
      warn_only ? warn(message) : abort(message)
    end
  end

  def release_artifact_relative_paths
    %w[build releases]
  end

  def mini_directory?(remote_path)
    ssh_system(
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
      'mini',
      "test -d #{Shellwords.escape(remote_path)}",
      out: File::NULL,
      err: File::NULL
    )
  end

  def mini_path_exists_fast?(remote_path)
    ssh_system(
      '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
      'mini',
      "test -e #{Shellwords.escape(remote_path)}",
      out: File::NULL,
      err: File::NULL
    )
  end

  def dispatch_command(command, args)
    # Check for --help flag on any command
    if args.include?('--help') || args.include?('-h')
      print_command_detail(command)
      return
    end

    case command
    # Diagnostics
    when 'diagnose'
      diagnose_args = parse_diagnose_args(args)
      diagnose(diagnose_args[:path], dump: diagnose_args[:dump])
    when 'runtime_snapshot', 'runtime_evidence', 'runtime-evidence', 'lldb_snapshot'
      success = runtime_snapshot(args)
      exit(success ? 0 : 1)
    when 'visual_smoke', 'visual-smoke'
      success = visual_smoke(args)
      exit(success ? 0 : 1)
    when 'resource_soak', 'resource-soak'
      resource_soak(args)
    when 'crash_report', 'crashes'
      analyze_crashes(args)
    when 'menu_scan'
      menu_scan(args)
    when 'validation_report', 'validation-report'
      run_external_command_with_workflow_receipt(
        'validation_report',
        'ruby',
        File.join(saneprocess_repo_root, 'scripts', 'validation_report.rb'),
        *args
      )
    when 'process_metrics', 'sop_metrics'
      process_metrics_dashboard(args)
    when 'route_cost_review', 'route-cost-review', 'rcr'
      route_cost_review(args)
    when 'near_miss_review', 'near-miss-review', 'nmr'
      near_miss_review(args)
    when 'verify_failure_review', 'verify-failure-review', 'vfr'
      verify_failure_review(args)
    when 'process_eval', 'process-eval'
      success = process_eval(args)
      exit(success ? 0 : 1)
    when 'trace_eval', 'trace-eval'
      success = trace_eval(args)
      exit(success ? 0 : 1)
    when 'sop_review', 'sop-review'
      sop_review(args)
    when 'proof_plan', 'proof-plan'
      proof_plan(args)
    when 'context_bundle', 'context-bundle'
      context_bundle(args)
    when 'ponytail_audit', 'ponytail-audit'
      success = ponytail_audit(args)
      exit(success ? 0 : 1)
    when 'agent_eval', 'agent-eval'
      success = agent_eval(args)
      exit(success ? 0 : 1)
    when 'skill_lint', 'skill-lint'
      success = skill_lint(args)
      exit(success ? 0 : 1)
    when 'refresh_qa_snapshots', 'qa_refresh'
      refresh_qa_snapshots(args)

    # Environment & Health
    when 'doctor'
      doctor
    when 'status'
      run_status(args)
    when 'operator_brief', 'operator-brief', 'brief'
      success = operator_brief(args)
      exit(success ? 0 : 1) if args.include?('--strict')
    when 'business_appointment', 'business-appointment', 'appointment'
      run_business_appointment(args)
    when 'check_inbox', 'check-inbox', 'inbox'
      run_check_inbox(args)
    when 'sync_mini', 'sync-mini'
      run_sync_mini(args)
    when 'sync_grok', 'sync-grok'
      run_sync_grok(args)
    when 'setapp_status', 'setapp-status'
      system('ruby', File.join(__dir__, 'setapp_status.rb'), *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
    when 'setapp_package', 'setapp-package'
      system('ruby', File.join(__dir__, 'setapp_package.rb'), *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
    when 'setapp_upload', 'setapp-upload'
      system('ruby', File.join(__dir__, 'setapp_upload.rb'), *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
    when 'setapp_media_sync', 'setapp-media-sync'
      system('ruby', File.join(__dir__, 'setapp_media_sync.rb'), *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
    when 'tool_discovery', 'tool_receipt', 'tool-receipt'
      tool_discovery(args)
    when 'agent_env_review', 'agent-env-review'
      agent_env_review(args)
    when 'health', 'h'
      run_health(args)
    when 'meta', 'tooling', 'audit-self'
      run_meta(args)
    when 'bootstrap', 'preflight', 'env'
      run_bootstrap(args)
    when 'setup'
      setup_environment
    when 'restore'
      restore_xcode
    when 'install_provisioning_profiles', 'install_profiles', 'install-profiles'
      install_provisioning_profiles_command(args)
    when 'dedupe_apps', 'dedupe-apps'
      system('ruby', File.join(__dir__, 'dedupe_sane_apps.rb'), *args)
    when 'machine_cleanup', 'machine-cleanup', 'cleanup_machine', 'cleanup-machine'
      success = machine_cleanup(args)
      exit(success ? 0 : 1)
    when 'mcp_watchdog', 'mcpw', 'mcp'
      mcp_watchdog(args)
    when 'universal_control_reset', 'uc_reset', 'ucr'
      universal_control_reset(args)
    when 'work_session_on', 'wson'
      work_session_on
    when 'work_session_off', 'wsof'
      work_session_off
    when 'work_session_status', 'wsst'
      work_session_status
    when 'server_acceptance', 'server-acceptance', 'air_mini_acceptance', 'air-mini-acceptance'
      system('/opt/homebrew/opt/ruby/bin/ruby', File.join(__dir__, 'automation', 'air_mini_acceptance.rb'), *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?

    # Build & Test
    when 'verify'
      verify(args)
    when 'clean'
      clean(args)
    when 'lint'
      run_lint
    when 'quality'
      run_quality_report
    when 'audit'
      audit_project
    when 'system_check'
      audit_unified
    when 'customer_ui_contract'
      customer_ui_contract(args)
    when 'customer_ui_sweep', 'customer-ui-sweep'
      customer_ui_sweep(args)
    when 'release_readiness', 'release-readiness'
      release_readiness(args)
    when 'launch_readiness', 'launch-readiness'
      launch_readiness(args)
    when 'release'
      release(args)
    when 'upgrade_path_proof', 'upgrade-path-proof'
      producer = SaneMasterModules::UpgradePathProof::UPGRADE_PRODUCER
      if ReleaseReceiptSigner.canonical_producer_child?(producer)
        upgrade_path_proof(args)
      else
        exit ReleaseReceiptSigner.run_canonical_producer(producer, project_root: Dir.pwd, args: args)
      end
    when 'release_preflight'
      producer = SaneMasterModules::UpgradePathProof::RELEASE_PREFLIGHT_PRODUCER
      if ReleaseReceiptSigner.canonical_producer_child?(producer)
        release_preflight(args)
      else
        exit ReleaseReceiptSigner.run_canonical_producer(producer, project_root: Dir.pwd, args: args)
      end
    when 'appstore_preflight', 'asp'
      producer = 'saneprocess.appstore_preflight.v1'
      if ReleaseReceiptSigner.canonical_producer_child?(producer)
        appstore_preflight(args)
      else
        exit ReleaseReceiptSigner.run_canonical_producer(producer, project_root: Dir.pwd, args: args)
      end

    # Sales & Downloads
    when 'sales'
      sales(args)
    when 'downloads', 'dl'
      downloads(args)
    when 'events'
      events(args)
    when 'x_impact', 'x-impact', 'ximpact'
      script = File.join(__dir__, 'automation', 'x-impact-report.py')
      system('python3', script, *args)
      exit($CHILD_STATUS.exitstatus || 1) unless $CHILD_STATUS&.success?
    when 'leads', 'prospects'
      run_python_automation_script('lead-research.py', args)

    # CI Helpers
    when 'enable_ci_tests'
      enable_ci_tests(args)
    when 'restore_ci_tests'
      restore_ci_tests(args)
    when 'fix_mocks'
      fix_mocks(args)
    when 'monitor_tests'
      monitor_tests(args)
    when 'image_info'
      image_info(args)
    when 'qa'
      system(File.join(__dir__, 'qa.rb'))
    when 'validate_test_references', 'validate-tests'
      validate_test_references

    # Permissions
    when 'reset'
      reset_permissions
    when 'check_permissions'
      check_permission_status

    # Generation & Verification
    when 'gen_assets'
      generate_test_assets
    when 'gen_test'
      generate_test_file(args)
    when 'gen_mock'
      generate_mocks(args)
    when 'check_xcodegen'
      check_xcodegen(args)
    when 'verify_api'
      verify_api(args)
    when 'verify_mocks'
      verify_mocks
    when 'check_protocol_changes'
      check_protocol_changes(args)
    when 'check_docs'
      verify_documentation_sync
    when 'template'
      manage_templates(args)

    # Quality Analysis
    when 'dead_code', 'find_dead_code'
      find_dead_code
    when 'check_deprecations', 'deprecations'
      check_deprecations
    when 'swift6_check', 'swift6', 'concurrency_check'
      swift6_check
    when 'saneui_guard', 'ui_guard'
      target = args.first || Dir.pwd
      success = SaneMasterModules::SaneUIGuard.run_cli(target)
      exit(success ? 0 : 1)
    when 'secret_scan', 'secret-scan', 'secrets'
      secret_scan(args)
    when 'test_suite', 'suite'
      run_test_suite(args)
    when 'test_scan', 'scan_tests', 'test_quality'
      run_test_scan(args)
    when 'gate_review', 'review_gate', 'gate_rule_review'
      success = run_gate_review(args)
      exit(success ? 0 : 1)
    when 'check_binary'
      check_binary

    # Dependencies & Versions
    when 'version_check', 'versions'
      check_latest_versions(args)
    when 'deps', 'dependencies'
      show_dependency_graph(args)
    when 'verify_mcps'
      verify_mcps

    # Interactive Debugging
    when 'launch', 'run'
      success = launch_app(args)
      exit(success ? 0 : 1)
    when 'logs'
      show_app_logs(args)
    when 'test_mode', 'tm'
      enter_test_mode(args)
    when 'mode', 'test_mode_switch', 'license_mode'
      app_test_mode(args)

    # Session state, approvals, and loop controls
    when 'github_post_approval', 'github-post-approval', 'gh_post_approval', 'gh-post-approval'
      github_post_approval(args)
    when 'email_force_approval', 'email-force-approval', 'email_force_approve', 'email-force-approve'
      email_force_approval(args)
    when 'session_end', 'se'
      session_end(args)
    when 'reset_breaker', 'rb'
      SaneMasterModules::CircuitBreakerState.reset!
    when 'breaker_status', 'bs'
      show_breaker_status
    when 'breaker_errors', 'be'
      show_breaker_errors
    when 'research_status', 'rs'
      research_status(args)
    when 'research_lock', 'rl'
      research_lock(args)
    when 'research_unlock', 'ru'
      research_unlock(args)
    when 'structural', 'sc'
      run_structural_compliance(args)
    when 'compliance', 'cr'
      run_structural_compliance(args)
      require_relative 'sanemaster/compliance_report'
      SaneMasterModules::ComplianceReport.generate

    # SOP Loop (Two-Fix Rule Compliant)
    when 'verify_gate', 'vg'
      verify_gate(args)
    when 'sop_loop', 'sop'
      start_sop_loop(args)
    when 'reset_escalation', 're'
      reset_escalation(args)

    # SaneLoop - Native structured task loops (replaces ralph-wiggum)
    when 'saneloop', 'sl'
      saneloop(args)

    # Debug Console
    when 'console'
      require 'pry'
      # rubocop:disable Lint/Debugger
      binding.pry
    # rubocop:enable Lint/Debugger

    # Export
    when 'export', 'pdf', 'export_pdf'
      export_pdf(args)
    when 'md_export', 'mdpdf'
      export_markdown(args)
    when 'listing_actions', 'listing-actions'
      run_python_automation_script('listing-actions.py', args)
    when 'hosted_file_actions', 'hosted-file-actions'
      run_python_automation_script('hosted-file-actions.py', args)

    else
      puts "❌ Unknown command: #{command}"
      print_help
    end
  end

  def show_breaker_status
    status = SaneMasterModules::CircuitBreakerState.status
    puts '🔌 --- [ CIRCUIT BREAKER STATUS ] ---'
    puts ''
    if status[:status] == 'OPEN'
      puts "   Status: 🔴 #{status[:status]} (TOOLS BLOCKED)"
      puts "   #{status[:message]}"
      puts "   Reason: #{status[:trip_reason]}" if status[:trip_reason]
      puts "   Blocked: #{status[:blocked_tools].join(', ')}"
      puts ''
      puts '   To see errors: ./scripts/SaneMaster.rb breaker_errors'
      puts '   To reset: ./scripts/SaneMaster.rb reset_breaker'
    else
      puts "   Status: 🟢 #{status[:status]}"
      puts "   #{status[:message]}"
    end
    puts ''
  end

  def github_post_approval(args)
    quote = nil
    body = nil
    admin = false
    i = 0
    while i < args.length
      case args[i]
      when '--user-approval', '--approval', '--quote'
        quote = args[i + 1]
        i += 1
      when '--body'
        body = args[i + 1]
        i += 1
      when '--body-file'
        file = args[i + 1]
        abort "❌ GitHub approval body file not found: #{file}" unless file && File.file?(file)

        body = File.read(file, encoding: Encoding::UTF_8)
        i += 1
      when '--admin', '--no-body'
        # Admin API calls (repo settings, branch protection) post no public
        # text; the user-approved token alone is the consent record.
        admin = true
      else
        quote ||= args[i]
      end
      i += 1
    end

    quote = quote.to_s.strip
    abort '❌ Missing explicit user approval quote. Use --user-approval "post it".' if quote.empty?
    body = body.to_s.strip
    if body.empty? && !admin
      abort '❌ Missing exact public post body. Use --body "final text" or --body-file <path>, or --admin for settings-only API calls with no post body.'
    end

    path = '/tmp/.gh_post_approved.json'
    payload = {
      'created_at' => Time.now.to_i,
      'user_approval' => quote,
      'body_hash' => body.empty? ? '' : Digest::SHA256.hexdigest(body),
      'admin' => admin
    }
    File.write(path, JSON.pretty_generate(payload))
    File.chmod(0o600, path)
    puts admin ? '✅ GitHub admin-call approval recorded for 5 minutes.' : '✅ GitHub public-post approval recorded for 5 minutes.'
  end

  def email_force_approval(args)
    action = nil
    id = nil
    reason = nil
    quote = nil
    i = 0
    while i < args.length
      case args[i]
      when '--action'
        action = args[i + 1]
        i += 1
      when '--id', '--email-id'
        id = args[i + 1]
        i += 1
      when '--reason'
        reason = args[i + 1]
        i += 1
      when '--user-approval', '--approval', '--quote'
        quote = args[i + 1]
        i += 1
      end
      i += 1
    end

    action = action.to_s.strip
    id = id.to_s.strip
    reason = reason.to_s.strip
    quote = quote.to_s.strip
    abort '❌ Missing --action for email force approval.' if action.empty?
    abort '❌ Missing --id for email force approval.' if id.empty?
    abort '❌ Missing --reason for email force approval.' if reason.empty?
    abort '❌ Missing --user-approval quote for email force approval.' if quote.empty?

    path = '/tmp/.email_force_approved.json'
    payload = {
      'created_at' => Time.now.to_i,
      'action' => action,
      'id' => id,
      'reason' => reason,
      'user_approval' => quote
    }
    File.write(path, JSON.pretty_generate(payload))
    File.chmod(0o600, path)
    puts '✅ Email force approval recorded for 5 minutes.'
  end

  def show_breaker_errors
    state = SaneMasterModules::CircuitBreakerState.load_state
    puts '🔌 --- [ CIRCUIT BREAKER ERRORS ] ---'
    puts ''

    messages = state[:failure_messages] || []
    if messages.empty?
      puts '   No failure messages recorded.'
    else
      puts "   Recent failures (#{messages.count}):"
      puts ''
      messages.each_with_index do |msg, i|
        puts "   #{i + 1}. #{msg}"
      end
    end

    # Show error signatures if any
    signatures = state[:error_signatures] || {}
    if signatures.any?
      puts ''
      puts '   Error patterns detected:'
      signatures.sort_by { |_, v| -v }.first(5).each do |sig, count|
        puts "   - #{count}x: #{sig[0, 60]}#{'...' if sig.length > 60}"
      end
    end

    puts ''
    puts '   Use this information to research the problem and create a plan.'
    puts ''
  end

  def parse_diagnose_args(args)
    path = nil
    dump = false

    args.each_with_index do |arg, i|
      if arg == '--path'
        path = args[i + 1]
      elsif arg == '--dump'
        dump = true
      elsif !arg.start_with?('-') && path.nil?
        path = arg
      end
    end

    { path: path, dump: dump }
  end

  def app_test_mode(args)
    helper = File.join(__dir__, 'app_test_mode.sh')
    unless File.file?(helper)
      puts "❌ Missing helper script: #{helper}"
      return
    end

    forwarded = args.dup
    mode_actions = %w[pro basic free status owner-check owner-install owner-pro owner-verify]

    if forwarded.empty?
      puts 'Usage: ./scripts/SaneMaster.rb mode [<AppName>] <pro|basic|free|status|owner-check|owner-install|owner-pro|owner-verify|list> [--launch] [--host local|mini]'
      return
    end

    first = forwarded.first
    if first == 'list'
      # passthrough: app_test_mode.sh list [--host ...]
    elsif mode_actions.include?(first) || first.start_with?('--')
      inferred_app = project_name
      unless KNOWN_SANE_APPS.include?(inferred_app)
        puts "❌ Could not infer app from current repo (#{inferred_app})."
        puts "   Pass app name explicitly: mode SaneBar #{first}"
        return
      end
      forwarded.unshift(inferred_app)
    elsif !KNOWN_SANE_APPS.include?(first)
      puts "❌ Unknown app '#{first}'."
      puts "   Known apps: #{KNOWN_SANE_APPS.join(', ')}"
      return
    end

    unless system('bash', helper, *forwarded)
      puts '❌ app_test_mode helper failed.'
    end
  end

  def check_binary
    puts '🛡️ --- [ SANEMASTER BINARY AUDIT ] ---'

    puts 'Searching for production binary...'
    build_settings = `xcodebuild -scheme #{project_scheme} -showBuildSettings 2>/dev/null`
    target_build_dir = build_settings.match(/TARGET_BUILD_DIR = (.*)/)&.[](1)
    executable_path = build_settings.match(/EXECUTABLE_PATH = (.*)/)&.[](1)

    unless target_build_dir && executable_path
      puts '❌ Error: Could not determine binary path. Build the app first.'
      return
    end

    full_path = File.join(target_build_dir, executable_path)
    unless File.exist?(full_path)
      puts "❌ Error: Binary not found at #{full_path}. Run 'SaneMaster verify' first."
      return
    end

    audit_binary_symbols(full_path)
    audit_binary_architectures(full_path)

    puts '✅ Binary audit complete.'
  end

  def audit_binary_symbols(full_path)
    print '  Checking for debug symbols... '
    `nm -u "#{full_path}" 2>&1`
    debug_indicators = `nm "#{full_path}" 2>&1`

    if debug_indicators.include?('DEBUG') || debug_indicators.include?('assertions')
      puts '⚠️  POTENTIAL UNSTRIPPED SYMBOLS FOUND'
    else
      puts '✅'
    end
  end

  def audit_binary_architectures(full_path)
    print '  Verifying architectures... '
    archs = `lipo -info "#{full_path}"`
    puts "✅ (#{archs.strip.split(': ').last})"
  end

  def print_help
    puts <<~HEADER
      ┌─────────────────────────────────────────────────────────────┐
      │  SaneMaster - Professional Automation Suite for #{project_name}    │
      └─────────────────────────────────────────────────────────────┘

      Quick Start:
    HEADER

    QUICK_START.each do |item|
      puts "        #{item[:cmd].ljust(12)} #{item[:desc]}"
    end

    puts "\n      Categories (use 'help <category>' for details):"
    puts '      ─────────────────────────────────────────────────'

    COMMANDS.each do |cat, data|
      cmd_list = data[:commands].keys.take(3).join(', ')
      cmd_list += ', ...' if data[:commands].size > 3
      puts "        #{cat.to_s.ljust(10)} #{data[:desc]}"
      puts "                   └─ #{cmd_list}"
    end

    puts <<~FOOTER

      Examples:
        ./scripts/SaneMaster.rb status          # Live cross-reference report
        ./scripts/SaneMaster.rb verify          # Build + test
        ./scripts/SaneMaster.rb help build      # Show build commands

      Aliases: sm = ./scripts/SaneMaster.rb (if configured)
    FOOTER
  end

  def print_category_help(category)
    unless COMMANDS.key?(category)
      puts "❌ Unknown category: #{category}"
      puts "   Available: #{COMMANDS.keys.join(', ')}"
      return
    end

    data = COMMANDS[category]
    puts <<~HEADER
      ┌─────────────────────────────────────────────────────────────┐
      │  #{category.to_s.upcase.center(57)}  │
      │  #{data[:desc].center(57)}  │
      └─────────────────────────────────────────────────────────────┘

      Commands:
    HEADER

    data[:commands].each do |cmd, info|
      args = info[:args].empty? ? '' : " #{info[:args]}"
      puts "        #{cmd}#{args}"
      puts "          #{info[:desc]}"
      puts
    end
  end

  # Extended help information for each command
  # rubocop:disable Lint/UselessConstantScoping
  COMMAND_DETAILS = {
    'verify' => {
      usage: 'verify [--ui|--ui-only] [--clean] [--no-grant-permissions] [--signed-tests] [--skip-test-validation] [--quiet] [--timeout positive_seconds]',
      description: 'Build and run tests; every Xcode phase must exit zero and provide scope-matched xcresult evidence.',
      flags: {
        '--ui' => 'Run unit/integration tests, then signed UI tests in a separate session',
        '--ui-only' => 'Run only the signed UI-test session for focused diagnostics',
        '--clean' => 'Clean build before testing',
        '--no-grant-permissions' => 'Disable the Mini permission monitor for this run',
        '--signed-tests' => 'Keep normal code signing enabled for the unit-test phase',
        '--skip-test-validation' => 'Skip the pre-run static test-reference validation',
        '--quiet' => 'Compatibility flag for callers that redirect verify output to a log',
        '--timeout positive_seconds' => 'Set one monotonic deadline shared across all Xcode test phases'
      },
      examples: [
        'verify                     # Run unit tests',
        'verify --ui                # Run unit/integration plus signed UI tests',
        'verify --ui-only           # Run only the signed UI-test lane',
        'verify --clean             # Clean build first',
        'verify --no-grant-permissions # Disable the permission monitor for diagnostics',
        'verify --timeout 900       # Allow longer-running suites to finish'
      ]
    },
    'clean' => {
      usage: 'clean [--nuclear]',
      description: 'Wipe build cache and test state files',
      flags: {
        '--nuclear' => 'Also remove DerivedData and reset Xcode state'
      },
      examples: ['clean', 'clean --nuclear']
    },
    'test_mode' => {
      usage: 'test_mode (or tm)',
      description: 'Interactive debugging workflow: Kill → Build → Launch → Logs',
      flags: {},
      examples: %w[test_mode tm]
    },
    'mode' => {
      usage: 'mode [<AppName>] <pro|basic|free|status|owner-check|owner-install|owner-pro|owner-verify|list> [--launch] [--host local|mini] [--allow-keychain]',
      description: 'Set/query app test license mode, or inspect owner-machine install health, via no-keychain defaults and canonical signed installs.',
      flags: {
        '--launch' => 'Launch app after switching mode',
        '--host local|mini' => 'Run mode/launch flow on local machine or mini',
        '--allow-keychain' => 'Use real keychain path instead of no-keychain launch'
      },
      examples: [
        'mode pro --launch                 # Current app to Pro and launch',
        'mode basic --launch --host mini   # Current app in Basic on mini',
        'mode SaneHosts status --host mini # Query another app mode on mini',
        'mode owner-check                  # Inspect current app install, keychain, and permissions',
        'mode owner-install                # Prepare canonical signed owner install on this machine',
        'mode owner-pro                    # Seed persistent Pro state for the installed owner app',
        'mode owner-verify --launch        # Verify owner install and launch the real app normally',
        'mode list                         # Show supported apps'
      ]
    },
    'dedupe_apps' => {
      usage: 'dedupe_apps [--host local|mini] [--apps App1,App2] [--dry-run] [--json]',
      description: 'Find duplicate installed/build app bundles and keep one canonical copy per Sane app.',
      flags: {
        '--host local|mini' => 'Run on this machine or over ssh on the Mini',
        '--apps App1,App2' => 'Restrict cleanup to specific Sane apps',
        '--dry-run' => 'Report what would be promoted/trashed without changing files',
        '--json' => 'Emit machine-readable output'
      },
      examples: [
        'dedupe_apps --dry-run            # Preview local cleanup',
        'dedupe_apps --host mini          # Clean duplicates on the Mini',
        'dedupe_apps --apps SaneBar,SaneHosts'
      ]
    },
    'machine_cleanup' => {
      usage: 'machine_cleanup [--host local|mini] [--server] [--apply] [--json] [--preserve-apps A,B]',
      description: 'Prune disposable caches, full Trash, simulators, stale DerivedData, and optional Mini server generated artifacts.',
      flags: {
        '--host local|mini' => 'Inspect this machine or route the cleanup command to the Mini',
        '--server' => 'Mini-only aggressive server reset: prune generated repo artifacts, routed workspaces, simulator runtimes, Codex residue, bulk outputs, and disposable app containers',
        '--apply' => 'Perform the planned safe cleanup; default is dry-run',
        '--preserve-apps A,B' => 'Additional app names to preserve even if no process is currently visible',
        '--min-free-gb N' => 'Disk pressure threshold used in the report',
        '--cache-threshold-gb N' => 'Minimum disposable-cache total before cache pruning is planned',
        '--deriveddata-age-days N' => 'Only prune inactive DerivedData older than this many days',
        '--json' => 'Emit machine-readable output'
      },
      examples: [
        'machine_cleanup --host mini --json',
        'machine_cleanup --host mini --server --apply',
        'machine_cleanup --host mini --apply --preserve-apps SaneVideo,SaneScan',
        'machine_cleanup --local --apply'
      ]
    },
    'doctor' => {
      usage: 'doctor',
      description: 'Check environment health and tool versions',
      flags: {},
      examples: ['doctor']
    },
    'tool_discovery' => {
      usage: 'tool_discovery --query "TEXT" [--skip-doctor] [--skip-validation] [--limit N]',
      description: 'Generate a tool-discovery receipt before using a workaround or adding a new tool.',
      flags: {
        '--query "TEXT"' => 'Describe the missing tool, workaround, or recurring workflow',
        '--skip-doctor' => 'Skip the doctor health check',
        '--skip-validation' => 'Skip validation_report.rb',
        '--limit N' => 'Limit matches per section',
        '--json' => 'Print receipt JSON to stdout'
      },
      examples: [
        'tool_discovery --query "missing screenshot diff tool"',
        'tool_discovery --query "workaround for docs audit"',
        'tool_receipt --query "do we already have a website crawler?"'
      ]
    },
    'status' => {
      usage: 'status [--fast|--full]',
      description: 'Run the full cross-reference across git, inbox, Setapp, hosted files, GitHub, releases, and current signals by default. Exit 3 means one or more selected lanes were unavailable.',
      flags: {
        '--fast' => 'Explicit partial summary: show active inbox actions and key worktrees only; still exits 3 if either selected lane is unavailable.',
        '--full' => 'Explicitly run the default full cross-reference, including the core worktree summary and all 10 deep lanes; every lane is attempted before the verdict.'
      },
      examples: [
        'status',
        'status --fast',
        'status --full'
      ]
    },
    'operator_brief' => {
      usage: 'operator_brief [--nightly-report PATH] [--morning-report PATH] [--handoff PATH] [--output PATH] [--json] [--strict]',
      description: 'Summarize current SaneApps receipts into a prioritized operator brief for the next maintenance loop.',
      flags: {
        '--nightly-report PATH' => 'Nightly report to parse (default: ~/SaneApps/outputs/nightly_report.md)',
        '--morning-report PATH' => 'Business/opportunity report to freshness-check',
        '--handoff PATH' => 'Session handoff to scan for active blockers',
        '--output PATH' => 'Markdown output path (default: ~/SaneApps/outputs/operator_brief.md)',
        '--json' => 'Print machine-readable report JSON',
        '--strict' => 'Exit non-zero when the brief finds priorities'
      },
      examples: [
        'operator_brief',
        'operator_brief --json',
        'operator-brief --strict'
      ]
    },
    'business_appointment' => {
      usage: 'business_appointment add --title TITLE --start "YYYY-MM-DD HH:MM" --attendee EMAIL [--apply] [--json]',
      description: 'Preview or create SaneApps-owned business calendar appointments without using personal Gmail/calendar routes.',
      flags: {
        '--attendee EMAIL' => 'Invitee address. Repeat for multiple attendees.',
        '--meeting-url URL' => 'Video call or appointment URL to include on the event.',
        '--duration-minutes N' => 'Event length in minutes. Default: 30.',
        '--reminders-minutes N' => 'Popup reminder minutes. Default: 15.',
        '--dedupe-key KEY' => 'Optional idempotency key. Default is derived from calendar, title, start, timezone, and attendees.',
        '--confirm-send TEXT' => 'Required with --apply. Use the confirm_send value from preview JSON.',
        '--apply' => 'Create the event only after business calendar credentials are configured.',
        '--json' => 'Print machine-readable receipt JSON'
      },
      examples: [
        'business_appointment add --title "SaneCite call" --start "2026-07-13 09:00" --attendee prospect@example.com --json',
        'business-appointment add --title "Test invite" --start "2026-07-06 09:00" --attendee stephanjoseph2007@gmail.com --confirm-send "send hi@saneapps.com invite to stephanjoseph2007@gmail.com at 2026-07-06T09:00:00 America/New_York" --apply --json'
      ]
    },
    'check_inbox' => {
      usage: 'check_inbox [check|review <id>|read <id>|reply ...]',
      description: 'Forward to the canonical support inbox script with the same subcommands.',
      flags: {},
      examples: [
        'check_inbox',
        'check_inbox review 538',
        'check_inbox read 545'
      ]
    },
    'sync_mini' => {
      usage: 'sync_mini [mini] [--quiet] [--no-restart]',
      description: 'Sync the Codex control-plane profile to the Mini without hunting for the automation script path.',
      flags: {
        '--quiet' => 'Reduce sync logging',
        '--no-restart' => 'Do not restart services after sync'
      },
      examples: [
        'sync_mini',
        'sync_mini mini --quiet --no-restart'
      ]
    },
    'sync_grok' => {
      usage: 'sync_grok [mini] [--quiet]',
      description: 'Sync the Grok control-plane profile (grok-bin helpers, ~/.grok/config.toml when present, and .agents/skills) to the Mini without hunting for the automation script path.',
      flags: {
        '--quiet' => 'Reduce sync logging'
      },
      examples: [
        'sync_grok',
        'sync_grok mini --quiet'
      ]
    },
    'setapp_status' => {
      usage: 'setapp_status [--json] [--soft]',
      description: 'Check Setapp review status for submitted SaneApps builds. Needs Revision means Setapp is waiting on us.',
      flags: {
        '--json' => 'Print machine-readable status',
        '--soft' => 'Always exit 0 for broad status reports',
        '--app NAME:APP_ID:VERSION_ID' => 'Check an additional or replacement Setapp app/version pair'
      },
      examples: [
        'setapp_status',
        'setapp_status --json',
        'setapp_status --soft'
      ]
    },
    'setapp_upload' => {
      usage: 'setapp_upload --zip ZIP --release-notes-file PATH --review-comments-file PATH [--portal-fallback --app-id ID (--version-id ID | --create-version)]',
      description: 'Upload a Setapp build. Canonical auth: `source ~/.config/nv/env` loads SETAPP_PORTAL_TOKEN from the keychain for --portal-fallback. New public release (pinned version Released) needs --create-version (PATCH is rejected); reupload during review PATCHes via --version-id. See templates/RELEASE_SOP.md "Upload through the standard Setapp lane".',
      flags: {
        '--zip PATH' => 'Setapp ZIP archive to upload',
        '--release-notes TEXT' => 'Public Setapp user-facing release notes text',
        '--release-notes-file PATH' => 'Read public Setapp user-facing release notes from a file',
        '--review-comments TEXT' => 'Private Setapp reviewer comments; never put these in public release notes',
        '--review-comments-file PATH' => 'Read private Setapp reviewer comments from a file',
        '--no-review-comments-needed' => 'Explicitly confirm this upload needs no private reviewer comments',
        '--portal-fallback' => 'Use developer portal upload_archive + version PATCH path',
        '--app-id ID' => 'Setapp application id for portal fallback',
        '--version-id ID' => 'Existing Setapp version id for portal fallback',
        '--validate-only' => 'Validate the archive without uploading',
        '--allow-needs-revision' => 'Attach archive without failing when a manual Submit for review is still required',
        '--dry-run' => 'Validate and print the planned path without uploading'
      },
      examples: [
        'setapp_upload --zip outputs/SaneBar-Setapp.zip --release-notes-file /tmp/setapp-notes.txt --review-comments-file /tmp/setapp-private-comments.txt',
        'setapp_upload --portal-fallback --app-id 1848 --version-id 46885 --zip outputs/SaneBar-Setapp.zip --release-notes-file /tmp/setapp-notes.txt --no-review-comments-needed'
      ]
    },
    'setapp_media_sync' => {
      usage: 'setapp_media_sync [--app NAME] [--dry-run] [--json] [--public-page-proof-file PATH]',
      description: 'Validate and sync Setapp listing screenshots from each app .saneprocess manifest to the developer portal media list. A public-page proof JSON receipt can clear the final setapp.com propagation gate.',
      flags: {
        '--app NAME' => 'Only sync one app, such as SaneBar or SaneClip',
        '--dry-run' => 'Validate and print the planned screenshot order without changing Setapp',
        '--json' => 'Print machine-readable output',
        '--no-safari-token' => 'Legacy alias: do not read the developer.setapp.com Brave token',
        '--allow-pending-public-page' => 'Exit 0 after portal sync even though public setapp.com proof is still pending',
        '--public-page-proof-file PATH' => 'JSON receipt proving the public Setapp page shows the expected screenshots'
      },
      examples: [
        'setapp_media_sync --dry-run',
        'setapp_media_sync --app SaneBar',
        'setapp_media_sync --app SaneBar --public-page-proof-file outputs/setapp-public-proof-sanebar.json'
      ]
    },
    'setapp_package' => {
      usage: 'setapp_package [--project PATH] [--app-name NAME] [--scheme NAME] [--version X.Y.Z]',
      description: 'Build a Setapp review package, sign it with Developer ID, notarize, staple, zip, and run the Setapp archive validation gate.',
      flags: {
        '--project PATH' => 'Project root; defaults to the current directory',
        '--app-name NAME' => 'App name; defaults to the .xcodeproj basename',
        '--scheme NAME' => 'Setapp archive scheme; defaults to APPSetapp',
        '--configuration NAME' => 'Archive configuration; defaults to Release-Setapp',
        '--version X.Y.Z' => 'Output version string; defaults to MARKETING_VERSION from project.yml',
        '--output-root PATH' => 'Receipt and package output root',
        '--signing-identity NAME' => 'Developer ID signing identity',
        '--notary-profile NAME' => 'notarytool keychain profile'
      },
      examples: [
        'setapp_package --project ~/SaneApps/apps/SaneClip --app-name SaneClip --scheme SaneClipSetapp'
      ]
    },
    'context_bundle' => {
      usage: 'context_bundle --task "TEXT" [--output PATH.md] [--json] [--dry-run] [--max-research N] [--max-memory N]',
      description: 'Create a compact local Markdown context bundle for subagents, critic reviews, and resumes. The bundle indexes existing research and Serena memory files using Updated/Status/TTL metadata instead of creating another memory store. Redact before sharing outside SaneApps.',
      flags: {
        '--task "TEXT"' => 'Task or review question the bundle is for',
        '--output PATH.md' => 'Write the bundle to a specific Markdown path inside the repo',
        '--max-research N' => 'Maximum research cards to include in the index',
        '--max-memory N' => 'Maximum Serena memory cards to include in the index',
        '--json' => 'Print the manifest as JSON after writing the Markdown bundle',
        '--dry-run' => 'Build and print the manifest without writing the bundle'
      },
      examples: [
        'context_bundle --task "critic review SaneMaster skill routing"',
        'context-bundle --task "subagent audit" --json',
        'context_bundle --task "resume release proof work" --max-research 10'
      ]
    },
    'universal_control_reset' => {
      usage: 'universal_control_reset [--status] [--dry-run] [--local-only|--mini-only] [--cleanup-mini] [--reboot-mini]',
      description: 'Reset Universal Control / Continuity state between this Mac and the Mini, then optionally reboot or clean the Mini.',
      flags: {
        '--status' => 'Print local + Mini discovery state without changing anything',
        '--dry-run' => 'Print the exact reset steps without executing them',
        '--local-only' => 'Only reset the current Mac',
        '--mini-only' => 'Only reset the Mini over SSH',
        '--cleanup-mini' => 'Hide Terminal/Codex and close Preview/Safari on the Mini',
        '--reboot-mini' => 'Ask the Mini to restart after the reset sequence'
      },
      examples: [
        'universal_control_reset                      # Standard Air + Mini recovery',
        'universal_control_reset --status            # Inspect discovery state first',
        'universal_control_reset --cleanup-mini      # Reset and clear Mini clutter',
        'universal_control_reset --reboot-mini       # Reset, then restart the Mini'
      ]
    },
    'export' => {
      usage: 'export [--highlight] [--include-tests] [--output <dir>]',
      description: 'Export source code to PDF for review',
      flags: {
        '--highlight' => 'Enable syntax highlighting (larger file)',
        '--include-tests' => 'Include test files in export',
        '--output <dir>' => 'Custom output directory (default: ~/Downloads)'
      },
      examples: [
        'export                    # Basic export',
        'export --highlight        # With syntax highlighting',
        'export --include-tests    # Include test files'
      ]
    },
    'listing_actions' => {
      usage: 'listing_actions [--json|--json-out PATH|--xlsx PATH|--max-pages N]',
      description: 'Export SaneBar listing/setup action items from inbox history to XLSX or JSON.',
      flags: {
        '--json' => 'Print the tracker payload as JSON instead of writing XLSX',
        '--json-out PATH' => 'Write the JSON payload to a file while still generating XLSX output',
        '--xlsx PATH' => 'Custom XLSX output path (default: outputs/listing_actions/sanebar_listing_actions_<date>.xlsx)',
        '--max-pages N' => 'Max inbox pages to fetch at 200 emails/page'
      },
      examples: [
        'listing_actions',
        'listing_actions --json',
        'listing_actions --json-out /tmp/sanebar_listings.json',
        'listing_actions --xlsx /tmp/sanebar_listings.xlsx'
      ]
    },
    'hosted_file_actions' => {
      usage: 'hosted_file_actions [--json|--json-out PATH|--xlsx PATH|--evidence-out PATH]',
      description: 'Export Lemon Squeezy hosted-file dashboard sync actions with exact product, variant, version, and dashboard links.',
      flags: {
        '--json' => 'Print JSON instead of writing XLSX',
        '--json-out PATH' => 'Write the JSON payload to a file while still generating XLSX output',
        '--xlsx PATH' => 'Custom XLSX output path (default: outputs/hosted_file_actions/saneapps_hosted_file_actions_<date>.xlsx)',
        '--evidence-out PATH' => 'Write Markdown release evidence with current actions, upload-folder audit, and live snapshot'
      },
      examples: [
        'hosted_file_actions',
        'hosted_file_actions --json',
        'hosted_file_actions --xlsx /tmp/hosted_file_actions.xlsx'
      ]
    },
    'gen_test' => {
      usage: 'gen_test <name> [--type <unit|ui>] [--target <class>] [--async]',
      description: 'Generate test file from template',
      flags: {
        '--type' => 'Test type: unit (default) or ui',
        '--framework' => 'Testing framework: testing (default) or xctest',
        '--target' => 'Target class/service to test',
        '--async' => 'Include async/await patterns'
      },
      examples: [
        'gen_test MyFeatureTests --target MyFeature',
        'gen_test MyTests --async --framework xctest'
      ]
    },
    'gen_mock' => {
      usage: 'gen_mock [--target <dir>] [--protocol <name>]',
      description: 'Generate mocks using Mockolo',
      flags: {
        '--target' => 'Generate for all protocols in directory',
        '--protocol' => 'Generate for specific protocol',
        '--output' => 'Output directory (default: Tests/Mocks)'
      },
      examples: [
        'gen_mock --target Services/Camera',
        'gen_mock --protocol CameraServiceProtocol'
      ]
    },
    'verify_api' => {
      usage: 'verify_api <APIName> [Framework]',
      description: 'Verify API exists in macOS SDK',
      flags: {},
      examples: [
        'verify_api faceCaptureQuality Vision',
        'verify_api SCContentSharingPicker ScreenCaptureKit'
      ]
    },
    'dead_code' => {
      usage: 'dead_code',
      description: 'Find unused code using Periphery',
      flags: {},
      examples: ['dead_code']
    },
    'swift6' => {
      usage: 'swift6',
      description: 'Check Swift 6 concurrency compliance',
      flags: {},
      examples: ['swift6']
    },
    'logs' => {
      usage: 'logs [--follow]',
      description: 'Show application logs',
      flags: {
        '--follow' => 'Stream logs in real-time'
      },
      examples: ['logs', 'logs --follow']
    },
    'crashes' => {
      usage: 'crashes [--recent]',
      description: 'Analyze crash reports',
      flags: {
        '--recent' => 'Show only recent crashes'
      },
      examples: ['crashes', 'crashes --recent']
    },
    'runtime_evidence' => {
      usage: 'runtime_evidence [--executable PATH|--pid PID] [--break File.swift:LINE] [--symbol NAME] [--expr EXPR] [--arg ARG] [--dry-run]',
      description: 'Capture a timestamped LLDB runtime-evidence bundle without building or launching apps. For SaneApps app work, launch through test_mode on the Mini first, then attach by PID.',
      flags: {
        '--executable PATH' => 'Run a reproducible Swift executable under LLDB',
        '--pid PID' => 'Attach to an already-running process',
        '--break File.swift:LINE' => 'Set a source breakpoint before capture',
        '--symbol NAME' => 'Set a symbol breakpoint before capture',
        '--expr EXPR' => 'Evaluate a side-effect-free expression in the stopped frame',
        '--arg ARG' => 'Pass an argument to the executable; repeat for multiple args',
        '--dry-run' => 'Write the evidence plan without invoking LLDB',
        '--json' => 'Print machine-readable result JSON'
      },
      examples: [
        'runtime_evidence --dry-run --break Sources/App.swift:42',
        'runtime_evidence --executable /tmp/Repro --break /tmp/Repro.swift:8 --expr value',
        'runtime_evidence --pid 12345 --expr "state.description"'
      ]
    },
    'visual_smoke' => {
      usage: 'visual_smoke [--app NAME] [--bundle-id ID] [--output DIR] [--peekaboo PATH] [--timeout seconds] [--require-peekaboo] [--terminal-host|--direct] [--dry-run] [--json]',
      description: 'Capture a Peekaboo-backed visual/AX evidence bundle for an already launched app. Uses the Mini Terminal host by default so Screen Recording grants apply.',
      flags: {
        '--app NAME' => 'App name to target for Peekaboo see output (default: current project)',
        '--bundle-id ID' => 'Bundle ID recorded in the receipt',
        '--output DIR' => 'Output root (default: outputs/visual_smoke)',
        '--peekaboo PATH' => 'Peekaboo binary path or command name',
        '--timeout seconds' => 'Per-command timeout, minimum 5s',
        '--require-peekaboo' => 'Fail instead of skipping when Peekaboo is not installed',
        '--terminal-host' => 'Run Peekaboo through Terminal.app so macOS Screen Recording grants apply',
        '--direct' => 'Run Peekaboo directly in the current shell instead of Terminal.app',
        '--no-screen' => 'Skip full-screen screenshot capture',
        '--no-menu' => 'Skip menu-bar screenshot capture',
        '--no-app' => 'Skip app-specific AX snapshot',
        '--dry-run' => 'Write the planned command receipt without running Peekaboo',
        '--json' => 'Print machine-readable result JSON'
      },
      examples: [
        'visual_smoke --dry-run',
        'visual_smoke --app SaneBar --require-peekaboo',
        'visual_smoke --app SaneClick --no-menu --json'
      ]
    },
    'resource_soak' => {
      usage: 'resource_soak [--adaptive|--fixed] [--duration-seconds N] [--interval-seconds N] [--json]',
      description: 'Run the adaptive Mini resource check against the already launched /Applications release candidate and write /tmp/sanebar_runtime_resource_soak.json for the customer UI release contract.',
      flags: {
        '--adaptive' => 'Allow early pass after stable 4 minute minimum (default)',
        '--fixed' => 'Run the full duration and record fixed-duration evidence only',
        '--duration-seconds N' => 'Adaptive cap or fixed duration in seconds (default: 600)',
        '--interval-seconds N' => 'Steady sample interval in seconds (default: 10; adaptive starts at 5)',
        '--dry-run' => 'Print the planned artifact path without sampling',
        '--no-exit' => 'Return the report without exiting non-zero',
        '--json' => 'Print machine-readable result JSON'
      },
      examples: [
        'resource_soak --adaptive',
        'resource_soak --dry-run',
        'resource_soak --json'
      ]
    },
    'customer_ui_sweep' => {
      usage: 'customer_ui_sweep [--json] [--dry-run] [--no-exit]',
      description: 'Run the project customer workflow runner on the Mini, clean the visual workspace first, and then validate the customer UI action contract.',
      flags: {
        '--json' => 'Print machine-readable result JSON',
        '--dry-run' => 'Validate that a project workflow runner exists without launching or clicking the app',
        '--no-exit' => 'Return the report without exiting non-zero'
      },
      examples: [
        'customer_ui_sweep --dry-run',
        'customer_ui_sweep --json'
      ]
    },
    'release_readiness' => {
      usage: 'release_readiness [--json] [--app APP] [--scope candidate|portfolio]',
      description: 'Report patch-candidate readiness separately from portfolio health so daily maintenance can target the right app before expensive proof or release.',
      flags: {
        '--json' => 'Print the full release-readiness report as JSON',
        '--app APP' => 'Inspect a specific app under ~/SaneApps/apps',
        '--scope candidate|portfolio' => 'Inspect the current candidate app or all tracked app manifests'
      },
      examples: [
        'release_readiness',
        'release_readiness --json',
        'release_readiness --app SaneBar --json'
      ]
    },
    'launch_readiness' => {
      usage: 'launch_readiness [--json] [--max-age-days N]',
      description: 'Validate .outreach.yml launch gates, launch_package proof/assets, and public-posting policy for launch actions; for already-live products, release-proof drift is advisory unless launch-specific blockers remain.',
      flags: {
        '--json' => 'Print the full launch-readiness report as JSON',
        '--max-age-days N' => 'Maximum age for the passing release_preflight proof (default: 7)'
      },
      examples: [
        'launch_readiness',
        'launch_readiness --json',
        'launch_readiness --max-age-days 3'
      ]
    },
    'deps' => {
      usage: 'deps [--dot]',
      description: 'Show dependency graph',
      flags: {
        '--dot' => 'Output in DOT format for visualization'
      },
      examples: ['deps', 'deps --dot > graph.dot']
    },
    'session_end' => {
      usage: 'session_end [--skip-prompts]',
      description: 'End session with insight extraction (inspired by Auto-Claude)',
      flags: {
        '--skip-prompts' => 'Skip interactive prompts, show summary only'
      },
      examples: ['session_end', 'se', 'session_end --skip-prompts']
    },
    'appstore_preflight' => {
      usage: 'appstore_preflight (or asp) [--platform macos|ios] [--pkg PATH]',
      description: 'Run App Store submission checks and bind the signed receipt to an exact fresh package; existing ASC build reuse is retired because remote bytes cannot be proven',
      flags: {
        '--platform PLATFORM' => 'Platform for exact submission binding (macos or ios)',
        '--pkg PATH' => 'Bind authorization to this exact fresh package digest and bundle metadata'
      },
      examples: ['appstore_preflight', 'appstore_preflight --platform macos --pkg build/Example.pkg', 'asp --platform ios --pkg build/Example.ipa']
    },
    'sales' => {
      usage: 'sales [--daily|--month|--products|--fees|--find-customer-orders --email E --name N --product P|--license-status KEY|--disable-license-key KEY|--refund-order ID|--refund-order-number N|--refund-duplicate-license-key KEY --keep-license-key KEY --approval-note PATH|--include-refunded|--json]',
      description: 'LemonSqueezy sales report and guarded order refunds. Default: daily breakdown (today/yesterday/week/all-time).',
      flags: {
        '--daily' => 'Today/yesterday/week/all-time breakdown (default)',
        '--month' => 'Current month with monthly aggregates',
        '--products' => 'Revenue by product',
        '--fees' => 'Detailed fee breakdown',
        '--find-customer-orders' => 'Find likely orders for a customer using email/name heuristics',
        '--email E' => 'Customer support email or suspected purchase email for customer/order lookup',
        '--name N' => 'Customer display name for customer/order lookup',
        '--product P' => 'Optional product filter for customer/order lookup',
        '--limit N' => 'Max customer order candidates to print',
        '--license-status KEY' => 'Inspect a LemonSqueezy license key using the public validation endpoint',
        '--disable-license-key KEY' => 'Disable a LemonSqueezy license key by key string',
        '--refund-order ID' => 'Issue a refund for a Lemon Squeezy order ID',
        '--refund-order-number N' => 'Issue a refund for a Lemon Squeezy order number',
        '--refund-duplicate-license-key KEY' => 'Refund the order tied to a duplicate license key and disable that key',
        '--keep-license-key KEY' => 'Companion key to keep active during duplicate-license refund handling',
        '--amount CENTS' => 'Refund a specific amount in cents (omit for full refund)',
        '--proof-file PATH' => 'Write a human-readable refund proof file (required for new refunds)',
        '--approval-note PATH' => 'Path to the explicit refund approval note (required for new refunds)',
        '--refund-type TYPE' => 'Refund classification: discretionary, duplicate_purchase, or external',
        '--customer-thread REF' => 'Support thread, issue, or customer record tied to the refund audit',
        '--approval-source REF' => 'Where explicit owner approval was captured for the refund audit',
        '--include-refunded' => 'Include refunded orders in report/json output',
        '--json' => 'Raw JSON output for piping'
      },
      examples: [
        'sales                # Today/yesterday/week/all-time',
        'sales --month        # Current month',
        'sales --products     # Revenue by product',
        'sales --fees         # Fee breakdown',
        'sales --find-customer-orders --email reed@reed-a.ca --name Reed --product SaneBar',
        'sales --license-status 766800DD-3877-4EAA-938F-D60D42FFA0D7',
        'SANE_REFUND_APPROVED=1 sales --refund-order 7679013 --refund-type discretionary --customer-thread email#123 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt',
        'SANE_REFUND_APPROVED=1 sales --refund-duplicate-license-key D1918... --keep-license-key 7668... --refund-order-number 270691528 --customer-thread email#542 --proof-file /tmp/refund.txt --approval-note /tmp/refund-note.txt'
      ]
    },
    'downloads' => {
      usage: 'downloads [--daily|--days N|--app NAME|--json]',
      description: 'Download analytics from the sane-dist Worker (D1-backed daily aggregates).',
      flags: {
        '--daily' => 'Today/yesterday/week/all-time breakdown (default)',
        '--days N' => 'Look back N days (default: 90)',
        '--app NAME' => 'Filter by app name (e.g. sanebar)',
        '--json' => 'Raw JSON output for piping'
      },
      examples: [
        'downloads                # Today/yesterday/week/all-time',
        'downloads --days 7       # Last 7 days',
        'downloads --app sanebar  # Filter to SaneBar',
        'downloads --json         # Raw JSON'
      ]
    },
    'events' => {
      usage: 'events [--days N|--app NAME|--json]',
      description: 'User-type event analytics (new free users, early adopter grants, license activations).',
      flags: {
        '--days N' => 'Look back N days (default: 90)',
        '--app NAME' => 'Filter by app name (e.g. sanebar)',
        '--json' => 'Raw JSON output for piping'
      },
      examples: [
        'events                   # Event breakdown by period',
        'events --days 7          # Last 7 days of events',
        'events --app sanebar     # SaneBar events only'
      ]
    },
    'x_impact' => {
      usage: 'x_impact [--collect] [--fetch-x] [--days N] [--json]',
      description: 'Backtest SaneApps X posts against engagement, Lemon sales, downloads, and funnel events.',
      flags: {
        '--collect' => 'Collect fresh sales/downloads/events JSON before reporting',
        '--fetch-x' => 'Fetch a fresh authenticated X own-posts snapshot before reporting',
        '--days N' => 'Lookback window for posts/downloads/events (default: 30)',
        '--baseline-days N' => 'Daily baseline window before each post (default: 7)',
        '--json' => 'Print the machine-readable report JSON'
      },
      examples: [
        'x_impact --collect',
        'x_impact --collect --fetch-x --days 30',
        'x_impact --json'
      ]
    },
    'leads' => {
      usage: 'leads --query "TEXT" [--site-limit N] [--page-limit N] [--domain example.com] [--json]',
      description: 'Find candidate sites with Exa and build readable site dossiers with Firecrawl.',
      flags: {
        '--query "TEXT"' => 'Lead research query sent to Exa',
        '--domain DOMAIN' => 'Research a known domain directly (repeatable)',
        '--search-results N' => 'How many Exa hits to request before deduping domains (default: 12)',
        '--site-limit N' => 'How many unique domains to research (default: 5)',
        '--page-limit N' => 'How many pages to scrape per site (default: 4)',
        '--map-limit N' => 'How many mapped URLs to fetch from Firecrawl (default: 25)',
        '--skip-map' => 'Skip the site map step and scrape homepage/source pages only',
        '--json' => 'Print the saved report JSON to stdout'
      },
      examples: [
        'leads --query "mac app review sites"',
        'leads --query "security newsletters for developers" --site-limit 8',
        'leads --domain setapp.com --domain macstories.net'
      ]
    },
    'enable_ci_tests' => {
      usage: 'enable_ci_tests',
      description: 'Temporarily re-enable test targets in project.yml for CI. Backs up original, regenerates Xcode project.',
      flags: {},
      examples: ['enable_ci_tests']
    },
    'restore_ci_tests' => {
      usage: 'restore_ci_tests',
      description: 'Restore project.yml from CI backup after tests complete.',
      flags: {},
      examples: ['restore_ci_tests']
    },
    'fix_mocks' => {
      usage: 'fix_mocks',
      description: 'Add @testable import to generated Mocks.swift file after mockolo generation.',
      flags: {},
      examples: ['fix_mocks']
    },
    'monitor_tests' => {
      usage: 'monitor_tests [--scheme NAME] [--test SELECTOR] [--timeout POSITIVE_SECONDS]',
      description: 'Run xcodebuild tests with live progress, bounded cleanup, and parsed xcresult proof of nonzero selected test cases.',
      flags: {
        '--scheme NAME' => 'Scheme to test (default: current project scheme)',
        '--test SELECTOR' => 'Exact xcodebuild only-testing selector',
        '--timeout POSITIVE_SECONDS' => 'Timeout before verified process-tree cleanup (default: 300)'
      },
      examples: [
        'monitor_tests                          # Test current scheme, 5min timeout',
        'monitor_tests --scheme SaneBar --test SaneBarTests/HistoryTests/testPaste --timeout 120'
      ]
    },
    'image_info' => {
      usage: 'image_info <path>',
      description: 'Extract image file info and base64 data for analysis.',
      flags: {},
      examples: ['image_info screenshot.png']
    }
  }.freeze
  # rubocop:enable Lint/UselessConstantScoping

  def print_command_detail(command)
    # Find command info from COMMANDS hash
    cmd_info = nil
    category = nil
    COMMANDS.each do |cat, data|
      data[:commands].each do |cmd, info|
        next unless cmd == command

        cmd_info = info
        category = cat
        break
      end
      break if cmd_info
    end

    command = canonical_command_name(command) if respond_to?(:canonical_command_name, true)

    details = COMMAND_DETAILS[command]

    puts <<~HEADER
      ┌─────────────────────────────────────────────────────────────┐
      │  #{command.upcase.center(57)}  │
      └─────────────────────────────────────────────────────────────┘

    HEADER

    if details
      puts "Usage: ./scripts/SaneMaster.rb #{details[:usage]}"
      puts
      puts 'Description:'
      puts "  #{details[:description]}"

      if details[:flags].any?
        puts
        puts 'Flags:'
        details[:flags].each do |flag, desc|
          puts "  #{flag.ljust(20)} #{desc}"
        end
      end

      if details[:examples].any?
        puts
        puts 'Examples:'
        details[:examples].each { |ex| puts "  ./scripts/SaneMaster.rb #{ex}" }
      end
    elsif cmd_info
      puts "Usage: ./scripts/SaneMaster.rb #{command} #{cmd_info[:args]}"
      puts
      puts 'Description:'
      puts "  #{cmd_info[:desc]}"
      puts
      puts "Category: #{category}"
    else
      puts "No detailed help available for '#{command}'"
      puts
      puts "Run './scripts/SaneMaster.rb' to see all available commands."
    end
  end
end

# --- Main Entry Point ---
SaneMaster.new.run(ARGV) if __FILE__ == $PROGRAM_NAME
