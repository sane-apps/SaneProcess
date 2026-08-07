# frozen_string_literal: true

require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'time'

module SaneMasterModules
  module MachineCleanup
    DEFAULT_MIN_FREE_GB = 30
    DEFAULT_CACHE_THRESHOLD_GB = 5
    DEFAULT_DERIVEDDATA_AGE_DAYS = 2
    DEFAULT_TRASH_THRESHOLD_GB = 1
    SERVER_CLEANUP_BLOCKING_ACTIVE_FLAGS = %i[xcodebuild_active simulator_active training_active codex_gui_active].freeze

    DISPOSABLE_CACHE_PATHS = [
      '~/.cache/huggingface',
      '~/.cache/codex-runtimes',
      '~/Library/Caches/com.openai.codex',
      '~/Library/Caches/ms-playwright',
      '~/Library/Caches/org.swift.swiftpm',
      '~/Library/Caches/Homebrew',
      '~/Library/Caches/pip',
      '~/Library/Caches/pnpm',
      '~/Library/Caches/node-gyp'
    ].freeze

    # Regenerating these costs real time (multi-GB downloads, flaky installers) while their
    # only benefit to cleanup is disk space — so they are cleaned ONLY under disk pressure
    # (available < --min-free-gb), never as routine hygiene. 2026-07-02: the nightly server
    # reset was wiping Playwright browsers, HuggingFace models, sim runtimes, and the npx
    # cache (the Mini's wrangler) daily with 80+ GB free.
    EXPENSIVE_RESTORE_CACHE_PATHS = [
      '~/.cache/huggingface',
      '~/.cache/codex-runtimes',
      '~/Library/Caches/ms-playwright'
    ].freeze
    SERVER_EXPENSIVE_EXACT_PATHS = [
      '~/.npm/_npx',
      '~/.npm/_cacache'
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
      '~/SaneApps/apps/SaneVideo/outputs',
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
      # Mini layout litter: also listed in LAYOUT_LITTER_PATHS for default (non-server) cleanup.
      # Globs (* ? []) are expanded by server_exact_cleanup_paths; Desktop LemonSqueezy-Uploads stays.
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
    # Mini layout litter: cleaned on every machine_cleanup (not only --server).
    # Nest dirs trash even when empty; Desktop LemonSqueezy-Uploads is NOT listed.
    LAYOUT_LITTER_PATHS = [
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
    LAYOUT_NEST_PATHS = [
      '~/Users',
      '~/SaneApps/Users',
      '~/$HOME'
    ].freeze
    SANE_APP_NAME_REGEX = /\b(SaneBar|SaneClip|SaneClick|SaneHosts|SaneSales|SaneSync|SaneVideo|SaneScan|SaneAI)\b/

    def machine_cleanup(args)
      original_args = args.dup
      options = parse_machine_cleanup_args(args)

      if options[:host] == 'mini' && !running_on_mini_host?
        return run_machine_cleanup_on_mini(original_args)
      end

      if options[:server] && options[:host] == 'local' && !running_on_mini_host?
        warn 'machine_cleanup --server is Mini-only. Use `machine_cleanup --host mini --server --apply` from the Air.'
        return false
      end

      plan = build_machine_cleanup_plan(options)

      if options[:json]
        puts JSON.pretty_generate(plan)
      else
        print_machine_cleanup_plan(plan)
      end

      return true unless options[:apply]

      result = apply_machine_cleanup_plan(plan, options)
      sweep_ghost_dock_tiles(options)
      puts JSON.pretty_generate(result) if options[:json]
      result[:success]
    end

    private

    # Ghost Dock tiles accumulate on the Mini when GUI/agent apps get
    # force-killed during build/test cleanup. Relaunching the Dock drops any
    # orphaned tiles; it's instant and non-destructive (the Dock auto-restarts).
    # Mini-only so we never disturb the Dock on the owner's workstation.
    def sweep_ghost_dock_tiles(options)
      return unless options[:apply]
      return unless running_on_mini_host?

      system('killall', 'Dock', out: File::NULL, err: File::NULL)
      warn '   🧹 Refreshed Dock to clear ghost app tiles' unless options[:json]
    end

    def parse_machine_cleanup_args(args)
      options = {
        apply: false,
        json: false,
        quiet: false,
        host: 'local',
        min_free_gb: DEFAULT_MIN_FREE_GB,
        cache_threshold_gb: DEFAULT_CACHE_THRESHOLD_GB,
        deriveddata_age_days: DEFAULT_DERIVEDDATA_AGE_DAYS,
        trash_threshold_gb: DEFAULT_TRASH_THRESHOLD_GB,
        preserve_apps: [],
        server: false
      }

      until args.empty?
        arg = args.shift
        case arg
        when '--apply'
          options[:apply] = true
        when '--dry-run'
          options[:apply] = false
        when '--json'
          options[:json] = true
        when '--quiet'
          options[:quiet] = true
        when '--host'
          options[:host] = args.shift.to_s
        when '--mini'
          options[:host] = 'mini'
        when '--local'
          options[:host] = 'local'
        when '--min-free-gb'
          options[:min_free_gb] = args.shift.to_f
        when '--cache-threshold-gb'
          options[:cache_threshold_gb] = args.shift.to_f
        when '--deriveddata-age-days'
          options[:deriveddata_age_days] = args.shift.to_i
        when '--trash-threshold-gb'
          options[:trash_threshold_gb] = args.shift.to_f
        when '--preserve-apps'
          options[:preserve_apps] = args.shift.to_s.split(',').map(&:strip).reject(&:empty?)
        when '--server', '--server-reset'
          options[:server] = true
        else
          raise ArgumentError, "Unknown machine_cleanup option: #{arg}"
        end
      end

      unless %w[local mini].include?(options[:host])
        raise ArgumentError, "machine_cleanup --host must be local or mini, got #{options[:host].inspect}"
      end

      options
    end

    def run_machine_cleanup_on_mini(args)
      remote_script = '~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb'
      forwarded = machine_cleanup_forwarded_args_for_mini(args)
      remote_args = ['machine_cleanup', '--host', 'local'] + forwarded
      remote_cmd = "cd ~/SaneApps/infra/SaneProcess && ruby #{remote_script} #{remote_args.map { |part| Shellwords.escape(part) }.join(' ')}"
      system('ssh', 'mini', remote_cmd)
    end

    def machine_cleanup_forwarded_args_for_mini(args)
      forwarded = []
      skip_next = false

      args.each do |arg|
        if skip_next
          skip_next = false
          next
        end

        case arg
        when '--host'
          skip_next = true
        when '--mini', 'mini'
          next
        else
          forwarded << arg
        end
      end

      forwarded
    end

    def build_machine_cleanup_plan(options)
      active = machine_cleanup_active_inventory
      disk = machine_cleanup_disk_snapshot
      pressure = machine_cleanup_disk_pressure?(disk, options)
      cache_targets = machine_cleanup_cache_targets(options, pressure)
      deriveddata_targets = machine_cleanup_deriveddata_targets(active, options)
      trash_target = machine_cleanup_trash_target(options)
      simulator_plan = machine_cleanup_simulator_plan(active, options, pressure)
      simulator_targets = simulator_plan.is_a?(Array) ? simulator_plan.compact : [simulator_plan].compact
      server_targets = machine_cleanup_server_targets(active, options, pressure)
      layout_targets = machine_cleanup_layout_litter_targets

      actions = []
      actions << trash_target if trash_target
      actions.concat(cache_targets)
      actions.concat(deriveddata_targets)
      actions.concat(simulator_targets)
      actions.concat(layout_targets)
      actions.concat(server_targets)
      actions = machine_cleanup_unique_actions(actions)

      {
        command: 'machine_cleanup',
        dry_run: !options[:apply],
        server: options[:server],
        host: Socket.gethostname,
        disk_pressure: pressure,
        thresholds: {
          min_free_gb: options[:min_free_gb],
          cache_threshold_gb: options[:cache_threshold_gb],
          deriveddata_age_days: options[:deriveddata_age_days],
          trash_threshold_gb: options[:trash_threshold_gb]
        },
        disk: disk,
        active: active,
        actions: actions,
        summary: machine_cleanup_summary(disk, active, actions)
      }
    end

    def machine_cleanup_active_inventory
      rows = machine_cleanup_ps_rows
      active = {
        apps: {},
        simulator_active: false,
        xcodebuild_active: false,
        training_active: false,
        codex_gui_active: false,
        mcp_processes: []
      }

      rows.each do |row|
        command = row[:command]
        command.scan(SANE_APP_NAME_REGEX).flatten.uniq.each do |app|
          active[:apps][app] ||= []
          active[:apps][app] << row
        end
        active[:simulator_active] ||= command.match?(/\b(simctl|launchd_sim)\b/) || command.include?('Simulator.app')
        active[:xcodebuild_active] ||= command.match?(/\bxcodebuild\b/)
        active[:training_active] ||= command.match?(/\b(mlx|train|training|finetune|inference)\b/i)
        active[:codex_gui_active] ||= command.include?('/Applications/Codex.app/Contents/MacOS/Codex') ||
                                      command.include?('Codex (Service)') ||
                                      command.include?('Codex (Renderer)')
        active[:mcp_processes] << row if command.match?(/\b(mcp|xcodebuildmcp)\b/i)
      end

      active[:apps] = active[:apps].transform_values { |list| list.first(5) }
      active[:mcp_processes] = active[:mcp_processes].first(10)
      active
    end

    def machine_cleanup_ps_rows
      output, status = Open3.capture2e('ps', '-axo', 'pid,ppid,pgid,stat,etime,command')
      return [] unless status.success?

      output.lines.drop(1).each_with_object([]) do |line, rows|
        parts = line.strip.split(/\s+/, 6)
        next if parts.length < 6

        rows << {
          pid: parts[0].to_i,
          ppid: parts[1].to_i,
          pgid: parts[2].to_i,
          stat: parts[3],
          etime: parts[4],
          command: parts[5].to_s
        }
      end
    end

    def machine_cleanup_disk_snapshot
      output, status = Open3.capture2e('df', '-k', File.expand_path('~'))
      return { ok: false, error: output.strip } unless status.success?

      fields = output.lines.last.to_s.split(/\s+/)
      size_kb = fields[1].to_i
      used_kb = fields[2].to_i
      avail_kb = fields[3].to_i
      capacity = fields[4].to_s
      {
        ok: true,
        size_gb: kb_to_gb(size_kb),
        used_gb: kb_to_gb(used_kb),
        available_gb: kb_to_gb(avail_kb),
        capacity: capacity,
        mount: fields[8] || fields[5]
      }
    end

    # Disk pressure = free space below --min-free-gb. Only then do expensive-to-restore
    # paths become fair game; a df failure counts as NO pressure so we never delete
    # slow-to-rebuild caches on bad telemetry.
    def machine_cleanup_disk_pressure?(disk, options)
      disk[:ok] == true && disk[:available_gb].to_f < options[:min_free_gb].to_f
    end

    def machine_cleanup_cache_targets(options, pressure = true)
      expensive = EXPENSIVE_RESTORE_CACHE_PATHS.map { |raw| File.expand_path(raw) }
      skips = []
      targets = DISPOSABLE_CACHE_PATHS.each_with_object([]) do |raw_path, list|
        path = File.expand_path(raw_path)
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0

        if !pressure && expensive.include?(path)
          skips << {
            type: 'skip',
            category: 'expensive_cache_preserved',
            path: path,
            size_gb: size_gb,
            reason: "Expensive-to-restore cache preserved: free space is above --min-free-gb, so the #{size_gb}G is not worth the re-download."
          }
          next
        end
        next if size_gb < 0.25 && total_disposable_cache_gb < options[:cache_threshold_gb]

        list << {
          type: 'trash_path',
          category: 'disposable_cache',
          path: path,
          size_gb: size_gb,
          reason: 'Disposable developer cache; safe to regenerate.'
        }
      end
      targets.concat(machine_cleanup_uv_cache_targets)

      total = targets.sum { |target| target[:size_gb].to_f }
      return skips if total < options[:cache_threshold_gb]

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
            type: 'trash_matching_children',
            category: 'uv_temp_cache',
            path: uv_root,
            pattern: '.tmp*',
            size_gb: tmp_size,
            reason: 'Stale uv temporary environments from interrupted Codex/MCP Python tooling.'
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
            type: 'trash_matching_children',
            category: 'uv_archive_cache',
            path: archive_root,
            pattern: '*',
            except_names: active_names,
            size_gb: stale_size,
            reason: 'Inactive uvx archive environments; active archive paths from running processes are preserved.'
          }
        end
      end

      targets
    end

    def machine_cleanup_active_uv_archive_names
      machine_cleanup_ps_rows.each_with_object([]) do |row, names|
        row[:command].to_s.scan(%r{\.cache/uv/archive-v0/([^/\s]+)}) do |match|
          names << match.first
        end
      end.uniq
    end

    def total_disposable_cache_gb
      @total_disposable_cache_gb ||= DISPOSABLE_CACHE_PATHS.sum do |raw_path|
        path = File.expand_path(raw_path)
        File.exist?(path) ? path_size_gb(path) : 0.0
      end
    end

    def machine_cleanup_deriveddata_targets(active, options)
      root = File.expand_path('~/Library/Developer/Xcode/DerivedData')
      return [] unless Dir.exist?(root)
      return [] if options[:server] && machine_cleanup_server_blocking_flags(active).any?

      active_apps = active.fetch(:apps, {}).keys + options[:preserve_apps]
      cutoff = Time.now - (options[:deriveddata_age_days].to_i * 86_400)

      Dir.children(root).each_with_object([]) do |entry, list|
        path = File.join(root, entry)
        next unless File.directory?(path)

        app = entry.split('-').first
        if active_apps.include?(app) && !options[:server]
          next
        end

        mtime = File.mtime(path) rescue Time.now
        next if mtime > cutoff && !options[:server]

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        list << {
          type: 'trash_path',
          category: options[:server] ? 'server_deriveddata' : 'inactive_deriveddata',
          path: path,
          size_gb: size_gb,
          reason: if options[:server]
                    'Server-mode cleanup: DerivedData is disposable on the Mini and must not accumulate between test runs.'
                  else
                    "DerivedData older than #{options[:deriveddata_age_days]} days and not tied to active app work."
                  end
        }
      end
    end

    def machine_cleanup_trash_target(options)
      trash = File.expand_path('~/.Trash')
      return nil unless Dir.exist?(trash)

      size_gb = path_size_gb(trash)
      return nil if size_gb < options[:trash_threshold_gb]

      {
        type: 'skip',
        category: 'trash',
        path: trash,
        size_gb: size_gb,
        reason: 'Trash exceeds threshold but is preserved; unattended cleanup never permanently deletes unrelated recoverable files.'
      }
    end

    def machine_cleanup_simulator_plan(active, options, pressure = true)
      if options[:server]
        blocking_flags = machine_cleanup_server_blocking_flags(active)
        unless blocking_flags.empty?
          return {
            type: 'skip',
            category: 'server_simulator',
            reason: "Server-mode simulator reset skipped because active work is visible: #{blocking_flags.join(', ')}"
          }
        end

        actions = [
          {
            type: 'command',
            category: 'server_simulator_shutdown',
            argv: %w[xcrun simctl shutdown all],
            reason: 'Server-mode cleanup: stop disposable simulator devices before deleting them.'
          },
          {
            type: 'command',
            category: 'server_simulator_delete',
            argv: %w[xcrun simctl delete all],
            reason: 'Server-mode cleanup: all simulator devices are disposable on the Mini and can be regenerated in seconds with simctl create.'
          },
          {
            type: 'command',
            category: 'server_simulator_unavailable',
            argv: %w[xcrun simctl delete unavailable],
            reason: 'Server-mode cleanup: remove unavailable simulator records after deleting devices.'
          }
        ]
        # Runtime disk images are multi-GB re-downloads (and the first capture on a fresh
        # runtime renders black PNGs) — only reclaim them under real disk pressure.
        if pressure
          actions << {
            type: 'command',
            category: 'server_simulator_runtime_delete',
            argv: [
              'sh',
              '-c',
              'xcrun simctl runtime list -v 2>/dev/null | grep -q "Total Disk Images: 0" && exit 0; xcrun simctl runtime delete all'
            ],
            reason: 'Disk pressure: free space is below --min-free-gb, reclaiming simulator runtime disk images.'
          }
        else
          actions << {
            type: 'skip',
            category: 'server_simulator_runtime_delete',
            reason: 'Simulator runtime disk images preserved: free space is above --min-free-gb and runtimes are slow multi-GB re-downloads.'
          }
        end
        return actions
      end

      {
        type: 'command',
        category: 'simulator',
        argv: %w[xcrun simctl delete unavailable],
        reason: 'Prune unavailable simulator devices only; does not shut down or delete active simulator work.'
      }
    end

    def machine_cleanup_layout_litter_targets
      targets = []
      layout_litter_paths.each do |path|
        next unless File.exist?(path)
        next unless machine_cleanup_safe_path?(path)

        size_gb = path_size_gb(path)
        nest = layout_nest_path?(path)
        next if !nest && size_gb <= 0.01

        targets << {
          type: 'trash_path',
          category: 'layout_litter',
          path: path,
          size_gb: size_gb,
          reason: nest ?
            'Layout litter: fake Air-path / literal $HOME nest (trash even when empty).' :
            'Layout litter: Desktop E2E temp or home-level project dump.'
        }
      end
      targets
    end

    def layout_litter_paths
      LAYOUT_LITTER_PATHS.flat_map do |raw|
        expanded = File.expand_path(raw)
        if raw.match?(/[*?\[]/)
          begin
            Dir.glob(expanded)
          rescue SystemCallError
            []
          end
        else
          [expanded]
        end
      end.uniq
    end

    def layout_nest_path?(path)
      expanded = File.expand_path(path)
      LAYOUT_NEST_PATHS.any? { |raw| expanded == File.expand_path(raw) }
    end

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

      targets = []
      server_expensive_exact_paths.each do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        if pressure
          targets << {
            type: 'trash_path',
            category: 'server_expensive_cache',
            path: path,
            size_gb: size_gb,
            reason: 'Disk pressure: free space is below --min-free-gb, reclaiming npm/npx caches (cached CLIs like wrangler/playwright will re-download on next use).'
          }
        else
          targets << {
            type: 'skip',
            category: 'server_expensive_cache',
            path: path,
            size_gb: size_gb,
            reason: 'npm/npx caches preserved: free space is above --min-free-gb and these hold the CLIs (wrangler, playwright) the Mini needs daily.'
          }
        end
      end
      server_child_cleanup_paths.each do |path|
        next unless Dir.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        targets << {
          type: 'trash_children',
          category: 'server_generated_artifacts',
          path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: clear contents of protected user folder without moving the folder itself.'
        }
      end

      server_exact_cleanup_paths.each do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        targets << {
          type: 'trash_path',
          category: 'server_generated_artifacts',
          path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: disposable Mini artifact/cache/output path.'
        }
      end

      if active[:codex_gui_active]
        targets << {
          type: 'skip',
          category: 'server_codex_residue',
          reason: 'Codex GUI is active; skipping code-sign clone cleanup until Codex is closed.'
        }
      else
        server_codex_code_sign_clone_paths.each do |path|
          size_gb = path_size_gb(path)
          next if size_gb <= 0.01

          targets << {
            type: 'trash_path',
            category: 'server_codex_residue',
            path: path,
            size_gb: size_gb,
            reason: 'Server-mode cleanup: stale Codex code-sign clone residue under /private/var/folders.'
          }
        end
      end

      server_desktop_email_media_paths.each do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.0

        targets << {
          type: 'trash_path',
          category: 'server_desktop_email_media',
          path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: downloaded email review media/signature assets must not stay on the Mini Desktop.'
        }
      end

      server_repo_generated_paths.each do |path|
        next unless File.exist?(path)

        size_gb = path_size_gb(path)
        next if size_gb <= 0.01

        targets << {
          type: 'trash_path',
          category: 'server_repo_generated_artifacts',
          path: path,
          size_gb: size_gb,
          reason: 'Server-mode cleanup: generated repo artifact; source files stay intact.'
        }
      end

      targets
    end

    def machine_cleanup_server_blocking_flags(active)
      SERVER_CLEANUP_BLOCKING_ACTIVE_FLAGS.select { |flag| active[flag] }
    end

    def machine_cleanup_summary(disk, active, actions)
      {
        available_gb: disk[:available_gb],
        active_apps: active.fetch(:apps, {}).keys.sort,
        action_count: actions.count { |action| action[:type] != 'skip' },
        skipped: actions.count { |action| action[:type] == 'skip' },
        reclaimable_gb: actions.select { |action| %w[trash_path trash_children trash_matching_children].include?(action[:type].to_s) }.sum { |action| action[:size_gb].to_f }.round(2)
      }
    end

    def machine_cleanup_unique_actions(actions)
      seen = {}
      actions.each_with_object([]) do |action, list|
        key = [action[:type], action[:category], action[:path], Array(action[:argv]).join("\0")]
        next if seen[key]

        seen[key] = true
        list << action
      end
    end

    def apply_machine_cleanup_plan(plan, options)
      applied = []
      failed = []

      plan.fetch(:actions, []).each do |action|
        case action[:type]
        when 'trash_path'
          if machine_cleanup_safe_path?(action[:path])
            if trash_path(action[:path])
              applied << action
            else
              failed << action.merge(error: 'trash command failed')
            end
          else
            failed << action.merge(error: 'path outside cleanup-safe roots')
          end
        when 'trash_children'
          if machine_cleanup_safe_path?(action[:path]) && trash_children(action[:path])
            applied << action
          else
            failed << action.merge(error: 'trash children failed')
          end
        when 'trash_matching_children'
          if machine_cleanup_safe_path?(action[:path]) && trash_matching_children(action[:path], action[:pattern], action.fetch(:except_names, []))
            applied << action
          else
            failed << action.merge(error: 'trash matching children failed')
          end
        when 'command'
          success = system(*action[:argv], out: options[:quiet] ? File::NULL : $stdout, err: options[:quiet] ? File::NULL : $stderr)
          success ? applied << action : failed << action.merge(error: 'command failed')
        end
      end

      {
        success: failed.empty?,
        applied_count: applied.length,
        failed_count: failed.length,
        failed: failed
      }
    end

    def machine_cleanup_safe_path?(path)
      expanded = File.expand_path(path)
      return false if cleanup_path_uses_symlink?(expanded)

      safe_root = CLEANUP_SAFE_ROOTS.any? do |raw_root|
        root = File.expand_path(raw_root)
        expanded == root || expanded.start_with?("#{root}/")
      end
      return true if safe_root

      return true if server_exact_cleanup_path?(expanded)
      return true if layout_litter_path_allowed?(expanded)
      return true if server_expensive_exact_paths.any? { |allowed| expanded == allowed }
      return true if server_child_cleanup_paths.any? { |allowed| expanded == allowed }
      return true if server_desktop_email_media_path?(expanded)
      return true if server_codex_code_sign_clone_path?(expanded)

      server_repo_generated_path?(expanded)
    end

    def layout_litter_path_allowed?(path)
      expanded = File.expand_path(path)
      return true if layout_litter_paths.any? { |allowed| expanded == allowed }

      LAYOUT_LITTER_PATHS.any? do |raw|
        next false unless raw.match?(/[*?\[]/)

        File.fnmatch?(File.expand_path(raw), expanded, File::FNM_PATHNAME)
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
        if raw.match?(/[*?\[]/)
          begin
            Dir.glob(expanded)
          rescue SystemCallError
            []
          end
        else
          [expanded]
        end
      end.uniq
    end

    def server_exact_cleanup_path?(path)
      expanded = File.expand_path(path)
      return true if server_exact_cleanup_paths.any? { |allowed| expanded == allowed }

      SERVER_EXACT_CLEANUP_PATHS.any? do |raw|
        next false unless raw.match?(/[*?\[]/)

        File.fnmatch?(File.expand_path(raw), expanded, File::FNM_PATHNAME)
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
      SERVER_DESKTOP_EMAIL_MEDIA_GLOBS.flat_map do |raw_glob|
        Dir.glob(File.expand_path(raw_glob))
      rescue SystemCallError
        []
      end.uniq
    end

    def server_desktop_email_media_path?(path)
      expanded = File.expand_path(path)
      desktop = File.expand_path('~/Desktop')
      screenshots = File.expand_path('~/Desktop/Screenshots')
      return false unless expanded.start_with?("#{desktop}/") || expanded.start_with?("#{screenshots}/")

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
          patterns.flat_map { |pattern| Dir.glob(pattern) }.select { |path| File.directory?(path) }
        end
      end.uniq
    end

    def server_repo_generated_path?(path)
      expanded = File.expand_path(path)
      SERVER_REPO_ROOTS.any? do |raw_root|
        root = File.expand_path(raw_root)
        next false unless expanded.start_with?("#{root}/")

        relative = expanded.delete_prefix("#{root}/")
        parts = relative.split(File::SEPARATOR)
        next false if parts.length < 2

        repo_relative = parts[1..].join(File::SEPARATOR)
        SERVER_GENERATED_RELATIVE_PATHS.include?(repo_relative) ||
          (parts.length == 3 && SERVER_GENERATED_DIR_NAMES.include?(parts[2])) ||
          (parts.length == 4 && parts[2] == 'vendor' && parts[3] == 'bundle')
      end
    end

    def trash_path(path)
      return true unless File.exist?(path)

      if File.executable?('/usr/bin/trash')
        system('/usr/bin/trash', path)
      elsif system('command', '-v', 'trash', out: File::NULL, err: File::NULL)
        system('trash', path)
      else
        warn "trash command is unavailable; refusing to delete #{path}"
        false
      end
    end

    def trash_children(path)
      return true unless Dir.exist?(path)

      Dir.children(path).all? do |entry|
        trash_path(File.join(path, entry))
      end
    end

    def trash_matching_children(path, pattern, except_names = [])
      return true unless Dir.exist?(path)

      Dir.glob(File.join(path, pattern)).all? do |child|
        next true if except_names.include?(File.basename(child))

        trash_path(child)
      end
    end

    def machine_cleanup_system_with_timeout(argv, seconds:)
      pid = Process.spawn(*argv, out: File::NULL, err: File::NULL)
      wait_thr = Process.detach(pid)
      return wait_thr.value.success? if wait_thr.join(seconds)

      Process.kill('TERM', pid)
      sleep 1
      Process.kill('KILL', pid) if wait_thr.alive?
      false
    rescue Errno::ESRCH, Errno::ECHILD
      false
    end

    def print_machine_cleanup_plan(plan)
      puts "Machine cleanup #{plan[:dry_run] ? 'dry-run' : 'apply'} on #{plan[:host]}"
      puts "Mode: #{plan[:server] ? 'server reset' : 'safe hygiene'}"
      puts "Disk: #{plan.dig(:disk, :available_gb)}G free (#{plan.dig(:disk, :capacity)} used) — #{plan[:disk_pressure] ? "UNDER PRESSURE (<#{plan.dig(:thresholds, :min_free_gb)}G): expensive caches eligible" : "healthy (≥#{plan.dig(:thresholds, :min_free_gb)}G): expensive-to-restore caches preserved"}"
      puts "Active apps preserved: #{plan.dig(:summary, :active_apps).join(', ').empty? ? 'none' : plan.dig(:summary, :active_apps).join(', ')}"
      puts "Reclaimable: #{plan.dig(:summary, :reclaimable_gb)}G across #{plan.dig(:summary, :action_count)} action(s)"
      puts

      plan.fetch(:actions, []).each do |action|
        label = action[:type] == 'skip' ? 'SKIP' : 'PLAN'
        size = action[:size_gb] ? " (#{action[:size_gb]}G)" : ''
        target = action[:path] || Array(action[:argv]).join(' ')
        puts "- #{label} #{action[:category]}#{size}: #{target}"
        puts "  #{action[:reason]}"
      end

      puts
      puts 'Dry-run only. Re-run with `--apply` to move planned paths to Trash; Trash itself is preserved.' if plan[:dry_run]
    end

    def path_size_gb(path)
      output, status = Open3.capture2e('du', '-sk', path)
      return 0.0 unless status.success?

      kb_to_gb(output.split(/\s+/).first.to_i)
    end

    def kb_to_gb(kb)
      (kb.to_f / 1024 / 1024).round(2)
    end
  end
end
