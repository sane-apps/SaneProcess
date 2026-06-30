# frozen_string_literal: true

module SaneMasterModules
  # Version checking, dependency graphs, CI parity, MCP verification
  module Dependencies
    include Base

    def check_latest_versions(args)
      puts '🔍 --- [ SANEMASTER VERSION CHECK ] ---'
      force_refresh = args.include?('--refresh') || args.include?('-f')

      cache = load_version_cache(force_refresh: force_refresh)

      if cache[:fetched_at]
        age_days = ((Time.now - Time.parse(cache[:fetched_at])) / 86_400).round(1)
        puts "📅 Cache age: #{age_days} days #{'(refreshed)' if force_refresh}"
        puts ''
      end

      puts 'Tool            Installed    Latest       Status'
      puts '-' * 55

      all_current = true
      TOOL_SOURCES.each_key do |tool|
        installed = get_installed_version(tool)
        latest = cache[:versions][tool] || 'unknown'

        status = determine_version_status(installed, latest)
        all_current = false if status.include?('missing') || status.include?('update')

        puts format('%-15<tool>s %-12<installed>s %-12<latest>s %<status>s',
                    tool: tool, installed: installed, latest: latest, status: status)
      end

      puts ''
      if all_current
        puts '✅ All tools are up to date!'
      else
        puts '💡 Run `brew upgrade <tool>` or `./scripts/SaneMaster.rb bootstrap` to update'
      end

      puts "\n🔄 To refresh cache: ./scripts/SaneMaster.rb versions --refresh"
    end

    def load_version_cache(force_refresh: false)
      ensure_sop_dirs

      if !force_refresh && File.exist?(VERSION_CACHE_FILE)
        begin
          cache = JSON.parse(File.read(VERSION_CACHE_FILE), symbolize_names: true)
          cache_age = Time.now - Time.parse(cache[:fetched_at])
          return cache if cache_age < VERSION_CACHE_MAX_AGE
        rescue StandardError
          # Cache corrupted, will refresh
        end
      end

      puts '🌐 Fetching latest versions from package managers...'
      versions = {}

      TOOL_SOURCES.each do |tool, config|
        print "   #{tool}... "
        version = fetch_latest_version(config)
        versions[tool] = version
        puts version
      end

      cache = { fetched_at: Time.now.iso8601, versions: versions }
      File.write(VERSION_CACHE_FILE, JSON.pretty_generate(cache))
      puts ''
      cache
    end

    def fetch_latest_version(config)
      case config[:type]
      when :homebrew then fetch_homebrew_version(config[:formula])
      when :github then fetch_github_version(config[:repo])
      when :rubygems then fetch_rubygems_version(config[:gem])
      else 'unknown'
      end
    rescue StandardError
      'unknown'
    end

    def get_installed_version(tool)
      case tool
      when 'swiftlint'
        `swiftlint --version 2>/dev/null`.strip.split.first || 'not installed'
      when 'xcodegen'
        output = `xcodegen --version 2>/dev/null`
        output.match(/Version: ([\d.]+)/)&.[](1) || 'not installed'
      when 'periphery'
        `periphery version 2>/dev/null`.strip || 'not installed'
      when 'mockolo'
        `mockolo --version 2>/dev/null`.strip || 'not installed'
      when 'lefthook'
        output = `lefthook --version 2>/dev/null`
        output.match(/lefthook version ([\d.]+)/)&.[](1) || 'not installed'
      when 'fastlane'
        output, _status = capture2e_with_bundle_env(preferred_bundle_bin, 'exec', 'fastlane', '--version')
        output.match(/fastlane ([\d.]+)/)&.[](1) || 'not installed'
      when 'ruby'
        output, _status = capture2e_with_ruby_env(preferred_ruby_bin, '--version')
        output.match(/ruby ([\d.]+)/)&.[](1) || 'not installed'
      else
        'unknown'
      end
    rescue StandardError
      'not installed'
    end

    def show_dependency_graph(args)
      puts '📊 --- [ SANEMASTER DEPENDENCY GRAPH ] ---'

      output_format = args.include?('--dot') ? :dot : :ascii

      deps = {
        swift_packages: scan_swift_packages,
        ruby_gems: scan_ruby_gems,
        homebrew: scan_homebrew_deps,
        frameworks: scan_frameworks
      }

      if output_format == :dot
        generate_dot_graph(deps)
      else
        print_ascii_graph(deps)
      end
    end

    def verify_mcps
      puts '🔍 --- [ MCP VERIFICATION ] ---'
      puts ''

      sop_mcps = {
        'apple-docs' => { package: '@mweinbach/apple-docs-mcp@1.3.1', required: true },
        'github' => { package: '@modelcontextprotocol/server-github@2025.4.8', required: true },
        'context7' => { package: '@upstash/context7-mcp@2.2.5', required: true },
        'xcode' => { package: 'mcpbridge', required: true },
        'macos-automator' => { package: '@steipete/macos-automator-mcp@0.4.1', required: true }
      }

      config_paths = ['.mcp.json']
      all_valid = true

      config_paths.each do |config_path|
        next unless File.exist?(config_path)

        all_valid = check_mcp_config_file(config_path, sop_mcps, all_valid)
      end

      print_mcp_verification_summary(all_valid)
    end

    DEFAULT_PER_CODEX_SERVER_CAP = 1

    CODEX_APP_SERVER_PATTERN = %r{(?:/Applications/Codex\.app/Contents/Resources/)?codex app-server(?:\s|$)}.freeze

    CODEX_SIDECAR_PATTERNS = [
      {
        kind: 'ssh-sanemaster-release',
        regex: /\bssh\b.*\bSaneMaster\.rb release(?:\s|$)/,
        grace_seconds: 3600,
        max_cpu: 0.2
      },
      {
        kind: 'pmset-thermlog',
        regex: /\bpmset -g thermlog\b/,
        grace_seconds: 120
      },
      {
        kind: 'sanemaster-release',
        regex: %r{/SaneMaster\.rb release(?:\s|$)},
        grace_seconds: 3600,
        max_cpu: 0.2
      }
    ].freeze

    def mcp_watchdog(args)
      action = 'status'
      quiet = false
      as_json = false
      max_per_server = 6
      per_codex_server_cap = DEFAULT_PER_CODEX_SERVER_CAP
      duplicate_grace_seconds = 900
      interval_seconds = 300

      i = 0
      while i < args.length
        arg = args[i]
        case arg
        when '--quiet'
          quiet = true
        when '--json'
          as_json = true
        when '--max'
          i += 1
          max_per_server = [args[i].to_i, 1].max if args[i]
        when '--per-codex-cap'
          i += 1
          per_codex_server_cap = [args[i].to_i, 1].max if args[i]
        when '--interval'
          i += 1
          interval_seconds = [args[i].to_i, 5].max if args[i]
        when '--grace'
          i += 1
          duplicate_grace_seconds = [args[i].to_i, 0].max if args[i]
        else
          action = arg unless arg.start_with?('--')
        end
        i += 1
      end

      snapshot = capture_mcp_process_snapshot
      analysis = analyze_mcp_processes(
        snapshot,
        max_per_server,
        per_codex_server_cap: per_codex_server_cap
      )
      analysis[:duplicate_grace_seconds] = duplicate_grace_seconds
      analysis[:per_codex_server_cap] = per_codex_server_cap

      case action
      when 'status'
        print_mcp_watchdog_status(analysis, max_per_server) unless quiet
      when 'doctor'
        doctor = mcp_watchdog_doctor(analysis, max_per_server)
        analysis[:doctor] = doctor
        persist_mcp_doctor_snapshot(analysis)
        print_mcp_watchdog_doctor(doctor) unless quiet
      when 'clean'
        cleaned = cleanup_mcp_processes(
          analysis,
          max_per_server,
          quiet: quiet,
          duplicate_grace_seconds: duplicate_grace_seconds
        )
        analysis[:cleaned] = cleaned
      when 'install'
        install_mcp_watchdog_launch_agent(interval_seconds, max_per_server)
      when 'uninstall'
        uninstall_mcp_watchdog_launch_agent
      else
        puts "❌ Unknown mcp_watchdog action: #{action}"
        puts '   Use one of: status, clean, install, uninstall'
        return
      end

      puts JSON.pretty_generate(analysis) if as_json
    end

    private

    MCP_PATTERNS = [
      ['apple-docs', /apple-docs-mcp|apple-docs/i],
      ['context7', /context7-mcp|context7/i],
      ['github', /mcp-server-github|server-github|@modelcontextprotocol\/server-github/i],
      ['xcode', /mcpbridge/i],
      ['memory', /server-memory|mcp-memory-enhanced\/server\.mjs|mcp-memory-enhanced/i],
      ['central-memory', /mcp-central-memory\/server\.mjs|central-memory-mcp/i],
      ['macos-automator', /macos-automator/i],
      ['serena', /serena start-mcp-server|github\.com\/oraios\/serena/i],
      ['chroma', /chroma-mcp/i],
      ['generic-mcp', /npx\/.*\/mcp|mcp-server\.cjs|worker-service\.cjs/i]
    ].freeze

    SERVER_SAFE_CAPS = {
      'xcode' => 8,
      'context7' => 6,
      'github' => 4,
      'apple-docs' => 4,
      'serena' => 4,
      'memory' => 4,
      'central-memory' => 4,
      'macos-automator' => 4,
      'chroma' => 4,
      'generic-mcp' => 4
    }.freeze
    SERVER_NAME_ALIASES = {}.freeze

    def capture_mcp_process_snapshot
      process_index = {}

      `ps -axo pid=,ppid=,etime=,%cpu=,state=,command=`.each_line do |line|
        match = line.match(/^\s*(\d+)\s+(\d+)\s+([0-9:\-]+)\s+([0-9.]+)\s+(\S+)\s+(.*)$/)
        next unless match

        pid = match[1].to_i
        ppid = match[2].to_i
        etimes = parse_etime_seconds(match[3].to_s)
        cpu = match[4].to_f
        state = match[5].to_s.strip
        cmd = match[6].to_s.strip

        process_index[pid] = {
          pid: pid,
          ppid: ppid,
          etimes: etimes,
          cpu: cpu,
          state: state,
          command: cmd
        }
      end

      build_mcp_process_snapshot(process_index)
    end

    def build_mcp_process_snapshot(process_index)
      annotate_codex_ownership!(process_index)

      processes = process_index.values.map do |proc_info|
        server = identify_mcp_server(proc_info[:command])
        next unless server

        proc_info.merge(
          server: server,
          instance_root_pid: mcp_instance_root_pid_for(proc_info[:pid], process_index, server: server)
        )
      end.compact

      all_pids = process_index.each_key.each_with_object({}) { |pid, memo| memo[pid] = true }

      {
        processes: processes,
        all_pids: all_pids,
        all_processes: process_index
      }
    end

    def parse_etime_seconds(etime)
      clean = etime.to_s.strip
      return 0 if clean.empty?

      days = 0
      clock = clean

      if clean.include?('-')
        day_part, clock_part = clean.split('-', 2)
        days = day_part.to_i
        clock = clock_part
      end

      parts = clock.split(':').map(&:to_i)
      case parts.length
      when 3
        hours, minutes, seconds = parts
      when 2
        hours = 0
        minutes, seconds = parts
      when 1
        hours = 0
        minutes = 0
        seconds = parts[0]
      else
        return 0
      end

      (days * 86_400) + (hours * 3600) + (minutes * 60) + seconds
    end

    def identify_mcp_server(command)
      return nil if shell_wrapper_command?(command)

      MCP_PATTERNS.each do |name, regex|
        return name if command.match?(regex)
      end
      nil
    end

    def shell_wrapper_command?(command)
      cmd = command.to_s.strip
      return true if cmd.start_with?('/bin/zsh -lc', '/bin/bash -lc', 'zsh -lc', 'bash -lc')
      return true if cmd.match?(%r{/mcp_singleton_bridge\.cjs\s+serve\s+\S+})

      false
    end

    def annotate_codex_ownership!(process_index)
      cache = {}

      process_index.each_value do |proc_info|
        owner_pid = codex_owner_pid_for(proc_info[:pid], process_index, cache)
        proc_info[:codex_owner_pid] = owner_pid
        proc_info[:codex_owner_command] = process_index[owner_pid]&.dig(:command)
        proc_info[:parent_command] = process_index[proc_info[:ppid]]&.dig(:command)
      end
    end

    def codex_owner_pid_for(pid, process_index, cache = {})
      return cache[pid] if cache.key?(pid)

      visited = {}
      current = pid
      owner_pid = nil

      while current && (proc_info = process_index[current])
        break if visited[current]

        if codex_app_server_command?(proc_info[:command])
          owner_pid = current
          break
        end

        visited[current] = true
        parent_pid = proc_info[:ppid].to_i
        break if parent_pid <= 1 || parent_pid == current

        current = parent_pid
      end

      cache[pid] = owner_pid
    end

    def codex_app_server_command?(command)
      command.to_s.match?(CODEX_APP_SERVER_PATTERN)
    end

    def mcp_instance_root_pid_for(pid, process_index, server:)
      current = pid
      visited = {}

      while current && (proc_info = process_index[current])
        break if visited[current]

        visited[current] = true
        parent_pid = proc_info[:ppid].to_i
        break if parent_pid <= 1 || parent_pid == current

        parent_info = process_index[parent_pid]
        break unless parent_info
        break unless identify_mcp_server(parent_info[:command]) == server

        current = parent_pid
      end

      current
    end

    def analyze_mcp_processes(snapshot, max_per_server, per_codex_server_cap: DEFAULT_PER_CODEX_SERVER_CAP)
      processes = snapshot[:processes]
      all_pids = snapshot[:all_pids]

      processes.each do |proc_info|
        ppid = proc_info[:ppid]
        proc_info[:orphan] = ppid <= 1 || !all_pids[ppid]
      end

      instances = build_mcp_instances(processes, snapshot[:all_processes], all_pids)
      by_server = instances.group_by { |instance| instance[:server] }
      raw_by_server = processes.group_by { |proc_info| proc_info[:server] }
      duplicate_servers = []
      by_server.each do |server, procs|
        server_cap = cap_for_server(server, max_per_server)
        next unless procs.length > server_cap

        duplicate_servers << { server: server, count: procs.length, cap: server_cap }
      end

      duplicate_codex_groups = build_duplicate_codex_groups(instances, per_codex_server_cap)
      codex_sidecars = detect_codex_sidecars(snapshot[:all_processes])

      {
        checked_at: Time.now.iso8601,
        total_processes: processes.length,
        total_instances: instances.length,
        max_per_server: max_per_server,
        by_server: by_server.transform_values(&:length),
        raw_by_server: raw_by_server.transform_values(&:length),
        orphan_processes: processes.select { |p| p[:orphan] },
        orphan_instances: instances.select { |instance| instance[:orphan] },
        duplicate_servers: duplicate_servers,
        duplicate_codex_groups: duplicate_codex_groups,
        codex_sidecars: codex_sidecars,
        instances: instances,
        processes: processes
      }
    end

    def cleanup_mcp_processes(analysis, max_per_server, quiet: false, duplicate_grace_seconds: 900)
      plan = plan_mcp_cleanup(analysis, max_per_server, duplicate_grace_seconds: duplicate_grace_seconds)
      pids_to_kill = plan[:pids].uniq
      killed = []
      failed = []

      pids_to_kill.each do |pid|
        begin
          Process.kill('TERM', pid)
          sleep(0.1)
          Process.kill('KILL', pid) if process_alive?(pid)
          killed << pid
        rescue Errno::ESRCH
          next
        rescue StandardError => e
          failed << { pid: pid, error: e.message }
        end
      end

      unless quiet
        puts '🧹 --- [ MCP WATCHDOG CLEANUP ] ---'
        puts "   Killed: #{killed.length}"
        puts "   Failed: #{failed.length}"
        puts "   Duplicate grace: #{duplicate_grace_seconds}s"
        puts "   MCP instance groups planned: #{plan[:instance_roots].length}"
        puts "   Codex sidecars planned: #{plan[:sidecar_pids].length}"
        puts ''
      end

      if killed.any?
        killed_by_server = analysis[:processes]
                           .select { |p| killed.include?(p[:pid]) }
                           .group_by { |p| p[:server] }
                           .transform_values(&:length)
        notify_mcp_cleanup(killed.length, killed_by_server)
      end

      { killed: killed, failed: failed }
    end

    def plan_mcp_cleanup(analysis, max_per_server, duplicate_grace_seconds: 900)
      instances = analysis[:instances] || analysis[:processes].group_by { |proc_info| proc_info[:instance_root_pid] }.values.map do |members|
        build_mcp_instance(members)
      end

      pids_to_kill = []
      instance_roots = []
      sidecar_pids = []

      analysis[:orphan_instances].each do |instance|
        instance_roots << instance[:root_pid]
        pids_to_kill.concat(instance[:pids])
      end

      instances.group_by { |instance| instance[:server] }.each do |server, server_instances|
        server_cap = cap_for_server(server, max_per_server)
        next unless server_instances.length > server_cap

        extras = cleanup_excess_instances(server_instances, server_cap, duplicate_grace_seconds)
        instance_roots.concat(extras.map { |instance| instance[:root_pid] })
        pids_to_kill.concat(extras.flat_map { |instance| instance[:pids] })
      end

      duplicate_codex_groups = analysis[:duplicate_codex_groups] || []
      duplicate_codex_groups.each do |group|
        group_instances = group[:instances] || []
        extras = cleanup_excess_instances(group_instances, group[:cap], 0)
        instance_roots.concat(extras.map { |instance| instance[:root_pid] })
        pids_to_kill.concat(extras.flat_map { |instance| instance[:pids] })
      end

      sidecars = Array(analysis[:codex_sidecars]).select { |sidecar| sidecar[:cleanup_eligible] }
      sidecar_pids.concat(sidecars.map { |sidecar| sidecar[:pid] })
      pids_to_kill.concat(sidecar_pids)

      {
        pids: pids_to_kill.uniq,
        instance_roots: instance_roots.uniq,
        sidecar_pids: sidecar_pids.uniq
      }
    end

    def cleanup_excess_instances(instances, cap, duplicate_grace_seconds)
      survivors = instances.sort_by { |instance| [instance[:orphan] ? 1 : 0, instance[:etimes], instance[:root_pid]] }.first(cap)
      survivor_ids = survivors.map { |instance| instance[:root_pid] }
      extras = instances.reject { |instance| survivor_ids.include?(instance[:root_pid]) }

      extras.select do |instance|
        instance[:orphan] || instance[:etimes].to_i >= duplicate_grace_seconds
      end
    end

    def build_mcp_instances(processes, process_index, all_pids)
      processes.group_by { |proc_info| proc_info[:instance_root_pid] }.values.map do |members|
        build_mcp_instance(members, process_index: process_index, all_pids: all_pids)
      end
    end

    def build_mcp_instance(members, process_index: nil, all_pids: nil)
      root_member = members.find { |member| member[:pid] == member[:instance_root_pid] } ||
                    members.min_by { |member| [member[:etimes], member[:pid]] }
      root_pid = root_member[:instance_root_pid] || root_member[:pid]
      root_proc = process_index&.[](root_pid) || root_member
      root_ppid = root_proc[:ppid].to_i
      orphan = if all_pids
                 root_ppid <= 1 || !all_pids[root_ppid]
               else
                 members.any? { |member| member[:orphan] }
               end

      {
        root_pid: root_pid,
        server: root_member[:server],
        codex_owner_pid: root_member[:codex_owner_pid],
        codex_owner_command: root_member[:codex_owner_command],
        pids: members.map { |member| member[:pid] }.sort,
        etimes: root_proc[:etimes] || root_member[:etimes],
        cpu: members.sum { |member| member[:cpu].to_f },
        orphan: orphan,
        process_count: members.length
      }
    end

    def build_duplicate_codex_groups(instances, per_codex_server_cap)
      instances.group_by { |instance| [instance[:server], instance[:codex_owner_pid]] }
               .map do |(server, owner_pid), owner_instances|
        next unless owner_pid.to_i.positive?
        next unless owner_instances.length > per_codex_server_cap

        {
          server: server,
          owner_pid: owner_pid,
          count: owner_instances.length,
          cap: per_codex_server_cap,
          instances: owner_instances
        }
      end.compact
    end

    def detect_codex_sidecars(process_index)
      process_index.values.map do |proc_info|
        next unless proc_info[:codex_owner_pid].to_i.positive?

        pattern = CODEX_SIDECAR_PATTERNS.find { |candidate| proc_info[:command].match?(candidate[:regex]) }
        next unless pattern

        cleanup_eligible = proc_info[:etimes].to_i >= pattern[:grace_seconds].to_i
        cleanup_eligible &&= proc_info[:cpu].to_f <= pattern[:max_cpu].to_f if pattern.key?(:max_cpu)

        {
          pid: proc_info[:pid],
          ppid: proc_info[:ppid],
          kind: pattern[:kind],
          etimes: proc_info[:etimes],
          cpu: proc_info[:cpu],
          command: proc_info[:command],
          codex_owner_pid: proc_info[:codex_owner_pid],
          cleanup_eligible: cleanup_eligible,
          grace_seconds: pattern[:grace_seconds]
        }
      end.compact
    end

    def process_alive?(pid)
      Process.getpgid(pid)
      true
    rescue Errno::ESRCH
      false
    rescue StandardError
      false
    end

    def notify_mcp_cleanup(killed_count, killed_by_server)
      return if killed_count <= 0

      summary = if killed_by_server.empty?
                  "Killed #{killed_count} duplicate/orphan MCP process#{killed_count == 1 ? '' : 'es'}."
                else
                  details = killed_by_server.sort_by { |server, _| server }
                                            .map { |server, count| "#{server}:#{count}" }
                                            .join(', ')
                  "Killed #{killed_count} MCP process#{killed_count == 1 ? '' : 'es'} (#{details})."
                end

      script = %(display notification "#{escape_osascript(summary)}" with title "SaneApps MCP Watchdog" subtitle "Auto-cleanup completed")
      system('/usr/bin/osascript', '-e', script, out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    def escape_osascript(text)
      text.to_s.gsub('"', '\"').gsub("\n", ' ')
    end

    def cap_for_server(server, max_per_server)
      [max_per_server.to_i, SERVER_SAFE_CAPS.fetch(server, max_per_server.to_i)].max
    end

    def print_mcp_watchdog_status(analysis, max_per_server)
      puts '🔌 --- [ MCP WATCHDOG STATUS ] ---'
      puts "   Total MCP processes: #{analysis[:total_processes]}"
      puts "   MCP instances: #{analysis[:total_instances]}"
      puts "   Max per server: #{max_per_server}"
      puts "   Per Codex cap: #{analysis[:per_codex_server_cap]}"
      puts ''

      if analysis[:by_server].empty?
        puts '   No MCP daemons detected.'
      else
        analysis[:by_server].sort_by { |server, _| server }.each do |server, count|
          server_cap = cap_for_server(server, max_per_server)
          marker = count > server_cap ? '⚠️' : '✅'
          raw_count = analysis[:raw_by_server].fetch(server, count)
          puts "   #{marker} #{server}: #{count} instance#{count == 1 ? '' : 's'} / #{raw_count} proc#{raw_count == 1 ? '' : 's'} (cap #{server_cap})"
        end
      end

      orphan_count = analysis[:orphan_instances].length
      puts ''
      puts "   Orphan instances: #{orphan_count}"
      puts "   Duplicates over cap: #{analysis[:duplicate_servers].length}"
      puts "   Duplicate Codex groups: #{analysis[:duplicate_codex_groups].length}"
      puts "   Stale Codex sidecars: #{Array(analysis[:codex_sidecars]).count { |sidecar| sidecar[:cleanup_eligible] }}"

      if analysis[:duplicate_servers].any? || analysis[:duplicate_codex_groups].any? || Array(analysis[:codex_sidecars]).any? { |sidecar| sidecar[:cleanup_eligible] }
        puts ''
        puts '   Run: ./scripts/SaneMaster.rb mcp_watchdog clean'
      end
      puts ''
    end

    def mcp_watchdog_doctor(analysis, max_per_server)
      configured_servers = configured_mcp_servers.map { |s| normalize_server_name(s) }.uniq.sort
      running_servers = analysis[:by_server].keys.map { |s| normalize_server_name(s) }.uniq.sort
      required_runtime_servers = required_runtime_mcp_servers(configured_servers)
      missing_runtime = required_runtime_servers - running_servers
      duplicate_servers = analysis[:duplicate_servers].map { |d| d[:server] }.sort
      duplicate_codex_servers = Array(analysis[:duplicate_codex_groups]).map { |d| d[:server] }.sort.uniq
      stale_sidecars = Array(analysis[:codex_sidecars]).select { |sidecar| sidecar[:cleanup_eligible] }
      live_probe = mcp_live_probe_snapshot

      {
        configured_servers: configured_servers,
        running_servers: running_servers,
        required_runtime_servers: required_runtime_servers,
        missing_runtime: missing_runtime,
        duplicate_servers: duplicate_servers,
        duplicate_codex_servers: duplicate_codex_servers,
        orphan_count: analysis[:orphan_instances].length,
        stale_sidecars: stale_sidecars,
        max_per_server: max_per_server,
        launch_agent: mcp_watchdog_launch_agent_status,
        recent_errors: mcp_watchdog_recent_errors,
        session_transport: mcp_watchdog_session_transport_errors,
        live_probe: live_probe,
        live_probe_failures: live_probe[:results].select { |result| result[:status].to_s == 'FAIL' }
      }
    end

    def print_mcp_watchdog_doctor(doctor)
      puts '🩺 --- [ MCP WATCHDOG DOCTOR ] ---'
      puts "   Configured MCPs: #{doctor[:configured_servers].join(', ')}"
      puts "   Running MCPs:    #{doctor[:running_servers].join(', ')}"
      puts ''

      if doctor[:required_runtime_servers].empty?
        puts '   ℹ️  No MCP servers marked as always-on required.'
      elsif doctor[:missing_runtime].empty?
        puts '   ✅ No configured MCPs are missing at runtime.'
      else
        puts "   ⚠️  Missing runtime MCPs: #{doctor[:missing_runtime].join(', ')}"
      end

      if doctor[:duplicate_servers].empty?
        puts '   ✅ No servers exceed cap.'
      else
        puts "   ⚠️  Servers over cap: #{doctor[:duplicate_servers].join(', ')}"
      end

      if doctor[:duplicate_codex_servers].empty?
        puts '   ✅ No per-session Codex duplicates detected.'
      else
        puts "   ⚠️  Per-session Codex duplicates: #{doctor[:duplicate_codex_servers].join(', ')}"
      end

      if doctor[:orphan_count].zero?
        puts '   ✅ No orphan MCP processes.'
      else
        puts "   ⚠️  Orphan MCP processes: #{doctor[:orphan_count]}"
      end

      if doctor[:stale_sidecars].empty?
        puts '   ✅ No stale Codex sidecars detected.'
      else
        kinds = doctor[:stale_sidecars].map { |sidecar| "#{sidecar[:kind]}(pid #{sidecar[:pid]})" }
        puts "   ⚠️  Stale Codex sidecars: #{kinds.join(', ')}"
      end

      launch = doctor[:launch_agent]
      puts ''
      puts "   LaunchAgent loaded: #{launch[:loaded] ? 'yes' : 'no'}"
      puts "   LaunchAgent state:  #{launch[:state]}"
      puts "   LaunchAgent exit:   #{launch[:last_exit]}"

      if doctor[:recent_errors].any?
        puts ''
        puts '   Recent watchdog errors:'
        doctor[:recent_errors].each { |line| puts "   - #{line}" }
      else
        puts '   ✅ No recent watchdog errors.'
      end

      live_probe = doctor[:live_probe] || { available: false, results: [] }
      puts ''
      if live_probe[:available]
        failures = Array(doctor[:live_probe_failures])
        if failures.empty?
          puts "   ✅ Live Codex MCP probe passed: #{live_probe[:command]}"
        else
          puts "   ❌ Live Codex MCP probe failed: #{live_probe[:command]}"
          failures.each do |failure|
            puts "   - #{failure[:name]}: #{failure[:detail]}"
          end
          puts '   Process presence is not enough; fix the configured endpoint or bridge before relying on MCPs.'
        end
      else
        puts '   ℹ️  Live Codex MCP probe unavailable (~/.codex/bin/check-mcps not executable).'
      end

      session_transport = doctor[:session_transport] || {}
      if session_transport[:total].to_i.positive?
        puts ''
        puts "   ⚠️  Session transport failures (last #{session_transport[:window_seconds]}s): #{session_transport[:total]}"
        by_server = session_transport[:by_server] || {}
        by_server.sort_by { |name, _| name.to_s }.each do |name, count|
          puts "   - #{name}: #{count}"
        end
        if session_transport[:latest_session]
          puts "   Latest session: #{session_transport[:latest_session]}"
        end
        puts '   Likely stale MCP bridge in current Codex session.'
        puts '   Fastest recovery: restart Codex app/session.'
      else
        puts '   ✅ No recent session transport failures detected.'
      end

      puts ''
    end

    def mcp_live_probe_snapshot
      checker = File.expand_path('~/.codex/bin/check-mcps')
      return { available: false, command: checker, results: [] } unless File.executable?(checker)

      output, status = Open3.capture2e(checker)
      results = output.lines.map do |line|
        match = line.match(/^\[(PASS|WARN|FAIL)\]\s+([^\s]+)\s+-\s+(.*)$/)
        next unless match

        { status: match[1], name: match[2], detail: match[3].strip }
      end.compact
      results << { status: 'FAIL', name: 'check-mcps', detail: 'no parseable status lines returned' } if results.empty?
      results << { status: 'FAIL', name: 'check-mcps', detail: "exited #{status.exitstatus}" } unless status.success?
      { available: true, command: checker, results: results }
    rescue StandardError => e
      { available: true, command: checker, results: [{ status: 'FAIL', name: 'check-mcps', detail: e.message }] }
    end

    def configured_mcp_servers
      mcp_config_paths.each_with_object([]) do |path, servers|
        next unless File.exist?(path)

        contents = File.read(path)
        servers.concat(path.end_with?('.toml') ? mcp_servers_from_toml(contents) : mcp_servers_from_json(contents))
      rescue StandardError
        next
      end.map { |name| normalize_server_name(name) }.uniq.sort
    end

    def mcp_config_paths
      [
        File.expand_path('~/.mcp.json'),
        File.join(Dir.pwd, '.mcp.json'),
        File.expand_path('~/.claude/settings.json'),
        File.expand_path('~/.config/claude/mcp-config.json'),
        File.join(Dir.pwd, '.claude', 'settings.json'),
        File.expand_path('~/.codex/config.toml'),
        File.join(Dir.pwd, '.codex', 'config.toml'),
        File.expand_path('~/.grok/config.toml'),
        File.join(Dir.pwd, '.grok', 'config.toml')
      ].uniq
    end

    def mcp_servers_from_json(contents)
      json = JSON.parse(contents)
      servers = []
      servers.concat(json['mcpServers'].keys) if json['mcpServers'].is_a?(Hash)
      permissions = Array(json.dig('permissions', 'allow')) + Array(json.dig('permissions', 'ask'))
      permissions.each do |permission|
        name = permission.to_s[/\Amcp__(.+?)__/, 1]
        servers << name if name
      end
      servers
    end

    def mcp_servers_from_toml(contents)
      contents.scan(/^\s*\[mcp_servers\.([^\]]+)\]/).flatten.reject do |name|
        name.include?('.')
      end.map do |name|
        name.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'")
      end
    rescue StandardError
      []
    end

    def normalize_server_name(name)
      SERVER_NAME_ALIASES.fetch(name.to_s, name.to_s)
    end

    def required_runtime_mcp_servers(configured_servers)
      raw = ENV['SANEMASTER_MCP_REQUIRED'].to_s.strip
      return [] if raw.empty?

      required = raw.split(',').map(&:strip).reject(&:empty?).map { |s| normalize_server_name(s) }.uniq
      configured_servers.select { |s| required.include?(s) }
    end

    def mcp_watchdog_launch_agent_status
      label = 'com.saneapps.mcp-watchdog'
      cmd = ['launchctl', 'print', "gui/#{Process.uid}/#{label}"]
      output, status = Open3.capture2e(*cmd)

      unless status.success?
        return {
          loaded: false,
          state: 'not loaded',
          last_exit: 'unknown'
        }
      end

      state = output[/state = ([^\n]+)/, 1] || 'unknown'
      last_exit = output[/last exit code = ([^\n]+)/, 1] || 'unknown'
      {
        loaded: true,
        state: state.strip,
        last_exit: last_exit.strip
      }
    rescue StandardError
      {
        loaded: false,
        state: 'unknown',
        last_exit: 'unknown'
      }
    end

    def mcp_watchdog_recent_errors
      log_path = File.expand_path('~/Library/Logs/SaneApps/mcp-watchdog.err.log')
      return [] unless File.exist?(log_path)
      return [] if (Time.now - File.mtime(log_path)) > 900

      lines = File.readlines(log_path).last(120)
      hits = []
      lines.each do |line|
        text = line.to_s.strip
        next if text.empty?
        next unless text.match?(/error|failed|exception|nomethoderror|transport closed/i)

        hits << text
      end
      hits.uniq.last(6)
    rescue StandardError
      []
    end

    def mcp_watchdog_session_transport_errors(window_seconds = 3600)
      sessions_root = File.expand_path('~/.codex/sessions')
      latest = Dir.glob(File.join(sessions_root, '**', '*.jsonl'))
                  .max_by { |path| File.mtime(path) rescue Time.at(0) }

      result = {
        window_seconds: window_seconds,
        total: 0,
        by_server: {},
        latest_session: latest
      }
      return result unless latest && File.exist?(latest)

      cutoff = Time.now - window_seconds
      call_to_tool = {}
      by_tool = Hash.new(0)

      File.foreach(latest) do |line|
        begin
          row = JSON.parse(line)
          payload = row['payload']
          next unless payload.is_a?(Hash)

          ts = parse_mcp_row_timestamp(row['timestamp'])
          next if ts && ts < cutoff

          if payload['type'] == 'function_call'
            name = payload['name'].to_s
            call_id = payload['call_id'].to_s
            if name.start_with?('mcp__') && !call_id.empty?
              call_to_tool[call_id] = name
            end
          elsif payload['type'] == 'function_call_output'
            output = payload['output'].to_s
            next unless output.include?('Transport closed')

            call_id = payload['call_id'].to_s
            tool_name = call_to_tool[call_id]
            next if tool_name.to_s.empty?

            by_tool[tool_name] += 1
          end
        rescue StandardError
          next
        end
      end

      by_server = Hash.new(0)
      by_tool.each do |tool_name, count|
        server = extract_mcp_server_name(tool_name)
        by_server[server] += count
      end

      result[:total] = by_tool.values.sum
      result[:by_server] = by_server
      result
    end

    def parse_mcp_row_timestamp(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    def extract_mcp_server_name(tool_name)
      match = tool_name.to_s.match(/^mcp__([^_]+)__/)
      return 'unknown' unless match

      normalize_server_name(match[1])
    end

    def persist_mcp_doctor_snapshot(payload)
      snapshot_dir = File.join(Dir.pwd, '.claude')
      snapshot_path = File.join(snapshot_dir, 'mcp_doctor_last.json')
      FileUtils.mkdir_p(snapshot_dir)
      File.write(snapshot_path, JSON.pretty_generate(payload))
    rescue StandardError
      nil
    end

    def install_mcp_watchdog_launch_agent(interval_seconds, max_per_server)
      label = 'com.saneapps.mcp-watchdog'
      launch_agents_dir = File.expand_path('~/Library/LaunchAgents')
      logs_dir = File.expand_path('~/Library/Logs/SaneApps')
      plist_path = File.join(launch_agents_dir, "#{label}.plist")
      sanemaster_script = File.expand_path('../SaneMaster.rb', __dir__)
      ruby_bin = File.exist?(HOMEBREW_RUBY) ? HOMEBREW_RUBY : '/usr/bin/ruby'
      out_log = File.join(logs_dir, 'mcp-watchdog.out.log')
      err_log = File.join(logs_dir, 'mcp-watchdog.err.log')

      FileUtils.mkdir_p(launch_agents_dir)
      FileUtils.mkdir_p(logs_dir)
      File.write(out_log, '')
      File.write(err_log, '')

      plist = <<~PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>#{label}</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{ruby_bin}</string>
            <string>#{sanemaster_script}</string>
            <string>mcp_watchdog</string>
            <string>clean</string>
            <string>--quiet</string>
            <string>--max</string>
            <string>#{max_per_server}</string>
            <string>--grace</string>
            <string>0</string>
          </array>
          <key>StartInterval</key>
          <integer>#{interval_seconds}</integer>
          <key>RunAtLoad</key>
          <true/>
          <key>StandardOutPath</key>
          <string>#{out_log}</string>
          <key>StandardErrorPath</key>
          <string>#{err_log}</string>
        </dict>
        </plist>
      PLIST

      File.write(plist_path, plist)

      system('launchctl', 'unload', plist_path, out: File::NULL, err: File::NULL)
      system('launchctl', 'load', '-w', plist_path)

      puts '✅ MCP watchdog launch agent installed.'
      puts "   Interval: #{interval_seconds}s"
      puts "   Cap per server: #{max_per_server}"
      puts "   Plist: #{plist_path}"
      puts ''
    end

    def uninstall_mcp_watchdog_launch_agent
      label = 'com.saneapps.mcp-watchdog'
      plist_path = File.expand_path("~/Library/LaunchAgents/#{label}.plist")

      unless File.exist?(plist_path)
        puts 'ℹ️  MCP watchdog launch agent is not installed.'
        puts ''
        return
      end

      system('launchctl', 'unload', plist_path, out: File::NULL, err: File::NULL)
      File.delete(plist_path)

      puts '✅ MCP watchdog launch agent removed.'
      puts ''
    end

    def determine_version_status(installed, latest)
      if installed == 'not installed'
        '❌ missing'
      elsif latest == 'unknown'
        '❓ unknown'
      elsif Gem::Version.new(installed.gsub(/[^\d.]/, '')) >= Gem::Version.new(latest.gsub(/[^\d.]/, ''))
        '✅ current'
      else
        '⬆️  update available'
      end
    end

    def fetch_homebrew_version(formula)
      output = `brew info #{formula} 2>/dev/null`.lines.first
      version = output&.match(/stable ([\d.]+)/)&.[](1) ||
                output&.match(/#{formula}[:\s]+([\d.]+)/)&.[](1)
      return 'unknown' if version&.match?(/alpha|beta|rc|pre/i)

      version || 'unknown'
    end

    def fetch_github_version(repo)
      output = `curl -s "https://api.github.com/repos/#{repo}/releases" 2>/dev/null`
      releases = JSON.parse(output)
      stable = releases.find { |r| !r['prerelease'] && !r['draft'] }
      version = stable&.dig('tag_name')&.gsub(/^v/, '')
      return 'unknown' if version&.match?(/alpha|beta|rc|pre/i)

      version || 'unknown'
    rescue StandardError
      'unknown'
    end

    def fetch_rubygems_version(gem_name)
      output = `gem search ^#{gem_name}$ --remote 2>/dev/null`
      version = output&.match(/#{gem_name} \(([\d.]+)\)/)&.[](1)
      return 'unknown' if version&.match?(/alpha|beta|rc|pre/i)

      version || 'unknown'
    end

    def scan_swift_packages
      package_file = File.join(project_xcodeproj, 'project.xcworkspace/xcshareddata/swiftpm/Package.resolved')
      package_file = 'Package.resolved' unless File.exist?(package_file)
      return [] unless File.exist?(package_file)

      data = JSON.parse(File.read(package_file))
      pins = data['pins'] || data.dig('object', 'pins') || []
      pins.map do |pin|
        {
          name: pin['identity'] || pin['package'],
          version: pin.dig('state', 'version') || pin.dig('state', 'revision')&.[](0..6) || 'branch',
          url: pin['location'] || pin['repositoryURL']
        }
      end
    rescue StandardError
      []
    end

    def scan_ruby_gems
      return [] unless File.exist?('Gemfile.lock')

      gems = []
      in_specs = false

      File.readlines('Gemfile.lock').each do |line|
        stripped = line.strip
        if stripped == 'specs:'
          in_specs = true
        elsif in_specs && line.match(/^\s{4}(\S+)\s+\(([\d.]+)\)/)
          gems << { name: ::Regexp.last_match(1), version: ::Regexp.last_match(2) }
        elsif stripped == 'GEM' || stripped.empty? || line.start_with?('PLATFORMS')
          in_specs = false
        end
      end

      gems.first(15)
    end

    def scan_homebrew_deps
      TOOL_SOURCES.keys.map do |tool|
        version = get_installed_version(tool)
        { name: tool, version: version } if version != 'not installed'
      end.compact
    end

    def scan_frameworks
      frameworks = Set.new
      Dir.glob(File.join(project_app_dir, '**/*.swift')).each do |file|
        File.readlines(file).each do |line|
          if line.match(/^import\s+(\w+)/)
            fw = ::Regexp.last_match(1)
            frameworks << fw unless %w[Foundation SwiftUI Combine].include?(fw)
          end
        end
      rescue StandardError
        next
      end
      frameworks.to_a.sort.map { |f| { name: f, version: 'system' } }
    end

    def print_ascii_graph(deps)
      puts ''
      puts '┌─────────────────────────────────────────────────────────┐'
      puts format('│%39s│', project_name.center(39))
      puts '└─────────────────────────────────────────────────────────┘'
      puts '                           │'

      print_package_section('Swift Packages', deps[:swift_packages])
      print_gem_section(deps[:ruby_gems])
      print_tool_section(deps[:homebrew])
      print_framework_section(deps[:frameworks])

      puts ''
      puts "📊 Total: #{deps[:swift_packages].count} Swift packages, #{deps[:ruby_gems].count} gems, " \
           "#{deps[:homebrew].count} tools, #{deps[:frameworks].count} frameworks"
    end

    def print_package_section(title, packages)
      return unless packages.any?

      puts '          ┌────────────────┴────────────────┐'
      puts "          │        #{title.ljust(24)}│"
      puts '          └─────────────────────────────────┘'
      packages.each { |pkg| puts "                    ├── #{pkg[:name]} (#{pkg[:version]})" }
      puts ''
    end

    def print_gem_section(gems)
      return unless gems.any?

      puts '          ┌─────────────────────────────────┐'
      puts '          │          Ruby Gems              │'
      puts '          └─────────────────────────────────┘'
      gems.first(10).each { |gem| puts "                    ├── #{gem[:name]} (#{gem[:version]})" }
      puts "                    └── ... and #{gems.count - 10} more" if gems.count > 10
      puts ''
    end

    def print_tool_section(tools)
      return unless tools.any?

      puts '          ┌─────────────────────────────────┐'
      puts '          │        Homebrew Tools           │'
      puts '          └─────────────────────────────────┘'
      tools.each { |tool| puts "                    ├── #{tool[:name]} (#{tool[:version]})" }
      puts ''
    end

    def print_framework_section(frameworks)
      return unless frameworks.any?

      puts '          ┌─────────────────────────────────┐'
      puts '          │       Apple Frameworks          │'
      puts '          └─────────────────────────────────┘'
      frameworks.first(15).each { |fw| puts "                    ├── #{fw[:name]}" }
      puts "                    └── ... and #{frameworks.count - 15} more" if frameworks.count > 15
    end

    def generate_dot_graph(deps)
      dot_file = 'dependencies.dot'
      File.open(dot_file, 'w') do |f|
        f.puts 'digraph Dependencies {'
        f.puts '  rankdir=TB;'
        f.puts '  node [shape=box];'
        f.puts ''
        f.puts "  #{project_name} [style=filled, fillcolor=lightblue];"
        f.puts ''

        deps[:swift_packages].each do |pkg|
          f.puts "  \"#{pkg[:name]}\" [label=\"#{pkg[:name]}\\n#{pkg[:version]}\"];"
          f.puts "  #{project_name} -> \"#{pkg[:name]}\";"
        end

        deps[:homebrew].each do |tool|
          f.puts "  \"#{tool[:name]}\" [label=\"#{tool[:name]}\\n#{tool[:version]}\", style=filled, fillcolor=lightyellow];"
          f.puts "  #{project_name} -> \"#{tool[:name]}\" [style=dashed];"
        end

        f.puts '}'
      end

      puts "✅ Generated: #{dot_file}"
      puts '💡 View with: dot -Tpng dependencies.dot -o dependencies.png && open dependencies.png'
    end

    def check_mcp_config_file(config_path, sop_mcps, all_valid)
      puts "📄 Checking: #{config_path}"
      config = JSON.parse(File.read(config_path))
      servers = config['mcpServers'] || {}

      sop_mcps.each do |name, info|
        if servers.key?(name)
          package = servers[name]['args']&.last || 'unknown'
          puts "   ✅ #{name}: Configured (#{package})"
        else
          puts "   ❌ #{name}: MISSING"
          all_valid = false if info[:required]
        end
      end

      extra = servers.keys - sop_mcps.keys
      puts "   📦 Extra servers: #{extra.join(', ')}" if extra.any?
      puts "   📊 Total: #{servers.length} servers"
      puts ''
      all_valid
    rescue JSON::ParserError => e
      puts "   ❌ Invalid JSON: #{e.message}"
      puts ''
      false
    end

    def print_mcp_verification_summary(all_valid)
      puts ''
      if all_valid
        puts '✅ All required MCPs are configured'
        puts ''
        puts '💡 To verify MCPs are working, use the active client MCP UI or `~/.codex/bin/check-mcps` when installed.'
      else
        puts '❌ Some required MCPs are missing or misconfigured'
        puts ''
        puts '💡 Fix by:'
        puts '   Add missing MCPs to the active client config or to project .mcp.json, then rerun MCP verification.'
      end
    end
  end
end
