# frozen_string_literal: true

require 'English'
require 'json'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'optparse'
require 'set'
require 'time'
require 'yaml'

module SaneMasterModules
  # Shared constants and utilities used across all modules
  module Base
    # --- Paths ---
    SOP_SNAPSHOT_DIR = File.expand_path('~/.sanemaster/snapshots')
    SOP_LOG_DIR = File.expand_path('~/.sanemaster/logs')
    HOMEBREW_RUBY = '/opt/homebrew/opt/ruby/bin/ruby'
    HOMEBREW_BUNDLE = '/opt/homebrew/opt/ruby/bin/bundle'
    VERSION_CACHE_FILE = File.expand_path('~/.sanemaster/versions_cache.json')
    VERSION_CACHE_MAX_AGE = 7 * 24 * 60 * 60 # 7 days in seconds
    TEMPLATE_DIR = File.expand_path('~/.sanemaster/templates')
    MEMORY_FILE = File.join(Dir.pwd, '.claude', 'memory.json')
    WORK_SESSION_STATE_FILE = File.expand_path('~/.sanemaster/work_session_state.json')
    WORK_SESSION_CAFFEINATE_PID_FILE = File.expand_path('~/.sanemaster/work_session_caffeinate.pid')
    WORK_SESSION_CAFFEINATE_LOG = File.expand_path('~/.sanemaster/work_session_caffeinate.log')
    WORK_SESSION_COMMANDS = Set.new(%w[
                                      verify
                                      clean
                                      lint
                                      audit
                                      tool_discovery
                                      tool_receipt
                                      system_check
                                      doctor
                                      qa
                                      launch
                                      run
                                      logs
                                      test_mode
                                      tm
                                      diagnose
                                      crash_report
                                      crashes
                                      release
                                      release_preflight
                                      appstore_preflight
                                      asp
                                    ]).freeze

    def homebrew_ruby_path
      HOMEBREW_RUBY
    end

    def homebrew_bundle_path
      HOMEBREW_BUNDLE
    end

    def preferred_ruby_bin
      File.executable?(homebrew_ruby_path) ? homebrew_ruby_path : 'ruby'
    end

    def preferred_bundle_bin
      File.executable?(homebrew_bundle_path) ? homebrew_bundle_path : 'bundle'
    end

    def bundle_available?
      File.executable?(homebrew_bundle_path) || system('command -v bundle >/dev/null 2>&1')
    end

    def ruby_tool_env(base_env = ENV.to_h)
      return {} unless File.executable?(homebrew_ruby_path)

      ruby_bin_dir = File.dirname(homebrew_ruby_path)
      current_path = base_env.fetch('PATH', ENV.fetch('PATH', ''))
      path_entries = current_path.split(File::PATH_SEPARATOR).reject(&:empty?)
      path_entries = [ruby_bin_dir] + path_entries.reject { |entry| entry == ruby_bin_dir }

      { 'PATH' => path_entries.join(File::PATH_SEPARATOR) }
    end

    def bundle_tool_env(base_env = ENV.to_h)
      env = ruby_tool_env(base_env)
      env['BUNDLE_PATH'] = base_env.fetch('BUNDLE_PATH', ENV.fetch('BUNDLE_PATH', 'vendor/bundle'))
      env
    end

    def system_with_ruby_env(*command, extra_env: {}, out: nil, err: nil)
      options = {}
      options[:out] = out unless out.nil?
      options[:err] = err unless err.nil?
      system(ruby_tool_env.merge(extra_env), *command, **options)
    end

    def capture2e_with_ruby_env(*command, extra_env: {})
      Open3.capture2e(ruby_tool_env.merge(extra_env), *command)
    end

    def system_with_bundle_env(*command, extra_env: {}, out: nil, err: nil)
      options = {}
      options[:out] = out unless out.nil?
      options[:err] = err unless err.nil?
      system(bundle_tool_env.merge(extra_env), *command, **options)
    end

    def capture2e_with_bundle_env(*command, extra_env: {})
      Open3.capture2e(bundle_tool_env.merge(extra_env), *command)
    end

    # --- Project Resolution ---

    def project_name
      @project_name ||= config_value(%w[name], 'SANEMASTER_PROJECT', File.basename(Dir.pwd))
    end

    def project_scheme
      @project_scheme ||= config_value(%w[scheme], 'SANEMASTER_SCHEME', project_name)
    end

    def project_xcodeproj
      @project_xcodeproj ||= begin
        from_config = config_value(%w[build xcodeproj], 'SANEMASTER_XCODEPROJ', nil) || saneprocess_value('project')
        from_config || Dir.glob('*.xcodeproj').first
      end
    end

    def project_workspace
      @project_workspace ||= config_value(%w[build workspace], 'SANEMASTER_WORKSPACE', nil)
    end

    def xcodebuild_container_args
      xcodebuild_container_args_for_scheme(project_scheme)
    end

    def xcodebuild_container_args_for_scheme(scheme)
      if workspace_usable_for_scheme?(scheme)
        ['-workspace', project_workspace]
      elsif project_xcodeproj && !project_xcodeproj.to_s.empty?
        ['-project', project_xcodeproj]
      else
        []
      end
    end

    def workspace_usable_for_scheme?(scheme = project_scheme)
      return false if project_workspace.to_s.empty?
      return false unless File.exist?(project_workspace.to_s)

      list_output = `xcodebuild -list -workspace #{Shellwords.escape(project_workspace.to_s)} 2>/dev/null`
      return false if list_output.include?('There are no schemes in workspace')

      list_output.include?(scheme.to_s)
    rescue StandardError
      false
    end

    def project_app_dir
      @project_app_dir ||= config_value(%w[build app_dir], 'SANEMASTER_APP_DIR', project_name)
    end

    def project_tests_dir
      @project_tests_dir ||= config_value(%w[tests unit_dir], 'SANEMASTER_TESTS_DIR', "#{project_name}Tests")
    end

    def project_ui_tests_dir
      @project_ui_tests_dir ||= config_value(%w[tests ui_dir], 'SANEMASTER_UI_TESTS_DIR', "#{project_name}UITests")
    end

    def project_test_target
      @project_test_target ||= config_value(%w[tests unit_target], 'SANEMASTER_TEST_TARGET', project_tests_dir)
    end

    def project_ui_test_target
      @project_ui_test_target ||= config_value(%w[tests ui_target], 'SANEMASTER_UI_TEST_TARGET', project_ui_tests_dir)
    end

    def project_ui_scheme
      @project_ui_scheme ||= config_value(%w[tests ui_scheme], 'SANEMASTER_UI_SCHEME', saneprocess_value('appstore', 'ios_scheme') || project_scheme)
    end

    def project_ui_destination
      @project_ui_destination ||= config_value(%w[tests ui_destination], 'SANEMASTER_UI_DESTINATION', 'platform=iOS Simulator,name=iPhone 17 Pro')
    end

    def saneprocess_config
      return @saneprocess_config if defined?(@saneprocess_config)

      path = File.join(Dir.pwd, '.saneprocess')
      @saneprocess_config = if File.exist?(path)
                              YAML.safe_load(File.read(path)) || {}
                            else
                              {}
                            end
    rescue StandardError
      @saneprocess_config = {}
    end

    def saneprocess_value(*keys)
      keys.reduce(saneprocess_config) do |acc, key|
        break nil unless acc.is_a?(Hash)

        acc[key] || acc[key.to_s]
      end
    end

    def config_value(config_keys, env_key, fallback)
      return ENV[env_key] if ENV.key?(env_key)

      value = saneprocess_value(*config_keys)
      value.nil? ? fallback : value
    end

    # --- Tool Versions ---
    TOOL_VERSIONS = {
      'swiftlint' => { cmd: 'swiftlint --version', min: '0.62.0' },
      'xcodegen' => { cmd: 'xcodegen --version', extract: /Version: ([\d.]+)/, min: '2.44.0' },
      'periphery' => { cmd: 'periphery version', min: '3.2.0' },
      'mockolo' => { cmd: 'mockolo --version', min: '2.4.0' },
      'lefthook' => { cmd: 'lefthook --version', extract: /lefthook version ([\d.]+)/, min: '2.0.0' }
    }.freeze

    TOOL_SOURCES = {
      'swiftlint' => { type: :homebrew, formula: 'swiftlint' },
      'xcodegen' => { type: :homebrew, formula: 'xcodegen' },
      'periphery' => { type: :homebrew, formula: 'periphery' },
      'mockolo' => { type: :github, repo: 'uber/mockolo' },
      'lefthook' => { type: :homebrew, formula: 'lefthook' },
      'fastlane' => { type: :rubygems, gem: 'fastlane' },
      'ruby' => { type: :homebrew, formula: 'ruby' }
    }.freeze

    # --- SOP Directory Helpers ---

    def ensure_sop_dirs
      FileUtils.mkdir_p(SOP_SNAPSHOT_DIR)
      FileUtils.mkdir_p(SOP_LOG_DIR)
    end

    def work_session_command?(command)
      WORK_SESSION_COMMANDS.include?(command.to_s)
    end

    def ensure_work_session_ready!(command)
      return unless work_session_command?(command)
      return if ENV['SANEMASTER_DISABLE_WORK_SESSION'] == '1'
      return unless RUBY_PLATFORM.include?('darwin')

      ensure_sop_dirs
      FileUtils.mkdir_p(File.dirname(WORK_SESSION_STATE_FILE))

      activate_work_session_caffeinate
      capture_work_session_defaults unless File.exist?(WORK_SESSION_STATE_FILE)
      apply_work_session_defaults
    end

    def work_session_on
      puts '🔒 --- [ WORK SESSION ON ] ---'
      ensure_work_session_ready!('verify')
      print_work_session_status
    end

    def work_session_off
      puts '🔓 --- [ WORK SESSION OFF ] ---'
      restore_work_session_defaults
      stop_work_session_caffeinate
      print_work_session_status
    end

    def work_session_status
      puts '🛠️  --- [ WORK SESSION STATUS ] ---'
      print_work_session_status
    end

    def sop_log(message)
      return unless @sop_log

      File.open(@sop_log, 'a') { |f| f.puts "[#{Time.now.iso8601}] #{message}" }
    end

    def activate_work_session_caffeinate
      existing_pid = read_work_session_caffeinate_pid
      return if existing_pid && process_alive?(existing_pid)

      FileUtils.rm_f(WORK_SESSION_CAFFEINATE_PID_FILE)
      cmd = [
        '/bin/sh', '-lc',
        "nohup /usr/bin/caffeinate -dimsu >> #{Shellwords.escape(WORK_SESSION_CAFFEINATE_LOG)} 2>&1 & echo $! > #{Shellwords.escape(WORK_SESSION_CAFFEINATE_PID_FILE)}"
      ]
      ok = system(*cmd, out: File::NULL, err: File::NULL)
      pid = read_work_session_caffeinate_pid
      raise 'unable to confirm caffeinate pid' unless ok && pid

      sop_log("Started work-session caffeinate pid=#{pid}")
    rescue StandardError => e
      warn "⚠️  Failed to start work-session caffeinate: #{e.message}"
    end

    def stop_work_session_caffeinate
      pid = read_work_session_caffeinate_pid
      if pid && process_alive?(pid)
        Process.kill('TERM', pid)
      end
    rescue Errno::ESRCH
      nil
    rescue StandardError => e
      warn "⚠️  Failed to stop work-session caffeinate: #{e.message}"
    ensure
      FileUtils.rm_f(WORK_SESSION_CAFFEINATE_PID_FILE)
    end

    def read_work_session_caffeinate_pid
      return nil unless File.exist?(WORK_SESSION_CAFFEINATE_PID_FILE)

      Integer(File.read(WORK_SESSION_CAFFEINATE_PID_FILE).strip)
    rescue StandardError
      nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def capture_work_session_defaults
      state = {
        'saved_at' => Time.now.iso8601,
        'host' => Socket.gethostname,
        'idle_time' => read_defaults_value(current_host: true, domain: 'com.apple.screensaver', key: 'idleTime'),
        'ask_for_password' => read_defaults_value(current_host: false, domain: 'com.apple.screensaver', key: 'askForPassword'),
        'screen_lock_status' => current_screen_lock_status
      }
      File.write(WORK_SESSION_STATE_FILE, JSON.pretty_generate(state))
      sop_log("Captured work-session defaults for #{state['host']}")
    rescue StandardError => e
      warn "⚠️  Failed to capture work-session defaults: #{e.message}"
    end

    def apply_work_session_defaults
      write_defaults_value(current_host: true, domain: 'com.apple.screensaver', key: 'idleTime', type: '-int', value: '0')
      write_defaults_value(current_host: false, domain: 'com.apple.screensaver', key: 'askForPassword', type: '-int', value: '0')
      system('killall', 'cfprefsd', out: File::NULL, err: File::NULL)
      sop_log('Applied work-session screensaver/lock defaults')
    rescue StandardError => e
      warn "⚠️  Failed to apply work-session defaults: #{e.message}"
    end

    def restore_work_session_defaults
      return unless File.exist?(WORK_SESSION_STATE_FILE)

      state = JSON.parse(File.read(WORK_SESSION_STATE_FILE))
      restore_defaults_value(current_host: true, domain: 'com.apple.screensaver', key: 'idleTime', snapshot: state['idle_time'])
      restore_defaults_value(current_host: false, domain: 'com.apple.screensaver', key: 'askForPassword', snapshot: state['ask_for_password'])
      system('killall', 'cfprefsd', out: File::NULL, err: File::NULL)
      FileUtils.rm_f(WORK_SESSION_STATE_FILE)
      sop_log("Restored work-session defaults for #{state['host']}")
    rescue StandardError => e
      warn "⚠️  Failed to restore work-session defaults: #{e.message}"
    end

    def read_defaults_value(current_host:, domain:, key:)
      cmd = ['defaults']
      cmd << '-currentHost' if current_host
      cmd += ['read', domain, key]
      output = `#{cmd.map { |part| Shellwords.escape(part) }.join(' ')} 2>/dev/null`
      status = $CHILD_STATUS.success?
      {
        'exists' => status,
        'value' => status ? output.strip : nil
      }
    end

    def write_defaults_value(current_host:, domain:, key:, type:, value:)
      cmd = ['defaults']
      cmd << '-currentHost' if current_host
      cmd += ['write', domain, key, type, value]
      system(*cmd, out: File::NULL, err: File::NULL)
    end

    def restore_defaults_value(current_host:, domain:, key:, snapshot:)
      return unless snapshot.is_a?(Hash)

      if snapshot['exists']
        write_defaults_value(
          current_host: current_host,
          domain: domain,
          key: key,
          type: defaults_type_for(snapshot['value']),
          value: snapshot['value'].to_s
        )
      else
        cmd = ['defaults']
        cmd << '-currentHost' if current_host
        cmd += ['delete', domain, key]
        system(*cmd, out: File::NULL, err: File::NULL)
      end
    end

    def defaults_type_for(value)
      return '-int' if value.to_s.match?(/\A-?\d+\z/)
      return '-float' if value.to_s.match?(/\A-?\d+\.\d+\z/)

      '-string'
    end

    def current_screen_lock_status
      `sysadminctl -screenLock status 2>&1`.strip
    rescue StandardError
      'unavailable'
    end

    def print_work_session_status
      caffeinate_pid = read_work_session_caffeinate_pid
      caffeinate_status = if caffeinate_pid && process_alive?(caffeinate_pid)
                            "running (pid #{caffeinate_pid})"
                          else
                            'stopped'
                          end
      idle_time = read_defaults_value(current_host: true, domain: 'com.apple.screensaver', key: 'idleTime')
      ask_for_password = read_defaults_value(current_host: false, domain: 'com.apple.screensaver', key: 'askForPassword')

      puts "   caffeinate: #{caffeinate_status}"
      puts "   screensaver idleTime: #{idle_time['exists'] ? idle_time['value'] : '(default)'}"
      puts "   askForPassword: #{ask_for_password['exists'] ? ask_for_password['value'] : '(default)'}"
      puts "   sysadminctl: #{current_screen_lock_status}"
      if current_screen_lock_status.include?('immediate')
        puts "   note: full unattended no-lock still requires a one-time 'sysadminctl -screenLock off -password -' on this Mac."
      end
    end

    # --- Memory Helpers ---

    # Load memory from STDIN (piped from mcp__memory__read_graph) or local cache
    def load_memory(from_stdin: false)
      if from_stdin
        input = begin
          $stdin.read.strip
        rescue StandardError
          ''
        end
        return nil if input.empty?

        begin
          memory = JSON.parse(input)
          # Cache locally for future use
          save_memory(memory)
          memory
        rescue JSON::ParserError
          nil
        end
      elsif File.exist?(MEMORY_FILE)
        JSON.parse(File.read(MEMORY_FILE))
      else
        warn ''
        warn '⚠️  No local memory cache found at .claude/memory.json'
        warn ''
        warn 'To use memory commands, pipe from MCP:'
        warn '  1. Ask Claude to run: mcp__memory__read_graph'
        warn '  2. Copy the JSON output'
        warn '  3. Run: echo \'<json>\' | ./Scripts/SaneMaster.rb <command>'
        warn ''
        warn 'Or use: ./Scripts/SaneMaster.rb msync to create a cache.'
        warn ''
        nil
      end
    rescue JSON::ParserError
      nil
    end

    def save_memory(memory)
      FileUtils.mkdir_p(File.dirname(MEMORY_FILE))
      File.write(MEMORY_FILE, JSON.pretty_generate(memory))
    end

    # Sync memory from STDIN (requires piping from mcp__memory__read_graph)
    def memory_sync(_args)
      puts '🔄 --- [ MEMORY SYNC ] ---'
      puts ''
      puts 'Paste the output from mcp__memory__read_graph below,'
      puts 'then press Ctrl+D (or Ctrl+Z on Windows) when done:'
      puts ''

      memory = load_memory(from_stdin: true)
      if memory
        count = (memory['entities'] || []).count
        puts ''
        puts "✅ Synced #{count} entities to .claude/memory.json"
      else
        puts ''
        puts '❌ No valid JSON received'
      end
    end
  end
end
