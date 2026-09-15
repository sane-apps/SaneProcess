# frozen_string_literal: true

require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'time'

require_relative 'machine_cleanup_artifacts'
require_relative 'machine_cleanup_apply'
require_relative 'machine_cleanup_caches'
require_relative 'machine_cleanup_evidence'
require_relative 'machine_cleanup_processes'

module SaneMasterModules
  module MachineCleanup
    include MachineCleanupArtifacts
    include MachineCleanupApply
    include MachineCleanupCaches
    include MachineCleanupEvidence
    include MachineCleanupProcesses

    DEFAULT_MIN_FREE_GB = 30
    DEFAULT_CACHE_THRESHOLD_GB = 0.25
    DEFAULT_DERIVEDDATA_AGE_DAYS = 2
    DEFAULT_TRASH_THRESHOLD_GB = 1

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
      if options[:json]
        puts JSON.pretty_generate(result)
      elsif !options[:quiet]
        freed = result[:freed_gb] ? "#{result[:freed_gb]}G" : 'unknown'
        puts "Applied #{result[:applied_count]} action(s), #{result[:failed_count]} failed; disk now reports #{freed} freed."
      end
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
        empty_trash: false,
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
        when '--empty-trash'
          options[:empty_trash] = true
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
      hygiene_targets = machine_cleanup_hygiene_targets(active, options)
      server_targets = machine_cleanup_server_targets(active, options, pressure)
      evidence_targets = machine_cleanup_evidence_targets(active, options, pressure)
      layout_targets = machine_cleanup_layout_litter_targets

      actions = []
      actions.concat(cache_targets)
      actions.concat(deriveddata_targets)
      actions.concat(simulator_targets)
      actions.concat(layout_targets)
      actions.concat(hygiene_targets)
      actions.concat(server_targets)
      actions.concat(evidence_targets)
      actions << trash_target if trash_target
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
        size_bytes: size_kb * 1024,
        used_bytes: used_kb * 1024,
        available_bytes: avail_kb * 1024,
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
        if active_apps.include?(app)
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
      return nil if size_gb < options[:trash_threshold_gb] && !options[:empty_trash]

      {
        type: options[:empty_trash] ? 'empty_trash' : 'skip',
        category: 'trash',
        path: trash,
        size_gb: size_gb,
        reason: options[:empty_trash] ?
          'Explicit cleanup approval: permanently empty Trash after moving planned disposable paths.' :
          'Trash exceeds threshold but is preserved unless --empty-trash is explicitly supplied.'
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

    def kb_to_gb(kb)
      (kb.to_f / 1024 / 1024).round(2)
    end
  end
end
