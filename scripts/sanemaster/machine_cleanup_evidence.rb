# frozen_string_literal: true

module SaneMasterModules
  module MachineCleanupEvidence
    SERVER_EVIDENCE_BUCKETS = %w[apps infra websites clients mcp].freeze
    SERVER_EVIDENCE_RETENTION = {
      'verify' => 5,
      'monitor-tests' => 8
    }.freeze
    SERVER_EVIDENCE_RECENT_SECONDS = 2 * 60 * 60
    SERVER_EVIDENCE_RUN_NAME = /\A\d{8}T\d{6}(?:\.\d+)?Z(?:-.+)?\z/

    private

    def machine_cleanup_evidence_targets(active, options, pressure)
      return [] unless running_on_mini_host? && pressure

      blocking = machine_cleanup_server_blocking_flags(active) & %i[
        process_scan_failed
        xcodebuild_active
        simulator_active
        workflow_active
      ]
      unless blocking.empty?
        return [{
          type: 'skip', category: 'generated_evidence',
          reason: "Generated-evidence retention skipped while app test work is active or unknown: #{blocking.join(', ')}"
        }]
      end

      protected_apps = machine_cleanup_protected_apps(active, options)
      server_evidence_lane_roots.flat_map do |lane_root|
        server_evidence_lane_targets(lane_root, protected_apps)
      end
    end

    def server_evidence_lane_roots
      SERVER_EVIDENCE_BUCKETS.flat_map do |bucket|
        Dir.glob(File.expand_path("~/SaneApps/#{bucket}/**/outputs/{#{SERVER_EVIDENCE_RETENTION.keys.join(',')}}"))
      rescue SystemCallError
        []
      end.select { |path| Dir.exist?(path) && !cleanup_path_uses_symlink?(path) }.uniq
    end

    def server_evidence_lane_targets(lane_root, protected_apps = [])
      repo_root = lane_root.split('/outputs/', 2).first
      if protected_apps.include?(File.basename(repo_root))
        return [{
          type: 'skip', category: 'generated_evidence', path: lane_root,
          reason: "Generated evidence preserved for active or explicitly protected app #{File.basename(repo_root)}."
        }]
      end

      keep_count = SERVER_EVIDENCE_RETENTION.fetch(File.basename(lane_root))
      runs = Dir.children(lane_root).filter_map do |name|
        next unless name.match?(SERVER_EVIDENCE_RUN_NAME)

        path = File.join(lane_root, name)
        next unless File.directory?(path)
        next if cleanup_path_uses_symlink?(path)

        { name: name, path: path, mtime: server_evidence_run_mtime(path) }
      rescue SystemCallError
        nil
      end
      return [] if runs.length <= keep_count

      referenced = server_evidence_referenced_names(repo_root, runs.map { |run| run[:name] })
      recent_cutoff = Time.now - SERVER_EVIDENCE_RECENT_SECONDS
      protected = runs.sort_by { |run| -run[:mtime].to_f }.first(keep_count).map { |run| run[:name] }
      protected.concat(runs.select { |run| run[:mtime] >= recent_cutoff }.map { |run| run[:name] })
      protected.concat(referenced)
      protected.uniq!

      runs.flat_map do |run|
        next [] if protected.include?(run[:name])

        server_evidence_disposable_artifacts(run[:path]).filter_map do |artifact|
          size_gb = path_size_gb(artifact)
          next if size_gb <= 0.0

          {
            type: 'trash_path', category: 'generated_evidence', path: artifact,
            size_gb: size_gb,
            reason: "Disk pressure: retain receipts/logs, newest #{keep_count} full runs, recent runs, and runs named in project docs."
          }
        end
      end
    rescue SystemCallError
      []
    end

    def server_evidence_run_mtime(run_path)
      paths = [run_path] + Dir.children(run_path).map { |name| File.join(run_path, name) }
      paths.map { |path| File.mtime(path) }.max
    rescue SystemCallError
      Time.now
    end

    def server_evidence_disposable_artifacts(run_path)
      Dir.children(run_path)
         .select { |name| name == 'DerivedData' || name.end_with?('.xcresult') }
         .map { |name| File.join(run_path, name) }
         .select { |path| File.exist?(path) && !cleanup_path_uses_symlink?(path) }
    rescue SystemCallError
      []
    end

    def server_evidence_referenced_names(repo_root, names)
      docs = %w[AGENTS.md README.md DEVELOPMENT.md ARCHITECTURE.md SESSION_HANDOFF.md]
      text = docs.filter_map do |name|
        path = File.join(repo_root, name)
        File.file?(path) ? File.read(path, mode: 'r:BOM|UTF-8') : nil
      rescue SystemCallError, EncodingError
        nil
      end.join("\n")
      names.select { |name| text.include?(name) }
    end

    def server_evidence_artifact_path?(path)
      run = File.dirname(path)
      lane = File.dirname(run)
      lane_name = File.basename(lane)
      return false unless SERVER_EVIDENCE_RETENTION.key?(lane_name)
      return false unless File.basename(File.dirname(lane)) == 'outputs'
      return false unless File.basename(run).match?(SERVER_EVIDENCE_RUN_NAME)
      return false unless File.basename(path) == 'DerivedData' || File.basename(path).end_with?('.xcresult')

      SERVER_EVIDENCE_BUCKETS.any? do |bucket|
        bucket_root = File.expand_path("~/SaneApps/#{bucket}")
        lane.start_with?("#{bucket_root}/")
      end
    end
  end
end
