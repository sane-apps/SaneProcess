# frozen_string_literal: true

require 'fileutils'
require 'shellwords'
require 'net/http'
require 'tempfile'
require 'time'
require 'uri'
require 'yaml'
require 'json'
require 'open3'
require 'openssl'
require 'base64'

module SaneMasterModules
  # Unified release entrypoint (delegates to SaneProcess release.sh)
  module Release
    ENV_CACHE_FILE = File.expand_path(ENV.fetch('SANE_ENV_CACHE_FILE', '~/.config/nv/env'))

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
      content = File.binread(path)
      content.force_encoding(Encoding::UTF_8)
      return content if content.valid_encoding?

      content.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '?')
    rescue StandardError
      ''
    end

    def applescript_string_literal(text)
      text.to_s
          .gsub('\\', '\\\\')
          .gsub('"', '\"')
          .gsub("\r", "\\r")
          .gsub("\n", "\\n")
    end

    def plist_bool_true?(content, key)
      content.to_s.match?(%r{<key>#{Regexp.escape(key)}</key>\s*<true/>}m)
    end

    def plist_file_to_hash(path)
      return {} unless path && File.exist?(path)

      script = <<~'PY'
        import json
        import plistlib
        import sys

        with open(sys.argv[1], 'rb') as handle:
          print(json.dumps(plistlib.load(handle), default=str))
      PY
      out, status = Open3.capture2e('python3', '-c', script, path)
      return {} unless status.success?

      JSON.parse(out)
    rescue StandardError
      {}
    end

    def decode_mobileprovision(path)
      return nil unless path && File.exist?(path)

      Tempfile.create(['mobileprovision', '.plist']) do |plist_file|
        cms_out, cms_status = Open3.capture2e('security', 'cms', '-D', '-i', path)
        return nil unless cms_status.success?

        plist_file.write(cms_out)
        plist_file.flush

        script = <<~'PY'
          import base64
          import json
          import plistlib
          import sys

          with open(sys.argv[1], 'rb') as handle:
            payload = plistlib.load(handle)
          subset = {
            'Name': payload.get('Name'),
            'UUID': payload.get('UUID'),
            'CreationDate': payload.get('CreationDate'),
            'ExpirationDate': payload.get('ExpirationDate'),
            'Entitlements': payload.get('Entitlements', {}),
            'DeveloperCertificates': [
              base64.b64encode(cert).decode('ascii')
              for cert in payload.get('DeveloperCertificates', [])
              if cert
            ]
          }
          print(json.dumps(subset, default=str))
        PY
        json_out, json_status = Open3.capture2e('python3', '-c', script, plist_file.path)
        return nil unless json_status.success?

        payload = JSON.parse(json_out)
        certificates = Array(payload['DeveloperCertificates']).map do |encoded|
          next if encoded.to_s.empty?

          begin
            certificate = OpenSSL::X509::Certificate.new(Base64.decode64(encoded))
            common_name = certificate.subject.to_a.find { |item| item[0] == 'CN' }&.[](1).to_s
            {
              'CommonName' => common_name,
              'SHA1' => OpenSSL::Digest::SHA1.hexdigest(certificate.to_der).upcase
            }
          rescue OpenSSL::X509::CertificateError, ArgumentError
            nil
          end
        end.compact
        payload['DeveloperCertificates'] = certificates

        return payload
      end
    rescue StandardError
      nil
    end

    def installed_mobileprovision_by_name(profile_name, cache = {})
      return cache[profile_name] if cache.key?(profile_name)

      match = nil
      profile_paths = [
        File.expand_path('~/Library/MobileDevice/Provisioning Profiles/*.mobileprovision'),
        File.expand_path('~/Library/MobileDevice/Provisioning Profiles/*.provisionprofile'),
        File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision'),
        File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.provisionprofile')
      ].flat_map { |pattern| Dir.glob(pattern) }.uniq.sort

      profile_paths.each do |path|
        payload = decode_mobileprovision(path)
        next unless payload.is_a?(Hash)
        next unless payload['Name'].to_s == profile_name.to_s

        match = payload.merge('__path' => path)
        break
      end

      cache[profile_name] = match
    end

    def provisioning_profile_destination_roots
      {
        mobileprovision: File.expand_path('~/Library/MobileDevice/Provisioning Profiles'),
        provisionprofile: File.expand_path('~/Library/Developer/Xcode/UserData/Provisioning Profiles')
      }
    end

    def provisioning_profile_paths(destination_roots = provisioning_profile_destination_roots)
      patterns = [
        File.join(destination_roots[:mobileprovision].to_s, '*.{mobileprovision,provisionprofile}'),
        File.join(destination_roots[:provisionprofile].to_s, '*.{mobileprovision,provisionprofile}')
      ]

      patterns.flat_map { |pattern| Dir.glob(pattern, File::FNM_EXTGLOB) }.uniq.sort
    end

    def default_downloaded_provisioning_profiles
      [
        File.expand_path('~/Downloads/*.mobileprovision'),
        File.expand_path('~/Downloads/*.provisionprofile')
      ].flat_map { |pattern| Dir.glob(pattern) }.uniq.sort
    end

    def provisioning_profile_time(value)
      return nil if value.to_s.strip.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    def provisioning_profile_install_lockfile
      File.expand_path('~/.sanemaster/provisioning_profile_install.lock')
    end

    def with_provisioning_profile_install_lock
      lock_path = provisioning_profile_install_lockfile
      FileUtils.mkdir_p(File.dirname(lock_path))

      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock_file|
        lock_file.flock(File::LOCK_EX)
        yield
      ensure
        lock_file.flock(File::LOCK_UN)
      end
    end

    def canonicalize_provisioning_profile_inputs(paths)
      candidates = Array(paths).each_with_object([]) do |path, acc|
        expanded = File.expand_path(path.to_s)
        next unless File.file?(expanded)

        ext = File.extname(expanded).downcase
        next unless %w[.mobileprovision .provisionprofile].include?(ext)

        payload = decode_mobileprovision(expanded)
        next unless payload.is_a?(Hash)

        acc << {
          path: expanded,
          ext: ext,
          payload: payload,
          name: payload['Name'].to_s,
          uuid: payload['UUID'].to_s,
          creation_time: provisioning_profile_time(payload['CreationDate']),
          expiration_time: provisioning_profile_time(payload['ExpirationDate']),
          mtime: File.mtime(expanded)
        }
      end

      chosen = []
      skipped = []

      candidates.group_by { |candidate| candidate[:name].to_s }.each_value do |group|
        app_store_group = group.any? { |candidate| candidate[:name].to_s.include?('App Store') }
        winner = group.max_by do |candidate|
          [
            provisioning_profile_distribution_rank(candidate, app_store_group: app_store_group),
            candidate[:expiration_time] || Time.at(0),
            candidate[:creation_time] || Time.at(0),
            candidate[:mtime],
            candidate[:uuid],
            candidate[:path]
          ]
        end
        chosen << winner
        skipped.concat(group - [winner])
      end

      {
        chosen: chosen.sort_by { |candidate| candidate[:path] },
        skipped: skipped.sort_by { |candidate| candidate[:path] }
      }
    end

    def provisioning_profile_distribution_rank(candidate, app_store_group: false)
      return 0 unless app_store_group

      names = Array(candidate.dig(:payload, 'DeveloperCertificates')).map { |cert| cert['CommonName'].to_s }
      return 2 if names.any? { |name| name.include?('Apple Distribution:') }
      return 1 if names.any? { |name| name.include?('3rd Party Mac Developer Application:') }

      0
    end

    def install_provisioning_profiles(paths, remove_source: false, destination_roots: provisioning_profile_destination_roots)
      with_provisioning_profile_install_lock do
        selection = canonicalize_provisioning_profile_inputs(paths)
        results = selection[:skipped].map do |candidate|
          removed_source = false
          if remove_source
            FileUtils.rm_f(candidate[:path])
            removed_source = !File.exist?(candidate[:path])
          end
          {
            path: candidate[:path],
            name: candidate[:name],
            uuid: candidate[:uuid],
            destination: nil,
            removed_existing: [],
            ok: true,
            skipped: true,
            reason: 'older duplicate download',
            removed_source: removed_source
          }
        end

        selection[:chosen].each do |candidate|
          destination_root = candidate[:ext] == '.provisionprofile' ? destination_roots[:provisionprofile] : destination_roots[:mobileprovision]
          removed_existing = []

          begin
            FileUtils.mkdir_p(destination_root)
            existing_matches = provisioning_profile_paths(destination_roots).select do |existing_path|
              next false if File.expand_path(existing_path) == candidate[:path]

              existing_payload = decode_mobileprovision(existing_path)
              next false unless existing_payload.is_a?(Hash)

              existing_uuid = existing_payload['UUID'].to_s
              existing_name = existing_payload['Name'].to_s
              existing_uuid == candidate[:uuid] || (!candidate[:name].empty? && existing_name == candidate[:name])
            end

            existing_matches.each do |existing_path|
              FileUtils.rm_f(existing_path)
              removed_existing << existing_path
            end

            destination_path = File.join(destination_root, "#{candidate[:uuid]}#{candidate[:ext]}")
            FileUtils.cp(candidate[:path], destination_path)
            installed_payload = decode_mobileprovision(destination_path)
            unless installed_payload.is_a?(Hash) && installed_payload['UUID'].to_s == candidate[:uuid]
              raise "verification failed for #{destination_path}"
            end

            FileUtils.rm_f(candidate[:path]) if remove_source && File.expand_path(candidate[:path]) != File.expand_path(destination_path)

            results << {
              path: candidate[:path],
              name: candidate[:name],
              uuid: candidate[:uuid],
              destination: destination_path,
              removed_existing: removed_existing,
              ok: true,
              skipped: false,
              reason: nil,
              removed_source: remove_source && !File.exist?(candidate[:path])
            }
          rescue StandardError => e
            results << {
              path: candidate[:path],
              name: candidate[:name],
              uuid: candidate[:uuid],
              destination: nil,
              removed_existing: removed_existing,
              ok: false,
              skipped: false,
              reason: e.message,
              removed_source: false
            }
          end
        end

        results
      end
    end

    def install_provisioning_profiles_command(args)
      remove_source = args.delete('--delete-source')
      requested_paths = if args.empty?
                          default_downloaded_provisioning_profiles
                        else
                          args.flat_map { |arg| Dir.glob(File.expand_path(arg)) }.uniq.sort
                        end

      filtered_paths = requested_paths.select do |path|
        File.file?(path) && %w[.mobileprovision .provisionprofile].include?(File.extname(path).downcase)
      end

      if filtered_paths.empty?
        puts 'No provisioning profiles found.'
        return
      end

      results = install_provisioning_profiles(filtered_paths, remove_source: remove_source)
      failures = results.reject { |result| result[:ok] }

      results.each do |result|
        if result[:skipped]
          removed_suffix = result[:removed_source] ? ' | source removed' : ''
          puts "⏭️  #{result[:name]} (#{File.basename(result[:path])}) skipped: #{result[:reason]}#{removed_suffix}"
          next
        end

        if result[:ok]
          removed = result[:removed_existing].map { |path| File.basename(path) }
          removed_suffix = removed.empty? ? '' : " | removed: #{removed.join(', ')}"
          source_suffix = result[:removed_source] ? ' | source removed' : ''
          puts "✅ #{result[:name]} -> #{result[:destination]}#{removed_suffix}#{source_suffix}"
        else
          puts "❌ #{result[:name]} (#{File.basename(result[:path])}) failed: #{result[:reason]}"
        end
      end

      raise SystemExit, 1 unless failures.empty?
    end

    def appstore_mobile_signing_targets(project_yml_path)
      return [] unless project_yml_path && File.exist?(project_yml_path)

      project = YAML.safe_load(File.read(project_yml_path)) || {}
      targets = project['targets'] || {}
      project_root = File.dirname(project_yml_path)

      targets.each_with_object([]) do |(name, spec), list|
        next unless spec.is_a?(Hash)

        platform = spec['platform'].to_s
        next unless %w[iOS watchOS].include?(platform)

        release_appstore = spec.dig('settings', 'configs', 'Release-AppStore') || {}
        next if release_appstore.empty?

        groups = Array(spec.dig('entitlements', 'properties', 'com.apple.security.application-groups')).map(&:to_s)
        entitlements_path = spec.dig('entitlements', 'path')
        if entitlements_path
          entitlements_hash = plist_file_to_hash(File.join(project_root, entitlements_path))
          file_groups = Array(entitlements_hash['com.apple.security.application-groups']).map(&:to_s)
          groups = file_groups unless file_groups.empty?
        end

        list << {
          name: name,
          platform: platform,
          bundle_id: release_appstore['PRODUCT_BUNDLE_IDENTIFIER'] || spec['bundleId'],
          code_sign_style: release_appstore['CODE_SIGN_STYLE'].to_s,
          code_sign_identity: release_appstore['CODE_SIGN_IDENTITY'].to_s,
          provisioning_profile: release_appstore['PROVISIONING_PROFILE_SPECIFIER'].to_s,
          app_groups: groups.reject(&:empty?)
        }
      end
    rescue StandardError
      []
    end

    def appstore_macos_signing_targets(project_yml_path)
      return [] unless project_yml_path && File.exist?(project_yml_path)

      project = YAML.safe_load(File.read(project_yml_path)) || {}
      targets = project['targets'] || {}
      results = []

      targets.each do |name, spec|
        next unless spec.is_a?(Hash)
        next unless spec['platform'].to_s == 'macOS'
        next if spec['type'].to_s.start_with?('bundle.')

        release_appstore = spec.dig('settings', 'configs', 'Release-AppStore') || {}
        next if release_appstore.empty?

        results << {
          name: name,
          bundle_id: release_appstore['PRODUCT_BUNDLE_IDENTIFIER'] || spec['bundleId'],
          code_sign_style: release_appstore['CODE_SIGN_STYLE'].to_s,
          code_sign_identity: release_appstore['CODE_SIGN_IDENTITY'].to_s,
          provisioning_profile: release_appstore['PROVISIONING_PROFILE_SPECIFIER'].to_s
        }
      end

      results
    rescue StandardError
      []
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

    def project_build_number(project_yml_content)
      build = project_yml_content[/CURRENT_PROJECT_VERSION:\s*"?([^"\s]+)"?/, 1].to_s.strip
      return build unless build.empty?

      Dir.glob('**/Config/*.xcconfig').reject { |p| p.include?('DerivedData') }.each do |xcf|
        match = safe_read(xcf).match(/CURRENT_PROJECT_VERSION\s*=\s*(.+)/)
        return match[1].strip if match
      end
      ''
    end

    def macos_release_target_config(project_yml_path = 'project.yml')
      return {} unless File.exist?(project_yml_path)

      config = YAML.safe_load(File.read(project_yml_path)) || {}
      targets = config['targets'].is_a?(Hash) ? config['targets'] : {}
      _target_name, target_config = targets.find do |_name, target|
        target.is_a?(Hash) &&
          target['type'].to_s == 'application' &&
          target['platform'].to_s.downcase == 'macos'
      end
      return {} unless target_config.is_a?(Hash)

      release_config = target_config.dig('settings', 'configs', 'Release')

      {
        bundle_id: target_config['bundleId'].to_s,
        info_path: target_config.dig('info', 'path').to_s,
        entitlements_path: release_config.is_a?(Hash) ? release_config['CODE_SIGN_ENTITLEMENTS'].to_s : ''
      }
    rescue StandardError
      {}
    end

    def shared_or_package_app_store_branch?(swift_files:)
      package_files = swift_files.select do |path|
        path.include?('/Sources/') || path.include?('Package/Sources/')
      end

      package_branch = package_files.any? { |path| safe_read(path).match?(/^\s*#if\s+!?APP_STORE\b/m) }
      return true if package_branch

      saneui_root = File.expand_path('~/SaneApps/infra/SaneUI/Sources/SaneUI')
      return false unless Dir.exist?(saneui_root)

      Dir.glob(File.join(saneui_root, '**/*.swift')).any? do |path|
        safe_read(path).match?(/^\s*#if\s+!?APP_STORE\b/m)
      end
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

    def informational_appcast_entries_missing_links(xml)
      xml.to_s.scan(/<item\b.*?<\/item>/m).each_with_object([]) do |item, acc|
        next unless item.include?('<sparkle:informationalUpdate')
        next unless item.match?(/<enclosure\b/m)

        item_link = item[/<link>\s*([^<]+)\s*<\/link>/m, 1].to_s.strip
        next unless item_link.empty?

        version = item[/<sparkle:shortVersionString>\s*([^<\s]+)\s*<\/sparkle:shortVersionString>/m, 1] ||
                  item[/sparkle:shortVersionString="([^"]+)"/, 1] ||
                  item[/<title>\s*([^<]+)\s*<\/title>/m, 1]
        acc << (version.to_s.strip.empty? ? '<unknown version>' : version.to_s.strip)
      end
    rescue StandardError
      []
    end

    def informational_appcast_entries_mismatched_constraint_versions(xml)
      xml.to_s.scan(/<item\b.*?<\/item>/m).each_with_object([]) do |item, acc|
        next unless item.include?('<sparkle:informationalUpdate')

        item_build = item[/<sparkle:version>\s*([^<\s]+)\s*<\/sparkle:version>/m, 1] ||
                     item[/sparkle:version="([^"]+)"/, 1]
        next unless item_build.to_s.match?(/\A\d+\z/)

        constraints = item.scan(/<sparkle:(?:version|belowVersion)>\s*([^<\s]+)\s*<\/sparkle:(?:version|belowVersion)>/m).flatten
        next if constraints.empty?
        next unless constraints.any? { |constraint| constraint.include?('.') }

        version = item[/<sparkle:shortVersionString>\s*([^<\s]+)\s*<\/sparkle:shortVersionString>/m, 1] ||
                  item[/sparkle:shortVersionString="([^"]+)"/, 1] ||
                  item[/<title>\s*([^<]+)\s*<\/title>/m, 1]
        acc << (version.to_s.strip.empty? ? '<unknown version>' : version.to_s.strip)
      end
    rescue StandardError
      []
    end

    def verify_output_indicates_failure?(output)
      text = output.to_s
      return true if text.match?(/\*\* TEST FAILED \*\*/)
      return true if text.match?(/\*\* BUILD FAILED \*\*/)
      return true if text.match?(/error:\s+-\[[^\]]+\]/)
      return true if text.match?(/Executed \d+ tests?, with [1-9]\d* failures?/)
      return true if text.match?(/Executed \d+ tests?, with \d+ failures?, with [1-9]\d* unexpected/)

      false
    end

    def verify_output_indicates_success?(output)
      text = output.to_s
      return true if text.include?('clean pass despite a non-zero runner exit')
      return true if text.include?('Test log shows a clean pass despite a non-zero runner exit; treating verify as successful.')
      return false if verify_output_indicates_failure?(text)

      return true if text.include?('✅ Tests passed!')
      return true if text.match?(/Swift Testing:\s+\d+ tests .* passed/)
      return true if text.match?(/Test run with \d+ tests? in \d+ suites? passed/)
      return true if text.match?(/Test Suite 'All tests' passed/)

      false
    end

    def verify_output_indicates_runtime_dedupe_cleanup?(output, app_name: nil)
      text = output.to_s
      return false if verify_output_indicates_failure?(text)

      app_pattern = if app_name.to_s.strip.empty?
                      '[^/]+'
                    else
                      Regexp.escape(app_name.to_s.strip)
                    end
      text.match?(%r{canonical:\s+/Applications/#{app_pattern}\.app}) &&
        text.match?(/trashed:\s+[1-9]\d*/) &&
        (text.include?('Refreshing Launch Services') || text.include?('Trashing '))
    end

    def summarized_output_tail(output, lines: 4)
      text = output.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
      text.lines.last(lines).map(&:strip).reject(&:empty?).join(' | ')
    rescue StandardError
      ''
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

    def monetization_guardrail_report(source_blob:, configured_product_id:, has_product_id_marker:, strict_appstore_product_id:, shared_or_package_branch:)
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
        if strict_appstore_product_id
          report[:issues] << 'AppStoreProductID marker not found in plist/build settings'
        else
          report[:warnings] << 'AppStoreProductID marker not found in plist/build settings'
        end
      end

      report[:issues] << 'No in-app purchase path found (purchasePro/Product.purchase)' unless has_purchase_path
      report[:issues] << 'No restore purchases path found (restorePurchases/AppStore.sync)' unless has_restore_path
      report[:issues] << 'No unlock/upgrade UI copy detected' unless has_upgrade_ui
      report[:issues] << 'No effective runtime Pro feature gates detected (isPro/isLicensed checks)' if gate_hits < 6 || !has_runtime_gate
      report[:warnings] << 'No direct checkout fallback found for website builds' unless has_checkout_fallback
      if shared_or_package_branch
        report[:warnings] << 'Shared/package source contains #if APP_STORE branches. Xcode app-target flags do not automatically propagate into Swift package targets; rely on runtime gates or package-level defines instead of assuming compile-time stripping.'
      end

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

    def mini_route_context_path
      File.join(Dir.pwd, '.sanemaster', 'mini_route_context.json')
    end

    def mini_route_context
      return @mini_route_context if defined?(@mini_route_context)

      @mini_route_context = begin
        path = mini_route_context_path
        if File.exist?(path)
          JSON.parse(safe_read(path))
        else
          nil
        end
      rescue StandardError
        nil
      end
    end

    def routed_workspace_context
      workspace = mini_route_context.is_a?(Hash) ? mini_route_context['workspace'] : nil
      workspace.is_a?(Hash) ? workspace : nil
    end

    def routed_webhook_context
      webhook = mini_route_context.is_a?(Hash) ? mini_route_context['webhook'] : nil
      webhook.is_a?(Hash) ? webhook : nil
    end

    def load_env_file(path)
      return unless File.file?(path)

      File.foreach(path) do |line|
        next if line.strip.empty? || line.lstrip.start_with?('#')

        text = line.sub(/\A\s*export\s+/, '').strip
        next unless text.include?('=')

        key, raw_value = text.split('=', 2)
        key = key.to_s.strip
        next if key.empty? || ENV.key?(key)

        value = raw_value.to_s.strip
        value = if value.start_with?('"') && value.end_with?('"') && value.length >= 2
                  value[1..-2]
                elsif value.start_with?("'") && value.end_with?("'") && value.length >= 2
                  value[1..-2]
                else
                  value
                end
        value = value.gsub(/\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
          ENV.fetch(Regexp.last_match(1) || Regexp.last_match(2), Regexp.last_match(0))
        end
        ENV[key] = value
      end
    end

    def load_default_env_files
      load_env_file(File.expand_path('~/.config/nv/env'))
      load_env_file(File.expand_path('~/.config/saneprocess/secrets.env'))
    end

    def keychain_fallback_enabled?
      ENV.fetch('SANE_NO_KEYCHAIN', '0') != '1' && ENV.fetch('SANE_KEYCHAIN_FALLBACK', '1') != '0'
    end

    def persist_secret_to_env_cache(value, *env_names)
      return if value.to_s.strip.empty?
      return if ENV.fetch('SANE_ENV_CACHE_WRITE', '1') == '0'

      names = env_names.flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
      return if names.empty?

      env_path = ENV_CACHE_FILE
      FileUtils.mkdir_p(File.dirname(env_path))
      lines = File.exist?(env_path) ? File.readlines(env_path, chomp: true) : []
      filtered = lines.reject do |line|
        stripped = line.strip
        names.any? { |name| stripped.start_with?("export #{name}=") }
      end
      names.each do |name|
        filtered << "export #{name}=#{Shellwords.escape(value)}"
      end
      File.write(env_path, filtered.join("\n") + "\n")
      File.chmod(0o600, env_path)
    rescue StandardError
      nil
    end

    def resolve_secret(service:, account:, env_names:)
      load_default_env_files
      env_names.each do |name|
        value = ENV[name].to_s.strip
        return value unless value.empty?
      end
      return '' unless keychain_fallback_enabled?

      output, status = Open3.capture2e('security', 'find-generic-password', '-s', service, '-a', account, '-w')
      value = status.success? ? output.to_s.strip : ''
      unless value.empty?
        env_names.each { |name| ENV[name] = value if name && !name.to_s.strip.empty? }
        persist_secret_to_env_cache(value, env_names)
      end
      value
    rescue StandardError
      ''
    end

    def fetch_text(url, headers: {})
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      headers.each { |key, value| request[key] = value }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 20

      response = http.request(request)
      return '' unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s
    rescue StandardError
      ''
    end

    def appstore_fetch_url_status(url)
      uri = URI(url.to_s)
      request = Net::HTTP::Get.new(uri)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 5
      http.read_timeout = 20

      response = http.request(request)
      {
        code: response.code.to_i,
        location: response['location'].to_s.strip,
        error: nil
      }
    rescue StandardError => e
      { code: 0, location: '', error: e.message }
    end

    def appstore_url_health(url, limit: 5)
      current_url = url.to_s.strip
      return { ok: false, code: 0, final_url: current_url, error: 'missing URL' } if current_url.empty?

      redirects = 0
      while redirects <= limit
        status = appstore_fetch_url_status(current_url)
        return status.merge(ok: false, final_url: current_url) if status[:error]

        code = status[:code].to_i
        if code.between?(200, 299)
          return { ok: true, code: code, final_url: current_url, error: nil }
        end

        if code.between?(300, 399)
          location = status[:location].to_s
          return { ok: false, code: code, final_url: current_url, error: 'redirect missing location' } if location.empty?

          current_url = URI.join(current_url, location).to_s
          redirects += 1
          next
        end

        return { ok: false, code: code, final_url: current_url, error: "HTTP #{code}" }
      end

      { ok: false, code: 0, final_url: current_url, error: 'too many redirects' }
    rescue StandardError => e
      { ok: false, code: 0, final_url: current_url, error: e.message }
    end

    def appstore_direct_purchase_markers(artifact_blob, built_product_id: '')
      markers = []
      has_storekit_unlock = !built_product_id.to_s.strip.empty?
      markers << 'website checkout URL' if artifact_blob.match?(/go\.saneapps\.com\/buy\//i)
      markers << 'license key entry copy' if artifact_blob.match?(/Enter License Key|license key/i) && !has_storekit_unlock
      markers << 'purchase key entry copy' if artifact_blob.match?(/Use Purchase Key|purchase key|Activation Code/i)
      markers << 'manual key entry CTA' if artifact_blob.match?(/I Have a Key|Enter Key|Activate License/i)
      markers
    end

    def appstore_donation_markers(artifact_blob)
      markers = []
      markers << 'Donate button/copy' if artifact_blob.match?(/\bDonate\b|Donate to/i)
      markers << 'GitHub Sponsors link/copy' if artifact_blob.match?(/Sponsor on GitHub|GitHub Sponsors|github\.com\/sponsors/i)
      markers << 'supporter appeal copy' if artifact_blob.match?(/Support independent development|keep .* alive/i)
      markers << 'crypto donation copy' if artifact_blob.match?(/\bsend crypto\b|\bBTC\b|\bSOL\b|\bZEC\b/i)
      markers
    end

    def appstore_update_markers(strings_out:, otool_out:)
      markers = []
      has_sparkle_framework = otool_out.match?(/Sparkle\.framework/)
      has_sparkle_settings_ui = strings_out.match?(/SaneSparkleRow|Check for updates automatically|Check Now|Software Updates/i)
      has_outside_update_copy = strings_out.match?(/(?m)^Check for Updates(?:\.{3}|…)?$/i)
      has_updater_service = strings_out.match?(/\bUpdateService\b/)

      markers << 'Sparkle framework linkage' if has_sparkle_framework
      markers << 'Sparkle settings UI' if has_sparkle_settings_ui && (has_sparkle_framework || has_outside_update_copy || has_updater_service)
      markers << 'outside-update menu copy' if has_outside_update_copy
      markers << 'updater service type' if has_updater_service
      markers
    end

    def image_edge_luminance_report(path)
      return nil unless path && File.file?(path)

      script = <<~PYTHON
        import json
        import sys

        try:
            from PIL import Image
        except Exception as exc:
            print(json.dumps({"error": "pil_missing", "detail": str(exc)}))
            raise SystemExit(0)

        img = Image.open(sys.argv[1]).convert("RGB")
        width, height = img.size
        samples = [
            (0, 0),
            (0, height - 1),
            (width - 1, 0),
            (width - 1, height - 1),
            (width // 2, 20),
            (20, height // 2),
            (max(width - 21, 0), height // 2),
            (width // 2, max(height - 21, 0))
        ]

        luminances = []
        for x, y in samples:
            r, g, b = img.getpixel((x, y))
            luminances.append(0.2126 * r + 0.7152 * g + 0.0722 * b)

        print(json.dumps({
            "average_edge_luminance": sum(luminances) / len(luminances),
            "min_edge_luminance": min(luminances),
            "max_edge_luminance": max(luminances)
        }))
      PYTHON

      out, status = Open3.capture2e('python3', '-c', script, path.to_s)
      return nil unless status.success?

      JSON.parse(out)
    rescue StandardError
      nil
    end

    def watch_marketing_icon_warning(path)
      report = image_edge_luminance_report(path)
      return nil unless report.is_a?(Hash)

      if report['error'] == 'pil_missing'
        return 'Could not audit the watch marketing icon automatically because Pillow is unavailable; inspect the watch icon manually before submission'
      end

      average = report['average_edge_luminance'].to_f
      minimum = report['min_edge_luminance'].to_f
      return nil unless average < 40.0 || minimum < 15.0

      format(
        'Watch marketing icon edges are very dark (avg %.1f, min %.1f). Apple can reject watch icons that do not read clearly as circular on watchOS.',
        average,
        minimum
      )
    end

    def appstore_scheme_build_targets(manifest, scheme_name)
      return [] unless manifest.is_a?(Hash)

      scheme = manifest.fetch('schemes', {}).fetch(scheme_name.to_s, nil)
      return [] unless scheme.is_a?(Hash)

      build_targets = scheme.fetch('build', {}).fetch('targets', nil)
      case build_targets
      when Hash
        build_targets.keys.map(&:to_s)
      when Array
        build_targets.map(&:to_s)
      else
        []
      end
    end

    def appstore_target_graph_issues(manifest:, direct_scheme:, appstore_scheme:, platform:)
      return [] unless manifest.is_a?(Hash)

      targets = manifest['targets']
      return [] unless targets.is_a?(Hash)

      normalized_platform = platform.to_s.downcase
      select_app_targets = lambda do |target_names|
        target_names.select do |target_name|
          target = targets[target_name]
          next false unless target.is_a?(Hash)

          target['type'].to_s == 'application' && target['platform'].to_s.downcase == normalized_platform
        end
      end

      direct_targets = select_app_targets.call(appstore_scheme_build_targets(manifest, direct_scheme))
      appstore_targets = select_app_targets.call(appstore_scheme_build_targets(manifest, appstore_scheme))

      issues = []
      if appstore_targets.empty?
        issues << "App Store scheme #{appstore_scheme} does not build a #{platform} application target"
        return issues
      end

      shared_targets = direct_targets & appstore_targets
      if shared_targets.any?
        issues << "App Store scheme #{appstore_scheme} reuses direct application target(s): #{shared_targets.join(', ')}"
      end

      appstore_targets.each do |target_name|
        target = targets[target_name]
        dependencies = Array(target['dependencies'])
        linked_packages = dependencies.each_with_object([]) do |dependency, packages|
          next unless dependency.is_a?(Hash) && dependency.key?('package')

          packages << dependency['package'].to_s
        end
        if linked_packages.include?('Sparkle')
          issues << "App Store target #{target_name} still links Sparkle at the target graph level"
        end

        info_properties = target.dig('info', 'properties')
        if info_properties.is_a?(Hash)
          sparkle_keys = info_properties.keys.map(&:to_s).grep(/\ASU[A-Z]/)
          if sparkle_keys.any?
            issues << "App Store target #{target_name} still declares Sparkle Info.plist keys (#{sparkle_keys.join(', ')})"
          end
        end

        scripts_blob = Array(target['postBuildScripts']).map do |script|
          next '' unless script.is_a?(Hash)

          [script['name'], script['script']].compact.join("\n")
        end.join("\n")
        if scripts_blob.match?(/Strip Sparkle|weaken_sparkle|Sparkle stripped and weak-linked/i)
          issues << "App Store target #{target_name} still relies on Sparkle strip/weaken scripts"
        end
      end

      issues
    end

    def fetch_live_email_worker_snapshot(product_name:, include_signed:)
      api_key = resolve_secret(
        service: 'sane-email-automation',
        account: 'api_key',
        env_names: %w[SANE_EMAIL_API_KEY EMAIL_API_KEY]
      )
      return nil if api_key.to_s.strip.empty?

      uri = URI('https://email-api.saneapps.com/api/debug/download-config')
      params = { 'product' => product_name.to_s }
      params['signed'] = '1' if include_signed
      uri.query = URI.encode_www_form(params)

      body = fetch_text(uri.to_s, headers: { 'Authorization' => "Bearer #{api_key}" })
      return nil if body.empty?

      JSON.parse(body)
    rescue StandardError
      nil
    end

    def live_email_worker_value(snapshot, product_name, field_name)
      return nil unless snapshot.is_a?(Hash)

      products = snapshot['products'].is_a?(Hash) ? snapshot['products'] : {}
      product = products[product_name.to_s]
      return nil unless product.is_a?(Hash)

      value = product[field_name.to_s]
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def appstore_connect_token
      require 'jwt'
      require 'openssl'

      load_default_env_files

      issuer_id = ENV['ASC_AUTH_ISSUER_ID'] || ENV['ASC_ISSUER_ID'] || 'c98b1e0a-8d10-4fce-a417-536b31c09bfb'
      key_id = ENV['ASC_AUTH_KEY_ID'] || ENV['ASC_KEY_ID'] || 'S34998ZCRT'
      p8_path = File.expand_path(
        ENV['ASC_AUTH_KEY_PATH'] ||
        ENV['ASC_KEY_PATH'] ||
        '~/.private_keys/AuthKey_S34998ZCRT.p8'
      )

      return nil unless File.exist?(p8_path)

      private_key = OpenSSL::PKey::EC.new(File.read(p8_path))
      now = Time.now.to_i
      payload = {
        iss: issuer_id,
        iat: now,
        exp: now + 1200,
        aud: 'appstoreconnect-v1'
      }
      header = {
        kid: key_id,
        typ: 'JWT'
      }
      JWT.encode(payload, private_key, 'ES256', header)
    rescue StandardError
      nil
    end

    def asc_get_json(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
      require 'net/http'
      require 'json'

      uri = URI("#{base}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
      return nil unless response.code.to_i.between?(200, 299)

      JSON.parse(response.body)
    rescue StandardError
      nil
    end

    def asc_iap_status(app_id:, product_id:)
      return nil if app_id.to_s.strip.empty? || product_id.to_s.strip.empty?

      token = appstore_connect_token
      return nil if token.nil?

      response = asc_get_json("/apps/#{app_id}/inAppPurchasesV2?limit=200", token: token)
      return nil unless response.is_a?(Hash)

      row = Array(response['data']).find do |entry|
        entry.dig('attributes', 'productId').to_s.strip == product_id.to_s.strip
      end
      return { exists: false, state: nil } unless row

      status = {
        exists: true,
        state: row.dig('attributes', 'state').to_s.strip
      }

      iap_id = row['id'].to_s.strip
      unless iap_id.empty?
        localization_response = asc_get_json(
          "/inAppPurchases/#{iap_id}/inAppPurchaseLocalizations?limit=50",
          token: token,
          base: 'https://api.appstoreconnect.apple.com/v2'
        )
        if localization_response.is_a?(Hash)
          localization_states = Array(localization_response['data']).map do |entry|
            entry.dig('attributes', 'state').to_s.strip
          end.reject(&:empty?).uniq
          status[:localization_states] = localization_states
          status[:rejected_localization] = localization_states.include?('REJECTED')
        end
      end

      status
    end

    APP_STORE_EDITABLE_STATES = %w[
      PREPARE_FOR_SUBMISSION
      REJECTED
      DEVELOPER_REJECTED
      READY_FOR_REVIEW
    ].freeze

    APP_STORE_ACTIVE_SUBMISSION_STATES = %w[
      WAITING_FOR_REVIEW
      IN_REVIEW
      PENDING_APPLE_RELEASE
      PENDING_DEVELOPER_RELEASE
      PROCESSING_FOR_DISTRIBUTION
    ].freeze

    APP_STORE_FINALIZED_STATES = %w[
      READY_FOR_SALE
      DEVELOPER_REMOVED_FROM_SALE
      REMOVED_FROM_SALE
      REPLACED_WITH_NEW_VERSION
    ].freeze

    def asc_version_lane_guardrail_report(app_id:, platform:, version_string:)
      report = { applicable: false, issues: [], warnings: [], summary: '', target_state: nil }
      return report if app_id.to_s.strip.empty? || version_string.to_s.strip.empty?

      token = appstore_connect_token
      return report if token.nil?

      asc_platform = platform.to_s.downcase == 'ios' ? 'IOS' : 'MAC_OS'
      response = asc_get_json("/apps/#{app_id}/appStoreVersions?filter[platform]=#{asc_platform}&limit=200", token: token)
      return report unless response.is_a?(Hash)

      versions = Array(response['data']).map do |entry|
        {
          id: entry['id'].to_s.strip,
          version: entry.dig('attributes', 'versionString').to_s.strip,
          state: entry.dig('attributes', 'appStoreState').to_s.strip
        }
      end

      report[:applicable] = true

      target = versions.find { |entry| entry[:version] == version_string.to_s.strip }
      editable_conflicts = versions.select do |entry|
        APP_STORE_EDITABLE_STATES.include?(entry[:state]) && entry[:version] != version_string.to_s.strip
      end
      active_conflicts = versions.select do |entry|
        APP_STORE_ACTIVE_SUBMISSION_STATES.include?(entry[:state]) && entry[:version] != version_string.to_s.strip
      end

      if target
        state = target[:state]
        report[:target_state] = state
        report[:summary] = "#{version_string} (#{state})"
        if APP_STORE_FINALIZED_STATES.include?(state)
          report[:issues] << "App Store Connect already has #{platform} version #{version_string} in final state #{state} — bump MARKETING_VERSION before submission."
        end
        return report
      end

      if active_conflicts.any?
        conflicts = active_conflicts.map { |entry| "#{entry[:version]} (#{entry[:state]})" }.join(', ')
        report[:issues] << "App Store Connect has active #{platform} submission lane(s) #{conflicts}, but local target is #{version_string}."
        report[:summary] = "conflict: #{conflicts}"
        return report
      end

      if editable_conflicts.any?
        conflicts = editable_conflicts.map { |entry| "#{entry[:version]} (#{entry[:state]})" }.join(', ')
        report[:issues] << "App Store Connect has editable #{platform} lane(s) #{conflicts}, but local target is #{version_string}. Retarget or clear that lane before submission."
        report[:summary] = "conflict: #{conflicts}"
        return report
      end

      report[:summary] = "#{version_string} clear"
      report
    end

    def appstore_version_ui_includes_iap?(app_id:, platform:, product_id:)
      return nil if app_id.to_s.strip.empty? || product_id.to_s.strip.empty?

      platform_path = platform.to_s.downcase == 'ios' ? 'ios' : 'macos'
      target_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/#{platform_path}/version/inflight"
      script = <<~JXA
        var safari = Application('Safari');
        safari.includeStandardAdditions = true;
        if (!safari.running()) {
          console.log('UNAVAILABLE');
        } else if (safari.documents().length === 0) {
          console.log('UNAVAILABLE');
        } else {
          var tab = safari.windows[0].currentTab();
          var originalURL = '';
          try { originalURL = String(tab.url()); } catch (originalUrlError) {}
          function run(js) {
            return safari.doJavaScript(js, { in: tab });
          }
          try {
            tab.url = #{target_url.to_json};
            var pageText = '';
            var pageUrl = '';
            for (var i = 0; i < 30; i++) {
              delay(1);
              pageUrl = String(run("location.href") || '');
              pageText = run("document.body ? document.body.innerText : ''") || '';
              var onTargetPage = pageUrl.indexOf(#{target_url.to_json}) !== -1;
              if (onTargetPage && pageText.indexOf(#{product_id.to_json}) !== -1) break;
              if (onTargetPage && pageText.indexOf('Included Assets') !== -1) break;
              if (onTargetPage && pageText.indexOf('In-App Purchases and Subscriptions') !== -1) break;
            }
            var found = pageUrl.indexOf(#{target_url.to_json}) !== -1 && pageText.indexOf(#{product_id.to_json}) !== -1;
            console.log(found ? 'FOUND' : 'MISSING');
          } catch (error) {
            console.log('ERROR:' + error.toString());
          }
          if (originalURL && originalURL.length > 0) {
            try { tab.url = originalURL; } catch (restoreError) {}
          }
        }
      JXA

      out, status = run_osascript_jxa(script)
      lines = out.to_s.lines.map(&:strip).reject(&:empty?)
      return true if lines.include?('FOUND')
      return false if lines.include?('MISSING')
      return nil if lines.include?('UNAVAILABLE')
      return nil unless status.success?

      result = lines.last.to_s
      return true if result == 'FOUND'
      return false if result == 'MISSING'

      nil
    rescue StandardError
      nil
    end

    def run_osascript_jxa(script)
      Open3.capture2e('osascript', '-l', 'JavaScript', stdin_data: script)
    end

    def normalized_cloudkit_config(config)
      cloudkit = config.is_a?(Hash) ? config['cloudkit'] : nil
      return nil unless cloudkit.is_a?(Hash) && cloudkit['enabled']

      release_cfg = config['release'].is_a?(Hash) ? config['release'] : {}

      {
        container_id: metadata_value(cloudkit, 'container_id'),
        team_id: metadata_value(cloudkit, 'team_id') || metadata_value(release_cfg, 'team_id'),
        required_record_types: Array(cloudkit['required_record_types']).map { |value| value.to_s.strip }.reject(&:empty?)
      }
    end

    def cloudkit_schema_guardrail_report(config:, environment: 'production')
      report = { applicable: false, issues: [], warnings: [], summary: '' }
      cloudkit = normalized_cloudkit_config(config)
      return report unless cloudkit

      report[:applicable] = true

      container_id = cloudkit[:container_id].to_s
      team_id = cloudkit[:team_id].to_s
      required_record_types = cloudkit[:required_record_types]

      report[:issues] << 'cloudkit.container_id is missing in .saneprocess' if container_id.empty?
      report[:issues] << 'CloudKit team ID is missing (set cloudkit.team_id or release.team_id in .saneprocess)' if team_id.empty?
      report[:warnings] << 'No cloudkit.required_record_types configured in .saneprocess' if required_record_types.empty?
      return report unless report[:issues].empty?

      _version_out, version_status = Open3.capture2e('xcrun', 'cktool', 'version')
      unless version_status.success?
        report[:issues] << 'CloudKit schema verification requires xcrun cktool, but cktool is unavailable'
        return report
      end

      Dir.mktmpdir('sanemaster-cloudkit-schema-') do |tmpdir|
        output_path = File.join(tmpdir, 'schema.ckdb')
        cmd = [
          'xcrun', 'cktool', 'export-schema',
          '--team-id', team_id,
          '--container-id', container_id,
          '--environment', environment,
          '--output-file', output_path
        ]

        export_out, export_status = Open3.capture2e(*cmd)
        unless export_status.success?
          first_line = export_out.to_s.lines.map(&:strip).reject(&:empty?).first.to_s
          if export_out.to_s.match?(/No management token found/i)
            report[:issues] << 'CloudKit production schema cannot be verified because cktool has no management token. Run `xcrun cktool save-token --type management --method file` on the release machine.'
          else
            report[:issues] << "CloudKit #{environment} schema export failed: #{first_line}"
          end
          return report
        end

        schema_blob = safe_read(output_path)
        if schema_blob.strip.empty?
          report[:issues] << "CloudKit #{environment} schema export returned an empty schema file"
          return report
        end

        missing_record_types = required_record_types.reject do |record_type|
          schema_blob.match?(/\b#{Regexp.escape(record_type)}\b/)
        end

        if missing_record_types.any?
          report[:issues] << "CloudKit #{environment} schema is missing record types: #{missing_record_types.join(', ')}"
        else
          report[:summary] = "verified #{environment} schema for #{container_id}"
        end
      end

      report
    rescue StandardError => e
      report[:applicable] = true
      report[:issues] << "CloudKit schema verification crashed: #{e.class}: #{e.message}"
      report
    end

    def gh_auth_unavailable?(output)
      text = output.to_s
      return false if text.empty?

      text.match?(/SecKeychainSearchCopyNext|not logged into any hosts|authentication failed|gh auth login|could not read Username/i)
    end

    def missing_cloudflare_token?(output)
      text = output.to_s
      return false if text.empty?

      text.match?(/CLOUDFLARE_API_TOKEN|non-interactive environment/i)
    end

    def parse_json_count(output)
      JSON.parse(output).length
    rescue StandardError
      0
    end

    def write_release_status_snapshot(path:, status:, issues:, warnings:)
      FileUtils.mkdir_p(File.dirname(path))
      payload = {
        generatedAt: Time.now.iso8601,
        projectName: File.basename(Dir.pwd),
        status: status,
        issueCount: issues.count,
        warningCount: warnings.count,
        issues: issues,
        warnings: warnings
      }
      File.write(path, JSON.pretty_generate(payload))
    rescue StandardError
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
      ios_macos_mismatch_re = /(menu bar|frontmost app|cmd\+v|cgevent|accessibility|finder|right-click|notch|applescript|status item|apple silicon)/i

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

    def review_notes_for_platform(appstore_config, platform)
      notes_by_platform = appstore_config['review_notes_by_platform']
      platform_aliases =
        case platform.to_s.downcase
        when 'ios'
          %w[ios iphone ipad mobile]
        when 'macos'
          %w[macos mac desktop]
        else
          [platform.to_s.downcase]
        end

      if notes_by_platform.is_a?(Hash)
        platform_aliases.each do |key|
          note = metadata_value(notes_by_platform, key)
          return note if note
        end
      end

      metadata_value(appstore_config, 'review_notes').to_s
    end

    def reviewer_guardrail_source_blobs(swift_files:)
      blobs = Hash.new { |hash, key| hash[key] = [] }

      swift_files.each do |file|
        content = safe_read(file)
        next if content.empty?

        normalized = file.tr('\\', '/')
        ios_only = normalized.start_with?('iOS/') || normalized.start_with?('iOSWidgets/') || normalized.start_with?('iOSShareExtension/')
        macos_only = normalized.start_with?('UI/') ||
                     normalized.start_with?('Widgets/') ||
                     normalized.start_with?('SaneClip/') ||
                     normalized == 'SaneClipApp.swift' ||
                     normalized == 'main.swift' ||
                     normalized == 'ProFeature.swift'

        blobs['all'] << content
        blobs['macos'] << content unless ios_only
        blobs['ios'] << content unless macos_only
      end

      blobs.transform_values { |parts| parts.join("\n") }
    end

    def local_package_swift_files(project_yml_path)
      return [] unless File.exist?(project_yml_path)

      config = YAML.safe_load(File.read(project_yml_path))
      packages = config.is_a?(Hash) ? config['packages'] : nil
      return [] unless packages.is_a?(Hash)

      project_root = File.dirname(project_yml_path)
      packages.values.flat_map do |pkg|
        next [] unless pkg.is_a?(Hash)

        rel_path = pkg['path'].to_s.strip
        abs_path =
          if !rel_path.empty?
            File.expand_path(rel_path, project_root)
          elsif pkg['url'].to_s.match?(%r{sane-apps/SaneUI(\.git)?}i)
            File.expand_path('../../infra/SaneUI', project_root)
          end

        next [] unless abs_path && Dir.exist?(abs_path)
        Dir.glob(File.join(abs_path, 'Sources', '**', '*.swift'))
      end.uniq
    rescue StandardError
      []
    end

    def reviewer_access_guardrail_report(source_blob:, appstore_config:, platforms:)
      report = { applicable: false, issues: [], warnings: [], summary: '' }
      normalized_platforms = Array(platforms).map { |p| p.to_s.downcase }.uniq
      normalized_platforms = %w[macos] if normalized_platforms.empty?

      combined_source = source_blob.is_a?(Hash) ? source_blob['all'].to_s : source_blob.to_s
      has_external_credentials = combined_source.match?(/Paste your API key|set(LemonSqueezy|Gumroad|Stripe)APIKey|KeychainService\.(lemonSqueezyAPIKey|gumroadAPIKey|stripeAPIKey)|Connect .* Account/i)
      has_demo_mode = combined_source.match?(/Try Demo Data|Enable Demo Mode|demoMode|DemoData|demo data/i)
      uses_license_service = combined_source.match?(/\bLicenseService\b/)

      return report unless has_external_credentials || has_demo_mode || uses_license_service

      report[:applicable] = true

      normalized_platforms.each do |platform|
        platform_source = source_blob.is_a?(Hash) ? source_blob.fetch(platform, combined_source) : combined_source
        platform_has_demo_mode = platform_source.match?(/Try Demo Data|Enable Demo Mode|demoMode|DemoData|demo data/i)
        platform_has_try_demo_action = platform_source.match?(/Try Demo Data/i)
        platform_has_settings_demo_toggle = platform_source.match?(/Enable Demo Mode|Disable Demo Mode/i)
        notes_text = review_notes_for_platform(appstore_config, platform).to_s
        notes_downcase = notes_text.downcase
        no_account_path = notes_downcase.match?(/no account required|no api key required|no credentials required|no sign.?in required|no .*payment .*launch|no .*payment .*demo/)
        demo_path = notes_downcase.match?(/demo|sample data|try demo data|enable demo mode/)
        business_model_path = notes_downcase.match?(/basic is free|free\./) &&
                              notes_downcase.match?(/in-app purchase|app store/) &&
                              notes_downcase.match?(/no external checkout|no license key|no license keys/)
        external_account_clarity = notes_downcase.match?(/existing merchant|their own .*api|their own sales data|not sold by|do not unlock paid app features|do not unlock paid app features or digital content/)
        business_model_answers = {
          'who the paid/external users are' => /merchant|seller|creator|business|store owner/,
          'where external services are purchased' => /outside the app|existing .*account|with lemonsqueezy|with gumroad|with stripe/,
          'what external paid content is accessed' => /their own sales data|read-only|analytics|orders|products|refunds/,
          'what non-IAP app unlocks exist' => /no paid content in the app|no paid digital content|none|do not unlock paid app features/,
          'whether account creation requires payment' => /no account signup|no account or api key is required|no payment is required|no fee to create an account/,
          'whether enterprise services are involved' => /not enterprise|not an enterprise service|no enterprise services|existing merchants/
        }

        if has_external_credentials
          if notes_text.strip.empty?
            report[:issues] << "[#{platform}] Missing review notes for credential-gated app — tell App Review how to access the app"
          elsif platform_has_demo_mode
            unless demo_path
              report[:issues] << "[#{platform}] Review notes do not explain the demo-mode reviewer path for a credential-gated app"
            end
            unless no_account_path
              report[:issues] << "[#{platform}] Review notes do not clearly state that no account/API key/payment is required for the reviewer path"
            end
          elsif !notes_downcase.match?(/api key|credential|username|password|sign in|login|demo account/)
            report[:issues] << "[#{platform}] Review notes do not provide usable review credentials or access steps"
          end

          missing_answers = business_model_answers.each_with_object([]) do |(label, pattern), acc|
            acc << label unless notes_downcase.match?(pattern)
          end
          if missing_answers.any?
            report[:issues] << "[#{platform}] Review notes do not answer App Review's business-model questions clearly enough: #{missing_answers.join(', ')}"
          end
        elsif platform_has_demo_mode && !notes_downcase.match?(/demo|sample data|try demo data|enable demo mode/)
          report[:warnings] << "[#{platform}] Demo mode exists in code, but review notes do not mention it"
        end

        if notes_downcase.include?('try demo data') && !platform_has_try_demo_action
          report[:issues] << "[#{platform}] Review notes mention “Try Demo Data”, but that action is not present in the code"
        end

        if notes_downcase.include?('enable demo mode') && !platform_has_settings_demo_toggle
          report[:issues] << "[#{platform}] Review notes mention “Enable Demo Mode”, but that settings action is not present in the code"
        end

        next unless uses_license_service

        purchase_surface_path = notes_downcase.match?(/settings\s*>\s*license|license tab|unlock pro|upgrade to pro|restore purchases|browse library|locked categor|open .*license/i)
        durable_purchase_surface_path = notes_downcase.match?(/settings\s*>\s*license|license tab|browse library|locked categor|open .*license/i)
        one_shot_onboarding_path = platform_source.match?(/hasSeenWelcome|WelcomeGateView/)
        has_license_surface = platform_source.match?(/Section\("License"\)|GlassSection\("License"|LicenseSettingsView/)
        has_welcome_gate_surface = platform_source.match?(/WelcomeGateView\(/)
        has_unlock_pro_surface = platform_source.match?(/Unlock Pro|purchasePro\(|restorePurchases\(/i) ||
                                 (notes_downcase.match?(/welcome screen|onboarding/) && has_welcome_gate_surface)
        has_browse_library_surface = platform_source.match?(/Browse Library/i)

        unless purchase_surface_path
          report[:issues] << "[#{platform}] Review notes do not tell App Review where to find the optional Pro unlock (for example Settings > License or another visible Unlock Pro path)"
        end

        if notes_downcase.match?(/settings\s*>\s*license|license tab/) && !has_license_surface
          report[:issues] << "[#{platform}] Review notes mention a License screen/section, but no License surface exists in the #{platform} source"
        end

        if notes_downcase.include?('unlock pro') && !has_unlock_pro_surface
          report[:issues] << "[#{platform}] Review notes mention “Unlock Pro”, but that action is not present in the #{platform} source"
        end

        if notes_downcase.include?('browse library') && !has_browse_library_surface
          report[:issues] << "[#{platform}] Review notes mention “Browse Library”, but that action is not present in the #{platform} source"
        end

        if one_shot_onboarding_path && !durable_purchase_surface_path
          report[:warnings] << "[#{platform}] Onboarding paywall appears one-shot in code, but review notes do not mention a durable post-onboarding upgrade path like Settings > License"
        end

        unless business_model_path
          report[:warnings] << "[#{platform}] Review notes do not clearly explain the App Store business model (free/basic, Pro unlock path, no website license flow)"
        end

        if has_external_credentials && !external_account_clarity
          report[:warnings] << "[#{platform}] Review notes do not clearly explain that external provider accounts are optional existing merchant accounts and do not unlock paid app features"
        end
      end

      if has_external_credentials &&
         normalized_platforms.length > 1 &&
         !appstore_config['review_notes_by_platform'].is_a?(Hash)
        report[:warnings] << 'Credential-gated app uses one shared review_notes block across multiple platforms — prefer review_notes_by_platform'
      end

      report[:summary] = [
        ('credentials' if has_external_credentials),
        ('demo' if has_demo_mode),
        ('license' if uses_license_service)
      ].compact.join(', ')
      report
    end

    def appstore_policy_guardrail_report(source_blob:, review_notes_blob:)
      report = { applicable: false, issues: [], warnings: [], summary: '' }
      normalized_source = source_blob.to_s
      normalized_notes = review_notes_blob.to_s

      has_accessibility_runtime =
        normalized_source.match?(/AXIsProcessTrusted|AXUIElement|NSAccessibilityUsageDescription|AccessibilityService/i)
      has_synthetic_input =
        normalized_source.match?(/CGEvent|keyboard events|simulatePaste|keyDown|mouseDown|mouseDragged/i)
      automates_clipboard =
        normalized_source.match?(/simulatePaste|automatic paste|paste in another app|pasteSelected|auto.?paste/i)
      automates_third_party_ui =
        normalized_source.match?(/moveMenuBarIcon|reorderMenuBarIcon|Cmd\+drag|drag.*menu bar|listMenuBarItemsWithPositions/i)
      mentions_apple_events =
        normalized_source.match?(/NSAppleEventsUsageDescription|osascript|AppleScript|System Events/i)
      clipboard_review_notes =
        normalized_notes.match?(/paste manually|cmd\+v|frontmost app/i)
      strips_appstore_automation_usage =
        normalized_source.match?(/Delete :NSAppleEventsUsageDescription/i) &&
        normalized_source.match?(/Delete :NSAccessibilityUsageDescription/i)

      return report unless has_accessibility_runtime || has_synthetic_input || mentions_apple_events

      report[:applicable] = true

      if has_accessibility_runtime && (automates_clipboard || (has_synthetic_input && clipboard_review_notes))
        if strips_appstore_automation_usage && clipboard_review_notes
          report[:warnings] << 'Source contains clipboard automation for non-App-Store builds, but the App Store build script strips automation usage descriptions and review notes describe manual paste. Verify the compiled App Store artifact before blocking submission.'
        else
          report[:issues] << 'App Store build appears to use Accessibility or synthetic input for clipboard/paste automation. Apple rejects this under Guideline 2.4.5.'
        end
      end

      if has_accessibility_runtime && has_synthetic_input && automates_third_party_ui
        report[:issues] << 'App Store build appears to inspect or reposition third-party UI with Accessibility/CGEvent automation. This is high-risk under Guideline 2.4.5 and should be removed from the App Store build.'
      end

      if mentions_apple_events && normalized_notes.to_s.strip.empty?
        report[:warnings] << 'App uses Apple Events / AppleScript but review notes do not explain when or why permission is requested.'
      end

      tags = []
      tags << 'accessibility' if has_accessibility_runtime
      tags << 'synthetic-input' if has_synthetic_input
      tags << 'apple-events' if mentions_apple_events
      tags << 'clipboard-automation' if automates_clipboard
      tags << 'ui-automation' if automates_third_party_ui
      report[:summary] = tags.join(', ')
      report
    end

    def release(args)
      return unless ensure_research_gate_clear!('release')

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
      return unless ensure_research_gate_clear!('release_preflight')

      require 'json'
      require 'open3'
      require 'tmpdir'
      require 'yaml'

      puts '🛫 --- [ RELEASE PREFLIGHT ] ---'
      puts "Project: #{Dir.pwd}"
      puts ''

      issues = []
      warnings = []
      preflight_status_path = File.join(Dir.pwd, 'outputs', 'release_preflight_status.json')
      saneprocess_path = File.join(Dir.pwd, '.saneprocess')
      preflight_config = if File.exist?(saneprocess_path)
                           YAML.safe_load(safe_read(saneprocess_path)) || {}
                         else
                           {}
                         end
      preflight_app_name = metadata_value(preflight_config, 'name') || File.basename(Dir.pwd)

      # 1. Tests pass
      print '  Tests... '
      verify_env = { 'SANEMASTER_RELEASE_PREFLIGHT' => '1' }
      out, status = Open3.capture2e(verify_env, './scripts/SaneMaster.rb', 'verify', '--quiet')
      verify_cleanup = verify_output_indicates_runtime_dedupe_cleanup?(out, app_name: preflight_app_name)
      if status.success? || verify_output_indicates_success?(out) || verify_cleanup
        if verify_cleanup
          puts '✅ (after runtime app dedupe cleanup)'
        else
          puts '✅'
        end
      else
        puts '❌ FAIL'
        hint = summarized_output_tail(out)
        puts "    ↳ #{hint}" unless hint.empty?
        issues << 'Tests failing'
      end

      # 1a. Project QA guardrails (if project provides qa.rb)
      normalize_chunk = lambda do |chunk|
        normalized = chunk.dup
        normalized.force_encoding(Encoding::UTF_8)
        next normalized if normalized.valid_encoding?

        chunk.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '?')
      rescue StandardError
        chunk.to_s.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '?')
      end

      qa_capture = lambda do |env, *cmd, heartbeat_label:, heartbeat_seconds: 8|
        output = +''
        status = nil
        started_at = Time.now
        last_output_at = Time.now
        last_heartbeat_at = Time.at(0)

        Open3.popen2e(env, *cmd) do |_stdin, stdout_err, wait_thr|
          loop do
            ready = IO.select([stdout_err], nil, nil, 1)
            if ready
              begin
                chunk = normalize_chunk.call(stdout_err.read_nonblock(4096))
                output << chunk
                print chunk
                $stdout.flush
                last_output_at = Time.now unless chunk.empty?
              rescue IO::WaitReadable
                nil
              rescue EOFError
                nil
              end
            end

            if wait_thr.join(0)
              status = wait_thr.value
              break
            end

            next unless (Time.now - last_output_at) >= heartbeat_seconds
            next unless (Time.now - last_heartbeat_at) >= heartbeat_seconds

            elapsed = (Time.now - started_at).round(1)
            puts "    … #{heartbeat_label} still running (#{elapsed}s)"
            last_heartbeat_at = Time.now
          end

          loop do
            chunk = normalize_chunk.call(stdout_err.read_nonblock(4096))
            output << chunk
            print chunk
            $stdout.flush
          rescue IO::WaitReadable
            break
          rescue EOFError
            break
          end
        end

        [output, status]
      end

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
          'SANEPROCESS_RUN_RUNTIME_SMOKE' => '1',
          "#{app_prefix}_RELEASE_PREFLIGHT" => '1',
          "#{app_prefix}_RUN_STABILITY_SUITE" => '1',
          "#{app_prefix}_RUN_RUNTIME_SMOKE" => '1',
        }
        puts
        qa_out, qa_status = qa_capture.call(
          qa_env,
          'ruby',
          qa_script,
          heartbeat_label: 'project QA guardrails'
        )
        if qa_status.success?
          puts "  Project QA guardrails... ✅ (#{qa_script})"
        else
          puts '  Project QA guardrails... ❌ FAIL'
          warn_line = qa_out.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
            .lines.last(4).map(&:strip).reject(&:empty?).join(' | ')
          puts "    ↳ #{warn_line}" unless warn_line.empty?
          issues << "Project QA guardrails failed (#{qa_script})"
        end
      else
        puts '⏭️  skipped (no qa.rb)'
      end

    # 1b. Monetization guardrails (protect against accidental full-free releases)
      print '  Monetization guardrails... '
      project_yml_content = File.exist?('project.yml') ? safe_read('project.yml') : ''
      plist_content = Dir.glob('**/*.plist').reject { |p| p.include?('DerivedData') || p.include?('build/') }.map { |p| safe_read(p) }.join("\n")
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
        strict_appstore_product_id: false,
        shared_or_package_branch: shared_or_package_app_store_branch?(swift_files: swift_files)
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

      # 1c. CloudKit production schema readiness
      print '  CloudKit production schema... '
      cloudkit_report = cloudkit_schema_guardrail_report(config: preflight_config, environment: 'production')
      if cloudkit_report[:applicable]
        if cloudkit_report[:issues].empty?
          puts "✅ #{cloudkit_report[:summary]}"
        else
          puts "❌ #{cloudkit_report[:issues].first}"
          cloudkit_report[:issues].each { |m| issues << "CloudKit: #{m}" }
        end
        cloudkit_report[:warnings].each { |m| warnings << "CloudKit: #{m}" }
      else
        puts '⏭️  skipped (no CloudKit release config)'
      end

      # 2. Git clean
      print '  Git clean... '
      routed_workspace = routed_workspace_context
      dirty_count = if routed_workspace
                      routed_workspace['dirty_count'].to_i
                    else
                      dirty, = Open3.capture2('git', 'status', '--porcelain')
                      dirty.to_s.lines.reject { |line| line.strip.empty? }.count
                    end
      if dirty_count.zero?
        puts '✅'
      else
        puts "⚠️  #{dirty_count} uncommitted changes"
        warnings << "#{dirty_count} uncommitted files"
      end

      # 2a. Remote branch sync (catches push failures before release work starts)
      print '  Remote branch sync... '
      routed_sync = routed_workspace.is_a?(Hash) ? routed_workspace['remote_sync'] : nil
      if routed_sync.is_a?(Hash)
        current_branch = metadata_value(routed_sync, 'branch') || metadata_value(routed_workspace, 'branch')
        case metadata_value(routed_sync, 'status')
        when 'detached'
          puts '⏭️  skipped (detached HEAD)'
        when 'unavailable'
          puts "⏭️  skipped (origin/#{current_branch} unavailable)"
          warnings << "Could not read origin/#{current_branch} during preflight"
        when 'matches'
          puts "✅ (#{current_branch} matches origin)"
        when 'ahead'
          puts "✅ ahead #{metadata_value(routed_sync, 'ahead_count') || '0'} commit(s)"
        when 'behind'
          puts "❌ behind origin/#{current_branch}"
          issues << "Local branch is behind origin/#{current_branch}"
        when 'diverged'
          puts "❌ diverged from origin/#{current_branch}"
          issues << "Local branch diverged from origin/#{current_branch}"
        else
          puts '⏭️  skipped (route context unavailable)'
        end
      else
        current_branch, = Open3.capture2('git', 'rev-parse', '--abbrev-ref', 'HEAD')
        current_branch = current_branch.strip
        if current_branch.empty? || current_branch == 'HEAD'
          puts '⏭️  skipped (detached HEAD)'
        else
          remote_ref_out, remote_ref_status = Open3.capture2('git', 'ls-remote', '--heads', 'origin', current_branch)
          remote_ref = remote_ref_out.to_s.split.first.to_s.strip
          if !remote_ref_status.success? || remote_ref.empty?
            puts "⏭️  skipped (origin/#{current_branch} unavailable)"
            warnings << "Could not read origin/#{current_branch} during preflight"
          else
            local_head, = Open3.capture2('git', 'rev-parse', 'HEAD')
            local_head = local_head.strip

            remote_is_ancestor = system('git', 'merge-base', '--is-ancestor', remote_ref, local_head, out: File::NULL, err: File::NULL)
            local_is_ancestor = system('git', 'merge-base', '--is-ancestor', local_head, remote_ref, out: File::NULL, err: File::NULL)

            if local_head == remote_ref
              puts "✅ (#{current_branch} matches origin)"
            elsif remote_is_ancestor && !local_is_ancestor
              ahead_count, = Open3.capture2('git', 'rev-list', '--count', "#{remote_ref}..#{local_head}")
              puts "✅ ahead #{ahead_count.strip} commit(s)"
            elsif local_is_ancestor && !remote_is_ancestor
              puts "❌ behind origin/#{current_branch}"
              issues << "Local branch is behind origin/#{current_branch}"
            else
              puts "❌ diverged from origin/#{current_branch}"
              issues << "Local branch diverged from origin/#{current_branch}"
            end
          end
        end
      end

      # 3. UserDefaults / migration changes
      print '  Defaults/migration changes... '
      changed_files = if routed_workspace
                        Array(routed_workspace['recent_changed_swift_files']).join("\n")
                      else
                        output, = Open3.capture2('git', 'diff', 'HEAD~5..HEAD', '--name-only', '--', '*.swift')
                        output
                      end
      defaults_files = changed_files.to_s.strip.split("\n")
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

      # 4a. Sparkle sandbox installer launcher requirements
      print '  Sparkle sandbox installer launcher... '
      sparkle_target = macos_release_target_config
      if checked_key && sparkle_target[:info_path].to_s != '' && sparkle_target[:entitlements_path].to_s != ''
        info_content = safe_read(sparkle_target[:info_path])
        entitlements_content = safe_read(sparkle_target[:entitlements_path])
        sandboxed = plist_bool_true?(entitlements_content, 'com.apple.security.app-sandbox')

        if sandboxed
          info_has_launcher = info_content.match?(/<key>SUEnableInstallerLauncherService<\/key>\s*<true\/>/m)
          bundle_id = sparkle_target[:bundle_id].to_s
          spki_token = bundle_id.empty? ? '$(PRODUCT_BUNDLE_IDENTIFIER)-spki' : "#{bundle_id}-spki"
          spks_token = bundle_id.empty? ? '$(PRODUCT_BUNDLE_IDENTIFIER)-spks' : "#{bundle_id}-spks"
          has_spki = entitlements_content.include?('$(PRODUCT_BUNDLE_IDENTIFIER)-spki') || entitlements_content.include?(spki_token)
          has_spks = entitlements_content.include?('$(PRODUCT_BUNDLE_IDENTIFIER)-spks') || entitlements_content.include?(spks_token)

          if info_has_launcher && has_spki && has_spks
            puts '✅'
          else
            puts '❌ missing required Sparkle sandbox config'
            issues << 'Sparkle sandboxed direct build must set SUEnableInstallerLauncherService=true'
            issues << 'Sparkle sandboxed direct build must grant mach lookup exception $(PRODUCT_BUNDLE_IDENTIFIER)-spki' unless has_spki
            issues << 'Sparkle sandboxed direct build must grant mach lookup exception $(PRODUCT_BUNDLE_IDENTIFIER)-spks' unless has_spks
          end
        else
          puts '⏭️  not sandboxed'
        end
      else
        puts '⏭️  skipped'
      end

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
        informational_entries_missing_links = informational_appcast_entries_missing_links(safe_read(appcast_path))
        informational_constraint_version_mismatches = informational_appcast_entries_mismatched_constraint_versions(safe_read(appcast_path))

        gate_failures = []
        gate_warnings = []

        if appcast_version.empty?
          gate_failures << "Could not parse sparkle:shortVersionString from #{appcast_path}"
        end
        if appcast_url.empty?
          gate_failures << "Could not parse enclosure URL from #{appcast_path}"
        end
        unless informational_entries_missing_links.empty?
          gate_failures << "Informational appcast entries missing item <link>: #{informational_entries_missing_links.join(', ')}"
        end
        unless informational_constraint_version_mismatches.empty?
          gate_failures << "Informational appcast entries compare against display versions instead of CFBundleVersion: #{informational_constraint_version_mismatches.join(', ')}"
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
        issue_json, issue_status = Open3.capture2e({ 'PATH' => tool_path }, gh_bin, 'issue', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
        if issue_status.success?
          open_count = parse_json_count(issue_json)
          if open_count.positive?
            puts "⚠️  #{open_count} open"
            warnings << "#{open_count} open GitHub issues"
          else
            puts '✅ none'
          end
        elsif gh_auth_unavailable?(issue_json)
          puts '⏭️  skipped (gh auth unavailable)'
        else
          puts '⏭️  gh query failed'
          warnings << "GitHub issue query failed: #{issue_json.lines.first.to_s.strip}"
        end

        print '  Open GitHub PRs... '
        pr_json, pr_status = Open3.capture2e({ 'PATH' => tool_path }, gh_bin, 'pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number')
        if pr_status.success?
          open_pr_count = parse_json_count(pr_json)
          if open_pr_count.positive?
            puts "⚠️  #{open_pr_count} open"
            warnings << "#{open_pr_count} open GitHub PRs"
          else
            puts '✅ none'
          end
        elsif gh_auth_unavailable?(pr_json)
          puts '⏭️  skipped (gh auth unavailable)'
        else
          puts '⏭️  gh query failed'
          warnings << "GitHub PR query failed: #{pr_json.lines.first.to_s.strip}"
        end
      else
        puts '⏭️  skipped (gh not installed)'
      end

      # 6. Pending customer emails
      print '  Pending emails... '
      api_key = resolve_secret(
        service: 'sane-email-automation',
        account: 'api_key',
        env_names: %w[SANE_EMAIL_API_KEY EMAIL_API_KEY]
      )
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
      live_appcast_item = { version: '', build: '', url: '' }
      website_domain = preflight_config['website_domain'].to_s.strip
      if !website_domain.empty?
        live_appcast_body = fetch_text("https://#{website_domain}/appcast.xml")
        live_appcast_item = parse_latest_appcast_item(live_appcast_body) unless live_appcast_body.empty?
      end

      webhook_snapshot = fetch_live_email_worker_snapshot(
        product_name: preflight_app_name,
        include_signed: true
      )
      webhook_ver = live_email_worker_value(webhook_snapshot, preflight_app_name, 'version')

      if live_appcast_item[:version].to_s.empty? && webhook_ver.to_s.empty?
        puts '⏭️  no live appcast or worker snapshot'
      elsif live_appcast_item[:version].to_s.empty?
        puts "✅ #{preflight_app_name} v#{webhook_ver} (worker live)"
      elsif webhook_ver.to_s.empty?
        puts "⚠️  #{preflight_app_name} missing from live email worker"
        warnings << "#{preflight_app_name} missing from live email worker snapshot"
      elsif live_appcast_item[:version] == webhook_ver
        puts "✅ #{preflight_app_name} v#{webhook_ver}"
      else
        puts "❌ DRIFT: worker=#{webhook_ver}, appcast=#{live_appcast_item[:version]}"
        issues << "Live email worker serves #{preflight_app_name}-#{webhook_ver} but live appcast is at #{live_appcast_item[:version]} — new customers get old builds"
      end

      # 10b. Check the live worker's signed download URL, not just source freshness.
      print '  Webhook Worker signed download... '
      webhook_download_url = live_email_worker_value(webhook_snapshot, preflight_app_name, 'downloadUrl')
      webhook_file = live_email_worker_value(webhook_snapshot, preflight_app_name, 'file')
      if webhook_download_url.to_s.empty?
        puts '⏭️  no signed download URL'
      elsif webhook_file.to_s.end_with?('.zip')
        archive_versions = archive_bundle_versions(zip_url: webhook_download_url, app_name: preflight_app_name)
        if archive_versions.nil?
          puts '❌ bundle unreadable'
          issues << "Live email worker signed download for #{preflight_app_name} could not be inspected"
        elsif !webhook_ver.to_s.empty? && archive_versions[:version] != webhook_ver
          puts "❌ v#{archive_versions[:version]} != worker #{webhook_ver}"
          issues << "Live email worker signed download bundle version #{archive_versions[:version]} does not match worker #{webhook_ver}"
        elsif !live_appcast_item[:build].to_s.empty? && archive_versions[:build] != live_appcast_item[:build]
          puts "❌ build #{archive_versions[:build]} != appcast #{live_appcast_item[:build]}"
          issues << "Live email worker signed download bundle build #{archive_versions[:build]} does not match live appcast #{live_appcast_item[:build]}"
        else
          puts "✅ v#{archive_versions[:version]} (#{archive_versions[:build]})"
        end
      else
        puts "⚠️  unsupported file #{webhook_file}"
        warnings << "Live email worker signed download uses unsupported archive type: #{webhook_file}"
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

      write_release_status_snapshot(
        path: preflight_status_path,
        status: issues.any? ? 'failed' : 'passed',
        issues: issues,
        warnings: warnings
      )

      exit 1 if issues.any?
    end

    # App Store submission preflight — validates everything Apple checks during review.
    # Derived from Apple's App Review Guidelines + community rejection checklists.
    # Works for any SaneApps project with a .saneprocess config.
    def appstore_preflight(_args)
      return unless ensure_research_gate_clear!('appstore_preflight')

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
      yml_content = File.exist?(project_yml) ? File.read(project_yml) : ''
      project_yml_content = yml_content
      version_str = project_marketing_version(yml_content)
      build_num = project_build_number(yml_content)
      if version_str && build_num
        puts "✅ v#{version_str} (#{build_num})"
      elsif version_str
        puts "⚠️  v#{version_str} but no CURRENT_PROJECT_VERSION"
        warnings << 'Missing CURRENT_PROJECT_VERSION in project.yml/xcconfig'
      else
        puts '⚠️  could not read from project.yml/xcconfig'
        warnings << 'Could not read version info from project.yml/xcconfig'
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
        has_sandbox = plist_bool_true?(ent_content, 'com.apple.security.app-sandbox')
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
      screenshots_config = appstore_config['screenshots'] || {}
      platforms = appstore_config['platforms'] || ['macos']

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

      # 3a1. Watch marketing icon audit
      print '  │ Watch marketing icon... '
      watch_assets_expected = project_yml_content.include?('WATCHOS_DEPLOYMENT_TARGET') || screenshots_config.key?('watch')
      watch_marketing_icons = Dir.glob('**/WatchAppIcon.appiconset/*.png').reject { |p| p.include?('DerivedData') || p.include?('build/') }.select do |path|
        dims, = Open3.capture2('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path)
        dims[/pixelWidth:\s*(\d+)/, 1].to_i == 1024 && dims[/pixelHeight:\s*(\d+)/, 1].to_i == 1024
      end
      if watch_assets_expected
        if watch_marketing_icons.empty?
          puts '❌ not found'
          issues << 'watchOS target detected but no 1024x1024 marketing icon was found in WatchAppIcon.appiconset'
        else
          warning = watch_marketing_icon_warning(watch_marketing_icons.first)
          if warning
            puts '⚠️  inspect contrast'
            warnings << warning
          else
            puts '✅'
          end
        end
      else
        puts '⏭️  skipped (no watch lane detected)'
      end

      # 3b. Screenshots configured and valid
      print '  │ Screenshots... '
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
              if platform == 'macos' && files.count < 3
                warnings << "Only #{files.count} macOS screenshot(s) configured — Apple allows one, but 3-5 screenshots is a safer review baseline"
              end

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
      swift_files.concat(local_package_swift_files(project_yml)).uniq!
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
      effective_required_keys = required_keys.dup

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
        provisional = []
        definite = []
        missing_keys.each do |entry|
          if entry.start_with?('NSAccessibilityUsageDescription') || entry.start_with?('NSAppleEventsUsageDescription')
            provisional << entry
          else
            definite << entry
          end
        end

        if definite.any?
          puts "❌ #{missing_keys.count} missing"
          missing_keys.each { |k| puts "  │   - #{k}" }
          issues << "Missing Info.plist usage descriptions: #{definite.join(', ')}"
        else
          puts "⚠️  #{missing_keys.count} provisional"
          missing_keys.each { |k| puts "  │   - #{k}" }
        end

        if provisional.any?
          warnings << "Source references automation permissions that may be compiled out for App Store builds: #{provisional.join(', ')}"
        end
      end

      # 4b. Privacy policy URL
      print '  │ Privacy policy URL... '
      privacy_url = appstore_config['privacy_policy_url'].to_s.strip
      privacy_url = "https://#{config['website_domain']}/privacy" if privacy_url.empty? && config['website_domain']
      if privacy_url.empty?
        puts '❌ missing'
        issues << 'No privacy policy URL — required for all App Store submissions'
      else
        health = appstore_url_health(privacy_url)
        if health[:ok]
          puts "✅ #{privacy_url} (#{health[:code]})"
          warnings << "No explicit privacy_policy_url in .saneprocess — Apple requires this in metadata" unless appstore_config['privacy_policy_url']
        else
          puts "❌ #{health[:error]}"
          issues << "Privacy policy URL #{privacy_url} did not resolve successfully (#{health[:error]})"
        end
      end

      # 4c. Support URL
      print '  │ Support URL... '
      support_url = appstore_config['support_url'].to_s.strip
      support_url = "https://#{config['website_domain']}/support" if support_url.empty? && config['website_domain']
      if support_url.empty?
        puts '❌ missing'
        issues << 'No support URL — required for App Store'
      else
        health = appstore_url_health(support_url)
        if health[:ok]
          puts "✅ #{support_url} (#{health[:code]})"
          warnings << "No explicit support_url in .saneprocess — Apple requires this" unless appstore_config['support_url']
        else
          puts "❌ #{health[:error]}"
          issues << "Support URL #{support_url} did not resolve successfully (#{health[:error]})"
        end
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
      verify_cleanup = verify_output_indicates_runtime_dedupe_cleanup?(out, app_name: config['name'] || File.basename(Dir.pwd))
      if status.success? || verify_output_indicates_success?(out) || verify_cleanup
        if verify_cleanup
          puts '✅ (after runtime app dedupe cleanup)'
        else
          puts '✅'
        end
      elsif out.include?('Newest appcast entry should match MARKETING_VERSION') &&
            out.scan('Expectation failed:').length == 1
        puts '⚠️  appcast/version drift'
        warnings << 'Direct-download appcast is one version behind MARKETING_VERSION (non-blocking for App Store submission)'
      elsif appcast_drift_failure_only?(out)
        puts '⚠️  appcast/version drift'
        warnings << 'Direct-download appcast is one version behind MARKETING_VERSION (non-blocking for App Store submission)'
      else
        puts '❌ FAIL'
        hint = summarized_output_tail(out)
        puts "  │   ↳ #{hint}" unless hint.empty?
        issues << 'Tests failing — fix before submission'
      end

      # 5a1. CloudKit production schema
      print '  │ CloudKit production schema... '
      cloudkit_report = cloudkit_schema_guardrail_report(config: config, environment: 'production')
      if cloudkit_report[:applicable]
        if cloudkit_report[:issues].empty?
          puts "✅ #{cloudkit_report[:summary]}"
        else
          puts "❌ #{cloudkit_report[:issues].first}"
          cloudkit_report[:issues].each { |m| issues << "CloudKit: #{m}" }
        end
        cloudkit_report[:warnings].each { |m| warnings << "CloudKit: #{m}" }
      else
        puts '⏭️  skipped (no CloudKit release config)'
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
          pbxproj = Dir.glob('*.xcodeproj/project.pbxproj').map { |p| File.read(p) rescue '' }.join("\n")
          if pbxproj.include?(asc_config_name)
            puts "✅ #{asc_config_name} (verified in project.pbxproj)"
          else
            puts "⚠️  #{asc_config_name} (can't verify — no project.yml)"
            warnings << "Can't verify build configuration without project.yml/project.pbxproj"
          end
        end
      else
        puts '⚠️  not specified'
        warnings << 'No appstore.configuration in .saneprocess — using default Release config?'
      end

      lane_reports = []

      # 5c0. App Store Connect version lane matches local target
      print '  │ ASC version lane... '
      if asc_app_id.to_s.strip.empty?
        puts '⚠️  skipped (no ASC app_id)'
        warnings << 'Cannot verify App Store Connect version lane without appstore.app_id'
      elsif version_str.to_s.strip.empty?
        puts '⚠️  skipped (no MARKETING_VERSION)'
        warnings << 'Cannot verify App Store Connect version lane without MARKETING_VERSION'
      else
        lane_reports = Array(platforms).map do |platform|
          [platform, asc_version_lane_guardrail_report(app_id: asc_app_id, platform: platform, version_string: version_str)]
        end

        applicable_reports = lane_reports.select { |_platform, report| report[:applicable] }
        if applicable_reports.empty?
          puts '⚠️  lookup failed'
          warnings << 'Could not verify App Store Connect version lane state'
        else
          lane_issues = applicable_reports.flat_map { |_platform, report| Array(report[:issues]) }
          if lane_issues.empty?
            summary = applicable_reports.map do |platform, report|
              "#{platform}: #{report[:summary]}"
            end.join(' | ')
            puts "✅ #{summary}"
          else
            first_platform, first_report = applicable_reports.find { |_platform, report| Array(report[:issues]).any? }
            puts "❌ #{first_platform}: #{first_report[:summary]}"
            lane_issues.each { |message| issues << message }
          end
        end
      end

      # 5c1. launchd daemon / helper architecture audit
      print '  │ launchd daemon audit... '
      if platforms.include?('macos')
        daemon_markers = []
        daemon_markers << 'SMAppService.daemon source' if all_source.match?(/SMAppService\.daemon\s*\(/)
        daemon_markers << 'LaunchDaemons payload copy step' if project_yml_content.match?(/LaunchDaemons/i) || yml_content.match?(/LaunchDaemons/i)

        xcodeproj_blob = Dir.glob('*.xcodeproj/project.pbxproj').map { |p| File.read(p) rescue '' }.join("\n")
        daemon_markers << 'embedded helper tool target' if xcodeproj_blob.match?(/productType = "com\.apple\.product-type\.tool"/) &&
                                                            xcodeproj_blob.match?(/Embed Helper|LaunchDaemons/i)

        if daemon_markers.empty?
          puts '✅'
        else
          puts "❌ #{daemon_markers.join(', ')}"
          issues << "Mac App Store build still relies on launchd daemon/helper architecture (#{daemon_markers.join(', ')}) — Mac App Store apps cannot ship launchd daemons or agents; redesign the App Store build or disable the lane"
        end
      else
        puts '⏭️  skipped (non-macOS submission)'
      end

      # 5d. StoreKit product ID routing for App Store unlock flow
      print '  │ StoreKit product ID routing... '
      uses_storekit_unlock = all_source.match?(/\bLicenseService\s*\(/)
      configured_product_id = appstore_config['product_id'].to_s.strip
      pbxproj_content = Dir.glob('*.xcodeproj/project.pbxproj').map { |p| File.read(p) rescue '' }.join("\n")
      appstore_build_flags = Array(appstore_config['build_flags']).join("\n")
      has_product_id_marker = [project_yml_content, plist_content, pbxproj_content, appstore_build_flags]
        .join("\n")
        .match?(/AppStoreProductID|INFOPLIST_KEY_AppStoreProductID/)

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

      # 5d2. App Store Connect IAP record exists
      print '  │ ASC IAP record... '
      if configured_product_id.empty?
        puts '⏭️  skipped (no appstore.product_id configured)'
      elsif asc_app_id.to_s.strip.empty?
        puts '⚠️  skipped (no ASC app_id)'
        warnings << 'Cannot verify IAP in App Store Connect without appstore.app_id'
      else
        iap_status = asc_iap_status(app_id: asc_app_id, product_id: configured_product_id)
        case iap_status
        when Hash
          if !iap_status[:exists]
            puts "❌ #{configured_product_id} not found"
            issues << "App Store Connect has no in-app purchase with product_id #{configured_product_id}"
          elsif iap_status[:rejected_localization]
            puts "❌ #{configured_product_id} (#{iap_status[:state]})"
            issues << "App Store Connect IAP #{configured_product_id} has a REJECTED localization — Apple requires a new product_id for a replacement IAP."
          elsif %w[WAITING_FOR_REVIEW IN_REVIEW APPROVED READY_FOR_SALE].include?(iap_status[:state])
            puts "✅ #{configured_product_id} (#{iap_status[:state]})"
          elsif iap_status[:state] == 'READY_TO_SUBMIT'
            attachable_lane_states = (APP_STORE_EDITABLE_STATES + APP_STORE_ACTIVE_SUBMISSION_STATES).uniq
            ready_lane = lane_reports.find do |_platform, report|
              attachable_lane_states.include?(report[:target_state].to_s)
            end
            ready_lane_platform = ready_lane&.first
            ui_attached = if ready_lane_platform
                            appstore_version_ui_includes_iap?(
                              app_id: asc_app_id,
                              platform: ready_lane_platform,
                              product_id: configured_product_id
                            )
                          end

            if ui_attached
              puts "⚠️  #{configured_product_id} (READY_TO_SUBMIT, attached on version page)"
              warnings << "App Store Connect still reports IAP #{configured_product_id} as READY_TO_SUBMIT, but Safari verified it is attached under Included Assets for #{ready_lane_platform} #{version_str}"
            else
              puts "❌ #{configured_product_id} (READY_TO_SUBMIT)"
              issues << "App Store Connect IAP #{configured_product_id} is still READY_TO_SUBMIT — Apple requires it to be added to the app version's In-App Purchases and Subscriptions section before submission."
            end
          else
            puts "❌ #{configured_product_id} (#{iap_status[:state]})"
            issues << "App Store Connect IAP #{configured_product_id} exists but is not review-ready (state=#{iap_status[:state]})"
          end
        when nil
          puts '⚠️  lookup failed'
          warnings << "Could not verify App Store Connect IAP record for #{configured_product_id}"
        else
          puts "❌ #{configured_product_id} not found"
          issues << "App Store Connect has no in-app purchase with product_id #{configured_product_id}"
        end
      end

      # 5e. Monetization guardrails (hard-fail for App Store submissions)
      print '  │ Monetization guardrails... '
      monetization_report = monetization_guardrail_report(
        source_blob: monetization_source_blob(swift_files: swift_files),
        configured_product_id: configured_product_id,
        has_product_id_marker: has_product_id_marker,
        strict_appstore_product_id: uses_storekit_unlock,
        shared_or_package_branch: shared_or_package_app_store_branch?(swift_files: swift_files)
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

      # 5f. iOS/watch signing and provisioning profile entitlement audit
      print '  │ iOS signing & profiles... '
      mobile_signing_targets = appstore_mobile_signing_targets(project_yml)
      if platforms.include?('ios') || mobile_signing_targets.any?
        signing_issues = []
        signing_warnings = []
        identities_out, = Open3.capture2e('security', 'find-identity', '-v', '-p', 'codesigning')
        unless identities_out.include?('Apple Distribution:')
          signing_issues << 'Apple Distribution signing identity is missing from the local keychain — iOS/watch App Store archives cannot sign'
        end

        profile_cache = {}
        if mobile_signing_targets.empty?
          signing_warnings << 'No iOS/watch Release-AppStore targets found in project.yml — verify the mobile App Store lane manually'
        end

        mobile_signing_targets.each do |target|
          unless target[:code_sign_identity].include?('Apple Distribution')
            signing_issues << "#{target[:name]} Release-AppStore is not using Apple Distribution signing"
          end

          if target[:provisioning_profile].to_s.empty?
            signing_issues << "#{target[:name]} Release-AppStore is missing PROVISIONING_PROFILE_SPECIFIER"
            next
          end

          if target[:code_sign_style] != 'Manual'
            signing_warnings << "#{target[:name]} Release-AppStore still uses automatic signing — the Mini path is safer with explicit App Store profiles"
          end

          profile = installed_mobileprovision_by_name(target[:provisioning_profile], profile_cache)
          unless profile.is_a?(Hash)
            signing_issues << "Provisioning profile \"#{target[:provisioning_profile]}\" for #{target[:name]} is not installed locally"
            next
          end

          profile_entitlements = profile['Entitlements'].is_a?(Hash) ? profile['Entitlements'] : {}
          profile_groups = Array(profile_entitlements['com.apple.security.application-groups']).map(&:to_s)
          target[:app_groups].each do |group|
            next if profile_groups.include?(group)

            signing_issues << "Provisioning profile \"#{target[:provisioning_profile]}\" for #{target[:name]} does not allow app group #{group}"
          end
        end

        if signing_issues.empty?
          detail = mobile_signing_targets.empty? ? 'no mobile targets found' : "#{mobile_signing_targets.count} target(s) checked"
          puts "✅ #{detail}"
        else
          puts "❌ #{signing_issues.first}"
          signing_issues.each { |msg| issues << msg }
        end
        signing_warnings.each { |msg| warnings << msg }
      else
        puts '⏭️  skipped (no iOS App Store lane)'
      end

      # 5f2. macOS App Store signing audit
      print '  │ macOS App Store signing... '
      mac_signing_targets = appstore_macos_signing_targets(project_yml)
      if platforms.include?('macos') || mac_signing_targets.any?
        mac_signing_issues = []
        mac_signing_warnings = []
        identities_out, = Open3.capture2e('security', 'find-identity', '-v', '-p', 'codesigning')
        unless identities_out.include?('Apple Distribution:')
          mac_signing_issues << 'Apple Distribution signing identity is missing from the local keychain — macOS App Store archives cannot sign correctly'
        end

        installer_identities_out, = Open3.capture2e('security', 'find-identity', '-v', '-p', 'basic')
        has_mac_app_store_installer_identity =
          installer_identities_out.include?('3rd Party Mac Developer Installer') ||
          installer_identities_out.include?('Mac Installer Distribution')
        unless has_mac_app_store_installer_identity
          mac_signing_warnings << 'Mac App Store installer signing identity is missing from the local keychain — macOS App Store export/upload will fail after archive'
        end

        if mac_signing_targets.empty?
          mac_signing_warnings << 'No macOS Release-AppStore targets found in project.yml — verify the desktop App Store lane manually'
        end

        mac_signing_targets.each do |target|
          unless target[:code_sign_identity].include?('Apple Distribution')
            mac_signing_issues << "#{target[:name]} Release-AppStore is not pinned to Apple Distribution signing"
          end

          if target[:provisioning_profile].to_s.empty?
            mac_signing_issues << "#{target[:name]} Release-AppStore is missing PROVISIONING_PROFILE_SPECIFIER"
            next
          end

          if target[:code_sign_style] == 'Automatic'
            mac_signing_warnings << "#{target[:name]} Release-AppStore still uses automatic signing — verify the archive is actually signed with Apple Distribution on the Mini"
          end

          profile_cache ||= {}
          profile = installed_mobileprovision_by_name(target[:provisioning_profile], profile_cache)
          unless profile.is_a?(Hash)
            mac_signing_issues << "Provisioning profile \"#{target[:provisioning_profile]}\" for #{target[:name]} is not installed locally"
            next
          end

          profile_cert_names = Array(profile['DeveloperCertificates']).map { |cert| cert['CommonName'].to_s }.reject(&:empty?)
          unless profile_cert_names.any? { |name| name.include?('Apple Distribution:') }
            detail = profile_cert_names.empty? ? 'no embedded signing certificates' : profile_cert_names.join(', ')
            mac_signing_issues << "Provisioning profile \"#{target[:provisioning_profile]}\" for #{target[:name]} is not tied to Apple Distribution signing (found: #{detail})"
          end
        end

        if mac_signing_issues.empty?
          detail = mac_signing_targets.empty? ? 'no macOS targets found' : "#{mac_signing_targets.count} target(s) checked"
          puts "✅ #{detail}"
        else
          puts "❌ #{mac_signing_issues.first}"
          mac_signing_issues.each { |msg| issues << msg }
        end
        mac_signing_warnings.each { |msg| warnings << msg }
      else
        puts '⏭️  skipped (no macOS App Store lane)'
      end

      # 5g. Reviewer access + business-model guardrails
      print '  │ Reviewer access guardrails... '
      reviewer_access_report = reviewer_access_guardrail_report(
        source_blob: reviewer_guardrail_source_blobs(swift_files: swift_files),
        appstore_config: appstore_config,
        platforms: platforms
      )
      if reviewer_access_report[:applicable]
        if reviewer_access_report[:issues].empty?
          puts "✅ #{reviewer_access_report[:summary]}"
        else
          puts "❌ #{reviewer_access_report[:issues].first}"
          reviewer_access_report[:issues].each { |msg| issues << "Review access guard: #{msg}" }
        end
        reviewer_access_report[:warnings].each { |msg| warnings << "Review access guard: #{msg}" }
      else
        puts '⏭️  skipped (no account/demo/license reviewer path detected)'
      end

      # 5g2. App Store policy guardrails for common rejection classes
      print '  │ App Store policy guardrails... '
      review_notes_blob = platforms.map { |platform| review_notes_for_platform(appstore_config, platform) }.join("\n")
      policy_report = appstore_policy_guardrail_report(
        source_blob: [all_source, project_yml_content, plist_content, pbxproj_content].join("\n"),
        review_notes_blob: review_notes_blob
      )
      if policy_report[:applicable]
        if policy_report[:issues].empty?
          puts "✅ #{policy_report[:summary]}"
        else
          puts "❌ #{policy_report[:issues].first}"
          policy_report[:issues].each { |msg| issues << "Policy guard: #{msg}" }
        end
        policy_report[:warnings].each { |msg| warnings << "Policy guard: #{msg}" }
      else
        puts '⏭️  skipped (no high-risk App Store automation patterns detected)'
      end

      # 5g3. App Store target graph audit
      print '  │ App Store target graph... '
      project_manifest = if project_yml && File.exist?(project_yml)
                           YAML.safe_load(File.read(project_yml)) || {}
                         else
                           nil
                         end
      if platforms.include?('macos') && project_manifest.is_a?(Hash)
        direct_scheme = (config['scheme'] || app_name).to_s
        appstore_scheme = (appstore_config['scheme'] || direct_scheme).to_s
        graph_issues = appstore_target_graph_issues(
          manifest: project_manifest,
          direct_scheme: direct_scheme,
          appstore_scheme: appstore_scheme,
          platform: 'macOS'
        )
        if graph_issues.empty?
          puts "✅ #{appstore_scheme}"
        else
          puts "❌ #{graph_issues.first}"
          graph_issues.each { |msg| issues << "App Store target graph: #{msg}" }
        end
      else
        puts '⏭️  skipped'
      end

      # 5h. Build App Store config and audit resulting artifact for runtime blockers
      print '  │ Compiled App Store artifact audit... '
      platforms = Array(appstore_config['platforms'] || ['macos']).map(&:to_s)
      if platforms.include?('macos')
        compiled_artifact_verified_clean = false
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
            effective_build_flags = Array(appstore_config['build_flags']).map(&:to_s).reject(&:empty?)
            unless configured_product_id.empty? || effective_build_flags.any? { |flag| flag.start_with?('INFOPLIST_KEY_AppStoreProductID=') }
              effective_build_flags << "INFOPLIST_KEY_AppStoreProductID=#{configured_product_id}"
            end
            build_cmd.concat(effective_build_flags)
            build_cmd.concat(Array(appstore_config['archive_extra_args']).map(&:to_s).reject(&:empty?))

            build_out, build_status = Open3.capture2e(*build_cmd)
            unless build_status.success?
              puts '❌ build failed'
              hint = summarized_output_tail(build_out)
              puts "  │   ↳ #{hint}" unless hint.empty?
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
            plist_dump = File.read(info_plist) rescue ''
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
              strings_out, = Open3.capture2('strings', '-a', binary_path)
              nm_out, = Open3.capture2('nm', '-m', binary_path)
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
                artifact_blob = [plist_dump, strings_out, nm_out, otool_out].join("\n")
                artifact_issues = []
                artifact_warnings = []
                launch_daemons_dir = File.join(app_dir, 'Contents', 'Library', 'LaunchDaemons')

                if Dir.exist?(launch_daemons_dir)
                  artifact_issues << 'Built App Store artifact still embeds LaunchDaemons payload — Mac App Store apps cannot ship launchd daemons or agents'
                end

                direct_purchase_markers = appstore_direct_purchase_markers(artifact_blob, built_product_id: built_product_id)
                if direct_purchase_markers.any?
                  artifact_issues << "Built App Store artifact still exposes direct-purchase markers (#{direct_purchase_markers.join(', ')})"
                elsif artifact_blob.match?(%r{api\.lemonsqueezy\.com/v1/licenses/validate}i) && !built_product_id.empty?
                  artifact_warnings << 'Built App Store artifact still contains LemonSqueezy license-validation strings — verify website-license code is unreachable in the App Store build'
                end

                donation_markers = appstore_donation_markers(artifact_blob)
                if donation_markers.any?
                  artifact_issues << "Built App Store artifact still exposes donation/support markers (#{donation_markers.join(', ')})"
                end

                update_markers = appstore_update_markers(strings_out: strings_out, otool_out: otool_out)
                if update_markers.any?
                  artifact_issues << "Built App Store artifact still exposes outside-update markers (#{update_markers.join(', ')})"
                end

                if review_notes_blob.match?(/does not request accessibility/i) &&
                   artifact_blob.include?('NSAccessibilityUsageDescription')
                  artifact_issues << 'Review notes claim no Accessibility request, but built Info.plist still declares NSAccessibilityUsageDescription'
                end

                if review_notes_blob.match?(/does not request.*apple events|no apple events/i) &&
                   artifact_blob.include?('NSAppleEventsUsageDescription')
                  artifact_issues << 'Review notes claim no Apple Events request, but built Info.plist still declares NSAppleEventsUsageDescription'
                end

                accessibility_markers = []
                accessibility_markers << 'ApplicationServices linkage' if otool_out.include?('ApplicationServices.framework')
                accessibility_markers << 'AXIsProcessTrusted symbol' if nm_out.match?(/_AXIsProcessTrusted/)
                accessibility_markers << 'Accessibility settings deep link' if strings_out.include?('Privacy_Accessibility')
                if accessibility_markers.any?
                  artifact_issues << "Built App Store artifact still contains Accessibility markers (#{accessibility_markers.join(', ')})"
                end

                apple_events_markers = []
                apple_events_markers << 'osascript runtime' if artifact_blob.include?('/usr/bin/osascript')
                apple_events_markers << 'Apple Events usage description' if artifact_blob.include?('NSAppleEventsUsageDescription')
                if apple_events_markers.any?
                  artifact_warnings << "Built App Store artifact still contains Apple Events markers (#{apple_events_markers.join(', ')}) — verify App Review notes and App Store policy fit"
                end

                if artifact_issues.empty?
                  puts '✅'
                  compiled_artifact_verified_clean = true
                else
                  puts "❌ #{artifact_issues.first}"
                  artifact_issues.each { |msg| issues << msg }
                end
                artifact_warnings.each { |msg| warnings << msg }
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
        if compiled_artifact_verified_clean
          warnings.delete('Policy guard: Source contains clipboard automation for non-App-Store builds, but the App Store build script strips automation usage descriptions and review notes describe manual paste. Verify the compiled App Store artifact before blocking submission.')
        end
      else
        puts '⏭️  skipped (non-macOS submission)'
      end

      # 5h. No DEBUG/development code leaking into release
      print '  │ Reserved shortcuts... '
      lsui_element = plist_content.include?('LSUIElement') || project_yml_content.include?('LSUIElement:')
      quit_shortcut_wired =
        all_source.match?(/app\.mainMenu\s*=|CommandGroup\s*\(\s*replacing:\s*\.appTermination|CommandMenu\s*\(\s*"App"|keyEquivalent:\s*"q"/)
      if lsui_element
        if quit_shortcut_wired
          puts '✅ menu bar app exposes explicit quit command wiring'
        else
          puts '❌ no explicit quit wiring found'
          issues << 'Menu bar app has LSUIElement enabled, but preflight could not find explicit Command-Q / quit-menu wiring'
        end
      else
        puts '⏭️  skipped (not an LSUIElement app)'
      end

      # 5i. No DEBUG/development code leaking into release
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
      normalized_platforms = Array(platforms).map { |p| p.to_s.downcase }.uniq
      normalized_platforms = %w[macos] if normalized_platforms.empty?
      platform_notes = normalized_platforms.to_h do |platform|
        [platform, review_notes_for_platform(appstore_config, platform).to_s]
      end
      notes_text = platform_notes.values.reject(&:empty?).join("\n")

      if notes_text && !notes_text.strip.empty?
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

        review_permission_keys = effective_required_keys.reject do |plist_key, _|
          %w[NSAccessibilityUsageDescription NSAppleEventsUsageDescription].include?(plist_key)
        end

        review_permission_keys.each_key do |plist_key|
          check = permission_keywords[plist_key]
          next unless check

          has_explanation = check[:required_terms].any? { |term| notes_text.downcase.include?(term.downcase) }
          unless has_explanation
            notes_issues << "Review notes mention #{check[:name]} but lack technical detail — #{check[:guidance]}"
          end
        end

        if notes_issues.empty?
          puts "✅ (#{platform_notes.values.reject(&:empty?).count} note variant(s), #{notes_text.length} chars total)"
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
