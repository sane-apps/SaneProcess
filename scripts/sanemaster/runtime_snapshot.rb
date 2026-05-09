# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'time'

module SaneMasterModules
  # LLDB-backed runtime evidence capture for reproducible Swift/macOS bugs.
  module RuntimeSnapshot
    RuntimeSnapshotOptions = Struct.new(
      :executable,
      :pid,
      :breakpoints,
      :symbols,
      :expressions,
      :program_args,
      :cwd,
      :timeout,
      :output_root,
      :json,
      :dry_run,
      :include_logs,
      keyword_init: true
    )

    def runtime_snapshot(args)
      options = parse_runtime_snapshot_args(args)
      result = build_runtime_snapshot(options)
      print_runtime_snapshot_result(result, json: options.json)
      result[:ok]
    rescue ArgumentError => e
      warn "❌ #{e.message}"
      warn 'Usage: ./scripts/SaneMaster.rb runtime_snapshot --executable PATH --break File.swift:123 [--expr "value"] [--arg ARG]'
      false
    end

    def parse_runtime_snapshot_args(args)
      options = RuntimeSnapshotOptions.new(
        breakpoints: [],
        symbols: [],
        expressions: [],
        program_args: [],
        cwd: Dir.pwd,
        timeout: 30,
        output_root: File.join(Dir.pwd, 'outputs', 'debug'),
        json: false,
        dry_run: false,
        include_logs: true
      )

      explicit_output = false
      i = 0
      while i < args.length
        arg = args[i]
        case arg
        when '--executable'
          options.executable = required_arg(args, i, arg)
          i += 1
        when /\A--executable=(.+)\z/
          options.executable = Regexp.last_match(1)
        when '--pid'
          options.pid = Integer(required_arg(args, i, arg), 10)
          i += 1
        when /\A--pid=(\d+)\z/
          options.pid = Integer(Regexp.last_match(1), 10)
        when '--break', '--breakpoint'
          options.breakpoints << required_arg(args, i, arg)
          i += 1
        when /\A--(?:break|breakpoint)=(.+)\z/
          options.breakpoints << Regexp.last_match(1)
        when '--symbol'
          options.symbols << required_arg(args, i, arg)
          i += 1
        when /\A--symbol=(.+)\z/
          options.symbols << Regexp.last_match(1)
        when '--expr', '--eval'
          options.expressions << required_arg(args, i, arg)
          i += 1
        when /\A--(?:expr|eval)=(.+)\z/
          options.expressions << Regexp.last_match(1)
        when '--arg'
          options.program_args << required_arg(args, i, arg)
          i += 1
        when /\A--arg=(.*)\z/
          options.program_args << Regexp.last_match(1)
        when '--cwd'
          options.cwd = required_arg(args, i, arg)
          i += 1
        when /\A--cwd=(.+)\z/
          options.cwd = Regexp.last_match(1)
        when '--timeout'
          options.timeout = Integer(required_arg(args, i, arg), 10)
          i += 1
        when /\A--timeout=(\d+)\z/
          options.timeout = Integer(Regexp.last_match(1), 10)
        when '--output'
          options.output_root = required_arg(args, i, arg)
          explicit_output = true
          i += 1
        when /\A--output=(.+)\z/
          options.output_root = Regexp.last_match(1)
          explicit_output = true
        when '--json'
          options.json = true
        when '--dry-run', '--plan'
          options.dry_run = true
        when '--no-logs'
          options.include_logs = false
        when '--local'
          # Consumed by SaneMaster Mini routing. No runtime_snapshot-specific meaning.
        else
          raise ArgumentError, "unknown option: #{arg}"
        end
        i += 1
      end

      options.output_root = File.join(options.cwd, 'outputs', 'debug') unless explicit_output
      normalize_runtime_snapshot_options(options)
    end

    def build_runtime_snapshot(options)
      snapshot_dir = runtime_snapshot_dir(options.output_root)
      FileUtils.mkdir_p(snapshot_dir)

      commands = runtime_snapshot_lldb_commands(options)
      metadata = runtime_snapshot_metadata(options, snapshot_dir, commands)
      write_runtime_snapshot_inputs(snapshot_dir, metadata, commands, options)

      lldb_result = if options.dry_run || (!options.executable && !options.pid)
                      { ran: false, timed_out: false, exit_status: nil, stdout: '', stderr: '' }
                    else
                      run_runtime_snapshot_lldb(commands, options, snapshot_dir)
                    end

      metadata[:lldb] = lldb_result.slice(:ran, :timed_out, :exit_status)
      File.write(File.join(snapshot_dir, 'metadata.json'), JSON.pretty_generate(metadata))
      write_runtime_snapshot_summary(snapshot_dir, metadata, lldb_result, options)

      {
        ok: runtime_snapshot_ok?(options, lldb_result),
        snapshot_dir: snapshot_dir,
        summary: File.join(snapshot_dir, 'summary.md'),
        lldb_output: File.join(snapshot_dir, 'lldb_output.txt'),
        lldb_ran: lldb_result[:ran],
        timed_out: lldb_result[:timed_out],
        exit_status: lldb_result[:exit_status]
      }
    end

    def runtime_snapshot_dir(output_root)
      timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
      File.join(output_root, "runtime_snapshot_#{timestamp}_#{Process.pid}")
    end

    def normalize_runtime_snapshot_options(options)
      raise ArgumentError, '--pid and --executable are mutually exclusive' if options.pid && options.executable

      options.cwd = File.expand_path(options.cwd)
      options.output_root = File.expand_path(options.output_root, options.cwd)
      options.executable = File.expand_path(options.executable, options.cwd) if options.executable
      options.breakpoints = options.breakpoints.map { |spec| normalize_breakpoint_spec(spec, options.cwd) }
      options.timeout = 1 if options.timeout.to_i < 1
      options
    end

    def normalize_breakpoint_spec(spec, cwd)
      file, line = spec.to_s.rpartition(':').values_at(0, 2)
      raise ArgumentError, "breakpoint must look like File.swift:123, got #{spec.inspect}" if file.empty? || line.empty?
      raise ArgumentError, "breakpoint line must be numeric, got #{line.inspect}" unless line.match?(/\A\d+\z/)

      { file: File.expand_path(file, cwd), line: Integer(line, 10), original: spec }
    end

    def runtime_snapshot_lldb_commands(options)
      commands = [
        'settings set interpreter.stop-command-source-on-error false',
        'settings set target.inline-breakpoint-strategy always'
      ]

      if options.pid
        commands << "process attach --pid #{options.pid}"
      elsif options.executable
        commands << "target create #{Shellwords.escape(options.executable)}"
      end

      options.breakpoints.each do |breakpoint|
        commands << "breakpoint set --file #{Shellwords.escape(breakpoint[:file])} --line #{breakpoint[:line]}"
      end
      options.symbols.each do |symbol|
        commands << "breakpoint set --name #{Shellwords.escape(symbol)}"
      end

      if options.executable
        run_command = ['run', *options.program_args].map { |part| Shellwords.escape(part) }.join(' ')
        commands << run_command
      end

      commands << 'thread backtrace all'
      commands << 'frame variable --show-types'
      options.expressions.each do |expression|
        commands << "expression -- #{expression}"
      end
      commands << (options.pid ? 'detach' : 'quit')
      commands << 'quit' if options.pid
      commands
    end

    def runtime_snapshot_metadata(options, snapshot_dir, commands)
      {
        created_at: Time.now.iso8601,
        project: project_name,
        cwd: options.cwd,
        snapshot_dir: snapshot_dir,
        executable: options.executable,
        pid: options.pid,
        breakpoints: options.breakpoints,
        symbols: options.symbols,
        expressions: options.expressions,
        args: options.program_args,
        timeout: options.timeout,
        dry_run: options.dry_run,
        git: runtime_snapshot_git_state,
        lldb_commands: commands
      }
    end

    def runtime_snapshot_git_state
      revision, = Open3.capture2('git', 'rev-parse', '--short', 'HEAD', chdir: Dir.pwd)
      status, = Open3.capture2('git', 'status', '--short', chdir: Dir.pwd)
      { revision: revision.strip, status: status.lines.map(&:chomp) }
    rescue StandardError
      { revision: '', status: [] }
    end

    def write_runtime_snapshot_inputs(snapshot_dir, metadata, commands, options)
      File.write(File.join(snapshot_dir, 'metadata.json'), JSON.pretty_generate(metadata))
      File.write(File.join(snapshot_dir, 'lldb_commands.txt'), "#{commands.join("\n")}\n")
      write_runtime_snapshot_source_context(snapshot_dir, options.breakpoints)
      write_runtime_snapshot_recent_logs(snapshot_dir, options) if options.include_logs
    end

    def write_runtime_snapshot_source_context(snapshot_dir, breakpoints)
      path = File.join(snapshot_dir, 'source_context.md')
      lines = ['# Source Context', '']
      breakpoints.each do |breakpoint|
        lines << "## #{breakpoint[:file]}:#{breakpoint[:line]}"
        if File.exist?(breakpoint[:file])
          source_lines = File.readlines(breakpoint[:file])
          first = [breakpoint[:line] - 6, 0].max
          last = [breakpoint[:line] + 4, source_lines.length - 1].min
          lines << '```swift'
          (first..last).each do |index|
            marker = (index + 1 == breakpoint[:line]) ? '>' : ' '
            lines << "#{marker} #{(index + 1).to_s.rjust(4)} #{source_lines[index].chomp}"
          end
          lines << '```'
        else
          lines << '_File not found on this machine._'
        end
        lines << ''
      end
      File.write(path, "#{lines.join("\n")}\n")
    end

    def write_runtime_snapshot_recent_logs(snapshot_dir, options)
      return unless options.executable || options.pid

      process = runtime_snapshot_process_name(options)
      return if process.to_s.empty?

      output, = Open3.capture2e(
        '/usr/bin/log',
        'show',
        '--last',
        '5m',
        '--style',
        'compact',
        '--predicate',
        "process == \"#{process}\""
      )
      File.write(File.join(snapshot_dir, 'recent_logs.txt'), output)
    rescue StandardError => e
      File.write(File.join(snapshot_dir, 'recent_logs.txt'), "log capture failed: #{e.class}: #{e.message}\n")
    end

    def runtime_snapshot_process_name(options)
      if options.executable
        File.basename(options.executable)
      elsif options.pid
        output, status = Open3.capture2('ps', '-p', options.pid.to_s, '-o', 'comm=')
        status.success? ? File.basename(output.strip) : nil
      end
    end

    def run_runtime_snapshot_lldb(commands, options, snapshot_dir)
      lldb = runtime_snapshot_lldb_path
      unless lldb
        return { ran: false, timed_out: false, exit_status: 127, stdout: '', stderr: 'lldb not found' }
      end

      script_path = File.join(snapshot_dir, 'lldb_commands.txt')
      stdout, stderr, status, timed_out = capture_runtime_snapshot_command(
        [lldb, '--batch', '-s', script_path],
        cwd: options.cwd,
        timeout: options.timeout
      )
      File.write(File.join(snapshot_dir, 'lldb_output.txt'), stdout)
      File.write(File.join(snapshot_dir, 'lldb_stderr.txt'), stderr)

      { ran: true, timed_out: timed_out, exit_status: status, stdout: stdout, stderr: stderr }
    end

    def runtime_snapshot_lldb_path
      output, status = Open3.capture2('xcrun', '--find', 'lldb')
      return output.strip if status.success? && !output.strip.empty?

      '/usr/bin/lldb' if File.executable?('/usr/bin/lldb')
    rescue StandardError
      '/usr/bin/lldb' if File.executable?('/usr/bin/lldb')
    end

    def capture_runtime_snapshot_command(command, cwd:, timeout:)
      stdout_text = +''
      stderr_text = +''
      status_code = nil
      timed_out = false

      Open3.popen3(*command, chdir: cwd, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }

        unless wait_thr.join(timeout)
          timed_out = true
          terminate_runtime_snapshot_process(wait_thr.pid)
          wait_thr.join(2) || kill_runtime_snapshot_process(wait_thr.pid)
        end

        stdout_text = stdout_reader.value.to_s
        stderr_text = stderr_reader.value.to_s
        status_code = wait_thr.value.exitstatus
      end

      [stdout_text, stderr_text, status_code, timed_out]
    end

    def terminate_runtime_snapshot_process(pid)
      Process.kill('TERM', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def kill_runtime_snapshot_process(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def write_runtime_snapshot_summary(snapshot_dir, metadata, lldb_result, options)
      lines = [
        '# Runtime Snapshot',
        '',
        "- Created: #{metadata[:created_at]}",
        "- Project: #{metadata[:project]}",
        "- Target: #{options.pid ? "pid #{options.pid}" : (options.executable || 'plan only')}",
        "- LLDB ran: #{lldb_result[:ran]}",
        "- Timed out: #{lldb_result[:timed_out]}",
        "- Exit status: #{lldb_result[:exit_status]}",
        '',
        '## Use This Evidence',
        '',
        'Cite the observed stack, frame variables, logs, or expression results before proposing a fix.',
        'Use side-effect-free expressions only; LLDB expression evaluation can execute code in the target process.',
        ''
      ]

      if options.dry_run || (!options.executable && !options.pid)
        lines += [
          '## Plan',
          '',
          'No runtime target was executed. Use `--executable PATH` for a reproducible Swift command/test binary, or `--pid PID` after launching an app through the canonical SaneProcess Mini-first path.',
          ''
        ]
      end

      lines += [
        '## Files',
        '',
        "- `metadata.json`",
        "- `lldb_commands.txt`",
        "- `lldb_output.txt`",
        "- `lldb_stderr.txt`",
        "- `source_context.md`",
        "- `recent_logs.txt`",
        ''
      ]

      File.write(File.join(snapshot_dir, 'summary.md'), "#{lines.join("\n")}\n")
    end

    def runtime_snapshot_ok?(options, lldb_result)
      return true if options.dry_run || (!options.executable && !options.pid)

      lldb_result[:ran] && !lldb_result[:timed_out] && lldb_result[:exit_status].to_i.zero?
    end

    def print_runtime_snapshot_result(result, json:)
      if json
        puts JSON.pretty_generate(result)
        return
      end

      puts '🧭 --- [ RUNTIME SNAPSHOT ] ---'
      puts "Evidence: #{result[:snapshot_dir]}"
      puts "Summary:  #{result[:summary]}"
      if result[:lldb_ran]
        puts "LLDB:     #{result[:lldb_output]}"
        puts result[:ok] ? '✅ Runtime snapshot complete.' : '⚠️  Runtime snapshot captured with LLDB errors.'
      else
        puts 'Plan-only snapshot complete. Add --executable or --pid to capture live runtime state.'
      end
    end

    def required_arg(args, index, flag)
      value = args[index + 1]
      raise ArgumentError, "#{flag} requires a value" if value.nil? || value.start_with?('--')

      value
    end
  end
end
