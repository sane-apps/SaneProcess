# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'socket'
require 'time'
require_relative 'process_tree_cleanup'

module SaneMasterModules
  # CI/CD test helpers — replaces standalone bash scripts:
  #   enable_tests_for_ci.sh → enable_ci_tests
  #   restore_tests_after_ci.sh → restore_ci_tests
  #   post_mock_generation.sh → fix_mocks
  #   monitor_tests.sh → monitor_tests
  #
  # These were previously duplicated across SaneBar, SaneVideo, and SaneProcess.
  # Now unified here — single source of truth for all projects.
  module CIHelpers
    include ProcessTreeCleanup
    # Temporarily re-enable test targets in project.yml for CI builds.
    # Backs up original file, modifies targets, regenerates Xcode project.
    def enable_ci_tests(_args)
      require 'open3'

      yml_path = File.join(Dir.pwd, 'project.yml')
      backup_path = File.join(Dir.pwd, 'project.yml.ci_backup')

      unless File.exist?(yml_path)
        puts '❌ No project.yml found'
        exit 1
      end

      # Backup original
      unless File.exist?(backup_path)
        FileUtils.cp(yml_path, backup_path)
        puts "📋 Backed up project.yml → #{File.basename(backup_path)}"
      end

      lines = File.readlines(yml_path)
      output = []
      i = 0

      while i < lines.length
        line = lines[i]

        # Re-enable commented-out test dependency: # AppTests: [test] → AppTests: [test]
        if line.match?(/^\s*#\s*#{Regexp.escape(project_name)}Tests:\s*\[test\]/)
          indent = line[/^\s*/]
          output << "#{indent}#{project_name}Tests: [test]\n"
          i += 1
          next
        end

        # Re-enable test scheme targets section
        if line.match?(/^\s+test:/) && i + 1 < lines.length
          output << line
          i += 1

          # Skip comment lines and empty/disabled targets
          while i < lines.length && lines[i].match?(/# Temporarily|# This is a known|# Re-enable|targets: \[\]|# targets:/)
            i += 1
          end

          # Insert actual targets
          output << "      targets:\n"
          output << "        - #{project_name}Tests\n"

          # Check if UI test target exists
          ui_test_dir = File.join(Dir.pwd, "#{project_name}UITests")
          output << "        - #{project_name}UITests\n" if Dir.exist?(ui_test_dir)

          # Skip remaining commented target lines
          while i < lines.length && (lines[i].match?(/^\s*#\s*-\s*#{Regexp.escape(project_name)}/) || lines[i].strip.empty?)
            i += 1
          end
          next
        end

        output << line
        i += 1
      end

      File.write(yml_path, output.join)
      puts "🔧 Test targets enabled for #{project_name}"

      # Regenerate Xcode project
      print '   Regenerating Xcode project... '
      _out, status = Open3.capture2e('xcodegen', 'generate')
      if status.success?
        puts '✅'
      else
        puts '❌ xcodegen failed'
        exit 1
      end

      puts "✅ Ready for CI test execution"
    end

    # Restore original project.yml from CI backup (disable tests again).
    def restore_ci_tests(_args)
      yml_path = File.join(Dir.pwd, 'project.yml')
      backup_path = File.join(Dir.pwd, 'project.yml.ci_backup')

      if File.exist?(backup_path)
        FileUtils.mv(backup_path, yml_path)
        puts '✅ Restored original project.yml from CI backup'
      else
        puts '⚠️  No CI backup found — nothing to restore'
      end
    end

    # Add @testable import to generated mocks file.
    # Run this after mockolo generation to fix missing imports.
    def fix_mocks(_args)
      mocks_path = File.join(Dir.pwd, "#{project_name}Tests", 'Mocks', 'Mocks.swift')

      unless File.exist?(mocks_path)
        # Try alternate paths
        alt_paths = Dir.glob(File.join(Dir.pwd, '*Tests', 'Mocks', 'Mocks.swift'))
        mocks_path = alt_paths.first if alt_paths.any?
      end

      unless mocks_path && File.exist?(mocks_path)
        puts "⚠️  Mocks file not found at #{project_name}Tests/Mocks/Mocks.swift"
        return
      end

      content = File.read(mocks_path)
      import_line = "@testable import #{project_name}"

      if content.include?(import_line)
        puts "ℹ️  @testable import already present in #{File.basename(mocks_path)}"
      else
        # Insert after the last import statement
        lines = content.lines
        last_import_idx = lines.rindex { |l| l.match?(/^import /) }

        if last_import_idx
          lines.insert(last_import_idx + 1, "#{import_line}\n")
          File.write(mocks_path, lines.join)
          puts "✅ Added #{import_line} to #{File.basename(mocks_path)}"
        else
          puts "⚠️  No import statements found in #{File.basename(mocks_path)}"
        end
      end
    end

    # Monitor test execution with live progress and timeout detection.
    # Runs xcodebuild in background, shows progress, kills on timeout.
    def monitor_tests(args)
      begin
        options = monitor_test_options(args, default_scheme: project_scheme)
      rescue ArgumentError => e
        puts "❌ Invalid monitor_tests arguments: #{e.message}"
        puts '   Usage: monitor_tests [--scheme NAME] [--package-path PATH] [--test-plan NAME] [--test SELECTOR] [--timeout POSITIVE_SECONDS]'
        exit 2
      end
      scheme = options.fetch(:scheme)
      package_path = options[:package_path]
      test_plan = options[:test_plan]
      test_name = options[:test_selector]
      timeout = options.fetch(:timeout)
      started_at = Time.now.utc
      started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      plan = monitor_test_plan(
        root: Dir.pwd,
        scheme: scheme,
        package_path: package_path,
        test_plan: test_plan,
        test_selector: test_name,
        started_at: started_at,
        upgrade_run_id: ENV['SANEMASTER_UPGRADE_RUN_ID'],
        upgrade_nonce: ENV['SANEMASTER_UPGRADE_NONCE']
      )
      secure_test_prepare_run_directory!(
        project_root: plan.fetch(:project_root),
        lane: 'monitor-tests',
        run_directory: plan.fetch(:run_directory)
      )
      secure_test_assert_absent!(plan.fetch(:result_bundle_path), plan.fetch(:run_directory))
      secure_test_assert_absent!(plan.fetch(:receipt_path), plan.fetch(:run_directory))

      puts "🔍 Monitoring tests for scheme: #{scheme}"
      puts "   Package: #{package_path}" if package_path
      puts "   Test plan: #{test_plan}" if test_plan
      puts "   Test: #{test_name}" if test_name
      puts "   Timeout: #{timeout}s"
      puts "   Results: #{plan.fetch(:result_bundle_path)}"
      puts ''

      log_file = plan.fetch(:log_path)
      cmd = plan.fetch(:command)

      # Start test in background
      log_io = secure_test_open_new_file(log_file, plan.fetch(:run_directory))
      begin
        pid = Process.spawn(*cmd, chdir: plan.fetch(:working_directory), out: log_io, err: log_io, pgroup: true)
      rescue StandardError => e
        log_io.write("Unable to start xcodebuild: #{e.class}: #{e.message}\n")
        log_io.flush
        receipt_path = write_monitor_test_receipt(
          plan: plan,
          started_at: started_at,
          completed_at: Time.now.utc,
          exit_status: 1,
          timed_out: false,
          error: e.message
        )
        puts "❌ Unable to start tests: #{e.message}"
        puts "   Receipt: #{receipt_path}"
        puts "SANEMASTER_MONITOR_RECEIPT=#{receipt_path}"
        exit 1
      ensure
        log_io.close unless log_io.closed?
      end

      timed_out = false
      termination_error = nil
      tracked_descendants = []
      root_identity = monitor_test_owned_process_identity(pid)
      tracked_identities = {}

      begin
        loop do
          tracked_descendants.concat(monitor_test_descendant_pids(pid)).uniq!
          monitor_test_track_descendant_identities(root_identity, tracked_identities)
        # Check if process is still running
          begin
            Process.getpgid(pid)
          rescue Errno::ESRCH
            break # Process finished
          end

          elapsed = monitor_test_elapsed_seconds(started_monotonic)

          if elapsed > timeout
            puts "⏱️  TIMEOUT: Test exceeded #{timeout}s, killing..."
            timed_out = true
            begin
              terminate_monitor_test_process_group(
                pid,
                root_identity: root_identity,
                tracked_identities: tracked_identities,
                tracked_descendants: tracked_descendants
              )
            rescue StandardError => e
              termination_error = e.message
              puts "❌ #{termination_error}"
            end
            break
          end

        # Show progress every 10 seconds
          if (elapsed % 10).zero? && elapsed > 0
            puts "⏱️  Elapsed: #{elapsed}s / #{timeout}s"
            monitor_test_log_lines(log_file, limit: 3).each { |line| puts "   #{line}" }
          end

          sleep 1
        end

      # Wait for process
      waited = begin
        if termination_error
          Process.wait2(pid, Process::WNOHANG)
        else
          Process.wait2(pid)
        end
      rescue Errno::ECHILD
        nil
      end
      _pid, status = waited || [nil, nil]
      exit_status = timed_out ? 124 : (status&.exitstatus || 1)
      receipt_path = write_monitor_test_receipt(
        plan: plan,
        started_at: started_at,
        completed_at: Time.now.utc,
        exit_status: exit_status,
        timed_out: timed_out,
        termination_signal: status&.termsig,
        error: termination_error
      )
      receipt = JSON.parse(secure_test_read_file(receipt_path, plan.fetch(:run_directory)))

      puts ''
      puts '📊 Test Results:'
      puts "   Receipt: #{receipt_path}"
      puts "SANEMASTER_MONITOR_RECEIPT=#{receipt_path}"

        if timed_out
        puts "❌ Test timed out after #{timeout}s"
        exit 124
      elsif receipt['status'] == 'passed'
        puts '✅ Tests passed'
        puts "   Verified passed tests: #{receipt['matched_test_count']} / #{receipt['passed_test_count']}"
        monitor_test_log_lines(log_file, pattern: /(Test Case|PASSED)/, limit: 20).each do |line|
          puts "   #{line}"
        end
        else
        puts "❌ Tests failed verification: #{receipt['error']}"
        puts "   Inspect: #{log_file}"
        monitor_test_log_lines(log_file, pattern: /(Test Case|FAILED|error:)/, limit: 30).each do |line|
          puts "   #{line}"
        end
          exit(exit_status.zero? ? 1 : exit_status)
        end
      ensure
        active_error = $!
        begin
          terminate_monitor_test_process_group(
            pid,
            root_identity: root_identity,
            tracked_identities: tracked_identities,
            tracked_descendants: tracked_descendants
          )
        rescue StandardError => cleanup_error
          if active_error
            warn "❌ Monitor cleanup also failed: #{cleanup_error.message}"
          else
            raise cleanup_error
          end
        end
      end
    end

    def monitor_test_elapsed_seconds(started_monotonic, now_monotonic: Process.clock_gettime(Process::CLOCK_MONOTONIC))
      now_monotonic - started_monotonic
    end

    # Extract image info and base64 for analysis.
    # Previously duplicated as extract_image_info.rb in 3 locations.
    def image_info(args)
      require 'base64'

      image_path = args.first
      unless image_path
        puts "Usage: SaneMaster.rb image_info <image_path>"
        exit 1
      end

      unless File.exist?(image_path)
        puts "❌ File not found: #{image_path}"
        exit 1
      end

      file_size = File.size(image_path)
      file_name = File.basename(image_path)
      mtime = File.mtime(image_path)

      image_data = File.binread(image_path)
      base64_data = Base64.strict_encode64(image_data)

      output = {
        file_path: image_path,
        file_name: file_name,
        file_size: file_size,
        modified_time: mtime.iso8601,
        base64_length: base64_data.length,
        base64_preview: "#{base64_data[0..100]}..."
      }

      puts JSON.pretty_generate(output)
    end

    private

    def secure_test_prepare_run_directory!(project_root:, lane:, run_directory:)
      root = File.realpath(project_root)
      outputs = File.join(root, 'outputs')
      lane_directory = File.join(outputs, lane)
      expected_parent = lane_directory
      raise "Unsafe test output lane #{lane.inspect}" unless lane.match?(/\A[A-Za-z0-9._-]+\z/)
      raise "Test run escaped #{lane_directory}" unless File.expand_path(File.dirname(run_directory)) == lane_directory

      [outputs, lane_directory, run_directory].each do |directory|
        begin
          metadata = File.lstat(directory)
          raise "Unsafe symlink in test output path: #{directory}" if metadata.symlink?
          raise "Test output component is not a directory: #{directory}" unless metadata.directory?
        rescue Errno::ENOENT
          Dir.mkdir(directory, 0o700)
        end
      end
      real_run = File.realpath(run_directory)
      real_lane = File.realpath(expected_parent)
      unless real_run.start_with?("#{real_lane}#{File::SEPARATOR}")
        raise "Test run escaped output lane: #{real_run}"
      end
      real_run
    end

    def secure_test_assert_absent!(path, run_directory)
      secure_test_assert_lexical_containment!(path, run_directory)
      File.lstat(path)
      raise "Refusing existing test artifact: #{path}"
    rescue Errno::ENOENT
      true
    end

    def secure_test_path_exists?(path)
      File.lstat(path)
      true
    rescue Errno::ENOENT
      false
    end

    def secure_test_assert_lexical_containment!(path, run_directory)
      expected = File.realpath(run_directory)
      expanded = File.expand_path(path)
      actual_parent = File.realpath(File.dirname(expanded))
      unless actual_parent == expected
        raise "Test artifact escaped run directory: #{path}"
      end
      metadata = File.lstat(run_directory)
      raise "Unsafe symlink test run directory: #{run_directory}" if metadata.symlink?
      true
    end

    def secure_test_open_new_file(path, run_directory)
      secure_test_assert_absent!(path, run_directory)
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags, 0o600)
    end

    def secure_test_read_file(path, run_directory, max_bytes: nil)
      secure_test_existing_artifact!(path, run_directory)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) { |file| max_bytes ? file.read(max_bytes) : file.read }
    end

    def secure_test_existing_artifact!(path, run_directory, directory: false)
      secure_test_assert_lexical_containment!(path, run_directory)
      metadata = File.lstat(path)
      raise "Unsafe symlink test artifact: #{path}" if metadata.symlink?
      expected_type = directory ? metadata.directory? : metadata.file?
      raise "Unexpected test artifact type: #{path}" unless expected_type
      real_run = File.realpath(run_directory)
      real_path = File.realpath(path)
      unless real_path.start_with?("#{real_run}#{File::SEPARATOR}")
        raise "Test artifact escaped run directory: #{path}"
      end
      true
    end

    def monitor_test_options(args, default_scheme:)
      values = {}
      remaining = args.dup
      until remaining.empty?
        argument = remaining.shift
        match = argument.match(/\A--(scheme|package-path|test-plan|test|timeout)=(.*)\z/)
        if match
          key = match[1]
          value = match[2]
        elsif %w[--scheme --package-path --test-plan --test --timeout].include?(argument)
          key = argument.delete_prefix('--')
          value = remaining.shift
          raise ArgumentError, "#{argument} requires a value" if value.nil? || value.start_with?('--')
        else
          raise ArgumentError, "unknown argument #{argument.inspect}; positional arguments are not supported"
        end

        raise ArgumentError, "--#{key} requires a value" if value.empty?
        symbol = case key
                 when 'test' then :test_selector
                 when 'package-path' then :package_path
                 when 'test-plan' then :test_plan
                 else key.to_sym
                 end
        raise ArgumentError, "--#{key} was provided more than once" if values.key?(symbol)

        values[symbol] = value
      end

      timeout_text = values.fetch(:timeout, '300')
      unless timeout_text.match?(/\A[1-9]\d*\z/)
        raise ArgumentError, '--timeout must be a positive integer'
      end

      scheme = values.fetch(:scheme, default_scheme).to_s
      raise ArgumentError, '--scheme is required when the current project has no scheme' if scheme.empty?

      {
        scheme: scheme,
        package_path: values[:package_path],
        test_plan: values[:test_plan],
        test_selector: values[:test_selector],
        timeout: timeout_text.to_i
      }
    end

    def monitor_test_plan(root:, scheme:, package_path: nil, test_plan: nil, test_selector:, started_at:, pid: Process.pid, nonce: SecureRandom.hex(4),
                          upgrade_run_id: nil, upgrade_nonce: nil)
      project_root = File.realpath(root)
      upgrade_run_id = upgrade_run_id.to_s.strip
      upgrade_nonce = upgrade_nonce.to_s.strip
      if upgrade_run_id.empty? != upgrade_nonce.empty?
        raise ArgumentError, 'upgrade monitor binding requires both run ID and nonce'
      end
      unless upgrade_run_id.empty?
        raise ArgumentError, 'upgrade monitor run ID is malformed' unless upgrade_run_id.match?(/\A\d{8}T\d{6}-[0-9a-f]{24}\z/)
        raise ArgumentError, 'upgrade monitor nonce is malformed' unless upgrade_nonce.match?(/\A[0-9a-f]{64}\z/)
      end
      run_id = "#{started_at.utc.strftime('%Y%m%dT%H%M%S.%6NZ')}-#{pid}-#{nonce}"
      unless upgrade_run_id.empty?
        binding = Digest::SHA256.hexdigest("#{upgrade_run_id}\0#{upgrade_nonce}")[0, 16]
        run_id = "#{run_id}-upgrade-#{binding}"
      end
      run_directory = File.join(project_root, 'outputs', 'monitor-tests', run_id)
      result_bundle_path = File.join(run_directory, 'test.xcresult')
      working_directory = monitor_test_working_directory(project_root, package_path)
      command = [
        'xcodebuild', 'test', '-scheme', scheme,
        '-destination', 'platform=macOS,arch=arm64',
        '-resultBundlePath', result_bundle_path
      ]
      if test_plan || package_path
        # Xcode cannot apply -only-testing to Swift Testing package targets.
        # Run the requested scope, then require the exact selector in xcresult.
        command += ['-testPlan', test_plan] if test_plan
      else
        command += ['-only-testing', test_selector] if test_selector
      end

      {
        project_root: project_root,
        working_directory: working_directory,
        run_directory: run_directory,
        result_bundle_path: result_bundle_path,
        xcresult_path: result_bundle_path,
        log_path: File.join(run_directory, 'xcodebuild.log'),
        receipt_path: File.join(run_directory, 'receipt.json'),
        command: command,
        run_id: run_id,
        scheme: scheme,
        package_path: package_path,
        test_plan: test_plan,
        test_selector: test_selector,
        upgrade_run_id: upgrade_run_id.empty? ? nil : upgrade_run_id,
        upgrade_nonce: upgrade_nonce.empty? ? nil : upgrade_nonce
      }
    end

    def monitor_test_working_directory(project_root, package_path)
      return project_root if package_path.nil?

      candidate = File.expand_path(package_path, project_root)
      raise ArgumentError, '--package-path must stay within the project root' unless candidate.start_with?("#{project_root}#{File::SEPARATOR}")
      raise ArgumentError, '--package-path must be an existing directory' unless File.directory?(candidate)

      resolved = File.realpath(candidate)
      raise ArgumentError, '--package-path must not resolve outside the project root' unless resolved.start_with?("#{project_root}#{File::SEPARATOR}")

      resolved
    end

    def build_monitor_test_receipt(plan:, started_at:, completed_at:, exit_status:, timed_out:,
                                   termination_signal: nil, error: nil, host: Socket.gethostname,
                                   result_summary: nil)
      result_bundle_path = plan.fetch(:result_bundle_path)
      artifact_error = nil
      begin
        secure_test_existing_artifact!(plan.fetch(:log_path), plan.fetch(:run_directory))
        secure_test_existing_artifact!(result_bundle_path, plan.fetch(:run_directory), directory: true) if secure_test_path_exists?(result_bundle_path)
        result_bundle_exists = File.directory?(result_bundle_path)
        info_plist = File.join(result_bundle_path, 'Info.plist')
        if result_bundle_exists && secure_test_path_exists?(info_plist)
          info_metadata = File.lstat(info_plist)
          raise "Unsafe symlink test artifact: #{info_plist}" if info_metadata.symlink?
        end
        result_bundle_valid = result_bundle_exists && File.file?(info_plist)
      rescue StandardError => e
        artifact_error = e.message
        result_bundle_exists = secure_test_path_exists?(result_bundle_path)
        result_bundle_valid = false
      end
      result_summary ||= if exit_status.zero? && !timed_out && result_bundle_valid
                           monitor_test_result_summary(result_bundle_path, plan[:test_selector])
                         else
                           monitor_test_empty_result_summary
                         end
      passed = exit_status.zero? && !timed_out && result_bundle_valid && result_summary[:ok]
      error ||= artifact_error
      error ||= monitor_test_receipt_error(
        exit_status: exit_status,
        timed_out: timed_out,
        result_bundle_exists: result_bundle_exists,
        result_bundle_valid: result_bundle_valid,
        result_summary: result_summary
      ) unless passed

      {
        source: 'SaneMaster.monitor_tests',
        status: passed ? 'passed' : 'failed',
        run_id: plan.fetch(:run_id),
        upgrade_run_id: plan[:upgrade_run_id],
        upgrade_nonce: plan[:upgrade_nonce],
        host: host,
        scheme: plan.fetch(:scheme),
        package_path: plan[:package_path],
        test_plan: plan[:test_plan],
        test_selector: plan[:test_selector],
        started_at: started_at.utc.iso8601(6),
        completed_at: completed_at.utc.iso8601(6),
        result_bundle_path: result_bundle_path,
        result_bundle_exists: result_bundle_exists,
        result_bundle_valid: result_bundle_valid,
        xcresult_verified: result_summary[:ok],
        discovered_test_count: result_summary[:discovered_test_count],
        passed_test_count: result_summary[:passed_test_count],
        matched_test_count: result_summary[:matched_test_count],
        xcresult_path: result_bundle_path,
        xcresult_exists: result_bundle_exists,
        command: plan.fetch(:command),
        exit_status: exit_status,
        timed_out: timed_out,
        termination_signal: termination_signal,
        log_path: plan.fetch(:log_path),
        error: error
      }
    end

    def write_monitor_test_receipt(**attributes)
      plan = attributes.fetch(:plan)
      receipt_path = plan.fetch(:receipt_path)
      temporary_path = "#{receipt_path}.tmp-#{Process.pid}"
      receipt = build_monitor_test_receipt(**attributes)
      temporary_file = secure_test_open_new_file(temporary_path, plan.fetch(:run_directory))
      temporary_file.write("#{JSON.pretty_generate(receipt)}\n")
      temporary_file.flush
      temporary_file.fsync
      temporary_file.close
      secure_test_assert_absent!(receipt_path, plan.fetch(:run_directory))
      File.rename(temporary_path, receipt_path)
      secure_test_existing_artifact!(receipt_path, plan.fetch(:run_directory))
      receipt_path
    ensure
      temporary_file.close if temporary_file && !temporary_file.closed?
      FileUtils.rm_f(temporary_path) if temporary_path && File.exist?(temporary_path)
    end

    MONITOR_TEST_LOG_TAIL_BYTES = 256 * 1024

    def monitor_test_log_lines(path, pattern: nil, limit:, max_bytes: MONITOR_TEST_LOG_TAIL_BYTES)
      secure_test_existing_artifact!(path, File.dirname(path))
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      data = File.open(path, flags) do |file|
        start_offset = [file.size - max_bytes, 0].max
        file.seek(start_offset)
        chunk = file.read(max_bytes).to_s
        chunk = chunk.sub(/\A[^\n]*\n/, '') if start_offset.positive?
        chunk
      end
      lines = data.force_encoding(Encoding::UTF_8).scrub.lines(chomp: true)
      lines = lines.grep(pattern) if pattern
      lines.last(limit)
    rescue Errno::ENOENT
      []
    end

    def monitor_test_receipt_error(exit_status:, timed_out:, result_bundle_exists:, result_bundle_valid:,
                                   result_summary:)
      return 'Test run timed out before producing a trustworthy result bundle' if timed_out
      return "xcodebuild exited with status #{exit_status}" unless exit_status.zero?
      return 'Result bundle was not created as a directory' unless result_bundle_exists
      return 'Result bundle is missing Info.plist' unless result_bundle_valid
      return result_summary[:error] unless result_summary[:ok]

      'Test run did not produce trustworthy evidence'
    end

    def monitor_test_empty_result_summary(error = 'Result bundle test results were not inspected')
      {
        ok: false,
        discovered_test_count: 0,
        passed_test_count: 0,
        matched_test_count: 0,
        error: error
      }
    end

    def monitor_test_result_summary(result_bundle_path, test_selector)
      output, status = Open3.capture2e(
        'xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', result_bundle_path
      )
      unless status.success?
        return monitor_test_empty_result_summary("xcresulttool could not inspect test results: #{output.to_s.lines.last.to_s.strip}")
      end

      monitor_test_result_summary_from_data(JSON.parse(output), test_selector)
    rescue JSON::ParserError => e
      monitor_test_empty_result_summary("xcresulttool returned invalid JSON: #{e.message}")
    rescue StandardError => e
      monitor_test_empty_result_summary("Could not inspect xcresult test results: #{e.class}: #{e.message}")
    end

    def monitor_test_result_summary_from_data(data, test_selector)
      nodes = monitor_test_deduplicated_result_nodes(monitor_test_result_nodes(data))
      passed_nodes = nodes.select { |node| node[:result].casecmp('passed').zero? }
      matched_nodes = if test_selector.to_s.empty?
                        passed_nodes
                      else
                        passed_nodes.select do |node|
                          monitor_test_identifier_matches_selector?(
                            node[:identifier],
                            test_selector,
                            bundle: node[:bundle]
                          )
                        end
                      end
      error = if nodes.empty?
                'xcresult contains zero test result nodes'
              elsif passed_nodes.empty?
                'xcresult contains no passed tests'
              elsif matched_nodes.empty?
                "xcresult does not contain a passed test matching #{test_selector.inspect}"
              end
      {
        ok: error.nil?,
        discovered_test_count: nodes.length,
        passed_test_count: passed_nodes.length,
        matched_test_count: matched_nodes.length,
        error: error
      }
    end

    def monitor_test_result_nodes(value, found = [], bundle = nil)
      if value.is_a?(Hash)
        node_type = value['nodeType'].to_s
        identifier = value['nodeIdentifier'] || value['testIdentifier'] || value['name']
        result = value['result']
        # xcresulttool does not always target-prefix test identifiers (current
        # Xcode emits bare "Suite/testName()"), so remember the enclosing test
        # bundle: it is the only reliable carrier of the target name.
        bundle = identifier.to_s.sub(/\.xctest\z/, '') if node_type.end_with?('test bundle')
        if ['Test Case', 'Test Case Run'].include?(node_type) && result
          found << { identifier: identifier.to_s, result: result.to_s, node_type: node_type, bundle: bundle }
        end
        value.each_value { |child| monitor_test_result_nodes(child, found, bundle) }
      elsif value.is_a?(Array)
        value.each { |child| monitor_test_result_nodes(child, found, bundle) }
      end
      found
    end

    def monitor_test_deduplicated_result_nodes(nodes)
      nodes.each_with_object({}) do |node, unique|
        key = node[:identifier].to_s.sub(/\(\)\z/, '')
        existing = unique[key]
        unique[key] = node if existing.nil? || (node[:node_type] == 'Test Case Run' && existing[:node_type] != 'Test Case Run')
      end.values
    end

    def monitor_test_identifier_matches_selector?(identifier, selector, bundle: nil)
      actual = identifier.to_s.sub(/\(\)\z/, '')
      expected = selector.to_s.sub(/\(\)\z/, '')
      normalized = expected.sub(%r{\A([^/]+)/}, '\\1.')
      return true if actual == expected || actual == normalized ||
                     actual.start_with?("#{expected}/") || actual.start_with?("#{normalized}/")

      # Current xcresulttool emits bare "Suite/testName()" identifiers with the
      # target name only on the enclosing bundle node. A bare-target selector
      # matches any test inside that bundle; a "Target/Suite/..." selector
      # matches when the bundle owns the target and the remainder matches the
      # bare identifier (regression 2026-07-14: SaneHosts evidence was rejected
      # everywhere despite every test passing).
      bundle_name = bundle.to_s
      return false if bundle_name.empty?
      return true if expected == bundle_name
      return false unless expected.start_with?("#{bundle_name}/")

      remainder = expected.delete_prefix("#{bundle_name}/")
      actual == remainder || actual.start_with?("#{remainder}/")
    end

  end
end
