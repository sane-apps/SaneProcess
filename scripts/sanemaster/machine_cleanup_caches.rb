# frozen_string_literal: true

module SaneMasterModules
  module MachineCleanupCaches
    private

    def machine_cleanup_cache_targets(options, pressure = true)
      expensive_paths = SaneMasterModules::MachineCleanup::EXPENSIVE_RESTORE_CACHE_PATHS
      cache_paths = SaneMasterModules::MachineCleanup::DISPOSABLE_CACHE_PATHS
      expensive = expensive_paths.map { |raw| File.expand_path(raw) }
      skips = []
      targets = cache_paths.each_with_object([]) do |raw_path, list|
        path = File.expand_path(raw_path)
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0

        if !pressure && expensive.include?(path)
          skips << {
            type: 'skip', category: 'expensive_cache_preserved', path: path, size_gb: size_gb,
            reason: "Expensive-to-restore cache preserved while free space is healthy: #{size_gb}G."
          }
          next
        end
        next if size_gb < 0.25 && total_disposable_cache_gb < options[:cache_threshold_gb]

        list << {
          type: 'trash_path', category: 'disposable_cache', path: path, size_gb: size_gb,
          reason: 'Disposable developer cache; safe to regenerate.'
        }
      end
      targets.concat(machine_cleanup_uv_cache_targets)
      return skips if targets.sum { |target| target[:size_gb].to_f } < options[:cache_threshold_gb]

      skips + targets
    end

    def machine_cleanup_uv_cache_targets
      targets = []
      uv_root = File.expand_path('~/.cache/uv')
      if Dir.exist?(uv_root)
        tmp_dirs = Dir.glob(File.join(uv_root, '.tmp*')).select { |path| File.directory?(path) }
        tmp_size = tmp_dirs.sum { |path| path_size_gb(path) }.round(2)
        if tmp_size > 0.01
          targets << {
            type: 'trash_matching_children', category: 'uv_temp_cache', path: uv_root,
            pattern: '.tmp*', size_gb: tmp_size,
            reason: 'Stale uv temporary environments from interrupted Python tooling.'
          }
        end
      end

      archive_root = File.join(uv_root, 'archive-v0')
      if Dir.exist?(archive_root)
        active_names = machine_cleanup_active_uv_archive_names
        stale_dirs = Dir.children(archive_root).map { |entry| File.join(archive_root, entry) }
                         .select { |path| File.directory?(path) && !active_names.include?(File.basename(path)) }
        stale_size = stale_dirs.sum { |path| path_size_gb(path) }.round(2)
        if stale_size > 0.01
          targets << {
            type: 'trash_matching_children', category: 'uv_archive_cache', path: archive_root,
            pattern: '*', except_names: active_names, size_gb: stale_size,
            reason: 'Inactive uvx archive environments; active process archives stay.'
          }
        end
      end
      targets
    end

    def machine_cleanup_active_uv_archive_names
      machine_cleanup_ps_rows.each_with_object([]) do |row, names|
        row[:command].to_s.scan(%r{\.cache/uv/archive-v0/([^/\s]+)}) { |match| names << match.first }
      end.uniq
    end

    def total_disposable_cache_gb
      paths = SaneMasterModules::MachineCleanup::DISPOSABLE_CACHE_PATHS
      @total_disposable_cache_gb ||= paths.sum do |raw_path|
        path = File.expand_path(raw_path)
        File.exist?(path) ? path_size_gb(path) : 0.0
      end
    end
  end
end
