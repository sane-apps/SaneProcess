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
        puts '💡 Run `brew upgrade <tool>` or `./Scripts/SaneMaster.rb bootstrap` to update'
      end

      puts "\n🔄 To refresh cache: ./Scripts/SaneMaster.rb versions --refresh"
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
        output = `#{HOMEBREW_BUNDLE} exec fastlane --version 2>/dev/null`
        output.match(/fastlane ([\d.]+)/)&.[](1) || 'not installed'
      when 'ruby'
        output = `#{HOMEBREW_RUBY} --version 2>/dev/null`
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
        'apple-docs' => { package: '@mweinbach/apple-docs-mcp@latest', required: true },
        'github' => { package: '@modelcontextprotocol/server-github', required: true },
        'context7' => { package: '@upstash/context7-mcp@latest', required: true },
        'xcode' => { package: 'mcpbridge', required: true },
        'macos-automator' => { package: '@steipete/macos-automator-mcp', required: true }
      }

      config_paths = ['.mcp.json', '.cursor/mcp.json']
      all_valid = true

      config_paths.each do |config_path|
        next unless File.exist?(config_path)

        all_valid = check_mcp_config_file(config_path, sop_mcps, all_valid)
      end

      unless File.exist?('.cursor/mcp.json')
        puts '⚠️  .cursor/mcp.json not found (Cursor may use this location)'
        puts '   Run: cp .mcp.json .cursor/mcp.json'
        all_valid = false
      end

      print_mcp_verification_summary(all_valid)
    end

    def mcp_watchdog(args)
      action = 'status'
      quiet = false
      as_json = false
      max_per_server = 6
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
        when '--interval'
          i += 1
          interval_seconds = [args[i].to_i, 60].max if args[i]
        when '--grace'
          i += 1
          duplicate_grace_seconds = [args[i].to_i, 0].max if args[i]
        else
          action = arg unless arg.start_with?('--')
        end
        i += 1
      end

      snapshot = capture_mcp_process_snapshot
      analysis = analyze_mcp_processes(snapshot, max_per_server)
      analysis[:duplicate_grace_seconds] = duplicate_grace_seconds

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
      ['memory', /server-memory/i],
      ['macos-automator', /macos-automator/i],
      ['serena', /serena start-mcp-server|github\.com\/oraios\/serena/i],
      ['nvidia', /nvidia_mcp_server/i],
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
      'macos-automator' => 4,
      'nvidia' => 4,
      'chroma' => 4,
      'generic-mcp' => 4
    }.freeze
    SERVER_NAME_ALIASES = {
      'nvidia' => 'nvidia-build'
    }.freeze

    def capture_mcp_process_snapshot
      all_pids = {}
      processes = []

      `ps -axo pid=,ppid=,etime=,command=`.each_line do |line|
        match = line.match(/^\s*(\d+)\s+(\d+)\s+([0-9:\-]+)\s+(.*)$/)
        next unless match

        pid = match[1].to_i
        ppid = match[2].to_i
        etimes = parse_etime_seconds(match[3].to_s)
        cmd = match[4].to_s.strip
        all_pids[pid] = true

        server = identify_mcp_server(cmd)
        next unless server

        processes << {
          pid: pid,
          ppid: ppid,
          etimes: etimes,
          command: cmd,
          server: server
        }
      end

      { processes: processes, all_pids: all_pids }
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

      false
    end

    def analyze_mcp_processes(snapshot, max_per_server)
      processes = snapshot[:processes]
      all_pids = snapshot[:all_pids]

      processes.each do |proc_info|
        ppid = proc_info[:ppid]
        proc_info[:orphan] = ppid <= 1 || !all_pids[ppid]
      end

      by_server = processes.group_by { |p| p[:server] }
      duplicate_servers = []
      by_server.each do |server, procs|
        server_cap = cap_for_server(server, max_per_server)
        next unless procs.length > server_cap

        duplicate_servers << { server: server, count: procs.length, cap: server_cap }
      end

      {
        checked_at: Time.now.iso8601,
        total_processes: processes.length,
        max_per_server: max_per_server,
        by_server: by_server.transform_values(&:length),
        orphan_processes: processes.select { |p| p[:orphan] },
        duplicate_servers: duplicate_servers,
        processes: processes
      }
    end

    def cleanup_mcp_processes(analysis, max_per_server, quiet: false, duplicate_grace_seconds: 900)
      processes = analysis[:processes]
      by_server = processes.group_by { |p| p[:server] }
      pids_to_kill = []

      # Always prioritize orphaned daemons.
      pids_to_kill.concat(analysis[:orphan_processes].map { |p| p[:pid] })

      # Then enforce per-server caps to prevent runaway duplicate MCP trees.
      by_server.each do |server, procs|
        server_cap = cap_for_server(server, max_per_server)
        next unless procs.length > server_cap

        survivors = procs.sort_by { |p| [p[:orphan] ? 1 : 0, p[:etimes]] }.first(server_cap)
        survivor_ids = survivors.map { |p| p[:pid] }
        extras = procs.reject { |p| survivor_ids.include?(p[:pid]) }
        extras = extras.select { |p| p[:orphan] || p[:etimes].to_i >= duplicate_grace_seconds }
        pids_to_kill.concat(extras.map { |p| p[:pid] })
      end

      pids_to_kill = pids_to_kill.uniq
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
      puts "   Max per server: #{max_per_server}"
      puts ''

      if analysis[:by_server].empty?
        puts '   No MCP daemons detected.'
      else
        analysis[:by_server].sort_by { |server, _| server }.each do |server, count|
          server_cap = cap_for_server(server, max_per_server)
          marker = count > server_cap ? '⚠️' : '✅'
          puts "   #{marker} #{server}: #{count} (cap #{server_cap})"
        end
      end

      orphan_count = analysis[:orphan_processes].length
      puts ''
      puts "   Orphans: #{orphan_count}"
      puts "   Duplicates over cap: #{analysis[:duplicate_servers].length}"

      if analysis[:duplicate_servers].any?
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

      {
        configured_servers: configured_servers,
        running_servers: running_servers,
        required_runtime_servers: required_runtime_servers,
        missing_runtime: missing_runtime,
        duplicate_servers: duplicate_servers,
        orphan_count: analysis[:orphan_processes].length,
        max_per_server: max_per_server,
        launch_agent: mcp_watchdog_launch_agent_status,
        recent_errors: mcp_watchdog_recent_errors
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

      if doctor[:orphan_count].zero?
        puts '   ✅ No orphan MCP processes.'
      else
        puts "   ⚠️  Orphan MCP processes: #{doctor[:orphan_count]}"
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

      puts ''
    end

    def configured_mcp_servers
      config_path = File.join(Dir.pwd, '.mcp.json')
      return [] unless File.exist?(config_path)

      raw = File.read(config_path)
      json = JSON.parse(raw)
      servers = json['mcpServers']
      return [] unless servers.is_a?(Hash)

      servers.keys.sort
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
      TOOL_SOURCES.keys.filter_map do |tool|
        version = get_installed_version(tool)
        { name: tool, version: version } if version != 'not installed'
      end
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
        puts '💡 To verify MCPs are working in Cursor:'
        puts '   1. Restart Cursor'
        puts '   2. Check Settings > MCP Tools'
      else
        puts '❌ Some required MCPs are missing or misconfigured'
        puts ''
        puts '💡 Fix by:'
        puts '   1. Add missing MCPs to .mcp.json'
        puts '   2. Copy to .cursor/mcp.json: cp .mcp.json .cursor/mcp.json'
        puts '   3. Restart Cursor'
      end
    end
  end
end
