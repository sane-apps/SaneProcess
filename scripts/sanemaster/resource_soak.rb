# frozen_string_literal: true

require 'json'
require 'open3'
require 'time'

module SaneMasterModules
  module ResourceSoak
    RESOURCE_SOAK_JSON = '/tmp/sanebar_runtime_resource_soak.json'
    RESOURCE_SOAK_LOG = '/tmp/sanebar_runtime_resource_soak.log'
    RESOURCE_SOAK_MIN_SECONDS = 20 * 60
    RESOURCE_SOAK_DEFAULT_INTERVAL_SECONDS = 15
    RESOURCE_SOAK_MAX_AVG_CPU = 5.0
    RESOURCE_SOAK_MAX_RSS_GROWTH_MB = 128.0
    RESOURCE_SOAK_MAX_PHYS_GROWTH_MB = 128.0

    def resource_soak(args = [])
      args = args.dup
      duration = extract_resource_soak_value(args, '--duration')&.to_i || RESOURCE_SOAK_MIN_SECONDS
      interval = extract_resource_soak_value(args, '--interval')&.to_i || RESOURCE_SOAK_DEFAULT_INTERVAL_SECONDS
      app_path = extract_resource_soak_value(args, '--app-path') || "/Applications/#{project_name}.app"
      allow_short = args.delete('--allow-short')
      json_output = args.delete('--json')

      if duration < RESOURCE_SOAK_MIN_SECONDS && !allow_short
        warn "resource_soak requires at least #{RESOURCE_SOAK_MIN_SECONDS}s unless --allow-short is used"
        return false
      end

      unless File.directory?(app_path)
        warn "App bundle not found: #{app_path}"
        return false
      end

      pid = resource_soak_pid_for_app(app_path) || resource_soak_launch_and_wait(app_path)
      unless pid
        warn "Could not find running app process for #{app_path}"
        return false
      end

      metadata = resource_soak_app_metadata(app_path)
      started_at = Time.now
      deadline = started_at + duration
      samples = []
      File.open(RESOURCE_SOAK_LOG, 'w') do |log|
        log.puts "app_path=#{app_path}"
        log.puts "pid=#{pid}"
        log.puts "version=#{metadata[:version]}"
        log.puts "build=#{metadata[:build]}"
        log.puts "started_at=#{started_at.utc.iso8601}"
        log.puts "duration_seconds=#{duration}"
        log.puts "interval_seconds=#{interval}"
        log.flush

        while Time.now < deadline
          current_pid = resource_soak_pid_for_app(app_path)
          if current_pid != pid
            log.puts "process_changed_at=#{Time.now.utc.iso8601} old=#{pid} new=#{current_pid || 'missing'}"
            break
          end

          sample = resource_soak_sample(pid)
          samples << sample if sample
          if sample
            log.puts [
              sample[:timestamp],
              "cpu=#{format('%.2f', sample[:cpu_percent])}",
              "rss_mb=#{format('%.1f', sample[:rss_mb])}",
              "phys_mb=#{sample[:physical_footprint_mb] ? format('%.1f', sample[:physical_footprint_mb]) : 'unavailable'}"
            ].join(' ')
            log.flush
          end
          sleep [interval, (deadline - Time.now)].min if Time.now < deadline
        end
      end

      payload = resource_soak_payload(
        app_path: app_path,
        metadata: metadata,
        started_at: started_at,
        completed_at: Time.now,
        duration: duration,
        interval: interval,
        samples: samples
      )
      File.write(RESOURCE_SOAK_JSON, JSON.pretty_generate(payload))

      if json_output
        puts JSON.pretty_generate(payload)
      else
        puts "Resource soak #{payload[:status]}: samples=#{samples.length} avgCpu=#{payload[:metrics][:avg_cpu_percent]} rssGrowth=#{payload[:metrics][:rss_growth_mb]}MB physGrowth=#{payload[:metrics][:physical_footprint_growth_mb]}MB"
        puts "JSON: #{RESOURCE_SOAK_JSON}"
        puts "Log: #{RESOURCE_SOAK_LOG}"
      end

      payload[:status] == 'pass'
    end

    private

    def extract_resource_soak_value(args, flag)
      index = args.index(flag)
      return nil unless index

      args.delete_at(index)
      value = args.delete_at(index)
      raise ArgumentError, "#{flag} requires a value" if value.to_s.strip.empty?

      value
    end

    def resource_soak_launch_and_wait(app_path)
      system('open', app_path, out: File::NULL, err: File::NULL)
      deadline = Time.now + 20
      while Time.now < deadline
        pid = resource_soak_pid_for_app(app_path)
        return pid if pid

        sleep 0.5
      end
      nil
    end

    def resource_soak_pid_for_app(app_path)
      process_path = File.join(app_path, 'Contents', 'MacOS', File.basename(app_path, '.app'))
      output, status = Open3.capture2e('ps', '-axo', 'pid=,command=')
      return nil unless status.success?

      line = output.lines.find { |candidate| candidate.include?(process_path) }
      line&.split&.first&.to_i
    end

    def resource_soak_sample(pid)
      output, status = Open3.capture2e('ps', '-p', pid.to_s, '-o', '%cpu=,rss=')
      return nil unless status.success?

      cpu, rss = output.split
      return nil unless cpu && rss

      {
        timestamp: Time.now.utc.iso8601,
        cpu_percent: cpu.to_f,
        rss_mb: rss.to_f / 1024.0,
        physical_footprint_mb: resource_soak_physical_footprint_mb(pid)
      }
    end

    def resource_soak_physical_footprint_mb(pid)
      output, status = Open3.capture2e('/usr/bin/footprint', '-p', pid.to_s, '-summary')
      return nil unless status.success?

      line = output.lines.find { |entry| entry.include?('phys_footprint:') }
      return nil unless line

      match = line.match(/phys_footprint:\s+([\d.]+)\s+([KMG]B)/)
      return nil unless match

      value = match[1].to_f
      case match[2]
      when 'KB' then value / 1024.0
      when 'GB' then value * 1024.0
      else value
      end
    rescue StandardError
      nil
    end

    def resource_soak_app_metadata(app_path)
      plist = File.join(app_path, 'Contents', 'Info.plist')
      {
        version: resource_soak_plist_value(plist, 'CFBundleShortVersionString'),
        build: resource_soak_plist_value(plist, 'CFBundleVersion')
      }
    end

    def resource_soak_plist_value(plist, key)
      output, status = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", plist)
      return nil unless status.success?

      output.strip
    end

    def resource_soak_payload(app_path:, metadata:, started_at:, completed_at:, duration:, interval:, samples:)
      avg_cpu = samples.empty? ? nil : samples.sum { |sample| sample[:cpu_percent] } / samples.length
      rss_values = samples.map { |sample| sample[:rss_mb] }
      phys_values = samples.map { |sample| sample[:physical_footprint_mb] }.compact
      rss_growth = rss_values.empty? ? nil : rss_values.last - rss_values.first
      phys_growth = phys_values.empty? ? nil : phys_values.last - phys_values.first
      passed = duration >= RESOURCE_SOAK_MIN_SECONDS &&
               !samples.empty? &&
               avg_cpu && avg_cpu <= RESOURCE_SOAK_MAX_AVG_CPU &&
               rss_growth && rss_growth <= RESOURCE_SOAK_MAX_RSS_GROWTH_MB &&
               phys_growth && phys_growth <= RESOURCE_SOAK_MAX_PHYS_GROWTH_MB

      {
        status: passed ? 'pass' : 'failed',
        evidence_types: %w[mini_runtime log state_receipt],
        evidence_paths: [RESOURCE_SOAK_LOG],
        completed_scenarios: [
          'at least 20m Mini soak sampled on the release candidate',
          'average CPU remains within idle budget',
          'RSS and physical footprint do not grow beyond the short-soak release budget'
        ],
        candidate: {
          app_path: app_path,
          app_version: metadata[:version],
          app_build: metadata[:build]
        },
        metrics: {
          started_at: started_at.utc.iso8601,
          completed_at: completed_at.utc.iso8601,
          duration_seconds: (completed_at - started_at).round(1),
          requested_duration_seconds: duration,
          interval_seconds: interval,
          sample_count: samples.length,
          avg_cpu_percent: avg_cpu&.round(3),
          rss_start_mb: rss_values.first&.round(1),
          rss_end_mb: rss_values.last&.round(1),
          rss_growth_mb: rss_growth&.round(1),
          physical_footprint_start_mb: phys_values.first&.round(1),
          physical_footprint_end_mb: phys_values.last&.round(1),
          physical_footprint_growth_mb: phys_growth&.round(1),
          max_avg_cpu_percent: RESOURCE_SOAK_MAX_AVG_CPU,
          max_rss_growth_mb: RESOURCE_SOAK_MAX_RSS_GROWTH_MB,
          max_physical_footprint_growth_mb: RESOURCE_SOAK_MAX_PHYS_GROWTH_MB
        },
        samples: samples
      }
    end
  end
end
