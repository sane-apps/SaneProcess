#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneMaster: Professional Automation Suite for SaneApps
# ==============================================================================
# Modular architecture - see Scripts/sanemaster/ for implementations:
#   base.rb        - Shared constants and utilities
#   memory.rb      - Memory MCP integration
#   dependencies.rb - Version checking, dependency graphs
#   generation.rb   - Test/mock generation, templates
#   diagnostics.rb  - Crash analysis, xcresult diagnosis
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
require 'fileutils'
require 'digest'

# Load all modules
require_relative 'sanemaster/base'
require_relative 'sanemaster/memory'
require_relative 'sanemaster/dependencies'
require_relative 'sanemaster/generation'
require_relative 'sanemaster/diagnostics'
require_relative 'sanemaster/bootstrap'
require_relative 'sanemaster/test_mode'
require_relative 'sanemaster/verify'
require_relative 'sanemaster/quality'
require_relative 'sanemaster/sop_loop'
require_relative 'sanemaster/export'
require_relative 'sanemaster/md_export'
require_relative 'sanemaster/meta'
require_relative 'sanemaster/tool_discovery'
require_relative 'sanemaster/session'
require_relative 'sanemaster/circuit_breaker_state'
require_relative 'sanemaster/structural_compliance'
require_relative 'sanemaster/release'
require_relative 'sanemaster/ci_helpers'
require_relative 'sanemaster/sales'
require_relative 'sanemaster/downloads'
require_relative 'sanemaster/leads'

