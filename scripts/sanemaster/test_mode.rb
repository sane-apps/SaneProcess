# frozen_string_literal: true

module SaneMasterModules
  # Interactive debugging workflow, app launching, logs
  module TestMode
    require 'fileutils'
    require 'tmpdir'

    # Detect project name from current directory (context-specific)
    def project_name
      @project_name ||= File.basename(Dir.pwd)
    end

    def launch_app(args)
      puts '🚀 --- [ SANEMASTER LAUNCH ] ---'

      build_config = launch_build_config(args)
      puts "🔧 Build configuration: #{build_config}"
      app_candidates = built_app_candidates(build_config)
      app_path = app_candidates.find { |candidate| app_bundle_executable?(candidate) } || app_candidates.first

      unless app_path && File.exist?(app_path)
        puts "❌ App binary not found for configuration '#{build_config}'. Run build first."
        return false
      end

      unless app_bundle_executable?(app_path)
        puts "❌ App bundle missing executable: #{app_path}"
        executable = app_bundle_executable_path(app_path)
        puts "   Expected executable: #{executable}"
        puts '   Tip: run build again to refresh DerivedData output.'
        return false
      end

      # STALE BUILD DETECTION - prevents launching outdated binaries
      binary_time = File.mtime(app_bundle_executable_path(app_path))
      source_files = project_swift_sources
      newest_source = source_files.max_by { |f| File.mtime(f) }

      if newest_source && File.mtime(newest_source) > binary_time
        age_seconds = (Time.now - binary_time).to_i
        age_str = age_seconds > 3600 ? "#{age_seconds / 3600}h ago" : "#{age_seconds / 60}m ago"
        stale_file = File.basename(newest_source)

        puts ''
        puts '⚠️  STALE BUILD DETECTED!'
        puts "   Binary built: #{age_str}"
        puts "   Source newer: #{stale_file} (#{File.mtime(newest_source).strftime('%H:%M:%S')})"
        puts ''

        if args.include?('--force')
          puts '   --force flag set, launching anyway...'
        else
          puts '   Rebuilding to ensure fresh binary...'
          unless run_build_command(build_config: build_config)
            puts '   ❌ Rebuild failed!'
            return
          end
          puts '   ✅ Rebuilt successfully'
          # Refresh app_path after rebuild
          refreshed_candidates = built_app_candidates(build_config)
          app_path = refreshed_candidates.find { |candidate| app_bundle_executable?(candidate) } || refreshed_candidates.first
          unless app_path && app_bundle_executable?(app_path)
            puts '   ❌ Rebuild produced an app bundle without executable.'
            return false
          end
        end
        puts ''
      end

      launch_path = stage_to_canonical_local_app_path(app_path)
      reconcile_accessibility_trust_local(launch_path)

      puts "📱 Launching: #{launch_path}"
      capture_logs = args.include?('--logs')
      env_vars = {}
      env_vars['VERIFY_PIP'] = ENV['VERIFY_PIP'] if ENV['VERIFY_PIP']
      ensure_single_instance

      if capture_logs
        puts '📝 Capturing logs to stdout...'
        pid = spawn(env_vars, File.join(launch_path, 'Contents', 'MacOS', project_name))
        Process.wait(pid)
      else
        opened = system(env_vars, 'open', launch_path)
        unless opened
          puts '❌ Failed to launch app via open. Verify staged app bundle/executable exists.'
          return false
        end
        puts '✅ App launched (fresh build verified)'
      end

      true
    end

    def restore_xcode
      puts '🛠️ --- [ SANEMASTER RESTORE ] ---'
      puts 'Fixing common Xcode/Launch Services issues...'

      lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
      if File.exist?(lsregister)
        print '  Resetting Launch Services database... '
      system(lsregister, '-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user')
        puts '✅'
      end

      print '  Restarting Dock... '
      system('killall', 'Dock')
      puts '✅'

      clean(['--nuclear'])
      puts "\n✅ System restored. Try opening the project in Xcode again."
    end

    def setup_environment
      puts '🛠️ --- [ SANEMASTER SETUP ] ---'

      print '📦 Running bundle install... '
      if system('bundle install --path vendor/bundle > /dev/null 2>&1')
        puts '✅'
      else
        puts '⚠️  Bundle install failed or not needed'
      end

      print '🔍 Checking SwiftFormat... '
      puts system('which swiftformat > /dev/null 2>&1') ? '✅' : '⚠️  Not found (brew install swiftformat)'

      print '🔍 Checking SwiftLint... '
      puts system('which swiftlint > /dev/null 2>&1') ? '✅' : '⚠️  Not found (brew install swiftlint)'

      puts "\n✅ Setup complete."
    end

    def enter_test_mode(_args)
      puts '🧪 --- [ TEST MODE ] ---'
      puts 'Preparing clean testing environment...'
      puts ''

      screenshots_dir = File.join(Dir.pwd, 'Screenshots')
      crash_dir = File.expand_path('~/Library/Logs/DiagnosticReports')

      kill_existing_processes
      show_screenshots(screenshots_dir)
      show_diagnostic_reports(crash_dir)
      return unless build_app

      return unless launch_app([])
      sleep 2
      print_test_mode_ready

      # Stream logs in background - non-sandboxed app uses unified logging
      puts '📡 Streaming live logs in background...'
      puts '   (Non-sandboxed app - using unified logging)'
      puts '─' * 60
      spawn('log', 'stream', '--predicate', "process == \"#{project_name}\"", '--style', 'compact')
    end

    def show_app_logs(args)
      puts '📋 --- [ APPLICATION LOGS ] ---'

      follow_mode = args.include?('--follow') || args.include?('-f')
      last_minutes = 5

      args.each_with_index do |arg, i|
        last_minutes = args[i + 1].to_i if arg == '--last' && args[i + 1]
      end

      # App is NOT sandboxed (requires Accessibility API)
      # Use unified logging via `log` command instead of file-based logs
      puts "📡 #{project_name} logs from unified logging system"
      puts '   (Non-sandboxed app - stdout goes to unified logs)'
      puts '─' * 60

      if follow_mode
        puts 'Following live logs (Ctrl+C to stop)...'
        puts ''
        # Stream live logs - process name from project_name
        Kernel.exec('log', 'stream', '--predicate', "process == \"#{project_name}\"", '--style', 'compact')
      else
        puts "(showing last #{last_minutes} minutes)"
        puts ''
        # Show recent logs - last_minutes is sanitized via .to_i
        system('log', 'show', '--predicate', "process == \"#{project_name}\"", '--last', "#{last_minutes}m", '--style', 'compact')
      end
    end

    private

    def kill_existing_processes
      puts "1️⃣  Killing existing #{project_name} processes..."
      system('killall', '-9', project_name, err: File::NULL)
      puts '   ✅ Done'
      puts ''
    end

    def ensure_single_instance
      puts "🛑 Ensuring single #{project_name} instance..."
      system('killall', '-9', project_name, err: File::NULL)
      sleep 0.3
    end

    def canonical_local_app_path
      env_override = ENV['SANEMASTER_CANONICAL_APP_PATH']
      return File.expand_path(env_override) if env_override && !env_override.strip.empty?

      app_name = "#{project_name}.app"
      system_app = File.join('/Applications', app_name)
      user_app = File.expand_path(File.join('~/Applications', app_name))

      return system_app if File.exist?(system_app)
      return user_app if File.exist?(user_app)

      user_app
    end

    def stage_to_canonical_local_app_path(source_app_path)
      target_app_path = canonical_local_app_path
      target_parent = File.dirname(target_app_path)
      FileUtils.mkdir_p(target_parent) unless Dir.exist?(target_parent)

      if File.expand_path(source_app_path) == File.expand_path(target_app_path)
        puts "📦 Using canonical app path: #{target_app_path}"
        return target_app_path
      end

      puts "📦 Staging build to canonical path: #{target_app_path}"
      lock_path = File.join(Dir.tmpdir, "saneapps-stage-#{project_name}.lock")
      staged_ok = false

      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock_file|
        lock_file.flock(File::LOCK_EX)

        temp_app_path = "#{target_app_path}.staging-#{Process.pid}-#{Time.now.to_i}"
        backup_app_path = "#{target_app_path}.backup-#{Process.pid}-#{Time.now.to_i}"
        moved_original = false

        begin
          FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
          copied = system('ditto', source_app_path, temp_app_path)
          unless copied && File.exist?(temp_app_path)
            puts "❌ Failed to stage app at canonical path: #{target_app_path}"
            return source_app_path
          end

          if File.exist?(target_app_path)
            FileUtils.mv(target_app_path, backup_app_path)
            moved_original = true
          end

          begin
            FileUtils.mv(temp_app_path, target_app_path)
          rescue StandardError
            if moved_original && File.exist?(backup_app_path)
              FileUtils.mv(backup_app_path, target_app_path)
            end
            raise
          end

          staged_ok = File.exist?(target_app_path)
        ensure
          FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
          FileUtils.rm_rf(backup_app_path) if File.exist?(backup_app_path)
          lock_file.flock(File::LOCK_UN)
        end
      end

      return source_app_path unless staged_ok

      # Flush Launch Services cache so macOS resolves the single canonical path.
      lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
      system(lsregister, '-kill', '-r', '-domain', 'user') if File.exist?(lsregister)

      target_app_path
    end

    def reconcile_accessibility_trust_local(app_path)
      bundle_id = bundle_id_for_app(app_path)
      return unless bundle_id

      user_db = File.expand_path('~/Library/Application Support/com.apple.TCC/TCC.db')
      return unless File.exist?(user_db)

      escaped_bundle = bundle_id.gsub("'", "''")
      rows_raw = `sqlite3 "#{user_db}" "SELECT rowid || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}';"`.strip
      return if rows_raw.empty?

      stale_row_ids = []

      rows_raw.each_line do |line|
        row = line.strip
        next if row.empty?

        row_id, csreq_hex = row.split('|', 2)
        next unless row_id && row_id.match?(/\A\d+\z/)

        if csreq_hex.nil? || csreq_hex.empty?
          stale_row_ids << row_id
          next
        end

        csreq_path = File.join(Dir.tmpdir, "sanemaster-ax-#{project_name}-#{row_id}.csreq")
        begin
          File.binwrite(csreq_path, [csreq_hex].pack('H*'))
          requirement = `csreq -r "#{csreq_path}" -t 2>/dev/null`.strip

          if requirement.empty?
            stale_row_ids << row_id
            next
          end

          matches = system('codesign', "-R=#{requirement}", app_path, out: File::NULL, err: File::NULL)
          stale_row_ids << row_id unless matches
        ensure
          FileUtils.rm_f(csreq_path)
        end
      end

      return if stale_row_ids.empty?

      puts "🧹 Repairing stale Accessibility rows for #{bundle_id}"
      system('killall', 'tccd', out: File::NULL, err: File::NULL)
      system('sqlite3', user_db, "DELETE FROM access WHERE rowid IN (#{stale_row_ids.join(',')});", out: File::NULL, err: File::NULL)
      system('killall', 'tccd', out: File::NULL, err: File::NULL)
    end

    def bundle_id_for_app(app_path)
      info_plist = File.join(app_path, 'Contents', 'Info.plist')
      return nil unless File.exist?(info_plist)

      bundle_id = `"/usr/libexec/PlistBuddy" -c "Print :CFBundleIdentifier" "#{info_plist}" 2>/dev/null`.strip
      return nil if bundle_id.empty?

      bundle_id
    end

    def show_screenshots(screenshots_dir)
      puts '2️⃣  Screenshots in project:'
      if Dir.exist?(screenshots_dir)
        screenshots = Dir.glob(File.join(screenshots_dir, '*.png')).sort_by { |f| File.mtime(f) }.reverse
        if screenshots.any?
          puts "   📁 #{screenshots_dir}"
          screenshots.first(5).each do |f|
            mtime = File.mtime(f).strftime('%Y-%m-%d %H:%M:%S')
            puts "   📸 #{File.basename(f)} (#{mtime})"
          end
          puts "   ... and #{screenshots.count - 5} more" if screenshots.count > 5
          puts "\n   💡 To clear old screenshots: rm Screenshots/*.png"
        else
          puts '   (no screenshots found)'
        end
      else
        puts "   (screenshots directory doesn't exist)"
      end
      puts ''
    end

    def show_diagnostic_reports(crash_dir)
      puts '3️⃣  Recent diagnostic reports:'
      crash_files = Dir.glob(File.join(crash_dir, "#{project_name}-*.ips")).sort_by { |f| File.mtime(f) }.reverse
      hang_files = Dir.glob(File.join(crash_dir, "#{project_name}-*.{spin,hang}")).sort_by { |f| File.mtime(f) }.reverse

      if crash_files.any?
        puts '   Crashes:'
        crash_files.first(3).each do |f|
          mtime = File.mtime(f).strftime('%Y-%m-%d %H:%M:%S')
          puts "   💥 #{File.basename(f)} (#{mtime})"
        end
        puts "   ... and #{crash_files.count - 3} more crashes" if crash_files.count > 3
      else
        puts '   💥 No crash reports'
      end

      if hang_files.any?
        puts '   Hangs/Spins:'
        hang_files.first(2).each do |f|
          mtime = File.mtime(f).strftime('%Y-%m-%d %H:%M:%S')
          puts "   🔄 #{File.basename(f)} (#{mtime})"
        end
      end

      show_xcresult_status
      puts ''
    end

    def show_xcresult_status
      xcresult_dir = File.expand_path('~/Library/Developer/Xcode/DerivedData')
      xcresults = Dir.glob(File.join(xcresult_dir, "#{project_name}-*/Logs/Test/*.xcresult")).sort_by { |f| File.mtime(f) }.reverse
      return unless xcresults.any?

      latest = xcresults.first
      mtime = File.mtime(latest).strftime('%Y-%m-%d %H:%M:%S')
      puts "   📊 Latest test result: #{File.basename(latest)} (#{mtime})"
    end

    def build_app # rubocop:disable Naming/PredicateMethod -- performs action, not just a query
      puts '4️⃣  Building app...'
      unless run_build_command(summary_lines: 5, build_config: launch_build_config([]))
        puts '   ❌ Build failed! Fix errors before continuing.'
        return false
      end
      puts '   ✅ Build succeeded'
      puts ''
      true
    end

    def show_log_status(log_file)
      puts '6️⃣  Debug log status:'
      if File.exist?(log_file)
        mtime = File.mtime(log_file).strftime('%Y-%m-%d %H:%M:%S')
        size = (File.size(log_file) / 1024.0).round(1)
        puts "   📋 #{log_file}"
        puts "   📅 Last updated: #{mtime} (#{size}KB)"
      else
        puts '   (log file not created yet - will appear after app runs)'
      end
      puts ''
    end

    def print_test_mode_ready
      puts '═' * 60
      puts '🧪 TEST MODE READY'
      puts '═' * 60
      puts ''
      puts '📋 Logs: Using unified logging (non-sandboxed app)'
      puts '   View with: ./Scripts/SaneMaster.rb logs --follow'
      puts ''
      puts "🕐 Session started: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      puts ''
    end

    def run_build_command(summary_lines: 3, build_config: launch_build_config([]))
      require 'open3'

      cmd = ['xcodebuild', *xcodebuild_container_args, '-scheme', project_scheme, '-configuration', build_config,
             '-destination', 'platform=macOS', 'ENABLE_DEBUG_DYLIB=NO', 'build']
      stdout, status = Open3.capture2e(*cmd)

      summary = stdout.lines.select { |line| line.match?(/BUILD|error:|warning:|CodeSign|Signing/) }.last(summary_lines)
      if summary.any?
        summary.each { |line| puts "   #{line.rstrip}" }
      elsif !status.success?
        puts '   ⚠️  Build failed without matched summary lines. Showing tail output:'
        stdout.lines.last(summary_lines).each { |line| puts "   #{line.rstrip}" }
      end

      status.success?
    end

    def built_app_candidates(build_config)
      dd_glob = File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*/Build/Products/#{build_config}")
      Dir.glob(File.join(dd_glob, "#{project_name}.app")).sort_by { |path| File.mtime(path) }.reverse
    end

    def app_bundle_executable_path(app_path)
      File.join(app_path, 'Contents', 'MacOS', project_name)
    end

    def app_bundle_executable?(app_path)
      executable = app_bundle_executable_path(app_path)
      File.file?(executable) && File.executable?(executable)
    end

    def launch_build_config(args)
      return 'ProdDebug' if args.include?('--proddebug')
      return 'Release' if args.include?('--release')

      # SaneBar local testing is only supported in signed launch modes.
      # Debug mode can trigger invisible/off-screen menu bar icon behavior.
      if project_name == 'SaneBar'
        requested = (ENV['SANEMASTER_BUILD_CONFIG'] || ENV['SANEBAR_BUILD_CONFIG'] || '').strip
        requested = case requested.downcase
                    when 'proddebug' then 'ProdDebug'
                    when 'release' then 'Release'
                    when 'debug' then 'Debug'
                    else requested
                    end

        return requested if %w[ProdDebug Release].include?(requested)

        if requested == 'Debug' && ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1'
          puts '⚠️  Unsigned fallback active for SaneBar: using Debug build configuration.'
          return 'Debug'
        end

        return 'ProdDebug'
      end

      ENV['SANEMASTER_BUILD_CONFIG'] || 'Debug'
    end

    def project_swift_sources
      ignored_roots = %w[.git build .build DerivedData node_modules vendor Pods releases fastlane].freeze

      Dir.glob('**/*.swift').reject do |path|
        path.split(File::SEPARATOR).any? { |part| ignored_roots.include?(part) }
      end
    end
  end
end
