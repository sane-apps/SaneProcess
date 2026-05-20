# frozen_string_literal: true

module SaneMasterModules
  # Interactive debugging workflow, app launching, logs
  module TestMode
    require 'fileutils'
    require 'tmpdir'

    SANEAPPS_TEST_MODE_APPS = %w[SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo].freeze

    # Detect project name from current directory (context-specific)
    def project_name
      @project_name ||= File.basename(Dir.pwd)
    end

    def launch_app(args)
      return false unless ensure_research_gate_clear!('launch')

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
      trashed_copies = trash_noncanonical_local_app_copies(preserve_paths: protected_local_app_paths(launch_path))
      puts "🧹 Trashed #{trashed_copies} stale app bundle(s) before launch" if trashed_copies.positive?
      reconcile_accessibility_trust_local(launch_path)

      puts "📱 Launching: #{launch_path}"
      capture_logs = args.include?('--logs')
      allow_keychain = args.include?('--allow-keychain')
      force_free_mode = args.include?('--free-mode') || args.include?('--basic-mode') || args.include?('--basic')
      env_vars = launch_env_vars(allow_keychain: allow_keychain, force_free_mode: force_free_mode)
      launch_args = launch_binary_args(allow_keychain: allow_keychain)
      ensure_single_instance
      kill_other_saneapps_processes

      executable_path = File.join(launch_path, 'Contents', 'MacOS', project_name)

      if capture_logs
        puts '📝 Capturing logs to stdout...'
        pid = spawn(env_vars, executable_path, *launch_args)
        Process.wait(pid)
      else
        open_cmd = ['open', '--fresh', launch_path]
        open_cmd += open_launch_env_pairs(allow_keychain: allow_keychain, force_free_mode: force_free_mode)
        open_cmd += ['--args', *launch_args] unless launch_args.empty?
        opened = system(*open_cmd)
        unless opened
          puts '❌ Failed to launch app via open. Verify staged app bundle/executable exists.'
          return false
        end
        unless launched_process_matches?(launch_path)
          puts "❌ Launch resolved to a different #{project_name}.app copy."
          puts "   Expected: #{launch_path}"
          show_other_running_app_copies(expected_path: launch_path)
          return false
        end
        mode_label = allow_keychain ? 'keychain-enabled' : 'no-keychain'
        puts "✅ App launched (fresh build verified, #{mode_label})"
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
      if system_with_bundle_env(
        preferred_bundle_bin,
        'install',
        out: File::NULL,
        err: File::NULL
      )
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

    def enter_test_mode(args)
      return unless ensure_research_gate_clear!('test_mode')

      puts '🧪 --- [ TEST MODE ] ---'
      puts 'Preparing clean testing environment...'
      puts ''

      screenshots_dir = File.join(Dir.pwd, 'Screenshots')
      crash_dir = File.expand_path('~/Library/Logs/DiagnosticReports')

      kill_existing_processes
      kill_other_saneapps_processes
      cleanup_stale_log_streams
      show_screenshots(screenshots_dir)
      show_diagnostic_reports(crash_dir)
      return unless build_app(args)

      launch_args = []
      launch_args << '--release' if args.include?('--release')
      launch_args << '--proddebug' if args.include?('--proddebug')
      launch_args << '--force' if args.include?('--force')
      launch_args << '--allow-keychain' if args.include?('--allow-keychain')
      launch_args << '--free-mode' if args.any? { |arg| %w[--free-mode --basic-mode --basic].include?(arg) }

      return unless launch_app(launch_args)
      sleep 2
      print_test_mode_ready

      if args.include?('--no-logs')
        puts '📡 Live log streaming skipped (--no-logs).'
        return
      end

      # Stream logs in background - non-sandboxed app uses unified logging
      puts '📡 Streaming live logs in background...'
      puts '   (Non-sandboxed app - using unified logging)'
      puts '─' * 60
      spawn('/usr/bin/log', 'stream', '--predicate', "process == \"#{project_name}\"", '--style', 'compact')
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
      system('killall', '-9', 'SaneClickExtension', err: File::NULL)
      puts '   ✅ Done'
      puts ''
    end

    def kill_other_saneapps_processes
      other_apps = SANEAPPS_TEST_MODE_APPS.reject { |app| app == project_name }
      return if other_apps.empty?

      puts "🧹 Closing other SaneApps before testing #{project_name}..."
      other_apps.each do |app_name|
        system('osascript', '-e', "tell application \"#{app_name}\" to quit", out: File::NULL, err: File::NULL)
        system('killall', '-9', app_name, out: File::NULL, err: File::NULL)
      end
      system('pkill', '-f', '/SaneSync/scripts/inference_server.py', out: File::NULL, err: File::NULL) unless project_name == 'SaneSync'
      puts '   ✅ Other app surfaces closed'
      puts ''
    end

    def cleanup_stale_log_streams
      pattern = "log stream --predicate process == \"#{project_name}\""
      system('pkill', '-f', pattern, err: File::NULL)
    end

    def ensure_single_instance
      puts "🛑 Ensuring single #{project_name} instance..."
      system('killall', '-9', project_name, err: File::NULL)
      sleep 0.3
    end

    def canonical_local_app_path
      env_override = ENV['SANEMASTER_CANONICAL_APP_PATH']
      app_name = "#{project_name}.app"
      system_app = File.join('/Applications', app_name)
      transient_app = transient_local_app_path

      if env_override && !env_override.strip.empty?
        override_path = File.expand_path(env_override)
        if unsigned_fallback_active? && override_path.start_with?('/Applications/')
          puts "⚠️  Ignoring SANEMASTER_CANONICAL_APP_PATH=#{override_path} during unsigned fallback."
          puts "   Using a transient non-indexed staging path instead to avoid replacing a signed /Applications install."
          return transient_app
        end
        return override_path
      end

      # Never replace a signed system install with unsigned fallback builds.
      return transient_app if unsigned_fallback_active?

      return system_app if system_app_dir_writable?
      return system_app if File.exist?(system_app)

      system_app
    end

    def stage_to_canonical_local_app_path(source_app_path)
      target_app_path = canonical_local_app_path
      if should_block_local_signing_tcc_drift?(source_app_path: source_app_path, target_app_path: target_app_path)
        puts "❌ Refusing to stage a locally signed build over the trusted #{project_name} install."
        puts '   That breaks the existing Accessibility/TCC identity and can trap the app in a permissions loop.'
        puts "   Use: ./scripts/SaneMaster.rb test_mode --release"
        puts '   Set SANEMASTER_ALLOW_TCC_IDENTITY_DRIFT=1 to override if you really want a fresh untrusted identity.'
        exit 1
      end

      if should_preserve_system_release_install?(source_app_path: source_app_path, target_app_path: target_app_path)
        puts "⚠️  Preserving signed /Applications install for #{project_name}."
        puts "   Skipping local Apple Development staging to avoid TCC identity drift."
        puts "   Launching existing official app at: #{target_app_path}"
        puts "   Set SANEMASTER_ALLOW_REPLACE_DEVELOPER_ID=1 to override."
        return target_app_path
      end

      if should_stage_apple_development_to_transient_path?(source_app_path: source_app_path, target_app_path: target_app_path)
        redirected_target = transient_local_app_path
        puts "⚠️  Staging Apple Development build to transient non-indexed path for #{project_name}."
        puts "   Skipping /Applications write to avoid permission identity drift and duplicate installed app identities."
        puts "   Target: #{redirected_target}"
        puts "   Set SANEMASTER_ALLOW_STAGE_APPLE_DEVELOPMENT_TO_SYSTEM=1 to override."
        target_app_path = redirected_target
      end

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
        begin
          FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
          copied = system('ditto', source_app_path, temp_app_path)
          unless copied && File.exist?(temp_app_path)
            puts "❌ Failed to stage app at canonical path: #{target_app_path}"
            return source_app_path
          end

          if File.exist?(target_app_path)
            # Avoid creating backup app bundle identities under /Applications.
            # TCC can retain those paths and keep stale camera attribution alive.
            FileUtils.rm_rf(target_app_path)
          end

          FileUtils.mv(temp_app_path, target_app_path)

          staged_ok = File.exist?(target_app_path)
          staged_ok &&= ad_hoc_sign_app_bundle(target_app_path) if staged_ok && unsigned_fallback_active?
        ensure
          FileUtils.rm_rf(temp_app_path) if File.exist?(temp_app_path)
          lock_file.flock(File::LOCK_UN)
        end
      end

      return source_app_path unless staged_ok

      trash_noncanonical_local_app_copies(preserve_paths: protected_local_app_paths(target_app_path))
      flush_launch_services_cache

      target_app_path
    end

    def should_preserve_system_release_install?(source_app_path:, target_app_path:)
      return false unless target_app_path.start_with?('/Applications/')
      return false if ENV['SANEMASTER_ALLOW_REPLACE_DEVELOPER_ID'] == '1'
      return false unless File.exist?(target_app_path)
      return false unless source_app_path && File.exist?(source_app_path)

      target_signed_release = developer_id_signed?(target_app_path)
      source_is_dev_signed = apple_development_signed?(source_app_path)
      target_signed_release && source_is_dev_signed
    end

    def should_stage_apple_development_to_transient_path?(source_app_path:, target_app_path:)
      return false unless target_app_path.start_with?('/Applications/')
      return false if ENV['SANEMASTER_ALLOW_STAGE_APPLE_DEVELOPMENT_TO_SYSTEM'] == '1'
      return false unless source_app_path && File.exist?(source_app_path)

      apple_development_signed?(source_app_path)
    end

    def should_block_local_signing_tcc_drift?(source_app_path:, target_app_path:)
      return false if ENV['SANEMASTER_ALLOW_TCC_IDENTITY_DRIFT'] == '1'
      return false unless tcc_identity_sensitive_project?
      return false unless source_app_path && File.exist?(source_app_path)
      return false unless target_app_path.start_with?('/Applications/')
      return false unless File.exist?(target_app_path)
      return false unless developer_id_signed?(target_app_path)

      !developer_id_signed?(source_app_path)
    end

    def tcc_identity_sensitive_project?
      %w[SaneBar SaneClick SaneVideo].include?(project_name)
    end

    def transient_local_app_path
      File.expand_path(File.join('/tmp/saneapps-staging.noindex', "#{project_name}.app"))
    end

    def ad_hoc_sign_app_bundle(app_path)
      signable_paths = []
      signable_paths.concat(Dir.glob(File.join(app_path, 'Contents', 'PlugIns', '*.appex')))
      signable_paths.concat(Dir.glob(File.join(app_path, 'Contents', 'Frameworks', '*.framework')))
      signable_paths.concat(Dir.glob(File.join(app_path, 'Contents', 'XPCServices', '*.xpc')))
      signable_paths.concat(Dir.glob(File.join(app_path, 'Contents', 'Helpers', '*')))
      signable_paths.select! { |path| File.exist?(path) }
      signable_paths.sort_by! { |path| -path.count('/') }
      signable_paths << app_path

      signable_paths.each do |path|
        next if system('codesign', '--force', '--sign', '-', '--timestamp=none', path, out: File::NULL, err: File::NULL)

        puts "❌ Failed to ad-hoc sign #{path}"
        return false
      end

      true
    end

    def system_app_dir_writable?
      File.writable?('/Applications')
    rescue StandardError
      false
    end

    def local_app_copy_paths
      patterns = [
        File.join('/Applications', "#{project_name}.app"),
        transient_local_app_path,
        File.expand_path("/tmp/#{project_name}.app"),
        File.expand_path("~/Library/Developer/Xcode/DerivedData/#{project_name}-*/Build/Products/*/#{project_name}.app"),
        File.expand_path("~/codex-runs/**/#{project_name}.app"),
        File.expand_path("~/codex-runs/.worktrees/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/apps/#{project_name}/build/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/apps/#{project_name}/outputs/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/release/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/release-publish/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/release-worktrees/**/#{project_name}.app"),
        File.expand_path("~/SaneApps/tmp/**/#{project_name}.app"),
        File.expand_path("~/tmp/**/#{project_name}.app")
      ]

      patterns
        .flat_map { |pattern| Dir.glob(pattern, File::FNM_DOTMATCH) }
        .select { |path| File.directory?(path) }
        .map { |path| File.expand_path(path) }
        .uniq
        .sort
    end

    def protected_local_app_paths(primary_path)
      preserved = [File.expand_path(primary_path)]

      system_app = File.join('/Applications', "#{project_name}.app")
      if unsigned_fallback_active? && File.exist?(system_app)
        preserved << File.expand_path(system_app)
      end

      # If the caller explicitly stages to a transient non-/Applications path,
      # keep any official signed /Applications install intact. It should not be
      # treated as a stale duplicate of an Apple Development build.
      if !File.expand_path(primary_path).start_with?('/Applications/') &&
         File.exist?(system_app) &&
         developer_id_signed?(system_app)
        preserved << File.expand_path(system_app)
      end

      preserved.uniq
    end

    def trash_noncanonical_local_app_copies(preserve_paths:)
      preserved = Array(preserve_paths).map { |path| File.expand_path(path) }
      stale_paths = local_app_copy_paths.reject { |path| preserved.include?(File.expand_path(path)) }
      stale_paths.each do |path|
        puts "🗑️  Trashing stale app bundle: #{path}"
        trash_local_path(path)
      end
      stale_paths.length
    end

    def trash_local_path(path)
      return unless File.exist?(path)

      ok = system('/usr/bin/trash', path, out: File::NULL, err: File::NULL)
      raise "Failed to move stale app bundle to Trash: #{path}" unless ok
    end

    def flush_launch_services_cache
      lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
      return unless File.exist?(lsregister)

      system(lsregister, '-kill', '-r', '-domain', 'local', '-domain', 'system', '-domain', 'user')
    end

    def local_app_processes(app_path)
      expected_binary = File.join(File.expand_path(app_path), 'Contents', 'MacOS', project_name)
      `ps ax -o pid=,command=`
        .lines
        .map(&:strip)
        .reject(&:empty?)
        .select do |line|
          _pid, command = line.split(/\s+/, 2)
          next false unless command

          binary = command.split(/\s+/, 2).first.to_s
          File.expand_path(binary) == expected_binary
        end
    end

    def any_project_processes
      binary_suffix = "/#{project_name}.app/Contents/MacOS/#{project_name}"
      `ps ax -o pid=,command=`
        .lines
        .map(&:strip)
        .reject(&:empty?)
        .select { |line| line.include?(binary_suffix) }
    end

    def launched_process_matches?(app_path)
      deadline = Time.now + 8
      loop do
        matches = local_app_processes(app_path)
        return true unless matches.empty?

        break if Time.now >= deadline

        sleep 0.5
      end

      false
    end

    def show_other_running_app_copies(expected_path:)
      others = any_project_processes.reject { |line| line.include?(File.expand_path(expected_path)) }
      if others.empty?
        puts '   No alternate running copy was detected.'
        return
      end

      puts '   Other running copies:'
      others.each { |line| puts "   #{line}" }
    end

    def codesign_authority_lines(app_path)
      return [] unless app_path && File.exist?(app_path)

      output = `codesign -dv --verbose=2 "#{app_path}" 2>&1`
      output.lines.map(&:strip).grep(/\AAuthority=/)
    end

    def developer_id_signed?(app_path)
      codesign_authority_lines(app_path).any? { |line| line.start_with?('Authority=Developer ID Application:') }
    end

    def apple_development_signed?(app_path)
      codesign_authority_lines(app_path).any? { |line| line.start_with?('Authority=Apple Development:') }
    end

    def reconcile_accessibility_trust_local(app_path)
      bundle_id = bundle_id_for_app(app_path)
      return unless bundle_id

      db_paths = accessibility_tcc_db_paths
      return if db_paths.empty?

      # Clean legacy dev-bundle aliases that create duplicate Accessibility rows
      # in System Settings and can lock users out of the actively launched app.
      legacy_aliases = [bundle_id.sub(/\.app\z/, '.dev')].uniq.reject { |id| id == bundle_id }
      legacy_aliases.each do |legacy_id|
        system('tccutil', 'reset', 'Accessibility', legacy_id, out: File::NULL, err: File::NULL)
      end

      denied_rows_by_db = {}

      db_paths.each do |db_path|
        rows = accessibility_tcc_rows(db_path, bundle_id)
        next if rows.empty?

        denied_rows = rows.select { |row| row[:auth_value].to_i.zero? }
        denied_rows_by_db[db_path] = denied_rows unless denied_rows.empty?

        stale_row_ids = []
        rows.each do |row|
          row_id = row[:row_id]
          csreq_hex = row[:csreq_hex]

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

        next if stale_row_ids.empty?

        puts "🧹 Repairing stale Accessibility rows for #{bundle_id} in #{db_path}"
        system('killall', 'tccd', out: File::NULL, err: File::NULL)
        system('sqlite3', db_path, "DELETE FROM access WHERE rowid IN (#{stale_row_ids.join(',')});", out: File::NULL, err: File::NULL)
        system('killall', 'tccd', out: File::NULL, err: File::NULL)
      end

      denied_rows = denied_rows_by_db[system_accessibility_tcc_db_path]
      return if denied_rows.nil? || denied_rows.empty?

      auth_values = denied_rows.map { |row| row[:auth_value] }.uniq.sort.join(',')
      puts "⚠️  System Accessibility row for #{bundle_id} is denied (auth_value=#{auth_values})."
      puts '   Live AX verification is blocked until the password-gated Modify Settings sheet is completed.'
    end

    def accessibility_tcc_rows(db_path, bundle_id)
      escaped_bundle = bundle_id.gsub("'", "''")
      rows_raw = `sqlite3 "#{db_path}" "SELECT rowid || '|' || auth_value || '|' || IFNULL(hex(csreq), '') FROM access WHERE service='kTCCServiceAccessibility' AND client='#{escaped_bundle}';"`.strip
      return [] if rows_raw.empty?

      rows_raw.each_line.map do |line|
        row = line.strip
        next if row.empty?

        row_id, auth_value, csreq_hex = row.split('|', 3)
        next unless row_id && row_id.match?(/\A\d+\z/)

        {
          row_id: row_id,
          auth_value: auth_value.to_i,
          csreq_hex: csreq_hex.to_s
        }
      end.compact
    end

    def accessibility_tcc_db_paths
      [
        File.expand_path('~/Library/Application Support/com.apple.TCC/TCC.db'),
        system_accessibility_tcc_db_path
      ].uniq.select { |path| File.exist?(path) }
    end

    def system_accessibility_tcc_db_path
      '/Library/Application Support/com.apple.TCC/TCC.db'
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

    def build_app(args = []) # rubocop:disable Naming/PredicateMethod -- performs action, not just a query
      puts '4️⃣  Building app...'
      unless run_build_command(summary_lines: 5, build_config: launch_build_config(args))
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
      puts '   View with: ./scripts/SaneMaster.rb logs --follow'
      puts ''
      puts "🕐 Session started: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      puts ''
    end

    def run_build_command(summary_lines: 3, build_config: launch_build_config([]))
      require 'open3'

      prepare_signing_session_for_build(build_config)

      ENV.delete('SANEMASTER_UNSIGNED_FALLBACK_ACTIVE')
      ENV['SANEMASTER_BUILD_CONFIG'] = build_config

      cmd = ['xcodebuild', *xcodebuild_container_args, '-scheme', project_scheme, '-configuration', build_config,
             '-destination', 'platform=macOS', 'ENABLE_DEBUG_DYLIB=NO', *release_runtime_build_args(build_config), 'build']
      stdout, status = Open3.capture2e(*cmd)

      if should_retry_unsigned_debug?(build_config: build_config, output: stdout, status: status)
        fallback_config = build_config == 'Release-AppStore' ? build_config : 'Debug'
        puts "   ⚠️  Signed build blocked in headless session; retrying unsigned #{fallback_config} build..."
        fallback_cmd = ['xcodebuild', *xcodebuild_container_args, '-scheme', project_scheme, '-configuration', fallback_config,
                        '-destination', 'platform=macOS', 'ENABLE_DEBUG_DYLIB=NO',
                        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'build']
        fallback_stdout, fallback_status = Open3.capture2e(*fallback_cmd)
        stdout = fallback_stdout
        status = fallback_status

        if fallback_status.success?
          ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] = '1'
          ENV['SANEMASTER_BUILD_CONFIG'] = fallback_config
        end
      end

      summary = stdout.lines.select { |line| line.match?(/BUILD|error:|warning:|CodeSign|Signing/) }.last(summary_lines)
      if summary.any?
        summary.each { |line| puts "   #{line.rstrip}" }
      elsif !status.success?
        puts '   ⚠️  Build failed without matched summary lines. Showing tail output:'
        stdout.lines.last(summary_lines).each { |line| puts "   #{line.rstrip}" }
      end

      status.success?
    end

    def release_runtime_build_args(build_config)
      return [] unless %w[ProdDebug Release].include?(build_config)

      configured = saneprocess_value('release', 'test_mode_extra_args') ||
                   saneprocess_value('release', 'archive_extra_args')
      Array(configured).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def prepare_signing_session_for_build(build_config)
      return unless %w[ProdDebug Release].include?(build_config)

      load_saneprocess_secrets_env

      login_keychain = ENV['SANEBAR_KEYCHAIN_PATH'] || ENV['KEYCHAIN_PATH'] || File.expand_path('~/Library/Keychains/login.keychain-db')
      return unless File.exist?(login_keychain)

      keychain_password = ENV['SANEBAR_KEYCHAIN_PASSWORD'] || ENV['KEYCHAIN_PASSWORD'] || ENV['KEYCHAIN_PASS']
      return if keychain_password.to_s.strip.empty?

      system('security', 'default-keychain', '-d', 'user', '-s', login_keychain, out: File::NULL, err: File::NULL)
      system('security', 'list-keychains', '-d', 'user', '-s', login_keychain, '/Library/Keychains/System.keychain',
             out: File::NULL, err: File::NULL)
      system('security', 'set-keychain-settings', '-lut', '21600', login_keychain, out: File::NULL, err: File::NULL)

      unless system('security', 'unlock-keychain', '-p', keychain_password, login_keychain,
                    out: File::NULL, err: File::NULL)
        puts "   ⚠️  Could not unlock login keychain for #{build_config} signing."
        return
      end

      unless ENV['OTHER_CODE_SIGN_FLAGS'].to_s.include?("--keychain #{login_keychain}")
        existing = ENV['OTHER_CODE_SIGN_FLAGS'].to_s.strip
        prefix = "--keychain #{login_keychain}"
        ENV['OTHER_CODE_SIGN_FLAGS'] = existing.empty? ? prefix : "#{prefix} #{existing}"
      end

      identities = `security find-identity -v -p codesigning "#{login_keychain}" 2>/dev/null`
      identities.each_line do |line|
        identity = line[/^\s*\d+\)\s+[0-9A-F]{40}\s+"([^"]+)"/, 1]
        next if identity.nil? || identity.empty?

        system('security', 'set-key-partition-list',
               '-S', 'apple-tool:,apple:,codesign:',
               '-s',
               '-k', keychain_password,
               '-D', identity,
               '-t', 'private',
               login_keychain,
               out: File::NULL,
               err: File::NULL)
      end
    end

    def load_saneprocess_secrets_env
      env_file = File.expand_path('~/.config/saneprocess/secrets.env')
      return unless File.file?(env_file)

      File.foreach(env_file) do |line|
        next if line.strip.empty? || line.lstrip.start_with?('#')

        text = line.sub(/\A\s*export\s+/, '').strip
        next unless text.include?('=')

        key, raw_value = text.split('=', 2)
        key = key.to_s.strip
        next if key.empty? || ENV.key?(key)

        value = raw_value.to_s.strip
        if value.start_with?('"') && value.end_with?('"') && value.length >= 2
          value = value[1..-2]
        elsif value.start_with?("'") && value.end_with?("'") && value.length >= 2
          value = value[1..-2]
        end

        ENV[key] = value
      end
    end

    def should_retry_unsigned_debug?(build_config:, output:, status:)
      return false if status.success?
      return false unless (ENV['SANEMASTER_ALLOW_UNSIGNED_FALLBACK'] || '1') != '0'
      return false unless ENV['SSH_CONNECTION'] || ENV['SANEMASTER_HEADLESS'] == '1'
      return false if build_config == 'Debug' && ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1'

      signing_error_patterns = [
        /errSecInternalComponent/,
        /Command CodeSign failed/,
        /User interaction is not allowed/,
        /codesign.*nonzero exit code/i,
        /No profiles for .+ were found/,
        /Automatic signing is disabled and unable to generate a profile/,
        /requires a provisioning profile with the .+ feature/
      ]

      signing_error_patterns.any? { |pattern| output.match?(pattern) }
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
      if ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1' &&
         ENV['SANEMASTER_BUILD_CONFIG'].to_s.strip.casecmp('debug').zero?
        puts '⚠️  Unsigned fallback active: launching Debug build configuration.'
        return 'Debug'
      end

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

    def launch_env_vars(allow_keychain:, force_free_mode:)
      env_vars = {}
      env_vars['VERIFY_PIP'] = ENV['VERIFY_PIP'] if ENV['VERIFY_PIP']
      passthrough_launch_env_vars.each do |key, value|
        env_vars[key] = value
      end
      env_vars['SANEAPPS_DISABLE_KEYCHAIN'] = '1' unless allow_keychain
      return env_vars unless force_free_mode

      env_vars['SANEAPPS_FORCE_LICENSE_CHECK'] = '1'
      env_vars['SANEAPPS_FORCE_FREE_MODE'] = '1' unless project_name == 'SaneBar'
      env_vars
    end

    def open_launch_env_pairs(allow_keychain:, force_free_mode:)
      pairs = []
      passthrough_launch_env_vars.each do |key, value|
        pairs += ['--env', "#{key}=#{value}"]
      end
      pairs += ['--env', 'SANEAPPS_DISABLE_KEYCHAIN=1'] unless allow_keychain
      return pairs unless force_free_mode

      pairs += ['--env', 'SANEAPPS_FORCE_LICENSE_CHECK=1']
      pairs += ['--env', 'SANEAPPS_FORCE_FREE_MODE=1'] unless project_name == 'SaneBar'
      pairs
    end

    def passthrough_launch_env_vars
      allowed_exact = %w[
        OPEN_PROJECT_PATH
        SANEAPPS_PERMISSIONLESS_AUTOMATION
        TEST_PROJECT_PATH
        VERIFY_PIP
      ].freeze

      ENV.each_with_object({}) do |(key, value), vars|
        next if value.nil? || value.empty?
        next unless key.start_with?('SANEVIDEO_') || allowed_exact.include?(key)

        vars[key] = value
      end
    end

    def launch_binary_args(allow_keychain:)
      return [] if allow_keychain

      ['--sane-no-keychain']
    end

    def unsigned_fallback_active?
      ENV['SANEMASTER_UNSIGNED_FALLBACK_ACTIVE'] == '1'
    end
  end
end
