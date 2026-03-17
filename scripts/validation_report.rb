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
  MIN_SAMPLES_FOR_SIGNIFICANCE = 30  # Bare minimum, 100+ preferred

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
    calculate_final_verdict
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

    @metrics[:config_consistency] = {
      issues: issues_found.size,
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
            @warnings << "Q0: [#{label}] #{name} local path missing on this machine: #{local_arg}"
          end
        end
      end
    rescue JSON::ParserError
      issues_found << "[#{label}] .mcp.json is corrupt"
    end
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

    PROJECTS.each do |project|
      claude_md = File.join(SANE_APPS_ROOT, project, 'CLAUDE.md')
      next unless File.exist?(claude_md)

      content = File.read(claude_md)
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
    total_sessions = 0
    passing_sessions = 0

    @data.each do |_, info|
      v = info[:state]['validation'] || {}
      total_sessions += v['sessions_total'].to_i
      passing_sessions += v['sessions_with_tests_passing'].to_i
    end

    pass_rate = total_sessions > 0 ? ((passing_sessions.to_f / total_sessions) * 100).round(1) : nil

    @metrics[:test_outcomes] = {
      total_sessions: total_sessions,
      sessions_tests_passing: passing_sessions,
      pass_rate: pass_rate
    }

    if total_sessions >= MIN_SAMPLES_FOR_SIGNIFICANCE
      if pass_rate && pass_rate < 80
        @issues << "Q4 FAIL: Only #{pass_rate}% sessions end with passing tests. Ship quality is low."
      end

      # Cross-check: High scores but low pass rate = scores are BS
      avg_score = @metrics.dig(:score_integrity, :average)
      if avg_score && avg_score >= 8 && pass_rate && pass_rate < 70
        @issues << "Q4 FAIL: Average score #{avg_score} but pass rate #{pass_rate}%. Scores don't reflect reality."
      end
    else
      @warnings << "Q4: Only #{total_sessions} sessions tracked. Need #{MIN_SAMPLES_FOR_SIGNIFICANCE}+."
    end
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

    if latest_url.nil? || latest_url.empty?
      warnings << "[#{app_name}] appcast.xml has no enclosure URL in latest item"
      return
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

    @metrics[:documentation_currency] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q10 DOCS: #{i}" }
    warnings_found.each { |w| @warnings << "Q10 DOCS: #{w}" }
  end

  # Q11: CROSS-CHANNEL VERSION CONSISTENCY
  # Are appcast, website, webhook, and Homebrew all serving the same version?
  # This catches the SaneBar 2.1.13-2.1.18 drift where 6 releases shipped without
  # updating the email webhook PRODUCT_CONFIG.
  def q11_cross_channel_version_consistency
    issues_found = []
    warnings_found = []
    version_table = []

    webhook_snapshot = fetch_live_email_worker_snapshot
    warnings_found << 'Live email worker snapshot unavailable; webhook drift check skipped where data is missing' if webhook_snapshot.nil?

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

      version_table << { app: app_name, versions: versions }

      # Compare all present versions against appcast (source of truth)
      next unless appcast_ver

      %i[website webhook cask].each do |channel|
        chan_ver = versions[channel]
        next if chan_ver == '—'

        if chan_ver != appcast_ver
          label = { website: 'Website download link', webhook: 'Email webhook PRODUCT_CONFIG', cask: 'Homebrew cask' }[channel]
          issues_found << "[#{app_name}] VERSION DRIFT: #{label} has v#{chan_ver} but appcast is v#{appcast_ver}"
        end
      end
    end

    @metrics[:cross_channel_consistency] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      table: version_table,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q11 DRIFT: #{i}" }
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

    {
      appcast_url: appcast_url,
      body: body,
      latest_item: latest_item,
      enclosure_url: enclosure_url,
      version: version.to_s.strip,
      build: build.to_s.strip,
      minimum_system_version: minimum_system_version.to_s.strip,
      has_signature: has_signature
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

    # Sufficient data?
    has_data = @data.size >= 3

    # Q6 RELEASE issues are CRITICAL - customers can't update!
    release_issues = (@metrics[:release_integrity] || {})[:issues].to_i
    # Q7 WEBSITE issues are CRITICAL - customers can't download!
    website_issues = (@metrics[:website_distribution] || {})[:issues].to_i
    # Q8 SIGNING issues are CRITICAL - app won't run!
    signing_issues = (@metrics[:code_signing] || {})[:issues].to_i
    # Q11 DRIFT issues are CRITICAL - customers get wrong builds!
    drift_issues = (@metrics[:cross_channel_consistency] || {})[:issues].to_i

    customer_facing_critical = release_issues + website_issues + signing_issues + drift_issues

    @metrics[:final] = {
      critical_failures: critical_fails,
      customer_facing_critical: customer_facing_critical,
      data_gaps: data_gaps,
      projects_with_data: @data.size
    }

    @verdict = if customer_facing_critical > 0
      # ANY customer-facing issue is a showstopper
      { status: 'BROKEN RELEASE PIPELINE', detail: "#{customer_facing_critical} customer-facing issues - CUSTOMERS AFFECTED", color: :red }
    elsif !has_data
      { status: 'INSUFFICIENT DATA', detail: 'Need data from 3+ projects', color: :yellow }
    elsif critical_fails >= 3
      { status: 'NOT WORKING', detail: "#{critical_fails} critical failures", color: :red }
    elsif critical_fails >= 1
      { status: 'NEEDS WORK', detail: "#{critical_fails} issues to fix", color: :yellow }
    elsif data_gaps >= 3
      { status: 'PROMISING BUT UNPROVEN', detail: "Not enough data to confirm", color: :yellow }
    else
      { status: 'WORKING', detail: "Objective metrics support effectiveness", color: :green }
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

    # CRITICAL ISSUES
    if @issues.any?
      puts "❌ CRITICAL ISSUES (#{@issues.size}):"
      @issues.each { |i| puts "   #{i}" }
      puts
    end

    # WARNINGS
    if @warnings.any?
      puts "⚠️  DATA GAPS (#{@warnings.size}):"
      @warnings.each { |w| puts "   #{w}" }
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
      puts "   %-12s %-10s %-10s %-10s %-10s" % %w[App Appcast Website Webhook Homebrew]
      puts "   #{'─' * 12} #{'─' * 10} #{'─' * 10} #{'─' * 10} #{'─' * 10}"
      table.each do |row|
        v = row[:versions]
        puts "   %-12s %-10s %-10s %-10s %-10s" % [row[:app], v[:appcast], v[:website], v[:webhook], v[:cask]]
      end
    end
    if m[:issues].to_i == 0
      puts "   ✅ All channels consistent"
    else
      puts "   ❌ #{m[:issues]} version drift issues detected"
      (m[:details] || []).each { |d| puts "      - #{d}" }
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
    has_category = false
    info_plist_paths = Dir.glob(File.join(project_path, '**/Info.plist'))
    info_plist_paths.each do |plist|
      content = File.read(plist) rescue ''
      if content.include?('LSApplicationCategoryType')
        has_category = true
        break
      end
    end
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
    candidate = links.find do |link|
      begin
        File.basename(URI(link).path.to_s) == expected_name
      rescue URI::InvalidURIError
        false
      end
    end
    candidate ? link_status_ok?(candidate) : false
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