class SaneMaster
  include SaneMasterModules::Base
  include SaneMasterModules::Memory
  include SaneMasterModules::Dependencies
  include SaneMasterModules::Generation
  include SaneMasterModules::Diagnostics
  include SaneMasterModules::Bootstrap
  include SaneMasterModules::TestMode
  include SaneMasterModules::Verify
  include SaneMasterModules::Quality
  include SaneMasterModules::SOPLoop
  include SaneMasterModules::Export
  include SaneMasterModules::MdExport
  include SaneMasterModules::Meta
  include SaneMasterModules::ToolDiscovery
  include SaneMasterModules::Session
  include SaneMasterModules::StructuralCompliance
  include SaneMasterModules::Release
  include SaneMasterModules::CIHelpers
  include SaneMasterModules::Sales
  include SaneMasterModules::Downloads
  include SaneMasterModules::Leads

  # ═══════════════════════════════════════════════════════════════════════════
  # COMMAND REFERENCE - Organized by category for easy discovery
  # ═══════════════════════════════════════════════════════════════════════════
  COMMANDS = {
    build: {
      desc: 'Build, test, and validate code',
      commands: {
        'verify' => { args: '[--ui] [--clean] [--grant-permissions]', desc: 'Build and run tests (unit by default, --ui for UI)' },
        'clean' => { args: '[--nuclear]', desc: 'Wipe build cache and test states' },
        'lint' => { args: '', desc: 'Run SwiftLint and auto-fix issues' },
        'audit' => { args: '', desc: 'Scan for missing accessibility identifiers' },
        'system_check' => { args: '', desc: 'Verify unified hook system across all projects' },
        'release' => { args: '[--full|--deploy|--no-deploy|--skip-notarize|--version X.Y.Z|--notes "..."]', desc: 'Build, sign, notarize, package, and optionally deploy' },
        'release_preflight' => { args: '', desc: 'Run all pre-release safety checks without building' },
        'appstore_preflight' => { args: '', desc: 'Run App Store submission compliance checks' }
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
        'check_docs' => { args: '', desc: 'Check docs are in sync with code' },
        'check_binary' => { args: '', desc: 'Audit binary for security issues' },
        'test_scan' => { args: '[-v]', desc: 'Scan tests for tautologies and hardcoded values' },
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
        'menu_scan' => { args: '[--json] [--owners bundle1,bundle2]', desc: 'Menu bar diagnostics (detected/normalized/excluded)' },
        'mode' => { args: '[<AppName>] <pro|basic|free|status|owner-check|owner-install|owner-pro|owner-verify|list> [--launch] [--host local|mini]', desc: 'Set/query test mode or owner-mode install/license state' }
      }
    },
    env: {
      desc: 'Environment and setup',
      commands: {
        'doctor' => { args: '', desc: 'Check environment health' },
        'tool_discovery' => { args: '--query "TEXT"', desc: 'Generate a proof receipt before workarounds or new tools' },
        'health' => { args: '', desc: 'Quick health check (< 100ms)' },
        'meta' => { args: '', desc: 'Audit SaneMaster tooling itself' },
        'bootstrap' => { args: '[--check-only]', desc: 'Full environment setup' },
        'setup' => { args: '', desc: 'Install gems and dependencies' },
        'versions' => { args: '', desc: 'Check tool versions' },
        'reset' => { args: '', desc: 'Reset TCC permissions' },
        'restore' => { args: '', desc: 'Fix Xcode/Launch Services issues' },
        'dedupe_apps' => { args: '[--host local|mini] [--apps App1,App2] [--dry-run] [--json]', desc: 'Keep one canonical app bundle per Sane app' },
        'mcp_watchdog' => { args: '[status|doctor|clean|install|uninstall] [--max N] [--interval SEC] [--json] [--quiet]', desc: 'Detect and clean duplicate MCP daemons' },
        'work_session_on' => { args: '', desc: 'Start keep-awake + no-lock work session guard' },
        'work_session_off' => { args: '', desc: 'Restore previous lock settings and stop work-session guard' },
        'work_session_status' => { args: '', desc: 'Show current work-session guard state' }
      }
    },
    memory: {
      desc: 'Cross-session memory (MCP)',
      commands: {
        'mc' => { args: '', desc: 'Show memory context' },
        'mr' => { args: '<type> <name>', desc: 'Record new entity' },
        'mp' => { args: '[--dry-run]', desc: 'Prune stale entities' },
        'mh' => { args: '', desc: 'Memory health check (entity/token counts)' },
        'msync' => { args: '(pipe JSON)', desc: 'Sync MCP memory to local cache' },
        'mcompact' => { args: '[--dry-run] [--aggressive]', desc: 'Compact memory (trim verbose, dedupe)' },
        'mcleanup' => { args: '(pipe JSON)', desc: 'Analyze MCP memory, generate cleanup commands' },
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
        'sales' => { args: '[--daily|--month|--products|--fees|--refund-order ID|--refund-order-number N|--json]', desc: 'LemonSqueezy sales report and refunds (default: daily breakdown)' },
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
        'monitor_tests' => { args: '[scheme] [test] [timeout]', desc: 'Run tests with timeout and progress' },
        'image_info' => { args: '<path>', desc: 'Extract image info and base64' }
      }
    },
    export: {
      desc: 'Export and documentation',
      commands: {
        'export' => { args: '[--highlight]', desc: 'Export code to PDF (~/Downloads)' },
        'md_export' => { args: '<file.md>', desc: 'Convert markdown to PDF' },
        'deps' => { args: '[--dot]', desc: 'Show dependency graph' },
        'quality' => { args: '', desc: 'Generate Ruby quality report' }
      }
    }
  }.freeze

  QUICK_START = [
    { cmd: 'verify', desc: 'Build + run tests' },
    { cmd: 'test_mode', desc: 'Kill → Build → Launch → Logs' },
    { cmd: 'doctor', desc: 'Check environment health' },
    { cmd: 'tool_discovery', desc: 'Prove existing-tool checks before workarounds' },
    { cmd: 'export', desc: 'Export code to PDF' }
  ].freeze

  KNOWN_SANE_APPS = %w[SaneBar SaneClip SaneClick SaneHosts SaneSales SaneSync SaneVideo].freeze

  MINI_FIRST_COMMANDS = Set.new(%w[
                                  verify
                                  clean
                                  lint
                                  quality
                                  audit
                                  system_check
                                  release
                                  release_preflight
                                  appstore_preflight
                                  asp
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
                                  crash_report
                                  crashes
                                  menu_scan
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
    if args.empty?
      print_help
      return
    end

    command = args.shift

    # Handle 'help <category>' specially
    if command == 'help'
      category = args.shift
      if category
        print_category_help(category.to_sym)
      else
        print_help
      end
      return
    end

    ensure_work_session_ready!(command)
    maybe_route_to_mini!(command, args)

    dispatch_command(command, args)
  end

  private

  def maybe_route_to_mini!(command, args)
    return if ENV['SANEMASTER_DISABLE_MINI_ROUTING'] == '1'
    return if running_on_mini_host?
    return unless MINI_FIRST_COMMANDS.include?(command)

    if ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1' && %w[launch run test_mode tm].include?(command)
      puts '⚠️  Unsigned fallback active; running locally to honor Debug fallback.'
      return
    end

    if args.include?('--local') || ENV['SANEMASTER_FORCE_LOCAL'] == '1'
      puts '⚠️  Mini-first bypass active (--local or SANEMASTER_FORCE_LOCAL=1); running locally.'
      return
    end

    unless mini_reachable?
      puts '⚠️  Mac mini is unreachable. Falling back to local execution.'
      return
    end

    remote_repo = map_local_path_to_mini(Dir.pwd)
    unless remote_repo
      puts "⚠️  Could not map local path to mini: #{Dir.pwd}"
      puts '   Falling back to local execution.'
      return
    end

    unless mini_path_exists?(remote_repo)
      puts "⚠️  Repo not found on mini: #{remote_repo}"
      puts '   Falling back to local execution.'
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
      execution_repo = if release_routed
                         prepare_release_workspace_on_mini!(Dir.pwd, remote_repo, preserve_release_artifacts: preserve_release_artifacts)
                       else
                         sync_workspace_to_mini!(remote_repo)
                         remote_repo
                       end
      execution_saneprocess_repo = release_routed ? routed_release_path_for_local(saneprocess_repo_root) : remote_saneprocess_repo
      if workspace_uses_saneui?(Dir.pwd) && Dir.exist?(saneui_repo_root)
        remote_saneui_repo = map_local_path_to_mini(saneui_repo_root)
        unless remote_saneui_repo
          abort "❌ Could not map SaneUI to mini: #{saneui_repo_root}"
        end
        remote_saneui_repo = routed_release_path_for_local(saneui_repo_root) if release_routed
        sync_local_dir_to_mini!(saneui_repo_root, remote_saneui_repo, label: 'SaneUI')
      end
      sync_local_dir_to_mini!(saneprocess_repo_root, execution_saneprocess_repo, label: 'SaneProcess')
      sync_release_artifacts_to_mini!(Dir.pwd, execution_repo) if preserve_release_artifacts
      if release_routed
        routed_webhook_repo = sync_release_support_repos_to_mini!(release_routed: true)
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
        SANEBAR_BUILD_CONFIG
        SANEMASTER_CANONICAL_APP_PATH
        SANEPROCESS_APPROVE_FAST_RELEASE
        SANEPROCESS_APPROVE_OPEN_REGRESSION_RELEASE
        SANEPROCESS_APPROVE_UNCONFIRMED_REGRESSION_CLOSE
        SANEBAR_APPROVE_FAST_RELEASE
        SANEBAR_APPROVE_OPEN_REGRESSION_RELEASE
        SANEBAR_APPROVE_UNCONFIRMED_REGRESSION_CLOSE
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
      remote_cmd = "#{remote_env_prefix}ruby #{Shellwords.escape(remote_script)} #{([command] + args).map { |arg| Shellwords.escape(arg) }.join(' ')}"
      puts "📍 Mini-first routing: #{command} -> mini (#{execution_repo})"
      $stdout.flush
      ssh_args = ['ssh']
      ssh_args << '-tt' if $stdout.tty?
      remote_ok = system(*ssh_args, 'mini', "cd #{Shellwords.escape(execution_repo)} && #{remote_cmd}")
      remote_status = $?.respond_to?(:exitstatus) ? $?.exitstatus : (remote_ok ? 0 : 1)
      sync_outputs_from_mini!(Dir.pwd, execution_repo)
      sync_release_artifacts_from_mini!(Dir.pwd, execution_repo, warn_only: true) if release_routed
      sync_release_support_repos_from_origin! if release_routed && remote_status.zero?
      exit remote_status
    end
  end

  def with_mini_route_lock(remote_repo, command)
    digest = Digest::SHA256.hexdigest(remote_repo)[0, 16]
    lock_path = File.join(Dir.tmpdir, "sanemaster-mini-route-#{digest}.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))

    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
      waited = !lock_file.flock(File::LOCK_EX | File::LOCK_NB)
      if waited
        puts "⏳ Waiting for mini workspace lock: #{command} @ #{remote_repo}"
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
    user = ENV.fetch('USER', '').downcase
    host.include?('mini') || user == 'stephansmac'
  rescue StandardError
    false
  end

  def mini_reachable?
    system('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=2', 'mini', 'true', out: File::NULL, err: File::NULL)
  end

  def map_local_path_to_mini(local_path)
    return local_path if local_path.start_with?('/Users/stephansmac/')
    return nil unless local_path.start_with?('/Users/sj/')

    "/Users/stephansmac/#{local_path.delete_prefix('/Users/sj/')}"
  end

  def mini_path_exists?(remote_path)
    system('ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', 'mini', "test -d #{Shellwords.escape(remote_path)}", out: File::NULL, err: File::NULL)
  end

  def repo_has_uncommitted_changes?
    return false unless system('git', 'rev-parse', '--is-inside-work-tree', out: File::NULL, err: File::NULL)
    return true unless system('git', 'diff', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)
    return true unless system('git', 'diff', '--cached', '--quiet', '--ignore-submodules=dirty', out: File::NULL, err: File::NULL)

    false
  rescue StandardError
    false
  end

  def sync_workspace_to_mini!(remote_repo)
    puts "🔄 Syncing local workspace snapshot to mini (#{remote_repo})"
    sync_local_dir_to_mini!(Dir.pwd, remote_repo, label: nil)
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
    sync_release_artifacts_from_mini!(local_repo, scratch_repo, warn_only: true) if preserve_release_artifacts
    remote_bundle_path = File.join('/tmp', "sanemaster-route-#{Digest::SHA256.hexdigest("#{File.expand_path(local_repo)}:#{head}")[0, 16]}.bundle")
    sync_git_bundle_to_mini!(local_repo, branch, remote_bundle_path) unless mini_repo_has_commit?(remote_repo, head)
    remote_cmd = <<~SH
      set -e
      bundle_path=#{Shellwords.escape(remote_bundle_path)}
      cleanup() {
        rm -f "$bundle_path"
      }
      trap cleanup EXIT
      rm -rf #{Shellwords.escape(scratch_root)}
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
    ok = system('ssh', 'mini', remote_cmd)
    abort '❌ Failed to prepare a clean routed release workspace on the mini.' unless ok

    puts "🔄 Syncing local workspace snapshot to mini (#{scratch_repo})"
    sync_local_dir_to_mini!(local_repo, scratch_repo, label: nil)
    scratch_repo
  end

  def release_artifact_resume_requested?(command, args)
    command == 'release' && args.include?('--skip-build')
  end

  def mini_repo_has_commit?(remote_repo, commit)
    system(
      'ssh',
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
      ok = system('ssh', 'mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
      abort '❌ Failed to prepare the routed release bundle path on the mini.' unless ok

      ok = system('rsync', '-az', tmp.path, "mini:#{remote_bundle_path}")
      abort '❌ Failed to sync the routed release git bundle to the mini.' unless ok
    end
  end

  def mini_release_workspace_root(local_repo)
    digest = Digest::SHA256.hexdigest(File.expand_path(local_repo))[0, 12]
    File.join('/Users/stephansmac', '.sanemaster', 'routed-workspaces', digest)
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
    %w[release release_preflight appstore_preflight asp].include?(command)
  end

  def saneprocess_repo_root
    File.expand_path('..', __dir__)
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

  def sync_release_support_repos_to_mini!(release_routed: false)
    webhook_repo = sane_email_automation_repo_root
    return unless Dir.exist?(webhook_repo)

    remote_webhook_repo = map_local_path_to_mini(webhook_repo)
    abort "❌ Could not map sane-email-automation to mini: #{webhook_repo}" unless remote_webhook_repo

    if release_routed
      prepare_release_workspace_on_mini!(webhook_repo, remote_webhook_repo)
    else
      sync_local_dir_to_mini!(webhook_repo, remote_webhook_repo, label: 'sane-email-automation')
      remote_webhook_repo
    end
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

  def sync_cktool_auth_to_mini!
    local_cktool_path = File.expand_path('~/.config/cktool')
    return unless File.exist?(local_cktool_path)

    remote_cktool_path = map_local_path_to_mini(local_cktool_path)
    abort "❌ Could not map cktool config to mini: #{local_cktool_path}" unless remote_cktool_path

    remote_parent = File.dirname(remote_cktool_path)
    ok = system('ssh', 'mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
    abort '❌ Failed to prepare cktool auth parent on the mini.' unless ok

    if File.directory?(local_cktool_path)
      puts "⚠️ Local cktool auth path is a directory; syncing legacy contents to mini (#{remote_cktool_path})"
      ok = system(
        'ssh',
        'mini',
        "if [ -f #{Shellwords.escape(remote_cktool_path)} ]; then /usr/bin/trash #{Shellwords.escape(remote_cktool_path)}; fi && mkdir -p #{Shellwords.escape(remote_cktool_path)}"
      )
      abort '❌ Failed to prepare legacy cktool auth directory on the mini.' unless ok

      ok = system(
        'rsync',
        '-az',
        '--delete',
        "#{local_cktool_path}/",
        "mini:#{remote_cktool_path}/"
      )
      abort '❌ Failed to sync legacy cktool auth directory to the mini.' unless ok
      return
    end

    ok = system(
      'ssh',
      'mini',
      "if [ -d #{Shellwords.escape(remote_cktool_path)} ]; then /usr/bin/trash #{Shellwords.escape(remote_cktool_path)} 2>/dev/null || [ ! -e #{Shellwords.escape(remote_cktool_path)} ]; fi"
    )
    abort '❌ Failed to clear stale cktool auth directory on the mini.' unless ok

    puts "🔄 Syncing cktool auth to mini (#{remote_cktool_path})"
    ok = system(
      'rsync',
      '-az',
      local_cktool_path,
      "mini:#{remote_cktool_path}"
    )
    abort '❌ Failed to sync cktool auth file to the mini.' unless ok
  end

  def sync_local_dir_to_mini!(local_dir, remote_dir, label: nil)
    puts "🔄 Syncing #{label} to mini (#{remote_dir})" if label
    remote_parent = File.dirname(remote_dir)
    ok = system('ssh', 'mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
    abort "❌ Failed to prepare mini destination for #{label || 'the current workspace snapshot'}." unless ok

    ok = system(
      'rsync',
      '-az',
      '--delete',
      '--exclude', '.git',
      '--exclude', '.worktrees',
      '--exclude', '.build',
      '--exclude', 'build',
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
    ok = system(
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
    ok = system('ssh', 'mini', remote_cmd)
    return if ok

    abort '❌ Failed to prepare the mini workspace after sync.'
  end

  def write_route_context_to_mini!(remote_repo, command, webhook_remote_repo: nil)
    context = build_route_context(command, webhook_remote_repo: webhook_remote_repo)
    remote_context_dir = File.join(remote_repo, '.sanemaster')
    remote_context_path = File.join(remote_context_dir, 'mini_route_context.json')
    ok = system('ssh', 'mini', "mkdir -p #{Shellwords.escape(remote_context_dir)}")
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
    changed_files_output, changed_files_status = Open3.capture2(
      'git', '-C', repo_dir, 'diff', 'HEAD~5..HEAD', '--name-only', '--', '*.swift'
    )

    {
      'path' => repo_dir,
      'branch' => branch.to_s.strip,
      'head' => head.to_s.strip,
      'dirty_count' => dirty_output.to_s.lines.reject { |line| line.strip.empty? }.count,
      'dirty_files' => dirty_output.to_s.lines.map(&:chomp).reject(&:empty?),
      'recent_changed_swift_files' => if changed_files_status.success?
                                        changed_files_output.to_s.lines.map(&:strip).reject(&:empty?)
                                      else
                                        []
                                      end,
      'remote_sync' => local_repo_remote_sync_context(repo_dir, branch.to_s.strip, head.to_s.strip)
    }
  rescue StandardError
    {
      'path' => repo_dir,
      'branch' => '',
      'head' => '',
      'dirty_count' => 0,
      'dirty_files' => [],
      'recent_changed_swift_files' => [],
      'remote_sync' => { 'status' => 'unavailable' }
    }
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
    ok = system('rsync', '-az', "mini:#{remote_outputs_dir}/", "#{local_outputs_dir}/")
    warn '⚠️  Failed to sync Mini outputs back to the local workspace.' unless ok
  end

  def sync_release_artifacts_to_mini!(local_repo, remote_repo)
    release_artifact_relative_paths.each do |relative_path|
      local_path = File.join(File.expand_path(local_repo), relative_path)
      next unless File.exist?(local_path)

      remote_path = File.join(remote_repo, relative_path)
      remote_parent = File.dirname(remote_path)
      ok = system('ssh', 'mini', "mkdir -p #{Shellwords.escape(remote_parent)}")
      abort "❌ Failed to prepare mini destination for routed release artifacts (#{relative_path})." unless ok

      puts "🔄 Syncing routed release artifacts to mini (#{remote_path})"
      if File.directory?(local_path)
        ok = system('rsync', '-az', '--delete', "#{local_path}/", "mini:#{remote_path}/")
      else
        ok = system('rsync', '-az', local_path, "mini:#{remote_path}")
      end
      abort "❌ Failed to sync routed release artifacts for #{relative_path} to the mini." unless ok
    end
  end

  def sync_release_artifacts_from_mini!(local_repo, remote_repo, warn_only: false)
    release_artifact_relative_paths.each do |relative_path|
      remote_path = File.join(remote_repo, relative_path)
      next unless mini_path_exists_fast?(remote_path)

      local_path = File.join(File.expand_path(local_repo), relative_path)
      FileUtils.mkdir_p(File.dirname(local_path))
      ok = if mini_directory?(remote_path)
             FileUtils.mkdir_p(local_path)
             system('rsync', '-az', '--delete', "mini:#{remote_path}/", "#{local_path}/")
           else
             system('rsync', '-az', "mini:#{remote_path}", "#{local_path}")
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
    system(
      'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
      'mini',
      "test -d #{Shellwords.escape(remote_path)}",
      out: File::NULL,
      err: File::NULL
    )
  end

  def mini_path_exists_fast?(remote_path)
    system(
      'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
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
    when 'crash_report', 'crashes'
      analyze_crashes(args)
    when 'menu_scan'
      menu_scan(args)

    # Environment & Health
    when 'doctor'
      doctor
    when 'tool_discovery', 'tool_receipt', 'tool-receipt'
      tool_discovery(args)
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
    when 'dedupe_apps', 'dedupe-apps'
      system('ruby', File.join(__dir__, 'dedupe_sane_apps.rb'), *args)
    when 'mcp_watchdog', 'mcpw', 'mcp'
      mcp_watchdog(args)
    when 'work_session_on', 'wson'
      work_session_on
    when 'work_session_off', 'wsof'
      work_session_off
    when 'work_session_status', 'wsst'
      work_session_status

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
    when 'release'
      release(args)
    when 'release_preflight'
      release_preflight(args)
    when 'appstore_preflight', 'asp'
      appstore_preflight(args)

    # Sales & Downloads
    when 'sales'
      sales(args)
    when 'downloads', 'dl'
      downloads(args)
    when 'events'
      events(args)
    when 'leads', 'prospects'
      leads(args)

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
    when 'test_suite', 'suite'
      run_test_suite(args)
    when 'test_scan', 'scan_tests', 'test_quality'
      run_test_scan(args)
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
      launch_app(args)
    when 'logs'
      show_app_logs(args)
    when 'test_mode', 'tm'
      enter_test_mode(args)
    when 'mode', 'test_mode_switch', 'license_mode'
      app_test_mode(args)

    # Memory MCP
    when 'memory_context', 'mc'
      show_memory_context(args)
    when 'memory_record', 'mr'
      record_memory_entity(args)
    when 'memory_prune', 'mp'
      prune_memory_entities(args)
    when 'memory_health', 'mh'
      memory_health(args)
    when 'memory_sync', 'msync'
      memory_sync(args)
    when 'memory_compact', 'mcompact'
      memory_compact(args)
    when 'memory_cleanup', 'mcleanup'
      memory_cleanup(args)
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
      puts '   To see errors: ./Scripts/SaneMaster.rb breaker_errors'
      puts '   To reset: ./Scripts/SaneMaster.rb reset_breaker'
    else
      puts "   Status: 🟢 #{status[:status]}"
      puts "   #{status[:message]}"
    end
    puts ''
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
        ./Scripts/SaneMaster.rb verify          # Build + test
        ./Scripts/SaneMaster.rb help build      # Show build commands
        ./Scripts/SaneMaster.rb help check      # Show analysis commands

      Aliases: sm = ./Scripts/SaneMaster.rb (if configured)
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
      usage: 'verify [--ui] [--clean] [--grant-permissions]',
      description: 'Build the project and run tests',
      flags: {
        '--ui' => 'Run UI tests instead of unit tests',
        '--clean' => 'Clean build before testing'
      },
      examples: [
        'verify                     # Run unit tests',
        'verify --ui                # Run UI tests',
        'verify --clean             # Clean build first',
        'verify --grant-permissions # Reset/grant TCC permissions before tests'
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
    'mc' => {
      usage: 'mc',
      description: 'Show current Memory MCP context',
      flags: {},
      examples: ['mc']
    },
    'mr' => {
      usage: 'mr <type> <name>',
      description: 'Record new entity to Memory MCP',
      flags: {},
      examples: ['mr bug CrashOnExport', 'mr fix AudioSyncIssue']
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
      usage: 'appstore_preflight (or asp)',
      description: 'Run App Store submission compliance checks (privacy manifest, entitlements, screenshots, usage descriptions, review notes, etc.)',
      flags: {},
      examples: ['appstore_preflight', 'asp']
    },
    'sales' => {
      usage: 'sales [--daily|--month|--products|--fees|--refund-order ID|--refund-order-number N|--json]',
      description: 'LemonSqueezy sales report and order refunds. Default: daily breakdown (today/yesterday/week/all-time).',
      flags: {
        '--daily' => 'Today/yesterday/week/all-time breakdown (default)',
        '--month' => 'Current month with monthly aggregates',
        '--products' => 'Revenue by product',
        '--fees' => 'Detailed fee breakdown',
        '--refund-order ID' => 'Issue a refund for a Lemon Squeezy order ID',
        '--refund-order-number N' => 'Issue a refund for a Lemon Squeezy order number',
        '--amount CENTS' => 'Refund a specific amount in cents (omit for full refund)',
        '--proof-file PATH' => 'Write a human-readable refund proof file',
        '--json' => 'Raw JSON output for piping'
      },
      examples: [
        'sales                # Today/yesterday/week/all-time',
        'sales --month        # Current month',
        'sales --products     # Revenue by product',
        'sales --fees         # Fee breakdown',
        'sales --refund-order 7679013 --proof-file /tmp/refund.txt'
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
      usage: 'monitor_tests [scheme] [test_name] [timeout_seconds]',
      description: 'Run xcodebuild tests with live progress reporting and timeout detection.',
      flags: {},
      examples: [
        'monitor_tests                          # Test current scheme, 5min timeout',
        'monitor_tests SaneBar MyTest 120       # Specific test, 2min timeout'
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

    # Check for alias mappings
    aliases = {
      'tm' => 'test_mode', 'crashes' => 'crash_report', 'versions' => 'version_check',
      'deprecations' => 'check_deprecations', 'pdf' => 'export'
    }
    command = aliases[command] if aliases.key?(command)

    details = COMMAND_DETAILS[command]

    puts <<~HEADER
      ┌─────────────────────────────────────────────────────────────┐
      │  #{command.upcase.center(57)}  │
      └─────────────────────────────────────────────────────────────┘

    HEADER

    if details
      puts "Usage: ./Scripts/SaneMaster.rb #{details[:usage]}"
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
        details[:examples].each { |ex| puts "  ./Scripts/SaneMaster.rb #{ex}" }
      end
    elsif cmd_info
      puts "Usage: ./Scripts/SaneMaster.rb #{command} #{cmd_info[:args]}"
      puts
      puts 'Description:'
      puts "  #{cmd_info[:desc]}"
      puts
      puts "Category: #{category}"
    else
      puts "No detailed help available for '#{command}'"
      puts
      puts "Run './Scripts/SaneMaster.rb' to see all available commands."
    end
  end
end

# --- Main Entry Point ---
SaneMaster.new.run(ARGV) if __FILE__ == $PROGRAM_NAME
