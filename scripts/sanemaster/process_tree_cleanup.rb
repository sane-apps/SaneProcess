# frozen_string_literal: true

require 'open3'

module SaneMasterModules
  # Identity-bound cleanup for process trees owned by test runners.
  module ProcessTreeCleanup
    private

    def terminate_monitor_test_process_group(pid, root_identity: nil, tracked_identities: {}, tracked_descendants: [],
                                             grace_seconds: 1.0, kill_grace_seconds: 1.0)
      root_identity ||= monitor_test_owned_process_identity(pid)
      tracked_descendants.each { |child_pid| monitor_test_capture_identity!(tracked_identities, child_pid) }
      tracked_identities = monitor_test_expand_descendant_identities(root_identity, tracked_identities)
      begin
        signal_monitor_test_processes('TERM', pid, tracked_identities.keys,
                                      root_identity: root_identity, tracked_identities: tracked_identities)
        tracked_identities = monitor_test_wait_for_exit(root_identity, tracked_identities, grace_seconds)
        survivors = monitor_test_termination_survivors(root_identity, tracked_identities)
        unless monitor_test_survivors_empty?(survivors)
          tracked_identities = monitor_test_expand_descendant_identities(root_identity, tracked_identities)
          signal_monitor_test_processes('KILL', pid, tracked_identities.keys,
                                        root_identity: root_identity, tracked_identities: tracked_identities)
          tracked_identities = monitor_test_wait_for_exit(root_identity, tracked_identities, kill_grace_seconds)
          survivors = monitor_test_termination_survivors(root_identity, tracked_identities)
        end
        return true if monitor_test_survivors_empty?(survivors)

        labels = []
        labels << "process group -#{pid}" if survivors[:group_alive]
        labels << "root pid #{pid}" if survivors[:root_alive]
        labels.concat(survivors[:descendant_pids].map { |child_pid| "descendant pid #{child_pid}" })
        raise "Timed-out test cleanup left survivors: #{labels.join(', ')}"
      rescue StandardError
        tracked_identities = monitor_test_expand_descendant_identities(root_identity, tracked_identities)
        signal_monitor_test_processes('KILL', pid, tracked_identities.keys,
                                      root_identity: root_identity, tracked_identities: tracked_identities)
        raise
      end
    end

    def monitor_test_wait_for_exit(root_identity, tracked_identities, grace_seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace_seconds
      loop do
        tracked_identities = monitor_test_expand_descendant_identities(root_identity, tracked_identities)
        break if monitor_test_survivors_empty?(monitor_test_termination_survivors(root_identity, tracked_identities))
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
      tracked_identities
    end

    def monitor_test_track_descendant_identities(root_identity, tracked_identities)
      expanded = monitor_test_expand_descendant_identities(root_identity, tracked_identities)
      tracked_identities.replace(expanded)
    end

    def monitor_test_expand_descendant_identities(root_identity, tracked_identities)
      snapshot = monitor_test_live_process_snapshot
      roots = [root_identity, *tracked_identities.values].compact.select do |identity|
        monitor_test_identity_present?(identity, snapshot)
      end
      children = Hash.new { |hash, key| hash[key] = [] }
      snapshot.each { |process| children[process[:ppid]] << process }
      expanded = tracked_identities.dup
      if monitor_test_identity_present?(root_identity, snapshot)
        snapshot.each do |process|
          expanded[process[:pid]] ||= process if process[:pgid] == root_identity[:pgid] && process[:pid] != root_identity[:pid]
        end
      end
      queue = roots.map { |identity| identity[:pid] }
      until queue.empty?
        parent_pid = queue.shift
        children[parent_pid].each do |child|
          expanded[child[:pid]] ||= child
          queue << child[:pid]
        end
      end
      expanded
    end

    def monitor_test_capture_identity!(identities, pid)
      identities[pid] ||= monitor_test_process_identity(pid)
      identities.delete(pid) unless identities[pid]
    end

    def monitor_test_termination_survivors(root_identity, tracked_identities)
      snapshot = monitor_test_live_process_snapshot
      root_alive = monitor_test_identity_present?(root_identity, snapshot)
      surviving_identities = tracked_identities.values.select do |identity|
        monitor_test_identity_present?(identity, snapshot)
      end
      {
        group_alive: ([root_identity] + surviving_identities).any? do |identity|
          identity[:pgid] == root_identity[:pgid] && monitor_test_identity_present?(identity, snapshot)
        end,
        root_alive: root_alive,
        descendant_pids: surviving_identities.map { |identity| identity[:pid] }
      }
    end

    def monitor_test_survivors_empty?(survivors)
      !survivors[:group_alive] && !survivors[:root_alive] && survivors[:descendant_pids].empty?
    end

    def signal_monitor_test_processes(signal, pid, descendants, root_identity: nil, tracked_identities: {})
      root_identity ||= monitor_test_process_identity(pid)
      current_root = monitor_test_revalidated_identity(root_identity)
      if current_root && current_root[:pgid] == pid
        monitor_test_send_signal(signal, -pid)
        current_root = monitor_test_revalidated_identity(root_identity)
        monitor_test_send_signal(signal, pid) if current_root
      end
      descendants.uniq.each do |child_pid|
        identity = tracked_identities[child_pid]
        identity ||= monitor_test_process_identity(child_pid)
        monitor_test_send_signal(signal, child_pid) if monitor_test_revalidated_identity(identity)
      end
    end

    def monitor_test_send_signal(signal, target)
      Process.kill(signal, target)
    rescue Errno::ESRCH, Errno::EINVAL, Errno::EPERM
      nil
    end

    def monitor_test_signal_targets(pid, descendants)
      [-pid, pid, *descendants].uniq
    end

    def monitor_test_revalidated_identity(identity)
      return nil unless identity

      if identity[:owned_child] && @monitor_test_process_scan_unavailable
        return identity if Process.getpgid(identity[:pid]) == identity[:pgid]
        return nil
      end

      current = monitor_test_process_identity(identity[:pid])
      current if monitor_test_same_identity?(identity, current)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def monitor_test_same_identity?(captured, current)
      return false unless captured && current

      # PID plus kernel process birth time is the stable identity. A legitimate
      # captured child may exec(2), reparent, or call setsid(2) while cleanup is
      # in progress; PGID, PPID, and command are observations, not identity.
      %i[pid start_time].all? { |key| captured[key] == current[key] }
    end

    def monitor_test_identity_present?(identity, snapshot)
      return false unless identity

      if identity[:owned_child] && @monitor_test_process_scan_unavailable
        return Process.getpgid(identity[:pid]) == identity[:pgid]
      end

      current = snapshot.find { |process| process[:pid] == identity[:pid] }
      monitor_test_same_identity?(identity, current)
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def monitor_test_process_identity(pid)
      monitor_test_live_process_snapshot.find { |process| process[:pid] == pid }
    end

    def monitor_test_process_scan_available?
      monitor_test_live_process_snapshot
      !@monitor_test_process_scan_unavailable
    end

    # Call only for a PID returned directly by this process's spawn/fork path.
    # The explicit process group remains safely identifiable when a client
    # sandbox denies process-table enumeration.
    def monitor_test_owned_process_identity(pid)
      identity = monitor_test_process_identity(pid)
      return identity if identity

      pgid = Process.getpgid(pid)
      return nil unless pgid == pid

      {
        pid: pid,
        ppid: Process.pid,
        pgid: pgid,
        start_time: "owned-child-#{pid}",
        command: 'owned isolated child process',
        owned_child: true
      }
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def monitor_test_process_group_alive?(pid)
      monitor_test_live_process_snapshot.any? { |process| process[:pgid] == pid }
    end

    def monitor_test_pid_alive?(pid)
      monitor_test_live_process_snapshot.any? { |process| process[:pid] == pid }
    end

    def monitor_test_live_process_snapshot
      output, status = Open3.capture2(
        { 'PATH' => '/usr/bin:/bin', 'LC_ALL' => 'C', 'LANG' => 'C' },
        '/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,lstart=,command=',
        unsetenv_others: true
      )
      unless status.success?
        @monitor_test_process_scan_unavailable = true
        @monitor_test_process_scan_error = "ps exited #{status.exitstatus}: #{output.to_s.strip}"
        return []
      end

      @monitor_test_process_scan_unavailable = false
      monitor_test_parse_process_snapshot(output)
    rescue SystemCallError => e
      @monitor_test_process_scan_unavailable = true
      @monitor_test_process_scan_error = e.message
      []
    end

    def monitor_test_parse_process_snapshot(output)
      seen = {}
      processes = output.each_line.each_with_object([]) do |line, parsed|
        raise 'Malformed process snapshot: blank row' if line.strip.empty?

        fields = line.strip.split(/\s+/, 10)
        raise "Malformed process snapshot row: #{line.inspect}" if fields.length < 10

        process_pid, parent_pid, process_group_id = fields[0, 3].map(&:to_i)
        state = fields[3]
        start_time = fields[4, 5].join(' ')
        command = fields[9]
        valid_start = start_time.match?(/\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{1,2} \d{2}:\d{2}:\d{2} \d{4}\z/)
        unless process_pid.positive? && parent_pid >= 0 && process_group_id.positive? &&
               !state.empty? && valid_start && !command.empty? && !seen[process_pid]
          raise "Inconsistent process snapshot row: #{line.inspect}"
        end
        seen[process_pid] = true
        next if state.start_with?('Z')

        parsed << {
          pid: process_pid,
          ppid: parent_pid,
          pgid: process_group_id,
          start_time: start_time,
          command: command
        }
      end
      raise 'Malformed process snapshot: no process rows' if processes.empty?

      processes
    end

    def monitor_test_descendant_pids(root_pid)
      root = monitor_test_process_identity(root_pid)
      monitor_test_expand_descendant_identities(root, {}).keys
    rescue StandardError
      []
    end
  end
end
