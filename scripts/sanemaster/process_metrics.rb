# frozen_string_literal: true

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

    private

    def safe_metric_project_name
      respond_to?(:project_name) ? project_name : File.basename(Dir.pwd)
    rescue StandardError
      File.basename(Dir.pwd)
    end
  end
end
