# frozen_string_literal: true

require 'fileutils'
require 'open3'

module SaneMasterModules
  module MachineCleanupApply
    private

    def machine_cleanup_summary(disk, active, actions)
      reclaimable = actions.select do |action|
        %w[trash_path trash_children trash_matching_children empty_trash].include?(action[:type].to_s)
      end
      {
        available_gb: disk[:available_gb],
        active_apps: active.fetch(:apps, {}).keys.sort,
        action_count: actions.count { |action| action[:type] != 'skip' },
        skipped: actions.count { |action| action[:type] == 'skip' },
        reclaimable_gb: reclaimable.sum { |action| action[:size_gb].to_f }.round(2)
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

      actions = plan.fetch(:actions, [])
      permanent, reversible = actions.partition { |action| action[:type] == 'empty_trash' }
      (reversible + permanent).each do |action|
        case action[:type]
        when 'trash_path'
          if machine_cleanup_safe_path?(action[:path]) && trash_path(action[:path])
            applied << action
          else
            failed << action.merge(error: 'trash path failed or was outside cleanup-safe roots')
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
        when 'empty_trash'
          if options[:empty_trash] == true && action[:path] == File.expand_path('~/.Trash') && empty_user_trash
            applied << action
          else
            failed << action.merge(error: 'empty Trash requires explicit --empty-trash approval and a valid Trash root')
          end
        when 'command'
          success = system(*action[:argv], out: options[:quiet] ? File::NULL : $stdout, err: options[:quiet] ? File::NULL : $stderr)
          success ? applied << action : failed << action.merge(error: 'command failed')
        end
      end

      after = machine_cleanup_disk_snapshot
      before_bytes = plan.dig(:disk, :available_bytes).to_i
      after_bytes = after[:available_bytes].to_i
      freed_bytes = before_bytes.positive? && after_bytes.positive? ? [after_bytes - before_bytes, 0].max : nil

      {
        success: failed.empty?,
        applied_count: applied.length,
        failed_count: failed.length,
        failed: failed,
        disk_after: after,
        freed_bytes: freed_bytes,
        freed_gb: freed_bytes ? (freed_bytes.to_f / 1024 / 1024 / 1024).round(2) : nil
      }
    end

    def empty_user_trash
      trash = File.expand_path('~/.Trash')
      return false unless Dir.exist?(trash)
      return false if File.symlink?(trash)

      mounted_images = mounted_disk_images_backed_by_trash(trash)
      if mounted_images.nil?
        warn 'Refusing to empty Trash because mounted disk-image inspection failed.'
        return false
      end
      unless mounted_images.empty?
        warn "Refusing to empty Trash because #{mounted_images.length} mounted disk image(s) use a backing file in Trash."
        return false
      end

      Dir.children(trash).each do |entry|
        path = File.join(trash, entry)
        if File.symlink?(path) || File.file?(path)
          File.unlink(path)
        elsif File.directory?(path)
          FileUtils.remove_entry_secure(path)
        else
          File.unlink(path)
        end
      end
      true
    rescue SystemCallError => error
      warn "Failed to empty Trash: #{error.message}"
      false
    end

    def mounted_disk_images_backed_by_trash(trash)
      output, status = machine_cleanup_hdiutil_info
      return nil unless status.success?

      trash_prefix = "#{File.expand_path(trash)}/"
      output.each_line.each_with_object([]) do |line, paths|
        match = line.match(/\A\s*image-path\s*:\s*(.+?)\s*\z/)
        next unless match

        path = File.expand_path(match[1])
        paths << path if path.start_with?(trash_prefix)
      end.uniq
    rescue SystemCallError
      nil
    end

    def machine_cleanup_hdiutil_info
      Open3.capture2e('/usr/bin/hdiutil', 'info')
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

      Dir.children(path).all? { |entry| trash_path(File.join(path, entry)) }
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
      pressure = plan[:disk_pressure] ? "UNDER PRESSURE (<#{plan.dig(:thresholds, :min_free_gb)}G)" : 'healthy'
      puts "Disk: #{plan.dig(:disk, :available_gb)}G free (#{plan.dig(:disk, :capacity)} used) — #{pressure}"
      apps = plan.dig(:summary, :active_apps).join(', ')
      puts "Active apps preserved: #{apps.empty? ? 'none' : apps}"
      puts "Reclaimable: #{plan.dig(:summary, :reclaimable_gb)}G across #{plan.dig(:summary, :action_count)} action(s)"
      puts

      plan.fetch(:actions, []).each do |action|
        label = action[:type] == 'skip' ? 'SKIP' : 'PLAN'
        size = action[:size_gb] ? " (#{action[:size_gb]}G)" : ''
        target = action[:path] || Array(action[:argv]).join(' ')
        puts "- #{label} #{action[:category]}#{size}: #{target}"
        puts "  #{action[:reason]}"
      end

      return unless plan[:dry_run]

      puts
      puts 'Dry-run only. Re-run with `--apply`; add `--empty-trash` only with explicit approval to reclaim moved bytes.'
    end

    def path_size_gb(path)
      output, status = Open3.capture2e('du', '-sk', path)
      return 0.0 unless status.success?

      kb_to_gb(output.split(/\s+/).first.to_i)
    end
  end
end
