# frozen_string_literal: true

module SaneMasterModules
  module MachineCleanupArtifacts
    SERVER_CLEANUP_BLOCKING_ACTIVE_FLAGS = %i[
      process_scan_failed
      xcodebuild_active
      simulator_active
      workflow_active
      training_active
      codex_gui_active
    ].freeze
    CLEANUP_SAFE_ROOTS = [
      '~/.Trash',
      '~/.cache',
      '~/Library/Caches',
      '~/Library/Developer/Xcode/DerivedData'
    ].freeze
    SERVER_GENERATED_DIR_NAMES = %w[
      .build
      .swiftpm
      .venv
      .venv-local
      .worktrees
      .wrangler
      build
      node_modules
      releases
      xcuserdata
    ].freeze
    SERVER_GENERATED_RELATIVE_PATHS = (SERVER_GENERATED_DIR_NAMES + ['vendor/bundle']).freeze
    SERVER_CHILD_CLEANUP_PATHS = ['~/tmp'].freeze
    SERVER_REPO_ROOTS = [
      '~/SaneApps/apps',
      '~/SaneApps/infra',
      '~/SaneApps-automation/apps',
      '~/SaneApps-automation/infra'
    ].freeze
    SERVER_EXACT_CLEANUP_PATHS = [
      '~/Documents/huggingface',
      '~/Dev/TZPaintStudio',
      '~/SaneApps-setapp-verify',
      '~/SaneApps/release-work',
      '~/SaneApps/release-publish',
      '~/SaneApps/release-worktrees',
      '~/SaneApps/tmp',
      '~/SaneApps/scratch',
      '~/SaneApps/outputs/setapp_review',
      '~/SaneApps/outputs/automation-smoke',
      '~/SaneApps-automation/release-work',
      '~/SaneApps-automation/release-publish',
      '~/SaneApps-automation/release-worktrees',
      '~/scratch',
      '~/abtest-scratch',
      '~/tmp_sanebar_release',
      '~/tmp_sanebar_upgrade',
      '~/.tmp_saneclip_upgrade_dd_v222',
      '~/.tmp_saneclip_upgrade_dd_v223',
      '~/.tmp_saneclip_upgrade_install',
      '~/.codex/tmp',
      '~/.codex/.tmp',
      '~/.sanemaster/routed-workspaces',
      '~/Library/Developer/XcodeBuildMCP/workspaces',
      '~/Desktop/SaneClick-E2E*',
      '~/Desktop/SaneClick-Categories*',
      '~/Users',
      '~/SaneApps/Users',
      '~/$HOME',
      '~/LemonSqueezy-Uploads',
      '~/shot',
      '~/memory-bakeoff',
      '~/sanebar-recovery-*',
      '~/sanecite-build'
    ].freeze
    SERVER_EXPENSIVE_EXACT_PATHS = [
      '~/.npm/_npx',
      '~/.npm/_cacache'
    ].freeze
    SERVER_CODE_SIGN_CLONE_GLOBS = [
      '/private/var/folders/*/*/X/com.openai.codex.code_sign_clone',
      '/System/Volumes/Data/private/var/folders/*/*/X/com.openai.codex.code_sign_clone'
    ].freeze
    SERVER_DESKTOP_EMAIL_MEDIA_GLOBS = [
      '~/Desktop/email-review-media*',
      '~/Desktop/email*-linked-media*',
      '~/Desktop/Screenshots/email-review-media*',
      '~/Desktop/Screenshots/email*-linked-media*',
      '~/Desktop/Screenshots/email[0-9]*'
    ].freeze

    private

    def machine_cleanup_server_targets(active, options, pressure = true)
      return [] unless options[:server]

      blocking_flags = machine_cleanup_server_blocking_flags(active)
      unless blocking_flags.empty?
        return [{
          type: 'skip',
          category: 'server_generated_artifacts',
          reason: "Server-mode cleanup skipped generated artifact pruning because active work is visible: #{blocking_flags.join(', ')}"
        }]
      end

      protected_apps = machine_cleanup_protected_apps(active, options)
      targets = server_expensive_cleanup_targets(pressure)
      targets.concat(server_child_cleanup_targets)
      targets.concat(server_exact_cleanup_targets(protected_apps))
      targets.concat(server_codex_cleanup_targets(active))
      targets.concat(server_desktop_email_cleanup_targets)
      targets.concat(server_repo_generated_cleanup_targets(protected_apps))
      targets
    end

    def server_expensive_cleanup_targets(pressure)
      server_expensive_exact_paths.filter_map do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        {
          type: pressure ? 'trash_path' : 'skip',
          category: 'server_expensive_cache',
          path: path,
          size_gb: size_gb,
          reason: pressure ?
            'Disk pressure: reclaiming npm/npx caches; locked CLIs will reinstall on next use.' :
            'npm/npx caches preserved because free space is healthy.'
        }
      end
    end

    def server_child_cleanup_targets
      server_child_cleanup_paths.filter_map do |path|
        next unless Dir.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        {
          type: 'trash_children', category: 'server_generated_artifacts', path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: clear generated children without moving the protected root.'
        }
      end
    end

    def server_exact_cleanup_targets(protected_apps = [])
      server_exact_cleanup_paths.filter_map do |path|
        next unless File.exist?(path)
        next if protected_apps.include?(server_repo_app_name(path))

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        {
          type: 'trash_path', category: 'server_generated_artifacts', path: path,
          size_gb: size_gb, reason: 'Server-mode cleanup: disposable Mini artifact/cache/output path.'
        }
      end
    end

    def server_codex_cleanup_targets(active)
      if active[:codex_gui_active]
        return [{
          type: 'skip', category: 'server_codex_residue',
          reason: 'Codex GUI is active; skipping code-sign clone cleanup until Codex is closed.'
        }]
      end

      server_codex_code_sign_clone_paths.filter_map do |path|
        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        {
          type: 'trash_path', category: 'server_codex_residue', path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: stale Codex code-sign clone residue.'
        }
      end
    end

    def server_desktop_email_cleanup_targets
      server_desktop_email_media_paths.filter_map do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.0

        {
          type: 'trash_path', category: 'server_desktop_email_media', path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: reviewed email media must not remain on the Mini Desktop.'
        }
      end
    end

    def server_repo_generated_cleanup_targets(protected_apps = [])
      server_repo_generated_paths.filter_map do |path|
        next unless File.exist?(path)
        next if protected_apps.include?(server_repo_app_name(path))

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        {
          type: 'trash_path', category: 'server_repo_generated_artifacts', path: path,
          size_gb: size_gb, reason: 'Server-mode cleanup: generated repo artifact; source stays intact.'
        }
      end
    end

    def machine_cleanup_server_blocking_flags(active)
      SERVER_CLEANUP_BLOCKING_ACTIVE_FLAGS.select { |flag| active[flag] }
    end

    def machine_cleanup_protected_apps(active, options)
      (active.fetch(:apps, {}).keys + Array(options[:preserve_apps])).uniq
    end

    def server_repo_app_name(path)
      apps_root = File.expand_path('~/SaneApps/apps')
      return nil unless File.expand_path(path).start_with?("#{apps_root}/")

      File.expand_path(path).delete_prefix("#{apps_root}/").split(File::SEPARATOR).first
    end

    def machine_cleanup_safe_path?(path)
      expanded = File.expand_path(path)
      return false if cleanup_path_uses_symlink?(expanded)
      return true if CLEANUP_SAFE_ROOTS.any? { |raw| expanded == File.expand_path(raw) || expanded.start_with?("#{File.expand_path(raw)}/") }
      return true if server_exact_cleanup_path?(expanded)
      return true if layout_litter_path_allowed?(expanded)
      return true if server_expensive_exact_paths.include?(expanded)
      return true if server_child_cleanup_paths.include?(expanded)
      return true if server_desktop_email_media_path?(expanded)
      return true if server_codex_code_sign_clone_path?(expanded)
      return true if respond_to?(:server_evidence_artifact_path?, true) && server_evidence_artifact_path?(expanded)

      server_repo_generated_path?(expanded)
    end

    def layout_litter_path_allowed?(path)
      expanded = File.expand_path(path)
      return true if layout_litter_paths.any? { |allowed| expanded == allowed }

      SaneMasterModules::MachineCleanup::LAYOUT_LITTER_PATHS.any? do |raw|
        raw.match?(/[*?\[]/) && File.fnmatch?(File.expand_path(raw), expanded, File::FNM_PATHNAME)
      end
    end

    def cleanup_path_uses_symlink?(path)
      current = path
      home = File.expand_path('~')
      boundary = path == home || path.start_with?("#{home}/") ? home : File.dirname(path)
      loop do
        return true if File.symlink?(current)
        break if current == boundary

        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      false
    rescue SystemCallError
      true
    end

    def server_child_cleanup_paths
      SERVER_CHILD_CLEANUP_PATHS.map { |path| File.expand_path(path) }
    end

    def server_exact_cleanup_paths
      SERVER_EXACT_CLEANUP_PATHS.flat_map do |raw|
        expanded = File.expand_path(raw)
        raw.match?(/[*?\[]/) ? Dir.glob(expanded) : [expanded]
      rescue SystemCallError
        []
      end.uniq
    end

    def server_exact_cleanup_path?(path)
      return true if server_exact_cleanup_paths.include?(File.expand_path(path))

      SERVER_EXACT_CLEANUP_PATHS.any? do |raw|
        raw.match?(/[*?\[]/) && File.fnmatch?(File.expand_path(raw), File.expand_path(path), File::FNM_PATHNAME)
      end
    end

    def server_expensive_exact_paths
      SERVER_EXPENSIVE_EXACT_PATHS.map { |path| File.expand_path(path) }
    end

    def server_codex_code_sign_clone_paths
      SERVER_CODE_SIGN_CLONE_GLOBS.flat_map { |glob| Dir.glob(glob) }.uniq
    end

    def server_codex_code_sign_clone_path?(path)
      expanded = File.expand_path(path)
      SERVER_CODE_SIGN_CLONE_GLOBS.any? do |glob|
        prefix = glob.split('*').first
        suffix = glob.split('*').last
        expanded.start_with?(File.expand_path(prefix)) && expanded.end_with?(suffix)
      end
    end

    def server_desktop_email_media_paths
      SERVER_DESKTOP_EMAIL_MEDIA_GLOBS.flat_map { |raw| Dir.glob(File.expand_path(raw)) }
                                     .uniq
    rescue SystemCallError
      []
    end

    def server_desktop_email_media_path?(path)
      expanded = File.expand_path(path)
      desktop = File.expand_path('~/Desktop')
      return false unless expanded.start_with?("#{desktop}/")

      basename = File.basename(expanded)
      basename.match?(/\Aemail-review-media/) ||
        basename.match?(/\Aemail.*-linked-media/) ||
        basename.match?(/\Aemail[0-9]+(?:\..+)?\z/)
    end

    def server_repo_generated_paths
      SERVER_REPO_ROOTS.flat_map do |raw_root|
        root = File.expand_path(raw_root)
        next [] unless Dir.exist?(root)

        Dir.children(root).flat_map do |repo_name|
          repo_root = File.join(root, repo_name)
          next [] unless File.directory?(repo_root)

          patterns = SERVER_GENERATED_RELATIVE_PATHS.map { |relative| File.join(repo_root, relative) }
          patterns.concat(SERVER_GENERATED_DIR_NAMES.map { |name| File.join(repo_root, '*', name) })
          patterns.flat_map { |pattern| Dir.glob(pattern) }.select { |candidate| File.directory?(candidate) }
        end
      end.uniq
    end

    def server_repo_generated_path?(path)
      expanded = File.expand_path(path)
      SERVER_REPO_ROOTS.any? do |raw_root|
        root = File.expand_path(raw_root)
        next false unless expanded.start_with?("#{root}/")

        parts = expanded.delete_prefix("#{root}/").split(File::SEPARATOR)
        next false if parts.length < 2

        repo_relative = parts[1..].join(File::SEPARATOR)
        SERVER_GENERATED_RELATIVE_PATHS.include?(repo_relative) ||
          (parts.length == 3 && SERVER_GENERATED_DIR_NAMES.include?(parts[2])) ||
          (parts.length == 4 && parts[2] == 'vendor' && parts[3] == 'bundle')
      end
    end

  end
end
