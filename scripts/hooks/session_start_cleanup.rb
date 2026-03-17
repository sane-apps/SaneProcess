#!/usr/bin/env ruby
# frozen_string_literal: true

module SessionStartCleanup
  def build_process_maps
    return @process_maps if @process_maps

    ps_lines = `ps -eo pid,ppid,command 2>/dev/null`.lines rescue []
    children_map = Hash.new { |h, k| h[k] = [] }
    command_map = {}

    ps_lines.each do |line|
      parts = line.strip.split(/\s+/, 3)
      next if parts.length < 2

      pid = parts[0].to_i
      ppid = parts[1].to_i
      cmd = parts[2] || ''
      next unless pid.positive? && ppid.positive?

      children_map[ppid] << pid
      command_map[pid] = cmd
    end

    @process_maps = { children: children_map, commands: command_map }
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def has_living_claude_ancestor?(pid)
    maps = build_process_maps
    current = pid
    10.times do
      ppid = `ps -o ppid= -p #{current} 2>/dev/null`.strip.to_i rescue 0
      break if ppid <= 1

      cmd = maps[:commands][ppid] || ''
      return process_alive?(ppid) if cmd.include?('claude') && !cmd.include?('grep')

      current = ppid
    end
    false
  end

  def get_process_tree(root_pid)
    maps = build_process_maps
    tree = [root_pid]
    queue = [root_pid]
    while queue.any?
      current = queue.shift
      children = maps[:children][current] || []
      children.each do |child|
        tree << child
        queue << child
      end
    end
    tree
  end

  def find_all_claude_session_pids
    maps = build_process_maps
    pids = []
    maps[:commands].each do |pid, cmd|
      if cmd.include?('claude') && !cmd.include?('--resume') && !cmd.include?('grep')
        pids << pid if process_alive?(pid)
      end
    end
    pids << Process.ppid
    pids.uniq
  end

  def get_all_claude_trees
    all_pids = find_all_claude_session_pids
    combined = {}
    all_pids.each do |pid|
      get_process_tree(pid).each { |p| combined[p] = true }
    end
    log_debug("all_claude_trees: #{all_pids.length} sessions, #{combined.size} total PIDs")
    combined
  end

  def cleanup_orphaned_claude_processes
    my_ancestors = []
    current = Process.pid
    10.times do
      ppid = `ps -o ppid= -p #{current} 2>/dev/null`.strip.to_i rescue 0
      break if ppid <= 1

      my_ancestors << ppid
      current = ppid
    end

    log_debug("cleanup: my ancestors=#{my_ancestors.inspect}")

    maps = build_process_maps
    orphans_killed = 0

    maps[:commands].each do |pid, cmd|
      next unless cmd.include?('--dangerously-skip-permissions')
      next if cmd.include?('grep')
      next if my_ancestors.include?(pid) || pid == Process.pid

      ppid = `ps -o ppid= -p #{pid} 2>/dev/null`.strip.to_i rescue 0
      unless ppid <= 1
        log_debug("cleanup: SKIP #{pid} (ppid=#{ppid}, not orphaned)")
        next
      end

      log_debug("cleanup: KILL #{pid} (orphaned, ppid=1)")
      begin
        Process.kill('KILL', pid)
        orphans_killed += 1
      rescue Errno::ESRCH, Errno::EPERM => e
        log_debug("cleanup: failed to kill #{pid}: #{e.message}")
      end
    end

    if orphans_killed.positive?
      warn "🧹 Cleaned up #{orphans_killed} orphaned Claude session#{orphans_killed == 1 ? '' : 's'}"
    end

    stale_warned = []
    stale_killed = 0
    maps[:commands].each do |pid, cmd|
      next unless cmd.include?('--dangerously-skip-permissions')
      next if cmd.include?('grep')
      next if my_ancestors.include?(pid) || pid == Process.pid

      ppid = `ps -o ppid= -p #{pid} 2>/dev/null`.strip.to_i rescue 0
      next if ppid <= 1

      elapsed = `ps -o etime= -p #{pid} 2>/dev/null`.strip rescue ''
      next if elapsed.empty?

      parts = elapsed.split(/[-:]/).map(&:to_i)
      total_hours = case parts.length
                    when 4 then parts[0] * 24 + parts[1]
                    when 3 then parts[0]
                    else 0
                    end

      tty = `ps -o tty= -p #{pid} 2>/dev/null`.strip rescue '?'

      if total_hours >= 24
        log_debug("cleanup: KILL stale session #{pid} (#{total_hours}h old, tty=#{tty})")
        begin
          Process.kill('TERM', pid)
          sleep 0.5
          Process.kill('KILL', pid) if process_alive?(pid)
          stale_killed += 1
        rescue Errno::ESRCH, Errno::EPERM => e
          log_debug("cleanup: failed to kill stale #{pid}: #{e.message}")
        end
      elsif total_hours >= 6
        stale_warned << { pid: pid, hours: total_hours, tty: tty }
      end
    end

    if stale_killed.positive?
      warn "🧹 Auto-killed #{stale_killed} stale Claude session#{stale_killed == 1 ? '' : 's'} (>24h old)"
    end

    if stale_warned.any?
      warn ''
      warn "⚠️  STALE CLAUDE SESSIONS (#{stale_warned.length}):"
      stale_warned.each do |stale|
        warn "   PID #{stale[:pid]} — running #{stale[:hours]}h — terminal #{stale[:tty]}"
      end
      warn '   Close them to free resources. To kill: kill <PID>'
      warn ''
    end
  rescue StandardError => e
    log_debug("Orphan cleanup error: #{e.class}: #{e.message}")
  end

  def cleanup_orphaned_mcp_daemons
    all_trees = get_all_claude_trees
    mcp_patterns = [
      'chroma-mcp', 'worker-service.cjs', 'mcp-server.cjs',
      'mcpbridge', 'context7-mcp', 'apple-docs-mcp',
      'mcp-server-github', 'server-memory', 'macos-automator',
      'serena', 'nvidia_mcp_server'
    ]
    mcp_regex_patterns = ['npx/.*/mcp']

    maps = build_process_maps
    daemons_killed = 0

    maps[:commands].each do |pid, cmd|
      matched = mcp_patterns.find { |pattern| cmd.include?(pattern) }
      matched ||= mcp_regex_patterns.find { |pattern| cmd.match?(Regexp.new(pattern)) }
      next unless matched

      if all_trees[pid]
        log_debug("mcp_cleanup: SKIP #{pid} (#{matched}) - belongs to a living session")
        next
      end

      if has_living_claude_ancestor?(pid)
        log_debug("mcp_cleanup: SKIP #{pid} (#{matched}) - has living Claude ancestor")
        next
      end

      log_debug("mcp_cleanup: KILL #{pid} (#{matched}) - truly orphaned")
      begin
        Process.kill('KILL', pid)
        daemons_killed += 1
      rescue Errno::ESRCH, Errno::EPERM => e
        log_debug("mcp_cleanup: failed to kill #{pid}: #{e.message}")
      end
    end

    if daemons_killed.positive?
      warn "🧹 Cleaned up #{daemons_killed} orphaned MCP daemon#{daemons_killed == 1 ? '' : 's'}"
    end
  rescue StandardError => e
    log_debug("MCP daemon cleanup error: #{e.class}: #{e.message}")
  end

  def run_mcp_watchdog_cleanup
    sane_master = File.expand_path('../SaneMaster.rb', __dir__)
    return unless File.exist?(sane_master)

    ok = system(
      RbConfig.ruby, sane_master, 'mcp_watchdog', 'clean',
      '--quiet', '--max', '4', '--grace', '0',
      out: File::NULL, err: File::NULL
    )
    log_debug("mcp_watchdog_cleanup done=#{ok}")
    schedule_mcp_watchdog_cleanup(sane_master, 20)
    schedule_mcp_watchdog_cleanup(sane_master, 60)
  rescue StandardError => e
    log_debug("mcp_watchdog_cleanup error: #{e.class}: #{e.message}")
  end

  def schedule_mcp_watchdog_cleanup(sane_master, delay_seconds)
    return unless delay_seconds.to_i.positive?

    pid = Process.spawn(
      RbConfig.ruby,
      '-e',
      <<~RUBY,
        sleep #{delay_seconds.to_i}
        exec #{[
          RbConfig.ruby,
          sane_master,
          'mcp_watchdog',
          'clean',
          '--quiet',
          '--max',
          '4',
          '--grace',
          '0'
        ].map(&:inspect).join(', ')}
      RUBY
      out: File::NULL,
      err: File::NULL
    )
    Process.detach(pid)
    log_debug("scheduled_mcp_watchdog_cleanup pid=#{pid} delay=#{delay_seconds}")
  rescue StandardError => e
    log_debug("scheduled_mcp_watchdog_cleanup error: #{e.class}: #{e.message}")
  end

  def cleanup_orphaned_subagents
    all_trees = get_all_claude_trees
    maps = build_process_maps
    subagents_killed = 0

    maps[:commands].each do |pid, cmd|
      next unless cmd.include?('claude') && cmd.include?('--resume')
      next if cmd.include?('--dangerously-skip-permissions')
      next if cmd.include?('grep')

      if all_trees[pid]
        log_debug("subagent_cleanup: SKIP #{pid} - belongs to a living session")
        next
      end

      if has_living_claude_ancestor?(pid)
        log_debug("subagent_cleanup: SKIP #{pid} - has living Claude ancestor")
        next
      end

      log_debug("subagent_cleanup: KILL #{pid} - truly orphaned")
      begin
        Process.kill('KILL', pid)
        subagents_killed += 1
      rescue Errno::ESRCH, Errno::EPERM => e
        log_debug("subagent_cleanup: failed to kill #{pid}: #{e.message}")
      end
    end

    if subagents_killed.positive?
      warn "🧹 Cleaned up #{subagents_killed} orphaned subagent#{subagents_killed == 1 ? '' : 's'}"
    end
  rescue StandardError => e
    log_debug("Subagent cleanup error: #{e.class}: #{e.message}")
  end
end
