# frozen_string_literal: true

module SaneMasterModules
  # Unified release entrypoint (delegates to SaneProcess release.sh)
  module Release
    def appcast_drift_failure_only?(verify_output)
      xcresult_path = verify_output[/Analyzing result:\s+(.+\.xcresult)/, 1]
      return false unless xcresult_path && File.directory?(xcresult_path)

      summary_out, summary_status = Open3.capture2e(
        'xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', xcresult_path
      )
      return false unless summary_status.success?

      summary = JSON.parse(summary_out) rescue nil
      failures = summary.is_a?(Hash) && summary['testFailures'].is_a?(Array) ? summary['testFailures'] : []
      return false unless failures.length == 1

      only_failure = failures.first
      identifier = only_failure['testIdentifierString'].to_s
      failure_text = only_failure['failureText'].to_s

      identifier.include?('AppcastReleaseGuardrailTests/newestMatchesProjectVersion()') ||
        failure_text.include?('Newest appcast entry should match MARKETING_VERSION')
    rescue StandardError
      false
    end

    def release(args)
      release_script = File.expand_path('../release.sh', __dir__)
      unless File.exist?(release_script)
        puts "❌ Release script not found: #{release_script}"
        exit 1
      end

      effective_args = args.dup
      # Keep release as a single-command flow by default.
      # If caller explicitly asks for --full, also deploy unless they opt out.
      if effective_args.include?('--full') && !effective_args.include?('--deploy')
        if effective_args.delete('--no-deploy')
          # explicit opt-out, keep build/notarize-only behavior
        else
          effective_args << '--deploy'
        end
      else
        effective_args.delete('--no-deploy')
      end

      cmd = [release_script]
      unless args.include?('--project')
        cmd += ['--project', Dir.pwd]
      end
      cmd.concat(effective_args)

      puts '🚀 --- [ SANEMASTER RELEASE ] ---'
      puts "Using: #{release_script}"
      puts "Project: #{Dir.pwd}" unless args.include?('--project')
      if effective_args.include?('--full') && effective_args.include?('--deploy')
        puts 'Mode: full release + deploy'
      elsif effective_args.include?('--full')
        puts 'Mode: full release (deploy skipped by explicit --no-deploy)'
      end
      puts ''

      exec(*cmd)
    end

    # Standalone release preflight — runs all safety checks without building.
    # Derived from 46 GitHub issues, 200+ customer emails, 34 documented burns.
    def release_preflight(_args)
      require 'json'
      require 'open3'

      puts '🛫 --- [ RELEASE PREFLIGHT ] ---'
      puts "Project: #{Dir.pwd}"
      puts ''

      issues = []
      warnings = []

      # 1. Tests pass
      print '  Tests... '
      out, status = Open3.capture2e('./scripts/SaneMaster.rb', 'verify', '--quiet')
      if status.success?
        puts '✅'
      else
        puts '❌ FAIL'
        issues << 'Tests failing'
      end

      # 2. Git clean
      print '  Git clean... '
      dirty, = Open3.capture2('git', 'status', '--porcelain')
      dirty = dirty.strip
      if dirty.empty?
        puts '✅'
      else
        puts "⚠️  #{dirty.lines.count} uncommitted changes"
        warnings << "#{dirty.lines.count} uncommitted files"
      end

      # 3. UserDefaults / migration changes
      print '  Defaults/migration changes... '
      changed_files, = Open3.capture2('git', 'diff', 'HEAD~5..HEAD', '--name-only', '--', '*.swift')
      defaults_files = changed_files.strip.split("\n")
        .select { |f| File.exist?(f) }
        .select do |f|
          content = File.read(f) rescue ''
          content.match?(/UserDefaults|setDefaultsIfNeeded|registerDefaults|migration|migrate/i)
        end
      if defaults_files.any?
        puts "⚠️  #{defaults_files.count} file(s)"
        defaults_files.each { |f| puts "    - #{f}" }
        warnings << 'UserDefaults/migration code changed — upgrade path test required'
      else
        puts '✅ none'
      end

      # 4. Sparkle key in project config
      print '  Sparkle public key... '
      plist_paths = Dir.glob('**/Info.plist').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      expected_key = '7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU='
      checked_key = false
      plist_paths.each do |plist|
        key, = Open3.capture2e('/usr/libexec/PlistBuddy', '-c', 'Print :SUPublicEDKey', plist)
        key = key.strip
        next if key.empty? || key.include?('Does Not Exist')

        checked_key = true
        if key == expected_key
          puts "✅ (#{plist})"
        else
          puts "❌ MISMATCH in #{plist}"
          issues << "SUPublicEDKey mismatch: #{key}"
        end
      end
      puts '⏭️  no Info.plist with SUPublicEDKey found' unless checked_key

      # 5. Open GitHub issues + PRs
      print '  Open GitHub issues... '
      saneprocess_path = File.join(Dir.pwd, '.saneprocess')
      app_name = nil
      if File.exist?(saneprocess_path)
        match = File.read(saneprocess_path).match(/^name:\s*(.+)/)
        app_name = match[1].strip if match
      end
      repo = "sane-apps/#{app_name || File.basename(Dir.pwd)}"
      gh_path, gh_status = Open3.capture2('bash', '-lc', 'command -v gh')
      if gh_status.success? && !gh_path.strip.empty?
        issue_json, = Open3.capture2('gh', 'issue', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
        open_count = begin
          JSON.parse(issue_json).length
        rescue StandardError
          0
        end
        if open_count.positive?
          puts "⚠️  #{open_count} open"
          warnings << "#{open_count} open GitHub issues"
        else
          puts '✅ none'
        end

        print '  Open GitHub PRs... '
        pr_json, = Open3.capture2('gh', 'pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
        open_pr_count = begin
          JSON.parse(pr_json).length
        rescue StandardError
          0
        end
        if open_pr_count.positive?
          puts "⚠️  #{open_pr_count} open"
          warnings << "#{open_pr_count} open GitHub PRs"
        else
          puts '✅ none'
        end
      else
        puts '⏭️  skipped (gh not installed)'
      end

      # 6. Pending customer emails
      print '  Pending emails... '
      api_key, = Open3.capture2('security', 'find-generic-password', '-s', 'sane-email-automation', '-a', 'api_key', '-w')
      api_key = api_key.strip
      if api_key.empty?
        puts '⏭️  skipped (no API key)'
      else
        pending_json, = Open3.capture2('curl', '-s',
                                       'https://email-api.saneapps.com/api/emails/pending',
                                       '-H', "Authorization: Bearer #{api_key}")
        pending_count = begin
          JSON.parse(pending_json).length
        rescue StandardError
          0
        end
        if pending_count.positive?
          puts "⚠️  #{pending_count} pending"
          warnings << "#{pending_count} pending customer emails"
        else
          puts '✅ none'
        end
      end

      # 7. License API reachable
      print '  License API (LemonSqueezy)... '
      ls_status, = Open3.capture2('curl', '-sI', '-o', '/dev/null', '-w', '%{http_code}',
                                  'https://api.lemonsqueezy.com/v1/licenses/validate')
      ls_status = ls_status.strip
      if ls_status == '000'
        puts '⚠️  unreachable'
        warnings << 'LemonSqueezy license API unreachable — new activations will fail'
      elsif ls_status.to_i >= 500
        puts "⚠️  server error (#{ls_status})"
        warnings << "LemonSqueezy API returned #{ls_status}"
      else
        puts "✅ (#{ls_status})"
      end

      # 8. Homebrew tap reachable
      print '  Homebrew tap... '
      tap_status, = Open3.capture2('curl', '-sI', '-o', '/dev/null', '-w', '%{http_code}',
                                   'https://raw.githubusercontent.com/sane-apps/homebrew-tap/main/Casks/sanebar.rb')
      tap_status = tap_status.strip
      if tap_status == '200'
        puts '✅'
      else
        puts "⚠️  returned #{tap_status}"
        warnings << "Homebrew tap cask not reachable (#{tap_status})"
      end

      # 9. Release timing
      print '  Release timing... '
      hour = Time.now.hour
      if hour >= 17 || hour < 6
        puts "⚠️  evening/night (#{Time.now.strftime('%H:%M')})"
        warnings << 'Evening release — 8-18hr discovery window if broken'
      else
        puts "✅ daytime (#{Time.now.strftime('%H:%M')})"
      end

      # Summary
      puts ''
      puts '═' * 50
      if issues.any?
        puts "❌ BLOCKED: #{issues.count} issue(s)"
        issues.each { |i| puts "   🔴 #{i}" }
      end
      if warnings.any?
        puts "⚠️  #{warnings.count} warning(s):"
        warnings.each { |w| puts "   🟡 #{w}" }
      end
      if issues.empty? && warnings.empty?
        puts '✅ ALL CLEAR — safe to release'
      elsif issues.empty?
        puts '🟡 PROCEED WITH CAUTION — review warnings above'
      end
      puts '═' * 50

      exit 1 if issues.any?
    end

    # App Store submission preflight — validates everything Apple checks during review.
    # Derived from Apple's App Review Guidelines + community rejection checklists.
    # Works for any SaneApps project with a .saneprocess config.
    def appstore_preflight(_args)
      require 'json'
      require 'open3'
      require 'tmpdir'
      require 'yaml'

      puts '🍎 --- [ APP STORE PREFLIGHT ] ---'
      puts "Project: #{Dir.pwd}"
      puts ''

      issues = []
      warnings = []

      config_path = File.join(Dir.pwd, '.saneprocess')
      config = if File.exist?(config_path)
                 YAML.safe_load(File.read(config_path)) || {}
               else
                 {}
               end

      app_name = config['name'] || File.basename(Dir.pwd)
      appstore_config = config['appstore'] || {}

      # ═══════════════════════════════════════════
      # SECTION 1: App Store Connect Setup
      # ═══════════════════════════════════════════
      puts '  ┌── App Store Connect Setup ──'

      # 1a. appstore config exists in .saneprocess
      print '  │ .saneprocess appstore config... '
      if appstore_config['enabled']
        puts "✅ (app_id: #{appstore_config['app_id'] || 'MISSING'})"
      else
        puts '❌ not configured'
        issues << ".saneprocess missing `appstore.enabled: true` — add appstore section"
      end

      # 1b. App Store Connect app ID
      print '  │ ASC app ID... '
      asc_app_id = appstore_config['app_id']
      if asc_app_id && !asc_app_id.to_s.empty?
        puts "✅ #{asc_app_id}"
      else
        puts '❌ missing'
        issues << "No `appstore.app_id` in .saneprocess — register app in App Store Connect first"
      end

      # 1c. ASC API key exists
      print '  │ ASC API key (.p8)... '
      p8_path = File.expand_path('~/.private_keys/AuthKey_S34998ZCRT.p8')
      if File.exist?(p8_path)
        puts '✅'
      else
        puts '❌ not found'
        issues << "API key not found at #{p8_path}"
      end

      # 1d. jwt gem available
      print '  │ jwt gem... '
      _jwt_out, jwt_status = Open3.capture2e('ruby', '-e', "require 'jwt'")
      if jwt_status.success?
        puts '✅'
      else
        puts '❌ missing'
        issues << 'Ruby jwt gem not installed — run: gem install jwt'
      end

      puts '  │'

      # ═══════════════════════════════════════════
      # SECTION 2: Build Preparation
      # ═══════════════════════════════════════════
      puts '  ├── Build Preparation ──'

      # 2a. Version and build number
      print '  │ Version/build number... '
      project_yml = File.join(Dir.pwd, 'project.yml')
      version_str = nil
      build_num = nil
      if File.exist?(project_yml)
        yml_content = File.read(project_yml)
        version_match = yml_content.match(/MARKETING_VERSION:\s*"?([^"\s]+)"?/)
        build_match = yml_content.match(/CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?/)
        version_str = version_match[1] if version_match
        build_num = build_match[1] if build_match
      end
      if version_str && build_num
        puts "✅ v#{version_str} (#{build_num})"
      elsif version_str
        puts "⚠️  v#{version_str} but no CURRENT_PROJECT_VERSION"
        warnings << 'Missing CURRENT_PROJECT_VERSION in project.yml'
      else
        puts '⚠️  could not read from project.yml'
        warnings << 'Could not read version info from project.yml'
      end

      # 2b. Entitlements file
      print '  │ Entitlements... '
      entitlements = Dir.glob('**/*.entitlements').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      app_name = config['name'] || File.basename(Dir.pwd)
      mac_like = entitlements.reject { |p| p =~ %r{/(ios|watch|widget|extension)/}i }
      # For App Store preflight, prefer the macOS AppStore-specific entitlements file.
      appstore_ent = mac_like.find { |p| p =~ /appstore/i }
      named_ent = mac_like.find do |p|
        base = File.basename(p, '.entitlements')
        base.casecmp?(app_name) || p.include?("/#{app_name}/")
      end
      target_ent = appstore_ent || named_ent || mac_like.first || entitlements.first
      if target_ent
        ent_content = File.read(target_ent) rescue ''
        has_sandbox = ent_content.include?('com.apple.security.app-sandbox')
        has_hardened = true # Hardened runtime is in build settings, not entitlements
        puts "✅ #{target_ent}"
        unless has_sandbox
          puts '  │   ⚠️  No App Sandbox entitlement (required for MAS)'
          warnings << "No com.apple.security.app-sandbox in entitlements — required for Mac App Store"
        end
      else
        puts '❌ no .entitlements file found'
        issues << 'No entitlements file found'
      end

      # 2c. Privacy manifest (PrivacyInfo.xcprivacy)
      print '  │ Privacy manifest... '
      privacy_manifests = Dir.glob('**/PrivacyInfo.xcprivacy').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      if privacy_manifests.any?
        puts "✅ #{privacy_manifests.first}"
      else
        puts '❌ missing'
        issues << 'No PrivacyInfo.xcprivacy found — required since Spring 2024 for all new submissions'
      end

      # 2d. Deployment target
      print '  │ Deployment target... '
      min_ver = config.dig('release', 'min_system_version')
      if min_ver
        puts "✅ macOS #{min_ver}"
      else
        puts '⚠️  not specified in .saneprocess'
        warnings << 'No min_system_version in .saneprocess — verify deployment target'
      end

      puts '  │'

      # ═══════════════════════════════════════════
      # SECTION 3: App Store Assets
      # ═══════════════════════════════════════════
      puts '  ├── App Store Assets ──'

      # 3a. App icon (1024x1024)
      print '  │ App icon (1024x1024)... '
      icon_1024 = Dir.glob('**/AppIcon.appiconset/icon_512x512@2x.png').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      if icon_1024.any?
        # Verify dimensions
        dims, = Open3.capture2('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', icon_1024.first)
        width = dims[/pixelWidth:\s*(\d+)/, 1].to_i
        height = dims[/pixelHeight:\s*(\d+)/, 1].to_i
        if width == 1024 && height == 1024
          puts '✅'
        else
          puts "❌ #{width}x#{height} (need 1024x1024)"
          issues << "App icon is #{width}x#{height}, must be 1024x1024"
        end
      else
        puts '❌ not found'
        issues << 'No 1024x1024 app icon found in AppIcon.appiconset'
      end

      # 3b. Screenshots configured and valid
      print '  │ Screenshots... '
      screenshots_config = appstore_config['screenshots'] || {}
      platforms = appstore_config['platforms'] || ['macos']
      project_yml_content = File.exist?(project_yml) ? File.read(project_yml) : ''
      ios_supports_ipad = project_yml_content.match?(/TARGETED_DEVICE_FAMILY:\s*["']?[^"\n]*\b2\b/)

      if screenshots_config.empty?
        puts '❌ not configured'
        issues << 'No screenshots configured in .saneprocess appstore.screenshots'
      else
        screenshot_issues = []
        screenshot_summary = []
        platforms.each do |platform|
          key = platform == 'ios' ? 'ios' : 'macos'
          glob_pattern = screenshots_config[key]
          if glob_pattern
            files = Dir.glob(File.join(Dir.pwd, glob_pattern))
            if files.any?
              screenshot_summary << "#{platform}: #{files.count}"

              # Validate screenshot dimensions for each device class
              if platform == 'ios'
                # Check for iPad-specific screenshots (not stretched iPhone images)
                ipad_globs = [
                  screenshots_config['ipad'],
                  screenshots_config['ipad_13'],
                  screenshots_config['ipad_12.9'],
                  screenshots_config['ipad_12_9'],
                  screenshots_config['ipad_11']
                ].compact

                if ios_supports_ipad && ipad_globs.empty?
                  screenshot_issues << 'iOS submission includes iPad but no iPad-specific screenshot glob configured — Apple rejects stretched iPhone screenshots on iPad'
                end

                if ios_supports_ipad && !ipad_globs.empty?
                  ipad_files = ipad_globs.flat_map { |glob| Dir.glob(File.join(Dir.pwd, glob)) }.uniq
                  if ipad_files.empty?
                    screenshot_issues << "No iPad screenshots found matching configured globs: #{ipad_globs.join(', ')}"
                  else
                    screenshot_summary << "ipad: #{ipad_files.count}"
                    ipad_files.each do |f|
                      dims, = Open3.capture2('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', f)
                      width = dims[/pixelWidth:\s*(\d+)/, 1].to_i
                      height = dims[/pixelHeight:\s*(\d+)/, 1].to_i
                      next if width.zero? || height.zero?

                      # iPad screenshots should be >= 1668 on shorter edge
                      if [width, height].min < 1668
                        screenshot_issues << "#{File.basename(f)} (#{width}x#{height}) appears too small for iPad screenshot requirements"
                      end
                    end
                  end
                end
              end
            else
              screenshot_issues << "No #{platform} screenshots found matching: #{glob_pattern}"
            end
          else
            screenshot_issues << "No screenshot glob for #{platform} in .saneprocess appstore.screenshots.#{key}"
          end
        end

        if screenshot_issues.empty?
          puts "✅ #{screenshot_summary.join(', ')}"
        else
          puts "❌ #{screenshot_issues.first}"
          screenshot_issues.each { |si| issues << si }
        end
      end

      # 3c. Contact info for review
      print '  │ Review contact... '
      contact = appstore_config['contact'] || {}
      if contact['name'] && contact['email'] && contact['phone']
        puts "✅ #{contact['name']}"
      else
        missing = []
        missing << 'name' unless contact['name']
        missing << 'email' unless contact['email']
        missing << 'phone' unless contact['phone']
        puts "❌ missing: #{missing.join(', ')}"
        issues << "Review contact info incomplete — add to .saneprocess appstore.contact"
      end

      puts '  │'

      # ═══════════════════════════════════════════
      # SECTION 4: Privacy & Permissions
      # ═══════════════════════════════════════════
      puts '  ├── Privacy & Permissions ──'

      # 4a. Info.plist usage descriptions
      print '  │ Usage descriptions... '
      # Check source code for permission-requiring APIs
      swift_files = Dir.glob('**/*.swift').reject { |p| p.include?('DerivedData') || p.include?('build/') || p.include?('Tests/') }
      all_source = swift_files.map { |f| File.read(f) rescue '' }.join("\n")

      required_keys = {}
      required_keys['NSAccessibilityUsageDescription'] = 'Accessibility' if all_source.match?(/AXUIElement|AXIsProcessTrusted|CGEvent\(keyboardEventSource:|CGEvent\.post\(tap:\s*\.cghidEventTap/)
      required_keys['NSCameraUsageDescription'] = 'Camera' if all_source.match?(/AVCaptureSession|AVCaptureDevice.*video/i)
      required_keys['NSMicrophoneUsageDescription'] = 'Microphone' if all_source.match?(/AVAudioSession|AVCaptureDevice.*audio/i)
      required_keys['NSPhotoLibraryUsageDescription'] = 'Photos' if all_source.match?(/PHPhotoLibrary|PHAsset/i)
      required_keys['NSLocationWhenInUseUsageDescription'] = 'Location' if all_source.match?(/CLLocationManager|CLGeocoder/)
      required_keys['NSAppleEventsUsageDescription'] = 'AppleEvents' if all_source.match?(/NSAppleScript|NSAppleEventManager|osascript/)
      required_keys['NSScreenCaptureUsageDescription'] = 'ScreenCapture' if all_source.match?(/SCShareableContent|SCContentSharingPicker|CGWindowListCreateImage/)

      # Check Info.plist for these keys
      plist_paths = Dir.glob('**/Info.plist').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      plist_content = plist_paths.map { |f| File.read(f) rescue '' }.join("\n")

      # Also check project.yml for plist values
      yml_content = File.exist?(project_yml) ? File.read(project_yml) : ''

      missing_keys = []
      required_keys.each do |key, api|
        unless plist_content.include?(key) || yml_content.include?(key)
          missing_keys << "#{key} (#{api})"
        end
      end

      if missing_keys.empty?
        if required_keys.any?
          puts "✅ #{required_keys.count} permission(s) declared"
        else
          puts '✅ no permissions detected'
        end
      else
        puts "❌ #{missing_keys.count} missing"
        missing_keys.each do |k|
          puts "  │   - #{k}"
        end
        issues << "Missing Info.plist usage descriptions: #{missing_keys.join(', ')}"
      end

      # 4b. Privacy policy URL
      print '  │ Privacy policy URL... '
      privacy_url = appstore_config['privacy_policy_url'] || config.dig('website_domain')
      if appstore_config['privacy_policy_url']
        puts "✅ #{appstore_config['privacy_policy_url']}"
      elsif config['website_domain']
        puts "⚠️  not explicit — using https://#{config['website_domain']}/privacy"
        warnings << "No explicit privacy_policy_url in .saneprocess — Apple requires this in metadata"
      else
        puts '❌ missing'
        issues << 'No privacy policy URL — required for all App Store submissions'
      end

      # 4c. Support URL
      print '  │ Support URL... '
      support_url = appstore_config['support_url']
      if support_url
        puts "✅ #{support_url}"
      elsif config['website_domain']
        puts "⚠️  not explicit — assuming https://#{config['website_domain']}/support"
        warnings << "No explicit support_url in .saneprocess — Apple requires this"
      else
        puts '❌ missing'
        issues << 'No support URL — required for App Store'
      end

      puts '  │'

      # ═══════════════════════════════════════════
      # SECTION 5: Technical Requirements
      # ═══════════════════════════════════════════
      puts '  ├── Technical Requirements ──'

      # 5a. Tests pass (shared with release_preflight)
      print '  │ Tests... '
      verify_env = { 'SANEMASTER_APPSTORE_PREFLIGHT' => '1' }
      out, status = Open3.capture2e(verify_env, './scripts/SaneMaster.rb', 'verify', '--quiet')
      if status.success?
        puts '✅'
      elsif out.include?('Newest appcast entry should match MARKETING_VERSION') &&
            out.scan('Expectation failed:').length == 1
        puts '⚠️  appcast/version drift'
        warnings << 'Direct-download appcast is one version behind MARKETING_VERSION (non-blocking for App Store submission)'
      elsif appcast_drift_failure_only?(out)
        puts '⚠️  appcast/version drift'
        warnings << 'Direct-download appcast is one version behind MARKETING_VERSION (non-blocking for App Store submission)'
      else
        puts '❌ FAIL'
        issues << 'Tests failing — fix before submission'
      end

      # 5b. Git clean
      print '  │ Git clean... '
      dirty, = Open3.capture2('git', 'status', '--porcelain')
      dirty = dirty.strip
      if dirty.empty?
        puts '✅'
      else
        puts "⚠️  #{dirty.lines.count} uncommitted changes"
        warnings << "#{dirty.lines.count} uncommitted files"
      end

      # 5c. App Store build configuration exists
      print '  │ App Store build config... '
      asc_config_name = appstore_config['configuration']
      if asc_config_name
        # Check project.yml for this configuration
        if File.exist?(project_yml)
          yml = File.read(project_yml)
          if yml.include?(asc_config_name)
            puts "✅ #{asc_config_name}"
          else
            puts "❌ #{asc_config_name} not found in project.yml"
            issues << "Build configuration '#{asc_config_name}' referenced in .saneprocess but not in project.yml"
          end
        else
          puts "⚠️  #{asc_config_name} (can't verify — no project.yml)"
          warnings << "Can't verify build configuration without project.yml"
        end
      else
        puts '⚠️  not specified'
        warnings << 'No appstore.configuration in .saneprocess — using default Release config?'
      end

      # 5d. StoreKit product ID routing for App Store unlock flow
      print '  │ StoreKit product ID routing... '
      uses_storekit_unlock = all_source.match?(/\bLicenseService\s*\(/)
      configured_product_id = appstore_config['product_id'].to_s.strip
      pbxproj_content = Dir.glob('*.xcodeproj/project.pbxproj').map { |p| File.read(p) rescue '' }.join("\n")
      has_product_id_marker = [project_yml_content, plist_content, pbxproj_content].join("\n").match?(/AppStoreProductID|INFOPLIST_KEY_AppStoreProductID/)

      if uses_storekit_unlock
        if configured_product_id.empty?
          puts '❌ missing appstore.product_id'
          issues << 'StoreKit unlock flow detected, but .saneprocess is missing appstore.product_id'
        else
          puts "✅ #{configured_product_id}"
          unless has_product_id_marker
            warnings << 'AppStoreProductID marker not found in project settings — relying on preflight/release build-flag injection'
          end
        end
      elsif configured_product_id.empty?
        puts '⚠️  not set (no StoreKit unlock detected)'
        warnings << 'No appstore.product_id configured'
      elsif has_product_id_marker
        puts "✅ #{configured_product_id}"
      else
        puts '⚠️  set but not wired'
        warnings << 'appstore.product_id is set, but AppStoreProductID marker not found in project settings'
      end

      # 5e. Build App Store config and audit resulting artifact for runtime blockers
      print '  │ Compiled App Store artifact audit... '
      platforms = Array(appstore_config['platforms'] || ['macos']).map(&:to_s)
      if platforms.include?('macos')
        begin
          Dir.mktmpdir('sanemaster_asc_audit') do |tmpdir|
            derived_data = File.join(tmpdir, 'DerivedData')
            configuration = (asc_config_name || appstore_config['configuration'] || 'Release-AppStore').to_s
            scheme = (appstore_config['scheme'] || config['scheme'] || app_name).to_s
            workspace = config['workspace']
            project = config['project'] || Dir.glob('*.xcodeproj').first

            build_cmd = ['xcodebuild']
            if workspace && File.exist?(workspace)
              build_cmd += ['-workspace', workspace]
            elsif project && File.exist?(project)
              build_cmd += ['-project', project]
            else
              puts '❌ project/workspace not found'
              issues << 'Cannot run compiled App Store artifact audit: missing workspace/project path'
              break
            end
            build_cmd += [
              '-scheme', scheme,
              '-configuration', configuration,
              '-destination', 'platform=macOS',
              '-derivedDataPath', derived_data,
              'CODE_SIGNING_ALLOWED=NO',
              'build'
            ]
            unless configured_product_id.empty?
              build_cmd << "INFOPLIST_KEY_AppStoreProductID=#{configured_product_id}"
            end

            build_out, build_status = Open3.capture2e(*build_cmd)
            unless build_status.success?
              puts '❌ build failed'
              issues << "App Store artifact audit build failed for configuration #{configuration}"
              next
            end

            app_dir = Dir.glob(File.join(derived_data, 'Build', 'Products', configuration, '*.app'))
              .reject { |p| p.include?('.appex/') }.first
            if app_dir.nil?
              puts '❌ built app missing'
              issues << "App Store artifact audit could not find built .app under #{configuration}"
              next
            end

            info_plist = File.join(app_dir, 'Contents', 'Info.plist')
            executable, = Open3.capture2('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleExecutable', info_plist)
            executable = executable.to_s.strip
            binary_path = File.join(app_dir, 'Contents', 'MacOS', executable)

            built_product_id, = Open3.capture2('/usr/libexec/PlistBuddy', '-c', 'Print :AppStoreProductID', info_plist)
            built_product_id = built_product_id.to_s.strip
            if uses_storekit_unlock
              if built_product_id.empty?
                issues << 'Built App Store artifact is missing Info.plist key AppStoreProductID (StoreKit unlock flow detected)'
              elsif !configured_product_id.empty? && built_product_id != configured_product_id
                issues << "Built AppStoreProductID mismatch (expected #{configured_product_id}, got #{built_product_id})"
              end
            end

            if File.file?(binary_path)
              otool_out, = Open3.capture2('otool', '-L', binary_path)
              dylib_lines = otool_out.lines.drop(1).map(&:strip).reject(&:empty?)
              unresolved = []

              dylib_lines.each do |line|
                lib = line.split(' (').first.to_s.strip
                next unless lib.start_with?('@rpath/')
                next if line.include?(', weak)')

                rel = lib.sub('@rpath/', '')
                candidate = File.join(app_dir, 'Contents', 'Frameworks', rel)
                unresolved << lib unless File.exist?(candidate)
              end

              sparkle_framework = File.join(app_dir, 'Contents', 'Frameworks', 'Sparkle.framework')
              sparkle_ref = dylib_lines.find { |line| line.include?('@rpath/Sparkle.framework') }
              if sparkle_ref && !sparkle_ref.include?(', weak)') && !File.exist?(sparkle_framework)
                unresolved << '@rpath/Sparkle.framework/Versions/B/Sparkle'
              end

              if unresolved.any?
                puts "❌ unresolved dylibs (#{unresolved.uniq.count})"
                issues << "App Store artifact has unresolved non-weak dylib references: #{unresolved.uniq.join(', ')}"
              else
                puts '✅'
              end
            else
              puts '❌ executable missing'
              issues << 'App Store artifact audit could not find app executable'
            end
          end
        rescue StandardError => e
          puts "⚠️  audit error: #{e.message}"
          warnings << "Compiled App Store artifact audit failed unexpectedly: #{e.message}"
        end
      else
        puts '⏭️  skipped (non-macOS submission)'
      end

      # 5f. No DEBUG/development code leaking into release
      print '  │ Debug code audit... '
      debug_patterns = swift_files.select do |f|
        content = File.read(f) rescue ''
        content.match?(/#if\s+DEBUG/) && content.match?(/print\(|NSLog\(|os_log/)
      end
      if debug_patterns.count > 5
        puts "⚠️  #{debug_patterns.count} files with #if DEBUG + logging"
        warnings << "#{debug_patterns.count} files have debug logging — verify it's gated"
      else
        puts '✅'
      end

      puts '  │'

      # ═══════════════════════════════════════════
      # SECTION 6: Review Preparation
      # ═══════════════════════════════════════════
      puts '  └── Review Preparation ──'

      # 6a. Review notes — must explain EACH permission with technical justification
      print '    Review notes... '
      review_notes = appstore_config['review_notes']
      if review_notes && !review_notes.to_s.strip.empty?
        notes_text = review_notes.to_s
        notes_issues = []

        # Verify each permission-requiring API has a specific explanation in the notes
        permission_keywords = {
          'NSAccessibilityUsageDescription' => {
            name: 'Accessibility',
            required_terms: %w[CGEvent AXIsProcessTrusted paste keystroke keyboard],
            guidance: 'Must explain WHAT specific feature uses Accessibility and HOW (e.g. CGEvent paste simulation). Generic "clipboard monitoring" is NOT sufficient — Apple will reject with Guideline 2.1'
          },
          'NSCameraUsageDescription' => {
            name: 'Camera',
            required_terms: %w[camera capture photo video scan],
            guidance: 'Must explain what feature uses the camera and why'
          },
          'NSAppleEventsUsageDescription' => {
            name: 'AppleEvents',
            required_terms: %w[AppleScript automation scripting control],
            guidance: 'Must explain which app(s) are controlled and why'
          }
        }

        required_keys.each_key do |plist_key|
          check = permission_keywords[plist_key]
          next unless check

          has_explanation = check[:required_terms].any? { |term| notes_text.downcase.include?(term.downcase) }
          unless has_explanation
            notes_issues << "Review notes mention #{check[:name]} but lack technical detail — #{check[:guidance]}"
          end
        end

        if notes_issues.empty?
          puts "✅ (#{notes_text.length} chars, permissions explained)"
        else
          puts "❌ #{notes_issues.count} permission(s) not adequately explained"
          notes_issues.each do |ni|
            puts "    - #{ni}"
            issues << ni
          end
        end
      else
        # Check if app needs special explanation (e.g. Accessibility)
        needs_explanation = required_keys.key?('NSAccessibilityUsageDescription') ||
                            entitlements.any? { |e| (File.read(e) rescue '').include?('apple-events') }
        if needs_explanation
          puts '❌ missing (app uses Accessibility/AppleEvents — reviewer needs explanation)'
          issues << 'No review_notes in .saneprocess — apps using Accessibility MUST explain why to App Review. Must include: specific feature name, API used (e.g. CGEvent), and why it cannot work without the permission'
        else
          puts '⚠️  not set'
          warnings << 'No review_notes in .saneprocess — consider adding explanation for reviewers'
        end
      end

      # 6b. Category
      print '    App category... '
      category = appstore_config['category']
      if category
        puts "✅ #{category}"
      else
        puts '⚠️  not specified'
        warnings << 'No appstore.category in .saneprocess — must set in ASC'
      end

      # 6c. Age rating
      print '    Age rating... '
      age_rating = appstore_config['age_rating']
      if age_rating
        puts "✅ #{age_rating}"
      else
        puts '⚠️  not specified'
        warnings << 'No appstore.age_rating in .saneprocess — defaults to 4+ in ASC'
      end

      # ═══════════════════════════════════════════
      # Summary
      # ═══════════════════════════════════════════
      puts ''
      puts '═' * 55
      puts "  APP STORE PREFLIGHT: #{app_name}"
      puts '═' * 55
      if issues.any?
        puts ''
        puts "  ❌ BLOCKED: #{issues.count} issue(s) must be fixed"
        issues.each_with_index { |i, idx| puts "     #{idx + 1}. #{i}" }
      end
      if warnings.any?
        puts ''
        puts "  ⚠️  #{warnings.count} warning(s) to review:"
        warnings.each_with_index { |w, idx| puts "     #{idx + 1}. #{w}" }
      end
      puts ''
      if issues.empty? && warnings.empty?
        puts '  ✅ ALL CLEAR — ready for App Store submission'
      elsif issues.empty?
        puts '  🟡 REVIEW WARNINGS — then proceed with submission'
      else
        puts '  🔴 FIX ISSUES ABOVE before submitting'
      end
      puts '═' * 55

      exit 1 if issues.any?
    end
  end
end
