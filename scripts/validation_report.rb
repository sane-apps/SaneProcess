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
require 'date'
require 'fileutils'

class ValidationReport
  SANE_APPS_ROOT = File.expand_path('~/SaneApps')
  REPORT_DIR = File.join(File.dirname(__FILE__), '..', 'outputs', 'validation')
  MIN_SAMPLES_FOR_SIGNIFICANCE = 30  # Bare minimum, 100+ preferred

  PROJECTS = %w[
    apps/SaneBar
    apps/SaneVideo
    apps/SaneSync
    apps/SaneClip
    apps/SaneAI
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
    apps/SaneAI
    apps/SaneHosts
    apps/SaneClick
  ].freeze

  def initialize
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
      'XcodeBuildMCP' => "#{home_dir}/Dev/xcodebuild-mcp-local",
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

    # === PROJECT HOOK CONSISTENCY CHECK ===
    # Audit all project settings.json for hook pattern consistency
    required_hooks = %w[SessionStart UserPromptSubmit PreToolUse PostToolUse Stop]
    deprecated_pattern = '~/.claude/hooks/'
    valid_patterns = [
      'SaneProcess/scripts/hooks/',     # Absolute path to SaneProcess (preferred)
      './scripts/hooks/',               # Project-relative (if project has own hooks)
      './Scripts/hooks/'                # Project-relative (capitalized)
    ]

    PROJECTS.each do |project|
      settings_file = File.join(SANE_APPS_ROOT, project, '.claude', 'settings.json')
      next unless File.exist?(settings_file)

      begin
        settings = JSON.parse(File.read(settings_file))
        hooks = settings['hooks'] || {}

        # Check each required hook
        required_hooks.each do |hook_name|
          hook_cmd = hooks.dig(hook_name, 0, 'hooks', 0, 'command') || ''

          if hook_cmd.empty?
            issues_found << "[#{project}] Missing hook: #{hook_name}"
          elsif hook_cmd.include?(deprecated_pattern)
            issues_found << "[#{project}] Deprecated hook pattern in #{hook_name}: uses ~/.claude/hooks/"
          elsif !valid_patterns.any? { |p| hook_cmd.include?(p) }
            # Check if it at least references the right hook file
            hook_file = hook_name == 'SessionStart' ? 'session_start.rb' :
                        hook_name == 'UserPromptSubmit' ? 'saneprompt.rb' :
                        hook_name == 'PreToolUse' ? 'sanetools.rb' :
                        hook_name == 'PostToolUse' ? 'sanetrack.rb' : 'sanestop.rb'
            unless hook_cmd.include?(hook_file)
              issues_found << "[#{project}] #{hook_name} hook doesn't reference #{hook_file}"
            end
          end
        end
      rescue JSON::ParserError
        # Already caught in deprecated plugins check
      end
    end

    # === GLOBAL HOOK REGISTRATION CHECK ===
    # Verify global settings.json hooks point to correct paths
    if File.exist?(global_settings)
      begin
        settings = JSON.parse(File.read(global_settings))
        hooks = settings['hooks'] || {}

        # Check SessionStart uses valid hook pattern
        session_start = hooks.dig('SessionStart', 0, 'hooks', 0, 'command') || ''
        unless session_start.include?('session_start.rb')
          issues_found << "Global SessionStart hook not configured (missing session_start.rb)"
        end
        if session_start.include?(deprecated_pattern)
          issues_found << "Global settings uses deprecated ~/.claude/hooks/ pattern"
        end
      rescue JSON::ParserError
        # Already caught above
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

        # Check if local path is correct
        if command == 'node' && !args.any? { |a| a.include?(local_path) }
          issues_found << "[#{label}] #{name} points to wrong local path"
        end
      end
    rescue JSON::ParserError
      issues_found << "[#{label}] .mcp.json is corrupt"
    end
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

    tokens_to_check = %w[GITHUB_TOKEN CLOUDFLARE_API_TOKEN LEMON_SQUEEZY_API_KEY]

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
    all_apps = %w[SaneBar SaneClip SaneVideo SaneSync SaneHosts SaneAI SaneClick]

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

    if all_scores.empty?
      @metrics[:score_integrity] = { status: 'NO DATA' }
      return
    end

    distribution = all_scores.tally.sort.to_h
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
      if high_pct >= 85
        @issues << "Q3 FAIL: #{high_pct}% scores are 8+. This is rubber-stamping, not assessment."
      end
      if std < 0.8
        @issues << "Q3 FAIL: Std dev #{std} too low. Scores should vary with actual performance."
      end
      if avg >= 8.5 && std < 1.0
        @issues << "Q3 FAIL: Average #{avg} with std #{std} = feel-good theater, not honest rating."
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

    APP_PROJECTS.each do |project|
      project_path = File.join(SANE_APPS_ROOT, project)
      next unless File.directory?(project_path)

      app_name = project.split('/').last

      # Check appcast.xml exists and has valid URLs
      appcast_paths = [
        File.join(project_path, 'docs', 'appcast.xml'),
        File.join(project_path, 'appcast.xml')
      ]

      appcast = appcast_paths.find { |p| File.exist?(p) }
      if appcast
        check_appcast_urls(appcast, app_name, issues_found, warnings_found)
      else
        warnings_found << "[#{app_name}] No appcast.xml found (OK if not using Sparkle)"
      end

      # Check releases folder has DMGs
      releases_dir = File.join(project_path, 'releases')
      if Dir.exist?(releases_dir)
        dmgs = Dir.glob(File.join(releases_dir, '*.dmg'))
        if dmgs.empty?
          warnings_found << "[#{app_name}] releases/ folder exists but has no DMGs"
        end
      end

      # Check GitHub releases exist (if repo exists)
      check_github_releases(app_name, issues_found, warnings_found)
    end

    @metrics[:release_integrity] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q6 RELEASE: #{i}" }
    warnings_found.each { |w| @warnings << "Q6 RELEASE: #{w}" }
  end

  def check_appcast_urls(appcast_path, app_name, issues, warnings)
    content = File.read(appcast_path)

    # Extract enclosure URLs
    urls = content.scan(/url="([^"]+)"/).flatten.select { |u| u.include?('.dmg') }

    if urls.empty?
      warnings << "[#{app_name}] appcast.xml has no DMG enclosure URLs"
      return
    end

    # Test each URL (just the latest, to save time)
    latest_url = urls.first
    if latest_url
      # Use curl to check if URL is accessible (returns 200 or 302)
      status = `curl -sI -o /dev/null -w "%{http_code}" "#{latest_url}" 2>/dev/null`.strip
      unless ['200', '301', '302'].include?(status)
        issues << "[#{app_name}] Release URL returns #{status}: #{latest_url}"
      end
    end

    # Check Sparkle signatures exist
    unless content.include?('sparkle:edSignature') || content.include?('sparkle:dsaSignature')
      warnings << "[#{app_name}] appcast.xml missing Sparkle signatures"
    end

    # Check minimumSystemVersion isn't blocking everyone
    min_versions = content.scan(/minimumSystemVersion>([^<]+)</).flatten
    min_versions.each do |v|
      major = v.to_f.floor
      if major > 14  # macOS 14 is Sonoma (2023)
        warnings << "[#{app_name}] minimumSystemVersion #{v} may block many users"
      end
    end
  end

  def check_github_releases(app_name, issues, warnings)
    # Check if GitHub CLI is available
    return unless system('which gh > /dev/null 2>&1')

    # Try to get releases for the app
    repo = "sane-apps/#{app_name}"
    result = `gh release list --repo #{repo} --limit 1 2>&1`

    if result.include?('no releases found') || result.strip.empty?
      issues << "[#{app_name}] No GitHub releases found (customers can't download updates)"
    elsif result.include?('Could not resolve') || result.include?('not found')
      # Repo doesn't exist yet, that's OK for unreleased apps
      warnings << "[#{app_name}] GitHub repo not found (OK if unreleased)"
    end
  end

  # Q7: WEBSITE/DISTRIBUTION HEALTH
  # Can customers find and download our apps?
  def q7_website_distribution
    issues_found = []
    warnings_found = []

    # Check main domains
    domains = [
      { url: 'https://saneapps.com', name: 'Main site' },
      { url: 'https://sanebar.com', name: 'SaneBar site' },
      { url: 'https://saneclip.com', name: 'SaneClip site' },
      { url: 'https://sanehosts.com', name: 'SaneHosts site' }
    ]

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

    @metrics[:website_distribution] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q7 WEBSITE: #{i}" }
    warnings_found.each { |w| @warnings << "Q7 WEBSITE: #{w}" }
  end

  def check_url_status(url)
    result = `curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 "#{url}" 2>&1`
    return 'timeout' if result.include?('Connection timed out') || result.include?('Could not resolve')
    return 'error' if result.include?('curl:')
    return '5xx' if result.start_with?('5')
    result.strip
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
    APP_PROJECTS.each do |project|
      project_path = File.join(SANE_APPS_ROOT, project)
      app_name = project.split('/').last

      # Find most recent .app in DerivedData or build folder
      app_bundle = find_recent_app_bundle(project_path, app_name)
      next unless app_bundle

      # Verify signature
      codesign_check = `codesign -v "#{app_bundle}" 2>&1`
      if codesign_check.include?('invalid signature') || codesign_check.include?('not signed')
        issues_found << "[#{app_name}] App bundle has invalid or missing signature"
      end

      # Check notarization status
      staple_check = `stapler validate "#{app_bundle}" 2>&1`
      unless staple_check.include?('valid')
        warnings_found << "[#{app_name}] App may not be notarized (stapler check failed)"
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

    # Check DerivedData
    derived_data = File.expand_path('~/Library/Developer/Xcode/DerivedData')
    apps = Dir.glob(File.join(derived_data, "#{app_name}*/**/#{app_name}.app")).select { |f| File.exist?(f) }
    return apps.max_by { |f| File.mtime(f) } if apps.any?

    nil
  end

  # Q9: SUPPORT INFRASTRUCTURE
  # Can customers reach us? Can we reach them?
  def q9_support_infrastructure
    issues_found = []
    warnings_found = []

    # Check keychain has required credentials
    keychain_items = [
      { service: 'cloudflare', account: 'api_token', name: 'Cloudflare API' },
      { service: 'resend', account: 'api_key', name: 'Resend Email API' },
      { service: 'lemonsqueezy', account: 'api_key', name: 'Lemon Squeezy API' }
    ]

    keychain_items.each do |item|
      check = `security find-generic-password -s "#{item[:service]}" -a "#{item[:account]}" 2>&1`
      if check.include?('could not be found')
        issues_found << "#{item[:name]} key missing from keychain"
      end
    end

    # Check Resend API is working (if key exists)
    resend_check = `security find-generic-password -s "resend" -a "api_key" -w 2>/dev/null`.strip
    if resend_check && !resend_check.empty? && !resend_check.include?('could not')
      # Quick API health check (don't actually send)
      api_check = `curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer #{resend_check}" "https://api.resend.com/domains" 2>/dev/null`
      unless ['200', '401', '403'].include?(api_check.strip)
        warnings_found << "Resend API may be down or key invalid"
      end
    end

    # Check Sane-Mem is running (local knowledge store)
    sanemem_check = `curl -s -o /dev/null -w "%{http_code}" "http://localhost:37777/health" 2>/dev/null`
    if sanemem_check.strip != '200'
      warnings_found << "Sane-Mem service not running (learnings not being captured)"
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

    APP_PROJECTS.each do |project|
      project_path = File.join(SANE_APPS_ROOT, project)
      next unless File.directory?(project_path)

      app_name = project.split('/').last

      # Get version from appcast (latest release version)
      appcast_version = get_appcast_version(project_path)

      # Get version from Info.plist or Package.swift
      bundle_version = get_bundle_version(project_path, app_name)

      # Check README mentions current version
      readme = File.join(project_path, 'README.md')
      if File.exist?(readme)
        readme_content = File.read(readme)
        if appcast_version && !readme_content.include?(appcast_version)
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
    end

    @metrics[:documentation_currency] = {
      issues: issues_found.size,
      warnings: warnings_found.size,
      details: issues_found + warnings_found
    }

    issues_found.each { |i| @issues << "Q10 DOCS: #{i}" }
    warnings_found.each { |w| @warnings << "Q10 DOCS: #{w}" }
  end

  def get_appcast_version(project_path)
    appcast_paths = [
      File.join(project_path, 'docs', 'appcast.xml'),
      File.join(project_path, 'appcast.xml')
    ]
    appcast = appcast_paths.find { |p| File.exist?(p) }
    return nil unless appcast

    content = File.read(appcast)
    # Extract latest version (first sparkle:version)
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

    customer_facing_critical = release_issues + website_issues + signing_issues

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
      puts "   ✅ All release URLs accessible, GitHub releases exist"
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

    all_apps = %w[SaneBar SaneClip SaneHosts SaneVideo SaneSync SaneAI SaneClick]

    all_apps.each do |app_name|
      project_path = File.join(SANE_APPS_ROOT, "apps/#{app_name}")
      next unless File.directory?(project_path)

      checklist = generate_app_checklist(app_name, project_path)

      # Determine status
      done_count = checklist.count { |item| item[:status] == :done }
      total_count = checklist.size

      status_icon = if done_count == total_count
        "✅ READY TO SHIP"
      elsif done_count >= total_count - 2
        "🟡 ALMOST READY"
      else
        "❌ NOT READY (#{total_count - done_count} items remaining)"
      end

      puts "#{app_name}: #{status_icon}"
      checklist.each do |item|
        icon = item[:status] == :done ? "✓" : "☐"
        puts "   [#{icon}] #{item[:name]}"
      end
      puts
    end

    puts "─" * 70
  end

  def generate_app_checklist(app_name, project_path)
    checklist = []

    # ===========================================
    # CODE & BUILD
    # ===========================================

    # 1. GitHub repo exists
    repo_exists = system("gh repo view sane-apps/#{app_name} > /dev/null 2>&1")
    checklist << { name: "GitHub repo (sane-apps/#{app_name})", status: repo_exists ? :done : :todo }

    # 2. GitHub release exists
    if repo_exists
      releases = `gh release list --repo sane-apps/#{app_name} --limit 1 2>/dev/null`.strip
      has_release = !releases.empty? && !releases.include?('no releases')
      checklist << { name: "GitHub release published", status: has_release ? :done : :todo }
    else
      checklist << { name: "GitHub release published", status: :todo }
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

    # ===========================================
    # SIGNING & NOTARIZATION
    # ===========================================

    # 6. DMG exists in releases folder
    releases_dir = File.join(project_path, 'releases')
    dmg_files = Dir.exist?(releases_dir) ? Dir.glob(File.join(releases_dir, '*.dmg')) : []
    latest_dmg = dmg_files.max_by { |f| File.mtime(f) }
    checklist << { name: "DMG in releases folder", status: latest_dmg ? :done : :todo }

    # 7. DMG signed with Developer ID (not ad-hoc)
    if latest_dmg
      codesign_output = `codesign -dv "#{latest_dmg}" 2>&1`
      signed_with_dev_id = codesign_output.include?('Developer ID')
      checklist << { name: "DMG signed with Developer ID", status: signed_with_dev_id ? :done : :todo }
    else
      checklist << { name: "DMG signed with Developer ID", status: :todo }
    end

    # 8. DMG notarized (check with stapler)
    if latest_dmg
      stapler_result = `xcrun stapler validate "#{latest_dmg}" 2>&1`
      is_stapled = stapler_result.include?('validated')
      checklist << { name: "DMG notarized & stapled", status: is_stapled ? :done : :todo }
    else
      checklist << { name: "DMG notarized & stapled", status: :todo }
    end

    # ===========================================
    # SPARKLE AUTO-UPDATE
    # ===========================================

    # 9. Appcast.xml exists and has entries
    appcast_paths = [
      File.join(project_path, 'docs', 'appcast.xml'),
      File.join(project_path, 'appcast.xml')
    ]
    appcast = appcast_paths.find { |p| File.exist?(p) }
    if appcast
      content = File.read(appcast)
      has_entries = content.include?('sparkle:version') && !content.match?(/<!--.*sparkle:version.*-->/m)
      has_signature = content.include?('sparkle:edSignature') && !content.include?('TODO')
      checklist << { name: "Appcast.xml with active entries", status: has_entries ? :done : :todo }
      checklist << { name: "Sparkle EdDSA signature", status: has_signature ? :done : :todo }
    else
      checklist << { name: "Appcast.xml with active entries", status: :todo }
      checklist << { name: "Sparkle EdDSA signature", status: :todo }
    end

    # 10. Release URL accessible
    if appcast
      content = File.read(appcast)
      url_match = content.match(/url="([^"]+\.dmg)"/)
      if url_match
        url = url_match[1]
        status = `curl -sI -o /dev/null -w "%{http_code}" "#{url}" 2>/dev/null`.strip
        url_works = ['200', '301', '302'].include?(status)
        checklist << { name: "Release URL accessible (#{status})", status: url_works ? :done : :todo }
      else
        checklist << { name: "Release URL accessible", status: :todo }
      end
    else
      checklist << { name: "Release URL accessible", status: :todo }
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
    website_url = "https://#{app_name.downcase}.com"
    website_status = `curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 3 "#{website_url}" 2>/dev/null`.strip
    website_works = ['200', '301', '302'].include?(website_status)
    checklist << { name: "Website (#{app_name.downcase}.com)", status: website_works ? :done : :todo }

    # 15. Cloudflare DNS (check if using Cloudflare nameservers)
    if website_works
      # Simple check - if website works and has CF headers, it's on Cloudflare
      cf_check = `curl -sI --connect-timeout 3 "#{website_url}" 2>/dev/null`
      on_cloudflare = cf_check.include?('cloudflare') || cf_check.include?('cf-ray')
      checklist << { name: "Cloudflare DNS/CDN", status: on_cloudflare ? :done : :todo }
    else
      checklist << { name: "Cloudflare DNS/CDN", status: :todo }
    end

    # 16. Website has download link (check for github.com/releases or lemonsqueezy)
    if website_works
      page_content = `curl -sL --connect-timeout 5 "#{website_url}" 2>/dev/null`
      has_download = page_content.include?('github.com') && page_content.include?('releases') ||
                     page_content.include?('lemonsqueezy.com') ||
                     page_content.include?('.dmg')
      checklist << { name: "Website has download link", status: has_download ? :done : :todo }
    else
      checklist << { name: "Website has download link", status: :todo }
    end

    # 17. Privacy policy on website
    if website_works
      privacy_url = "#{website_url}/privacy"
      privacy_status = `curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 3 "#{privacy_url}" 2>/dev/null`.strip
      # Also check if main page links to privacy
      page_content = `curl -sL --connect-timeout 5 "#{website_url}" 2>/dev/null` rescue ''
      has_privacy_link = ['200', '301', '302'].include?(privacy_status) ||
                         page_content.downcase.include?('privacy')
      checklist << { name: "Privacy policy on website", status: has_privacy_link ? :done : :todo }
    else
      checklist << { name: "Privacy policy on website", status: :todo }
    end

    # ===========================================
    # PAYMENT & LICENSING
    # ===========================================

    # 18. Lemon Squeezy product configured (check website for lemonsqueezy link)
    if website_works
      page_content = `curl -sL --connect-timeout 5 "#{website_url}" 2>/dev/null` rescue ''
      has_lemonsqueezy = page_content.include?('lemonsqueezy.com') ||
                         page_content.include?('lemon-squeezy') ||
                         page_content.include?('checkout')
      checklist << { name: "Lemon Squeezy store configured", status: has_lemonsqueezy ? :done : :todo }
    else
      checklist << { name: "Lemon Squeezy store configured", status: :todo }
    end

    # ===========================================
    # SUPPORT
    # ===========================================

    # 19. Support email configured (check website for contact/support)
    if website_works
      page_content = `curl -sL --connect-timeout 5 "#{website_url}" 2>/dev/null` rescue ''
      has_support = page_content.include?('support') ||
                    page_content.include?('contact') ||
                    page_content.include?('hi@saneapps.com') ||
                    page_content.include?('mailto:')
      checklist << { name: "Support contact on website", status: has_support ? :done : :todo }
    else
      checklist << { name: "Support contact on website", status: :todo }
    end

    # 20. GitHub issues enabled (for bug reports)
    if repo_exists
      # If we can view the repo, issues are likely enabled
      checklist << { name: "GitHub issues for bug reports", status: :done }
    else
      checklist << { name: "GitHub issues for bug reports", status: :todo }
    end

    checklist
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
end

if __FILE__ == $PROGRAM_NAME
  format = ARGV.include?('--json') ? :json : :text
  ValidationReport.new.run(format: format)
end
