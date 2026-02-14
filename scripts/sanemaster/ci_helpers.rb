# frozen_string_literal: true

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
      require 'open3'

      scheme = args.shift || project_scheme
      test_name = args.shift
      timeout = (args.shift || '300').to_i

      puts "🔍 Monitoring tests for scheme: #{scheme}"
      puts "   Test: #{test_name}" if test_name
      puts "   Timeout: #{timeout}s"
      puts ''

      log_file = '/tmp/sanemaster_test_output.log'

      # Build xcodebuild command
      cmd = ['xcodebuild', 'test', '-scheme', scheme, '-destination', 'platform=macOS,arch=arm64']
      cmd += ['-only-testing', test_name] if test_name

      # Start test in background
      pid = Process.spawn(*cmd, out: log_file, err: log_file)

      start_time = Time.now
      timed_out = false

      loop do
        # Check if process is still running
        begin
          Process.getpgid(pid)
        rescue Errno::ESRCH
          break # Process finished
        end

        elapsed = (Time.now - start_time).to_i

        if elapsed > timeout
          puts "⏱️  TIMEOUT: Test exceeded #{timeout}s, killing..."
          Process.kill('KILL', pid) rescue nil
          timed_out = true
          break
        end

        # Show progress every 10 seconds
        if (elapsed % 10).zero? && elapsed > 0
          puts "⏱️  Elapsed: #{elapsed}s / #{timeout}s"
          # Show last few lines
          recent = `tail -3 #{log_file} 2>/dev/null`.strip
          recent.lines.each { |l| puts "   #{l}" } unless recent.empty?
        end

        sleep 1
      end

      # Wait for process
      _pid, status = Process.wait2(pid) rescue [nil, nil]

      puts ''
      puts '📊 Test Results:'

      if timed_out
        puts "❌ Test timed out after #{timeout}s"
        exit 124
      elsif status&.success?
        puts '✅ Tests passed'
        results = `grep -E "(Test Case|PASSED)" #{log_file} 2>/dev/null`.strip
        results.lines.last(20).each { |l| puts "   #{l}" } unless results.empty?
      else
        code = status&.exitstatus || 1
        puts "❌ Tests failed (exit code: #{code})"
        results = `grep -E "(Test Case|FAILED|error:)" #{log_file} 2>/dev/null`.strip
        results.lines.last(30).each { |l| puts "   #{l}" } unless results.empty?
        exit code
      end
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
  end
end
