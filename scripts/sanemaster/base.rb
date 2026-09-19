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
    REQUIRED_RUBY_VERSION = ENV.fetch('SANEPROCESS_REQUIRED_RUBY_VERSION', '4.0.0')
    HOMEBREW_RUBY = '/opt/homebrew/opt/ruby/bin/ruby'
    HOMEBREW_BUNDLE = '/opt/homebrew/opt/ruby/bin/bundle'
    HOMEBREW_RUBY_GEM_BIN = '/opt/homebrew/lib/ruby/gems/4.0.0/bin'
    DEFAULT_IOS_SIMULATOR_DEVICE_TYPE_NAME = 'iPhone 17 Pro'
    REQUIRED_RUBY_GEMS = {
      'jwt' => 'App Store Connect submission helpers'
    }.freeze
    VERSION_CACHE_FILE = File.expand_path('~/.sanemaster/versions_cache.json')
    VERSION_CACHE_MAX_AGE = 7 * 24 * 60 * 60 # 7 days in seconds
    TEMPLATE_DIR = File.expand_path('~/.sanemaster/templates')
    WORK_SESSION_STATE_FILE = File.expand_path('~/.sanemaster/work_session_state.json')
    WORK_SESSION_CAFFEINATE_PID_FILE = File.expand_path('~/.sanemaster/work_session_caffeinate.pid')
    WORK_SESSION_DURATION = 12 * 60 * 60
    WORK_SESSION_CAFFEINATE_LOG = File.expand_path('~/.sanemaster/work_session_caffeinate.log')
    WORK_SESSION_RESTART_INHIBIT = File.expand_path('~/.sanemaster/restart-inhibit')
    SERVER_MAINTENANCE_ACTIVE_DIR = File.expand_path('~/.sanemaster/maintenance-active')
    SERVER_RESTART_EXCLUSIVE_DIR = File.expand_path('~/.sanemaster/restart-exclusive')
    WORK_SESSION_COMMANDS = Set.new(%w[
                                      verify
                                      clean
                                      lint
                                      audit
                                      tool_discovery
                                      tool_receipt
                                      secret_scan
                                      system_check
                                      doctor
                                      qa
                                      launch
                                      run
                                      logs
                                      test_mode
                                      tm
                                      visual_smoke
                                      visual-smoke
                                      resource_soak
                                      resource-soak
                                      diagnose
                                      crash_report
                                      crashes
      release
      upgrade_path_proof
      release_preflight
                                      appstore_preflight
                                      setapp_status
                                      setapp-status
                                      setapp_package
                                      setapp-package
                                      setapp_upload
                                      setapp-upload
                                      asp
                                    ]).freeze

    def homebrew_ruby_path
      HOMEBREW_RUBY
    end

    def homebrew_bundle_path
      HOMEBREW_BUNDLE
    end

    def required_ruby_version
      REQUIRED_RUBY_VERSION
    end

    def homebrew_ruby_gem_bin
      HOMEBREW_RUBY_GEM_BIN
    end

    def ruby_version_at_least?(current, required = required_ruby_version)
      current_parts = current.to_s.split('.').map(&:to_i)
      required_parts = required.to_s.split('.').map(&:to_i)
      max = [current_parts.length, required_parts.length].max

      (0...max).each do |index|
        current_part = current_parts[index] || 0
        required_part = required_parts[index] || 0
        return true if current_part > required_part
        return false if current_part < required_part
      end

      true
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
      preferred_entries = [ruby_bin_dir]
      preferred_entries << homebrew_ruby_gem_bin if File.directory?(homebrew_ruby_gem_bin)
      path_entries = preferred_entries + path_entries.reject { |entry| preferred_entries.include?(entry) }

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
      # Empty **options under ruby 2.6 appends a literal {} (see route_system).
      return system(ruby_tool_env.merge(extra_env), *command) if options.empty?

      system(ruby_tool_env.merge(extra_env), *command, **options)
    end

    def capture2e_with_ruby_env(*command, extra_env: {})
      Open3.capture2e(ruby_tool_env.merge(extra_env), *command)
    end

    def system_with_bundle_env(*command, extra_env: {}, out: nil, err: nil)
      options = {}
      options[:out] = out unless out.nil?
      options[:err] = err unless err.nil?
      # Empty **options under ruby 2.6 appends a literal {} (see route_system).
      return system(bundle_tool_env.merge(extra_env), *command) if options.empty?

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

    def project_unit_destination
      @project_unit_destination ||= ENV['SANEMASTER_UNIT_DESTINATION'] ||
                                    ENV['SANEMASTER_TEST_DESTINATION'] ||
                                    saneprocess_value('tests', 'unit_destination') ||
                                    default_project_test_destination
    end

    def project_ui_test_target
      @project_ui_test_target ||= config_value(%w[tests ui_target], 'SANEMASTER_UI_TEST_TARGET', project_ui_tests_dir)
    end

    def project_ui_scheme
      @project_ui_scheme ||= config_value(%w[tests ui_scheme], 'SANEMASTER_UI_SCHEME', saneprocess_value('appstore', 'ios_scheme') || project_scheme)
    end

    def project_ui_destination
      @project_ui_destination ||= config_value(
        %w[tests ui_destination],
        'SANEMASTER_UI_DESTINATION',
        default_project_test_destination
      )
    end

    def resolved_xcodebuild_destination(destination)
      destination = destination.to_s
      return destination if destination.empty?
      return destination unless destination.include?('platform=iOS Simulator')
      return destination if destination.match?(/(?:\A|,)id=/)

      simulator_name = destination[/name=([^,]+)/, 1].to_s.strip
      return destination if simulator_name.empty?

      candidates = ios_simulator_destinations.select { |simulator| simulator[:name] == simulator_name }
      requested_os = destination[/OS=([^,]+)/, 1].to_s.strip
      if !requested_os.empty? && requested_os.downcase != 'latest'
        os_matches = candidates.select { |simulator| simulator[:os] == requested_os }
        candidates = os_matches unless os_matches.empty?
      end
      chosen = candidates.find { |simulator| simulator[:state] == 'Booted' } ||
               candidates.max_by { |simulator| simulator_os_sort_key(simulator[:os]) }
      return "id=#{chosen[:udid]}" if chosen

      created_udid = create_ios_simulator_destination(simulator_name, requested_os)
      return "id=#{created_udid}" if created_udid

      destination
    end

    def ios_simulator_destinations
      @ios_simulator_destinations ||= begin
        output, status = Open3.capture2e('xcrun', 'simctl', 'list', 'devices', 'available', '--json')
        if status.success?
          data = JSON.parse(output)
          devices = data['devices'].is_a?(Hash) ? data['devices'] : {}
          devices.flat_map do |runtime, runtime_devices|
            next [] unless runtime.to_s.include?('iOS')

            os = runtime[/iOS[- ](\d+(?:[-.]\d+)*)/, 1].to_s.tr('-', '.')
            Array(runtime_devices).each_with_object([]) do |device, result|
              next unless device.is_a?(Hash)

              udid = device['udid'].to_s
              name = device['name'].to_s
              next if udid.empty? || name.empty?

              result << { name: name, udid: udid, os: os, state: device['state'].to_s }
            end
          end
        else
          []
        end
      end
    rescue StandardError
      []
    end

    def create_ios_simulator_destination(simulator_name, requested_os = nil)
      return nil if ENV['SANEMASTER_AUTO_CREATE_IOS_SIMULATOR'] == '0'

      device_type = ios_simulator_device_type_for(simulator_name)
      return nil unless device_type

      runtime = ios_simulator_runtimes_for(device_type[:identifier], requested_os).max_by do |candidate|
        simulator_os_sort_key(candidate[:version])
      end
      return nil unless runtime

      output, status = Open3.capture2e(
        'xcrun',
        'simctl',
        'create',
        simulator_name,
        device_type[:identifier],
        runtime[:identifier]
      )
      return nil unless status.success?

      @ios_simulator_destinations = nil
      output.to_s.lines.map(&:strip).find { |line| line.match?(/\A[0-9A-F-]{36}\z/i) }
    rescue StandardError
      nil
    end

    def ios_simulator_device_type_for(simulator_name)
      device_types = ios_simulator_device_types
      exact = device_types.find { |candidate| candidate[:name] == simulator_name }
      return exact if exact

      custom_iphone = simulator_name.to_s.split(/[-_\s]+/).any? { |token| token.casecmp('iPhone').zero? }
      return nil unless custom_iphone

      device_types.find { |candidate| candidate[:name] == DEFAULT_IOS_SIMULATOR_DEVICE_TYPE_NAME }
    end

    def ios_simulator_device_types
      @ios_simulator_device_types ||= begin
        output, status = Open3.capture2e('xcrun', 'simctl', 'list', 'devicetypes', '--json')
        if status.success?
          data = JSON.parse(output)
          Array(data['devicetypes']).each_with_object([]) do |device_type, device_types|
            next device_types unless device_type.is_a?(Hash)

            name = device_type['name'].to_s
            identifier = device_type['identifier'].to_s
            next device_types if name.empty? || identifier.empty?

            device_types << { name: name, identifier: identifier }
          end
        else
          []
        end
      end
    rescue StandardError
      []
    end

    def ios_simulator_runtimes_for(device_type_identifier, requested_os = nil)
      output, status = Open3.capture2e('xcrun', 'simctl', 'list', 'runtimes', 'available', '--json')
      return [] unless status.success?

      data = JSON.parse(output)
      Array(data['runtimes']).each_with_object([]) do |runtime, runtimes|
        next runtimes unless runtime.is_a?(Hash)
        next runtimes unless runtime['isAvailable'] != false

        identifier = runtime['identifier'].to_s
        version = runtime['version'].to_s
        next runtimes unless identifier.include?('iOS') || runtime['name'].to_s.include?('iOS')
        next runtimes if identifier.empty? || version.empty?

        supported = Array(runtime['supportedDeviceTypes']).any? do |device_type|
          device_type.is_a?(Hash) && device_type['identifier'].to_s == device_type_identifier
        end
        next runtimes unless supported
        if requested_os.to_s.strip != '' &&
           requested_os.to_s.downcase != 'latest' &&
           version != requested_os.to_s
          next runtimes
        end

        runtimes << { identifier: identifier, version: version }
      end
    rescue StandardError
      []
    end

    def simulator_os_sort_key(os)
      os.to_s.scan(/\d+/).map(&:to_i)
    end

    def default_project_test_destination
      ios_only_project? ? "platform=iOS Simulator,name=#{DEFAULT_IOS_SIMULATOR_DEVICE_TYPE_NAME}" : 'platform=macOS,arch=arm64'
    end

    def ios_only_project?
      type = saneprocess_value('type').to_s.downcase
      platforms = Array(saneprocess_value('appstore', 'platforms')).map { |platform| platform.to_s.downcase }
      type == 'ios_app' || (platforms.include?('ios') && !platforms.include?('macos'))
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
      acquire_server_maintenance_holder!
      FileUtils.touch(WORK_SESSION_RESTART_INHIBIT)

      raise 'Work-session protection could not be started' unless activate_work_session_caffeinate
    end

    def acquire_server_maintenance_holder!
      return if @server_maintenance_holder_path
      raise 'Mini weekly restart gate is active; retry after the restart window' if Dir.exist?(SERVER_RESTART_EXCLUSIVE_DIR)

      FileUtils.mkdir_p(SERVER_MAINTENANCE_ACTIVE_DIR)
      holder = File.join(SERVER_MAINTENANCE_ACTIVE_DIR, Process.pid.to_s)
      File.write(holder, "#{Time.now.utc.iso8601}\n")
      if Dir.exist?(SERVER_RESTART_EXCLUSIVE_DIR)
        FileUtils.rm_f(holder)
        raise 'Mini weekly restart gate became active; retry after the restart window'
      end

      @server_maintenance_holder_path = holder
      at_exit { FileUtils.rm_f(holder) }
    end

    def work_session_on
      puts '🔒 --- [ WORK SESSION ON ] ---'
      ensure_work_session_ready!('verify')
      print_work_session_status
    end

    def work_session_off
      puts '🔓 --- [ WORK SESSION OFF ] ---'
      if File.exist?(WORK_SESSION_STATE_FILE)
        warn "Saved legacy lock preferences left unchanged: #{WORK_SESSION_STATE_FILE}"
      end
      stop_work_session_caffeinate
      FileUtils.rm_f(WORK_SESSION_RESTART_INHIBIT)
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
      pid = identity = nil
      with_work_session_lock do
        previous = read_work_session_record
        pid = Process.spawn('/usr/bin/nice', '-n', '10', '/usr/bin/caffeinate',
                            '-dimsu', '-t', WORK_SESSION_DURATION.to_s,
                            in: File::NULL, out: [WORK_SESSION_CAFFEINATE_LOG, 'a'], err: [:child, :out], pgroup: true)
        Process.detach(pid)
        identity = nil
        20.times do
          identity = work_session_process_identity(pid)
          break if identity && identity['executable'] == '/usr/bin/caffeinate' && work_session_assertions_ready?(pid)
          sleep 0.05
        end
        unless identity && identity['executable'] == '/usr/bin/caffeinate' && work_session_assertions_ready?(pid)
          raise 'unable to confirm owned caffeinate assertions'
        end

        record = identity.merge('pid' => pid, 'expires_at' => (Time.now + WORK_SESSION_DURATION).utc.iso8601)
        temporary = "#{WORK_SESSION_CAFFEINATE_PID_FILE}.#{Process.pid}"
        File.write(temporary, JSON.generate(record), mode: 'w', perm: 0o600)
        File.rename(temporary, WORK_SESSION_CAFFEINATE_PID_FILE)
        # Replacement exists before the prior assertion is released.
        terminate_work_session_process(previous)
        sop_log("Started work-session caffeinate pid=#{pid} expires=#{record['expires_at']}")
      end
      true
    rescue StandardError => e
      terminate_work_session_process(identity.merge('pid' => pid)) if identity && pid
      warn "⚠️  Work-session protection renewal failed: #{e.message}"
      false
    end

    def with_work_session_lock
      FileUtils.mkdir_p(File.dirname(WORK_SESSION_CAFFEINATE_PID_FILE))
      File.open("#{WORK_SESSION_CAFFEINATE_PID_FILE}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def work_session_process_identity(pid)
      return nil unless pid.is_a?(Integer) && pid.positive?

      output, status = Open3.capture2('/bin/ps', '-p', pid.to_s, '-o', 'uid=', '-o', 'lstart=', '-o', 'comm=')
      match = output.strip.match(/\A(\d+)\s+(.{24})\s+(.+)\z/)
      return nil unless status.success? && match

      { 'uid' => match[1].to_i, 'started_at' => match[2], 'executable' => match[3] }
    end

    def work_session_assertions_ready?(pid)
      output, status = Open3.capture2('/usr/bin/pmset', '-g', 'assertions')
      return false unless status.success?

      owned = output.lines.select { |line| line.match?(/\bpid #{pid}\(caffeinate\):/) }.join
      %w[UserIsActive PreventUserIdleDisplaySleep PreventUserIdleSystemSleep].all? do |kind|
        owned.match?(/\b#{kind}\b/)
      end
    end

    def owned_work_session_process?(record)
      return false unless record.is_a?(Hash) && record['uid'] == Process.uid &&
                          record['executable'] == '/usr/bin/caffeinate' && record['started_at']

      work_session_process_identity(record['pid']) ==
        record.slice('uid', 'started_at', 'executable')
    end

    def terminate_work_session_process(record)
      return unless owned_work_session_process?(record)

      Process.kill('TERM', record['pid'])
    rescue Errno::ESRCH
      nil
    end

    def stop_work_session_caffeinate
      with_work_session_lock do
        record = read_work_session_record
        if record && process_alive?(record['pid']) && !owned_work_session_process?(record)
          warn "Unverified work-session PID #{record['pid']} left running; no process was killed."
        else
          terminate_work_session_process(record)
        end
        FileUtils.rm_f(WORK_SESSION_CAFFEINATE_PID_FILE)
      end
    rescue StandardError => e
      warn "⚠️  Failed to stop work-session caffeinate: #{e.message}"
    end

    def read_work_session_record
      return nil unless File.exist?(WORK_SESSION_CAFFEINATE_PID_FILE)

      value = JSON.parse(File.read(WORK_SESSION_CAFFEINATE_PID_FILE))
      value = { 'pid' => value } if value.is_a?(Integer)
      return value if value.is_a?(Hash) && value['pid'].is_a?(Integer) && value['pid'].positive?
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def read_work_session_caffeinate_pid
      read_work_session_record&.fetch('pid')
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def print_work_session_status
      record = read_work_session_record
      expires = Time.iso8601(record['expires_at']) if record && record['expires_at']
      if owned_work_session_process?(record) && expires && expires > Time.now && work_session_assertions_ready?(record['pid'])
        puts "   caffeinate: active (pid #{record['pid']}); expires #{expires.utc.iso8601}"
      else
        puts '   caffeinate: NOT PROTECTED (stopped, expired, or unverified)'
      end
      puts '   lock and automatic logout preferences: unchanged'
      puts '   bounded manual session; renew during long work and run work_session_off when finished'
    rescue ArgumentError
      puts '   caffeinate: NOT PROTECTED (invalid session expiry)'
    end

  end
end
