# frozen_string_literal: true

require 'json'
require 'time'
require 'digest'
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
      otel_path = extract_flag_value(args, '--export-otel')
      summary = process_metrics_summary(read_process_metric_events)
      export_process_metrics_json(summary, json_path) if json_path
      export_process_metrics_html(summary, html_path) if html_path
      export_process_metrics_otel(read_process_metric_events, otel_path) if otel_path

      if args.include?('--json')
        puts JSON.pretty_generate(summary)
      else
        puts 'SaneProcess Metrics Dashboard'
        puts '=' * 34
        puts "Metrics path: #{process_metrics_path}"
        puts "JSON export: #{json_path}" if json_path
        puts "HTML export: #{html_path}" if html_path
        puts "OpenTelemetry export: #{otel_path}" if otel_path
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

    def route_cost_review(args = [])
      options = parse_route_cost_review_options(args)
      events = options[:metrics_path] ? read_route_cost_events_from_path(options[:metrics_path]) : read_process_metric_events
      window = options[:limit] ? events.last(options[:limit]) : events
      result = build_route_cost_review(window, options: options.merge(total_events: events.length))

      if options[:json]
        puts JSON.pretty_generate(result)
      else
        print_route_cost_review(result)
      end

      result
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

    def read_route_cost_events_from_path(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).map do |line|
        next if line.strip.empty?

        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end.compact
    end

    def parse_route_cost_review_options(args)
      options = { json: false, limit: nil, min_count: 2, include_bookkeeping: false }
      rest = args.dup
      until rest.empty?
        token = rest.shift
        case token
        when '--json'
          options[:json] = true
        when '--limit'
          value = rest.shift
          raise ArgumentError, '--limit requires a positive integer' unless value.to_s.match?(/\A\d+\z/)

          options[:limit] = value.to_i
        when '--all'
          options[:limit] = nil
        when '--min-count'
          value = rest.shift
          raise ArgumentError, '--min-count requires a positive integer' unless value.to_s.match?(/\A\d+\z/)

          options[:min_count] = value.to_i
        when '--metrics'
          value = rest.shift
          raise ArgumentError, '--metrics requires a path' if value.to_s.empty?

          options[:metrics_path] = File.expand_path(value)
        when '--include-bookkeeping'
          options[:include_bookkeeping] = true
        else
          raise ArgumentError, "unknown route_cost_review option: #{token}"
        end
      end
      options
    end

    def build_route_cost_review(events, options: {})
      receipts = events.select { |event| event['type'] == 'workflow_receipt' }
      bookkeeping = receipts.select { |event| route_cost_bookkeeping_workflow?(event['workflow']) }
      review_receipts = options[:include_bookkeeping] ? receipts : receipts - bookkeeping
      min_count = [options.fetch(:min_count, 2).to_i, 1].max

      workflows = review_receipts
                  .group_by { |event| route_cost_canonical_workflow(event['workflow'] || event['command']) }
                  .map { |workflow, group| route_cost_workflow_summary(workflow, group) }
                  .select { |entry| entry[:count] >= min_count }
                  .sort_by { |entry| [route_cost_rank(entry), -entry[:p95_ms].to_i, -entry[:failures].to_i, entry[:workflow]] }

      {
        generated_at: Time.now.utc.iso8601,
        metrics_path: options[:metrics_path] || (respond_to?(:process_metrics_path) ? process_metrics_path : nil),
        total_events: options[:total_events] || events.length,
        lookback_events: events.length,
        workflow_receipts: receipts.length,
        ignored_bookkeeping_receipts: options[:include_bookkeeping] ? 0 : bookkeeping.length,
        min_count: min_count,
        summary: {
          workflow_count: workflows.length,
          high_cost_count: workflows.count { |entry| entry[:cost_class] == 'high' },
          proof_scope_sensitive_count: workflows.count { |entry| entry[:route_guard] == 'proof_scope_sensitive' },
          release_only_count: workflows.count { |entry| entry[:route_guard] == 'release_only' }
        },
        workflows: workflows,
        recommended_actions: route_cost_recommended_actions(workflows, bookkeeping.length, options[:include_bookkeeping])
      }
    end

    def route_cost_workflow_summary(workflow, group)
      durations = group.map { |event| event['duration_ms'].to_f }.select { |value| value.positive? }.sort
      failures = group.count { |event| event['success'] == false || (event.key?('exit_status') && event['exit_status'].to_i != 0) }
      avg_ms = durations.empty? ? nil : (durations.sum / durations.length).round
      p95_ms = route_cost_percentile(durations, 0.95)
      failure_rate = group.empty? ? 0.0 : ((failures.to_f / group.length) * 100).round(1)

      {
        workflow: workflow,
        raw_workflows: group.map { |event| route_cost_value(event['workflow'] || event['command']) }.uniq.sort,
        count: group.length,
        failures: failures,
        failure_rate: failure_rate,
        avg_ms: avg_ms,
        p95_ms: p95_ms,
        cost_class: route_cost_class(avg_ms, p95_ms),
        failure_risk: route_cost_failure_risk(failure_rate, group.length),
        route_guard: route_cost_guard(workflow),
        proof_guidance: route_cost_guidance(workflow),
        projects: group.map { |event| route_cost_value(event['project']) }.uniq.sort.first(10),
        examples: group.last(3).map { |event| route_cost_example(event) }
      }
    end

    def route_cost_percentile(values, percentile)
      return nil if values.empty?

      index = (values.length * percentile).floor
      index = values.length - 1 if index >= values.length
      values[index].round
    end

    def route_cost_class(avg_ms, p95_ms)
      avg = avg_ms.to_i
      p95 = p95_ms.to_i
      return 'high' if p95 >= 300_000 || avg >= 120_000
      return 'medium' if p95 >= 60_000 || avg >= 30_000

      'low'
    end

    def route_cost_failure_risk(failure_rate, count)
      return 'high' if failure_rate >= 40.0 && count >= 5
      return 'medium' if failure_rate >= 20.0 && count >= 3

      'low'
    end

    def route_cost_guard(workflow)
      case workflow.to_s
      when /release_preflight|appstore_preflight|launch_readiness|resource_soak|setapp_upload/
        'release_only'
      when /verify|test_mode|customer_ui_sweep|visual_smoke|monitor_tests|validation_report/
        'proof_scope_sensitive'
      when /mcp_watchdog/
        'bookkeeping'
      else
        'normal'
      end
    end

    def route_cost_guidance(workflow)
      case route_cost_guard(workflow)
      when 'release_only'
        'Use only for release, App Store, public launch, or ship-readiness proof; scoped behavior bugs should run proof_plan first.'
      when 'proof_scope_sensitive'
        'Run after proof_plan selects the right scope; focused behavior work should prefer focused tests plus exact Mini runtime proof.'
      when 'bookkeeping'
        'Treat as compressed bookkeeping, not customer-facing proof evidence.'
      else
        'Normal workflow cost; still record receipt and avoid passive wait states.'
      end
    end

    def route_cost_bookkeeping_workflow?(workflow)
      workflow.to_s.match?(/mcp_watchdog/)
    end

    def route_cost_rank(entry)
      cost_rank = { 'high' => 0, 'medium' => 1, 'low' => 2 }.fetch(entry[:cost_class], 3)
      failure_rank = { 'high' => 0, 'medium' => 1, 'low' => 2 }.fetch(entry[:failure_risk], 3)
      guard_rank = { 'release_only' => 0, 'proof_scope_sensitive' => 1, 'normal' => 2, 'bookkeeping' => 3 }.fetch(entry[:route_guard], 4)
      [cost_rank, failure_rank, guard_rank]
    end

    def route_cost_recommended_actions(workflows, ignored_bookkeeping_count, include_bookkeeping)
      actions = []
      release_only = workflows.select { |entry| entry[:route_guard] == 'release_only' && entry[:cost_class] != 'low' }
      if release_only.any?
        names = release_only.first(3).map { |entry| entry[:workflow] }.join(', ')
        actions << "Require proof_plan or explicit release/public-launch intent before running expensive release-only workflow(s): #{names}."
      end

      scoped = workflows.select { |entry| entry[:route_guard] == 'proof_scope_sensitive' && entry[:cost_class] != 'low' }
      if scoped.any?
        names = scoped.first(3).map { |entry| entry[:workflow] }.join(', ')
        actions << "For scoped behavior work, choose focused tests/runtime proof before broad workflow(s): #{names}."
      end

      unstable = workflows.select { |entry| entry[:failure_rate].to_f >= 30.0 && entry[:count].to_i >= 5 }
      if unstable.any?
        names = unstable.first(3).map { |entry| "#{entry[:workflow]} #{entry[:failure_rate]}%" }.join(', ')
        actions << "Review high-failure workflow defaults before increasing timeouts: #{names}."
      end

      actions << "Ignored #{ignored_bookkeeping_count} bookkeeping receipt(s); rerun with --include-bookkeeping only when auditing daemon health." if ignored_bookkeeping_count.positive? && !include_bookkeeping
      actions << 'No repeated expensive workflow met the threshold in this window.' if actions.empty?
      actions
    end

    def route_cost_example(event)
      {
        timestamp: event['timestamp'],
        workflow: event['workflow'],
        project: event['project'],
        success: event['success'],
        exit_status: event['exit_status'],
        duration_ms: event['duration_ms'],
        host: event['host']
      }.compact
    end

    def route_cost_value(value)
      value.to_s.empty? ? 'unknown' : value.to_s
    end

    def route_cost_canonical_workflow(value)
      workflow = route_cost_value(value)
      case workflow
      when 'validation_report', 'status', 'release_preflight', 'appstore_preflight', 'launch_readiness'
        "sanemaster:#{workflow}"
      else
        workflow
      end
    end

    def print_route_cost_review(result)
      puts 'Route Cost Review'
      puts '=' * 17
      puts "Metrics path: #{result[:metrics_path]}" if result[:metrics_path]
      puts "Workflow receipts: #{result[:workflow_receipts]}"
      puts "Ignored bookkeeping receipts: #{result[:ignored_bookkeeping_receipts]}"
      puts
      result[:workflows].each do |workflow|
        puts "#{workflow[:workflow]}: #{workflow[:cost_class]} cost, #{workflow[:failure_risk]} failure risk, #{workflow[:route_guard]}"
        puts "  Count: #{workflow[:count]} | Failures: #{workflow[:failures]} (#{workflow[:failure_rate]}%) | avg #{workflow[:avg_ms] || 'n/a'}ms | p95 #{workflow[:p95_ms] || 'n/a'}ms"
        puts "  Guidance: #{workflow[:proof_guidance]}"
      end
      puts
      puts 'Recommended actions:'
      result[:recommended_actions].each { |action| puts "  - #{action}" }
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

    def export_process_metrics_otel(events, path)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      File.write(path, JSON.pretty_generate(process_metrics_otel_payload(events)))
    end

    def process_metrics_otel_payload(events)
      {
        resourceSpans: [
          {
            resource: {
              attributes: otel_attributes(
                'service.name' => 'SaneProcess',
                'service.namespace' => 'SaneApps',
                'telemetry.sdk.name' => 'saneprocess',
                'telemetry.sdk.language' => 'ruby'
              )
            },
            scopeSpans: [
              {
                scope: {
                  name: 'saneprocess.process_metrics',
                  version: '1'
                },
                spans: events.map { |event| process_metric_otel_span(event) }.compact
              }
            ]
          }
        ]
      }
    end

    def process_metric_otel_span(event)
      timestamp = event['started_at'] || event['timestamp']
      return nil if timestamp.to_s.strip.empty?

      started = Time.parse(timestamp)
      completed = event['completed_at'] ? Time.parse(event['completed_at'].to_s) : started
      completed = started if completed < started
      type = event['type'].to_s.empty? ? 'process_metric' : event['type'].to_s
      workflow = event['workflow'].to_s
      name = workflow.empty? ? type : "#{type} #{workflow}"
      status_code = event.key?('success') ? (event['success'] == true ? 'STATUS_CODE_OK' : 'STATUS_CODE_ERROR') : 'STATUS_CODE_UNSET'

      {
        traceId: otel_hex_id(event, 32),
        spanId: otel_hex_id(event.merge('span' => name), 16),
        name: name,
        kind: 'SPAN_KIND_INTERNAL',
        startTimeUnixNano: (started.to_r * 1_000_000_000).to_i.to_s,
        endTimeUnixNano: (completed.to_r * 1_000_000_000).to_i.to_s,
        status: { code: status_code },
        attributes: otel_attributes(otel_event_attributes(event))
      }
    rescue ArgumentError
      nil
    end

    def otel_event_attributes(event)
      {
        'saneprocess.event_type' => event['type'],
        'saneprocess.project' => event['project'],
        'saneprocess.cwd' => event['cwd'],
        'saneprocess.workflow' => event['workflow'],
        'saneprocess.command_sha256' => event['command_sha256'],
        'saneprocess.exit_status' => event['exit_status'],
        'saneprocess.duration_ms' => event['duration_ms'],
        'host.name' => event['host']
      }.compact
    end

    def otel_hex_id(event, length)
      stable = event.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
                    .sort.to_h
      Digest::SHA256.hexdigest(JSON.generate(stable))[0, length]
    end

    def otel_attributes(hash)
      hash.map do |key, value|
        {
          key: key.to_s,
          value: otel_attribute_value(value)
        }
      end
    end

    def otel_attribute_value(value)
      case value
      when true, false
        { boolValue: value }
      when Integer
        { intValue: value.to_s }
      when Float
        { doubleValue: value }
      else
        { stringValue: value.to_s }
      end
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
      visual_smoke = events.select { |event| event['type'] == 'visual_smoke' && event['dry_run'] != true && event['status'].to_s != 'planned' }
      workflow_events = events.reject { |event| %w[verify session_end hook_block].include?(event['type'].to_s) }
      verify_by_project = {}
      verify.group_by { |event| event['project'].to_s.empty? ? 'unknown' : event['project'].to_s }
            .sort.each do |project, project_events|
        attempts = project_events.length
        passes = project_events.count { |event| event['success'] == true && event['tests_run'].to_i.positive? }
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
          passes: verify.count { |event| event['success'] == true && event['tests_run'].to_i.positive? },
          build_only_successes: verify.count { |event| event['success'] == true && event.key?('tests_run') && event['tests_run'].to_i.zero? },
          pass_rate: verify.empty? ? nil : ((verify.count { |event| event['success'] == true && event['tests_run'].to_i.positive? }.to_f / verify.length) * 100).round(1),
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
        visual_smoke: {
          attempts: visual_smoke.length,
          passes: visual_smoke.count { |event| event['success'] == true },
          failures: visual_smoke.count { |event| event['success'] != true },
          mini_passes: visual_smoke.count { |event| event['success'] == true && event['host'].to_s.downcase.include?('mini') }
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
