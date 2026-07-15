# frozen_string_literal: true

module SaneMasterModules
  # Doctor environment checks and UI-identifier scanning helpers
  # (split from verify.rb for Rule #10).
  module Verify
    private

    def check_disk_space
      puts "\n💾 Disk Space:"
      disk_info = `df -h . 2>/dev/null`.lines.last&.split || []
      return unless disk_info.length >= 4

      available = disk_info[3]
      puts "  ✅ Available: #{available}"
      puts '  ⚠️  Low disk space! Export/build may fail' if available.include?('G') && available.to_f < 10
    end

    def check_test_assets
      puts "\n📦 Test Assets:"
      assets_dir = 'Tests/Assets'
      test_asset_name = ENV['TEST_ASSET_NAME'] || 'test_video.mp4'
      test_video = File.join(assets_dir, test_asset_name)
      max_asset_mb = (ENV['SANEMASTER_MAX_TEST_ASSET_MB'] || '200').to_i
      max_assets_dir_mb = (ENV['SANEMASTER_MAX_TEST_ASSETS_DIR_MB'] || '500').to_i

      if File.exist?(test_video)
        size = File.size(test_video) / 1024 / 1024.0
        size_str = size >= 1 ? "#{size.round(1)}MB" : "#{(size * 1024).round}KB"
        puts "  ✅ #{test_asset_name} exists (#{size_str})"
      else
        puts "  ⚠️  #{test_asset_name} missing"
        puts '     Run: ./scripts/SaneMaster.rb gen_assets'
      end

      return unless Dir.exist?(assets_dir)

      total_bytes = 0
      oversized = []
      Dir.glob(File.join(assets_dir, '*')).each do |asset_path|
        next unless File.file?(asset_path)

        bytes = File.size(asset_path)
        total_bytes += bytes
        oversized << [asset_path, bytes] if bytes > (max_asset_mb * 1024 * 1024)
      end

      total_mb = total_bytes / 1024.0 / 1024.0
      if total_mb > max_assets_dir_mb || oversized.any?
        puts "  ⚠️  Assets directory is large (#{total_mb.round(1)}MB)."
        oversized.sort_by { |(_, bytes)| -bytes }.first(5).each do |(path, bytes)|
          puts "     - #{File.basename(path)}: #{(bytes / 1024.0 / 1024.0).round(1)}MB"
        end
        puts "     Keep test media lightweight. Regenerate with: ./scripts/SaneMaster.rb gen_assets"
      end
    end

    def check_xcodegen_sync
      puts "\n📁 XcodeGen Sync:"
      unless project_xcodeproj && !project_xcodeproj.to_s.empty?
        puts '  ℹ️  No Xcode project for this repo. Skipping XcodeGen sync check.'
        return
      end

      project_path = File.join(project_xcodeproj, 'project.pbxproj')
      unless File.exist?(project_path)
        puts '  ❌ Project file missing. Run: xcodegen generate'
        return
      end

      puts '  ✅ Project file exists'
      begin
        require 'xcodeproj'
        project = Xcodeproj::Project.open(project_xcodeproj)
        project_swift_count = project.files.count { |f| f.path&.end_with?('.swift') }
        disk_swift_count = `find . -name "*.swift" -not -path "*/.*" -not -path "*/build/*" -not -path "*/vendor/*" | wc -l`.strip.to_i
        if (project_swift_count - disk_swift_count).abs > 15
          puts "  ⚠️  File count mismatch (project: #{project_swift_count}, disk: ~#{disk_swift_count})"
          puts '     Run: xcodegen generate'
        else
          puts "  ✅ Project appears in sync (#{project_swift_count} Swift files)"
        end
      rescue LoadError
        puts '  ⚠️  Skipping sync check (run with: bundle exec ./scripts/SaneMaster.rb doctor)'
      rescue StandardError => e
        puts "  ⚠️  Could not verify sync: #{e.message}"
      end
    end

    def check_permissions
      puts "\n🔐 Permissions:"
      check_permission_status
    end

    def check_mockolo
      puts "\n🎭 Mock Generation:"
      if system('which mockolo > /dev/null 2>&1')
        version = `mockolo --version 2>&1`.strip
        puts "  ✅ Mockolo installed (#{version})"
      else
        puts '  ⚠️  Mockolo not found. Install: brew install mockolo'
      end
    end

    def check_xcode
      puts "\n🛠️  Xcode:"
      xcode_version = `xcodebuild -version 2>&1`.strip
      if xcode_version.include?('Xcode')
        puts "  ✅ #{xcode_version}"
      else
        puts '  ❌ Xcode not found'
      end
    end

    def check_code_quality_tools
      puts "\n🎨 Code Quality Tools:"
      if system('which swiftlint > /dev/null 2>&1')
        version = `swiftlint version 2>&1`.strip
        puts "  ✅ SwiftLint #{version}"
      else
        puts '  ⚠️  SwiftLint not found. Install: brew install swiftlint'
      end
    end

    def check_stuck_processes
      puts "\n🔄 Stuck Processes:"
      stuck = `pgrep -f 'xcodebuild|xctest' 2>/dev/null`.strip
      stuck_pids = stuck.split.reject do |pid|
        # Get full command to check what this process actually is
        cmd = `ps -p #{pid} -o command= 2>/dev/null`.strip
        # Exclude: system processes, MCP servers, and npm processes
        cmd.include?('testmanagerd') ||
          cmd.include?('/usr/libexec/') ||
          cmd.include?('mcp') ||
          cmd.include?('npm exec')
      end
      if stuck_pids.empty?
        puts '  ✅ No stuck test processes'
      else
        puts "  ⚠️  Found stuck processes: #{stuck_pids.join(', ')}"
        puts '     Run: killall -9 xcodebuild xctest'
      end
    end

    def check_derived_data
      puts "\n📁 DerivedData:"
      dd_path = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*")
      dd_dirs = Dir.glob(dd_path)
      if dd_dirs.any?
        total_size = dd_dirs.map { |d| `du -sh "#{d}" 2>/dev/null`.split.first }.join(', ')
        puts "  📦 Size: #{total_size}"
        puts '     Clean with: ./scripts/SaneMaster.rb clean --nuclear'
      else
        puts '  ✅ No DerivedData cache'
      end
    end

    def scan_for_missing_identifiers(swift_files)
      missing_count = 0
      ui_components = %w[Button TextField Toggle Slider Picker]

      swift_files.uniq.each do |path|
        next unless File.exist?(path)

        content = File.read(path)
        ui_components.each do |component|
          last_pos = 0
          while (start_idx = content.index(/\b#{component}\s*\(/, last_pos))
            context = content[start_idx..(start_idx + 3000)] || ''
            unless context.include?('accessibilityIdentifier')
              puts "  ⚠️  Potential missing ID: #{component} in #{File.basename(path)} (near line #{content[0..start_idx].count("\n") + 1})"
              missing_count += 1
            end
            last_pos = start_idx + 1
          end
        end
      end

      missing_count
    end

    def extract_ui_identifiers
      identifiers = Set.new

      identifiers_file = File.join(project_app_dir, 'Core/Testing/AccessibilityIdentifiers.swift')
      if File.exist?(identifiers_file)
        content = File.read(identifiers_file)
        content.scan(/static let \w+ = ["']([^"']+)["']/) { |match| identifiers << match[0] }
      end

      Dir.glob(File.join(Dir.pwd, '**/*.swift')).each do |file|
        next if file.include?('/Tests/') ||
                file.include?('/UITests/') ||
                file.include?('/Mocks/') ||
                file.include?('/.build/') ||
                file.include?('/DerivedData/') ||
                file.include?('/docs/') ||
                file.include?('AccessibilityIdentifiers.swift')
        next unless File.exist?(file)

        content = File.read(file)
        content.scan(/\.accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
        content.scan(/accessibilityIdentifier\(["']([^"']+)["']\)/) { |match| identifiers << match[0] }
        # Labeled component arguments forward identifiers into shared views —
        # accessibilityID:, cancelID:, actionID:, bare id:, ...Identifier: —
        # these are declarations too (2026-07-15 SaneVideo pre-push false
        # failures). Value must be identifier-shaped (dotted/dashed lowercase,
        # same shape looks_like_custom_ui_identifier? accepts) so data-model
        # ids like id: "UUID-1234" are not swallowed.
        content.scan(/\b\w*[Ii][Dd](?:entifier)?\s*:\s*["']([a-z0-9]+(?:[._-][A-Za-z0-9]+)+)["']/) do |match|
          identifiers << match[0]
        end
      end

      identifiers.to_a
    end

    def extract_test_references
      return Set.new.to_a unless ui_tests_present?

      identifiers = Set.new
      Dir.glob(File.join(project_ui_tests_dir, '**/*.swift')).each do |file|
        next unless File.exist?(file)

        content = File.read(file)
        content.scan(/accessibilityIdentifier\(["']([^"']+)["']\)/) do |match|
          value = match[0]
          identifiers << value if looks_like_custom_ui_identifier?(value)
        end
        content.scan(/\bapp\.(?!launchEnvironment\b)(?!launchArguments\b)\w+(?:\.\w+)*\s*\[\s*["']([^"']+)["']\s*\]/) do |match|
          value = match[0]
          identifiers << value if looks_like_custom_ui_identifier?(value)
        end
      end

      identifiers.to_a
    end

    def looks_like_custom_ui_identifier?(value)
      value.match?(/\A[a-z0-9]+(?:[._-][A-Za-z0-9]+)+\z/)
    end

    def find_references_in_files(identifier)
      return [] unless ui_tests_present?

      files = []
      Dir.glob(File.join(project_ui_tests_dir, '**/*.swift')).each do |file|
        next unless File.exist?(file)
        next unless File.read(file).include?(identifier)

        files << file
      end
      files
    end

    def ui_tests_present?
      Dir.exist?(project_ui_tests_dir)
    end

    def runtime_smoke_coverage_present?
      File.exist?(File.join(Dir.pwd, 'Scripts', 'live_zone_smoke.rb')) &&
        File.exist?(File.join(Dir.pwd, 'Tests', 'RuntimeGuardXCTests.swift'))
    end
  end
end
