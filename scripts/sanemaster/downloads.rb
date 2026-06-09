# frozen_string_literal: true

module SaneMasterModules
  # Download analytics reporting — wraps dl-report.py for unified CLI access.
  # Mirrors the sales.rb pattern.
  #
  # Usage:
  #   SaneMaster.rb downloads              # Today/yesterday/week/all-time (default)
  #   SaneMaster.rb downloads --days 7     # Last 7 days
  #   SaneMaster.rb downloads --app sanebar # Filter by app
  #   SaneMaster.rb downloads --json       # Raw JSON for piping
  module Downloads
    def downloads(args)
      dl_report = File.join(__dir__, '..', 'automation', 'dl-report.py')

      unless File.exist?(dl_report)
        puts "❌ dl-report.py not found at #{dl_report}"
        exit 1
      end

      # Default to --daily if no flags given
      if args.empty?
        system('python3', dl_report, '--daily')
      else
        system('python3', dl_report, *args)
      end
    end

    def events(args)
      dl_report = File.join(__dir__, '..', 'automation', 'dl-report.py')

      unless File.exist?(dl_report)
        puts "❌ dl-report.py not found at #{dl_report}"
        exit 1
      end

      system('python3', dl_report, '--events', *args)
    end

    def appstore_funnel(args)
      days = extract_value_arg(args, '--days') || '30'
      json = args.include?('--json')
      dl_report = File.join(__dir__, '..', 'automation', 'dl-report.py')

      unless File.exist?(dl_report)
        puts "❌ dl-report.py not found at #{dl_report}"
        exit 1
      end

      output = `python3 #{Shellwords.escape(dl_report)} --events --days #{Shellwords.escape(days)} --json`
      unless $CHILD_STATUS.success?
        puts output
        exit $CHILD_STATUS.exitstatus || 1
      end

      rows = JSON.parse(output).fetch('event_dimensions', [])
      appstore_rows = rows.select { |row| row['channel'].to_s == 'app_store' }
      summary = summarize_appstore_funnel(appstore_rows)

      if json
        puts JSON.pretty_generate({ days: days.to_i, apps: summary })
        return
      end

      print_appstore_funnel(days.to_i, summary)
    end

    private

    PURCHASE_OUTCOME_EVENTS = %w[
      product_loaded
      product_load_failed
      purchase_started
      purchase_completed
      purchase_cancelled
      purchase_pending
      purchase_failed
      restore_completed
      restore_failed
    ].freeze

    SELLING_SIGNAL_EVENTS = %w[
      paywall_seen
      upsell_shown
      checkout_clicked
      chart_locked_viewed
      order_history_gate_seen
      second_provider_attempt
      purchase_started
      appstore_purchase_started
    ].freeze

    def extract_value_arg(args, flag)
      index = args.index(flag)
      return nil unless index

      args[index + 1]
    end

    def summarize_appstore_funnel(rows)
      grouped = rows.group_by { |row| [row['app'].to_s, row['platform'].to_s] }

      grouped.map do |(app, platform), app_rows|
        event_counts = Hash.new(0)
        app_rows.each do |row|
          event_counts[row['event'].to_s] += row['count'].to_i
        end

        {
          app: app,
          platform: platform,
          total_events: event_counts.values.sum,
          sellable_signals: event_counts.select { |event, _| SELLING_SIGNAL_EVENTS.include?(event) },
          purchase_outcomes: event_counts.select { |event, _| PURCHASE_OUTCOME_EVENTS.include?(event) },
          missing_outcomes: PURCHASE_OUTCOME_EVENTS.reject { |event| event_counts.key?(event) },
          events: event_counts.sort.to_h
        }
      end.sort_by { |entry| [entry[:app], entry[:platform]] }
    end

    def print_appstore_funnel(days, summary)
      puts "📱 App Store funnel events (last #{days} days)"
      puts

      if summary.empty?
        puts "No App Store-channel funnel events found."
        return
      end

      summary.each do |entry|
        puts "#{entry[:app]} #{entry[:platform]} — #{entry[:total_events]} events"
        if entry[:sellable_signals].empty?
          puts "  Sellable signals: none"
        else
          puts "  Sellable signals: #{format_event_counts(entry[:sellable_signals])}"
        end

        if entry[:purchase_outcomes].empty?
          puts "  Purchase outcomes: none"
        else
          puts "  Purchase outcomes: #{format_event_counts(entry[:purchase_outcomes])}"
        end

        puts "  Missing outcome telemetry: #{entry[:missing_outcomes].join(', ')}" unless entry[:missing_outcomes].empty?
        puts
      end
    end

    def format_event_counts(counts)
      counts.sort.map { |event, count| "#{event}=#{count}" }.join(', ')
    end
  end
end
