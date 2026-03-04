# frozen_string_literal: true

module SaneMasterModules
  # Environment setup, auto-update, rollback, health checks
  module Bootstrap
    include Base

    def run_bootstrap(args)
      check_only = args.include?('--check-only') || args.include?('--check')
      rollback = args.include?('--rollback')
      auto_fix = !args.include?('--no-fix')

      puts '🚀 --- [ SANEMASTER BOOTSTRAP ] ---'
      mode_str = determine_mode_string(check_only, rollback, auto_fix)
      puts "Mode: #{mode_str}"
      puts ''

      ensure_sop_dirs
      @sop_log = File.join(SOP_LOG_DIR, "sop_#{Time.now.strftime('%Y%m%d_%H%M%S')}.log")
      sop_log("SOP Bootstrap started - #{mode_str.downcase}")

      return perform_rollback if rollback

      create_snapshot unless check_only

      results = run_all_checks(check_only)
      results[:auto_fix] = handle_auto_fix(results, auto_fix, check_only)

      show_memory_context_summary unless check_only
      print_sop_summary(results, check_only)

      sop_log("SOP Bootstrap completed - #{results.values.all? { |r| [:ok, true].include?(r) } ? 'SUCCESS' : 'ISSUES FOUND'}")
    end

    def fix_common_issues(issues)
      puts "\n🔧 Auto-fixing common issues..."
      fixed = []

      if issues.any? { |i| i.include?('stuck build processes') }
        puts '   🔪 Killing stuck xcodebuild/xctest processes...'
        system('killall -9 xcodebuild 2>/dev/null')
        system('killall -9 xctest 2>/dev/null')
        system("killall -9 #{project_name} 2>/dev/null")
        fixed << 'Killed stuck processes'
        sop_log('Auto-fix: killed stuck build processes')
      end

      if issues.any? { |i| i.include?('DerivedData') }
        puts "   🧹 Clearing #{project_name} DerivedData..."
        dd_path = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*")
        Dir.glob(dd_path).each { |d| FileUtils.rm_rf(d) }
        fixed << 'Cleared DerivedData'
        sop_log('Auto-fix: cleared DerivedData')
      end

      if fixed.any?
        puts "   ✅ Fixed: #{fixed.join(', ')}"
        :fixed
      else
        :nothing_to_fix
      end
    end

    private

    def determine_mode_string(check_only, rollback, auto_fix)
      if check_only
        'CHECK ONLY'
      elsif rollback
        'ROLLBACK'
      else
        auto_fix ? 'FULL UPDATE + AUTO-FIX' : 'FULL UPDATE'
      end
    end

    def run_all_checks(check_only)
      {
        ruby: check_ruby_environment(check_only),
        bundle: check_bundle(check_only),
        homebrew_tools: check_homebrew_tools(check_only),
        claude_plugins: check_claude_plugins,
        mcp_servers: check_mcp_config,
        doctor: run_doctor_check,
        auto_fix: nil
      }
    end

    def run_doctor_check
      puts "\n📋 Running doctor health check..."
      doctor_silent
    end

    def handle_auto_fix(results, auto_fix, check_only)
      return nil unless auto_fix && !check_only && results[:doctor].is_a?(Array) && results[:doctor].any?

      result = fix_common_issues(results[:doctor])
      results[:doctor] = doctor_silent
      result
    end

    def create_snapshot
      puts '📸 Creating configuration snapshot...'
      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      snapshot_dir = File.join(SOP_SNAPSHOT_DIR, timestamp)
      FileUtils.mkdir_p(snapshot_dir)

      snapshot_config_files(snapshot_dir)
      snapshot_tool_versions(snapshot_dir)
      update_latest_symlink(snapshot_dir)

      puts "   ✅ Snapshot saved: #{snapshot_dir}"
      sop_log("Snapshot created: #{snapshot_dir}")
    end

    def snapshot_config_files(snapshot_dir)
      files_to_snapshot = %w[Gemfile Gemfile.lock .ruby-version .claude/settings.local.json .mcp.json]

      files_to_snapshot.each do |file|
        src = File.join(Dir.pwd, file)
        next unless File.exist?(src)

        dest_dir = File.join(snapshot_dir, File.dirname(file))
        FileUtils.mkdir_p(dest_dir)
        FileUtils.cp(src, File.join(snapshot_dir, file))
      end
    end

    def snapshot_tool_versions(snapshot_dir)
      versions = {}
      TOOL_VERSIONS.each do |tool, config|
        version = `#{config[:cmd]} 2>/dev/null`.strip
        version = version.match(config[:extract])[1] if config[:extract] && version.match(config[:extract])
        versions[tool] = version
      end
      versions['ruby'] = begin
        `#{HOMEBREW_RUBY} --version 2>/dev/null`.strip.split[1]
      rescue StandardError
        'unknown'
      end

      File.write(File.join(snapshot_dir, 'versions.json'), JSON.pretty_generate(versions))
    end

    def update_latest_symlink(snapshot_dir)
      latest_link = File.join(SOP_SNAPSHOT_DIR, 'latest')
      FileUtils.rm_f(latest_link)
      FileUtils.ln_s(snapshot_dir, latest_link)
    end

    def perform_rollback
      latest = File.join(SOP_SNAPSHOT_DIR, 'latest')
      unless File.exist?(latest)
        puts '❌ No snapshot found to rollback to'
        return
      end

      snapshot_dir = File.realpath(latest)
      puts "🔄 Rolling back to: #{snapshot_dir}"

      %w[Gemfile Gemfile.lock .ruby-version].each do |file|
        src = File.join(snapshot_dir, file)
        next unless File.exist?(src)

        FileUtils.cp(src, File.join(Dir.pwd, file))
        puts "   ✅ Restored: #{file}"
      end

      puts '📦 Re-installing bundle...'
      system("#{HOMEBREW_BUNDLE} install")

      puts "\n✅ Rollback complete"
      sop_log("Rollback performed from: #{snapshot_dir}")
    end

    def check_ruby_environment(check_only)
      puts '💎 Checking Ruby environment...'

      unless File.exist?(HOMEBREW_RUBY)
        puts '   ❌ Homebrew Ruby not found. Install: brew install ruby'
        sop_log('Ruby: Homebrew Ruby not installed')
        return :missing
      end

      version = `#{HOMEBREW_RUBY} --version 2>/dev/null`.strip
      puts "   Ruby: #{version}"

      check_ruby_version_file(check_only, version)
      check_rubygems_version

      sop_log("Ruby check: #{version}")
      :ok
    end

    def check_ruby_version_file(check_only, version)
      ruby_version_file = File.join(Dir.pwd, '.ruby-version')
      if File.exist?(ruby_version_file)
        puts '   ✅ .ruby-version exists'
      elsif !check_only
        ruby_ver = begin
          version.match(/ruby ([\d.]+)/)[1]
        rescue StandardError
          '3.4'
        end
        File.write(ruby_version_file, "#{ruby_ver}\n")
        puts "   ✅ Created .ruby-version (#{ruby_ver})"
        sop_log("Created .ruby-version: #{ruby_ver}")
      else
        puts '   ⚠️  .ruby-version missing'
      end
    end

    def check_rubygems_version
      gems_version = `#{HOMEBREW_RUBY} -e "puts Gem::VERSION" 2>/dev/null`.strip
      if Gem::Version.new(gems_version) >= Gem::Version.new('3.2.0')
        puts "   ✅ RubyGems #{gems_version}"
      else
        puts "   ⚠️  RubyGems #{gems_version} (upgrade recommended)"
      end
    end

    def check_bundle(check_only)
      puts "\n📦 Checking bundle dependencies..."

      unless File.exist?(HOMEBREW_BUNDLE)
        puts '   ❌ Homebrew bundle not found'
        return :missing
      end

      bundle_check = `#{HOMEBREW_BUNDLE} check 2>&1`
      if bundle_check.include?('dependencies are satisfied')
        puts '   ✅ Bundle dependencies satisfied'
        sop_log('Bundle: dependencies satisfied')
        return :ok if check_only
      end

      return :ok if check_only

      puts '   🔄 Running bundle update...'
      if system("#{HOMEBREW_BUNDLE} update 2>&1")
        puts '   ✅ Bundle updated'
        sop_log('Bundle: updated successfully')
        system('lefthook install -f 2>/dev/null')
      else
        puts '   ❌ Bundle update failed'
        sop_log('Bundle: update failed')
        return :failed
      end

      :ok
    end

    def check_homebrew_tools(check_only)
      puts "\n🍺 Checking Homebrew tools..."

      outdated = []
      TOOL_VERSIONS.each do |tool, config|
        version_output = `#{config[:cmd]} 2>/dev/null`.strip
        current = extract_version(version_output, config)

        status = determine_tool_status(current, config[:min])
        outdated << tool if status == :outdated

        status_icon = { ok: '✅', outdated: '⚠️  outdated', missing: '❌ not installed' }[status] || '✅'
        puts "   #{tool}: #{current.empty? ? 'missing' : current} #{status_icon}"
      end

      update_outdated_tools(outdated) if outdated.any? && !check_only

      sop_log("Homebrew tools check: #{outdated.empty? ? 'all current' : "outdated: #{outdated.join(', ')}"}")
      outdated.empty? ? :ok : :updated
    end

    def extract_version(version_output, config)
      if config[:extract]
        match = version_output.match(config[:extract])
        match ? match[1] : version_output
      else
        version_output.split.first || ''
      end
    end

    def determine_tool_status(current, min_version)
      return :missing if current.empty?

      current_clean = current.gsub(/[^\d.]/, '')
      Gem::Version.new(current_clean) >= Gem::Version.new(min_version) ? :ok : :outdated
    rescue ArgumentError
      :ok
    end

    def update_outdated_tools(outdated)
      puts "\n   🔄 Updating outdated tools: #{outdated.join(', ')}"
      outdated.each do |tool|
        print "      Updating #{tool}... "
        if system("brew upgrade #{tool} 2>/dev/null || brew install #{tool} 2>/dev/null")
          puts '✅'
          sop_log("Updated: #{tool}")
        else
          puts '❌'
          sop_log("Failed to update: #{tool}")
        end
      end
    end

    def check_claude_plugins
      puts "\n🔌 Checking Claude Code plugins..."

      settings_file = File.expand_path('~/.claude/settings.json')
      unless File.exist?(settings_file)
        puts '   ⚠️  Claude settings not found'
        return :missing
      end

      settings = JSON.parse(File.read(settings_file))
      plugins = settings['enabledPlugins'] || {}

      required_plugins = %w[swift-lsp@claude-plugins-official code-review@claude-plugins-official security-guidance@claude-plugins-official]

      required_plugins.each do |plugin|
        status = plugins[plugin] ? '✅ enabled' : '⚠️  not enabled'
        puts "   #{plugin.split('@').first}: #{status}"
      end

      sop_log("Claude plugins: #{plugins.keys.join(', ')}")
      :ok
    rescue JSON::ParserError => e
      puts "   ❌ Failed to parse settings: #{e.message}"
      :error
    end

    def check_mcp_config
      puts "\n🔗 Checking MCP configuration..."

      sources = collect_mcp_sources
      if sources.empty?
        puts '   ❌ No MCP configuration found (.mcp.json, ~/.config/claude/mcp-config.json, or codex mcp list)'
        return :missing
      end

      total_servers = 0
      sources.each do |source|
        servers = source[:servers] || {}
        next if servers.empty?

        total_servers += servers.keys.count
        puts "   ✅ #{source[:label]}: #{servers.keys.count} servers configured"
        servers.keys.sort.each { |server| puts "      - #{server}" }

        # Only project .mcp.json has reliable local memory.json path args.
        check_memory_json_exists(servers) if source[:label] == '.mcp.json'
      end

      if total_servers.zero?
        puts '   ⚠️  MCP sources found but no servers configured'
        return :warning
      end

      check_local_settings

      sop_log("MCP: #{total_servers} servers across #{sources.count} source(s)")
      :ok
    rescue StandardError => e
      puts "   ❌ MCP check failed: #{e.message}"
      :error
    end

    def collect_mcp_sources
      sources = []

      codex_servers = codex_mcp_servers
      sources << { label: 'codex mcp list', servers: codex_servers } if codex_servers.any?

      claude_config_path = File.expand_path('~/.config/claude/mcp-config.json')
      if File.exist?(claude_config_path)
        begin
          claude_config = JSON.parse(File.read(claude_config_path))
          servers = claude_config['mcpServers'] || {}
          sources << { label: '~/.config/claude/mcp-config.json', servers: servers }
        rescue JSON::ParserError => e
          puts "   ⚠️  ~/.config/claude/mcp-config.json parse error: #{e.message}"
        end
      end

      project_mcp_path = File.join(Dir.pwd, '.mcp.json')
      if File.exist?(project_mcp_path)
        begin
          project_mcp = JSON.parse(File.read(project_mcp_path))
          servers = project_mcp['mcpServers'] || {}
          sources << { label: '.mcp.json', servers: servers }
        rescue JSON::ParserError => e
          puts "   ⚠️  .mcp.json parse error: #{e.message}"
        end
      end

      sources
    end

    def codex_mcp_servers
      codex_cmd = `command -v codex 2>/dev/null`.strip
      return {} if codex_cmd.empty?

      output = `codex mcp list 2>/dev/null`
      return {} if output.strip.empty?

      server_names = output.lines.filter_map do |line|
        stripped = line.strip
        next if stripped.empty?
        next if stripped.start_with?('Name ')
        next unless line.match?(/^\S+\s{2,}/)

        line.split(/\s{2,}/).first&.strip
      end

      server_names.uniq.each_with_object({}) { |name, acc| acc[name] = {} }
    rescue StandardError
      {}
    end

    def check_memory_json_exists(servers)
      return unless servers['memory']

      memory_args = servers['memory']['args'] || []
      memory_path = memory_args.find { |a| a.include?('memory.json') }
      return unless memory_path

      # Resolve relative paths
      if memory_path.start_with?('.') || !memory_path.start_with?('/')
        memory_path = File.join(Dir.pwd, memory_path)
      end

      if File.exist?(memory_path)
        puts '   ✅ memory.json exists'
      else
        puts "   ❌ memory.json missing: #{memory_path}"
        puts '      Creating empty memory.json...'
        FileUtils.mkdir_p(File.dirname(memory_path))
        File.write(memory_path, '{"entities":[],"relations":[]}')
        puts '   ✅ memory.json created'
        sop_log("Created missing memory.json: #{memory_path}")
      end
    end

    def check_local_settings
      local_settings = File.join(Dir.pwd, '.claude/settings.local.json')
      return unless File.exist?(local_settings)

      local = JSON.parse(File.read(local_settings))
      if local['enableAllProjectMcpServers']
        puts '   ✅ enableAllProjectMcpServers: true'
      else
        puts '   ⚠️  enableAllProjectMcpServers not set'
      end

      return unless local['enabledMcpjsonServers']

      puts "   ⚠️  enabledMcpjsonServers restrictive list found (#{local['enabledMcpjsonServers'].count} servers)"
    end

    def doctor_silent
      issues = []

      dd_size = begin
        `du -sh ~/Library/Developer/Xcode/DerivedData 2>/dev/null`.split.first
      rescue StandardError
        '?'
      end
      size_gb = parse_size_to_gb(dd_size)
      issues << "DerivedData: #{dd_size}" if size_gb > 5

      stuck_pids = find_stuck_processes
      issues << "#{stuck_pids.count} stuck build processes" if stuck_pids.any?

      available = `df -h . | tail -1 | awk '{print $4}'`.strip
      issues << "Low disk: #{available}" if available.end_with?('M') || available.to_f < 50

      issues.empty? ? :ok : issues
    end

    def parse_size_to_gb(size_str)
      if size_str.end_with?('G')
        size_str.to_f
      elsif size_str.end_with?('M')
        size_str.to_f / 1024
      else
        0
      end
    end

    def find_stuck_processes
      stuck_pids = `pgrep -f 'xcodebuild|xctest' 2>/dev/null`.strip.split
      stuck_pids.reject do |pid|
        cmd = `ps -p #{pid} -o command= 2>/dev/null`.strip
        cmd.include?('mcpbridge')
      end
    end

    def print_sop_summary(results, check_only)
      puts "\n#{'=' * 60}"
      puts check_only ? '📋 SOP STATUS REPORT' : '✅ SOP BOOTSTRAP COMPLETE'
      puts '=' * 60

      summary = {
        'Ruby Environment' => results[:ruby],
        'Bundle Dependencies' => results[:bundle],
        'Homebrew Tools' => results[:homebrew_tools],
        'Claude Plugins' => results[:claude_plugins],
        'MCP Servers' => results[:mcp_servers]
      }

      summary.each do |name, status|
        icon = status_icon(status)
        puts "#{icon} #{name}"
      end

      puts '🔧 Auto-Fix Applied' if results[:auto_fix] == :fixed

      if results[:doctor].is_a?(Array) && results[:doctor].any?
        puts "\n⚠️  Remaining Health Issues:"
        results[:doctor].each { |issue| puts "   - #{issue}" }
      else
        puts '✅ Health Check'
      end

      puts '=' * 60

      unless check_only
        puts "\n💡 Session log: #{@sop_log}"
        puts '💾 Rollback available: ./Scripts/SaneMaster.rb sop --rollback'
      end

      # Session-ready toast (SOP requirement)
      puts "\n#{'─' * 50}"
      puts '✅ Ready — Ruby, tools, hooks, MCP servers checked.'
      puts '🧠 Memory will load on first response.'

      # Show handoff if exists
      show_session_handoff

      # Show recent git activity
      show_git_summary

      puts "\nWhat would you like to work on today?"
      puts '─' * 50
    end

    def show_session_handoff
      handoff_path = File.join(Dir.pwd, '.claude', 'SESSION_HANDOFF.md')
      return unless File.exist?(handoff_path)

      puts ''
      puts '📋 Previous Session Handoff:'
      content = File.read(handoff_path)
      # Show just the key sections
      content.lines.each do |line|
        next if line.strip.empty? || line.start_with?('---') || line.start_with?('*Generated')

        puts "   #{line.rstrip}"
        break if line.include?('## Next Steps') # Stop after showing structure
      end
      puts '   (see .claude/SESSION_HANDOFF.md for full details)'
    end

    def show_git_summary
      commits = `git log --oneline -5 --format='%h %s (%cr)' 2>/dev/null`.strip
      return if commits.empty?

      puts ''
      puts '📜 Recent Git Activity:'
      commits.split("\n").each { |c| puts "   #{c}" }
    end

    def status_icon(status)
      case status
      when :ok, true then '✅'
      when :updated then '🔄'
      when :missing, :failed, :error then '❌'
      else '⚠️'
      end
    end

    # Check Memory MCP configuration
    def check_memory_health
      sources = collect_mcp_sources
      return { status: :warning, message: 'No MCP configuration found' } if sources.empty?

      has_memory = sources.any? { |source| (source[:servers] || {}).key?('memory') }
      return { status: :warning, message: 'Memory MCP not configured' } unless has_memory

      # Memory is MCP-managed (in-process), can't check file directly.
      { status: :ok, message: 'Memory MCP configured (use mcp__memory__read_graph to validate content)' }
    end

    # Full health check - consolidates quick checks + meta audit
    def run_health(args = [])
      # Just run meta - it covers everything
      run_meta(args)
    end
  end
end
