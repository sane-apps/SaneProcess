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
      args = args.dup
      json_path = extract_flag_value(args, '--export-json')
      html_path = extract_flag_value(args, '--export-html')
      summary = process_metrics_summary(read_process_metric_events)
      export_process_metrics_json(summary, json_path) if json_path
      export_process_metrics_html(summary, html_path) if html_path

      if args.include?('--json')
        puts JSON.pretty_generate(summary)
      else
        puts 'SaneProcess Metrics Dashboard'
        puts '=' * 34
        puts "Metrics path: #{process_metrics_path}"
        puts "JSON export: #{json_path}" if json_path
        puts "HTML export: #{html_path}" if html_path
        puts "Events: #{summary[:total_events]}"
        puts
        puts "Verify attempts: #{summary[:verify][:attempts]}"
        puts "  Pass rate: #{summary[:verify][:pass_rate] || 'N/A'}%"
        puts "  Zero-test failures: #{summary[:verify][:zero_test_failures]}"
        puts "  Zero-test successes: #{summary[:verify][:zero_test_successes]}"
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
        puts
        puts "Workflow events:"
        summary[:workflow_events][:by_type].each { |type, count| puts "  #{type}: #{count}" }
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

    def extract_flag_value(args, flag)
      index = args.index(flag)
      return nil unless index

      args.delete_at(index)
      value = args.delete_at(index)
      raise ArgumentError, "#{flag} requires a path" if value.to_s.strip.empty?

      value
    end

    def export_process_metrics_json(summary, path)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      File.write(path, JSON.pretty_generate(summary))
    end

    def export_process_metrics_html(summary, path)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      File.write(path, process_metrics_html(summary))
    end

    def process_metrics_html(summary)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>SaneProcess Metrics</title>
          <style>
            body { font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 32px; color: #101418; background: #f7f8fa; }
            main { max-width: 980px; margin: 0 auto; }
            h1 { margin: 0 0 4px; font-size: 28px; }
            .muted { color: #5d6875; }
            .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 20px 0; }
            .card { background: white; border: 1px solid #dce1e7; border-radius: 8px; padding: 16px; }
            .value { display: block; font-size: 26px; font-weight: 700; margin-top: 6px; }
            table { width: 100%; border-collapse: collapse; background: white; border: 1px solid #dce1e7; }
            th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #e8ebef; }
            th { background: #eef2f5; }
          </style>
        </head>
        <body>
          <main>
            <h1>SaneProcess Metrics</h1>
            <p class="muted">Generated from local process metrics. HTML is a review artifact; JSONL remains the source log.</p>
            <section class="grid">
              <div class="card">Events<span class="value">#{escape_html(summary[:total_events])}</span></div>
              <div class="card">Verify Pass Rate<span class="value">#{escape_html(summary.dig(:verify, :pass_rate) || 'N/A')}%</span></div>
              <div class="card">Session Events<span class="value">#{escape_html(summary.dig(:sessions, :total))}</span></div>
              <div class="card">Hook Blocks<span class="value">#{escape_html(summary.dig(:hook_blocks, :total))}</span></div>
            </section>
            <h2>Verify By Project</h2>
            <table>
              <thead><tr><th>Project</th><th>Passes</th><th>Attempts</th><th>Pass Rate</th></tr></thead>
              <tbody>
                #{process_metrics_project_rows(summary)}
              </tbody>
            </table>
            <h2>Session Quality</h2>
            <table>
              <tbody>
                <tr><th>Clean green</th><td>#{escape_html(summary.dig(:sessions, :clean_green))}</td></tr>
                <tr><th>Recovered green</th><td>#{escape_html(summary.dig(:sessions, :recovered_green))}</td></tr>
                <tr><th>Unrecovered failures</th><td>#{escape_html(summary.dig(:sessions, :unrecovered_failures))}</td></tr>
                <tr><th>Average SOP score</th><td>#{escape_html(summary.dig(:sessions, :average_sop_score) || 'N/A')}</td></tr>
              </tbody>
            </table>
            <h2>Hook Blocks</h2>
            <table>
              <thead><tr><th>Rule</th><th>Count</th></tr></thead>
              <tbody>
                #{process_metrics_hook_rows(summary)}
              </tbody>
            </table>
            <h2>Workflow Events</h2>
            <table>
              <thead><tr><th>Type</th><th>Count</th></tr></thead>
              <tbody>
                #{process_metrics_workflow_rows(summary)}
              </tbody>
            </table>
          </main>
        </body>
        </html>
      HTML
    end

    def process_metrics_project_rows(summary)
      summary.dig(:verify, :by_project).map do |project, data|
        <<~ROW
          <tr>
            <td>#{escape_html(project)}</td>
            <td>#{escape_html(data[:passes])}</td>
            <td>#{escape_html(data[:attempts])}</td>
            <td>#{escape_html(data[:pass_rate] || 'N/A')}%</td>
          </tr>
        ROW
      end.join
    end

    def process_metrics_hook_rows(summary)
      rows = summary.dig(:hook_blocks, :by_rule).map do |rule, count|
        "<tr><td>#{escape_html(rule)}</td><td>#{escape_html(count)}</td></tr>"
      end
      rows.empty? ? '<tr><td colspan="2">No hook blocks recorded</td></tr>' : rows.join
    end

    def process_metrics_workflow_rows(summary)
      rows = summary.dig(:workflow_events, :by_type).map do |type, count|
        "<tr><td>#{escape_html(type)}</td><td>#{escape_html(count)}</td></tr>"
      end
      rows.empty? ? '<tr><td colspan="2">No workflow receipt metrics recorded</td></tr>' : rows.join
    end

    def escape_html(value)
      value.to_s
           .gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
           .gsub("'", '&#39;')
    end

    def process_metrics_summary(events)
      verify = events.select { |event| event['type'] == 'verify' }
      sessions = events.select { |event| event['type'] == 'session_end' }
      hook_blocks = events.select { |event| event['type'] == 'hook_block' }
      workflow_events = events.reject { |event| %w[verify session_end hook_block].include?(event['type'].to_s) }
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
          zero_test_successes: verify.count { |event| event['success'] == true && event.key?('tests_run') && event['tests_run'].to_i.zero? },
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
        },
        workflow_events: {
          total: workflow_events.length,
          by_type: workflow_events.group_by { |event| event['type'].to_s.empty? ? 'unknown' : event['type'].to_s }
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
