# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module SaneProcessMetrics
  DEFAULT_PATH = File.expand_path('~/.sanemaster/process_metrics.jsonl')
  DEFAULT_MAX_BYTES = 6 * 1024 * 1024
  DEFAULT_ROTATE_KEEP = 3

  module_function

  def record(type, payload = {})
    event = {
      timestamp: Time.now.utc.iso8601,
      project: metric_project_name,
      cwd: Dir.pwd,
      type: type.to_s
    }.merge(payload)

    path = metrics_path
    FileUtils.mkdir_p(File.dirname(path))
    rotate_if_needed(path)
    File.open(path, 'a') { |file| file.puts(JSON.generate(event)) }
    true
  rescue StandardError => e
    warn "⚠️  Could not record process metric: #{e.message}" if ENV['DEBUG']
    false
  end

  def metrics_path
    ENV['SANEMASTER_PROCESS_METRICS_PATH'] || DEFAULT_PATH
  end

  def rotate_if_needed(path)
    return if ENV['SANEMASTER_PROCESS_METRICS_ROTATE_DISABLE'] == '1'

    max_bytes = positive_integer_env('SANEMASTER_PROCESS_METRICS_MAX_BYTES', DEFAULT_MAX_BYTES)
    return if max_bytes <= 0
    return unless File.exist?(path) && File.size(path) >= max_bytes

    keep = positive_integer_env('SANEMASTER_PROCESS_METRICS_ROTATE_KEEP', DEFAULT_ROTATE_KEEP)
    keep = 1 if keep < 1

    keep.downto(1) do |index|
      source = index == 1 ? path : "#{path}.#{index - 1}"
      target = "#{path}.#{index}"
      next unless File.exist?(source)

      FileUtils.rm_f(target)
      FileUtils.mv(source, target)
    end
  end

  def positive_integer_env(name, fallback)
    Integer(ENV.fetch(name, fallback.to_s))
  rescue ArgumentError
    fallback
  end

  def mini_or_structured_fallback?(event)
    host = event['host'].to_s.downcase
    return true if host.include?('mini')

    fallback = event['local_fallback'] || event['fallback_approval'] || event['mini_fallback']
    return false unless fallback.is_a?(Hash)

    fallback['approved'] == true &&
      !fallback['approved_by'].to_s.strip.empty? &&
      !fallback['reason'].to_s.strip.empty? &&
      !fallback['user_quote'].to_s.strip.empty?
  end

  def authoritative_verify_event?(event, require_source_fingerprint: false)
    return false unless event['type'].to_s == 'verify'
    return false unless event['success'] == true
    return false unless event['tests_run'].to_i.positive?
    return false if event['evidence_strength'].to_s == 'build_only'
    return false unless mini_or_structured_fallback?(event)

    if require_source_fingerprint
      fingerprint = event['source_fingerprint'].to_s
      return false if fingerprint.empty? || fingerprint == 'unknown'
    end

    true
  end

  def metric_project_name
    project_dir = ENV['CLAUDE_PROJECT_DIR']
    return File.basename(project_dir) if project_dir && !project_dir.empty?

    File.basename(Dir.pwd)
  end
end
