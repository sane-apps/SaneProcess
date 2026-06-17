# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'
require 'yaml'

module SaneMasterModules
  module ReleaseReadiness
    private

    def release_readiness(args = [])
      options = parse_release_readiness_args(args)
      report = release_readiness_report(options)

      if options[:json]
        puts JSON.pretty_generate(report)
      else
        print_release_readiness_report(report)
      end

      exit(report.dig(:summary, :ready) ? 0 : 1)
    end

    def parse_release_readiness_args(args)
      options = { json: false, app: nil, scope: nil }
      index = 0
      while index < args.length
        arg = args[index]
        case arg
        when '--json'
          options[:json] = true
        when '--app'
          index += 1
          raise ArgumentError, 'missing value for release_readiness --app' if args[index].to_s.empty? || args[index].start_with?('--')

          options[:app] = args[index]
        when /\A--app=(.+)\z/
          options[:app] = Regexp.last_match(1)
        when '--app='
          raise ArgumentError, 'missing value for release_readiness --app'
        when '--scope'
          index += 1
          raise ArgumentError, 'missing value for release_readiness --scope' if args[index].to_s.empty? || args[index].start_with?('--')

          options[:scope] = args[index]
        when /\A--scope=(.+)\z/
          options[:scope] = Regexp.last_match(1)
        when '--scope='
          raise ArgumentError, 'missing value for release_readiness --scope'
        else
          raise ArgumentError, "unknown release_readiness argument: #{arg}"
        end
        index += 1
      end
      options[:scope] ||= options[:app] ? 'candidate' : default_release_readiness_scope
      unless %w[candidate portfolio].include?(options[:scope].to_s)
        raise ArgumentError, "invalid release_readiness scope: #{options[:scope]}"
      end
      options
    end

    def default_release_readiness_scope
      File.exist?(File.join(Dir.pwd, '.saneprocess')) ? 'candidate' : 'portfolio'
    end

    def release_readiness_report(options = {})
      app_paths = release_readiness_target_paths(options)
      app_reports = app_paths.map { |path| release_readiness_app_report(path) }
      candidate_reports = app_reports.select { |report| report[:candidate_readiness][:status] != 'not_applicable' }
      portfolio_blockers = app_reports.flat_map { |report| report[:portfolio_health][:blockers].map { |blocker| "#{report[:app]}: #{blocker}" } }
      candidate_blockers = candidate_reports.flat_map { |report| report[:candidate_readiness][:blockers].map { |blocker| "#{report[:app]}: #{blocker}" } }
      candidate_ready = candidate_blockers.empty?
      portfolio_ok = portfolio_blockers.empty?
      scope_ready = options[:scope].to_s == 'candidate' ? candidate_ready : (candidate_ready && portfolio_ok)

      {
        generated_at: Time.now.utc.iso8601,
        scope: options[:scope],
        summary: {
          ready: scope_ready,
          candidate_ready: candidate_ready,
          portfolio_ok: portfolio_ok,
          candidate_blocker_count: candidate_blockers.count,
          portfolio_blocker_count: portfolio_blockers.count
        },
        apps: app_reports,
        next_actions: release_readiness_next_actions(candidate_blockers, portfolio_blockers)
      }
    end

    def release_readiness_target_paths(options)
      if options[:app]
        path = release_readiness_app_path(options[:app])
        raise ArgumentError, "unknown app for release_readiness: #{options[:app]}" unless path

        return [path]
      end

      if options[:scope].to_s == 'candidate' && File.exist?(File.join(Dir.pwd, '.saneprocess'))
        return [Dir.pwd]
      end

      Dir.glob(File.join(release_readiness_apps_root, '*'))
        .select { |path| File.exist?(File.join(path, '.saneprocess')) }
        .sort
    end

    def release_readiness_apps_root
      File.expand_path('../../apps', saneprocess_repo_root)
    end

    def release_readiness_app_path(app_name)
      direct = File.join(release_readiness_apps_root, app_name.to_s)
      return direct if File.exist?(File.join(direct, '.saneprocess'))

      Dir.glob(File.join(release_readiness_apps_root, '*')).find do |path|
        release_readiness_manifest(path)['name'].to_s.casecmp(app_name.to_s).zero?
      end
    end

    def release_readiness_app_report(project_path)
      manifest = release_readiness_manifest(project_path)
      app_name = manifest['name'].to_s.empty? ? File.basename(project_path) : manifest['name'].to_s
      preflight = release_readiness_read_json(File.join(project_path, 'outputs', 'release_preflight_status.json'))
      qa = release_readiness_read_json(File.join(project_path, 'outputs', 'qa_status.json'))
      dirty_entries = release_readiness_git_status(project_path)
      candidate = release_readiness_candidate_status(preflight, qa, dirty_entries)

      {
        app: app_name,
        project_path: project_path,
        candidate_readiness: candidate,
        portfolio_health: release_readiness_portfolio_status(project_path, preflight),
        receipts: {
          release_preflight: release_readiness_receipt_summary(preflight),
          qa: release_readiness_receipt_summary(qa)
        },
        git: {
          dirty: !dirty_entries.empty?,
          dirty_count: dirty_entries.count,
          dirty_entries: dirty_entries.first(20)
        }
      }
    end

    def release_readiness_candidate_status(preflight, qa, dirty_entries)
      blockers = []
      warnings = []

      if preflight.nil?
        blockers << 'release_preflight receipt missing'
      elsif preflight['status'].to_s != 'passed'
        blockers.concat(Array(preflight['issues']).map(&:to_s))
        blockers << "release_preflight status is #{preflight['status']}" if blockers.empty?
      end

      if qa && qa['policyOnlyMode'] == true && qa['status'].to_s != 'passed'
        Array(qa['errors']).each { |error| blockers << "policy QA: #{error}" }
      end

      warnings << "#{dirty_entries.count} uncommitted file(s)" unless dirty_entries.empty?

      {
        status: blockers.empty? ? 'ready' : 'blocked',
        blockers: blockers.uniq,
        warnings: warnings
      }
    end

    def release_readiness_portfolio_status(_project_path, preflight)
      blockers = []
      if preflight && preflight['status'].to_s != 'passed' && Array(preflight['issues']).any? { |issue| issue.to_s.match?(/Customer UI action contract/i) }
        blockers << 'customer UI proof is stale for portfolio validation'
      end
      { status: blockers.empty? ? 'ok' : 'blocked', blockers: blockers.uniq }
    end

    def release_readiness_receipt_summary(receipt)
      return nil unless receipt

      {
        generated_at: receipt['generatedAt'] || receipt['generated_at'],
        status: receipt['status'],
        policy_only: receipt['policyOnlyMode'] == true,
        issue_count: receipt['issueCount'] || receipt['errorCount'],
        warning_count: receipt['warningCount']
      }
    end

    def release_readiness_next_actions(candidate_blockers, portfolio_blockers)
      actions = []
      actions << 'Fix candidate blockers or wait for release cadence before shipping.' unless candidate_blockers.empty?
      actions << 'Refresh targeted customer UI proof for the candidate app before release.' if (candidate_blockers + portfolio_blockers).any? { |item| item.match?(/customer UI/i) }
      actions << 'Portfolio is not fully green; keep broad launch/posting disabled until portfolio health clears.' unless portfolio_blockers.empty?
      actions << 'Candidate receipts are green; proceed to subagent audit and release gates.' if candidate_blockers.empty?
      actions
    end

    def release_readiness_manifest(project_path)
      path = File.join(project_path, '.saneprocess')
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    def release_readiness_read_json(path)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      nil
    end

    def release_readiness_git_status(project_path)
      output, status = Open3.capture2e('git', '-C', project_path, 'status', '--porcelain=1', '--untracked-files=all')
      return [] unless status.success?

      output.lines.map(&:chomp).reject(&:empty?).sort
    end

    def print_release_readiness_report(report)
      puts "Release readiness (#{report[:scope]})"
      puts "Generated: #{report[:generated_at]}"
      puts "Summary: #{report.dig(:summary, :ready) ? 'READY' : 'BLOCKED'}"
      puts
      report[:apps].each do |app|
        candidate = app[:candidate_readiness]
        portfolio = app[:portfolio_health]
        puts "#{app[:app]}: candidate #{candidate[:status]}, portfolio #{portfolio[:status]}"
        candidate[:blockers].each { |blocker| puts "  blocker: #{blocker}" }
        portfolio[:blockers].each { |blocker| puts "  portfolio: #{blocker}" }
        candidate[:warnings].each { |warning| puts "  warning: #{warning}" }
      end
      puts
      puts 'Next actions:'
      report[:next_actions].each { |action| puts "  - #{action}" }
    end
  end
end
