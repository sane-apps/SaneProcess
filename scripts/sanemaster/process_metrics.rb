# frozen_string_literal: true

require 'json'
require 'time'
require_relative '../hooks/core/process_metrics'

module SaneMasterModules
  module ProcessMetrics
    def record_process_metric(type, payload = {})
      SaneProcessMetrics.record(
        type,
        { project: safe_metric_project_name, cwd: Dir.pwd }.merge(payload)
      )
    end

    def process_metrics_path
      SaneProcessMetrics.metrics_path
    end

    def process_metrics_dashboard(args = [])
      summary = process_metrics_summary(read_process_metric_events)
      if args.include?('--json')
        puts JSON.pretty_generate(summary)
      else
        puts 'SaneProcess Metrics Dashboard'
        puts '=' * 34
        puts "Metrics path: #{process_metrics_path}"
        puts "Events: #{summary[:total_events]}"
        puts
        puts "Verify attempts: #{summary[:verify][:attempts]}"
        puts "  Pass rate: #{summary[:verify][:pass_rate] || 'N/A'}%"
        puts "  Zero-test failures: #{summary[:verify][:zero_test_failures]}"
        puts "  By project:"
        summary[:verify][:by_project].each do |project, data|
          puts "    #{project}: #{data[:passes]}/#{data[:attempts]} passed (#{data[:pass_rate] || 'N/A'}%)"
        end
        puts
        puts "Session quality: #{summary[:sessions][:total]} session_end events"
        puts "  Clean green: #{summary[:sessions][:clean_green]}"
        puts "  Recovered green: #{summary[:sessions][:recovered_green]}"
        puts "  Unrecovered failures: #{summary[:sessions][:unrecovered_failures]}"
        puts "  Average SOP score: #{summary[:sessions][:average_sop_score] || 'N/A'}"
        puts
        puts "Hook blocks: #{summary[:hook_blocks][:total]}"
        summary[:hook_blocks][:by_rule].each { |rule, count| puts "  #{rule}: #{count}" }
      end
      summary
    end

    def refresh_qa_snapshots(args = [])
      run = args.include?('--run')
      json = args.include?('--json')
      targets = qa_snapshot_targets

      payload = {
        mode: run ? 'run' : 'dry-run',
        stale_count: targets.count { |target| target[:stale] },
        targets: targets
      }

      if json
        puts JSON.pretty_generate(payload)
      else
        puts "QA Snapshot Refresh (#{payload[:mode]})"
        puts '=' * 30
        targets.each do |target|
          status = target[:stale] ? 'STALE' : 'current'
          puts "#{target[:app]}: #{status}"
          puts "  Path: #{target[:project_path]}"
          puts "  Status: #{target[:status_path] || 'missing'}"
          Array(target[:stale_reasons]).each { |reason| puts "  - #{reason}" }
          puts "  Command: cd #{target[:project_path]} && ruby scripts/qa.rb" if target[:stale]
        end
      end

      return payload unless run

      targets.select { |target| target[:stale] }.each do |target|
        puts "▶ Refreshing #{target[:app]} QA snapshot..."
        ok = system('ruby', 'scripts/qa.rb', chdir: target[:project_path])
        target[:refresh_status] = ok ? 'passed' : 'failed'
      end

      payload
    end

    private

    def read_process_metric_events
      return [] unless File.exist?(process_metrics_path)

      File.readlines(process_metrics_path, chomp: true).map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def process_metrics_summary(events)
      verify = events.select { |event| event['type'] == 'verify' }
      sessions = events.select { |event| event['type'] == 'session_end' }
      hook_blocks = events.select { |event| event['type'] == 'hook_block' }
      verify_by_project = {}
      verify.group_by { |event| event['project'].to_s.empty? ? 'unknown' : event['project'].to_s }
            .sort.each do |project, project_events|
        attempts = project_events.length
        passes = project_events.count { |event| event['success'] == true }
        verify_by_project[project] = {
          attempts: attempts,
          passes: passes,
          pass_rate: attempts.positive? ? ((passes.to_f / attempts) * 100).round(1) : nil
        }
      end

      scores = sessions.map { |event| event['sop_score'].to_f }.reject(&:zero?)
      {
        total_events: events.length,
        verify: {
          attempts: verify.length,
          passes: verify.count { |event| event['success'] == true },
          pass_rate: verify.empty? ? nil : ((verify.count { |event| event['success'] == true }.to_f / verify.length) * 100).round(1),
          zero_test_failures: verify.count { |event| event['success'] != true && event['tests_run'].to_i.zero? },
          by_project: verify_by_project
        },
        sessions: {
          total: sessions.length,
          clean_green: sessions.count { |event| event['success'] == true && event['verify_failures'].to_i.zero? },
          recovered_green: sessions.count { |event| event['success'] == true && event['verify_failures'].to_i.positive? },
          unrecovered_failures: sessions.count { |event| event['success'] != true && event['edits'].to_i.positive? },
          average_sop_score: scores.empty? ? nil : (scores.sum / scores.length).round(2)
        },
        hook_blocks: {
          total: hook_blocks.length,
          by_rule: hook_blocks.group_by { |event| event['rule'].to_s.empty? ? 'unknown' : event['rule'].to_s }
                              .transform_values(&:length)
                              .sort.to_h
        }
      }
    end

    def qa_snapshot_targets(root = File.expand_path('~/SaneApps/apps'))
      Dir.glob(File.join(root, '*')).sort.map do |project_path|
        next unless File.directory?(project_path)
        next unless File.exist?(File.join(project_path, 'scripts', 'qa.rb'))

        status = latest_qa_snapshot(project_path)
        stale_reasons = qa_snapshot_stale_reasons(project_path, status)
        {
          app: File.basename(project_path),
          project_path: project_path,
          status_path: status && status[:path],
          generated_at: status && status[:generated_at],
          status: status && status[:status],
          stale: stale_reasons.any?,
          stale_reasons: stale_reasons
        }
      end.compact
    end

    def latest_qa_snapshot(project_path)
      paths = [
        File.join(project_path, 'outputs', 'qa_status.json'),
        File.join(project_path, 'outputs', 'release_preflight_status.json'),
        File.join(project_path, 'outputs', 'validation', 'qa_status.json')
      ].select { |path| File.exist?(path) }
      return nil if paths.empty?

      path = paths.max_by { |candidate| File.mtime(candidate) }
      data = JSON.parse(File.read(path))
      { path: path, generated_at: data['generatedAt'], status: data['status'] }
    rescue JSON::ParserError
      { path: path, generated_at: nil, status: 'corrupt' }
    end

    def qa_snapshot_stale_reasons(project_path, status)
      reasons = []
      reasons << 'snapshot missing' unless status

      if status && status[:generated_at]
        snapshot_time = Time.parse(status[:generated_at]).to_i rescue 0
        head_epoch = `git -C "#{project_path}" log -1 --format=%ct 2>/dev/null`.to_i
        reasons << 'snapshot predates current HEAD commit' if head_epoch.positive? && snapshot_time < head_epoch
      end

      dirty = `git -C "#{project_path}" status --porcelain 2>/dev/null`
      reasons << 'repository has uncommitted changes' unless dirty.strip.empty?
      reasons << 'latest snapshot failed' if status && status[:status].to_s == 'failed'
      reasons
    end

    def safe_metric_project_name
      respond_to?(:project_name) ? project_name : File.basename(Dir.pwd)
    rescue StandardError
      File.basename(Dir.pwd)
    end
  end
end
