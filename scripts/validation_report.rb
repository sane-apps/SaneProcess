#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# SaneProcess Validation Report - SCIENTIFIC EDITION
# ==============================================================================
# Answers ONE question: Is SaneProcess making us 10x more productive?
#
# NOT vanity metrics. HARD questions:
#   1. Are blocks CORRECT? (User didn't override = correct)
#   2. Are doom loops being CAUGHT? (Breaker trips on repeat errors)
#   3. Is score variance REAL? (Not just rubber-stamping 8/10)
#   4. Are tests PASSING at session end? (Actual quality)
#   5. TREND over time? (Getting better or worse?)
#
# Requires 100+ data points for statistical significance.
# ==============================================================================

require 'json'
require 'yaml'
require 'date'
require 'time'
require 'fileutils'
require 'net/http'
require 'open3'
require 'uri'
require 'shellwords'
require 'tmpdir'

class ValidationReport
  SANE_APPS_ROOT = File.expand_path('~/SaneApps')
  REPORT_DIR = File.join(File.dirname(__FILE__), '..', 'outputs', 'validation')
  PRODUCT_CONFIG_PATH = File.join(SANE_APPS_ROOT, 'infra/SaneProcess/config/products.yml')
  PROCESS_METRICS_PATH = File.expand_path('~/.sanemaster/process_metrics.jsonl')
  MIN_SAMPLES_FOR_SIGNIFICANCE = 30  # Bare minimum, 100+ preferred
  WORKFLOW_POLICY_EXCEPTION_MARKER = 'SANEAPPS_GITHUB_HOSTED_EXCEPTION:'
  MANUAL_WORKFLOW_TRIGGERS = %w[workflow_dispatch workflow_call].freeze
  GITHUB_POLICY_SEGMENTS = %w[apps infra mcp web].freeze
  AGENTS_WARNING_BYTES = 28 * 1024
  AGENTS_HARD_BYTES = 32 * 1024
  AGENTS_WARNING_LINES = 450
  RESEARCH_CACHE_MAX_LINES = 200
  HANDOFF_MAX_LINES = 800
  WORKFLOW_EXCEPTIONS_CONFIG_PATH = File.join(File.dirname(__FILE__), '..', 'config', 'github_workflow_exceptions.yml')
  RED_NOISE_BUDGET_DAYS = 7

  PROJECTS = %w[
    apps/SaneBar
    apps/SaneVideo
    apps/SaneSync
    apps/SaneClip
    apps/SaneHosts
    apps/SaneClick
    infra/SaneProcess
  ].freeze

  # Apps only (for release/distribution checks)
  APP_PROJECTS = %w[
    apps/SaneBar
    apps/SaneVideo
    apps/SaneSync
    apps/SaneClip
    apps/SaneHosts
    apps/SaneClick
  ].freeze

  def initialize
    load_headless_env
    @data = {}
    @issues = []
    @warnings = []
    @metrics = {}
    @verdict = nil
    @workflow_policy_exception_count = 0
  end

  def run(format: :text)
    collect_data
    run_hard_analysis

    case format
    when :json then output_json
    when :text then output_text
    end

    save_snapshot
  end

  private

  def collect_data
    PROJECTS.each do |project|
      state_file = File.join(SANE_APPS_ROOT, project, '.claude', 'state.json')
      next unless File.exist?(state_file)

      begin
        raw = JSON.parse(File.read(state_file))
        state = raw['data'] || raw
        @data[project] = { state: state, mtime: File.mtime(state_file) }
      rescue JSON::ParserError => e
        @issues << "[#{project}] Corrupt state.json: #{e.message}"
      end
    end
  end

  # ==========================================================================
  # THE HARD QUESTIONS
  # ==========================================================================
  def run_hard_analysis
    q0_config_consistency  # Config drift, deprecated plugins, npm vs local
    q1_block_accuracy
    q2_doom_loop_prevention
    q3_score_integrity
    q4_test_outcomes
    q5_trend_analysis
    # NEW: Release pipeline and customer-facing checks
    q6_release_integrity      # Appcast URLs, GitHub releases, DMG verification
    q7_website_distribution   # SSL, DNS, download links
    q8_code_signing           # Identity, notarization, entitlements
    q9_support_infrastructure # Email, API keys, keychain
    q10_documentation_currency # Version consistency, changelog, README
    q11_cross_channel_version_consistency # Appcast vs website vs webhook vs Homebrew
    q12_red_noise_budget
    calculate_final_verdict
  end

  def process_metric_events(type: nil)
    @process_metric_events ||= begin
      if File.exist?(PROCESS_METRICS_PATH)
        File.readlines(PROCESS_METRICS_PATH, chomp: true).map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end.compact
      else
        []
      end
    end
    return @process_metric_events unless type

    @process_metric_events.select { |event| event['type'] == type.to_s }
  end

  def finding_area(finding)
    text = finding.to_s
    case text
    when /^Q[0-5]\b/, /^Q[0-5]\s/, /^Q[0-5]:/, /^Q[0-5] FAIL:/, /^Q0 CONFIG:/
      :system_health
    when /^Q6 RELEASE:/, /^Q7 WEBSITE:/, /^Q8 SIGNING:/, /^Q11 DRIFT:/, /^Q11 HOSTED FILE ACTION:/
      :release_readiness
    when /^Q10 DOCS:/
      :app_readiness
    when /^Q9 SUPPORT:/
      :system_health
    else
      :advisory
    end
  end

  def finding_action(finding)
    text = finding.to_s
    case text
    when /automatic GitHub triggers/
      'Add an inline SANEAPPS_GITHUB_HOSTED_EXCEPTION marker or a central config/github_workflow_exceptions.yml entry with a concrete reason.'
    when /verify attempts pass/
      'Use the process metrics dashboard to identify the noisiest project/failure class, then remove the repeated red/green failure source.'
    when /final verify groups finish green/
      'Inspect the latest failed verify event for each project/day and rerun the standard Mini verify after fixing the blocker.'
    when /Scores don't reflect verify churn/
      'Keep score caps tied to recovered/unrecovered verification failures; do not raise SOP scores manually without final green evidence.'
    when /failed verify attempts recorded zero tests/
      'Classify build-start/environment failures separately from test-suite failures and fix the top repeat setup blocker.'
    when /AGENTS\.md/
      'Move durable detail into DEVELOPMENT.md or ARCHITECTURE.md and keep AGENTS.md to active operating rules.'
    when /\.claude\/research\.md/
      'Promote stale verified research into ARCHITECTURE.md, DEVELOPMENT.md, Serena, memory, or issues, then compact the active cache.'
    when /SESSION_HANDOFF\.md/
      'Compact old session history into durable docs or memory; keep only active state, recent sessions, and next actions.'
    when /Latest project QA gate/
      'Run `ruby scripts/SaneMaster.rb refresh_qa_snapshots --dry-run`, review the commands, then rerun with `--run` for the target apps.'
    when /CHANGELOG/
      'Update the app CHANGELOG entry for the latest shipped version or mark the version as unreleased in product config.'
    when /Website has download link/
      'Update the website download href or product release config so validation can find the canonical download path.'
    when /Live release archive|Live ZIP|Live appcast|Sparkle|release URL/
      'Run release_preflight for the app and repair the missing live distribution artifact before considering that app release-ready.'
    when /Lemon Squeezy hosted file/
      'Use the hosted-file dashboard action export and update the Lemon Squeezy hosted file to the canonical release artifact.'
    else
      'Open the matching Q-section in validation_report.rb, fix the named source of truth, and rerun `ruby scripts/validation_report.rb` on the Mini.'
    end
  end

  def finding_records
    issue_records = @issues.map do |finding|
      {
        severity: 'critical',
        area: finding_area(finding).to_s,
        text: finding,
        action: finding_action(finding)
      }
    end
    warning_records = @warnings.map do |finding|
      {
        severity: 'warning',
        area: finding_area(finding).to_s,
        text: finding,
        action: finding_action(finding)
      }
    end
    issue_records + warning_records
  end

  def finding_summary_metrics
    records = finding_records
    areas = %i[system_health release_readiness app_readiness advisory]
    areas.each_with_object({}) do |area, summary|
      area_records = records.select { |record| record[:area] == area.to_s }
      summary[area] = {
        critical: area_records.count { |record| record[:severity] == 'critical' },
        warnings: area_records.count { |record| record[:severity] == 'warning' }
      }
    end
  end

  # Q0: Is config CONSISTENT across all projects?
  # Catches: deprecated plugins, npm vs local MCPs, config drift
  def q0_config_consistency
    issues_found = []

    # === DEPRECATED PLUGINS CHECK ===
    deprecated_plugins = %w[greptile]
    global_settings = File.expand_path('~/.claude/settings.json')

    if File.exist?(global_settings)
      begin
        settings = JSON.parse(File.read(global_settings))
        enabled = settings['enabledPlugins'] || {}
        deprecated_plugins.each do |plugin|
          if enabled.keys.any? { |k| k.downcase.include?(plugin) }
            issues_found << "Deprecated plugin '#{plugin}' still enabled in global settings.json"
          end
        end
      rescue JSON::ParserError
        issues_found << "Global settings.json is corrupt"
      end
    end

    # Check project settings too
    PROJECTS.each do |project|
      settings_file = File.join(SANE_APPS_ROOT, project, '.claude', 'settings.json')
      next unless File.exist?(settings_file)

      begin
        settings = JSON.parse(File.read(settings_file))
        enabled = settings['enabledPlugins'] || {}
        deprecated_plugins.each do |plugin|
          if enabled.keys.any? { |k| k.downcase.include?(plugin) }
            issues_found << "[#{project}] Deprecated plugin '#{plugin}' still enabled"
          end
        end
      rescue JSON::ParserError
        issues_found << "[#{project}] settings.json is corrupt"
      end
    end

    # === LOCAL MCP CHECK ===
    # These MCPs should use local paths, not npm
    home_dir = File.expand_path('~')
    local_mcps = {
      'apple-docs' => "#{home_dir}/Dev/apple-docs-mcp-local"
    }

    # Check global .mcp.json
    global_mcp = File.expand_path('~/.mcp.json')
    if File.exist?(global_mcp)
      check_mcp_file(global_mcp, local_mcps, 'global', issues_found)
    end

    # Check project .mcp.json files
    PROJECTS.each do |project|
      mcp_file = File.join(SANE_APPS_ROOT, project, '.mcp.json')
      next unless File.exist?(mcp_file)

      check_mcp_file(mcp_file, local_mcps, project, issues_found)
    end

    # === HOOK FILES CHECK ===
    # Verify critical hooks exist in SaneProcess (the source of truth)
    saneprocess_hooks = File.expand_path('~/SaneApps/infra/SaneProcess/scripts/hooks')
    %w[session_start.rb saneprompt.rb sanetools.rb sanetrack.rb sanestop.rb].each do |hook|
      hook_path = File.join(saneprocess_hooks, hook)
      unless File.exist?(hook_path)
        issues_found << "Missing SaneProcess hook: #{hook}"
      end
    end

    # === GLOBAL HOOK COMPLETENESS CHECK ===
    # Hooks are defined GLOBALLY in ~/.claude/settings.json (source of truth).
    # Projects opt-in via .saneprocess manifest. Claude Code merges global hooks at runtime.
    # DO NOT check project-local settings.json for hooks — that causes false positives
    # and adding hooks there recreates Session 15's duplicate-firing bug.
    hook_file_map = {
      'SessionStart' => 'session_start.rb',
      'UserPromptSubmit' => 'saneprompt.rb',
      'PreToolUse' => 'sanetools.rb',
      'PostToolUse' => 'sanetrack.rb',
      'Stop' => 'sanestop.rb'
    }

    if File.exist?(global_settings)
      begin
        settings = JSON.parse(File.read(global_settings))
        hooks = settings['hooks'] || {}

        hook_file_map.each do |hook_name, hook_file|
          hook_cmd = hooks.dig(hook_name, 0, 'hooks', 0, 'command') || ''
          if hook_cmd.empty?
            issues_found << "Global #{hook_name} hook missing"
          elsif !hook_cmd.include?(hook_file)
            issues_found << "Global #{hook_name} hook doesn't reference #{hook_file}"
          end
        end
      rescue JSON::ParserError
        issues_found << "Global settings.json is corrupt (hooks check skipped)"
      end
    else
      codex_config = File.expand_path('~/.codex/config.toml')
      if File.exist?(codex_config)
        @warnings << "Q0: Global ~/.claude/settings.json missing (Codex-only environment)"
      else
        issues_found << "Global ~/.claude/settings.json missing (no hooks configured)"
      end
    end

    # === PROJECT MANIFEST CHECK ===
    # Projects opt-in to global hooks via .saneprocess manifest file.
    # Note: identical local hooks are harmless — Claude Code deduplicates them at runtime
    # (confirmed Session 15 research). Only flag DIVERGENT local hooks.
    PROJECTS.each do |project|
      project_root = File.join(SANE_APPS_ROOT, project)
      manifest = File.join(project_root, '.saneprocess')
      unless File.exist?(manifest)
        issues_found << "[#{project}] Missing .saneprocess manifest (global hooks won't fire)"
      end
    end

    # === MEMORY.JSON EXISTENCE CHECK ===
    # Every .mcp.json referencing memory should have existing memory.json
    check_memory_json_files(issues_found)

    # === GLOBAL MCP PATH CHECK ===
    # Verify global .mcp.json paths are valid
    check_global_mcp_paths(issues_found)

    # === ENVIRONMENT VARIABLE LOCATION CHECK ===
    # GITHUB_TOKEN and other MCP tokens should be in .zprofile, not .zshrc
    check_env_var_locations(issues_found)

    # === SISTER APPS COMPLETENESS CHECK ===
    # All CLAUDE.md files should list all sister apps
    check_sister_apps_lists(issues_found)

    # === CODEX SKILL HEALTH CHECK ===
    # Local Codex skills should use real entrypoint files and match the Codex registry.
    check_codex_skill_health(issues_found)

    # === GITHUB HOSTED AUTOMATION CHECK ===
    # Repo-owned workflows and Dependabot should stay local-first unless explicitly excepted.
    check_github_workflow_policy(issues_found)

    @metrics[:config_consistency] = {
      issues: issues_found.size,
      workflow_policy_exceptions: @workflow_policy_exception_count,
      details: issues_found
    }

    issues_found.each do |issue|
      @issues << "Q0 CONFIG: #{issue}"
    end
  end

  def check_mcp_file(path, local_mcps, label, issues_found)
    begin
      config = JSON.parse(File.read(path))
      servers = config['mcpServers'] || {}

      local_mcps.each do |name, local_path|
        next unless servers[name]

        args = servers[name]['args'] || []
        command = servers[name]['command']

        # Check if using npx (npm) instead of local
        if command == 'npx' || args.any? { |a| a.include?('@') || a.include?('latest') }
          issues_found << "[#{label}] #{name} using npm instead of local (#{local_path})"
        end

        # Check if local path exists (don't hardcode username/home path)
        if command == 'node'
          local_arg = args.find { |a| a.include?(name) || a.include?('apple-docs-mcp-local') || a.include?('/dist/index.js') }
          if local_arg.nil?
            issues_found << "[#{label}] #{name} points to wrong local path"
          elsif local_arg.start_with?('/') && !File.exist?(local_arg)
            next if codex_server_uses_http?(name)
            @warnings << "Q0: [#{label}] #{name} local path missing on this machine: #{local_arg}"
          end
        end
      end
    rescue JSON::ParserError
      issues_found << "[#{label}] .mcp.json is corrupt"
    end
  end

  def codex_server_uses_http?(name)
    codex_config = File.expand_path('~/.codex/config.toml')
    return false unless File.exist?(codex_config)

    content = File.read(codex_config)
    block = content[/^\[mcp_servers\.#{Regexp.escape(name)}\]\s*\n(.*?)(?=^\[|\z)/m, 1]
    return false unless block

    block.match?(/^\s*url\s*=/)
  rescue StandardError
    false
  end

  def load_headless_env
    env_file = File.expand_path('~/.config/nv/env')
    return unless File.exist?(env_file)

    File.readlines(env_file).each do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?('#')
      next unless stripped.include?('=')

      key, value = stripped.split('=', 2)
      key = key.sub(/^export\s+/, '').strip
      value = value.strip
      value = value.gsub(/\A['"]|['"]\z/, '')
      next if key.empty? || !ENV[key].to_s.empty?

      ENV[key] = value
    end
  rescue StandardError
    # Best-effort load only; validation continues with existing ENV.
  end

  # Check that every .mcp.json memory path points to existing file
  def check_memory_json_files(issues_found)
    # Check global
    global_mcp = File.expand_path('~/.mcp.json')
    if File.exist?(global_mcp)
      check_memory_path(global_mcp, 'global', issues_found)
    end

    # Check project .mcp.json files
    PROJECTS.each do |project|
      mcp_file = File.join(SANE_APPS_ROOT, project, '.mcp.json')
      next unless File.exist?(mcp_file)
      check_memory_path(mcp_file, project, issues_found)
    end
  end

  def check_memory_path(mcp_file, label, issues_found)
    begin
      config = JSON.parse(File.read(mcp_file))
      memory_args = config.dig('mcpServers', 'memory', 'args') || []
      # Memory path is typically the last argument
      memory_path = memory_args.find { |a| a.include?('memory.json') }
      if memory_path && !File.exist?(memory_path)
        issues_found << "[#{label}] memory.json missing: #{memory_path}"
      end
    rescue JSON::ParserError
      # Already caught elsewhere
    end
  end

  # Check global .mcp.json paths are valid (not pointing to old locations)
  def check_global_mcp_paths(issues_found)
    global_mcp = File.expand_path('~/.mcp.json')
    return unless File.exist?(global_mcp)

    begin
      config = JSON.parse(File.read(global_mcp))
      servers = config['mcpServers'] || {}

      # Check memory path uses correct SaneApps structure
      memory_args = servers.dig('memory', 'args') || []
      memory_path = memory_args.find { |a| a.include?('memory.json') }
      if memory_path
        # Old path: ~/SaneBar, ~/SaneVideo, etc.
        # New path: ~/SaneApps/apps/SaneBar, ~/SaneApps/apps/SaneVideo, etc.
        if memory_path.match?(%r{/Users/[^/]+/Sane[A-Z][^/]*/\.claude/memory\.json})
          issues_found << "[global] Memory path uses old location (should be ~/SaneApps/apps/...)"
        end
      end
    rescue JSON::ParserError
      # Already caught elsewhere
    end
  end

  # Check environment variables are in .zprofile, not .zshrc
  def check_env_var_locations(issues_found)
    zshrc = File.expand_path('~/.zshrc')
    zprofile = File.expand_path('~/.zprofile')

    tokens_to_check = %w[GITHUB_TOKEN CLOUDFLARE_API_TOKEN LEMONSQUEEZY_API_KEY]

    tokens_to_check.each do |token|
      in_zshrc = File.exist?(zshrc) && File.read(zshrc).include?(token)
      in_zprofile = File.exist?(zprofile) && File.read(zprofile).include?(token)

      if in_zshrc && !in_zprofile
        issues_found << "#{token} in .zshrc but not .zprofile (MCPs may not load it)"
      elsif in_zshrc && in_zprofile
        @warnings << "#{token} in both .zshrc and .zprofile (redundant, keep only .zprofile)"
      end
    end
  end

  # Check all CLAUDE.md files list all sister apps
  def check_sister_apps_lists(issues_found)
    all_apps = product_definitions.map { |product| product[:name] }

    validation_projects.each do |project|
      claude_md = File.join(sane_apps_root, project, 'CLAUDE.md')
      next unless File.exist?(claude_md)

      content = File.read(claude_md)
      next if private_local_claude_file?(content)

      # Find sister apps line
      match = content.match(/\*\*Sister apps:\*\*\s*(.+)$/) ||
              content.match(/\*\*Apps using this:\*\*\s*(.+)$/) ||
              content.match(/\*\*Used by:\*\*\s*(.+)$/)

      next unless match

      listed_apps = match[1].split(',').map(&:strip)
      project_name = project.split('/').last

      # Check what's missing (excluding the project itself)
      missing = all_apps.reject { |a| a == project_name || listed_apps.include?(a) }
      if missing.any?
        issues_found << "[#{project}] CLAUDE.md missing sister apps: #{missing.join(', ')}"
      end
    end
  end

  def sane_apps_root
    SANE_APPS_ROOT
  end

  def validation_projects
    PROJECTS
  end

  def private_local_claude_file?(content)
    content.include?('private to your local environment') ||
      content.include?('Public guidance lives in `CLAUDE_PUBLIC.md`')
  end

  def check_codex_skill_health(issues_found)
    skill_root = File.expand_path('~/.codex/skills')
    registry_path = File.expand_path('~/.codex/SKILLS_REGISTRY.md')
    return unless Dir.exist?(skill_root) || File.exist?(registry_path)

    local_skill_names = []

    if Dir.exist?(skill_root)
      Dir.children(skill_root).sort.each do |entry|
        next if entry.start_with?('.')

        skill_dir = File.join(skill_root, entry)
        next unless File.directory?(skill_dir)

        skill_file = File.join(skill_dir, 'SKILL.md')
        unless File.exist?(skill_file)
          @warnings << "Q0: [codex] skill directory missing SKILL.md: #{entry}"
          next
        end

        local_skill_names << entry

        if File.symlink?(skill_file)
          issues_found << "[codex] symlinked SKILL.md entrypoint: #{skill_file}"
        elsif !File.file?(skill_file)
          issues_found << "[codex] SKILL.md is not a regular file: #{skill_file}"
        elsif !File.readable?(skill_file)
          issues_found << "[codex] unreadable SKILL.md: #{skill_file}"
        end

        header = File.read(skill_file, 512)
        issues_found << "[codex] missing `name:` in #{skill_file}" unless header.match?(/^\s*name:\s*.+$/)
        issues_found << "[codex] missing `description:` in #{skill_file}" unless header.match?(/^\s*description:\s*.+$/)
      end
    end

    return unless File.exist?(registry_path)

    registry_content = File.read(registry_path)
    registry_skill_names = registry_content.scan(/^\|\s*`([^`]+)`\s*\|/).flatten.uniq.sort

    missing_from_registry = local_skill_names.sort - registry_skill_names
    registry_only = registry_skill_names - local_skill_names.sort

    if missing_from_registry.any?
      issues_found << "[codex] local skills missing from SKILLS_REGISTRY.md: #{missing_from_registry.join(', ')}"
    end

    if registry_only.any?
      @warnings << "Q0: [codex] SKILLS_REGISTRY.md entries missing local skill dirs: #{registry_only.join(', ')}"
    end
  end

  def check_github_workflow_policy(issues_found)
    workflow_policy_repositories.each do |repo_root|
      repo_label = repo_root.delete_prefix("#{sane_apps_root}/")
      github_dir = File.join(repo_root, '.github')
      workflow_dir = File.join(github_dir, 'workflows')
      dependabot_file = File.join(github_dir, 'dependabot.yml')

      if Dir.exist?(workflow_dir)
        Dir.glob(File.join(workflow_dir, '*.{yml,yaml}')).sort.each do |workflow_file|
          content = File.read(workflow_file)
          basename = File.basename(workflow_file)
          next if workflow_policy_exception?(repo_label, basename, :workflow, content)

          begin
            config = YAML.safe_load(content, permitted_classes: [], aliases: true) || {}
          rescue Psych::SyntaxError => e
            issues_found << "[#{repo_label}] #{File.basename(workflow_file)} has invalid workflow YAML (#{e.message})"
            next
          end

          triggers = workflow_trigger_keys(config)
          non_manual = triggers - MANUAL_WORKFLOW_TRIGGERS
          next if non_manual.empty?

          issues_found << "[#{repo_label}] #{basename} uses automatic GitHub triggers (#{non_manual.join(', ')}); default must stay manual workflow_dispatch unless the file documents #{WORKFLOW_POLICY_EXCEPTION_MARKER} <reason>"
        end
      end

      next unless File.exist?(dependabot_file)

      dependabot_content = File.read(dependabot_file)
      next if workflow_policy_exception?(repo_label, 'dependabot.yml', :dependabot, dependabot_content)

      issues_found << "[#{repo_label}] dependabot.yml enables automatic GitHub dependency PR automation; default must stay local-first unless the file documents #{WORKFLOW_POLICY_EXCEPTION_MARKER} <reason>"
    end
  end

  def workflow_policy_exception?(repo_label, file_name, type, content)
    if content.include?(WORKFLOW_POLICY_EXCEPTION_MARKER)
      @workflow_policy_exception_count += 1
      return true
    end

    reason = workflow_policy_exception_reason(repo_label, file_name, type)
    return false if reason.to_s.strip.empty?

    @workflow_policy_exception_count += 1
    true
  end

  def workflow_policy_exception_reason(repo_label, file_name, type)
    repo_config = github_workflow_exceptions.dig('repositories', repo_label)
    return nil unless repo_config.is_a?(Hash)

    if type == :dependabot
      entry = repo_config['dependabot']
    else
      entry = repo_config.dig('workflows', file_name)
    end

    entry.is_a?(Hash) ? entry['reason'] : entry
  end

  def github_workflow_exceptions
    @github_workflow_exceptions ||= begin
      if File.exist?(WORKFLOW_EXCEPTIONS_CONFIG_PATH)
        YAML.safe_load(File.read(WORKFLOW_EXCEPTIONS_CONFIG_PATH), permitted_classes: [], aliases: true) || {}
      else
        {}
      end
    rescue Psych::SyntaxError
      {}
    end
  end

  def workflow_policy_repositories
    GITHUB_POLICY_SEGMENTS.flat_map do |segment|
      root = File.join(sane_apps_root, segment)
      next [] unless Dir.exist?(root)

      Dir.children(root).sort.map { |child| File.join(root, child) }
    end.select do |repo_root|
      next false unless File.directory?(repo_root)

      File.directory?(File.join(repo_root, '.github'))
    end
  end

  def workflow_trigger_keys(config)
    on_config = config['on'] || config[:on] || config[true]
    case on_config
    when String
      [on_config]
    when Array
      on_config.map(&:to_s)
    when Hash
      on_config.keys.map(&:to_s)
    else
      []
    end
  end

  # Q1: Are blocks CORRECT?
  # If user constantly overrides/bypasses, blocks are wrong = product is broken
  def q1_block_accuracy
    correct = 0
    wrong = 0

    @data.each do |_, info|
      v = info[:state]['validation'] || {}
      correct += v['blocks_that_were_correct'].to_i
      wrong += v['blocks_that_were_wrong'].to_i
    end

    total = correct + wrong
    @metrics[:block_accuracy] = {
      correct: correct,
      wrong: wrong,
      total: total,
      accuracy: total > 0 ? ((correct.to_f / total) * 100).round(1) : nil,
      sample_size: total
    }

    if total < MIN_SAMPLES_FOR_SIGNIFICANCE
      @warnings << "Q1: Only #{total} block samples. Need #{MIN_SAMPLES_FOR_SIGNIFICANCE}+ for significance."
    elsif @metrics[:block_accuracy][:accuracy] && @metrics[:block_accuracy][:accuracy] < 80
      @issues << "Q1 FAIL: Block accuracy #{@metrics[:block_accuracy][:accuracy]}% - users override too often. Blocks are wrong."
    end
  end

  # Q2: Are doom loops being CAUGHT?
  # If breaker never trips but errors repeat, we're not catching anything
  def q2_doom_loop_prevention
    caught = 0
    missed = 0
    breaker_trips = 0
    repeat_errors = 0

    @data.each do |_, info|
      v = info[:state]['validation'] || {}
      caught += v['doom_loops_caught'].to_i
      missed += v['doom_loops_missed'].to_i

      cb = info[:state]['circuit_breaker'] || {}
      breaker_trips += 1 if cb['tripped']
      (cb['error_signatures'] || {}).each do |_, count|
        repeat_errors += 1 if count.to_i >= 3
      end
    end

    total = caught + missed
    @metrics[:doom_loop_prevention] = {
      caught: caught,
      missed: missed,
      catch_rate: total > 0 ? ((caught.to_f / total) * 100).round(1) : nil,
      breaker_trips: breaker_trips,
      repeat_error_patterns: repeat_errors
    }

    # Hard question: Do we have repeat errors but no breaker trips?
    if repeat_errors > 0 && breaker_trips == 0
      @issues << "Q2 FAIL: #{repeat_errors} repeat error patterns but 0 breaker trips. Doom loops NOT being caught."
    end

    if total >= MIN_SAMPLES_FOR_SIGNIFICANCE && @metrics[:doom_loop_prevention][:catch_rate].to_f < 70
      @issues << "Q2 FAIL: Only catching #{@metrics[:doom_loop_prevention][:catch_rate]}% of doom loops."
    end
  end

  # Q3: Is self-rating HONEST or rubber-stamping?
  # 90%+ scores at 8+ with low variance = lying to ourselves
  def q3_score_integrity
    all_scores = []
    @data.each do |_, info|
      scores = info[:state].dig('patterns', 'session_scores') || []
      all_scores.concat(scores)
    end

    # Also read from sop_ratings.csv (written by sanestop.rb) as canonical source
    # CSV is the durable record; state.json session_scores rotate (last 10 per project)
    csv_path = File.join(File.dirname(__FILE__), '..', 'outputs', 'sop_ratings.csv')
    if File.exist?(csv_path)
      csv_scores = []
      File.readlines(csv_path).drop(1).each do |line|
        # CSV format: date,sop_score,notes (notes may contain commas)
        parts = line.strip.split(',', 3)
        score = parts[1]&.to_i
        csv_scores << score if score && score > 0
      end
      # Prefer CSV when it has data (it's the persistent record)
      # State.json session_scores are per-project rolling windows
      all_scores = csv_scores if csv_scores.size > all_scores.size
    end

    if all_scores.empty?
      @metrics[:score_integrity] = { status: 'NO DATA' }
      return
    end

    distribution = tally_counts(all_scores).sort.to_h
    avg = (all_scores.sum.to_f / all_scores.size).round(2)
    std = std_dev(all_scores).round(2)
    high_count = all_scores.count { |s| s >= 8 }
    high_pct = (high_count.to_f / all_scores.size * 100).round(1)

    @metrics[:score_integrity] = {
      sample_size: all_scores.size,
      distribution: distribution,
      average: avg,
      std_dev: std,
      pct_8_or_higher: high_pct,
      statistically_significant: all_scores.size >= MIN_SAMPLES_FOR_SIGNIFICANCE
    }

    if all_scores.size < MIN_SAMPLES_FOR_SIGNIFICANCE
      @warnings << "Q3: Only #{all_scores.size} scores. Need #{MIN_SAMPLES_FOR_SIGNIFICANCE}+ for significance."
    else
      # HARD CHECKS
      # Process-health signal only: this should not block release readiness by itself.
      if high_pct >= 85
        @warnings << "Q3: #{high_pct}% scores are 8+. Possible score inflation."
      end
      if std < 0.8
        @warnings << "Q3: Std dev #{std} is low. Score variance may be unrealistic."
      end
      if avg >= 8.5 && std < 1.0
        @warnings << "Q3: Average #{avg} with std #{std} suggests scoring bias."
      end
    end
  end

  # Q4: Do sessions end with tests PASSING?
  # High scores but failing tests = scores are meaningless
  def q4_test_outcomes
    state_sessions = 0
    state_passing_sessions = 0

    @data.each do |_, info|
      v = info[:state]['validation'] || {}
      state_sessions += v['sessions_total'].to_i
      state_passing_sessions += v['sessions_with_tests_passing'].to_i
    end

    verify_metrics = verify_outcome_metrics
    session_quality = session_quality_metrics
    pass_rate = verify_metrics[:attempt_pass_rate]
    final_pass_rate = verify_metrics[:final_pass_rate]

    @metrics[:test_outcomes] = {
      total_sessions: state_sessions + verify_metrics[:attempt_total],
      sessions_tests_passing: state_passing_sessions + verify_metrics[:attempt_passes],
      pass_rate: pass_rate,
      state_sessions: state_sessions,
      state_passing_sessions: state_passing_sessions,
      process_metric_verify_attempts: verify_metrics[:attempt_total],
      process_metric_verify_passes: verify_metrics[:attempt_passes],
      verify_attempt_pass_rate: verify_metrics[:attempt_pass_rate],
      verify_zero_test_failures: verify_metrics[:zero_test_failures],
      day_project_final_verify_groups: verify_metrics[:final_total],
      day_project_final_verify_passes: verify_metrics[:final_passes],
      day_project_final_verify_pass_rate: verify_metrics[:final_pass_rate],
      session_quality: session_quality
    }

    if verify_metrics[:attempt_total] >= MIN_SAMPLES_FOR_SIGNIFICANCE
      if pass_rate && pass_rate < 80
        @warnings << "Q4: Only #{pass_rate}% verify attempts pass. Process has too much red/green churn."
      end

      if verify_metrics[:zero_test_failures].positive?
        @warnings << "Q4: #{verify_metrics[:zero_test_failures]} failed verify attempts recorded zero tests; prioritize build-start/environment failure prevention."
      end

      if verify_metrics[:final_total] >= 10 && final_pass_rate && final_pass_rate < 90
        @warnings << "Q4: Only #{final_pass_rate}% day/project final verify groups finish green."
      end

      # Cross-check: High scores but low pass rate = scores are BS
      avg_score = @metrics.dig(:score_integrity, :average)
      if avg_score && avg_score >= 8 && pass_rate && pass_rate < 70
        @warnings << "Q4: Average SOP score #{avg_score} but verify-attempt pass rate #{pass_rate}%. Scores don't reflect verify churn."
      end
    else
      @warnings << "Q4: Only #{verify_metrics[:attempt_total]} verify attempts tracked. Need #{MIN_SAMPLES_FOR_SIGNIFICANCE}+."
    end

    if session_quality[:sample_size].positive?
      if session_quality[:clean_green_rate] && session_quality[:clean_green_rate] < 70
        @warnings << "Q4: Only #{session_quality[:clean_green_rate]}% session_end metrics were clean green. Recovered sessions are allowed but should not look like flawless SOP."
      end

      if session_quality[:unrecovered_failures].positive?
        @issues << "Q4 FAIL: #{session_quality[:unrecovered_failures]} session_end metrics finished without successful verification."
      end
    end
  end

  def verify_outcome_metrics
    verify_events = process_metric_events(type: 'verify').sort_by { |event| event['timestamp'].to_s }
    attempt_total = verify_events.length
    attempt_passes = verify_events.count { |event| event['success'] == true }
    attempt_pass_rate = attempt_total.positive? ? ((attempt_passes.to_f / attempt_total) * 100).round(1) : nil
    zero_test_failures = verify_events.count do |event|
      event['success'] != true && event['tests_run'].to_i.zero?
    end

    grouped = {}
    verify_events.each do |event|
      day = event['timestamp'].to_s[0, 10]
      key = [day, event['project'].to_s]
      grouped[key] ||= []
      grouped[key] << event
    end

    final_events = grouped.values.map { |events| events.max_by { |event| event['timestamp'].to_s } }
    final_total = final_events.length
    final_passes = final_events.count { |event| event['success'] == true }
    final_pass_rate = final_total.positive? ? ((final_passes.to_f / final_total) * 100).round(1) : nil

    {
      attempt_total: attempt_total,
      attempt_passes: attempt_passes,
      attempt_pass_rate: attempt_pass_rate,
      zero_test_failures: zero_test_failures,
      final_total: final_total,
      final_passes: final_passes,
      final_pass_rate: final_pass_rate
    }
  end

  def session_quality_metrics
    session_events = process_metric_events(type: 'session_end').sort_by { |event| event['timestamp'].to_s }
    total = session_events.length
    clean_green = session_events.count do |event|
      event['success'] == true && event['verify_failures'].to_i.zero?
    end
    recovered_green = session_events.count do |event|
      event['success'] == true && event['verify_failures'].to_i.positive?
    end
    unrecovered = session_events.count do |event|
      event['success'] != true && event['edits'].to_i.positive?
    end
    with_edits = session_events.count { |event| event['edits'].to_i.positive? }
    avg_score = if total.positive?
      scores = session_events.map { |event| event['sop_score'].to_f }.reject(&:zero?)
      scores.empty? ? nil : (scores.sum / scores.length).round(2)
    end

    {
      sample_size: total,
      sessions_with_edits: with_edits,
      clean_green: clean_green,
      recovered_green: recovered_green,
      unrecovered_failures: unrecovered,
      clean_green_rate: total.positive? ? ((clean_green.to_f / total) * 100).round(1) : nil,
      recovered_green_rate: total.positive? ? ((recovered_green.to_f / total) * 100).round(1) : nil,
      average_sop_score: avg_score
    }
  end

  # Q5: Is the TREND improving?
  # Loads historical snapshots and checks if we're getting better
  def q5_trend_analysis
    snapshots = load_historical_snapshots
    if snapshots.size < 5
      @metrics[:trend] = { status: 'INSUFFICIENT HISTORY', snapshots: snapshots.size }
      @warnings << "Q5: Only #{snapshots.size} historical snapshots. Need 5+ for trend analysis."
      return
    end

    # Compare first half to second half
    mid = snapshots.size / 2
    first_half = snapshots[0...mid]
    second_half = snapshots[mid..]

    first_issues = first_half.sum { |s| (s['issues'] || []).size }
    second_issues = second_half.sum { |s| (s['issues'] || []).size }

    first_score = first_half.map { |s| s.dig('metrics', 'productivity_score', 'percentage') }.compact
    second_score = second_half.map { |s| s.dig('metrics', 'productivity_score', 'percentage') }.compact

    @metrics[:trend] = {
      snapshots_analyzed: snapshots.size,
      first_half_avg_issues: first_half.any? ? (first_issues.to_f / first_half.size).round(1) : nil,
      second_half_avg_issues: second_half.any? ? (second_issues.to_f / second_half.size).round(1) : nil,
      first_half_avg_score: first_score.any? ? (first_score.sum.to_f / first_score.size).round(1) : nil,
      second_half_avg_score: second_score.any? ? (second_score.sum.to_f / second_score.size).round(1) : nil
    }

    # TREND CHECK: Are we getting worse?
    if @metrics[:trend][:first_half_avg_score] && @metrics[:trend][:second_half_avg_score]
      if @metrics[:trend][:second_half_avg_score] < @metrics[:trend][:first_half_avg_score] - 5
        @issues << "Q5 FAIL: Score trending DOWN (#{@metrics[:trend][:first_half_avg_score]} → #{@metrics[:trend][:second_half_avg_score]})"
      end
    end
  end

  def load_historical_snapshots
    return [] unless Dir.exist?(REPORT_DIR)

    Dir.glob(File.join(REPORT_DIR, '*.json')).sort.map do |f|
      JSON.parse(File.read(f)) rescue nil
    end.compact
  end

  def q12_red_noise_budget
    snapshots = load_historical_snapshots
    current = (@issues + @warnings).uniq
    first_seen = {}

    snapshots.each do |snapshot|
      date = snapshot['generated_at'].to_s[0, 10]
      next if date.empty?

      Array(snapshot['issues']).each { |finding| first_seen[finding] ||= date }
      Array(snapshot['warnings']).each { |finding| first_seen[finding] ||= date }
    end

    stale = current.map do |finding|
      seen_on = first_seen[finding]
      next unless seen_on

      age_days = (Date.today - Date.parse(seen_on)).to_i
      next if age_days < RED_NOISE_BUDGET_DAYS

      { finding: finding, first_seen: seen_on, age_days: age_days, action: finding_action(finding) }
    rescue ArgumentError
      nil
    end.compact

    @metrics[:red_noise_budget] = {
      budget_days: RED_NOISE_BUDGET_DAYS,
      stale_count: stale.length,
      details: stale.first(20)
    }

    return if stale.empty?

    @warnings << "Q12 RED NOISE: #{stale.length} findings have stayed red for #{RED_NOISE_BUDGET_DAYS}+ days; fix, explicitly accept, or downgrade them."
  end

  # ==========================================================================
  # Q6-Q10: RELEASE PIPELINE & CUSTOMER-FACING CHECKS
  # These catch the "shipped broken product" class of failures
  # ==========================================================================

  # Q6: RELEASE INTEGRITY
  # Can customers actually download our releases?
  # This would have caught the SaneBar 404 disaster
  def q6_release_integrity
    issues_found = []
    warnings_found = []

    released_product_definitions.each do |product|
      next unless product[:project_exists]

      app_name = product[:name]
      site_host = product[:domain]
      live_appcast = fetch_live_appcast_snapshot(site_host)
      if live_appcast
        check_live_appcast_snapshot(live_appcast, app_name, issues_found, warnings_found)
      else
        warnings_found << "[#{app_name}] No live appcast found at https://#{site_host}/appcast.xml"
      end

      # Check GitHub releases are absent (forbidden for distribution)
      check_github_releases(product, issues_found, warnings_found)
    end

    @metrics[:release_integrity] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q6 RELEASE: #{i}" }
    warnings_found.each { |w| @warnings << "Q6 RELEASE: #{w}" }
  end

  def check_live_appcast_snapshot(snapshot, app_name, issues, warnings)
    content = snapshot[:body].to_s

    # Verify it's valid XML first
    unless content.include?('<rss') || content.include?('<item')
      issues << "[#{app_name}] appcast.xml is not valid XML"
      return
    end

    latest_item = snapshot[:latest_item].to_s
    latest_url = snapshot[:enclosure_url].to_s
    informational_entries_missing_links = Array(snapshot[:informational_entries_missing_links])
    informational_constraint_version_mismatches = Array(snapshot[:informational_constraint_version_mismatches])

    if latest_url.nil? || latest_url.empty?
      warnings << "[#{app_name}] appcast.xml has no enclosure URL in latest item"
      return
    end

    unless informational_entries_missing_links.empty?
      issues << "[#{app_name}] Informational appcast entries are missing item <link>: #{informational_entries_missing_links.join(', ')}"
    end
    unless informational_constraint_version_mismatches.empty?
      issues << "[#{app_name}] Informational appcast entries compare against display versions instead of CFBundleVersion: #{informational_constraint_version_mismatches.join(', ')}"
    end

    status = check_url_status(latest_url, follow_redirects: true)
    unless %w[200 301 302].include?(status)
      issues << "[#{app_name}] Latest release URL returns #{status}: #{latest_url}"
    end

    # Check Sparkle signatures exist
    unless snapshot[:has_signature]
      warnings << "[#{app_name}] appcast.xml missing Sparkle signatures"
    end

    # Check minimumSystemVersion on latest entry isn't blocking users
    latest_min_version = snapshot[:minimum_system_version].to_s
    unless latest_min_version.empty?
      major = latest_min_version.to_f.floor
      if major > 14  # macOS 14 is Sonoma (2023)
        warnings << "[#{app_name}] Latest release requires macOS #{latest_min_version} (excludes Sonoma users)"
      end
    end
  end

  def check_github_releases(product, issues, warnings)
    # Check if GitHub CLI is available
    return unless system('which gh > /dev/null 2>&1')

    safe_repo = product[:github_repo].to_s.empty? ? "sane-apps/#{product[:name]}" : product[:github_repo]
    result = `gh release list --repo #{Shellwords.shellescape(safe_repo)} --limit 1 2>&1`
    has_releases = result && !result.include?('no releases found') && !result.include?('not found') && !result.strip.empty?

    return unless has_releases

    if product[:license_gated]
      # Gated app — GitHub releases are fine, just note it
      # (no issue, no warning — this is expected)
    else
      issues << "[#{product[:name]}] GitHub release exists (FORBIDDEN — no license gating; distribution must use Cloudflare R2/dist only)"
    end
  end

  # Q7: WEBSITE/DISTRIBUTION HEALTH
  # Can customers find and download our apps?
  def q7_website_distribution
    issues_found = []
    warnings_found = []

    # Check main domains
    domains = [{ url: 'https://saneapps.com', name: 'Main site' }]
    domains.concat(
      product_definitions.map do |product|
        next if product[:domain].to_s.empty?

        { url: "https://#{product[:domain]}", name: "#{product[:name]} site" }
      end.compact
    )
    domains = domains.uniq { |domain| domain[:url] }

    domains.each do |domain|
      status = check_url_status(domain[:url])
      case status
      when '200', '301', '302'
        # OK
      when 'timeout', 'error'
        issues_found << "#{domain[:name]} (#{domain[:url]}) unreachable"
      when '404'
        warnings_found << "#{domain[:name]} (#{domain[:url]}) returns 404"
      when '5xx'
        issues_found << "#{domain[:name]} (#{domain[:url]}) server error"
      else
        warnings_found << "#{domain[:name]} (#{domain[:url]}) returns #{status}"
      end
    end

    # Check SSL certificates (via curl)
    domains.each do |domain|
      ssl_check = `curl -sI --connect-timeout 5 "#{domain[:url]}" 2>&1`
      if ssl_check.include?('SSL certificate problem')
        issues_found << "#{domain[:name]} SSL certificate error"
      end
    end

    # Check REVENUE-CRITICAL checkout links (from products.yml config)
    config = load_product_config
    store_base = config[:checkout_base]
    checkout_links = config[:products].map do |_slug, prod|
      next unless prod['checkout_uuid']
      { url: "#{store_base}/#{prod['checkout_uuid']}", name: "#{prod['name']} checkout" }
    end.compact
    checkout_links << { url: config[:store_base], name: 'LemonSqueezy store' } unless config[:store_base].to_s.empty?
    checkout_links.each do |link|
      status = check_url_status(link[:url], follow_redirects: true)
      case status
      when '200', '301', '302'
        # OK
      else
        issues_found << "REVENUE CRITICAL: #{link[:name]} (#{link[:url]}) returns #{status}"
      end
    end

    # Scan HTML files for wrong checkout domains (e.g. old store slugs)
    website_dirs = product_definitions.flat_map do |product|
      [
        File.join(product[:project_path], 'docs'),
        File.join(product[:project_path], 'website')
      ]
    end.uniq
    website_dirs.each do |full_dir|
      next unless Dir.exist?(full_dir)
      Dir.glob(File.join(full_dir, '**/*.html')).each do |html_file|
        content = File.read(html_file)
        content.scan(%r{https?://([a-z]+)\.lemonsqueezy\.com/checkout/}).each do |match|
          unless match[0] == 'saneapps'
            rel = html_file.sub("#{SANE_APPS_ROOT}/", '')
            issues_found << "REVENUE CRITICAL: Wrong checkout domain '#{match[0]}.lemonsqueezy.com' in #{rel}"
          end
        end
      end
    end

    # Check Sparkle appcast feeds (CRITICAL - no updates if broken)
    appcast_urls = released_product_definitions.map do |product|
      next if product[:domain].to_s.empty?

      { url: "https://#{product[:domain]}/appcast.xml", name: "#{product[:name]} appcast" }
    end.compact
    appcast_urls.each do |appcast|
      status = check_url_status(appcast[:url])
      case status
      when '200', '301', '302'
        # OK - also verify it's valid XML
        xml_content = `curl -s --connect-timeout 5 #{Shellwords.shellescape(appcast[:url])} 2>&1`
        unless xml_content.include?('<rss') || xml_content.include?('<feed')
          warnings_found << "#{appcast[:name]} doesn't appear to be valid XML"
        end
      else
        issues_found << "UPDATE CRITICAL: #{appcast[:name]} (#{appcast[:url]}) returns #{status} - users cannot get updates!"
      end
    end

    # Check distribution workers (Cloudflare R2 endpoints)
    dist_urls = released_product_definitions.map do |product|
      next if product[:dist_domain].to_s.empty?

      { url: "https://#{product[:dist_domain]}/", name: "#{product[:name]} dist worker" }
    end.compact
    dist_urls.each do |dist|
      status = check_url_status(dist[:url])
      case status
      when '200', '301', '302', '403', '404'
        # 403 and 404 are OK for root - workers respond to specific file paths
      else
        issues_found << "DOWNLOAD CRITICAL: #{dist[:name]} (#{dist[:url]}) returns #{status} - downloads fail!"
      end
    end

    @metrics[:website_distribution] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q7 WEBSITE: #{i}" }
    warnings_found.each { |w| @warnings << "Q7 WEBSITE: #{w}" }
  end

  def check_url_status(url, follow_redirects: false)
    escaped_url = Shellwords.shellescape(url)
    head_cmd = if follow_redirects
                 "curl -sI -L -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 #{escaped_url} 2>&1"
               else
                 "curl -sI -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 #{escaped_url} 2>&1"
               end
    get_cmd = if follow_redirects
                "curl -sL -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 #{escaped_url} 2>&1"
              else
                "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 #{escaped_url} 2>&1"
              end

    statuses = []
    errors = []

    2.times do
      head_result = `#{head_cmd}`.strip
      statuses << head_result
      if head_result.start_with?('5') || head_result == '000'
        # Some providers intermittently fail HEAD but succeed GET.
        get_result = `#{get_cmd}`.strip
        statuses << get_result
      end
    end

    statuses.each do |result|
      errors << result if result.include?('Connection timed out') || result.include?('Could not resolve') || result.include?('Operation timed out')
      errors << result if result.include?('curl:')
    end

    return 'timeout' if errors.any? { |e| e.include?('timed out') || e.include?('Could not resolve') }
    return 'error' if errors.any?

    http_codes = statuses.select { |s| s.match?(/^\d{3}$/) }
    return 'error' if http_codes.empty?
    return http_codes.find { |c| %w[200 301 302].include?(c) } if http_codes.any? { |c| %w[200 301 302].include?(c) }
    return '5xx' if http_codes.any? { |c| c.start_with?('5') }

    http_codes.first
  end

  # Q8: CODE SIGNING STATUS
  # Are our signing identities and notarization working?
  def q8_code_signing
    issues_found = []
    warnings_found = []

    # Check Developer ID signing identity exists
    identities = `security find-identity -v -p codesigning 2>/dev/null`
    unless identities.include?('Developer ID Application')
      issues_found << "No 'Developer ID Application' signing identity found"
    end

    # Check if signing identity is expired
    if identities.include?('CSSMERR_TP_CERT_EXPIRED')
      issues_found << "Code signing certificate is EXPIRED"
    end

    # Check notarytool keychain profile exists
    notary_check = `xcrun notarytool history --keychain-profile "notarytool" 2>&1`
    if notary_check.include?('Could not find credentials')
      issues_found << "Notarytool keychain profile 'notarytool' not found"
    elsif notary_check.include?('Error')
      warnings_found << "Notarytool profile may have issues: check manually"
    end

    # Check each app's recent build is signed
    product_definitions.each do |product|
      next unless product[:project_exists]

      project_path = product[:project_path]
      app_name = product[:name]
      checked_context_paths ||= []
      checked_context_paths << File.expand_path(project_path)

      # Find most recent .app in DerivedData or build folder
      app_bundle = find_recent_app_bundle(project_path, app_name)
      next unless app_bundle

      # Verify signature
      codesign_check = `codesign -v "#{app_bundle}" 2>&1`
      if codesign_check.include?('invalid signature') || codesign_check.include?('not signed')
        issues_found << "[#{app_name}] App bundle has invalid or missing signature"
      end

      # Check notarization on shipped DMGs only (DerivedData builds are never notarized)
      latest_dmg = Dir.glob(File.join(project_path, 'releases', '*.dmg')).max_by { |f| File.mtime(f) }
      if latest_dmg
        staple_check = `stapler validate "#{latest_dmg}" 2>&1`
        unless staple_check.include?('valid')
          warnings_found << "[#{app_name}] Released DMG may not be notarized (stapler check failed)"
        end
      end
    end

    @metrics[:code_signing] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q8 SIGNING: #{i}" }
    warnings_found.each { |w| @warnings << "Q8 SIGNING: #{w}" }
  end

  def find_recent_app_bundle(project_path, app_name)
    # Check releases folder first
    releases = Dir.glob(File.join(project_path, 'releases', '*.app')).select { |f| File.exist?(f) }
    return releases.max_by { |f| File.mtime(f) } if releases.any?

    # Check DerivedData Release builds only (Debug builds are never Developer ID signed)
    derived_data = File.expand_path('~/Library/Developer/Xcode/DerivedData')
    apps = Dir.glob(File.join(derived_data, "#{app_name}*/Build/Products/Release/#{app_name}.app")).select { |f| File.exist?(f) }
    return apps.max_by { |f| File.mtime(f) } if apps.any?

    nil
  end

  # Q9: SUPPORT INFRASTRUCTURE
  # Can customers reach us? Can we reach them?
  def q9_support_infrastructure
    issues_found = []
    warnings_found = []
    keychain_fallback_enabled = ENV.fetch('SANE_KEYCHAIN_FALLBACK', '1') == '1'
    keychain_fallback_enabled = false if ENV['SANE_NO_KEYCHAIN'] == '1'
    secret_for = lambda do |service, account, *env_names|
      env_names.each do |env_name|
        value = ENV[env_name]
        return value if value && !value.empty?
      end
      return '' unless keychain_fallback_enabled

      `security find-generic-password -s "#{service}" -a "#{account}" -w 2>/dev/null`.strip
    end

    # Check required credentials are available (env-first, optional keychain fallback)
    required_items = [
      { service: 'cloudflare', account: 'api_token', name: 'Cloudflare API', env: %w[CLOUDFLARE_API_TOKEN] },
      { service: 'resend', account: 'api_key', name: 'Resend Email API', env: %w[RESEND_API_KEY] },
      { service: 'lemonsqueezy', account: 'api_key', name: 'Lemon Squeezy API', env: %w[LEMONSQUEEZY_API_KEY] }
    ]

    required_items.each do |item|
      value = secret_for.call(item[:service], item[:account], *item[:env])
      issues_found << "#{item[:name]} key missing (env/keychain)" if value.nil? || value.empty?
    end

    # Check Resend API is working (if key exists)
    # Use Net::HTTP to avoid leaking API keys in shell process list
    resend_key = secret_for.call('resend', 'api_key', 'RESEND_API_KEY')
    if resend_key && !resend_key.empty?
      begin
        uri = URI("https://api.resend.com/emails")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{resend_key}"
        resp = http.request(req)
        case resp.code
        when '200'
          # OK
        when '401', '403'
          issues_found << "Resend API key invalid (HTTP #{resp.code})"
        else
          warnings_found << "Resend API may be down (HTTP #{resp.code})"
        end
      rescue StandardError => e
        warnings_found << "Resend API check failed: #{e.message}"
      end
    end

    # Check LemonSqueezy API is working (if key exists)
    ls_key = secret_for.call('lemonsqueezy', 'api_key', 'LEMONSQUEEZY_API_KEY')
    if ls_key && !ls_key.empty?
      begin
        uri = URI("https://api.lemonsqueezy.com/v1/products")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5
        http.read_timeout = 5
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer #{ls_key}"
        resp = http.request(req)
        case resp.code
        when '200'
          # OK
        when '401', '403'
          issues_found << "LemonSqueezy API key invalid (HTTP #{resp.code})"
        else
          warnings_found << "LemonSqueezy API may be down (HTTP #{resp.code})"
        end
      rescue StandardError => e
        warnings_found << "LemonSqueezy API check failed: #{e.message}"
      end
    end

    # Check knowledge graph exists (official Memory MCP)
    kg_path = File.expand_path('~/.claude/memory/knowledge-graph.jsonl')
    unless File.exist?(kg_path)
      warnings_found << "Knowledge graph missing at #{kg_path} (Memory MCP not seeded)"
    end

    @metrics[:support_infrastructure] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q9 SUPPORT: #{i}" }
    warnings_found.each { |w| @warnings << "Q9 SUPPORT: #{w}" }
  end

  # Q10: DOCUMENTATION CURRENCY
  # Do our docs match our releases?
  def q10_documentation_currency
    issues_found = []
    warnings_found = []

    product_definitions.each do |product|
      next unless product[:project_exists]

      project_path = product[:project_path]
      app_name = product[:name]

      # Get version from appcast (latest release version)
      appcast_version = get_appcast_version(project_path)

      # Get version from Info.plist or Package.swift
      bundle_version = get_bundle_version(project_path, app_name)

      # Check README mentions current version (skip if using dynamic GitHub release badge)
      readme = File.join(project_path, 'README.md')
      if File.exist?(readme)
        readme_content = File.read(readme)
        has_release_badge = readme_content.include?('shields.io/github/v/release')
        if appcast_version && !has_release_badge && !readme_content.include?(appcast_version)
          warnings_found << "[#{app_name}] README may not mention latest version #{appcast_version}"
        end
      end

      # Check CHANGELOG has latest version
      changelog_paths = [
        File.join(project_path, 'CHANGELOG.md'),
        File.join(project_path, 'docs', 'CHANGELOG.md')
      ]
      changelog = changelog_paths.find { |p| File.exist?(p) }
      if changelog && appcast_version
        changelog_content = File.read(changelog)
        unless changelog_content.include?(appcast_version)
          issues_found << "[#{app_name}] CHANGELOG missing version #{appcast_version}"
        end
      elsif !changelog
        warnings_found << "[#{app_name}] No CHANGELOG.md found"
      end

      # Check SESSION_HANDOFF.md isn't stale (> 7 days old)
      handoff = File.join(project_path, 'SESSION_HANDOFF.md')
      if File.exist?(handoff)
        age_days = (Time.now - File.mtime(handoff)) / 86400
        if age_days > 7
          warnings_found << "[#{app_name}] SESSION_HANDOFF.md is #{age_days.round} days old"
        end
      end
      check_context_file_sizes(project_path, app_name, issues_found, warnings_found)

      # Q10.6: 5-Doc Standard (CHANGELOG + SESSION_HANDOFF checked above)
      unless File.exist?(readme)
        issues_found << "[#{app_name}] Missing README.md (5-doc standard)"
      end

      development = File.join(project_path, 'DEVELOPMENT.md')
      unless File.exist?(development)
        warnings_found << "[#{app_name}] Missing DEVELOPMENT.md (5-doc standard)"
      end

      architecture = File.join(project_path, 'ARCHITECTURE.md')
      unless File.exist?(architecture)
        warnings_found << "[#{app_name}] Missing ARCHITECTURE.md (5-doc standard)"
      end

      # Q10.7: Internal Link Validation (project root .md files only)
      Dir.glob(File.join(project_path, '*.md')).each do |md_file|
        md_content = File.read(md_file)
        md_basename = File.basename(md_file)
        md_content.scan(/\[([^\]]*)\]\(([^)]+)\)/).each do |_text, link|
          next if link.start_with?('http', '#', 'mailto:')

          # Strip anchor fragments
          link_path = link.split('#').first
          next if link_path.nil? || link_path.empty?

          resolved = File.expand_path(link_path, project_path)
          unless File.exist?(resolved)
            warnings_found << "[#{app_name}] #{md_basename} has broken link: #{link_path}"
          end
        end
      end
    end

    checked_context_paths ||= []
    validation_projects.each do |relative_project|
      project_path = File.join(sane_apps_root, relative_project)
      expanded_path = File.expand_path(project_path)
      next unless Dir.exist?(expanded_path)
      next if checked_context_paths.include?(expanded_path)

      check_context_file_sizes(expanded_path, File.basename(expanded_path), issues_found, warnings_found)
    end

    @metrics[:documentation_currency] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q10 DOCS: #{i}" }
    warnings_found.each { |w| @warnings << "Q10 DOCS: #{w}" }
  end

  def check_context_file_sizes(project_path, app_name, issues_found, warnings_found)
    agents_path = File.join(project_path, 'AGENTS.md')
    if File.exist?(agents_path)
      bytes = File.size(agents_path)
      lines = line_count(agents_path)
      if bytes >= AGENTS_HARD_BYTES
        issues_found << "[#{app_name}] AGENTS.md is #{bytes} bytes (Codex default instruction cap: #{AGENTS_HARD_BYTES}); split or shrink active guidance"
      elsif bytes >= AGENTS_WARNING_BYTES || lines > AGENTS_WARNING_LINES
        warnings_found << "[#{app_name}] AGENTS.md is #{bytes} bytes / #{lines} lines; nearing Codex instruction-context limits"
      end
    end

    research_path = File.join(project_path, '.claude', 'research.md')
    if File.exist?(research_path)
      lines = line_count(research_path)
      if lines > RESEARCH_CACHE_MAX_LINES
        issues_found << "[#{app_name}] .claude/research.md is #{lines} lines (active cache cap: #{RESEARCH_CACHE_MAX_LINES}); promote stale verified findings before appending more research"
      end
    end

    handoff_path = File.join(project_path, 'SESSION_HANDOFF.md')
    if File.exist?(handoff_path)
      lines = line_count(handoff_path)
      if lines > HANDOFF_MAX_LINES
        issues_found << "[#{app_name}] SESSION_HANDOFF.md is #{lines} lines (active handoff cap: #{HANDOFF_MAX_LINES}); compact older sessions into durable docs or memory"
      end
    end
  end

  def line_count(path)
    File.foreach(path).count
  end

  # Q11: CROSS-CHANNEL VERSION CONSISTENCY
  # Are appcast, website, webhook, and Homebrew all serving the same version?
  # This catches the SaneBar 2.1.13-2.1.18 drift where 6 releases shipped without
  # updating the email webhook PRODUCT_CONFIG.
  def q11_cross_channel_version_consistency
    issues_found = []
    hosted_file_actions = []
    warnings_found = []
    version_table = []

    webhook_snapshot = fetch_live_email_worker_snapshot
    warnings_found << 'Live email worker snapshot unavailable; webhook drift check skipped where data is missing' if webhook_snapshot.nil?
    lemonsqueezy_snapshot = fetch_live_lemonsqueezy_hosted_versions
    warnings_found << 'Live Lemon Squeezy hosted file snapshot unavailable; hosted-file drift check skipped where data is missing' if lemonsqueezy_snapshot.nil?

    released_product_definitions.each do |product|
      next unless product[:project_exists]

      app_name = product[:name]
      site_host = product[:domain]

      versions = {}

      # 1. Appcast version (live fetch — customer-facing source of truth)
      appcast_ver = nil
      appcast_body = fetch_url_text("https://#{site_host}/appcast.xml")
      unless appcast_body.empty?
        appcast_match = appcast_body.match(/sparkle:shortVersionString="([^"]+)"/)
        appcast_ver = appcast_match[1] if appcast_match
        if appcast_ver.nil?
          appcast_match = appcast_body.match(/sparkle:shortVersionString[=>]+"?([^"<\s]+)/)
          appcast_ver = appcast_match[1] if appcast_match
        end
      end
      versions[:appcast] = appcast_ver || '—'

      # 2. Website download link version (live HTML)
      website_ver = nil
      html_content = fetch_url_text("https://#{site_host}")
      unless html_content.empty?
        match = html_content.match(/#{Regexp.escape(app_name)}-(\d+\.\d+(?:\.\d+)?)\.(zip|dmg)/)
        website_ver = match[1] if match
      end
      versions[:website] = website_ver || '—'

      # 3. Webhook PRODUCT_CONFIG version (live worker snapshot)
      webhook_ver = nil
      if webhook_snapshot.is_a?(Hash)
        webhook_product = webhook_snapshot.dig('products', app_name)
        webhook_ver = webhook_product['version'] if webhook_product.is_a?(Hash)
      end
      versions[:webhook] = webhook_ver || '—'

      # 4. Homebrew cask version (GitHub content API, raw fallback only if needed)
      cask_ver = nil
      cask_body = fetch_homebrew_cask_body(product[:slug])
      unless cask_body.empty?
        match = cask_body.match(/version\s+"([^"]+)"/)
        cask_ver = match[1] if match
      end
      versions[:cask] = cask_ver || '—'

      # 5. Lemon Squeezy hosted file version
      lemonsqueezy_ver = nil
      if lemonsqueezy_snapshot.is_a?(Hash)
        hosted_file = lemonsqueezy_snapshot[app_name]
        lemonsqueezy_ver = hosted_file['version'] if hosted_file.is_a?(Hash)
      end
      versions[:lemonsqueezy] = lemonsqueezy_ver || '—'

      version_table << { app: app_name, versions: versions }

      # Compare all present versions against appcast (source of truth)
      next unless appcast_ver

      %i[website webhook cask lemonsqueezy].each do |channel|
        chan_ver = versions[channel]
        next if chan_ver == '—'

        if chan_ver != appcast_ver
          if channel == :lemonsqueezy
            hosted_file = lemonsqueezy_snapshot[app_name]
            hosted_file_actions << build_lemonsqueezy_hosted_file_action(app_name, chan_ver, appcast_ver, hosted_file)
          else
            label = {
              website: 'Website download link',
              webhook: 'Email webhook PRODUCT_CONFIG',
              cask: 'Homebrew cask'
            }[channel]
            issues_found << "[#{app_name}] VERSION DRIFT: #{label} has v#{chan_ver} but appcast is v#{appcast_ver}"
          end
        end
      end
    end

    @metrics[:cross_channel_consistency] = {
      issues: issues_found.size + hosted_file_actions.size,
      canonical_issues: issues_found.size,
      hosted_file_actions: hosted_file_actions.size,
      warnings: warnings_found.size,
      table: version_table,
      canonical_details: issues_found,
      hosted_file_details: hosted_file_actions,
      details: issues_found + hosted_file_actions + warnings_found
    }

    issues_found.each { |i| @issues << "Q11 DRIFT: #{i}" }
    hosted_file_actions.each { |i| @warnings << "Q11 HOSTED FILE ACTION: #{i}" }
    warnings_found.each { |w| @warnings << "Q11 DRIFT: #{w}" }
  end

  def fetch_url_text(url, headers: {})
    uri = URI(url)
    request = Net::HTTP::Get.new(uri)
    headers.each { |key, value| request[key] = value }

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 5
    http.read_timeout = 15

    response = http.request(request)
    return '' unless response.is_a?(Net::HTTPSuccess)

    response.body.to_s
  rescue StandardError
    ''
  end

  def resolve_secret_value(service, account, *env_names)
    env_names.flatten.each do |env_name|
      value = ENV[env_name].to_s.strip
      return value unless value.empty?
    end

    keychain_fallback_enabled = ENV.fetch('SANE_KEYCHAIN_FALLBACK', '1') == '1'
    keychain_fallback_enabled = false if ENV['SANE_NO_KEYCHAIN'] == '1'
    return '' unless keychain_fallback_enabled

    `security find-generic-password -s "#{service}" -a "#{account}" -w 2>/dev/null`.strip
  end

  def fetch_live_email_worker_snapshot
    api_key = resolve_secret_value('sane-email-automation', 'api_key', 'SANE_EMAIL_API_KEY', 'EMAIL_API_KEY')
    return nil if api_key.empty?

    body = fetch_url_text(
      'https://email-api.saneapps.com/api/debug/download-config',
      headers: { 'Authorization' => "Bearer #{api_key}" }
    )
    return nil if body.empty?

    JSON.parse(body)
  rescue StandardError
    nil
  end

  def fetch_homebrew_cask_body(cask_name)
    github_api_path = "repos/sane-apps/homebrew-tap/contents/Casks/#{cask_name}.rb?ref=main"
    gh_content = `gh api #{Shellwords.shellescape(github_api_path)} --jq .content 2>/dev/null | tr -d '\\n' | base64 -d 2>/dev/null`
    return gh_content if $?.success? && !gh_content.to_s.empty?

    raw_url = "https://raw.githubusercontent.com/sane-apps/homebrew-tap/main/Casks/#{cask_name}.rb"
    raw_content = `curl -fsSL --connect-timeout 5 --max-time 10 #{Shellwords.shellescape(raw_url)} 2>/dev/null`
    return raw_content if $?.success? && !raw_content.to_s.empty?

    ''
  end

  def fetch_live_lemonsqueezy_hosted_versions
    api_key = resolve_secret_value('lemonsqueezy', 'api_key', 'LEMONSQUEEZY_API_KEY')
    return nil if api_key.empty?

    products = fetch_lemonsqueezy_collection('/v1/products?page[size]=100', api_key)
    variants = fetch_lemonsqueezy_collection('/v1/variants?page[size]=100', api_key)
    return nil unless products.is_a?(Array) && variants.is_a?(Array)

    released_product_definitions.each_with_object({}) do |product, snapshot|
      product_record = products.find do |record|
        name = record.dig('attributes', 'name').to_s.strip
        name == product[:name] || name.start_with?("#{product[:name]}:")
      end
      next unless product_record

      variant_record = variants.find do |record|
        record.dig('attributes', 'product_id').to_s == product_record['id'].to_s
      end
      next unless variant_record

      files = fetch_lemonsqueezy_collection("/v1/variants/#{variant_record['id']}/files?page[size]=100", api_key)
      next unless files.is_a?(Array)

      published_file = files.find { |record| record.dig('attributes', 'status').to_s == 'published' } || files.first
      next unless published_file

      filename = published_file.dig('attributes', 'name').to_s.strip
      version = extract_release_version_from_filename(filename)
      next if filename.empty? && version.nil?

      snapshot[product[:name]] = {
        'filename' => filename,
        'version' => version,
        'product_id' => product_record['id'].to_s,
        'product_slug' => product_record.dig('attributes', 'slug').to_s,
        'variant_id' => variant_record['id'].to_s
      }
    end
  rescue StandardError
    nil
  end

  def build_lemonsqueezy_hosted_file_action(app_name, current_version, expected_version, hosted_file)
    hosted_file ||= {}
    filename = hosted_file['filename'].to_s.strip
    product_id = hosted_file['product_id'].to_s.strip
    product_slug = hosted_file['product_slug'].to_s.strip
    variant_id = hosted_file['variant_id'].to_s.strip

    refs = []
    refs << "product_id=#{product_id}" unless product_id.empty?
    refs << "product_slug=#{product_slug}" unless product_slug.empty?
    refs << "variant_id=#{variant_id}" unless variant_id.empty?
    refs_text = refs.empty? ? '' : " (#{refs.join(', ')})"
    filename_text = filename.empty? ? '' : " file #{filename}"

    "[#{app_name}] Lemon Squeezy hosted#{filename_text} has v#{current_version} but appcast is v#{expected_version}; replace the published hosted file#{refs_text}"
  end

  def fetch_lemonsqueezy_collection(path, api_key)
    body = fetch_url_text(
      "https://api.lemonsqueezy.com#{path}",
      headers: {
        'Authorization' => "Bearer #{api_key}",
        'Accept' => 'application/vnd.api+json'
      }
    )
    return nil if body.empty?

    parsed = JSON.parse(body)
    parsed['data']
  rescue StandardError
    nil
  end

  def extract_release_version_from_filename(filename)
    match = filename.to_s.match(/-(\d+\.\d+(?:\.\d+)?)\.(zip|dmg)\z/i)
    match && match[1]
  end

  def website_domain_for_project(project_path, app_name)
    saneprocess_path = File.join(project_path, '.saneprocess')
    if File.exist?(saneprocess_path)
      config = YAML.safe_load(File.read(saneprocess_path), permitted_classes: []) || {}
      domain = config['website_domain'].to_s.strip
      return domain unless domain.empty?
    end

    "#{app_name.downcase}.com"
  rescue StandardError
    "#{app_name.downcase}.com"
  end

  def fetch_live_appcast_snapshot(site_host)
    return nil if site_host.to_s.strip.empty?

    appcast_url = "https://#{site_host}/appcast.xml"
    body = fetch_url_text(appcast_url)
    return nil if body.empty?

    latest_item = body.scan(/<item\b.*?<\/item>/m).first || body
    enclosure_url = latest_item[/<enclosure[^>]*\burl="([^"]+)"/m, 1].to_s
    version = latest_item[/sparkle:shortVersionString="([^"]+)"/, 1] ||
              latest_item[/<sparkle:shortVersionString>\s*([^<]+)\s*<\/sparkle:shortVersionString>/m, 1]
    build = latest_item[/sparkle:version="([^"]+)"/, 1] ||
            latest_item[/<sparkle:version>\s*([^<]+)\s*<\/sparkle:version>/m, 1]
    minimum_system_version = latest_item[/minimumSystemVersion>([^<]+)</, 1] ||
                             latest_item[/sparkle:minimumSystemVersion="([^"]+)"/, 1]
    has_signature = latest_item.include?('sparkle:edSignature') || latest_item.include?('sparkle:dsaSignature')
    informational_entries_missing_links = body.scan(/<item\b.*?<\/item>/m).each_with_object([]) do |item, acc|
      next unless item.include?('<sparkle:informationalUpdate')
      next unless item.match?(/<enclosure\b/m)

      item_link = item[/<link>\s*([^<]+)\s*<\/link>/m, 1].to_s.strip
      next unless item_link.empty?

      version = item[/sparkle:shortVersionString="([^"]+)"/, 1] ||
                item[/<sparkle:shortVersionString>\s*([^<]+)\s*<\/sparkle:shortVersionString>/m, 1] ||
                item[/<title>\s*([^<]+)\s*<\/title>/m, 1]
      acc << (version.to_s.strip.empty? ? '<unknown version>' : version.to_s.strip)
    end
    informational_constraint_version_mismatches = body.scan(/<item\b.*?<\/item>/m).each_with_object([]) do |item, acc|
      next unless item.include?('<sparkle:informationalUpdate')

      item_build = item[/sparkle:version="([^"]+)"/, 1] ||
                   item[/<sparkle:version>\s*([^<]+)\s*<\/sparkle:version>/m, 1]
      next unless item_build.to_s.match?(/\A\d+\z/)

      constraints = item.scan(/<sparkle:(?:version|belowVersion)>\s*([^<\s]+)\s*<\/sparkle:(?:version|belowVersion)>/m).flatten
      next if constraints.empty?
      next unless constraints.any? { |constraint| constraint.include?('.') }

      version = item[/sparkle:shortVersionString="([^"]+)"/, 1] ||
                item[/<sparkle:shortVersionString>\s*([^<]+)\s*<\/sparkle:shortVersionString>/m, 1] ||
                item[/<title>\s*([^<]+)\s*<\/title>/m, 1]
      acc << (version.to_s.strip.empty? ? '<unknown version>' : version.to_s.strip)
    end

    {
      appcast_url: appcast_url,
      body: body,
      latest_item: latest_item,
      enclosure_url: enclosure_url,
      version: version.to_s.strip,
      build: build.to_s.strip,
      minimum_system_version: minimum_system_version.to_s.strip,
      has_signature: has_signature,
      informational_entries_missing_links: informational_entries_missing_links,
      informational_constraint_version_mismatches: informational_constraint_version_mismatches
    }
  rescue StandardError
    nil
  end

  def inspect_live_release_artifact(url)
    return { artifact_name: nil, signed: false, notarized: false, available: false } if url.to_s.strip.empty?

    uri = URI(url)
    artifact_name = File.basename(uri.path.to_s)

    Dir.mktmpdir('validation_live_release_') do |dir|
      local_path = File.join(dir, artifact_name.empty? ? 'release_artifact' : artifact_name)
      _out, status = Open3.capture2e('curl', '-fsSL', url, '-o', local_path)
      return { artifact_name: artifact_name, signed: false, notarized: false, available: false } unless status.success? && File.exist?(local_path)

      if local_path.end_with?('.zip')
        signed, notarized = zip_contains_signed_notarized_app?(local_path)
        return { artifact_name: artifact_name, signed: signed, notarized: notarized, available: true }
      end

      if local_path.end_with?('.dmg')
        codesign_output = `codesign -dv "#{local_path}" 2>&1`
        stapler_result = `xcrun stapler validate "#{local_path}" 2>&1`
        signed = codesign_output.include?('Developer ID') || codesign_output.include?('TeamIdentifier=')
        notarized = stapler_result.include?('validated')
        return { artifact_name: artifact_name, signed: signed, notarized: notarized, available: true }
      end

      { artifact_name: artifact_name, signed: false, notarized: false, available: true }
    end
  rescue StandardError
    { artifact_name: nil, signed: false, notarized: false, available: false }
  end

  def get_appcast_version(project_path)
    appcast_paths = [
      File.join(project_path, 'docs', 'appcast.xml'),
      File.join(project_path, 'appcast.xml')
    ]
    appcast = appcast_paths.find { |p| File.exist?(p) }
    return nil unless appcast

    content = File.read(appcast)
    # Extract latest marketing version (shortVersionString is what CHANGELOGs use)
    match = content.match(/sparkle:shortVersionString="([^"]+)"/)
    return match[1] if match

    # Fallback to sparkle:version (build number) if no shortVersionString
    match = content.match(/sparkle:version="([^"]+)"/)
    match ? match[1] : nil
  end

  def get_bundle_version(project_path, app_name)
    # Try Info.plist in various locations
    plist_paths = [
      File.join(project_path, app_name, 'Info.plist'),
      File.join(project_path, 'Info.plist'),
      File.join(project_path, app_name, 'Resources', 'Info.plist')
    ]

    plist = plist_paths.find { |p| File.exist?(p) }
    return nil unless plist

    # Extract CFBundleShortVersionString
    content = File.read(plist)
    match = content.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)
    match ? match[1] : nil
  end

  # ==========================================================================
  # FINAL VERDICT
  # ==========================================================================
  def calculate_final_verdict
    critical_fails = @issues.count { |i| i.include?('FAIL') }
    data_gaps = @warnings.size
    finding_summary = finding_summary_metrics

    # Sufficient data?
    has_data = @data.size >= 3

    # Q6 RELEASE issues are CRITICAL - customers can't update!
    release_issues = (@metrics[:release_integrity] || {})[:issues].to_i
    # Q7 WEBSITE issues are CRITICAL - customers can't download!
    website_issues = (@metrics[:website_distribution] || {})[:issues].to_i
    # Q8 SIGNING issues are CRITICAL - app won't run!
    signing_issues = (@metrics[:code_signing] || {})[:issues].to_i
    # Q11 canonical drift is CRITICAL. Hosted-file drift is real, but it is a dashboard action,
    # not the same class of failure as a broken website, webhook, or appcast.
    canonical_drift_issues = (@metrics[:cross_channel_consistency] || {})[:canonical_issues].to_i
    hosted_file_actions = (@metrics[:cross_channel_consistency] || {})[:hosted_file_actions].to_i

    customer_facing_critical = release_issues + website_issues + signing_issues + canonical_drift_issues

    @metrics[:final] = {
      critical_failures: critical_fails,
      customer_facing_critical: customer_facing_critical,
      hosted_file_actions: hosted_file_actions,
      data_gaps: data_gaps,
      projects_with_data: @data.size,
      finding_summary: finding_summary
    }

    system_critical = finding_summary[:system_health][:critical].to_i
    app_critical = finding_summary[:app_readiness][:critical].to_i

    overall = if customer_facing_critical > 0
      # ANY customer-facing issue is a showstopper
      { status: 'BROKEN RELEASE PIPELINE', detail: "#{customer_facing_critical} customer-facing issues - CUSTOMERS AFFECTED", color: :red }
    elsif hosted_file_actions > 0
      { status: 'NEEDS DASHBOARD SYNC', detail: "#{hosted_file_actions} Lemon Squeezy hosted file updates pending", color: :yellow }
    elsif !has_data
      { status: 'INSUFFICIENT DATA', detail: 'Need data from 3+ projects', color: :yellow }
    elsif system_critical.positive?
      { status: 'PROCESS HEALTH BLOCKED', detail: "#{system_critical} system-health issues to fix", color: :red }
    elsif app_critical.positive?
      { status: 'APP READINESS BLOCKED', detail: "#{app_critical} app-readiness issues to fix", color: :yellow }
    elsif critical_fails >= 3
      { status: 'NOT WORKING', detail: "#{critical_fails} critical failures", color: :red }
    elsif critical_fails >= 1
      { status: 'NEEDS WORK', detail: "#{critical_fails} issues to fix", color: :yellow }
    elsif data_gaps >= 3
      { status: 'PROMISING BUT UNPROVEN', detail: "Not enough data to confirm", color: :yellow }
    else
      { status: 'WORKING', detail: "Objective metrics support effectiveness", color: :green }
    end

    @verdict = overall.merge(
      sections: {
        system_health: section_verdict(:system_health, finding_summary[:system_health]),
        release_readiness: section_verdict(:release_readiness, finding_summary[:release_readiness]),
        app_readiness: section_verdict(:app_readiness, finding_summary[:app_readiness]),
        advisory: section_verdict(:advisory, finding_summary[:advisory])
      }
    )
  end

  def section_verdict(area, summary)
    critical = summary[:critical].to_i
    warnings = summary[:warnings].to_i
    label = area.to_s.split('_').map(&:capitalize).join(' ')

    if critical.positive?
      { status: 'BLOCKED', detail: "#{critical} critical, #{warnings} warning", label: label }
    elsif warnings.positive?
      { status: 'WARN', detail: "#{warnings} warning", label: label }
    else
      { status: 'PASS', detail: 'No open findings', label: label }
    end
  end

  # ==========================================================================
  # OUTPUT
  # ==========================================================================
  def output_text
    puts
    puts "═" * 70
    puts "  SANEPROCESS VALIDATION REPORT"
    puts "  Is this thing actually working, or is it BS?"
    puts "═" * 70
    puts "  Generated: #{Time.now}"
    puts "  Projects: #{@data.keys.join(', ')}"
    puts "═" * 70
    puts

    # VERDICT FIRST
    color = case @verdict[:color]
            when :red then "\e[31m"
            when :green then "\e[32m"
            else "\e[33m"
            end
    puts "#{color}▶ VERDICT: #{@verdict[:status]}\e[0m"
    puts "  #{@verdict[:detail]}"
    puts

    if @verdict[:sections]
      puts "SECTION VERDICTS:"
      @verdict[:sections].each_value do |section|
        icon = case section[:status]
               when 'PASS' then '✅'
               when 'WARN' then '⚠️ '
               else '❌'
               end
        puts "   #{icon} #{section[:label]}: #{section[:status]} (#{section[:detail]})"
      end
      puts
    end

    # CRITICAL ISSUES
    if @issues.any?
      puts "❌ CRITICAL ISSUES (#{@issues.size}):"
      @issues.each do |i|
        puts "   #{i}"
        puts "      Action: #{finding_action(i)}"
      end
      puts
    end

    # WARNINGS
    if @warnings.any?
      puts "⚠️  DATA GAPS (#{@warnings.size}):"
      @warnings.each do |w|
        puts "   #{w}"
        puts "      Action: #{finding_action(w)}"
      end
      puts
    end

    # METRICS BY QUESTION
    puts "─" * 70
    puts "Q0: IS CONFIG CONSISTENT?"
    m = @metrics[:config_consistency]
    if m[:issues] == 0
      puts "   ✅ All configs consistent (deprecated plugins removed, local MCPs used)"
    else
      puts "   ❌ #{m[:issues]} config issues found:"
      m[:details].each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q1: ARE BLOCKS CORRECT?"
    if @metrics[:block_accuracy][:total] > 0
      puts "   Accuracy: #{@metrics[:block_accuracy][:accuracy]}% (#{@metrics[:block_accuracy][:correct]}/#{@metrics[:block_accuracy][:total]})"
      puts "   Need: 80%+ to prove blocks add value"
    else
      puts "   NO DATA - validation tracking not yet populated"
    end
    puts

    puts "Q2: ARE DOOM LOOPS BEING CAUGHT?"
    m = @metrics[:doom_loop_prevention]
    puts "   Caught: #{m[:caught]}, Missed: #{m[:missed]}"
    puts "   Catch rate: #{m[:catch_rate] || 'N/A'}%"
    puts "   Breaker trips: #{m[:breaker_trips]}, Repeat patterns: #{m[:repeat_error_patterns]}"
    puts

    puts "Q3: IS SELF-RATING HONEST?"
    if @metrics[:score_integrity][:status] == 'NO DATA'
      puts "   NO DATA"
    else
      m = @metrics[:score_integrity]
      puts "   Samples: #{m[:sample_size]} (need #{MIN_SAMPLES_FOR_SIGNIFICANCE}+)"
      puts "   Distribution: #{m[:distribution]}"
      puts "   Average: #{m[:average]}, Std Dev: #{m[:std_dev]}"
      puts "   % at 8+: #{m[:pct_8_or_higher]}% (>85% = rubber-stamping)"
    end
    puts

    puts "Q4: DO SESSIONS END WITH PASSING TESTS?"
    m = @metrics[:test_outcomes]
    if m[:total_sessions] > 0
      puts "   Pass rate: #{m[:pass_rate]}% (#{m[:sessions_tests_passing]}/#{m[:total_sessions]})"
      if m[:session_quality] && m[:session_quality][:sample_size].positive?
        q = m[:session_quality]
        puts "   Session quality: #{q[:clean_green]} clean green, #{q[:recovered_green]} recovered, #{q[:unrecovered_failures]} unrecovered"
        puts "   Clean green rate: #{q[:clean_green_rate]}%, Avg SOP score: #{q[:average_sop_score] || 'N/A'}"
      end
    else
      puts "   NO DATA - sessions_total not tracked yet"
    end
    puts

    puts "Q5: IS THE TREND IMPROVING?"
    m = @metrics[:trend]
    if m[:status]
      puts "   #{m[:status]} (#{m[:snapshots]} snapshots)"
    else
      puts "   First half avg score: #{m[:first_half_avg_score]}"
      puts "   Second half avg score: #{m[:second_half_avg_score]}"
    end
    puts

    puts "─" * 70
    puts "RELEASE PIPELINE & CUSTOMER-FACING CHECKS"
    puts "─" * 70
    puts

    puts "Q6: CAN CUSTOMERS DOWNLOAD RELEASES?"
    m = @metrics[:release_integrity] || {}
    if m[:issues].to_i == 0 && m[:warnings].to_i == 0
      puts "   ✅ All release URLs accessible, no forbidden GitHub release distribution detected"
    else
      puts "   ❌ #{m[:issues]} issues, #{m[:warnings]} warnings"
      (m[:details] || []).each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q7: ARE WEBSITES ACCESSIBLE?"
    m = @metrics[:website_distribution] || {}
    if m[:issues].to_i == 0 && m[:warnings].to_i == 0
      puts "   ✅ All websites reachable, SSL valid"
    else
      puts "   ⚠️  #{m[:issues]} issues, #{m[:warnings]} warnings"
      (m[:details] || []).each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q8: IS CODE SIGNING VALID?"
    m = @metrics[:code_signing] || {}
    if m[:issues].to_i == 0 && m[:warnings].to_i == 0
      puts "   ✅ Signing identity valid, notarization working"
    else
      puts "   ⚠️  #{m[:issues]} issues, #{m[:warnings]} warnings"
      (m[:details] || []).each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q9: IS SUPPORT INFRASTRUCTURE WORKING?"
    m = @metrics[:support_infrastructure] || {}
    if m[:issues].to_i == 0 && m[:warnings].to_i == 0
      puts "   ✅ API keys valid, services running"
    else
      puts "   ⚠️  #{m[:issues]} issues, #{m[:warnings]} warnings"
      (m[:details] || []).each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q10: IS DOCUMENTATION CURRENT?"
    m = @metrics[:documentation_currency] || {}
    if m[:issues].to_i == 0 && m[:warnings].to_i == 0
      puts "   ✅ Docs match latest versions"
    else
      puts "   ⚠️  #{m[:issues]} issues, #{m[:warnings]} warnings"
      (m[:details] || []).each { |d| puts "      - #{d}" }
    end
    puts

    puts "Q11: CROSS-CHANNEL VERSION CONSISTENCY"
    m = @metrics[:cross_channel_consistency] || {}
    table = m[:table] || []
    if table.any?
      puts "   %-12s %-10s %-10s %-10s %-10s %-10s" % %w[App Appcast Website Webhook Homebrew Lemon]
      puts "   #{'─' * 12} #{'─' * 10} #{'─' * 10} #{'─' * 10} #{'─' * 10} #{'─' * 10}"
      table.each do |row|
        v = row[:versions]
        puts "   %-12s %-10s %-10s %-10s %-10s %-10s" % [row[:app], v[:appcast], v[:website], v[:webhook], v[:cask], v[:lemonsqueezy]]
      end
    end
    canonical_issues = m[:canonical_issues].to_i
    hosted_file_actions = m[:hosted_file_actions].to_i
    if canonical_issues == 0 && hosted_file_actions == 0
      puts "   ✅ All channels consistent"
    else
      puts "   ❌ #{canonical_issues} canonical drift issues detected" if canonical_issues > 0
      puts "   ⚠️  #{hosted_file_actions} Lemon Squeezy hosted file updates pending" if hosted_file_actions > 0
      (m[:canonical_details] || []).each { |d| puts "      - #{d}" }
      (m[:hosted_file_details] || []).each { |d| puts "      - #{d}" }
      @warnings.grep(/^Q11 DRIFT:/).each { |d| puts "      - #{d.sub(/^Q11 DRIFT: /, '')}" }
    end

    puts
    puts "Q12: RED-NOISE BUDGET"
    m = @metrics[:red_noise_budget] || {}
    if m[:stale_count].to_i.zero?
      puts "   ✅ No findings older than #{RED_NOISE_BUDGET_DAYS} days in the active report"
    else
      puts "   ⚠️  #{m[:stale_count]} findings are older than #{RED_NOISE_BUDGET_DAYS} days"
      Array(m[:details]).first(8).each do |detail|
        puts "      - #{detail[:age_days]}d: #{detail[:finding]}"
        puts "        Action: #{detail[:action]}"
      end
    end

    puts "─" * 70
    puts

    # RELEASE READINESS CHECKLISTS
    output_release_checklists

    puts "Run daily. Need 30+ samples per metric for statistical significance."
    puts "═" * 70
  end

  def output_release_checklists
    puts "═" * 70
    puts "RELEASE READINESS CHECKLISTS (ALL APPS)"
    puts "═" * 70
    puts

    product_definitions.each do |product|
      next unless product[:project_exists]

      checklist = generate_app_checklist(product)

      # Determine status
      done_count = checklist.count { |item| item[:status] == :done }
      total_count = checklist.size
      critical_missing = checklist.any? { |item| item[:critical] && item[:status] != :done }

      status_icon = if critical_missing
        "❌ NOT READY (critical gate failed)"
      elsif done_count == total_count
        "✅ READY TO SHIP"
      elsif done_count >= total_count - 2
        "🟡 ALMOST READY"
      else
        "❌ NOT READY (#{total_count - done_count} items remaining)"
      end

      puts "#{product[:name]}: #{status_icon}"
      checklist.each do |item|
        icon = item[:status] == :done ? "✓" : "☐"
        puts "   [#{icon}] #{item[:name]}"
      end
      puts
    end

    puts "─" * 70
  end

  def generate_app_checklist(product)
    checklist = []
    app_name = product[:name]
    project_path = product[:project_path]
    site_host = product[:domain].to_s.empty? ? website_domain_for_project(project_path, app_name) : product[:domain]
    website_url = "https://#{site_host}"
    live_appcast = fetch_live_appcast_snapshot(site_host)
    live_release_url = live_appcast && live_appcast[:enclosure_url].to_s
    live_artifact = inspect_live_release_artifact(live_release_url)
    page_content = fetch_url_text(website_url)
    page_links = extract_page_links(page_content, base_url: website_url)

    # ===========================================
    # CODE & BUILD
    # ===========================================

    # 1. GitHub repo exists
    github_repo = product[:github_repo].to_s.empty? ? "sane-apps/#{app_name}" : product[:github_repo]
    repo_exists = system("gh repo view #{Shellwords.shellescape(github_repo)} > /dev/null 2>&1")
    checklist << { name: "GitHub repo (#{github_repo})", status: repo_exists ? :done : :todo }

    # 2. GitHub release policy (license-gated apps allow all channels; ungated = R2 only)
    license_gated = product[:license_gated]

    if repo_exists
      releases = `gh release list --repo sane-apps/#{app_name} --limit 1 2>/dev/null`.strip
      has_release = !releases.empty? && !releases.include?('no releases')
      if license_gated
        checklist << { name: "GitHub releases (allowed — license gated)", status: :done }
      else
        checklist << { name: "No GitHub releases (no license gating)", status: has_release ? :todo : :done }
      end
    else
      checklist << { name: "GitHub release policy", status: :done }
    end

    # 3. Hardened runtime enabled (check xcconfig or project)
    xcconfig_paths = [
      File.join(project_path, 'Config', 'Release.xcconfig'),
      File.join(project_path, 'Config', 'Shared.xcconfig')
    ]
    hardened_runtime = xcconfig_paths.any? do |p|
      File.exist?(p) && File.read(p).include?('ENABLE_HARDENED_RUNTIME = YES')
    end
    # Also check project.pbxproj
    pbxproj = Dir.glob(File.join(project_path, '**/*.pbxproj')).first
    if pbxproj && !hardened_runtime
      hardened_runtime = File.read(pbxproj).include?('ENABLE_HARDENED_RUNTIME = YES')
    end
    checklist << { name: "Hardened runtime enabled", status: hardened_runtime ? :done : :todo }

    # 4. Entitlements file exists
    entitlements = Dir.glob(File.join(project_path, '**/*.entitlements')).first
    checklist << { name: "Entitlements file exists", status: entitlements ? :done : :todo }

    # 5. App category set (check Info.plist or xcconfig)
    has_category = project_declares_app_category?(project_path)
    checklist << { name: "App category set (LSApplicationCategoryType)", status: has_category ? :done : :todo }

    qa_status = latest_project_qa_status(project_path)
    if qa_status
      qa_time = qa_status['generatedAt'] ? Time.parse(qa_status['generatedAt']).strftime('%Y-%m-%d %H:%M') : 'unknown'
      stale_reasons = Array(qa_status['staleReasons']).reject(&:empty?)
      qa_current = stale_reasons.empty?
      qa_passed = qa_status['status'] != 'failed' && qa_current
      qa_label =
        if !qa_current
          "Latest project QA gate is current (snapshot stale: #{stale_reasons.join('; ')})"
        elsif qa_passed
          "Latest project QA gate passed (#{qa_time})"
        else
          "Latest project QA gate passed (latest run failed at #{qa_time})"
        end
      checklist << { name: qa_label, status: qa_passed ? :done : :todo, critical: true }
    else
      checklist << { name: 'Latest project QA gate passed', status: :todo, critical: true }
    end

    # ===========================================
    # SIGNING & NOTARIZATION
    # ===========================================

    # 6. Live release artifact exists
    artifact_name = live_artifact[:artifact_name]
    checklist << {
      name: artifact_name ? "Live release archive (#{artifact_name})" : 'Live release archive',
      status: live_artifact[:available] ? :done : :todo
    }

    # 7. Artifact signing check
    # 8. Artifact notarization check
    if live_artifact[:available]
      if artifact_name.to_s.end_with?('.dmg')
        checklist << { name: 'Live DMG signed with Developer ID', status: live_artifact[:signed] ? :done : :todo }
        checklist << { name: 'Live DMG notarized & stapled', status: live_artifact[:notarized] ? :done : :todo }
      else
        checklist << { name: 'Live ZIP contains Developer ID signed app', status: live_artifact[:signed] ? :done : :todo }
        checklist << { name: 'Live ZIP app notarization check', status: live_artifact[:notarized] ? :done : :todo }
      end
    else
      checklist << { name: 'Live ZIP contains Developer ID signed app', status: :todo }
      checklist << { name: 'Live ZIP app notarization check', status: :todo }
    end

    # ===========================================
    # SPARKLE AUTO-UPDATE
    # ===========================================

    # 9. Live appcast exists and has active entries
    if live_appcast
      has_entries = !live_appcast[:version].to_s.empty? && !live_release_url.to_s.empty?
      has_signature = live_appcast[:has_signature]
      checklist << { name: "Live appcast.xml with active entry", status: has_entries ? :done : :todo }
      checklist << { name: "Live Sparkle EdDSA signature", status: has_signature ? :done : :todo }
    else
      checklist << { name: "Live appcast.xml with active entry", status: :todo }
      checklist << { name: "Live Sparkle EdDSA signature", status: :todo }
    end

    # 10. Release URL accessible
    if live_release_url && !live_release_url.empty?
      status = check_url_status(live_release_url, follow_redirects: true)
      url_works = %w[200 301 302].include?(status)
      checklist << { name: "Live release URL accessible (#{status})", status: url_works ? :done : :todo }
    else
      checklist << { name: "Live release URL accessible", status: :todo }
    end

    # ===========================================
    # DOCUMENTATION
    # ===========================================

    # 11. CHANGELOG.md exists
    changelog_paths = [
      File.join(project_path, 'CHANGELOG.md'),
      File.join(project_path, 'docs', 'CHANGELOG.md')
    ]
    has_changelog = changelog_paths.any? { |p| File.exist?(p) }
    checklist << { name: "CHANGELOG.md", status: has_changelog ? :done : :todo }

    # 12. README.md exists
    has_readme = File.exist?(File.join(project_path, 'README.md'))
    checklist << { name: "README.md", status: has_readme ? :done : :todo }

    # 13. PRIVACY.md exists
    has_privacy = File.exist?(File.join(project_path, 'PRIVACY.md'))
    checklist << { name: "PRIVACY.md", status: has_privacy ? :done : :todo }

    # ===========================================
    # WEBSITE & DISTRIBUTION
    # ===========================================

    # 14. Website accessible
    website_status = check_url_status(website_url, follow_redirects: true)
    website_works = %w[200 301 302].include?(website_status)
    checklist << { name: "Website (#{site_host})", status: website_works ? :done : :todo }

    # 15. Cloudflare DNS (check if using Cloudflare nameservers)
    if website_works
      # Simple check - if website works and has CF headers, it's on Cloudflare
      cf_check = `curl -sI --connect-timeout 3 "#{website_url}" 2>/dev/null`
      on_cloudflare = cf_check.include?('cloudflare') || cf_check.include?('cf-ray')
      checklist << { name: "Cloudflare DNS/CDN", status: on_cloudflare ? :done : :todo }
    else
      checklist << { name: "Cloudflare DNS/CDN", status: :todo }
    end

    # 16. Website has download link (must not depend on GitHub releases)
    if website_works
      has_download = page_has_live_download_link?(page_links, live_release_url)
      checklist << { name: "Website has download link", status: has_download ? :done : :todo }
    else
      checklist << { name: "Website has download link", status: :todo }
    end

    # 17. Privacy policy on website
    if website_works
      has_privacy_link = page_has_privacy_link?(page_links, website_url)
      checklist << { name: "Privacy policy on website", status: has_privacy_link ? :done : :todo }
    else
      checklist << { name: "Privacy policy on website", status: :todo }
    end

    # ===========================================
    # PAYMENT & LICENSING
    # ===========================================

    # 18. Lemon Squeezy product configured (check website or products.yml for checkout config)
    if website_works
      has_lemonsqueezy = page_has_checkout_link?(page_links, product)
      checklist << { name: "Lemon Squeezy store configured", status: has_lemonsqueezy ? :done : :todo }
    else
      checklist << { name: "Lemon Squeezy store configured", status: :todo }
    end

    # ===========================================
    # SUPPORT
    # ===========================================

    # 19. Support email configured (check website for contact/support)
    if website_works
      has_support = page_has_support_contact?(page_links, github_repo)
      checklist << { name: "Support contact on website", status: has_support ? :done : :todo }
    else
      checklist << { name: "Support contact on website", status: :todo }
    end

    # 20. GitHub issues enabled (for bug reports)
    has_issues = repo_exists && github_repo_has_issues?(github_repo)
    checklist << { name: "GitHub issues for bug reports", status: has_issues ? :done : :todo }

    checklist
  end

  def latest_project_qa_status(project_path)
    candidates = [
      File.join(project_path, 'outputs', 'qa_status.json'),
      File.join(project_path, 'outputs', 'release_preflight_status.json'),
      File.join(project_path, 'outputs', 'validation', 'qa_status.json')
    ]
    status_path = candidates
      .select { |path| File.exist?(path) }
      .max_by { |path| File.mtime(path) }
    return nil unless status_path

    status = JSON.parse(File.read(status_path))
    snapshot_time = begin
      Time.parse(status['generatedAt'].to_s)
    rescue ArgumentError
      File.mtime(status_path)
    end
    head_epoch = `git -C #{Shellwords.shellescape(project_path)} log -1 --format=%ct 2>/dev/null`.to_s.strip.to_i
    dirty = !`git -C #{Shellwords.shellescape(project_path)} status --porcelain 2>/dev/null`.to_s.strip.empty?
    stale_reasons = []
    stale_reasons << 'snapshot predates current HEAD commit' if head_epoch.positive? && snapshot_time.to_i < head_epoch
    stale_reasons << 'repository has uncommitted changes' if dirty
    status['staleReasons'] = stale_reasons
    status
  rescue JSON::ParserError
    nil
  rescue StandardError
    nil
  end

  def project_declares_app_category?(project_path)
    candidate_paths = Dir.glob(File.join(project_path, '**/Info.plist')) +
      Dir.glob(File.join(project_path, '**/*.xcconfig')) +
      Dir.glob(File.join(project_path, '**/*.pbxproj'))

    candidate_paths.any? do |path|
      content = File.read(path) rescue ''
      content.include?('LSApplicationCategoryType') ||
        content.include?('INFOPLIST_KEY_LSApplicationCategoryType')
    end
  end

  def load_product_config
    @load_product_config ||= begin
      raw = YAML.safe_load(File.read(PRODUCT_CONFIG_PATH), permitted_classes: []) || {}
      products = raw['products'].is_a?(Hash) ? raw['products'] : {}
      store = raw['store'].is_a?(Hash) ? raw['store'] : {}
      redirect = raw['redirect'].is_a?(Hash) ? raw['redirect'] : {}

      {
        products: products,
        store_base: store['base_url'].to_s.strip,
        checkout_base: store['checkout_base'].to_s.strip,
        redirect_base: redirect['base_url'].to_s.strip,
        all_domains: Array(raw['all_domains']).map(&:to_s).map(&:strip).reject(&:empty?)
      }
    rescue StandardError
      { products: {}, store_base: '', checkout_base: '', redirect_base: '', all_domains: [] }
    end
  end

  def product_definitions
    @product_definitions ||= begin
      load_product_config[:products].map do |slug, prod|
        next unless prod.is_a?(Hash)

        app_name = prod['name'].to_s.strip
        next if app_name.empty?

        project_path = File.join(SANE_APPS_ROOT, 'apps', app_name)
        {
          slug: slug.to_s,
          name: app_name,
          domain: prod['domain'].to_s.strip,
          dist_domain: prod['dist_domain'].to_s.strip,
          github_repo: prod['github_repo'].to_s.strip,
          checkout_uuid: prod['checkout_uuid'].to_s.strip,
          license_gated: !!prod['license_gated'],
          project_path: project_path,
          project_exists: File.directory?(project_path)
        }
      end.compact
    end
  end

  def released_product_definitions
    product_definitions.select { |product| !product[:checkout_uuid].to_s.empty? }
  end

  def extract_page_links(html, base_url:)
    return [] if html.to_s.empty?

    html.scan(/href\s*=\s*["']([^"']+)["']/i).flatten.map do |href|
      next if href.to_s.strip.empty? || href.start_with?('#', 'javascript:')

      begin
        uri = URI.parse(href)
        if uri.scheme.nil?
          URI.join(base_url, href).to_s
        elsif %w[http https mailto].include?(uri.scheme)
          uri.to_s
        end
      rescue URI::InvalidURIError
        nil
      end
    end.compact.uniq
  end

  def link_status_ok?(url)
    %w[200 301 302].include?(check_url_status(url, follow_redirects: true))
  end

  def page_has_live_download_link?(links, live_release_url)
    return false if live_release_url.to_s.strip.empty?

    expected_name = File.basename(URI(live_release_url).path.to_s)
    direct_candidate = links.find do |link|
      begin
        File.basename(URI(link).path.to_s) == expected_name
      rescue URI::InvalidURIError
        false
      end
    end
    return true if direct_candidate && link_status_ok?(direct_candidate)

    redirect_candidate = links.find { |link| download_redirect_candidate?(link) }
    return false unless redirect_candidate

    link_resolves_to_live_release?(redirect_candidate, expected_name) ||
      download_landing_page_links_to_live_release?(redirect_candidate, expected_name)
  rescue StandardError
    false
  end

  def download_redirect_candidate?(link)
    uri = URI(link)
    return false unless %w[http https].include?(uri.scheme)

    segments = uri.path.to_s.split('/').reject(&:empty?)
    segments.any? { |segment| segment.downcase == 'download' }
  rescue URI::InvalidURIError
    false
  end

  def link_resolves_to_live_release?(link, expected_name)
    output, status = Open3.capture2e(
      'curl',
      '-sIL',
      '--max-redirs', '5',
      '--connect-timeout', '5',
      '--max-time', '15',
      '-o', '/dev/null',
      '-w', '%{url_effective} %{http_code}',
      link
    )
    return false unless status.success?

    effective_url, status_code = output.to_s.strip.rpartition(' ').values_at(0, 2)
    return false unless %w[200 301 302].include?(status_code)

    File.basename(URI(effective_url).path.to_s) == expected_name
  rescue StandardError
    false
  end

  def download_landing_page_links_to_live_release?(link, expected_name)
    html = fetch_url_text(link)
    links = extract_page_links(html, base_url: link)
    direct_candidate = links.find do |candidate|
      begin
        File.basename(URI(candidate).path.to_s) == expected_name
      rescue URI::InvalidURIError
        false
      end
    end
    direct_candidate ? link_status_ok?(direct_candidate) : false
  rescue StandardError
    false
  end

  def page_has_checkout_link?(links, product)
    config = load_product_config
    expected_prefixes = []
    unless config[:redirect_base].empty?
      expected_prefixes << "#{config[:redirect_base]}/#{product[:slug]}"
    end
    unless config[:checkout_base].empty? || product[:checkout_uuid].to_s.empty?
      expected_prefixes << "#{config[:checkout_base]}/#{product[:checkout_uuid]}"
    end
    candidate = links.find do |link|
      expected_prefixes.any? { |prefix| link.start_with?(prefix) }
    end
    candidate ? link_status_ok?(candidate) : false
  end

  def page_has_privacy_link?(links, website_url)
    candidates = links.select { |link| link.downcase.include?('/privacy') || link.downcase.include?('privacy.html') }
    candidates.concat([
      "#{website_url}/privacy",
      "#{website_url}/privacy.html"
    ])
    candidates.uniq.any? { |link| link_status_ok?(link) }
  end

  def page_has_support_contact?(links, github_repo)
    issue_prefix = "https://github.com/#{github_repo}/issues"
    links.any? do |link|
      link.start_with?('mailto:') ||
        link.include?('/cdn-cgi/l/email-protection') ||
        link.start_with?(issue_prefix) ||
        link == "#{issue_prefix}/new" ||
        link_status_ok?(link) && link.include?('/support')
    end
  end

  def github_repo_has_issues?(github_repo)
    result = `gh api repos/#{Shellwords.shellescape(github_repo)} --jq .has_issues 2>/dev/null`.to_s.strip
    result == 'true'
  rescue StandardError
    false
  end

  def zip_contains_signed_notarized_app?(zip_path)
    signed = false
    notarized = false

    Dir.mktmpdir('validation_zip_') do |dir|
      extracted = system("ditto -x -k #{Shellwords.shellescape(zip_path)} #{Shellwords.shellescape(dir)} > /dev/null 2>&1")
      return [false, false] unless extracted

      app_path = Dir.glob(File.join(dir, '**', '*.app')).first
      return [false, false] unless app_path

      codesign_output = `codesign -dv "#{app_path}" 2>&1`
      spctl_output = `spctl -a -t exec -vv "#{app_path}" 2>&1`
      signed = spctl_output.include?('origin=Developer ID Application') || codesign_output.include?('TeamIdentifier=')
      notarized = spctl_output.include?('Notarized Developer ID') ||
                  (spctl_output.include?('accepted') && !spctl_output.include?('rejected'))
    end

    [signed, notarized]
  rescue StandardError
    [false, false]
  end

  def output_json
    puts JSON.pretty_generate({
      generated_at: Time.now.iso8601,
      verdict: @verdict,
      issues: @issues,
      warnings: @warnings,
      findings: finding_records,
      metrics: @metrics
    })
  end

  def save_snapshot
    FileUtils.mkdir_p(REPORT_DIR)
    File.write(
      File.join(REPORT_DIR, "#{Date.today}.json"),
      JSON.pretty_generate({
        generated_at: Time.now.iso8601,
        verdict: @verdict,
        issues: @issues,
        warnings: @warnings,
        findings: finding_records,
        metrics: @metrics
      })
    )
  end

  def std_dev(arr)
    return 0 if arr.empty?
    mean = arr.sum.to_f / arr.size
    Math.sqrt(arr.sum { |x| (x - mean)**2 } / arr.size)
  end

  def tally_counts(arr)
    if arr.respond_to?(:tally)
      arr.tally
    else
      counts = Hash.new(0)
      arr.each { |v| counts[v] += 1 }
      counts
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  format = ARGV.include?('--json') ? :json : :text
  ValidationReport.new.run(format: format)
end
