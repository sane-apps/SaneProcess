# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'socket'
require 'time'
require 'tmpdir'

module SaneMasterModules
  # Optional Peekaboo-backed visual evidence capture for Mini-first app testing.
  module VisualSmoke
    VisualSmokeOptions = Struct.new(
      :app_name,
      :bundle_id,
      :cwd,
      :output_root,
      :peekaboo_bin,
      :timeout,
      :json,
      :dry_run,
      :require_peekaboo,
      :terminal_host,
      :capture_screen,
      :capture_menu,
      :capture_app,
      keyword_init: true
    )

    VISUAL_SMOKE_SANE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo].freeze
    VISUAL_SMOKE_ALLOWED_VISIBLE_PROCESSES = %w[Finder SystemUIServer ControlCenter Dock NotificationCenter].freeze
    VISUAL_SMOKE_HELPER_APPS = ['Preview', 'Safari', 'TextEdit', 'QuickTime Player'].freeze
    VISUAL_SMOKE_DESKTOP_ARTIFACT_PATTERNS = [
      /\ASaneProcess-rsync-misfire-/,
      /\ASaneUI-test-output-.*\.txt\z/,
      /\ASaneClip OCR final proof .+\.txt\z/
    ].freeze

    def visual_smoke(args)
      options = parse_visual_smoke_args(args)
      result = build_visual_smoke(options)
      print_visual_smoke_result(result, json: options.json)
      result[:ok]
    rescue ArgumentError => e
      warn "❌ #{e.message}"
      warn 'Usage: ./scripts/SaneMaster.rb visual_smoke [--app NAME] [--require-peekaboo] [--json] [--dry-run]'
      false
    end

    def parse_visual_smoke_args(args)
      options = VisualSmokeOptions.new(
        app_name: project_name,
        bundle_id: @bundle_id,
        cwd: Dir.pwd,
        output_root: File.join(Dir.pwd, 'outputs', 'visual_smoke'),
        peekaboo_bin: ENV.fetch('PEEKABOO_BIN', 'peekaboo'),
        timeout: 20,
        json: false,
        dry_run: false,
        require_peekaboo: false,
        terminal_host: ENV.fetch('SANEMASTER_VISUAL_SMOKE_DIRECT', '') != '1',
        capture_screen: true,
        capture_menu: true,
        capture_app: true
      )

      explicit_output = false
      i = 0
      while i < args.length
        arg = args[i]
        case arg
        when '--app'
          options.app_name = visual_smoke_required_arg(args, i, arg)
          i += 1
        when /\A--app=(.+)\z/
          options.app_name = Regexp.last_match(1)
        when '--bundle-id'
          options.bundle_id = visual_smoke_required_arg(args, i, arg)
          i += 1
        when /\A--bundle-id=(.+)\z/
          options.bundle_id = Regexp.last_match(1)
        when '--output'
          options.output_root = visual_smoke_required_arg(args, i, arg)
          explicit_output = true
          i += 1
        when /\A--output=(.+)\z/
          options.output_root = Regexp.last_match(1)
          explicit_output = true
        when '--peekaboo'
          options.peekaboo_bin = visual_smoke_required_arg(args, i, arg)
          i += 1
        when /\A--peekaboo=(.+)\z/
          options.peekaboo_bin = Regexp.last_match(1)
        when '--timeout'
          options.timeout = Integer(visual_smoke_required_arg(args, i, arg), 10)
          i += 1
        when /\A--timeout=(\d+)\z/
          options.timeout = Integer(Regexp.last_match(1), 10)
        when '--json'
          options.json = true
        when '--dry-run', '--plan'
          options.dry_run = true
        when '--require-peekaboo'
          options.require_peekaboo = true
        when '--direct'
          options.terminal_host = false
        when '--terminal-host'
          options.terminal_host = true
        when '--no-screen'
          options.capture_screen = false
        when '--no-menu', '--no-menubar'
          options.capture_menu = false
        when '--no-app'
          options.capture_app = false
        when '--local'
          # Consumed by SaneMaster Mini routing. No visual_smoke-specific meaning.
        else
          raise ArgumentError, "unknown option: #{arg}"
        end
        i += 1
      end

      options.cwd = File.expand_path(options.cwd)
      options.output_root = File.expand_path(options.output_root, options.cwd) unless explicit_output
      options.output_root = File.expand_path(options.output_root, options.cwd)
      options.timeout = 5 if options.timeout.to_i < 5
      options
    end

    def build_visual_smoke(options)
      smoke_dir = visual_smoke_dir(options.output_root)
      FileUtils.mkdir_p(smoke_dir)

      commands = visual_smoke_commands(options, smoke_dir)
      peekaboo_path = resolve_visual_smoke_peekaboo(options.peekaboo_bin)
      result = {
        ok: true,
        status: 'passed',
        project: project_name,
        app: options.app_name,
        bundle_id: options.bundle_id,
        created_at: Time.now.iso8601,
        smoke_dir: smoke_dir,
        summary: File.join(smoke_dir, 'summary.md'),
        receipt: File.join(smoke_dir, 'receipt.json'),
        peekaboo: {
          requested: options.peekaboo_bin,
          resolved: peekaboo_path,
          available: !peekaboo_path.nil?,
          required: options.require_peekaboo
        },
        runner: options.terminal_host ? 'terminal-host' : 'direct',
        commands: commands,
        artifacts: [],
        cleanliness: {
          checked: false,
          issues: []
        }
      }

      visual_smoke_with_lock(result) do
        if options.dry_run
          result[:status] = 'planned'
        elsif peekaboo_path.nil?
          result[:status] = options.require_peekaboo ? 'failed' : 'skipped'
          result[:ok] = !options.require_peekaboo
          result[:reason] = 'Peekaboo CLI not found. Install on the Mini with: brew install steipete/tap/peekaboo'
        else
          cleanliness_issues = visual_smoke_cleanliness_issues(options)
          result[:cleanliness] = {
            checked: true,
            issues: cleanliness_issues
          }
          unless cleanliness_issues.empty?
            result[:ok] = false
            result[:status] = 'failed'
            result[:reason] = "Mini visual workspace is dirty: #{cleanliness_issues.join('; ')}"
            break
          end

          commands.each do |command|
            command[:argv][0] = peekaboo_path
            command_result = run_visual_smoke_command(command, timeout: options.timeout, terminal_host: options.terminal_host)
            command.merge!(command_result)
            result[:artifacts] << command[:output] if command[:output] && File.exist?(command[:output])
            command.fetch(:artifacts, []).each do |artifact|
              result[:artifacts] << artifact if File.exist?(artifact)
            end
          end
          result[:artifacts].uniq!
          failed = commands.reject { |command| command[:success] }
          unless failed.empty?
            result[:ok] = false
            result[:status] = 'failed'
            result[:reason] = "#{failed.length} Peekaboo command(s) failed"
          end
        end
      end

      write_visual_smoke_receipt(result)
      result
    end

    def visual_smoke_commands(options, smoke_dir)
      commands = [
        visual_smoke_json_command('permissions', smoke_dir, [options.peekaboo_bin, 'permissions', 'status', '--json']),
        visual_smoke_json_command('apps', smoke_dir, [options.peekaboo_bin, 'list', 'apps', '--json']),
        visual_smoke_json_command('menubar-list', smoke_dir, [options.peekaboo_bin, 'list', 'menubar', '--json'])
      ]
      if options.capture_app
        commands.insert(
          2,
          visual_smoke_json_command('windows', smoke_dir, [options.peekaboo_bin, 'list', 'windows', '--app', options.app_name, '--json'])
        )
      end
      if options.capture_screen
        commands << visual_smoke_artifact_command(
          'screen-image',
          File.join(smoke_dir, 'screen.png'),
          [options.peekaboo_bin, 'image', '--mode', 'screen', '--retina', '--path', File.join(smoke_dir, 'screen.png')]
        )
      end
      if options.capture_menu
        commands << visual_smoke_artifact_command(
          'menu-image',
          File.join(smoke_dir, 'menu.png'),
          [options.peekaboo_bin, 'image', '--app', 'menubar', '--retina', '--path', File.join(smoke_dir, 'menu.png'), '--json']
        )
      end
      if options.capture_app
        app_image = File.join(smoke_dir, 'app-see.png')
        commands << visual_smoke_json_command(
          'app-see',
          smoke_dir,
          [options.peekaboo_bin, 'see', '--app', options.app_name, '--json', '--annotate', '--path', app_image],
          artifacts: [app_image]
        )
      end
      commands
    end

    def visual_smoke_json_command(name, smoke_dir, argv, artifacts: [])
      {
        name: name,
        argv: argv,
        output: File.join(smoke_dir, "#{name}.json"),
        stderr: File.join(smoke_dir, "#{name}.stderr.txt"),
        artifacts: artifacts
      }
    end

    def visual_smoke_artifact_command(name, output, argv)
      {
        name: name,
        argv: argv,
        output: output,
        stderr: output.sub(/\.[^.]+\z/, '.stderr.txt'),
        artifacts: [output]
      }
    end

    def run_visual_smoke_command(command, timeout:, terminal_host:)
      return run_visual_smoke_command_via_terminal(command, timeout: timeout) if terminal_host && visual_smoke_terminal_host_available?

      stdout_data = +''
      stderr_data = +''
      status = nil
      timed_out = false

      Open3.popen3(*command[:argv]) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stdout_reader = Thread.new { stdout_data = stdout.read.to_s }
        stderr_reader = Thread.new { stderr_data = stderr.read.to_s }

        unless wait_thr.join(timeout)
          timed_out = true
          Process.kill('TERM', wait_thr.pid) rescue nil
          sleep 0.5
          Process.kill('KILL', wait_thr.pid) rescue nil
        end

        status = wait_thr.value unless timed_out
        stdout_reader.join(1)
        stderr_reader.join(1)
      end

      File.write(command[:stderr], stderr_data) if command[:stderr]
      if command[:output] && !command[:name].end_with?('-image')
        File.write(command[:output], stdout_data)
      end

      {
        success: !timed_out && status&.success?,
        exit_status: status&.exitstatus,
        timed_out: timed_out
      }
    end

    def run_visual_smoke_command_via_terminal(command, timeout:)
      status_path = "#{command[:stderr]}.status"
      stdout_path = "#{command[:stderr]}.stdout"
      script_path = "#{command[:stderr]}.run.sh"
      File.write(
        script_path,
        [
          '#!/bin/zsh',
          'set +e',
          "#{command[:argv].map { |part| Shellwords.escape(part.to_s) }.join(' ')} > #{Shellwords.escape(stdout_path)} 2> #{Shellwords.escape(command[:stderr])}",
          "echo $? > #{Shellwords.escape(status_path)}"
        ].join("\n")
      )
      File.chmod(0o700, script_path)

      apple_script = <<~APPLESCRIPT
        on run argv
          tell application "Terminal"
            do script item 1 of argv
          end tell
        end run
      APPLESCRIPT
      Open3.capture2e('/usr/bin/osascript', '-e', apple_script, "/bin/zsh #{Shellwords.escape(script_path)}; exit")
      visual_smoke_hide_terminal

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until File.exist?(status_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.25
      end
      visual_smoke_close_terminal_host

      timed_out = !File.exist?(status_path)
      exit_status = timed_out ? nil : File.read(status_path).to_i
      stdout_data = File.exist?(stdout_path) ? File.read(stdout_path) : ''

      if command[:output] && !command[:name].end_with?('-image')
        File.write(command[:output], stdout_data)
      end

      {
        success: !timed_out && exit_status.zero?,
        exit_status: exit_status,
        timed_out: timed_out,
        runner: 'terminal-host'
      }
    ensure
      visual_smoke_close_terminal_host
    end

    def visual_smoke_hide_terminal
      apple_script = <<~APPLESCRIPT
        tell application "System Events"
          if exists process "Terminal" then set visible of process "Terminal" to false
        end tell
      APPLESCRIPT
      Open3.capture2e('/usr/bin/osascript', '-e', apple_script)
    rescue StandardError
      nil
    end

    def visual_smoke_dismiss_system_popovers
      apple_script = <<~APPLESCRIPT
        tell application "System Events"
          key code 53
          delay 0.1
          key code 53
        end tell
        tell application "Finder" to activate
      APPLESCRIPT
      Open3.capture2e('/usr/bin/osascript', '-e', apple_script)
    rescue StandardError
      nil
    end

    def visual_smoke_with_lock(result)
      lock_path = File.join(Dir.tmpdir, 'sanemaster-visual-smoke.lock')
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          result[:ok] = false
          result[:status] = 'failed'
          result[:reason] = 'another visual_smoke run is active; wait for it or clean up the stale run before capturing'
          return result
        end
        yield
      end
      result
    end

    def visual_smoke_cleanliness_issues(options)
      return [] unless RUBY_PLATFORM.include?('darwin')
      return [] if ENV['SANEMASTER_VISUAL_SMOKE_ALLOW_DIRTY_GUI'] == '1'

      issues = []
      if visual_smoke_mini_host?
        visual_smoke_dismiss_system_popovers
        visual_smoke_close_terminal_host
        sleep 0.5
      end
      terminal_windows = visual_smoke_terminal_window_count
      if terminal_windows.positive?
        issues << "Terminal has #{terminal_windows} open window(s); close them before visual capture"
      end

      prompt_hits = visual_smoke_permission_prompt_hits(options.app_name)
      issues.concat(prompt_hits)
      issues.concat(visual_smoke_visible_process_issues(options.app_name))
      issues.concat(visual_smoke_running_sane_process_issues(options.app_name))
      issues.concat(visual_smoke_desktop_artifact_issues)
      issues
    end

    def visual_smoke_terminal_window_count
      script = <<~APPLESCRIPT
        tell application "System Events"
          if exists process "Terminal" then
            tell process "Terminal"
              return count of windows
            end tell
          end if
        end tell
        return 0
      APPLESCRIPT
      stdout, status = Open3.capture2('/usr/bin/osascript', '-e', script)
      return 0 unless status.success?

      stdout.to_i
    rescue StandardError
      0
    end

    def visual_smoke_permission_prompt_hits(app_name)
      app_names = (VISUAL_SMOKE_SANE_APPS + [app_name]).compact.uniq
      quoted_names = app_names.map { |name| %("#{name.gsub('"', '\"')}") }.join(', ')
      script = <<~APPLESCRIPT
        set hits to {}
        tell application "System Events"
          repeat with procName in {#{quoted_names}}
            if exists process procName then
              tell process procName
                repeat with candidateWindow in windows
                  set buttonNames to {}
                  try
                    set buttonNames to name of buttons of candidateWindow
                  end try
                  if buttonNames contains "Allow" or buttonNames contains "Don’t Allow" or buttonNames contains "Don't Allow" then
                    set end of hits to ((procName as text) & " has an unresolved permission prompt")
                  end if
                end repeat
              end tell
            end if
          end repeat
        end tell
        return hits
      APPLESCRIPT
      stdout, status = Open3.capture2('/usr/bin/osascript', '-e', script)
      return [] unless status.success?

      stdout.split(',').map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    def visual_smoke_visible_process_issues(app_name)
      visible_names = visual_smoke_visible_process_names
      visible_names.each_with_object([]) do |name, issues|
        next if name.nil? || name.empty?
        next if VISUAL_SMOKE_ALLOWED_VISIBLE_PROCESSES.include?(name)
        next if name == app_name

        if name == 'Terminal'
          issues << 'Terminal is visible; hide or close automation windows before visual capture'
        elsif VISUAL_SMOKE_SANE_APPS.include?(name)
          issues << "Visible stale SaneApps window: #{name} while testing #{app_name}"
        elsif VISUAL_SMOKE_HELPER_APPS.include?(name)
          issues << "Visible helper app can contaminate screenshot: #{name}"
        end
      end
    end

    def visual_smoke_visible_process_names
      script = <<~APPLESCRIPT
        set output to {}
        tell application "System Events"
          repeat with proc in application processes
            try
              if visible of proc is true then set end of output to name of proc
            end try
          end repeat
        end tell
        return output
      APPLESCRIPT
      stdout, status = Open3.capture2('/usr/bin/osascript', '-e', script)
      return [] unless status.success?

      stdout.split(',').map(&:strip).reject(&:empty?)
    rescue StandardError
      []
    end

    def visual_smoke_desktop_artifact_issues
      visual_smoke_desktop_artifacts.each_with_object([]) do |name, issues|
        next unless VISUAL_SMOKE_DESKTOP_ARTIFACT_PATTERNS.any? { |pattern| name.match?(pattern) }

        issues << "Desktop contains leftover test artifact: #{name}"
      end
    end

    def visual_smoke_desktop_artifacts
      desktop = File.expand_path('~/Desktop')
      return [] unless Dir.exist?(desktop)

      Dir.children(desktop).reject { |name| name.start_with?('.') }
    rescue StandardError
      []
    end

    def visual_smoke_running_sane_process_issues(app_name)
      visual_smoke_running_sane_process_lines.each_with_object([]) do |line, issues|
        next unless line.include?('/Applications/Sane') ||
                    line.include?('SaneClickExtension') ||
                    line.include?('/SaneSync/scripts/inference_server.py')
        next if visual_smoke_process_allowed_for_app?(line, app_name)

        if line.include?('SaneClickExtension')
          issues << 'Stale SaneClickExtension helper is still running'
        elsif line.include?('/SaneSync/scripts/inference_server.py')
          issues << 'Stale SaneSync inference server is still running'
        else
          issues << "Stale SaneApps process while testing #{app_name}: #{line}"
        end
      end
    end

    def visual_smoke_running_sane_process_lines
      commands = [
        ['/usr/bin/pgrep', '-fl', 'Sane(Bar|Click|Clip|Hosts|Sales|Sync|Video)'],
        ['/usr/bin/pgrep', '-fl', '/SaneSync/scripts/inference_server.py']
      ]
      commands.flat_map do |command|
        stdout, = Open3.capture2e(*command)
        stdout.lines.map(&:strip)
      end.reject(&:empty?).uniq
    rescue StandardError
      []
    end

    def visual_smoke_process_allowed_for_app?(line, app_name)
      return true if line.include?("/Applications/#{app_name}.app/")
      return true if line.match?(/\A\d+\s+.*\/#{Regexp.escape(app_name)}(\s|\z)/)
      return true if app_name == 'SaneClick' && line.include?('SaneClickExtension')
      return true if app_name == 'SaneSync' && line.include?('/SaneSync/scripts/inference_server.py')

      false
    end

    def visual_smoke_close_terminal_host
      apple_script = <<~APPLESCRIPT
        tell application "Terminal"
          close every window
          quit
        end tell
      APPLESCRIPT
      Open3.popen2e('/usr/bin/osascript', '-e', apple_script) do |_stdin, _stdout_err, wait_thr|
        unless wait_thr.join(2)
          Process.kill('TERM', wait_thr.pid) rescue nil
          sleep 0.2
          Process.kill('KILL', wait_thr.pid) rescue nil
        end
      end
      system('/usr/bin/pkill', '-x', 'Terminal', out: File::NULL, err: File::NULL)
    rescue StandardError
      nil
    end

    def visual_smoke_mini_host?
      Socket.gethostname.downcase.include?('mini') || ENV.fetch('USER', '').downcase == 'stephansmac'
    rescue StandardError
      false
    end

    def visual_smoke_terminal_host_available?
      return false unless RUBY_PLATFORM.include?('darwin')

      system('/usr/bin/pgrep', '-x', 'Terminal', out: File::NULL, err: File::NULL) ||
        system('/usr/bin/open', '-a', 'Terminal', out: File::NULL, err: File::NULL)
    end

    def resolve_visual_smoke_peekaboo(peekaboo_bin)
      return File.expand_path(peekaboo_bin) if peekaboo_bin.include?(File::SEPARATOR) && File.executable?(peekaboo_bin)

      visual_smoke_search_path.each do |dir|
        candidate = File.join(dir, peekaboo_bin)
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end
      nil
    end

    def visual_smoke_search_path
      env_path = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).reject(&:empty?)
      (env_path + ['/opt/homebrew/bin', '/usr/local/bin']).uniq
    end

    def visual_smoke_dir(output_root)
      timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
      File.join(output_root, "visual_smoke_#{timestamp}_#{Process.pid}")
    end

    def write_visual_smoke_receipt(result)
      File.write(result[:receipt], JSON.pretty_generate(result))
      File.write(result[:summary], visual_smoke_summary(result))
    end

    def visual_smoke_summary(result)
      lines = [
        "# Visual Smoke Receipt",
        '',
        "- Status: `#{result[:status]}`",
        "- Project: `#{result[:project]}`",
        "- App: `#{result[:app]}`",
        "- Bundle ID: `#{result[:bundle_id]}`",
        "- Peekaboo available: `#{result[:peekaboo][:available]}`",
        "- Runner: `#{result[:runner]}`",
        "- Directory: `#{result[:smoke_dir]}`"
      ]
      lines << "- Reason: #{result[:reason]}" if result[:reason]
      lines << ''
      lines << '## Commands'
      result[:commands].each do |command|
        status = if command.key?(:success)
                   command[:success] ? 'pass' : 'fail'
                 else
                   'planned'
                 end
        lines << "- `#{command[:name]}` #{status}: `#{command[:argv].map { |part| Shellwords.escape(part.to_s) }.join(' ')}`"
      end
      lines << ''
      lines << '## Artifacts'
      artifacts = result[:artifacts].empty? ? result[:commands].map { |command| command[:output] }.compact : result[:artifacts]
      artifacts.each { |artifact| lines << "- `#{artifact}`" }
      lines << ''
      lines.join("\n")
    end

    def print_visual_smoke_result(result, json: false)
      if json
        puts JSON.pretty_generate(result)
        return
      end

      case result[:status]
      when 'passed'
        puts "✅ Visual smoke complete: #{result[:summary]}"
      when 'planned'
        puts "🧭 Visual smoke plan written: #{result[:summary]}"
      when 'skipped'
        puts "⏭️  Visual smoke skipped: #{result[:reason]}"
        puts "   Receipt: #{result[:summary]}"
      else
        puts "❌ Visual smoke failed: #{result[:reason]}"
        puts "   Receipt: #{result[:summary]}"
      end
    end

    def visual_smoke_required_arg(args, index, flag)
      value = args[index + 1]
      raise ArgumentError, "#{flag} requires a value" if value.nil? || value.start_with?('--')

      value
    end
  end
end
