# frozen_string_literal: true

require 'digest'
require 'json'
require 'open3'
require 'time'

module SaneMasterModules
  # Target ownership, process discovery, sampling, and metrics for resource_soak.
  module ResourceSoakTargets
    RESOURCE_SOAK_TARGETS = %w[macos-app ios-simulator browser-extension command-tree].freeze

    class ResourceSoakTargetError < StandardError; end

    def resource_soak_prepare_target(options)
      case options[:target]
      when 'macos-app' then resource_soak_prepare_macos_target(options)
      when 'ios-simulator' then resource_soak_prepare_ios_target(options)
      when 'browser-extension' then resource_soak_prepare_browser_target(options)
      when 'command-tree' then resource_soak_prepare_command_target(options)
      else raise ResourceSoakTargetError, "unsupported resource target: #{options[:target]}"
      end
    end

    def resource_soak_prepare_macos_target(options)
      candidates = resource_soak_running_app_candidates(options[:app_name])
      if candidates.empty?
        raise ResourceSoakTargetError,
              "#{options[:app_name]} is not running from /Applications; launch with ./scripts/SaneMaster.rb test_mode --release --no-logs"
      end
      if candidates.length > 1
        pids = candidates.map { |candidate| candidate[:pid] }.join(', ')
        raise ResourceSoakTargetError,
              "Multiple #{options[:app_name]} processes are running from /Applications: #{pids}; relaunch with ./scripts/SaneMaster.rb test_mode --release --no-logs"
      end

      candidate = candidates.first
      { kind: 'macos-app', ownership: 'attached', candidate: candidate,
        root_identity: resource_soak_identity_for_pid(candidate[:pid]) }
    end

    def resource_soak_prepare_ios_target(options)
      udid = resource_soak_required_option(options, :simulator_udid, '--simulator-udid')
      bundle_id = resource_soak_required_option(options, :bundle_id, '--bundle-id')
      app_path, status = resource_soak_capture('xcrun', 'simctl', 'get_app_container', udid, bundle_id, 'app')
      raise ResourceSoakTargetError, "iOS Simulator app is not installed: #{bundle_id} on #{udid}" unless status&.success?

      app_path = app_path.strip
      executable_name = resource_soak_plist_value(app_path, 'CFBundleExecutable')
      executable = File.join(app_path, executable_name.to_s)
      candidates = resource_soak_process_rows.select { |row| resource_soak_command_uses_executable?(row[:command], executable) }
      raise ResourceSoakTargetError, "iOS Simulator app is not running: #{bundle_id} on #{udid}" if candidates.empty?
      raise ResourceSoakTargetError, "multiple iOS Simulator app processes match #{bundle_id}" if candidates.length > 1

      row = candidates.first.merge(executable: executable)
      candidate = {
        pid: row[:pid], app_path: app_path, bundle_id: bundle_id, simulator_udid: udid,
        app_version: resource_soak_plist_value(app_path, 'CFBundleShortVersionString'),
        app_build: resource_soak_plist_value(app_path, 'CFBundleVersion'),
        process_path: executable, process_started_at: row[:started_at],
        app_executable_mtime: File.mtime(executable).iso8601
      }
      { kind: 'ios-simulator', ownership: 'attached', candidate: candidate,
        root_identity: resource_soak_identity(row) }
    end

    def resource_soak_prepare_browser_target(options)
      receipt_path = resource_soak_required_option(options, :session_receipt, '--session-receipt')
      receipt = resource_soak_read_session_receipt(receipt_path)
      unless receipt['browser'] == 'brave' && receipt['private_automation'] == true
        raise ResourceSoakTargetError, 'browser receipt must describe a private Brave automation session'
      end
      raise ResourceSoakTargetError, 'browser receipt schema_version must be 1' unless receipt['schema_version'] == 1
      %w[session_id source_fingerprint package_sha256 created_at].each do |key|
        raise ResourceSoakTargetError, "browser receipt #{key} is missing" if receipt[key].to_s.empty?
      end
      raise ResourceSoakTargetError, 'browser receipt package_sha256 is invalid' unless receipt['package_sha256'].match?(/\A[0-9a-f]{64}\z/i)
      raise ResourceSoakTargetError, 'browser receipt created_at is invalid' unless resource_soak_time(receipt['created_at'])

      profile = File.realpath(receipt.fetch('user_data_dir'))
      unless (profile.start_with?('/tmp/') || profile.start_with?('/private/tmp/')) &&
             File.directory?(profile) && !File.symlink?(receipt.fetch('user_data_dir'))
        raise ResourceSoakTargetError, 'browser receipt user_data_dir must be a real private directory under /tmp'
      end
      root_pid = Integer(receipt.fetch('root_pid').to_s, 10)
      row = resource_soak_process_rows.find { |process| process[:pid] == root_pid }
      expected_executable = File.realpath(receipt.fetch('executable'))
      raise ResourceSoakTargetError, 'browser receipt executable is not Brave Browser' unless File.basename(expected_executable) == 'Brave Browser'
      extension_id = receipt.fetch('extension_id')
      raise ResourceSoakTargetError, 'browser receipt extension_id is invalid' unless extension_id.match?(/\A[a-p]{32}\z/)
      unless row && row[:uid] == Process.uid && resource_soak_command_uses_executable?(row[:command], expected_executable) &&
             resource_soak_command_has_profile?(row[:command], profile)
        raise ResourceSoakTargetError, 'private Brave root process identity does not match its receipt'
      end
      if receipt['process_started_at'] && receipt['process_started_at'].to_s != row[:started_at].to_s
        raise ResourceSoakTargetError, 'private Brave root process start time does not match its receipt'
      end

      row = row.merge(executable: expected_executable)
      candidate = {
        pid: row[:pid], extension_id: extension_id, browser: 'brave', session_id: receipt.fetch('session_id'),
        user_data_dir: profile, process_path: expected_executable,
        process_started_at: row[:started_at], source_fingerprint: receipt.fetch('source_fingerprint'),
        package_sha256: receipt.fetch('package_sha256'), created_at: receipt.fetch('created_at'),
        session_receipt_sha256: Digest::SHA256.file(receipt_path).hexdigest
      }
      { kind: 'browser-extension', ownership: 'attached', candidate: candidate,
        root_identity: resource_soak_identity(row) }
    rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError => e
      raise ResourceSoakTargetError, "invalid private Brave session receipt: #{e.message}"
    end

    def resource_soak_prepare_command_target(options)
      argv = Array(options[:command_argv])
      raise ResourceSoakTargetError, 'command-tree target requires argv after --' if argv.empty?

      cwd = File.realpath(options[:cwd] || Dir.pwd)
      executable = resource_soak_resolve_executable(argv.first, cwd)
      pid = Process.spawn(*argv, chdir: cwd, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
      row = resource_soak_wait_for_process(pid)
      unless row && row[:pgid] == pid && row[:uid] == Process.uid &&
             resource_soak_command_uses_executable?(row[:command], executable)
        resource_soak_signal_group(pid, 'TERM')
        raise ResourceSoakTargetError, 'owned command did not establish its expected process group'
      end
      row = row.merge(executable: executable)

      candidate = {
        pid: pid, pgid: pid, process_path: row[:executable], process_started_at: row[:started_at],
        cwd: cwd, argv_sha256: Digest::SHA256.hexdigest(argv.join("\0"))
      }
      { kind: 'command-tree', ownership: 'owned', candidate: candidate,
        root_identity: resource_soak_identity(row), last_identities: [resource_soak_identity(row)], pgid: pid }
    rescue Errno::ENOENT, Errno::EACCES => e
      raise ResourceSoakTargetError, "could not start owned command: #{e.message}"
    end

    def resource_soak_cleanup_target(target)
      return { attempted: false, result: 'not_owned' } unless target && target[:ownership] == 'owned'

      rows = resource_soak_process_rows.select { |row| row[:pgid] == target[:pgid] }
      return { attempted: true, result: 'already_exited' } if rows.empty?
      known = Array(target[:last_identities])
      exact = rows.all? { |row| known.include?(resource_soak_identity(row)) }
      root_exact = resource_soak_root_identity_valid?(target, rows)
      return { attempted: true, result: 'refused_identity_drift' } unless exact && root_exact

      resource_soak_signal_group(target[:pgid], 'TERM')
      remaining = resource_soak_wait_for_group_exit(target, 2.0)
      used_kill = false
      unless remaining.empty?
        unchanged = remaining.all? { |row| rows.map { |prior| resource_soak_identity(prior) }.include?(resource_soak_identity(row)) }
        return { attempted: true, result: 'refused_identity_drift_after_term' } unless unchanged
        resource_soak_signal_group(target[:pgid], 'KILL')
        used_kill = true
        remaining = resource_soak_wait_for_group_exit(target, 1.0)
      end
      return { attempted: true, result: 'kill_incomplete' } unless remaining.empty?
      { attempted: true, result: used_kill ? 'killed_after_term' : 'terminated' }
    rescue Errno::ECHILD, Errno::ESRCH
      { attempted: true, result: 'exited' }
    end

    def resource_soak_target_sample(target)
      if target[:kind] == 'macos-app'
        sample = resource_soak_sample(target[:candidate][:pid])
        return sample && sample.merge(pids: [target[:candidate][:pid]], process_count: 1,
                                      fd_count: resource_soak_fd_count([target[:candidate][:pid]]))
      end

      rows = resource_soak_target_rows(target)
      return nil if rows.empty? || !resource_soak_root_identity_valid?(target, rows)
      target[:last_identities] = rows.map { |row| resource_soak_identity(row) }

      stats = resource_soak_process_stats(rows.map { |row| row[:pid] })
      return nil unless stats.length == rows.length

      {
        sampled_at: Time.now.utc.iso8601,
        cpu: stats.sum { |row| row[:cpu] },
        rss_mb: stats.sum { |row| row[:rss_mb] },
        physical_footprint_mb: target[:kind] == 'ios-simulator' && rows.length == 1 ? resource_soak_physical_footprint_mb(rows.first[:pid]) : nil,
        fd_count: resource_soak_fd_count(rows.map { |row| row[:pid] }),
        pids: rows.map { |row| row[:pid] }.sort,
        process_count: rows.length
      }
    end

    def resource_soak_target_rows(target)
      rows = resource_soak_process_rows
      root_pid = target[:candidate][:pid]
      descendants = [root_pid]
      loop do
        added = rows.select { |row| descendants.include?(row[:ppid]) }.map { |row| row[:pid] } - descendants
        break if added.empty?
        descendants.concat(added)
      end
      rows.select { |row| descendants.include?(row[:pid]) }
    end

    def resource_soak_root_identity_valid?(target, rows)
      root = rows.find { |row| row[:pid] == target[:candidate][:pid] }
      expected = target[:root_identity]
      root && root[:pid] == expected[:pid] && root[:pgid] == expected[:pgid] &&
        root[:uid] == expected[:uid] && root[:started_at] == expected[:started_at] &&
        resource_soak_command_uses_executable?(root[:command], expected[:executable])
    end

    def resource_soak_running_app_candidate(app_name)
      candidates = resource_soak_running_app_candidates(app_name)
      candidates.length == 1 ? candidates.first : nil
    end

    def resource_soak_running_app_candidates(app_name)
      app_path = "/Applications/#{app_name}.app"
      executable = File.join(app_path, 'Contents', 'MacOS', app_name)
      return [] unless File.executable?(executable)

      resource_soak_process_rows.each_with_object([]) do |row, candidates|
        next unless resource_soak_command_uses_executable?(row[:command], executable)

        candidates << {
          pid: row[:pid], app_path: app_path,
          app_version: resource_soak_plist_value(app_path, 'CFBundleShortVersionString'),
          app_build: resource_soak_plist_value(app_path, 'CFBundleVersion'),
          process_path: executable, process_started_at: row[:started_at],
          app_executable_mtime: File.mtime(executable).iso8601
        }
      end
    end

    def resource_soak_candidate_version_issues(candidate)
      expected = resource_soak_expected_project_version
      issues = []
      if expected[:app_version] && candidate[:app_version].to_s != expected[:app_version].to_s
        issues << "Running candidate version #{candidate[:app_version]} does not match project MARKETING_VERSION #{expected[:app_version]}"
      end
      if expected[:app_build] && candidate[:app_build].to_s != expected[:app_build].to_s
        issues << "Running candidate build #{candidate[:app_build]} does not match project CURRENT_PROJECT_VERSION #{expected[:app_build]}"
      end
      started = resource_soak_time(candidate[:process_started_at])
      replaced = resource_soak_time(candidate[:app_executable_mtime])
      if started && replaced && replaced > started + 1
        issues << "Running candidate process #{candidate[:pid]} started before /Applications executable was last replaced; relaunch with ./scripts/SaneMaster.rb test_mode --release --no-logs"
      end
      issues
    end

    def resource_soak_expected_project_version
      path = File.join(Dir.pwd, 'project.yml')
      return {} unless customer_ui_regular_file?(path)

      content = safe_customer_ui_file_read(path)
      { app_version: content[/MARKETING_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip,
        app_build: content[/CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip }.reject { |_, value| value.empty? }
    end

    def resource_soak_plist_value(app_path, key)
      value, status = resource_soak_capture('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(app_path, 'Info.plist'))
      unless status&.success?
        value, status = resource_soak_capture('/usr/libexec/PlistBuddy', '-c', "Print :#{key}", File.join(app_path, 'Contents', 'Info.plist'))
      end
      status&.success? ? value.strip : nil
    end

    def resource_soak_sample(pid)
      stats = resource_soak_process_stats([pid]).first
      return nil unless stats

      { sampled_at: Time.now.utc.iso8601, cpu: stats[:cpu], rss_mb: stats[:rss_mb],
        physical_footprint_mb: resource_soak_physical_footprint_mb(pid) }
    end

    def resource_soak_physical_footprint_mb(pid)
      output, status = resource_soak_capture('footprint', '-pid', pid.to_s, '-summary')
      status&.success? ? resource_soak_parse_footprint_mb(output) : nil
    end

    def resource_soak_parse_footprint_mb(output)
      match = output.to_s.match(/phys_footprint:\s*([0-9.]+)\s*([KMG])B?\b/i)
      return nil unless match

      value = match[1].to_f
      { 'K' => value / 1024.0, 'G' => value * 1024.0 }.fetch(match[2].upcase, value)
    end

    def resource_soak_process_rows
      output, status = resource_soak_capture('ps', '-axo', 'pid=,ppid=,pgid=,uid=,lstart=,command=')
      return [] unless status&.success?

      output.lines.map do |line|
        match = line.chomp.match(/\A\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+(.+)\z/)
        next unless match
        command = match[6].strip
        { pid: match[1].to_i, ppid: match[2].to_i, pgid: match[3].to_i, uid: match[4].to_i,
          started_at: Time.strptime(match[5], '%a %b %e %H:%M:%S %Y').iso8601,
          executable: command.split(/\s+/, 2).first, command: command }
      rescue ArgumentError
        nil
      end.compact
    end

    def resource_soak_process_stats(pids)
      return [] if pids.empty?
      output, status = resource_soak_capture('ps', '-o', 'pid=,%cpu=,rss=', '-p', pids.join(','))
      return [] unless status&.success?
      output.lines.map do |line|
        pid, cpu, rss = line.strip.split(/\s+/, 3)
        { pid: pid.to_i, cpu: cpu.to_f, rss_mb: rss.to_f / 1024.0 } if pid && cpu && rss
      end.compact
    end

    def resource_soak_fd_count(pids)
      return nil if pids.empty?
      output, status = resource_soak_capture('lsof', '-nP', '-a', '-p', pids.join(','), '-Ff')
      status&.success? ? output.lines.count { |line| line.start_with?('f') } : nil
    end

    def resource_soak_identity_for_pid(pid)
      row = resource_soak_process_rows.find { |process| process[:pid] == pid }
      row && resource_soak_identity(row)
    end

    def resource_soak_identity(row)
      row.slice(:pid, :pgid, :uid, :started_at, :executable)
    end

    def resource_soak_wait_for_process(pid)
      20.times do
        row = resource_soak_process_rows.find { |process| process[:pid] == pid }
        return row if row
        sleep 0.05
      end
      nil
    end

    def resource_soak_signal_group(pgid, signal)
      Process.kill(signal, -Integer(pgid))
    rescue Errno::ESRCH
      nil
    end

    def resource_soak_wait_for_group_exit(target, seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        Process.waitpid(target[:candidate][:pid], Process::WNOHANG) rescue nil
        rows = resource_soak_process_rows.select { |row| row[:pgid] == target[:pgid] }
        return rows if rows.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
    end

    def resource_soak_command_has_profile?(command, profile)
      command.include?("--user-data-dir=#{profile}") || command.include?("--user-data-dir #{profile}")
    end

    def resource_soak_command_uses_executable?(command, executable)
      command == executable || command.start_with?("#{executable} ")
    end

    def resource_soak_read_session_receipt(path)
      absolute = File.expand_path(path)
      cursor = absolute
      until cursor == '/'
        stat = File.lstat(cursor)
        expected = cursor == absolute ? stat.file? : stat.directory?
        raise ResourceSoakTargetError, 'browser receipt path and ancestors must not be symlinks' if stat.symlink? || !expected
        cursor = File.dirname(cursor)
      end
      stat = File.lstat(absolute)
      unless stat.uid == Process.uid && stat.nlink == 1 && (stat.mode & 0o777) == 0o600
        raise ResourceSoakTargetError, 'browser receipt must be owned 0600 with one link'
      end
      JSON.parse(File.open(absolute, File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0), &:read))
    end

    def resource_soak_required_option(options, key, flag)
      value = options[key].to_s.strip
      raise ResourceSoakTargetError, "#{flag} is required for #{options[:target]}" if value.empty?
      value
    end

    def resource_soak_resolve_executable(command, cwd)
      paths = command.include?('/') ? [File.expand_path(command, cwd)] : ENV.fetch('PATH', '').split(':').map { |dir| File.join(dir, command) }
      path = paths.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      raise ResourceSoakTargetError, "owned command executable was not found: #{command}" unless path
      File.realpath(path)
    end

    def resource_soak_capture(*command)
      output = +''
      status = nil
      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [stdout, stderr].map do |stream|
          Thread.new do
            loop do
              chunk = stream.readpartial(16_384)
              output << chunk if output.bytesize < 262_144
            end
          rescue EOFError, IOError
            nil
          end
        end
        unless wait_thread.join(5.0)
          resource_soak_signal_group(wait_thread.pid, 'TERM')
          wait_thread.join(1.0) || resource_soak_signal_group(wait_thread.pid, 'KILL')
          wait_thread.join(1.0)
        end
        readers.each { |reader| reader.join(1.0) }
        status = wait_thread.value unless wait_thread.alive?
      end
      [output, status]
    rescue Errno::ENOENT
      ['', nil]
    end

    def resource_soak_time(value)
      return value if value.is_a?(Time)
      return nil if value.to_s.strip.empty?
      Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def resource_soak_metrics(samples, options = {})
      return resource_soak_empty_metrics if samples.empty?

      rss = samples.map { |sample| sample[:rss_mb].to_f }
      cpu = samples.map { |sample| sample[:cpu].to_f }
      physical = samples.map { |sample| sample[:physical_footprint_mb]&.to_f }.compact
      fds = samples.map { |sample| sample[:fd_count]&.to_i }.compact
      baseline_count = [options.fetch(:adaptive_baseline_sample_count, 6).to_i, 1].max
      baseline = samples.first(baseline_count)
      recent = samples.last(baseline_count)
      latest = samples.last[:elapsed_seconds].to_f
      window = [options.fetch(:adaptive_rolling_window_seconds, 60.0).to_f, 1.0].max
      rolling_cpu = samples.select { |sample| latest - sample[:elapsed_seconds].to_f <= window }
                           .map { |sample| sample[:cpu].to_f }
      baseline_rss = resource_soak_median(baseline.map { |sample| sample[:rss_mb]&.to_f }.compact)
      baseline_physical = resource_soak_median(baseline.map { |sample| sample[:physical_footprint_mb]&.to_f }.compact)
      {
        sample_count: samples.length,
        physical_sample_count: physical.length,
        physical_missing_sample_count: samples.length - physical.length,
        fd_sample_count: fds.length,
        fd_missing_sample_count: samples.length - fds.length,
        avg_cpu: resource_soak_round(cpu.sum / cpu.length), peak_cpu: resource_soak_round(cpu.max),
        rolling_cpu_avg_60s: resource_soak_round(rolling_cpu.sum / rolling_cpu.length),
        rolling_cpu_peak_60s: resource_soak_round(rolling_cpu.max),
        avg_rss_mb: resource_soak_round(rss.sum / rss.length), peak_rss_mb: resource_soak_round(rss.max),
        rss_growth_mb: resource_soak_round(rss.last - rss.first), baseline_rss_mb: resource_soak_round(baseline_rss),
        rss_growth_from_baseline_mb: resource_soak_round(rss.last - baseline_rss.to_f),
        rss_slope_mb_per_min: resource_soak_round(resource_soak_slope(samples.last(baseline_count), :rss_mb)),
        recent_rss_range_mb: resource_soak_round(resource_soak_range(recent, :rss_mb)),
        avg_physical_footprint_mb: physical.empty? ? nil : resource_soak_round(physical.sum / physical.length),
        peak_physical_footprint_mb: resource_soak_round(physical.max),
        physical_footprint_growth_mb: physical.empty? ? nil : resource_soak_round(physical.last - physical.first),
        baseline_physical_footprint_mb: resource_soak_round(baseline_physical),
        physical_footprint_growth_from_baseline_mb: baseline_physical.nil? || physical.empty? ? nil : resource_soak_round(physical.last - baseline_physical),
        physical_footprint_slope_mb_per_min: resource_soak_round(resource_soak_slope(samples.last(baseline_count), :physical_footprint_mb)),
        recent_physical_footprint_range_mb: resource_soak_round(resource_soak_range(recent, :physical_footprint_mb)),
        peak_fd_count: fds.max, fd_growth: fds.empty? ? nil : fds.last - fds.first,
        sample_span_seconds: resource_soak_round(samples.last[:elapsed_seconds].to_f - samples.first[:elapsed_seconds].to_f)
      }
    end

    def resource_soak_empty_metrics
      { sample_count: 0, physical_sample_count: 0, physical_missing_sample_count: 0,
        fd_sample_count: 0, fd_missing_sample_count: 0, avg_cpu: 0.0, peak_cpu: 0.0,
        rolling_cpu_avg_60s: 0.0, rolling_cpu_peak_60s: 0.0, avg_rss_mb: 0.0,
        peak_rss_mb: 0.0, rss_growth_mb: 0.0, baseline_rss_mb: nil,
        rss_growth_from_baseline_mb: nil, rss_slope_mb_per_min: nil, recent_rss_range_mb: nil,
        avg_physical_footprint_mb: nil, peak_physical_footprint_mb: nil,
        physical_footprint_growth_mb: nil, baseline_physical_footprint_mb: nil,
        physical_footprint_growth_from_baseline_mb: nil, physical_footprint_slope_mb_per_min: nil,
        recent_physical_footprint_range_mb: nil, peak_fd_count: nil, fd_growth: nil,
        sample_span_seconds: 0.0 }
    end

    def resource_soak_median(values)
      values = values.compact.map(&:to_f).sort
      return nil if values.empty?
      mid = values.length / 2
      values.length.odd? ? values[mid] : (values[mid - 1] + values[mid]) / 2.0
    end

    def resource_soak_slope(samples, key)
      points = samples.select { |sample| !sample[key].nil? && !sample[:elapsed_seconds].nil? }
      return nil if points.length < 2
      minutes = (points.last[:elapsed_seconds].to_f - points.first[:elapsed_seconds].to_f) / 60.0
      minutes.positive? ? (points.last[key].to_f - points.first[key].to_f) / minutes : 0.0
    end

    def resource_soak_range(samples, key)
      values = samples.map { |sample| sample[key]&.to_f }.compact
      values.empty? ? nil : values.max - values.min
    end
  end
end
