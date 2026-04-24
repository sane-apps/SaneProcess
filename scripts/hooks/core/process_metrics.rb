# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module SaneProcessMetrics
  DEFAULT_PATH = File.expand_path('~/.sanemaster/process_metrics.jsonl')

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
    File.open(path, 'a') { |file| file.puts(JSON.generate(event)) }
    true
  rescue StandardError => e
    warn "⚠️  Could not record process metric: #{e.message}" if ENV['DEBUG']
    false
  end

  def metrics_path
    ENV['SANEMASTER_PROCESS_METRICS_PATH'] || DEFAULT_PATH
  end

  def metric_project_name
    project_dir = ENV['CLAUDE_PROJECT_DIR']
    return File.basename(project_dir) if project_dir && !project_dir.empty?

    File.basename(Dir.pwd)
  end
end
