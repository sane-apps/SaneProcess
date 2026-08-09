# frozen_string_literal: true

require 'open3'
require 'shellwords'

module SaneMasterModules
  module MachineCleanupProcesses
    SANE_APP_NAMES = %w[
      SaneAI
      SaneBar
      SaneCite
      SaneClick
      SaneClip
      SaneHosts
      SaneLot
      SaneSales
      SaneScan
      SaneSync
      SaneVideo
    ].freeze
    SANE_APP_NAME_REGEX = /\b(#{SANE_APP_NAMES.join('|')})\b/
    BUILD_EXECUTABLES = %w[
      clang
      clang++
      ld
      swift
      swift-build
      swift-frontend
      swift-test
      swiftc
      xcodebuild
      xctest
    ].freeze
    WORKFLOW_SCRIPTS = %w[qa.rb release.sh sane_test.rb SaneMaster.rb].freeze
    ACTIVE_SANEMASTER_COMMANDS = %w[
      appstore_preflight
      build
      clean
      launch
      release
      release_preflight
      test_mode
      verify
    ].freeze

    private

    def machine_cleanup_active_inventory
      rows = machine_cleanup_ps_rows
      scan_failed = @machine_cleanup_process_scan_ok == false
      owners_by_pid = machine_cleanup_process_owners(rows)
      active = {
        apps: {},
        simulator_active: false,
        xcodebuild_active: false,
        workflow_active: false,
        training_active: false,
        codex_gui_active: false,
        process_scan_failed: scan_failed,
        mcp_processes: []
      }

      rows.each do |row|
        command = row[:command].to_s
        executable = machine_cleanup_process_executable(row)
        basename = File.basename(executable)
        Array(owners_by_pid[row[:pid]]).each do |app|
          active[:apps][app] ||= []
          active[:apps][app] << row
        end
        active[:simulator_active] ||= machine_cleanup_simulator_process?(executable, basename)
        active[:xcodebuild_active] ||= basename == 'xcodebuild'
        active[:workflow_active] ||= machine_cleanup_active_workflow_process?(row)
        active[:training_active] ||= machine_cleanup_training_process?(command, basename)
        active[:codex_gui_active] ||= machine_cleanup_codex_process?(executable, command)
        active[:mcp_processes] << row if machine_cleanup_mcp_process?(command, basename)
      end

      active[:apps] = active[:apps].transform_values { |list| list.first(5) }
      active[:mcp_processes] = active[:mcp_processes].first(10)
      active
    end

    def machine_cleanup_process_owners(rows)
      rows_by_pid = rows.to_h { |row| [row[:pid], row] }
      direct = rows.to_h { |row| [row[:pid], machine_cleanup_direct_process_apps(row)] }

      rows.to_h do |row|
        owners = direct.fetch(row[:pid], []).dup
        parent_pid = row[:ppid]
        visited = {}
        while parent_pid.to_i.positive? && !visited[parent_pid]
          visited[parent_pid] = true
          owners.concat(direct.fetch(parent_pid, []))
          parent = rows_by_pid[parent_pid]
          break unless parent

          parent_pid = parent[:ppid]
        end
        [row[:pid], owners.uniq]
      end
    end

    def machine_cleanup_direct_process_apps(row)
      command = row[:command].to_s
      executable = machine_cleanup_process_executable(row)
      basename = File.basename(executable)

      app_binary = SANE_APP_NAMES.find do |app|
        basename == app || executable.include?("/#{app}.app/Contents/MacOS/")
      end
      return [app_binary] if app_binary

      if executable.include?('.xctest/Contents/MacOS/') || BUILD_EXECUTABLES.include?(basename)
        return command.scan(SANE_APP_NAME_REGEX).flatten.uniq
      end

      return [] unless machine_cleanup_active_workflow_process?(row)

      [command, row[:cwd]].compact.join(' ').scan(SANE_APP_NAME_REGEX).flatten.uniq
    end

    def machine_cleanup_active_workflow_process?(row)
      command = row[:command].to_s
      executable = machine_cleanup_process_executable(row)
      return false unless %w[bash ruby sh zsh].include?(File.basename(executable))

      tokens = Shellwords.shellsplit(command)
      script_index = tokens.index { |token| WORKFLOW_SCRIPTS.include?(File.basename(token)) }
      return false unless script_index

      script = File.basename(tokens[script_index])
      return true unless script == 'SaneMaster.rb'

      ACTIVE_SANEMASTER_COMMANDS.include?(tokens[script_index + 1].to_s.tr('-', '_'))
    rescue ArgumentError
      false
    end

    def machine_cleanup_process_executable(row)
      explicit = row[:executable].to_s
      return explicit unless explicit.empty?

      Shellwords.shellsplit(row[:command].to_s).first.to_s
    rescue ArgumentError
      row[:command].to_s.split(/\s+/, 2).first.to_s
    end

    def machine_cleanup_simulator_process?(executable, basename)
      %w[Simulator CoreSimulatorService launchd_sim simctl].include?(basename) ||
        executable.include?('/Simulator.app/')
    end

    def machine_cleanup_training_process?(command, basename)
      return false unless %w[mlx mlx_lm python python3 ruby].include?(basename)

      command.match?(/(?:\A|[\/_.-])(train|training|finetune|inference)(?:[\/_.-]|\z)/i)
    end

    def machine_cleanup_codex_process?(executable, command)
      executable.include?('/Applications/Codex.app/Contents/MacOS/') ||
        command.start_with?('/Applications/Codex.app/Contents/MacOS/') ||
        command.start_with?('Codex (Service)') || command.start_with?('Codex (Renderer)')
    end

    def machine_cleanup_mcp_process?(command, basename)
      basename.match?(/mcp/i) || command.match?(/(?:\A|[\/_.-])xcodebuildmcp(?:[\/_.-]|\z)/i)
    end

    def machine_cleanup_ps_rows
      return @machine_cleanup_ps_rows if defined?(@machine_cleanup_ps_rows)

      output, status = Open3.capture2e('ps', '-axo', 'pid,ppid,pgid,stat,etime,command')
      unless status.success?
        @machine_cleanup_process_scan_ok = false
        @machine_cleanup_ps_rows = []
        return @machine_cleanup_ps_rows
      end

      rows = output.lines.drop(1).each_with_object([]) do |line, parsed|
        parts = line.strip.split(/\s+/, 6)
        next if parts.length < 6

        command = parts[5].to_s
        parsed << {
          pid: parts[0].to_i,
          ppid: parts[1].to_i,
          pgid: parts[2].to_i,
          stat: parts[3],
          etime: parts[4],
          executable: machine_cleanup_process_executable(command: command),
          command: command
        }
      end
      @machine_cleanup_process_scan_ok = !rows.empty?
      @machine_cleanup_ps_rows = rows
    rescue SystemCallError
      @machine_cleanup_process_scan_ok = false
      @machine_cleanup_ps_rows = []
    end
  end
end
