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

    def safe_read(path)
      File.read(path)
    rescue StandardError
      ''
    end

    def project_marketing_version(project_yml_content)
      version = project_yml_content[/MARKETING_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip
      return version unless version.empty?

      Dir.glob('**/Config/*.xcconfig').reject { |p| p.include?('DerivedData') }.each do |xcf|
        match = safe_read(xcf).match(/MARKETING_VERSION\s*=\s*(.+)/)
        return match[1].strip if match
      end
      ''
    end

    def compare_semver(left, right)
      return nil if left.to_s.strip.empty? || right.to_s.strip.empty?

      l_parts = left.to_s.strip.split('.').map { |p| p.to_i }
      r_parts = right.to_s.strip.split('.').map { |p| p.to_i }
      max_len = [l_parts.length, r_parts.length, 3].max
      l_parts += [0] * (max_len - l_parts.length)
      r_parts += [0] * (max_len - r_parts.length)
      l_parts <=> r_parts
    rescue StandardError
      nil
    end

    def parse_latest_appcast_item(xml)
      item = xml.to_s.match(/<item>.*?<\/item>/m)&.[](0).to_s
      item = xml.to_s if item.empty?

      version = item[/<sparkle:shortVersionString>\s*([^<\s]+)\s*<\/sparkle:shortVersionString>/m, 1] ||
                item[/sparkle:shortVersionString="([^"]+)"/, 1]
      build = item[/<sparkle:version>\s*([^<\s]+)\s*<\/sparkle:version>/m, 1] ||
              item[/sparkle:version="([^"]+)"/, 1]
      enclosure = item[/<enclosure\b[^>]*>/m, 0].to_s
      url = enclosure[/\burl="([^"]+)"/, 1]

      {
        version: version.to_s.strip,
        build: build.to_s.strip,
        url: url.to_s.strip
      }
    rescue StandardError
      { version: '', build: '', url: '' }
    end

    def local_appcast_paths
      [
        File.join(Dir.pwd, 'docs', 'appcast.xml'),
        File.join(Dir.pwd, 'website', 'appcast.xml')
      ].select { |path| File.exist?(path) }
    end

    def local_appcast_versions
      local_appcast_paths.each_with_object({}) do |path, acc|
        acc[path] = parse_latest_appcast_item(safe_read(path))[:version]
      end
    end

    def archive_bundle_versions(zip_url:, app_name:)
      return nil if zip_url.to_s.strip.empty?

      Dir.mktmpdir("sanemaster-preflight-#{app_name}-") do |tmpdir|
        zip_path = File.join(tmpdir, 'dist.zip')
        unpack_dir = File.join(tmpdir, 'unpacked')

        _curl_out, curl_status = Open3.capture2e('curl', '-fsSL', zip_url, '-o', zip_path)
        return nil unless curl_status.success? && File.exist?(zip_path)

        _unzip_out, unzip_status = Open3.capture2e('ditto', '-x', '-k', zip_path, unpack_dir)
        return nil unless unzip_status.success?

        app_bundle = Dir.glob(File.join(unpack_dir, '**', "#{app_name}.app")).first
        app_bundle ||= Dir.glob(File.join(unpack_dir, '**', '*.app')).first
        return nil unless app_bundle

        version, = Open3.capture2('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString', File.join(app_bundle, 'Contents/Info.plist'))
        build, = Open3.capture2('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleVersion', File.join(app_bundle, 'Contents/Info.plist'))
        {
          version: version.to_s.strip,
          build: build.to_s.strip
        }
      end
    rescue StandardError
      nil
    end

    def monetization_source_blob(swift_files:)
      app_source = swift_files.map { |f| safe_read(f) }.join("\n")
      return app_source unless app_source.include?('import SaneUI')

      saneui_root = File.expand_path('~/SaneApps/infra/SaneUI/Sources/SaneUI')
      return app_source unless Dir.exist?(saneui_root)

      saneui_source = Dir.glob(File.join(saneui_root, '**/*.swift')).map { |f| safe_read(f) }.join("\n")
      [app_source, saneui_source].join("\n")
    end

    def monetization_guardrail_report(source_blob:, configured_product_id:, has_product_id_marker:, strict_appstore_product_id:)
      report = { applicable: false, issues: [], warnings: [], summary: '' }
      uses_license_service = source_blob.match?(/\bLicenseService\b/)
      return report unless uses_license_service || !configured_product_id.to_s.strip.empty?

      report[:applicable] = true
      gate_hits = source_blob.scan(/\bisPro\b|\bisLicensed\b|\busesAppStorePurchase\b/).count
      has_runtime_gate = source_blob.match?(/guard\s+.*isPro|if\s+.*isPro|!isPro/)
      has_purchase_path = source_blob.match?(/\bpurchasePro\s*\(/) || source_blob.match?(/\bProduct\.purchase\s*\(/)
      has_restore_path = source_blob.match?(/\brestorePurchases\s*\(/) || source_blob.match?(/\bAppStore\.sync\s*\(/)
      has_upgrade_ui = source_blob.match?(/Unlock Pro|Pro feature|Upgrade|Restore Purchases|One-time unlock|Buy Now/i)
      has_checkout_fallback = source_blob.match?(/go\.saneapps\.com\/buy\//) || source_blob.match?(/\bcheckoutURL\b/)

      product_id = configured_product_id.to_s.strip
      if product_id.empty?
        if strict_appstore_product_id
          report[:issues] << 'appstore.product_id is missing — free App Store downloads would have no in-app Pro unlock target'
        else
          report[:warnings] << 'appstore.product_id not set — App Store IAP upgrade path will not be available'
        end
      elsif !has_product_id_marker
        report[:issues] << 'AppStoreProductID marker not found in plist/build settings'
      end

      report[:issues] << 'No in-app purchase path found (purchasePro/Product.purchase)' unless has_purchase_path
      report[:issues] << 'No restore purchases path found (restorePurchases/AppStore.sync)' unless has_restore_path
      report[:issues] << 'No unlock/upgrade UI copy detected' unless has_upgrade_ui
      report[:issues] << 'No effective runtime Pro feature gates detected (isPro/isLicensed checks)' if gate_hits < 6 || !has_runtime_gate
      report[:warnings] << 'No direct checkout fallback found for website builds' unless has_checkout_fallback

      report[:summary] = "gates=#{gate_hits}, purchase=#{has_purchase_path ? 'yes' : 'no'}, restore=#{has_restore_path ? 'yes' : 'no'}, checkout=#{has_checkout_fallback ? 'yes' : 'no'}"
      report
    end

    def metadata_value(hash, *keys)
      return nil unless hash.is_a?(Hash)

      keys.each do |key|
        key_str = key.to_s
        key_sym = key_str.to_sym
        value = hash.key?(key_str) ? hash[key_str] : hash[key_sym]
        next if value.nil?

        text = value.to_s.strip
        return text unless text.empty?
      end
      nil
    end

    def appstore_metadata_for_platform(appstore_config, platform)
      metadata_cfg = appstore_config['metadata'].is_a?(Hash) ? appstore_config['metadata'] : {}
      default_cfg = metadata_cfg['default'].is_a?(Hash) ? metadata_cfg['default'] : {}

      aliases =
        case platform.to_s.downcase
        when 'ios'
          %w[ios iphone ipad mobile]
        when 'macos'
          %w[macos mac macosx desktop]
        else
          [platform.to_s.downcase]
        end

      platform_cfg = {}
      aliases.each do |alias_key|
        candidate = metadata_cfg[alias_key]
        next unless candidate.is_a?(Hash)

        platform_cfg = candidate
        break
      end

      metadata = {
        subtitle: metadata_value(platform_cfg, 'subtitle') ||
                  metadata_value(default_cfg, 'subtitle') ||
                  metadata_value(appstore_config, 'subtitle'),
        promotional_text: metadata_value(platform_cfg, 'promotional_text', 'promotionalText') ||
                          metadata_value(default_cfg, 'promotional_text', 'promotionalText') ||
                          metadata_value(appstore_config, 'promotional_text', 'promotionalText'),
        description: metadata_value(platform_cfg, 'description') ||
                     metadata_value(default_cfg, 'description') ||
                     metadata_value(appstore_config, 'description'),
        keywords: metadata_value(platform_cfg, 'keywords') ||
                  metadata_value(default_cfg, 'keywords') ||
                  metadata_value(appstore_config, 'keywords')
      }

      [metadata, platform_cfg]
    end

    def appstore_listing_copy_audit(appstore_config:, platforms:, app_name:)
      issues = []
      warnings = []
      summaries = []

      fallback_description = "#{app_name} helps you stay productive on Apple devices with a clear free tier and a one-time Pro upgrade."
      placeholder_re = /\b(lorem ipsum|tbd|placeholder|coming soon|dummy text)\b/i
      review_style_re = /(does not request|does not simulate|to test:|frontmost app|cmd\+v|manually press|keyboard events)/i
      ios_macos_mismatch_re = /(menu bar|frontmost app|cmd\+v|cgEvent|accessibility)/i

      normalized_platforms = Array(platforms).map { |p| p.to_s.downcase }.uniq
      normalized_platforms = %w[macos] if normalized_platforms.empty?

      normalized_platforms.each do |platform|
        metadata, explicit_platform_cfg = appstore_metadata_for_platform(appstore_config, platform)

        missing_fields = metadata.select { |_k, v| v.nil? }.keys
        if missing_fields.any?
          warnings << "[#{platform}] Missing metadata fields in .saneprocess: #{missing_fields.join(', ')}"
        end

        unless explicit_platform_cfg.is_a?(Hash) && !explicit_platform_cfg.empty?
          warnings << "[#{platform}] No platform-specific metadata block found (appstore.metadata.#{platform}); fallback/default copy may leak into App Store listing"
        end

        description = metadata[:description].to_s
        promo = metadata[:promotional_text].to_s
        subtitle = metadata[:subtitle].to_s
        keywords = metadata[:keywords].to_s
        keyword_terms = keywords.split(',').map(&:strip).reject(&:empty?)

        if description.casecmp?(fallback_description)
          issues << "[#{platform}] Description is fallback boilerplate; set appstore.metadata.#{platform}.description"
        end

        if keywords.downcase == 'productivity,utility,mac'
          warnings << "[#{platform}] Keywords are generic fallback terms; replace with product-specific search terms"
        end

        if [description, promo, subtitle].any? { |text| text.match?(placeholder_re) }
          issues << "[#{platform}] Listing copy contains placeholder text (TBD/coming soon/lorem ipsum)"
        end

        if [description, promo].any? { |text| text.match?(review_style_re) }
          warnings << "[#{platform}] Listing copy reads like review notes/debug instructions; move that language to appstore.review_notes"
        end

        if !description.empty? && description.length < 140
          warnings << "[#{platform}] Description is short (#{description.length} chars); App Store copy usually converts better with clear feature detail"
        end

        if !promo.empty? && promo.length < 45
          warnings << "[#{platform}] Promotional text is short (#{promo.length} chars); tighten value proposition"
        end

        if !keywords.empty? && keyword_terms.length < 5
          warnings << "[#{platform}] Only #{keyword_terms.length} keyword term(s); target at least 5 focused terms"
        end

        if platform == 'ios' && [description, promo, subtitle].any? { |text| text.match?(ios_macos_mismatch_re) }
          issues << '[ios] Listing copy includes macOS-specific behavior (menu bar/Cmd+V/accessibility). Keep iOS listing focused on iPhone/iPad behavior.'
        end

        present_count = metadata.count { |_k, v| !v.nil? }
        summaries << "#{platform}: #{present_count}/4 fields"
      end

      {
        issues: issues.uniq,
        warnings: warnings.uniq,
        summary: summaries.join(', ')
      }
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
      require 'tmpdir'

      puts '🛫 --- [ RELEASE PREFLIGHT ] ---'
      puts "Project: #{Dir.pwd}"
      puts ''

      issues = []
      warnings = []
      saneprocess_path = File.join(Dir.pwd, '.saneprocess')
      preflight_app_name = if File.exist?(saneprocess_path)
                             match = safe_read(saneprocess_path).match(/^name:\s*(.+)/)
                             match ? match[1].strip : File.basename(Dir.pwd)
                           else
                             File.basename(Dir.pwd)
                           end

      # 1. Tests pass
      print '  Tests... '
      out, status = Open3.capture2e('./scripts/SaneMaster.rb', 'verify', '--quiet')
      if status.success?
        puts '✅'
      else
        puts '❌ FAIL'
        issues << 'Tests failing'
      end

      # 1a. Project QA guardrails (if project provides qa.rb)
      print '  Project QA guardrails... '
      qa_script = ['Scripts/qa.rb', 'scripts/qa.rb'].find { |path| File.exist?(path) }
      if qa_script
        app_name_for_env = begin
          manifest = File.join(Dir.pwd, '.saneprocess')
          if File.exist?(manifest)
            match = File.read(manifest).match(/^name:\s*(.+)$/)
            match ? match[1].strip : File.basename(Dir.pwd)
          else
            File.basename(Dir.pwd)
          end
        rescue StandardError
          File.basename(Dir.pwd)
        end

        app_prefix = app_name_for_env.upcase.gsub(/[^A-Z0-9]+/, '_')
        qa_env = {
          'LANG' => (ENV['LANG'].to_s.empty? ? 'en_US.UTF-8' : ENV['LANG']),
          'LC_ALL' => (ENV['LC_ALL'].to_s.empty? ? 'en_US.UTF-8' : ENV['LC_ALL']),
          'PATH' => ([ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin'].compact.join(':')),
          'SANEPROCESS_RELEASE_PREFLIGHT' => '1',
          'SANEPROCESS_RUN_STABILITY_SUITE' => '1',
          "#{app_prefix}_RELEASE_PREFLIGHT" => '1',
          "#{app_prefix}_RUN_STABILITY_SUITE" => '1',
        }
        qa_out, qa_status = Open3.capture2e(qa_env, 'ruby', qa_script)
        if qa_status.success?
          puts "✅ (#{qa_script})"
        else
          puts '❌ FAIL'
          warn_line = qa_out.to_s.lines.last(4).map(&:strip).reject(&:empty?).join(' | ')
          puts "    ↳ #{warn_line}" unless warn_line.empty?
          issues << "Project QA guardrails failed (#{qa_script})"
        end
      else
        puts '⏭️  skipped (no qa.rb)'
      end

      # 1b. Monetization guardrails (protect against accidental full-free releases)
      print '  Monetization guardrails... '
      project_yml_content = File.exist?('project.yml') ? safe_read('project.yml') : ''
      plist_content = Dir.glob('**/Info.plist').reject { |p| p.include?('DerivedData') || p.include?('build/') }.map { |p| safe_read(p) }.join("\n")
      pbxproj_content = Dir.glob('*.xcodeproj/project.pbxproj').map { |p| safe_read(p) }.join("\n")
      product_id = begin
        cfg = YAML.safe_load(safe_read('.saneprocess')) || {}
        (cfg.dig('appstore', 'product_id') || '').to_s
      rescue StandardError
        ''
      end
      has_product_id_marker = [project_yml_content, plist_content, pbxproj_content].join("\n").match?(/AppStoreProductID|INFOPLIST_KEY_AppStoreProductID/)
      swift_files = Dir.glob('**/*.swift').reject { |p| p.include?('DerivedData') || p.include?('build/') || p.include?('Tests/') }
      monetization = monetization_guardrail_report(
        source_blob: monetization_source_blob(swift_files: swift_files),
        configured_product_id: product_id,
        has_product_id_marker: has_product_id_marker,
        strict_appstore_product_id: false
      )
      if monetization[:applicable]
        if monetization[:issues].empty?
          puts "✅ #{monetization[:summary]}"
        else
          puts "❌ #{monetization[:issues].first}"
          monetization[:issues].each { |m| issues << "Monetization guard: #{m}" }
        end
        monetization[:warnings].each { |m| warnings << "Monetization guard: #{m}" }
      else
        puts '⏭️  skipped (no license/pro model detected)'
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

      # 4b. Appcast channel integrity (appcast metadata must match downloadable archive).
      print '  Appcast channel integrity... '
      appcast_path = local_appcast_paths.first
      if appcast_path.nil?
        puts '⏭️  no appcast.xml found'
      else
        appcast_versions = local_appcast_versions
        docs_appcast = File.join(Dir.pwd, 'docs', 'appcast.xml')
        website_appcast = File.join(Dir.pwd, 'website', 'appcast.xml')
        docs_version = appcast_versions[docs_appcast].to_s
        website_version = appcast_versions[website_appcast].to_s
        if !docs_version.empty? && !website_version.empty? && docs_version != website_version
          puts "❌ docs=#{docs_version}, website=#{website_version}"
          issues << "Appcast integrity: local drift between docs/appcast.xml (#{docs_version}) and website/appcast.xml (#{website_version})"
        end

        appcast_item = parse_latest_appcast_item(safe_read(appcast_path))
        appcast_version = appcast_item[:version]
        appcast_build = appcast_item[:build]
        appcast_url = appcast_item[:url]
        project_version = project_marketing_version(project_yml_content)

        gate_failures = []
        gate_warnings = []

        if appcast_version.empty?
          gate_failures << "Could not parse sparkle:shortVersionString from #{appcast_path}"
        end
        if appcast_url.empty?
          gate_failures << "Could not parse enclosure URL from #{appcast_path}"
        end

        version_cmp = compare_semver(appcast_version, project_version)
        if !project_version.empty? && !appcast_version.empty?
          if version_cmp == 1
            gate_failures << "Appcast version #{appcast_version} is newer than project MARKETING_VERSION #{project_version}"
          elsif version_cmp == -1
            gate_warnings << "Appcast version #{appcast_version} is older than project MARKETING_VERSION #{project_version} (expected before publish)"
          end
        end

        archive_versions = nil
        unless appcast_url.empty?
          archive_versions = archive_bundle_versions(zip_url: appcast_url, app_name: preflight_app_name)
          if archive_versions.nil?
            gate_failures << "Could not inspect downloadable archive at #{appcast_url}"
          else
            if !appcast_version.empty? && archive_versions[:version] != appcast_version
              gate_failures << "ZIP bundle version #{archive_versions[:version]} does not match appcast #{appcast_version}"
            end
            if !appcast_build.empty? && archive_versions[:build] != appcast_build
              gate_failures << "ZIP bundle build #{archive_versions[:build]} does not match appcast #{appcast_build}"
            end
          end
        end

        if gate_failures.any?
          puts "❌ #{gate_failures.first}"
          gate_failures.each { |msg| issues << "Appcast integrity: #{msg}" }
        elsif gate_warnings.any?
          puts "⚠️  #{gate_warnings.first}"
          gate_warnings.each { |msg| warnings << "Appcast integrity: #{msg}" }
        else
          puts "✅ v#{appcast_version} (#{appcast_build}) ↔ ZIP v#{archive_versions[:version]} (#{archive_versions[:build]})"
        end
      end

      # 5. Open GitHub issues + PRs
      print '  Open GitHub issues... '
      repo = "sane-apps/#{preflight_app_name || File.basename(Dir.pwd)}"
      tool_path = [ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin'].compact.join(':')
      gh_path, gh_status = Open3.capture2({ 'PATH' => tool_path }, 'bash', '-lc', 'command -v gh')
      gh_bin = if gh_status.success? && !gh_path.strip.empty?
                 gh_path.strip
               elsif File.executable?('/opt/homebrew/bin/gh')
                 '/opt/homebrew/bin/gh'
               elsif File.executable?('/usr/local/bin/gh')
                 '/usr/local/bin/gh'
               end
      if gh_bin
        issue_json, = Open3.capture2({ 'PATH' => tool_path }, gh_bin, 'issue', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
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
        pr_json, = Open3.capture2({ 'PATH' => tool_path }, gh_bin, 'pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
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

      # 8. Homebrew tap reachable + version match
      print '  Homebrew tap... '
      cask_app = preflight_app_name.downcase
      cask_url_base = "https://raw.githubusercontent.com/sane-apps/homebrew-tap/main/Casks/#{cask_app}.rb"
      cask_commit = nil
      commits_api = "https://api.github.com/repos/sane-apps/homebrew-tap/commits?path=Casks/#{cask_app}.rb&per_page=1"
      commits_json, commits_status = Open3.capture2('curl', '-fsSL', commits_api)
      if commits_status.success?
        commits = JSON.parse(commits_json) rescue []
        cask_commit = commits.first['sha'].to_s.strip if commits.is_a?(Array) && commits.first.is_a?(Hash)
      end
      cask_url = if cask_commit && !cask_commit.empty?
                   "https://raw.githubusercontent.com/sane-apps/homebrew-tap/#{cask_commit}/Casks/#{cask_app}.rb"
                 else
                   cask_url_base
                 end
      tap_status, = Open3.capture2('curl', '-sI', '-o', '/dev/null', '-w', '%{http_code}', cask_url)
      tap_status = tap_status.strip
      if tap_status == '200'
        cask_body, = Open3.capture2('curl', '-fsSL', cask_url)
        cask_version = cask_body[/version\s+"([^"]+)"/, 1].to_s.strip
        project_version = project_marketing_version(project_yml_content)
        if cask_version.empty?
          puts '⚠️  could not parse cask version'
          warnings << 'Homebrew cask version unreadable'
        elsif project_version.empty?
          puts "✅ reachable (v#{cask_version}, project version unknown)"
        elsif cask_version == project_version
          puts "✅ (v#{cask_version})"
        else
          puts "⚠️  cask has v#{cask_version}, project is v#{project_version}"
          warnings << "Homebrew cask version mismatch: cask=#{cask_version} project=#{project_version}"
        end
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

      # 10. Email webhook download version drift
      print '  Email webhook PRODUCT_CONFIG... '
      webhook_js = File.expand_path('~/SaneApps/infra/sane-email-automation/src/handlers/webhook-lemonsqueezy.js')
      if File.exist?(webhook_js)
        webhook_content = File.read(webhook_js)

        # Get version from appcast.xml (source of truth for what's actually released)
        appcast_paths = local_appcast_paths
        appcast_ver = nil
        appcast_paths.each do |ac|
          match = File.read(ac).match(/sparkle:shortVersionString[=>]+"?([^"<\s]+)/)
          appcast_ver = match[1] if match
          break if appcast_ver
        end

        # Get version from webhook
        webhook_match = webhook_content.match(/'#{Regexp.escape(preflight_app_name)}':\s*\{\s*file:\s*'#{Regexp.escape(preflight_app_name)}-([^']+)\.(zip|dmg)'/)
        webhook_ver = webhook_match ? webhook_match[1] : nil

        if appcast_ver && webhook_ver
          if appcast_ver == webhook_ver
            puts "✅ #{preflight_app_name} v#{webhook_ver}"
          else
            puts "❌ DRIFT: webhook=#{webhook_ver}, appcast=#{appcast_ver}"
            issues << "Email webhook sends #{preflight_app_name}-#{webhook_ver} but appcast is at #{appcast_ver} — new customers get old builds"
          end
        elsif appcast_ver && !webhook_ver
          puts "⚠️  #{preflight_app_name} not in webhook PRODUCT_CONFIG"
          warnings << "#{preflight_app_name} missing from email webhook PRODUCT_CONFIG"
        else
          puts '⏭️  no appcast.xml found'
        end
      else
        puts '⏭️  webhook file not found'
      end

      # 10b. Check if deployed Worker is stale vs git
      print '  Webhook Worker deploy freshness... '
      if File.exist?(webhook_js)
        webhook_dir = File.dirname(File.dirname(File.dirname(webhook_js)))
        wrangler_toml = File.join(webhook_dir, 'wrangler.toml')
        if File.exist?(wrangler_toml)
          # Get last git commit time on the webhook JS file
          last_commit_epoch, commit_status = Open3.capture2(
            'git', '-C', webhook_dir, 'log', '-1', '--format=%ct', '--', 'src/handlers/webhook-lemonsqueezy.js'
          )
          last_commit_epoch = last_commit_epoch.strip.to_i if commit_status.success?

          # Get latest wrangler deployment timestamp
          npx_bin = if File.executable?('/opt/homebrew/bin/npx')
                      '/opt/homebrew/bin/npx'
                    elsif File.executable?('/usr/local/bin/npx')
                      '/usr/local/bin/npx'
                    else
                      'npx'
                    end
          deploy_env = { 'PATH' => [ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin'].compact.join(':') }
          deploy_output, deploy_status = Open3.capture2(
            deploy_env,
            npx_bin, 'wrangler', 'deployments', 'list', '--config', wrangler_toml,
            chdir: webhook_dir
          )

          if deploy_status.success? && last_commit_epoch.to_i > 0
            # Parse the most recent deployment timestamp from wrangler output
            # Format varies but typically: "Created: 2026-03-01T12:00:00Z" or ISO date in the first entry
            deploy_dates = deploy_output.scan(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)/).flatten
            if deploy_dates.any?
              latest_deploy_time = deploy_dates
                .map { |ts| Time.parse(ts).to_i rescue 0 }
                .max.to_i
              if latest_deploy_time > 0 && last_commit_epoch > latest_deploy_time
                age_hours = ((last_commit_epoch - latest_deploy_time) / 3600.0).round(1)
                puts "⚠️  Worker stale by #{age_hours}h"
                warnings << "Email Worker not deployed — code committed #{age_hours}h after last deploy. Run: cd #{webhook_dir} && npx wrangler deploy --keep-vars"
              else
                puts '✅ Worker up to date'
              end
            else
              puts '⏭️  could not parse deploy timestamps'
            end
          else
            puts '⏭️  wrangler deployments list failed'
          end
        else
          puts '⏭️  no wrangler.toml found'
        end
      else
        puts '⏭️  webhook file not found'
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

      # 5e. Monetization guardrails (hard-fail for App Store submissions)
      print '  │ Monetization guardrails... '
      monetization_report = monetization_guardrail_report(
        source_blob: monetization_source_blob(swift_files: swift_files),
        configured_product_id: configured_product_id,
        has_product_id_marker: has_product_id_marker,
        strict_appstore_product_id: uses_storekit_unlock
      )
      if monetization_report[:applicable]
        if monetization_report[:issues].empty?
          puts "✅ #{monetization_report[:summary]}"
        else
          puts "❌ #{monetization_report[:issues].first}"
          monetization_report[:issues].each { |msg| issues << "Monetization guard: #{msg}" }
        end
        monetization_report[:warnings].each { |msg| warnings << "Monetization guard: #{msg}" }
      else
        puts '⏭️  skipped (no license/pro model detected)'
      end

      # 5f. Build App Store config and audit resulting artifact for runtime blockers
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

      # 5g. No DEBUG/development code leaking into release
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

      # 6d. Listing copy quality (metadata accuracy + conversion readiness)
      print '    Listing copy quality... '
      copy_audit = appstore_listing_copy_audit(
        appstore_config: appstore_config,
        platforms: platforms,
        app_name: app_name
      )
      if copy_audit[:issues].empty?
        puts "✅ #{copy_audit[:summary]}"
      else
        puts "❌ #{copy_audit[:issues].first}"
      end
      copy_audit[:issues].each { |msg| issues << msg }
      copy_audit[:warnings].each { |msg| warnings << msg }

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
