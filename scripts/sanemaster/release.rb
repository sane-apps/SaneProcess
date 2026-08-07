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
require 'optparse'
require 'base64'
require 'digest'
require 'socket'
require 'pathname'
require_relative 'upgrade_path_proof'
require_relative 'source_fingerprint'

module SaneMasterModules
  # Unified release entrypoint (delegates to SaneProcess release.sh)
  module Release
    include SaneMasterModules::UpgradePathProof
    ENV_CACHE_FILE = File.expand_path(ENV.fetch('SANE_ENV_CACHE_FILE', '~/.config/nv/env'))
    DEFAULT_LAUNCH_READY_MAX_PREFLIGHT_AGE_DAYS = 7
    UNTRACKED_SWIFT_MAX_BYTES = 2 * 1024 * 1024
    REQUIRED_LAUNCH_PACKAGE_FIELDS = %w[
      status
      audience
      problem
      solution
      primary_story
      pricing_proof
      privacy_proof
      proof_assets
      channel_plan
      go_no_go
    ].freeze
    REQUIRED_LAUNCH_PROOF_ASSET_FIELDS = %w[type status].freeze
    # Single source of truth: the fingerprint module must exclude the same
    # receipt paths the release upgrade lane owns, or the identities drift.
    UPGRADE_PATH_RECEIPT_PATHS = SaneSourceFingerprint::UPGRADE_PATH_RECEIPT_PATHS
    UPGRADE_PATH_RECEIPT_MAX_AGE_SECONDS = 12 * 60 * 60
    SIGNED_RECEIPT_CLOCK_SKEW_SECONDS = 5

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

    def swift_test_only_path?(path)
      normalized = path.to_s.sub(%r{\A\./}, '')
      components = normalized.split('/')
      return true if components.any? { |component| component.match?(/(?:UI)?Tests\z/) }

      File.basename(normalized).match?(/(?:Test|Tests|Spec)\.swift\z/)
    end

    def git_diff_destination_path(header)
      raw_path = header.to_s.delete_prefix('+++ ').strip
      return nil if raw_path == '/dev/null'

      if raw_path.start_with?('"')
        raw_path = JSON.parse(raw_path)
      end
      raw_path.delete_prefix('b/')
    rescue JSON::ParserError
      nil
    end

    def added_swift_lines_by_file(diff)
      current_path = nil
      diff.to_s.each_line.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, added_lines|
        if line.start_with?('+++ ')
          current_path = git_diff_destination_path(line)
          current_path = nil unless current_path&.end_with?('.swift')
          next
        end
        next unless current_path && line.start_with?('+') && !line.start_with?('+++')

        added_lines[current_path] << line.delete_prefix('+')
      end
    end

    def defaults_migration_changed_files_from_diff(diff)
      pattern = /UserDefaults|setDefaultsIfNeeded|registerDefaults|migration|migrate/i
      path_pattern = /(?:Defaults?|Preferences?|Migration)/i
      default_map_pattern = /(?:\bUserDefaults(?:\.standard)?|\b[a-zA-Z_]\w*)\s*\.register\s*\(\s*defaults\s*:|\b(?:registered|registration|initial|factory|standard|user)?Defaults\w*\b\s*(?::[^=\n]+)?=/i
      swift_diff_hunks_by_file(diff).each_with_object([]) do |(path, hunks), files|
        next if swift_test_only_path?(path)
        relevant = hunks.any? do |hunk|
          changed_lines = hunk[:added] + hunk[:deleted]
          hunk_lines = changed_lines + hunk[:context]
          changed_lines.any? { |line| line.match?(pattern) } ||
            (changed_lines.any? && path.match?(path_pattern)) ||
            (changed_lines.any? && hunk_lines.any? { |line| line.match?(default_map_pattern) }) ||
            (hunk[:added].any? && hunk[:deleted].any? && hunk[:context].any? { |line| line.match?(pattern) })
        end
        next unless relevant

        files << path
      end.sort
    end

    def swift_diff_hunks_by_file(diff)
      current_path = nil
      current_hunk = nil
      diff.to_s.each_line.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, files|
        if line.start_with?('diff --git ')
          paths = Shellwords.shellsplit(line.delete_prefix('diff --git ').strip)
          current_path = paths.last&.delete_prefix('b/')
          current_path = nil unless current_path&.end_with?('.swift')
          current_hunk = nil
          next
        end
        if line.start_with?('+++ ')
          destination = git_diff_destination_path(line)
          current_path = destination if destination&.end_with?('.swift')
          next
        end
        next unless current_path

        if line.start_with?('@@')
          current_hunk = { added: [], deleted: [], context: [] }
          files[current_path] << current_hunk
          next
        end
        next if line.start_with?('--- ', '+++ ')
        next unless line.start_with?('+', '-', ' ')

        unless current_hunk
          current_hunk = { added: [], deleted: [], context: [] }
          files[current_path] << current_hunk
        end
        if line.start_with?('+')
          current_hunk[:added] << line.delete_prefix('+')
        elsif line.start_with?('-')
          current_hunk[:deleted] << line.delete_prefix('-')
        else
          current_hunk[:context] << line.delete_prefix(' ')
        end
      end
    rescue ArgumentError
      {}
    end

    def release_unreleased_history_base(repo_dir)
      tags_output, tags_status = Open3.capture2e('git', '-C', repo_dir, 'tag', '--merged', 'HEAD', '--list')
      stable_tags = if tags_status.success?
                      tags_output.lines.map(&:strip).grep(/\Av\d+\.\d+\.\d+\z/)
                    else
                      []
                    end
      unless stable_tags.empty?
        describe_args = ['git', '-C', repo_dir, 'describe', '--tags', '--abbrev=0']
        stable_tags.each { |tag| describe_args.concat(['--match', tag]) }
        tag, status = Open3.capture2e(*describe_args, 'HEAD')
        return tag.strip if status.success? && tag.to_s.strip.match?(/\Av\d+\.\d+\.\d+\z/)
      end

      '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
    end

    def upgrade_path_behavioral_proof_report(app_name:, routed_workspace: nil, project_path: Dir.pwd,
                                             source_fingerprint: nil, now: Time.now.utc)
      receipt, receipt_path = upgrade_path_behavioral_receipt(
        routed_workspace: routed_workspace,
        project_path: project_path
      )
      return { ok: false, error: 'upgrade-path behavioral proof receipt is missing' } unless receipt.is_a?(Hash)
      return { ok: false, error: receipt['_route_error'].to_s } if receipt['_route_error']

      expected_fingerprint = source_fingerprint.to_s
      expected_fingerprint = release_status_source_fingerprint(project_path).to_s if expected_fingerprint.empty?
      generated_at = Time.parse(receipt['generatedAt'].to_s)
      max_age = ENV.fetch(
        'SANEPROCESS_UPGRADE_PATH_RECEIPT_MAX_AGE_SECONDS',
        UPGRADE_PATH_RECEIPT_MAX_AGE_SECONDS.to_s
      ).to_i
      current_version = Dir.chdir(project_path) { release_current_project_version[:version].to_s }
      errors = []
      errors << 'receipt type must be upgrade_path_behavioral_proof' unless receipt['type'].to_s == 'upgrade_path_behavioral_proof'
      errors << 'receipt status is not passed' unless receipt['status'].to_s == 'passed'
      errors << 'receipt is not marked behavioral' unless receipt['behavioral'] == true
      errors << "receipt app does not match #{app_name}" unless receipt['app'].to_s == app_name.to_s
      errors << 'receipt did not execute any upgrade scenarios' unless receipt['testsRun'].to_i.positive?
      errors << 'receipt was not generated on Mini runtime' unless receipt['miniRuntime'] == true
      errors << 'receipt source fingerprint is missing or stale' if expected_fingerprint.empty? || receipt['sourceFingerprint'].to_s != expected_fingerprint
      errors << 'receipt fromVersion is missing' if receipt['fromVersion'].to_s.strip.empty?
      errors << 'receipt toVersion is missing' if receipt['toVersion'].to_s.strip.empty?
      if !current_version.empty? && receipt['toVersion'].to_s != current_version
        errors << "receipt toVersion #{receipt['toVersion']} does not match current version #{current_version}"
      end
      errors << 'receipt does not prove an upgrade between different versions' if receipt['fromVersion'].to_s == receipt['toVersion'].to_s
      errors << 'receipt is future-dated' if generated_at > now + SIGNED_RECEIPT_CLOCK_SKEW_SECONDS
      errors << 'receipt is stale' if max_age.positive? && (now - generated_at) > max_age
      artifact_error = upgrade_path_verify_artifacts(receipt, project_path)
      errors << artifact_error if artifact_error

      return { ok: false, error: errors.join('; '), receipt_path: receipt_path } if errors.any?

      {
        ok: true,
        receipt_path: receipt_path,
        evidence: receipt.reject { |key, _value| key == '__ts__' }
      }
    rescue ArgumentError, TypeError => e
      { ok: false, error: "upgrade-path behavioral proof receipt is malformed: #{e.message}", receipt_path: receipt_path }
    end

    def release_verify_evidence_from_metrics(since:, source_fingerprint:, project_path: Dir.pwd, metrics_path: nil)
      path = metrics_path || (respond_to?(:process_metrics_path) ? process_metrics_path : nil)
      return nil if path.to_s.empty? || !File.file?(path)

      expected_root = File.realpath(project_path)
      since_time = since.is_a?(Time) ? since : Time.parse(since.to_s)
      File.readlines(path, chomp: true).reverse_each do |line|
        event = JSON.parse(line)
        next unless event['type'].to_s == 'verify' && event['success'] == true
        next unless event['tests_run'].to_i.positive?
        next if %w[build_only failed].include?(event['evidence_strength'].to_s)
        next unless event['source_fingerprint'].to_s == source_fingerprint.to_s
        next unless File.realpath(event['cwd'].to_s) == expected_root
        next unless event['host'].to_s.downcase.include?('mini')

        timestamp = Time.parse(event['timestamp'].to_s)
        next if timestamp < since_time - 1 || timestamp > Time.now.utc + 300

        return {
          'type' => 'verify',
          'success' => true,
          'timestamp' => timestamp.utc.iso8601,
          'host' => event['host'],
          'cwd' => expected_root,
          'testsRun' => event['tests_run'].to_i,
          'evidenceStrength' => event['evidence_strength'],
          'sourceFingerprint' => event['source_fingerprint']
        }
      rescue JSON::ParserError, ArgumentError, Errno::ENOENT, Errno::EACCES
        next
      end
      nil
    rescue StandardError
      nil
    end

    def release_verify_result_valid?(status:, evidence:)
      status && status.success? && evidence.is_a?(Hash) && evidence['success'] == true
    end

    def upgrade_path_behavioral_receipt(routed_workspace:, project_path:)
      project_root = File.realpath(project_path)
      UPGRADE_PATH_RECEIPT_PATHS.reverse_each do |relative_path|
        path = File.join(project_root, relative_path)
        next unless release_regular_file_without_symlinked_parent?(path)
        verified = upgrade_path_read_signed(path, producer: UPGRADE_PRODUCER)
        next unless verified.is_a?(Hash)

        return [verified, path]
      end
      [nil, nil]
    rescue StandardError => e
      [{ '_route_error' => "upgrade-path behavioral proof receipt is invalid: #{e.message}" }, path]
    end

    def recent_swift_diff_for_preflight(routed_workspace)
      if routed_workspace.is_a?(Hash) && routed_workspace.key?('recent_swift_diff')
        routed_error = routed_workspace['recent_swift_diff_error'].to_s.strip
        raise "Unable to inspect recent Swift changes: #{routed_error}" unless routed_error.empty?

        return routed_workspace['recent_swift_diff'].to_s
      end

      # Diff the latest released tag against the working tree so every
      # unreleased commit plus staged/unstaged release work is inspected.
      range = release_unreleased_history_base(Dir.pwd)
      output, status = Open3.capture2(
        'git', 'diff', range, '--unified=3', '--no-color', '--no-ext-diff', '--', '*.swift'
      )
      raise 'Unable to inspect tracked Swift changes with git diff' unless status.success?

      untracked_output, untracked_status = Open3.capture2(
        'git', 'ls-files', '-z', '--others', '--exclude-standard', '--', '*.swift'
      )
      raise 'Unable to inspect untracked Swift files with git ls-files' unless untracked_status.success?

      untracked_paths = untracked_output.split("\0").reject(&:empty?)
      untracked_diff, untracked_error = release_untracked_swift_diff(Dir.pwd, untracked_paths)
      raise "Unable to inspect untracked Swift changes: #{untracked_error}" if untracked_error

      output.to_s + untracked_diff
    end

    def release_untracked_swift_diff(repo_dir, paths)
      chunks = paths.map do |relative_path|
        absolute_path = File.expand_path(relative_path, repo_dir)
        repo_root = File.realpath(repo_dir)
        metadata = File.lstat(absolute_path)
        raise "symlink or non-regular path #{relative_path}" unless metadata.file?
        raise "file exceeds #{UNTRACKED_SWIFT_MAX_BYTES} bytes: #{relative_path}" if metadata.size > UNTRACKED_SWIFT_MAX_BYTES

        real_path = File.realpath(absolute_path)
        raise "path escapes repository #{relative_path}" unless real_path.start_with?("#{repo_root}/")

        contents = File.binread(real_path, UNTRACKED_SWIFT_MAX_BYTES + 1)
        raise "file grew beyond size limit: #{relative_path}" if contents.bytesize > UNTRACKED_SWIFT_MAX_BYTES
        contents = contents.force_encoding(Encoding::UTF_8)
        contents = contents.scrub('?') unless contents.valid_encoding?
        source = JSON.generate("a/#{relative_path}")
        destination = JSON.generate("b/#{relative_path}")
        added = contents.each_line.map { |line| "+#{line}" }.join
        added << "\n" unless added.empty? || added.end_with?("\n")
        "diff --git #{source} #{destination}\n--- /dev/null\n+++ #{destination}\n#{added}"
      end
      [chunks.join, nil]
    rescue StandardError => e
      ['', e.message]
    end

    def auto_reconcile_stash_noise_file?(path)
      normalized = path.to_s.sub(%r{\A\./}, '')
      return true if normalized.empty?
      return true if normalized.end_with?('/.DS_Store') || normalized == '.DS_Store'
      return true if normalized == 'default.profraw'
      return true if normalized == 'fastlane/report.xml'
      return true if normalized.start_with?('fastlane/reports/')
      return true if normalized.match?(%r{\A\.claude/(audit_log\.jsonl|edit_count\.json|tool_count\.json|active_skills\.json)\z})

      false
    end

    def blocking_auto_reconcile_stash_files(files)
      Array(files)
        .map { |path| path.to_s.strip }
        .reject(&:empty?)
        .reject { |path| auto_reconcile_stash_noise_file?(path) }
        .uniq
        .sort
    end

    def git_object_content(repo_path, object_spec)
      output, status = Open3.capture2e('git', '-C', repo_path, 'show', object_spec)
      [status.success?, output]
    end

    def stash_file_matches_head?(repo_path, ref, path)
      stash_ok, stash_content = git_object_content(repo_path, "#{ref}:#{path}")
      head_ok, head_content = git_object_content(repo_path, "HEAD:#{path}")
      return true if !stash_ok && !head_ok
      return false unless stash_ok && head_ok

      stash_content == head_content
    end

    def unresolved_auto_reconcile_stash_files(repo_path, ref, files)
      blocking_auto_reconcile_stash_files(files).reject do |path|
        stash_file_matches_head?(repo_path, ref, path)
      end
    end

    def reviewed_auto_reconcile_stash?(config, report)
      entries = config.dig('release', 'reviewed_auto_reconcile_stashes')
      return false unless entries.is_a?(Array)

      entries.any? do |entry|
        next false unless entry.is_a?(Hash)

        decision = entry['decision'].to_s.strip
        stash_sha = entry['stash_sha'].to_s.strip
        subject = entry['subject'].to_s.strip
        reason = entry['reason'].to_s.strip
        next false unless %w[recovered superseded deferred archived].include?(decision)
        next false if reason.empty?
        next false unless !stash_sha.empty? && stash_sha == report[:stash_sha].to_s

        subject.empty? || subject == report[:subject].to_s
      end
    end

    def auto_reconcile_stash_reports(repo_path: Dir.pwd, limit: 30)
      return [] unless File.directory?(File.join(repo_path, '.git'))

      list_output, list_status = Open3.capture2e(
        'git', '-C', repo_path, 'stash', 'list', '--format=%gd%x09%H%x09%gs'
      )
      return [] unless list_status.success?

      reports = []
      list_output.lines.each do |line|
        ref, stash_sha, subject = line.chomp.split("\t", 3)
        next unless ref && subject&.include?('auto-reconcile-')

        files_output, files_status = Open3.capture2e(
          'git', '-C', repo_path, 'stash', 'show', '--include-untracked',
          '--name-only', '--format=', ref
        )
        next unless files_status.success?

        blocking_files = unresolved_auto_reconcile_stash_files(repo_path, ref, files_output.lines)
        next if blocking_files.empty?

        reports << {
          ref: ref,
          stash_sha: stash_sha.to_s,
          subject: subject,
          blocking_files: blocking_files
        }
      end
      reports.first(limit)
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

    def project_info_plist_paths
      ignored_segments = %w[
        .build
        .swiftpm
        Build
        build
        DerivedData
        Pods
        SourcePackages
        vendor
      ]
      ignored_nested = [
        %w[Carthage Checkouts]
      ]

      Dir.glob('**/Info.plist').reject do |path|
        segments = path.split(File::SEPARATOR)
        ignored_segments.any? { |segment| segments.include?(segment) } ||
          segments.any? { |segment| segment.end_with?('.xcarchive') } ||
          ignored_nested.any? { |nested| segments.each_cons(nested.length).any? { |candidate| candidate == nested } }
      end
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

    def appstore_application_bundle_ids(project_yml_path, platform:)
      return [] unless project_yml_path && File.exist?(project_yml_path)

      project = YAML.safe_load(File.read(project_yml_path)) || {}
      targets = project['targets'] || {}
      wanted_platform = platform.to_s.downcase

      targets.each_with_object([]) do |(_name, spec), bundle_ids|
        next unless spec.is_a?(Hash)
        next unless spec['type'].to_s == 'application'
        next unless spec['platform'].to_s.downcase == wanted_platform

        bundle_id =
          spec.dig('settings', 'configs', 'Release-AppStore', 'PRODUCT_BUNDLE_IDENTIFIER') ||
          spec.dig('settings', 'base', 'PRODUCT_BUNDLE_IDENTIFIER') ||
          spec['bundleId']
        bundle_id = bundle_id.to_s.strip
        next if bundle_id.empty? || bundle_id.include?('$(')

        bundle_ids << bundle_id
      end.uniq
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
        next unless spec['type'].to_s == 'application'

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

    def release_source_files_for_api_compatibility
      Dir.glob('**/*.swift').reject do |path|
        path.include?('/Tests/') ||
          path.start_with?('Tests/') ||
          path.include?('/DerivedData/') ||
          path.include?('/.build/') ||
          path.include?('/build/') ||
          path.include?('/outputs/')
      end
    end

    def api_compatibility_guardrail_rules
      [
        {
          symbol: 'SCScreenshotConfiguration',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 screenshot configuration class causes dyld launch crashes on macOS 15 builds'
        },
        {
          symbol: 'SCScreenshotOutput',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 screenshot output class causes dyld launch crashes on macOS 15 builds'
        },
        {
          symbol: 'captureScreenshot(contentFilter:',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 screenshot API requires SCScreenshotConfiguration/SCScreenshotOutput'
        },
        {
          symbol: 'captureScreenshot(rect:',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 screenshot API requires SCScreenshotConfiguration/SCScreenshotOutput'
        },
        {
          symbol: 'SCStreamConfigurationPresetCaptureHDRScreenshotLocalDisplay',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 HDR screenshot preset is unavailable on older supported systems'
        },
        {
          symbol: 'SCStreamConfigurationPresetCaptureHDRScreenshotCanonicalDisplay',
          introduced: '26.0',
          framework: 'ScreenCaptureKit',
          reason: 'macOS 26 HDR screenshot preset is unavailable on older supported systems'
        }
      ]
    end

    def api_compatibility_guardrail_report(config:, source_files: nil)
      min_system_version = config.dig('release', 'min_system_version').to_s.strip
      return { applicable: false, issues: [], warnings: [], summary: 'no release.min_system_version configured' } if min_system_version.empty?

      files = source_files || release_source_files_for_api_compatibility
      issues = []
      api_compatibility_guardrail_rules.each do |rule|
        next unless compare_semver(min_system_version, rule[:introduced]) == -1

        matching_files = files.select do |path|
          File.exist?(path) && safe_read(path).include?(rule[:symbol])
        end
        next if matching_files.empty?

        sample = matching_files.first(4).join(', ')
        suffix = matching_files.length > 4 ? " (+#{matching_files.length - 4} more)" : ''
        issues << "#{rule[:framework]} #{rule[:symbol]} requires macOS #{rule[:introduced]} but release.min_system_version is #{min_system_version}: #{sample}#{suffix} — #{rule[:reason]}"
      end

      {
        applicable: true,
        issues: issues,
        warnings: [],
        summary: issues.empty? ? "checked #{files.length} Swift source file(s) against macOS #{min_system_version}" : "#{issues.length} incompatible API marker(s)"
      }
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

    def website_routes_to_download_page?(homepage_body)
      homepage_body.to_s.match?(%r{href\s*=\s*["'](?:https?://[^"']+)?/download(?:[?#][^"']*)?["']}i)
    end

    def website_versioned_archive_version(app_name:, homepage_body:, download_page_body: '')
      archive_pattern = /#{Regexp.escape(app_name)}-(\d+\.\d+(?:\.\d+)?)\.(?:zip|dmg)/
      homepage_version = homepage_body.to_s[archive_pattern, 1].to_s.strip
      return homepage_version unless homepage_version.empty?
      return '' unless website_routes_to_download_page?(homepage_body)

      download_page_body.to_s[archive_pattern, 1].to_s.strip
    end

    def website_versioned_archive_version_for_domain(app_name:, website_domain:)
      homepage_body = fetch_text("https://#{website_domain}")
      download_page_body = if website_routes_to_download_page?(homepage_body)
                             fetch_text("https://#{website_domain}/download")
                           else
                             ''
                           end
      website_versioned_archive_version(
        app_name: app_name,
        homepage_body: homepage_body,
        download_page_body: download_page_body
      )
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

    def informational_appcast_entries_missing_versions(xml)
      xml.to_s.scan(/<item\b.*?<\/item>/m).each_with_object([]) do |item, acc|
        next unless item.include?('<sparkle:informationalUpdate')

        item_build = item[/<sparkle:version>\s*([^<\s]+)\s*<\/sparkle:version>/m, 1] ||
                     item[/sparkle:version="([^"]+)"/, 1]
        next unless item_build.to_s.strip.empty?

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

    def release_project_qa_script
      ['Scripts/qa.rb', 'scripts/qa.rb'].find { |path| File.exist?(path) }
    end

    def release_project_qa_policy_only_supported?(qa_script)
      return false if qa_script.to_s.empty? || !File.exist?(qa_script)

      safe_read(qa_script).include?('SANEPROCESS_RELEASE_POLICY_ONLY')
    end

    def release_project_qa_env(app_name:, policy_only: false, skip_runtime_smoke: false)
      app_prefix = app_name.to_s.upcase.gsub(/[^A-Z0-9]+/, '_')
      env = {
        'LANG' => (ENV['LANG'].to_s.empty? ? 'en_US.UTF-8' : ENV['LANG']),
        'LC_ALL' => (ENV['LC_ALL'].to_s.empty? ? 'en_US.UTF-8' : ENV['LC_ALL']),
        'PATH' => ([ENV['PATH'], '/opt/homebrew/bin', '/usr/local/bin'].compact.join(':'))
      }

      if policy_only
        env['SANEPROCESS_RELEASE_POLICY_ONLY'] = '1'
        env["#{app_prefix}_RELEASE_POLICY_ONLY"] = '1' unless app_prefix.empty?
      else
        env.merge!(
          'SANEPROCESS_RELEASE_PREFLIGHT' => '1',
          'SANEPROCESS_RUN_STABILITY_SUITE' => '1'
        )
        env['SANEPROCESS_RUN_RUNTIME_SMOKE'] = '1' unless skip_runtime_smoke
        unless app_prefix.empty?
          env.merge!(
            "#{app_prefix}_RELEASE_PREFLIGHT" => '1',
            "#{app_prefix}_RUN_STABILITY_SUITE" => '1'
          )
          env["#{app_prefix}_RUN_RUNTIME_SMOKE"] = '1' unless skip_runtime_smoke
        end
        if skip_runtime_smoke
          env['SANEPROCESS_REUSE_CUSTOMER_UI_RUNTIME_PROOF'] = '1'
          env["#{app_prefix}_REUSE_CUSTOMER_UI_RUNTIME_PROOF"] = '1' unless app_prefix.empty?
        end
      end

      env
    end

    def release_customer_ui_runtime_smoke_reusable?(ui_contract_report, app_name:)
      return false unless ui_contract_report.is_a?(Hash) && ui_contract_report[:ok]

      receipt_path = ui_contract_report[:receipt_path].to_s
      receipt_path = release_customer_ui_newest_receipt_path if receipt_path.empty?
      return false if receipt_path.to_s.empty?
      return false unless release_regular_file_without_symlinked_parent?(receipt_path)
      receipt = JSON.parse(safe_read(receipt_path))
      return false unless receipt.is_a?(Hash)
      return false unless receipt['app'].to_s == app_name.to_s
      return false unless receipt['status'].to_s == 'passed'
      expected_source_fingerprint = ui_contract_report[:source_fingerprint].to_s
      if expected_source_fingerprint.empty? && respond_to?(:customer_ui_source_fingerprint, true)
        expected_source_fingerprint = customer_ui_source_fingerprint.to_s
      end
      if !expected_source_fingerprint.empty? && respond_to?(:customer_ui_receipt_source_fingerprint_current?, true)
        return false unless customer_ui_receipt_source_fingerprint_current?(receipt, expected_source_fingerprint)
      elsif !expected_source_fingerprint.empty?
        return false unless receipt['source_fingerprint'].to_s == expected_source_fingerprint
      end

      generated_at = Time.parse(receipt['generated_at'].to_s)
      return false unless release_customer_ui_receipt_time_reusable?(generated_at, max_age_seconds: 12 * 60 * 60)

      expected = release_current_project_version
      evidence = receipt['evidence'].is_a?(Hash) ? receipt['evidence'] : {}
      return false unless release_candidate_value_matches?(evidence['app_version'], expected[:version])
      return false unless release_candidate_value_matches?(evidence['app_build'], expected[:build])

      rows = Array(receipt['runtime_state_results']).select { |row| row.is_a?(Hash) }
      rows_by_id = rows.to_h { |row| [row['id'].to_s, row] }
      required_rows = %w[
        fullscreen_maximize_transition
        wake_visible_zone_persistence
        dynamic_helper_wake_drift
        shared_bundle_exact_id_moves
        hover_auto_rehide
        license_clipboard_paste
        resource_soak_growth
      ]
      return false unless (required_rows - rows_by_id.keys).empty?

      required_rows.all? do |id|
        row = rows_by_id[id]
        candidate = row['runtime_candidate'].is_a?(Hash) ? row['runtime_candidate'] : {}
        row['status'].to_s == 'passed' &&
          release_runtime_candidate_app_path_matches?(candidate['app_path'], app_name) &&
          release_customer_ui_runtime_row_has_durable_evidence?(id, row) &&
          release_candidate_value_matches?(candidate['app_version'], expected[:version]) &&
          release_candidate_value_matches?(candidate['app_build'], expected[:build])
      end
    rescue JSON::ParserError, ArgumentError, TypeError
      false
    end

    def release_customer_ui_receipt_time_reusable?(generated_at, max_age_seconds:)
      generated_at = generated_at.utc
      now = Time.now.utc
      return false if generated_at > now + 5 * 60

      now - generated_at <= max_age_seconds
    end

    def release_runtime_candidate_app_path_matches?(actual_path, app_name)
      expected_path = File.join('/Applications', "#{app_name}.app")
      File.expand_path(actual_path.to_s) == expected_path
    rescue StandardError
      false
    end

    def release_customer_ui_runtime_row_has_durable_evidence?(id, row)
      paths = Array(row['evidence_paths'])
      return false if paths.any? { |path| release_customer_ui_temp_evidence_file?(path) }

      if release_customer_ui_runtime_preflight_required_id?(id)
        return false unless paths.any? { |path| release_customer_ui_durable_runtime_preflight_evidence_file?(id, path) }
      end

      paths.any? do |path|
        release_customer_ui_durable_evidence_file?(path) ||
          release_customer_ui_durable_runtime_preflight_evidence_file?(id, path)
      end
    end

    def release_customer_ui_newest_receipt_path
      %w[
        .sane/customer_ui_action_receipt.json
        outputs/customer_ui_action_receipt.json
      ].map { |path| File.expand_path(path, Dir.pwd) }
        .select { |path| release_regular_file_without_symlinked_parent?(path) }
        .max_by { |path| File.mtime(path) }
    rescue StandardError
      nil
    end

    def release_customer_ui_durable_evidence_file?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      root = File.expand_path(File.join(Dir.pwd, 'outputs', 'customer-ui'))
      expanded = File.realpath(expanded)
      root = File.realpath(root) if File.exist?(root)
      normalized = expanded.tr('\\', '/')
      normalized.start_with?("#{root.tr('\\', '/')}/") &&
        release_regular_file_without_symlinked_parent?(expanded)
    rescue StandardError
      false
    end

    def release_customer_ui_runtime_preflight_required_id?(id)
      %w[hover_auto_rehide license_clipboard_paste].include?(id.to_s)
    end

    def release_customer_ui_durable_runtime_preflight_evidence_file?(id, path)
      basename = case id.to_s
                 when 'hover_auto_rehide'
                   'sanebar_runtime_hover_rehide'
                 when 'license_clipboard_paste'
                   'sanebar_runtime_license_paste'
                 else
                   return false
                 end
      expanded = File.expand_path(path.to_s, Dir.pwd)
      root = File.expand_path(File.join(Dir.pwd, 'outputs', 'runtime-preflight'))
      normalized = expanded.tr('\\', '/')
      normalized.start_with?("#{root.tr('\\', '/')}/") &&
        File.basename(normalized).match?(/\A#{Regexp.escape(basename)}\.(?:json|log|png)\z/) &&
        release_regular_file_without_symlinked_parent?(expanded)
    rescue StandardError
      false
    end

    def release_customer_ui_temp_evidence_file?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      expanded = File.realpath(expanded) if File.exist?(expanded)
      expanded.start_with?('/tmp/') ||
        expanded.start_with?('/private/tmp/') ||
        expanded.start_with?('/var/folders/')
    rescue StandardError
      false
    end

    def release_regular_file_without_symlinked_parent?(path)
      expanded = File.expand_path(path.to_s, Dir.pwd)
      parts = expanded.split(File::SEPARATOR).reject(&:empty?)
      current = expanded.start_with?(File::SEPARATOR) ? File::SEPARATOR : Dir.pwd
      parts.each_with_index do |component, index|
        current = current == File::SEPARATOR ? File.join(current, component) : File.join(current, component)
        stat = File.lstat(current)
        if index == parts.length - 1
          return stat.file? && !stat.symlink?
        end
        return false if stat.symlink? || !stat.directory?
      end
      false
    rescue StandardError
      false
    end

    def release_candidate_value_matches?(actual, expected)
      expected = expected.to_s.strip
      actual = actual.to_s.strip
      return true if expected.empty?

      actual == expected
    end

    def release_current_project_version
      content = File.exist?('project.yml') ? safe_read('project.yml') : ''
      {
        version: project_marketing_version(content),
        build: project_build_number(content)
      }
    end

    def normalize_release_output_chunk(chunk)
      normalized = chunk.dup
      normalized.force_encoding(Encoding::UTF_8)
      return normalized if normalized.valid_encoding?

      chunk.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '?')
    rescue StandardError
      chunk.to_s.encode(Encoding::UTF_8, Encoding::BINARY, invalid: :replace, undef: :replace, replace: '?')
    end

    def capture_release_command_output(env, *cmd, heartbeat_label:, heartbeat_seconds: 8, timeout_seconds: nil)
      output = +''
      status = nil
      started_at = Time.now
      last_output_at = Time.now
      last_heartbeat_at = Time.at(0)
      timed_out = false

      Open3.popen2e(env, *cmd, pgroup: true) do |_stdin, stdout_err, wait_thr|
        loop do
          ready = IO.select([stdout_err], nil, nil, 1)
          if ready
            begin
              chunk = normalize_release_output_chunk(stdout_err.read_nonblock(4096))
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

          if timeout_seconds && timeout_seconds.positive? && (Time.now - started_at) > timeout_seconds
            timed_out = true
            message = "release command timeout after #{timeout_seconds}s: #{cmd.join(' ')}"
            output << "\n#{message}\n"
            puts "\n#{message}"
            terminate_release_command_process(wait_thr.pid, signal: 'TERM')
            wait_thr.join(2) || terminate_release_command_process(wait_thr.pid, signal: 'KILL')
            status = wait_thr.value if wait_thr.join(0)
            break
          end

          next unless (Time.now - last_output_at) >= heartbeat_seconds
          next unless (Time.now - last_heartbeat_at) >= heartbeat_seconds

          elapsed = (Time.now - started_at).round(1)
          puts "    … #{heartbeat_label} still running (#{elapsed}s)"
          last_heartbeat_at = Time.now
        end

        loop do
          chunk = normalize_release_output_chunk(stdout_err.read_nonblock(4096))
          output << chunk
          print chunk
          $stdout.flush
        rescue IO::WaitReadable
          break
        rescue EOFError
          break
        end
      end

      status = nil if timed_out
      [output, status]
    end

    def release_verify_timeout_seconds
      ENV.fetch('SANEPROCESS_RELEASE_VERIFY_TIMEOUT_SECONDS', '1800').to_i
    rescue StandardError
      1800
    end

    def terminate_release_command_process(root_pid, signal:)
      [-(root_pid.to_i), root_pid.to_i, *release_descendant_pids(root_pid)].uniq.each do |pid|
        Process.kill(signal, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    def release_descendant_pids(root_pid)
      output, status = Open3.capture2('ps', '-axo', 'pid=,ppid=')
      return [] unless status.success?

      children_by_parent = Hash.new { |hash, key| hash[key] = [] }
      output.each_line do |line|
        pid_text, ppid_text = line.split
        pid = pid_text.to_i
        ppid = ppid_text.to_i
        next unless pid.positive? && ppid.positive?

        children_by_parent[ppid] << pid
      end
      queue = children_by_parent[root_pid.to_i].dup
      descendants = []
      until queue.empty?
        pid = queue.shift
        next if descendants.include?(pid)

        descendants << pid
        queue.concat(children_by_parent[pid])
      end
      descendants
    rescue StandardError
      []
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

    def local_latest_appcast_version
      appcast_path = local_appcast_paths.first
      return '' unless appcast_path

      parse_latest_appcast_item(safe_read(appcast_path))[:version].to_s
    end

    def prepublish_channel_version_drift?(channel_version:, project_version:)
      compare_semver(channel_version, project_version) == -1
    end

    def homebrew_lane_declared?(config)
      homebrew = config.is_a?(Hash) ? (config['homebrew'] || config[:homebrew]) : nil
      return false unless homebrew.is_a?(Hash)

      enabled = homebrew.key?('enabled') ? homebrew['enabled'] : homebrew[:enabled]
      return false if enabled == false
      return true if enabled == true

      !metadata_value(homebrew, 'tap_repo').to_s.empty?
    end

    def homebrew_tap_repo(config)
      homebrew = config.is_a?(Hash) ? (config['homebrew'] || config[:homebrew]) : nil
      metadata_value(homebrew, 'tap_repo') || 'sane-apps/homebrew-tap'
    end

    def homebrew_macos_symbol_for_system_version(system_version)
      case system_version.to_s.strip
      when /\A10\.15(?:\.\d+)?\z/ then 'catalina'
      when /\A11(?:\.\d+)?\z/ then 'big_sur'
      when /\A12(?:\.\d+)?\z/ then 'monterey'
      when /\A13(?:\.\d+)?\z/ then 'ventura'
      when /\A14(?:\.\d+)?\z/ then 'sonoma'
      when /\A15(?:\.\d+)?\z/ then 'sequoia'
      when /\A26(?:\.\d+)?\z/ then 'tahoe'
      end
    end

    def release_min_system_version(config)
      release = config.is_a?(Hash) ? (config['release'] || config[:release]) : nil
      metadata_value(release, 'min_system_version').to_s.strip
    end

    def homebrew_cask_preflight_result(config:, tap_status:, cask_body:, project_version:, appcast_version:, min_system_version: nil)
      status = tap_status.to_s.strip
      result = { message: '', warnings: [], issues: [] }

      unless status == '200'
        if status == '404' && !homebrew_lane_declared?(config)
          result[:message] = '⏭️  skipped (no Homebrew lane declared and no existing cask found)'
        else
          result[:message] = "⚠️  returned #{status}"
          result[:warnings] << "Homebrew tap cask not reachable (#{status})"
        end
        return result
      end

      cask_version = cask_body.to_s[/version\s+"([^"]+)"/, 1].to_s.strip
      if cask_version.empty?
        result[:message] = '⚠️  could not parse cask version'
        result[:warnings] << 'Homebrew cask version unreadable'
      elsif project_version.to_s.empty?
        result[:message] = "✅ reachable (v#{cask_version}, project version unknown)"
      elsif cask_version == project_version
        result[:message] = "✅ (v#{cask_version})"
      elsif prepublish_channel_version_drift?(
        channel_version: cask_version,
        project_version: project_version
      ) && prepublish_channel_version_drift?(
        channel_version: appcast_version,
        project_version: project_version
      )
        result[:message] = "⚠️  cask has v#{cask_version}, project is v#{project_version} (expected before publish)"
        result[:warnings] << "Homebrew cask version #{cask_version} is older than project MARKETING_VERSION #{project_version} (expected before publish)"
      else
        result[:message] = "❌ cask has v#{cask_version}, project is v#{project_version}"
        result[:issues] << "Homebrew cask version mismatch: cask=#{cask_version} project=#{project_version}"
      end

      expected_macos_symbol = homebrew_macos_symbol_for_system_version(min_system_version)
      if min_system_version && !min_system_version.to_s.empty? && expected_macos_symbol.nil?
        result[:issues] << "Unsupported release min_system_version for Homebrew cask: #{min_system_version}"
      elsif expected_macos_symbol
        actual_macos_symbol = cask_body.to_s[/depends_on\s+macos:\s*:([a-z_]+)/, 1]
        if actual_macos_symbol.nil?
          result[:issues] << 'Homebrew cask macOS requirement unreadable'
        elsif actual_macos_symbol != expected_macos_symbol
          prepublish_drift = prepublish_channel_version_drift?(
            channel_version: cask_version,
            project_version: project_version
          ) && prepublish_channel_version_drift?(
            channel_version: appcast_version,
            project_version: project_version
          )
          message = "Homebrew cask macOS mismatch: cask=#{actual_macos_symbol} release=#{expected_macos_symbol}"
          prepublish_drift ? result[:warnings] << "#{message} (will sync on publish)" : result[:issues] << message
        end
      end

      result
    end

    def archive_bundle_versions(zip_url:, app_name:)
      return nil if zip_url.to_s.strip.empty?

      Dir.mktmpdir("sanemaster-preflight-#{app_name}-") do |tmpdir|
        zip_path = File.join(tmpdir, 'dist.zip')
        unpack_dir = File.join(tmpdir, 'unpacked')

        _curl_out, curl_status = Open3.capture2e(
          'curl', '--connect-timeout', '10', '--max-time', '60', '-fsSL', zip_url, '-o', zip_path
        )
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
      gate_marker = /\b(?:isPro|isLicensed|usesAppStorePurchase|isSubscribed)\b/
      gate_hits = source_blob.scan(gate_marker).count
      has_runtime_gate = source_blob.match?(
        /(?:guard|if)\s+[^\n{]*\b(?:isPro|isLicensed|usesAppStorePurchase|isSubscribed)\b/
      )
      has_purchase_path = source_blob.match?(/\bpurchasePro\s*\(/) ||
                          source_blob.match?(/\bProduct\.purchase\s*\(/) ||
                          source_blob.match?(/\b(?:[A-Za-z_][A-Za-z0-9_]*)?product[A-Za-z0-9_]*\.purchase\s*\(/i)
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

      report[:issues] << 'No in-app purchase path found (purchasePro/Product.purchase/product.purchase)' unless has_purchase_path
      report[:issues] << 'No restore purchases path found (restorePurchases/AppStore.sync)' unless has_restore_path
      report[:issues] << 'No unlock/upgrade UI copy detected' unless has_upgrade_ui
      report[:issues] << 'No effective runtime paid-feature gates detected (Pro/license/subscription checks)' if gate_hits < 6 || !has_runtime_gate
      if uses_license_service && !has_checkout_fallback
        report[:warnings] << 'No direct checkout fallback found for website builds'
      end
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
      return if ENV.fetch('SANE_ENV_CACHE_WRITE', '0') == '0'

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

    def resolved_asc_credentials
      key_id = resolve_secret(
        service: 'saneprocess.asc.key_id',
        account: 'asc_key_id',
        env_names: %w[ASC_AUTH_KEY_ID ASC_KEY_ID]
      )
      issuer_id = resolve_secret(
        service: 'saneprocess.asc.issuer_id',
        account: 'asc_issuer_id',
        env_names: %w[ASC_AUTH_ISSUER_ID ASC_ISSUER_ID]
      )
      key_path = resolve_secret(
        service: 'saneprocess.asc.key_path',
        account: 'asc_key_path',
        env_names: %w[ASC_AUTH_KEY_PATH ASC_KEY_PATH]
      ).to_s.strip

      {
        key_id: key_id.to_s.strip,
        issuer_id: issuer_id.to_s.strip,
        key_path: key_path.empty? ? '' : File.expand_path(key_path)
      }
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

    def capture_github_command_with_timeout(env, *cmd, timeout_seconds: 20)
      output = +''
      status = nil
      started_at = Time.now
      Open3.popen2e(env, *cmd, pgroup: true) do |_stdin, stdout_err, wait_thr|
        loop do
          begin
            ready = IO.select([stdout_err], nil, nil, 0.2)
            output << stdout_err.read_nonblock(4096) if ready
          rescue IO::WaitReadable
            # keep waiting until the process exits or times out
          rescue EOFError
            nil
          end

          if wait_thr.join(0)
            status = wait_thr.value
            break
          end

          if timeout_seconds.positive? && (Time.now - started_at) > timeout_seconds
            output << "\ngh command timeout after #{timeout_seconds}s: #{cmd.join(' ')}\n"
            terminate_release_command_process(wait_thr.pid, signal: 'TERM')
            wait_thr.join(2) || terminate_release_command_process(wait_thr.pid, signal: 'KILL')
            status = wait_thr.value if wait_thr.join(0)
            break
          end
        end
        begin
          output << stdout_err.read.to_s unless stdout_err.closed?
        rescue StandardError
          nil
        end
      end
      status ||= Struct.new(:success?, :exitstatus).new(false, nil)
      [output, status]
    rescue StandardError => error
      ["#{error.class}: #{error.message}", Struct.new(:success?, :exitstatus).new(false, nil)]
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
      markers << 'manual key entry CTA' if artifact_blob.match?(/I Have a Key|Enter Key|\bActivate License/i)
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

    APPSTORE_PERMISSION_PLIST_KEYS = %w[
      NSAccessibilityUsageDescription
      NSAppleEventsUsageDescription
    ].freeze

    def appstore_plistbuddy_capture(*args)
      Open3.capture2e('/usr/libexec/PlistBuddy', *args)
    end

    def appstore_built_plist_permission_report(info_plist)
      issues = []
      declarations = APPSTORE_PERMISSION_PLIST_KEYS.to_h { |key| [key, false] }
      unless File.file?(info_plist)
        issues << 'App Store artifact audit could not find the built Info.plist'
        return { verified: false, root_dump: '', declarations: declarations, issues: issues }
      end

      root_dump, root_status = appstore_plistbuddy_capture('-c', 'Print', info_plist)
      unless root_status.success?
        detail = summarized_output_tail(root_dump)
        message = 'App Store artifact audit could not parse the built Info.plist with PlistBuddy'
        message += ": #{detail}" unless detail.empty?
        issues << message
        return { verified: false, root_dump: '', declarations: declarations, issues: issues }
      end

      APPSTORE_PERMISSION_PLIST_KEYS.each do |key|
        output, status = appstore_plistbuddy_capture('-c', "Print :#{key}", info_plist)
        if status.success?
          declarations[key] = true
        elsif !output.to_s.match?(/Does Not Exist/i)
          detail = summarized_output_tail(output)
          message = "App Store artifact audit could not query built Info.plist root key #{key}"
          message += ": #{detail}" unless detail.empty?
          issues << message
        end
      end

      {
        verified: issues.empty?,
        root_dump: root_dump.to_s,
        declarations: declarations,
        issues: issues
      }
    rescue StandardError => e
      {
        verified: false,
        root_dump: '',
        declarations: declarations,
        issues: ["App Store artifact audit could not inspect the built Info.plist: #{e.message}"]
      }
    end

    def appstore_permission_artifact_findings(review_notes_blob:, declarations:, artifact_blob:, strings_out:, nm_out:, otool_out:,
                                               payload_label: nil)
      issues = []
      warnings = []
      suffix = payload_label.to_s.empty? ? '' : " in #{payload_label}"

      if review_notes_blob.match?(/does not request accessibility/i) &&
         declarations['NSAccessibilityUsageDescription']
        issues << "Review notes claim no Accessibility request, but built Info.plist still declares NSAccessibilityUsageDescription#{suffix}"
      end

      if review_notes_blob.match?(/does not request.*apple events|no apple events/i) &&
         declarations['NSAppleEventsUsageDescription']
        issues << "Review notes claim no Apple Events request, but built Info.plist still declares NSAppleEventsUsageDescription#{suffix}"
      end

      accessibility_markers = []
      accessibility_markers << 'ApplicationServices linkage' if otool_out.include?('ApplicationServices.framework')
      accessibility_markers << 'AXIsProcessTrusted symbol' if nm_out.match?(/_AXIsProcessTrusted/)
      accessibility_markers << 'Accessibility settings deep link' if strings_out.include?('Privacy_Accessibility')
      if accessibility_markers.any?
        issues << "Built App Store artifact still contains Accessibility markers (#{accessibility_markers.join(', ')})#{suffix}"
      end

      apple_events_markers = []
      apple_events_markers << 'osascript runtime' if artifact_blob.include?('/usr/bin/osascript')
      if declarations['NSAppleEventsUsageDescription']
        apple_events_markers << 'Apple Events usage description'
      end
      if apple_events_markers.any?
        warnings << "Built App Store artifact still contains Apple Events markers (#{apple_events_markers.join(', ')})#{suffix} — verify App Review notes and App Store policy fit"
      end

      { issues: issues, warnings: warnings }
    end

    def appstore_artifact_capture(*command)
      Open3.capture2e(*command)
    end

    def appstore_macho_file?(path)
      magic = File.binread(path, 4)
      ["\xFE\xED\xFA\xCE", "\xCE\xFA\xED\xFE", "\xFE\xED\xFA\xCF", "\xCF\xFA\xED\xFE",
       "\xCA\xFE\xBA\xBE", "\xBE\xBA\xFE\xCA"].any? { |candidate| magic == candidate.b }
    rescue StandardError
      false
    end

    def appstore_runnable_non_macho_file?(path)
      metadata = File.stat(path)
      return false unless metadata.file?
      return false if appstore_macho_file?(path)
      return true unless (metadata.mode & 0o111).zero?

      File.open(path, 'rb') { |file| file.read(2) } == '#!'
    rescue StandardError
      false
    end

    def appstore_shipped_executable_inventory(app_dir:, platform:, main_binary:)
      issues = []
      paths = [main_binary]
      string_only_paths = []
      roots = if platform.to_s.downcase == 'macos'
                %w[Contents/Helpers Contents/PlugIns Contents/XPCServices Contents/Library/LoginItems Contents/Frameworks]
              else
                %w[PlugIns Watch AppClips Frameworks]
              end.map { |relative| File.join(app_dir, relative) }.select { |path| Dir.exist?(path) }

      bundle_dirs = roots.flat_map do |root|
        %w[app appex xpc].flat_map { |extension| Dir.glob(File.join(root, '**', "*.#{extension}")) }
      end.select { |path| File.directory?(path) }.uniq.sort
      bundle_dirs.each do |bundle_dir|
        mac_layout = Dir.exist?(File.join(bundle_dir, 'Contents'))
        info_path = File.join(bundle_dir, mac_layout ? 'Contents/Info.plist' : 'Info.plist')
        unless File.file?(info_path)
          issues << "Recognized embedded bundle is missing Info.plist: #{bundle_dir.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')}"
          next
        end
        executable_out, executable_status = appstore_plistbuddy_capture('-c', 'Print :CFBundleExecutable', info_path)
        executable = executable_out.to_s.strip
        unless executable_status.success? && !executable.empty?
          issues << "Recognized embedded bundle has no readable CFBundleExecutable: #{bundle_dir.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')}"
          next
        end
        executable_path = File.join(bundle_dir, mac_layout ? 'Contents/MacOS' : '', executable)
        if File.file?(executable_path)
          paths << executable_path
        else
          issues << "Recognized embedded bundle executable is missing: #{executable_path.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')}"
        end
      end

      framework_dirs = roots.flat_map { |root| Dir.glob(File.join(root, '**', '*.framework')) }
        .select { |path| File.directory?(path) }.uniq.sort
      framework_dirs.each do |framework_dir|
        info_paths = [
          File.join(framework_dir, 'Info.plist'),
          File.join(framework_dir, 'Resources', 'Info.plist'),
          *Dir.glob(File.join(framework_dir, 'Versions', '*', 'Resources', 'Info.plist'))
        ].select { |path| File.file?(path) }.uniq
        if info_paths.empty?
          relative = framework_dir.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')
          issues << "Recognized framework is missing Info.plist: #{relative}"
          next
        end
        executable_names = info_paths.map do |info_path|
          output, status = appstore_plistbuddy_capture('-c', 'Print :CFBundleExecutable', info_path)
          unless status.success? && !output.to_s.strip.empty?
            issues << "Recognized framework has an unreadable CFBundleExecutable: #{info_path.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')}"
            next
          end
          output.to_s.strip
        end.compact.uniq
        candidates = executable_names.flat_map do |name|
          [
            File.join(framework_dir, name),
            File.join(framework_dir, 'Versions', 'Current', name),
            *Dir.glob(File.join(framework_dir, 'Versions', '*', name))
          ]
        end.select { |path| File.file?(path) }
        candidates = candidates.group_by { |path| File.realpath(path) rescue File.expand_path(path) }.values.map(&:first)
        if candidates.length == 1
          paths << candidates.first
        else
          relative = framework_dir.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')
          issues << "Recognized framework executable identity is #{candidates.empty? ? 'missing' : 'ambiguous'}: #{relative}"
        end
      end

      framework_roots = roots.select { |root| File.basename(root) == 'Frameworks' }
      bundle_dirs.each do |bundle_dir|
        framework_roots << File.join(bundle_dir, 'Frameworks')
        framework_roots << File.join(bundle_dir, 'Contents', 'Frameworks')
      end
      framework_roots.select! { |root| Dir.exist?(root) }
      framework_roots.uniq!
      framework_roots.each do |root|
        Dir.glob(File.join(root, '**', '*.dylib')).select { |path| File.file?(path) }.each { |path| paths << path }
      end
      roots.each do |root|
        Dir.glob(File.join(root, '**', '*')).select { |path| File.file?(path) }.each do |path|
          relative_to_root = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
          next if relative_to_root.split(File::SEPARATOR).include?('Resources')

          if appstore_macho_file?(path)
            paths << path
          elsif appstore_runnable_non_macho_file?(path)
            paths << path
            string_only_paths << path
          end
        end
      end
      paths = paths.group_by { |path| File.realpath(path) rescue File.expand_path(path) }.values.map(&:first)
      string_only_paths = string_only_paths.map { |path| File.realpath(path) rescue File.expand_path(path) }.uniq
      { paths: paths, issues: issues, string_only_paths: string_only_paths }
    end

    def appstore_payload_framework_dirs(executable_path:, app_dir:, main_frameworks_dir:)
      dirs = [main_frameworks_dir]
      cursor = File.dirname(executable_path)
      while cursor.start_with?(File.expand_path(app_dir))
        if File.basename(cursor).match?(/\.(?:app|appex|xpc)\z/)
          dirs << File.join(cursor, 'Frameworks')
          dirs << File.join(cursor, 'Contents', 'Frameworks')
        end
        parent = File.dirname(cursor)
        break if parent == cursor

        cursor = parent
      end
      dirs.compact.select { |path| Dir.exist?(path) }.uniq
    end

    def appstore_compiled_artifact_report(app_dir:, platform:, expected_bundle_id:, review_notes_blob:,
                                          configured_product_id:, uses_storekit_unlock:)
      issues = []
      warnings = []
      identity = appstore_select_submission_app(
        app_dirs: [app_dir],
        expected_bundle_ids: [expected_bundle_id],
        platform: platform
      )
      return { verified: false, issues: identity[:issues], warnings: warnings } unless identity[:verified]

      permission_plist_report = appstore_built_plist_permission_report(identity[:info_plist])
      unless permission_plist_report[:verified]
        return { verified: false, issues: permission_plist_report[:issues], warnings: warnings }
      end

      product_out, product_status = appstore_plistbuddy_capture('-c', 'Print :AppStoreProductID', identity[:info_plist])
      built_product_id = product_status.success? ? product_out.to_s.strip : ''
      unless product_status.success? || product_out.to_s.match?(/Does Not Exist/i)
        issues << 'App Store artifact audit could not query AppStoreProductID from the built Info.plist'
      end
      if uses_storekit_unlock
        if built_product_id.empty?
          issues << 'Built App Store artifact is missing Info.plist key AppStoreProductID (StoreKit unlock flow detected)'
        elsif !configured_product_id.to_s.empty? && built_product_id != configured_product_id.to_s
          issues << "Built AppStoreProductID mismatch (expected #{configured_product_id}, got #{built_product_id})"
        end
      end

      binary_path = File.join(identity[:layout][:executable_dir], identity[:executable])
      unless File.file?(binary_path)
        issues << "App Store artifact audit could not find app executable for #{expected_bundle_id}"
        return { verified: false, issues: issues, warnings: warnings }
      end

      inventory = appstore_shipped_executable_inventory(
        app_dir: app_dir,
        platform: platform,
        main_binary: binary_path
      )
      issues.concat(inventory[:issues])
      inventory[:paths].each do |payload_path|
        payload_label = payload_path.sub(%r{\A#{Regexp.escape(app_dir)}/?}, '')
        canonical_payload_path = File.realpath(payload_path) rescue File.expand_path(payload_path)
        string_only = Array(inventory[:string_only_paths]).include?(canonical_payload_path)
        command_results = { strings: appstore_artifact_capture('strings', '-a', payload_path) }
        unless string_only
          command_results[:otool] = appstore_artifact_capture('otool', '-L', payload_path)
          command_results[:nm] = appstore_artifact_capture('nm', '-m', payload_path)
        end
        command_results.each do |name, (_output, status)|
          issues << "App Store artifact audit could not run #{name} on shipped executable #{payload_label}" unless status.success?
        end
        next unless command_results.values.all? { |_output, status| status.success? }

        otool_out = command_results.dig(:otool, 0).to_s
        strings_out = command_results[:strings][0].to_s
        nm_out = command_results.dig(:nm, 0).to_s
        framework_dirs = appstore_payload_framework_dirs(
          executable_path: payload_path,
          app_dir: app_dir,
          main_frameworks_dir: identity[:layout][:frameworks_dir]
        )
        unresolved = otool_out.lines.drop(1).map(&:strip).reject(&:empty?).map do |line|
          lib = line.split(' (').first.to_s.strip
          next unless lib.start_with?('@rpath/')
          next if line.include?(', weak)')

          relative = lib.sub('@rpath/', '')
          lib unless framework_dirs.any? { |dir| File.exist?(File.join(dir, relative)) }
        end.compact
        if unresolved.any?
          issues << "App Store artifact has unresolved non-weak dylib references in #{payload_label}: #{unresolved.uniq.join(', ')}"
        end

        artifact_blob = [payload_path == binary_path ? permission_plist_report[:root_dump] : '', strings_out, nm_out, otool_out].join("\n")
        direct_purchase_markers = appstore_direct_purchase_markers(artifact_blob, built_product_id: built_product_id)
        if direct_purchase_markers.any?
          issues << "Built App Store artifact still exposes direct-purchase markers in #{payload_label} (#{direct_purchase_markers.join(', ')})"
        elsif artifact_blob.match?(%r{api\.lemonsqueezy\.com/v1/licenses/validate}i) && !built_product_id.empty?
          warnings << "Built App Store artifact still contains LemonSqueezy license-validation strings in #{payload_label} — verify website-license code is unreachable in the App Store build"
        end

        donation_markers = appstore_donation_markers(artifact_blob)
        if donation_markers.any?
          issues << "Built App Store artifact still exposes donation/support markers in #{payload_label} (#{donation_markers.join(', ')})"
        end

        update_markers = appstore_update_markers(strings_out: strings_out, otool_out: otool_out)
        if update_markers.any?
          issues << "Built App Store artifact still exposes outside-update markers in #{payload_label} (#{update_markers.join(', ')})"
        end

        payload_declarations = if payload_path == binary_path
                                 permission_plist_report[:declarations]
                               else
                                 { 'NSAccessibilityUsageDescription' => false, 'NSAppleEventsUsageDescription' => false }
                               end
        permission_findings = appstore_permission_artifact_findings(
          review_notes_blob: payload_path == binary_path ? review_notes_blob : '',
          declarations: payload_declarations,
          artifact_blob: artifact_blob,
          strings_out: strings_out,
          nm_out: nm_out,
          otool_out: otool_out,
          payload_label: payload_label
        )
        issues.concat(permission_findings[:issues])
        warnings.concat(permission_findings[:warnings])
      end

      launch_daemons_dir = identity[:layout][:launch_daemons_dir]
      if launch_daemons_dir && Dir.exist?(launch_daemons_dir)
        issues << 'Built App Store artifact still embeds LaunchDaemons payload — Mac App Store apps cannot ship launchd daemons or agents'
      end

      { verified: issues.empty?, issues: issues.uniq, warnings: warnings.uniq }
    rescue StandardError => e
      {
        verified: false,
        issues: ["Compiled App Store artifact audit failed unexpectedly: #{e.message}"],
        warnings: warnings || []
      }
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

      credentials = resolved_asc_credentials
      issuer_id = credentials[:issuer_id]
      key_id = credentials[:key_id]
      p8_path = credentials[:key_path]

      return nil if issuer_id.empty? || key_id.empty? || p8_path.empty? || !File.exist?(p8_path)

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

    def asc_get_json_with_status(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
      require 'net/http'
      require 'json'

      uri = URI("#{base}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Bearer #{token}"
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 20
      response = http.request(request)
      parsed = begin
        JSON.parse(response.body.to_s)
      rescue StandardError
        { 'raw' => response.body.to_s }
      end
      [response.code.to_i, parsed]
    rescue StandardError
      [0, nil]
    end

    def asc_get_json(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
      code, parsed = asc_get_json_with_status(path, token: token, base: base)
      return nil unless code.between?(200, 299)

      parsed
    end

    def asc_app_availability_status(app_id:)
      return nil if app_id.to_s.strip.empty?

      token = appstore_connect_token
      return nil if token.nil?

      code, response = asc_get_json_with_status("/apps/#{app_id}/appAvailabilityV2", token: token)
      return { exists: false, http_code: code } if code == 404
      return nil unless code.between?(200, 299) && response.is_a?(Hash)

      availability_id = response.dig('data', 'id').to_s.strip
      availability_id = app_id.to_s.strip if availability_id.empty?
      availability = {
        exists: true,
        available_in_new_territories: response.dig('data', 'attributes', 'availableInNewTerritories')
      }

      rel_code, rel_response = asc_get_json_with_status(
        "/appAvailabilities/#{availability_id}/relationships/territoryAvailabilities?limit=200",
        token: token,
        base: 'https://api.appstoreconnect.apple.com/v2'
      )
      if rel_code.between?(200, 299) && rel_response.is_a?(Hash)
        availability[:territory_total] = rel_response.dig('meta', 'paging', 'total') || Array(rel_response['data']).length
      end

      detail_code, detail_response = asc_get_json_with_status(
        "/appAvailabilities/#{availability_id}/territoryAvailabilities?limit=200",
        token: token,
        base: 'https://api.appstoreconnect.apple.com/v2'
      )
      if detail_code.between?(200, 299) && detail_response.is_a?(Hash)
        status_counts = Hash.new(0)
        territory_rows = Array(detail_response['data'])
        selected_count = 0
        release_ready_count = 0
        territory_rows.each do |entry|
          statuses = Array(entry.dig('attributes', 'contentStatuses')).map(&:to_s).reject(&:empty?)
          key = statuses.empty? ? 'UNKNOWN' : statuses.join('+')
          status_counts[key] += 1

          selected = entry.dig('attributes', 'available') == true
          selected_count += 1 if selected
          release_ready = statuses.include?('AVAILABLE') ||
                          statuses.include?('AVAILABLE_FOR_SALE_UNRELEASED_APP')
          release_ready_count += 1 if selected && release_ready
        end
        availability[:content_status_counts] = status_counts
        availability[:available_count] = selected_count
        availability[:all_territories_available] = release_ready_count.positive? &&
                                                   release_ready_count == territory_rows.length
      end

      availability
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

    def appstore_iap_auto_renewable_subscription?(appstore_config)
      type = appstore_config.dig('iap', 'type').to_s.strip
      type == 'auto_renewable_subscription' || type == 'subscription' || type.include?('auto_renewable')
    end

    def appstore_fingerprint_entries(root:, paths:)
      root_real = File.realpath(root)
      Array(paths).sort.map do |relative_path|
        next if relative_path == 'outputs/appstore_preflight_status.json'
        next if relative_path.start_with?('outputs/appstore-preflight-bindings/')

        absolute_path = File.expand_path(relative_path, root_real)
        unless absolute_path.start_with?("#{root_real}/")
          raise "fingerprint path escapes project root: #{relative_path}"
        end

        metadata = File.lstat(absolute_path)
        if metadata.symlink?
          "L:#{relative_path}:#{File.readlink(absolute_path)}"
        elsif metadata.file?
          "F:#{relative_path}:#{OpenSSL::Digest::SHA256.file(absolute_path).hexdigest}"
        else
          "O:#{relative_path}:#{metadata.mode}"
        end
      end.compact
    end

    def appstore_worktree_fingerprint(root: Dir.pwd)
      git_dir, git_status = Open3.capture2e('git', '-C', root, 'rev-parse', '--git-dir')
      unless git_status.success? && !git_dir.to_s.strip.empty?
        paths = Dir.glob(File.join(root, '**/*'), File::FNM_DOTMATCH)
          .reject { |path| %w[. ..].include?(File.basename(path)) }
          .select { |path| File.file?(path) || File.symlink?(path) }
          .map { |path| path.sub(%r{\A#{Regexp.escape(File.expand_path(root))}/?}, '') }
        material = appstore_fingerprint_entries(root: root, paths: paths).join("\n")
        return OpenSSL::Digest::SHA256.hexdigest(material)
      end

      parts = []
      %w[rev-parse\ HEAD status\ --porcelain=v1 diff\ --binary diff\ --cached\ --binary].each do |command|
        out, = Open3.capture2e('git', '-C', root, *command.split(' '))
        parts << out
      end
      untracked, untracked_status = Open3.capture2e(
        'git', '-C', root, 'ls-files', '-z', '--others', '--exclude-standard'
      )
      raise 'git ls-files failed while fingerprinting untracked content' unless untracked_status.success?

      parts << appstore_fingerprint_entries(root: root, paths: untracked.split("\0").reject(&:empty?)).join("\n")
      OpenSSL::Digest::SHA256.hexdigest(parts.join("\n---\n"))
    rescue StandardError
      'unknown'
    end

    def appstore_bundle_layout(app_dir, platform:)
      if platform.to_s == 'ios'
        {
          info_plist: File.join(app_dir, 'Info.plist'),
          executable_dir: app_dir,
          frameworks_dir: File.join(app_dir, 'Frameworks'),
          launch_daemons_dir: nil
        }
      else
        contents = File.join(app_dir, 'Contents')
        {
          info_plist: File.join(contents, 'Info.plist'),
          executable_dir: File.join(contents, 'MacOS'),
          frameworks_dir: File.join(contents, 'Frameworks'),
          launch_daemons_dir: File.join(contents, 'Library', 'LaunchDaemons')
        }
      end
    end

    def appstore_bundle_identity_report(app_dir, platform:)
      layout = appstore_bundle_layout(app_dir, platform: platform)
      info_path = layout[:info_plist]
      return { verified: false, issue: "App Store artifact is missing Info.plist: #{app_dir}" } unless File.file?(info_path)

      values = {}
      %w[CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleExecutable].each do |key|
        output, status = appstore_plistbuddy_capture('-c', "Print :#{key}", info_path)
        value = output.to_s.strip
        unless status.success? && !value.empty?
          return { verified: false, issue: "App Store artifact could not read #{key} from #{info_path}" }
        end
        values[key] = value
      end
      {
        verified: true,
        app_dir: app_dir,
        info_plist: info_path,
        bundle_id: values['CFBundleIdentifier'],
        version: values['CFBundleShortVersionString'],
        build: values['CFBundleVersion'],
        executable: values['CFBundleExecutable'],
        layout: layout
      }
    rescue StandardError => e
      { verified: false, issue: "App Store artifact identity inspection failed for #{app_dir}: #{e.message}" }
    end

    def appstore_select_submission_app(app_dirs:, expected_bundle_ids:, platform:)
      expected = Array(expected_bundle_ids).map(&:to_s).reject(&:empty?).uniq
      if expected.empty?
        return { verified: false, issues: ['Cannot resolve the expected App Store bundle ID for exact artifact selection'] }
      end

      candidates = Array(app_dirs).uniq.sort.map do |app_dir|
        appstore_bundle_identity_report(app_dir, platform: platform)
      end
      matches = candidates.select { |candidate| candidate[:verified] && expected.include?(candidate[:bundle_id]) }
      if matches.length != 1
        discovered = candidates.select { |candidate| candidate[:verified] }.map { |candidate| candidate[:bundle_id] }.uniq
        detail = discovered.empty? ? 'none with readable identity' : discovered.join(', ')
        issue = if matches.empty?
                  "Exact App Store artifact not found for bundle ID #{expected.join(' or ')} (found: #{detail})"
                else
                  "App Store artifact selection is ambiguous for bundle ID #{matches.first[:bundle_id]} (#{matches.length} matches)"
                end
        identity_issues = candidates.reject { |candidate| candidate[:verified] }.map { |candidate| candidate[:issue] }
        return { verified: false, issues: [issue, *identity_issues].compact }
      end

      matches.first.merge(issues: [])
    end

    def appstore_pkg_top_level_app_dirs(expanded_dir)
      Dir.glob(File.join(expanded_dir, '**', 'Payload', '**', '*.app')).select do |path|
        relative = path.split('/Payload/', 2)[1].to_s
        parents = relative.split('/')[0...-1]
        parents.none? { |component| component.end_with?('.app') }
      end.uniq.sort
    end

    def with_launch_services_clean_tempdir(prefix)
      Dir.mktmpdir(prefix) do |tmpdir|
        FileUtils.touch(File.join(tmpdir, '.metadata_never_index'))
        begin
          yield tmpdir
        ensure
          unregister_launch_services_paths(Dir.glob(File.join(tmpdir, '**', '*.app')))
        end
      end
    end

    def unregister_launch_services_paths(paths)
      lsregister = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
      return unless File.executable?(lsregister)

      Array(paths)
        .map { |path| File.expand_path(path) }
        .uniq
        .sort_by { |path| -path.count(File::SEPARATOR) }
        .each do |path|
          system(lsregister, '-u', path, out: File::NULL, err: File::NULL)
        end
      system(lsregister, '-gc', out: File::NULL, err: File::NULL)
    end

    def appstore_with_submission_package_app(pkg_path, expected_bundle_ids:, expected_sha256: nil)
      platform = if pkg_path.end_with?('.ipa')
                   'ios'
                 elsif pkg_path.end_with?('.pkg')
                   'macos'
                 end
      unless platform
        return yield(verified: false, issues: ["Unsupported App Store package type: #{pkg_path}"])
      end

      digest_before = OpenSSL::Digest::SHA256.file(pkg_path).hexdigest
      if expected_sha256 && digest_before != expected_sha256.to_s
        return yield(verified: false, issues: ['Exact App Store package bytes do not match the bound submissionTarget.sha256'])
      end

      with_launch_services_clean_tempdir('sanemaster_appstore_package_audit') do |tmpdir|
        extraction_issue = nil
        app_dirs = begin
          if platform == 'ios'
            extracted = system('unzip', '-qq', '-o', pkg_path, '-d', tmpdir, out: File::NULL, err: File::NULL)
            extraction_issue = "Could not extract exact iOS submission package: #{pkg_path}" unless extracted
            extracted ? Dir.glob(File.join(tmpdir, 'Payload', '*.app')) : []
          else
            expanded = File.join(tmpdir, 'expanded')
            extracted = system('pkgutil', '--expand-full', pkg_path, expanded, out: File::NULL, err: File::NULL)
            extraction_issue = "Could not extract exact macOS submission package: #{pkg_path}" unless extracted
            extracted ? appstore_pkg_top_level_app_dirs(expanded) : []
          end
        rescue StandardError => e
          extraction_issue = "Exact App Store package extraction failed: #{e.message}"
          []
        end
        return yield(verified: false, issues: [extraction_issue]) if extraction_issue

        digest_after = OpenSSL::Digest::SHA256.file(pkg_path).hexdigest
        unless digest_after == digest_before && (!expected_sha256 || digest_after == expected_sha256.to_s)
          return yield(verified: false, issues: ['Exact App Store package changed while it was being extracted for audit'])
        end

        selection = appstore_select_submission_app(
          app_dirs: app_dirs,
          expected_bundle_ids: expected_bundle_ids,
          platform: platform
        )
        yield selection.merge(platform: platform)
      end
    end

    def appstore_package_info(pkg_path, expected_bundle_ids:, expected_sha256: nil)
      result = nil
      appstore_with_submission_package_app(
        pkg_path,
        expected_bundle_ids: expected_bundle_ids,
        expected_sha256: expected_sha256
      ) do |selection|
        @appstore_package_info_issues = Array(selection[:issues])
        if selection[:verified]
          result = {
            bundle_id: selection[:bundle_id],
            version: selection[:version],
            build: selection[:build]
          }
        end
      end
      result
    end

    def appstore_preflight_submission_target(args:, version:, build:, platforms:, issues:)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on('--pkg PATH') { |value| options[:pkg] = value }
        opts.on('--platform PLATFORM') { |value| options[:platform] = value.to_s.downcase }
      end
      parser.parse!(Array(args).dup)

      return nil unless options[:pkg]

      platform = options[:platform].to_s
      if platform.empty? || !Array(platforms).map { |item| item.to_s.downcase }.include?(platform)
        issues << "App Store preflight submission platform is invalid or not configured: #{platform.inspect}"
        return nil
      end

      if options[:pkg]
        path = File.expand_path(options[:pkg])
        unless File.file?(path)
          issues << "App Store submission package not found: #{path}"
          return nil
        end

        signing_targets = if platform == 'macos'
                            appstore_macos_signing_targets(File.join(Dir.pwd, 'project.yml'))
                          else
                            appstore_mobile_signing_targets(File.join(Dir.pwd, 'project.yml'))
                          end
        expected_bundle_ids = Array(signing_targets).map { |target| target[:bundle_id].to_s }.reject(&:empty?).uniq
        if expected_bundle_ids.empty?
          expected_bundle_ids = appstore_application_bundle_ids(
            File.join(Dir.pwd, 'project.yml'),
            platform: platform
          )
        end
        if expected_bundle_ids.empty?
          issues << "Cannot resolve an App Store target bundle ID for package inspection on #{platform}"
          return nil
        end

        package_sha256 = OpenSSL::Digest::SHA256.file(path).hexdigest
        info = appstore_package_info(
          path,
          expected_bundle_ids: expected_bundle_ids,
          expected_sha256: package_sha256
        )
        unless info
          detail = Array(@appstore_package_info_issues).join('; ')
          message = "Could not extract a unique expected bundle identity from App Store submission package: #{path}"
          message += " (#{detail})" unless detail.empty?
          issues << message
          return nil
        end
        issues << "Submission package version #{info[:version]} does not match preflight version #{version}" unless info[:version].to_s == version.to_s
        issues << "Submission package build #{info[:build]} does not match preflight build #{build}" unless info[:build].to_s == build.to_s
        expected_platform = path.end_with?('.ipa') ? 'ios' : (path.end_with?('.pkg') ? 'macos' : '')
        issues << "Submission package type does not match platform #{platform}" unless expected_platform == platform
        if expected_bundle_ids.any? && !expected_bundle_ids.include?(info[:bundle_id].to_s)
          issues << "Submission package bundle ID #{info[:bundle_id]} is not an App Store target bundle ID (expected #{expected_bundle_ids.join(', ')})"
        end

        return {
          type: 'package',
          platform: platform,
          fileName: File.basename(path),
          sha256: package_sha256,
          size: File.size(path),
          bundleId: info[:bundle_id],
          version: info[:version],
          build: info[:build],
          path: path
        }
      end
    rescue OptionParser::ParseError => e
      issues << "Invalid App Store preflight submission binding: #{e.message}"
      nil
    end

    def write_appstore_preflight_status_snapshot(path:, status:, issues:, warnings:, app_name:, app_id:, version:, build:, platforms:, submission_target: nil)
      FileUtils.mkdir_p(File.dirname(path))
      payload = {
        type: 'appstore_preflight_status',
        generatedAt: Time.now.iso8601,
        projectName: app_name,
        appId: app_id.to_s,
        version: version.to_s,
        build: build.to_s,
        platforms: Array(platforms).map(&:to_s),
        submissionTarget: submission_target&.reject { |key, _value| key.to_s == 'path' },
        worktreeFingerprint: appstore_worktree_fingerprint(root: Dir.pwd),
        status: status,
        issueCount: issues.count,
        warningCount: warnings.count,
        issues: issues,
        warnings: warnings
      }
      upgrade_path_write_signed_atomic!(
        path,
        payload,
        producer: 'saneprocess.appstore_preflight.v1',
        project_root: File.realpath(Dir.pwd)
      )
    end

    def subscription_purchase_flow_guardrail_report(source_blob:, appstore_config:, config:)
      report = { applicable: false, issues: [], warnings: [], summary: '' }
      return report unless appstore_iap_auto_renewable_subscription?(appstore_config)

      report[:applicable] = true
      source = source_blob.to_s
      iap_config = appstore_config['iap'].is_a?(Hash) ? appstore_config['iap'] : {}
      product_name = metadata_value(iap_config, 'display_name', 'name').to_s
      privacy_url = metadata_value(appstore_config, 'privacy_policy_url').to_s
      privacy_url = "https://#{config['website_domain']}/privacy" if privacy_url.empty? && config['website_domain']

      has_storekit_subscription_view = source.include?('SubscriptionStoreView')
      has_link_api = source.match?(/\bLink\s*\(|openURL|SFSafariViewController|UIApplication\.shared\.open/)
      has_terms_label = source.match?(/Terms of Use|EULA|License Agreement/i)
      has_terms_url = source.match?(%r{apple\.com/legal/internet-services/itunes/dev/stdeula|/terms/?["')]?}i)
      has_privacy_label = source.match?(/Privacy Policy|Privacy/i)
      has_privacy_url = !privacy_url.empty? && source.include?(privacy_url)
      has_product_title = has_storekit_subscription_view ||
                          (!product_name.empty? && source.include?(product_name)) ||
                          source.match?(/displayName|Sane\w*\s+Pro/i)
      has_duration = has_storekit_subscription_view ||
                     source.match?(/year|annual|month|week|subscriptionPeriod|renewal term|once per/i)
      has_price = has_storekit_subscription_view || source.match?(/displayPrice|price|Product\.SubscriptionInfo/i)
      has_value = source.match?(/Unlimited|unlock|included|provided|batch import|scan/i)
      has_cancel = has_storekit_subscription_view || source.match?(/cancel/i)
      has_restore = source.match?(/Restore Purchases|restorePurchases\s*\(|AppStore\.sync\s*\(/)

      report[:issues] << 'Auto-renewable subscription purchase flow lacks a visible subscription title/product name' unless has_product_title
      report[:issues] << 'Auto-renewable subscription purchase flow lacks renewal duration/term copy' unless has_duration
      report[:issues] << 'Auto-renewable subscription purchase flow lacks price/displayPrice in the purchase option' unless has_price
      report[:issues] << 'Auto-renewable subscription purchase flow lacks what the subscriber gets during each period' unless has_value
      report[:issues] << 'Auto-renewable subscription purchase flow lacks cancellation/manage-subscription copy' unless has_cancel
      report[:issues] << 'Auto-renewable subscription purchase flow lacks a restore purchases path' unless has_restore
      unless has_link_api && has_terms_label && has_terms_url
        report[:issues] << 'Auto-renewable subscription purchase flow lacks a functional Terms of Use/EULA link inside the app'
      end
      unless has_link_api && has_privacy_label && (has_privacy_url || source.match?(%r{/privacy/?["')]?}i))
        report[:issues] << 'Auto-renewable subscription purchase flow lacks a functional Privacy Policy link inside the app'
      end

      if iap_config.key?('introductory_offer') || iap_config.key?('trial') || iap_config.key?('free_trial')
        report[:issues] << 'Introductory offer/trial configured but purchase flow lacks trial and post-trial billing copy' unless source.match?(/trial|introductory|after.*trial|then/i)
      end

      checks = {
        title: has_product_title,
        duration: has_duration,
        price: has_price,
        value: has_value,
        cancel: has_cancel,
        restore: has_restore,
        terms: has_link_api && has_terms_label && has_terms_url,
        privacy: has_link_api && has_privacy_label && (has_privacy_url || source.match?(%r{/privacy/?["')]?}i))
      }
      report[:summary] = checks.map { |name, ok| "#{name}=#{ok ? 'yes' : 'no'}" }.join(', ')
      report
    end

    def appstore_metadata_completeness_report(appstore_config:, platforms:)
      issues = []
      warnings = []
      required = {
        'category' => 'primary App Store category',
        'age_rating' => 'age rating',
        'privacy_policy_url' => 'privacy policy URL',
        'support_url' => 'support URL',
        'copyright' => 'copyright',
        'content_rights_declaration' => 'content rights declaration'
      }
      required.each do |key, label|
        issues << "Missing appstore.#{key} (#{label})" if appstore_config[key].to_s.strip.empty?
      end

      export = appstore_config['export_compliance']
      if export.is_a?(Hash)
        if !export.key?('uses_non_exempt_encryption') && !export.key?(:uses_non_exempt_encryption)
          issues << 'Missing appstore.export_compliance.uses_non_exempt_encryption'
        end
        if export['exemption_reason'].to_s.strip.empty? && export[:exemption_reason].to_s.strip.empty?
          warnings << 'appstore.export_compliance.exemption_reason is empty'
        end
      else
        issues << 'Missing appstore.export_compliance — do not let submission tooling assume export compliance answers'
      end

      accessibility = appstore_config['accessibility_declarations']
      if Array(platforms).map(&:to_s).include?('ios')
        if !accessibility.is_a?(Hash) || !accessibility['families'].is_a?(Hash)
          issues << 'Missing appstore.accessibility_declarations.families for iOS Accessibility Nutrition Labels'
        else
          %w[iphone ipad].each do |family|
            next unless accessibility['families'].key?(family)

            flags = accessibility.dig('families', family)
            unless flags.is_a?(Hash) && flags.keys.any? { |key| key.to_s.start_with?('supports_') }
              issues << "Accessibility declaration #{family} lacks supports_* flags"
            end
          end
        end
      end

      {
        issues: issues,
        warnings: warnings,
        summary: issues.empty? ? 'required metadata declared' : "#{issues.count} missing"
      }
    end

    def privacy_manifest_guardrail_report(manifest_paths:, project_yml_content:)
      issues = []
      warnings = []
      if manifest_paths.empty?
        return {
          issues: ['No PrivacyInfo.xcprivacy found — SaneApps requires a manifest so Required Reason API and collected-data declarations are explicit in the submitted bundle'],
          warnings: [],
          summary: 'missing'
        }
      end

      manifest_paths.each do |path|
        lint_out, lint_status = Open3.capture2e('plutil', '-lint', path)
        issues << "#{path} is not valid plist: #{lint_out.strip}" unless lint_status.success?

        parsed_out, parsed_status = Open3.capture2e('plutil', '-p', path)
        if parsed_status.success?
          issues << "#{path} is missing NSPrivacyTracking" unless parsed_out.include?('NSPrivacyTracking')
          issues << "#{path} is missing NSPrivacyCollectedDataTypes" unless parsed_out.include?('NSPrivacyCollectedDataTypes')
          issues << "#{path} is missing NSPrivacyAccessedAPITypes" unless parsed_out.include?('NSPrivacyAccessedAPITypes')
        end
      end

      manifest_content = manifest_paths.map { |path| safe_read(path) }.join("\n")
      privacy_manifest_required_reason_categories.each do |category, reason|
        unless manifest_content.include?(category)
          issues << "PrivacyInfo.xcprivacy missing required reason API category #{category}"
          next
        end
        next if reason.nil? || manifest_content.include?(reason)

        issues << "PrivacyInfo.xcprivacy category #{category} is missing reason #{reason}"
      end

      if project_yml_content.match?(/excludes:\s*(?:.|\n){0,500}PrivacyInfo\.xcprivacy/)
        issues << 'project.yml excludes PrivacyInfo.xcprivacy from the app target — the privacy manifest may not be bundled'
      elsif manifest_paths.none? { |path| project_yml_content.include?(File.basename(path)) || project_yml_content.include?("path: #{File.dirname(path)}") }
        warnings << 'PrivacyInfo.xcprivacy is not mentioned in project.yml; verify it is bundled in the archived app'
      end

      {
        issues: issues.uniq,
        warnings: warnings.uniq,
        summary: manifest_paths.join(', ')
      }
    end

    def privacy_manifest_required_reason_categories
      source = Dir.glob(File.join(Dir.pwd, '{Core,UI,Sources,SaneBar}', '**', '*.swift')).map { |path| safe_read(path) }.join("\n")
      required = {}
      required['NSPrivacyAccessedAPICategoryUserDefaults'] = 'CA92.1' if source.match?(/\bUserDefaults\b/)
      if source.match?(/\.creationDate\b|\.modificationDate\b|contentModificationDateKey|creationDateKey|fileModificationDate|\b(?:stat|lstat|fstat|fstatat|getattrlist|getattrlistbulk|fgetattrlist|getattrlistat)\s*\(/)
        required['NSPrivacyAccessedAPICategoryFileTimestamp'] = nil
      end
      if source.match?(/volumeAvailableCapacity|volumeTotalCapacity|volumeAvailableCapacityForImportantUsageKey|volumeAvailableCapacityForOpportunisticUsageKey|\b(?:statfs|fstatfs)\s*\(/)
        required['NSPrivacyAccessedAPICategoryDiskSpace'] = nil
      end
      required['NSPrivacyAccessedAPICategorySystemBootTime'] = nil if source.match?(/\bsystemUptime\b|\bmach_absolute_time\s*\(/)
      required
    end

    def asc_subscription_status(app_id:, product_id:)
      return nil if app_id.to_s.strip.empty? || product_id.to_s.strip.empty?

      token = appstore_connect_token
      return nil if token.nil?

      response = asc_get_json("/apps/#{app_id}/subscriptionGroups?include=subscriptions&limit=200", token: token)
      return nil unless response.is_a?(Hash)

      subscriptions = Array(response['included']).select { |entry| entry['type'] == 'subscriptions' }
      if subscriptions.empty?
        Array(response['data']).each do |group|
          group_id = group['id'].to_s.strip
          next if group_id.empty?

          group_response = asc_get_json("/subscriptionGroups/#{group_id}/subscriptions?limit=200", token: token)
          subscriptions.concat(Array(group_response&.dig('data'))) if group_response.is_a?(Hash)
        end
      end

      row = subscriptions.find do |entry|
        entry.dig('attributes', 'productId').to_s.strip == product_id.to_s.strip
      end
      return { exists: false, state: nil } unless row

      status = {
        exists: true,
        state: row.dig('attributes', 'state').to_s.strip
      }
      subscription_id = row['id'].to_s.strip
      unless subscription_id.empty?
        detail = asc_get_json(
          "/subscriptions/#{subscription_id}?include=subscriptionLocalizations,appStoreReviewScreenshot,prices,subscriptionAvailability",
          token: token
        )
        if detail.is_a?(Hash)
          included = Array(detail['included'])
          localizations = included.select { |entry| entry['type'] == 'subscriptionLocalizations' }
          status[:localization_states] = localizations.map { |entry| entry.dig('attributes', 'state').to_s.strip }.reject(&:empty?).uniq
          status[:rejected_localization] = status[:localization_states].include?('REJECTED')
          status[:has_localization] = localizations.any?

          screenshots = included.select { |entry| entry['type'] == 'subscriptionAppStoreReviewScreenshots' }
          screenshot_states = screenshots.map do |entry|
            attrs = entry['attributes'] || {}
            attrs.dig('assetDeliveryState', 'state') || attrs['fileStatus']
          end.compact
          status[:has_review_screenshot] = screenshots.any?
          status[:review_screenshot_states] = screenshot_states

          status[:has_price] = included.any? { |entry| entry['type'] == 'subscriptionPrices' }
          status[:has_availability] = included.any? { |entry| entry['type'] == 'subscriptionAvailabilities' }
        end
      end
      status
    end

    def appstore_no_iap_policy?(appstore_config)
      appstore_config['iap_policy'].to_s.strip.downcase == 'none'
    end

    def asc_list_app_subscriptions(app_id:, token:)
      response = asc_get_json("/apps/#{app_id}/subscriptionGroups?include=subscriptions&limit=200", token: token)
      return [] unless response.is_a?(Hash)

      subscriptions = Array(response['included']).select { |entry| entry['type'] == 'subscriptions' }
      if subscriptions.empty?
        Array(response['data']).each do |group|
          group_id = group['id'].to_s.strip
          next if group_id.empty?

          group_response = asc_get_json("/subscriptionGroups/#{group_id}/subscriptions?limit=200", token: token)
          subscriptions.concat(Array(group_response&.dig('data'))) if group_response.is_a?(Hash)
        end
      end
      subscriptions
    end

    def asc_subscription_has_rejected_version?(subscription_id:, token:)
      response = asc_get_json("/subscriptions/#{subscription_id}/versions?limit=200", token: token)
      return true unless response.is_a?(Hash)

      Array(response['data']).any? do |entry|
        entry.dig('attributes', 'state').to_s == 'DEVELOPER_REJECTED'
      end
    end

    def appstore_no_iap_preflight_report(app_id:, appstore_config:, lane_reports:, version_str:)
      report = { applicable: true, issues: [], warnings: [], summary: '' }
      retired_ids = Array(appstore_config['retired_product_ids'])
                    .map { |value| value.to_s.strip }
                    .reject(&:empty?)
                    .uniq
      token = appstore_connect_token
      unless token
        report[:warnings] << 'Could not verify no-IAP App Store Connect state without API token'
        report[:summary] = 'lookup unavailable'
        return report
      end

      subscriptions = asc_list_app_subscriptions(app_id: app_id, token: token)
      unexpected = subscriptions.reject do |entry|
        retired_ids.include?(entry.dig('attributes', 'productId').to_s.strip)
      end
      unless unexpected.empty?
        product_ids = unexpected.map { |entry| entry.dig('attributes', 'productId').to_s.strip }.join(', ')
        report[:issues] << "App Store Connect still has non-retired subscriptions: #{product_ids}"
      end

      subscriptions.select do |entry|
        retired_ids.include?(entry.dig('attributes', 'productId').to_s.strip)
      end.each do |entry|
        product_id = entry.dig('attributes', 'productId').to_s.strip
        subscription_id = entry['id'].to_s.strip
        name = entry.dig('attributes', 'name').to_s.strip

        if asc_subscription_has_rejected_version?(subscription_id: subscription_id, token: token)
          report[:warnings] <<(
            "Retired subscription #{product_id} (#{name}) has a DEVELOPER_REJECTED subscription version; " \
            'ASC refuses permanent deletion. Confirm unavailable + not in Included Assets, and reply in Resolution Center.'
          )
        end

        ready_lane = lane_reports.find do |_platform, lane_report|
          %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED READY_FOR_REVIEW].include?(
            lane_report[:target_state].to_s
          )
        end
        ready_lane_platform = ready_lane&.first
        if ready_lane_platform &&
           appstore_version_ui_includes_iap?(app_id: app_id, platform: ready_lane_platform, product_id: product_id)
          report[:issues] <<(
            "Retired subscription #{product_id} is still selected under Included Assets for " \
            "#{ready_lane_platform} #{version_str}"
          )
        end
      end

      report[:summary] = if report[:issues].empty?
                             "no IAP attached; #{retired_ids.length} retired subscription(s) checked"
                           else
                             report[:issues].first
                           end
      report
    end

    def appstore_iap_attachment_receipt_valid?(app_id:, platform:, version:, product_id:)
      path = [
        File.join(Dir.pwd, '.sane', 'appstore_iap_attachment_receipt.json'),
        File.join(Dir.pwd, 'outputs', 'appstore_iap_attachment_receipt.json')
      ].find { |candidate| File.file?(candidate) }
      return false unless path

      receipt = JSON.parse(File.read(path))
      generated_at = Time.parse(receipt['generatedAt'].to_s) rescue nil
      return false unless generated_at && generated_at > Time.now - (4 * 60 * 60)

      receipt['appId'].to_s == app_id.to_s &&
        receipt['platform'].to_s.downcase == platform.to_s.downcase &&
        receipt['version'].to_s == version.to_s &&
        receipt['productId'].to_s == product_id.to_s &&
        receipt['checked'] == true
    rescue StandardError
      false
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

    def entitlement_sources_include_game_center?(entitlement_paths:, project_yml_content:)
      blobs = Array(entitlement_paths).map { |path| File.read(path) rescue '' }
      blobs << project_yml_content.to_s
      blobs.any? { |blob| blob.include?('com.apple.developer.game-center') }
    end

    def asc_game_center_guardrail_report(app_id:, platform:, version_string:, entitlement_paths:, project_yml_content:)
      report = { applicable: false, issues: [], warnings: [], summary: 'not configured' }
      return report unless platform.to_s.downcase == 'ios'
      return report if app_id.to_s.strip.empty? || version_string.to_s.strip.empty?

      token = appstore_connect_token
      return report if token.nil?

      response = asc_get_json('/apps/%s/appStoreVersions?filter[platform]=IOS&limit=200' % app_id, token: token)
      return report unless response.is_a?(Hash)

      version_row = Array(response['data']).find do |entry|
        entry.dig('attributes', 'versionString').to_s.strip == version_string.to_s.strip
      end
      return report unless version_row

      version_id = version_row['id'].to_s.strip
      game_center = asc_get_json("/appStoreVersions/#{version_id}/gameCenterAppVersion", token: token)
      return report unless game_center.is_a?(Hash) && game_center['data'].is_a?(Hash)

      enabled = game_center.dig('data', 'attributes', 'enabled') == true
      has_entitlement = entitlement_sources_include_game_center?(
        entitlement_paths: entitlement_paths,
        project_yml_content: project_yml_content
      )
      report[:applicable] = true
      report[:summary] = enabled ? 'enabled in ASC' : 'disabled in ASC'

      if enabled && !has_entitlement
        report[:issues] << 'App Store Connect Game Center is enabled for this iOS version, but the build has no com.apple.developer.game-center entitlement.'
      elsif has_entitlement && !enabled
        report[:warnings] << 'Build declares Game Center entitlement, but App Store Connect Game Center is disabled for this iOS version.'
      end

      report
    end

    def appstore_version_ui_includes_iap?(app_id:, platform:, product_id:)
      return nil if app_id.to_s.strip.empty? || product_id.to_s.strip.empty?

      platform_path = platform.to_s.downcase == 'ios' ? 'ios' : 'macos'
      target_url = "https://appstoreconnect.apple.com/apps/#{app_id}/distribution/#{platform_path}/version/inflight"
      script = <<~JXA
        var brave = Application('Brave Browser');
        brave.includeStandardAdditions = true;
        if (!brave.running()) {
          console.log('UNAVAILABLE');
        } else if (brave.windows().length === 0) {
          console.log('UNAVAILABLE');
        } else {
          var tab = null;
          var windows = brave.windows();
          for (var windowIndex = 0; windowIndex < windows.length && !tab; windowIndex++) {
            var tabs = windows[windowIndex].tabs();
            for (var tabIndex = 0; tabIndex < tabs.length; tabIndex++) {
              var candidateURL = '';
              try { candidateURL = String(tabs[tabIndex].url()); } catch (candidateError) {}
              if (candidateURL.indexOf('https://appstoreconnect.apple.com') === 0) {
                tab = tabs[tabIndex];
                break;
              }
            }
          }
          if (!tab) {
            console.log('UNAVAILABLE');
          } else {
          var originalURL = '';
          try { originalURL = String(tab.url()); } catch (originalUrlError) {}
          function run(js) {
            return tab.execute({ javascript: js });
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
            if (!found && pageUrl.indexOf(#{target_url.to_json}) !== -1 && pageText.indexOf('Select In-App Purchases or Subscriptions') !== -1) {
              var modalProbe = run(`(function() {
                function text(el) { return (el.innerText || el.textContent || '').trim(); }
                var buttons = Array.from(document.querySelectorAll('button'));
                var selector = buttons.find(function(button) {
                  return text(button) === 'Select In-App Purchases or Subscriptions';
                });
                if (selector) selector.click();
                return 'opened';
              })()`);
              for (var j = 0; j < 10; j++) {
                delay(1);
                var state = run(`(function() {
                  var productId = #{product_id.to_json};
                  var body = document.body ? document.body.innerText : '';
                  if (body.indexOf(productId) === -1) return 'MISSING';
                  var checkboxes = Array.from(document.querySelectorAll('input[type="checkbox"]'));
                  if (checkboxes.some(function(input) { return input.checked; })) return 'FOUND';
                  return 'UNCHECKED';
                })()`);
                if (state === 'FOUND') {
                  found = true;
                  break;
                }
                if (state === 'UNCHECKED') break;
              }
              try {
                run(`(function() {
                  var done = Array.from(document.querySelectorAll('button')).find(function(button) {
                    return (button.innerText || '').trim() === 'Done';
                  });
                  if (done) done.click();
                })()`);
              } catch (closeError) {}
            }
            if (pageUrl.indexOf('https://appstoreconnect.apple.com') !== 0) {
              console.log('UNAVAILABLE');
            } else {
              console.log(found ? 'FOUND' : 'MISSING');
            }
          } catch (error) {
            console.log('ERROR:' + error.toString());
          }
          if (originalURL && originalURL.length > 0) {
            try { tab.url = originalURL; } catch (restoreError) {}
          }
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

    def write_release_status_snapshot(path:, status:, issues:, warnings:, verify_evidence: nil,
                                      migration_files: [], upgrade_path_evidence: nil)
      FileUtils.mkdir_p(File.dirname(path))
      payload = {
        type: 'release_preflight_status',
        generatedAt: Time.now.iso8601,
        host: Socket.gethostname,
        miniRuntime: release_status_mini_runtime?,
        projectName: File.basename(Dir.pwd),
        sourceFingerprint: release_status_source_fingerprint,
        status: status,
        issueCount: issues.count,
        warningCount: warnings.count,
        issues: issues,
        warnings: warnings,
        verifyEvidence: verify_evidence,
        migrationFiles: Array(migration_files),
        upgradePathEvidence: upgrade_path_evidence
      }
      upgrade_path_write_signed_atomic!(
        path,
        payload,
        producer: RELEASE_PREFLIGHT_PRODUCER,
        project_root: File.realpath(Dir.pwd)
      )
    end

    # Source-identity helpers live in SaneSourceFingerprint so hooks compare
    # receipts with the exact algorithm that produced them. These delegators
    # keep the historical release.rb API.
    def release_status_source_fingerprint(project_path = Dir.pwd)
      SaneSourceFingerprint.release_status_source_fingerprint(
        project_path,
        saneapps_root: release_status_saneapps_root
      )
    end

    def release_status_source_files(project_path)
      SaneSourceFingerprint.release_status_source_files(project_path)
    end

    def filesystem_release_status_source_files(project_path)
      SaneSourceFingerprint.filesystem_release_status_source_files(project_path)
    end

    def release_status_source_entries(project_path)
      SaneSourceFingerprint.release_status_source_entries(
        project_path,
        saneapps_root: release_status_saneapps_root
      )
    end

    def release_status_shared_source_files(project_path)
      SaneSourceFingerprint.release_status_shared_source_files(
        project_path,
        saneapps_root: release_status_saneapps_root
      )
    end

    def release_status_saneapps_root
      if respond_to?(:saneapps_root, true)
        saneapps_root
      else
        File.expand_path('../..', saneprocess_repo_root)
      end
    rescue StandardError
      SaneSourceFingerprint.default_saneapps_root
    end

    def release_status_mini_runtime?
      Socket.gethostname.to_s.downcase.include?('mini')
    rescue StandardError
      false
    end

    def release_status_harness_source_files(process_root = SaneSourceFingerprint.process_root)
      SaneSourceFingerprint.release_status_harness_source_files(process_root)
    end

    def release_status_proof_files(project_path)
      SaneSourceFingerprint.release_status_proof_files(project_path)
    end

    def release_status_source_file?(project_path, relative_path)
      SaneSourceFingerprint.release_status_source_file?(project_path, relative_path)
    end

    def launch_readiness(args)
      json_mode = args.delete('--json')
      max_age_days = parse_launch_readiness_max_age_days(args)
      report = launch_readiness_report(config: saneprocess_config, max_preflight_age_days: max_age_days)

      if json_mode
        puts JSON.pretty_generate(report)
      else
        puts '📣 --- [ LAUNCH READINESS ] ---'
        puts "Project: #{Dir.pwd}"
        puts "App: #{report[:app]}"
        puts "Classification: #{report[:classification]}" unless report[:classification].to_s.empty?
        puts "Rule: #{report[:rule]}" unless report[:rule].to_s.empty?
        puts "Latest release preflight: #{report[:release_preflight_status]}#{report[:release_preflight_age_days] ? " (#{report[:release_preflight_age_days]} day(s) old)" : ''}"
        puts ''

        if report[:issues].empty? && report[:warnings].empty?
          puts '✅ Launch-ready'
        else
          report[:issues].each { |issue| puts "🔴 #{issue}" }
          report[:warnings].each { |warning| puts "🟡 #{warning}" }
        end
      end

      exit 1 unless report[:ok]

      report
    rescue ArgumentError => e
      warn "Error: #{e.message}"
      exit 1
    end

    def parse_launch_readiness_max_age_days(args)
      raw_value = extract_flag_value(args, '--max-age-days')
      return DEFAULT_LAUNCH_READY_MAX_PREFLIGHT_AGE_DAYS if raw_value.nil?

      value = Integer(raw_value)
      raise ArgumentError, '--max-age-days must be greater than 0' if value <= 0

      value
    rescue ArgumentError
      raise ArgumentError, '--max-age-days must be a positive integer'
    end

    def launch_readiness_report(config:, max_preflight_age_days: DEFAULT_LAUNCH_READY_MAX_PREFLIGHT_AGE_DAYS)
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      report = {
        ok: true,
        app: app_name,
        issues: [],
        warnings: [],
        classification: '',
        rule: '',
        outreach_path: File.join(Dir.pwd, '.outreach.yml'),
        release_preflight_path: File.join(Dir.pwd, 'outputs', 'release_preflight_status.json'),
        release_preflight_status: 'missing',
        release_preflight_age_days: nil
      }

      unless File.exist?(report[:outreach_path])
        report[:issues] << 'Missing .outreach.yml launch source of truth'
        report[:ok] = false
        return report
      end

      outreach = YAML.safe_load(safe_read(report[:outreach_path])) || {}
      launch_calendar = metadata_node(outreach, 'launch_calendar')
      unless launch_calendar.is_a?(Hash)
        report[:issues] << 'Missing launch_calendar in .outreach.yml'
        report[:ok] = false
        return report
      end

      report[:classification] = metadata_value(launch_calendar, 'classification').to_s.strip
      report[:rule] = metadata_value(launch_calendar, 'rule').to_s.strip
      live_release_state = launch_readiness_live_release_state?(launch_calendar, report[:classification])
      launched_support_mode = launch_readiness_launched_support_mode?(launch_calendar, report[:classification])

      report[:issues] << 'launch_calendar.classification is required' if report[:classification].empty?
      report[:issues] << 'launch_calendar.rule is required' if report[:rule].empty?
      validate_launch_offer_window!(launch_calendar, report)

      Array(metadata_node(launch_calendar, 'blockers')).map { |item| item.to_s.strip }.reject(&:empty?).each do |blocker|
        report[:issues] << "Outstanding launch blocker: #{blocker}"
      end

      Array(metadata_node(launch_calendar, 'required_before_meaningful_launch')).map { |item| item.to_s.strip }.reject(&:empty?).each do |requirement|
        report[:issues] << "Missing meaningful-launch requirement completion: #{requirement}"
      end

      Array(metadata_node(launch_calendar, 'scheduled')).each_with_index do |entry, index|
        unless entry.is_a?(Hash)
          report[:issues] << "launch_calendar.scheduled[#{index}] must be a mapping"
          next
        end

        missing_fields = []
        has_timing = (!metadata_value(entry, 'date').to_s.strip.empty? && !metadata_value(entry, 'time').to_s.strip.empty?) ||
                     !metadata_value(entry, 'cadence').to_s.strip.empty?
        missing_fields << 'date/time or cadence' unless has_timing

        %w[channel action gate success_metric].each do |field|
          missing_fields << field if metadata_value(entry, field).to_s.strip.empty?
        end
        next if missing_fields.empty?

        report[:issues] << "launch_calendar.scheduled[#{index}] missing #{missing_fields.join(', ')}"
      end

      public_posting_policy = metadata_node(outreach, 'public_posting_policy')
      if public_posting_policy.is_a?(Hash)
        report[:warnings] << 'public_posting_policy.approval_required should be true before automation posts publicly' unless public_posting_policy['approval_required'] == true
        if public_posting_policy['disclosure_required'].to_s.strip.empty?
          report[:warnings] << 'public_posting_policy.disclosure_required should explain the builder disclosure rule'
        elsif !public_posting_policy['disclosure_required'].to_s.include?('I built')
          report[:warnings] << "public_posting_policy.disclosure_required should include the exact 'I built ...' disclosure"
        end
      else
        report[:warnings] << 'Missing public_posting_policy in .outreach.yml'
      end

      validate_launch_package!(outreach, report, launched_support_mode: launched_support_mode)

      unless File.exist?(report[:release_preflight_path])
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: 'Missing outputs/release_preflight_status.json; run ./scripts/SaneMaster.rb release_preflight first'
        )
        report[:ok] = false
        return report
      end

      preflight_status = upgrade_path_read_signed(
        report[:release_preflight_path],
        producer: RELEASE_PREFLIGHT_PRODUCER
      )
      unless preflight_status.is_a?(Hash)
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: 'release_preflight_status.json is unreadable'
        )
        report[:ok] = false
        return report
      end

      report[:release_preflight_status] = preflight_status['status'].to_s
      current_source_fingerprint = release_status_source_fingerprint(Dir.pwd).to_s
      if current_source_fingerprint.empty? || preflight_status['sourceFingerprint'].to_s != current_source_fingerprint
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: 'release_preflight_status.json does not match current source'
        )
      end
      generated_at = begin
        Time.parse(preflight_status['generatedAt'].to_s)
      rescue StandardError
        nil
      end
      if generated_at && generated_at > Time.now + SIGNED_RECEIPT_CLOCK_SKEW_SECONDS
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: 'release_preflight_status.json is future-dated'
        )
      elsif generated_at
        age_days = ((Time.now - generated_at) / 86_400.0).round(2)
        report[:release_preflight_age_days] = age_days
        if age_days > max_preflight_age_days
          launch_readiness_add_release_proof_finding!(
            report,
            live_release_state: live_release_state,
            message: "Latest release_preflight proof is stale (#{age_days} days old; max #{max_preflight_age_days})"
          )
        end
      else
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: 'release_preflight_status.json is missing a valid generatedAt timestamp'
        )
      end

      if report[:release_preflight_status] != 'passed'
        issue_count = preflight_status['issueCount']
        suffix = issue_count ? " (#{issue_count} issue(s))" : ''
        launch_readiness_add_release_proof_finding!(
          report,
          live_release_state: live_release_state,
          message: "Latest release_preflight is not green: #{report[:release_preflight_status]}#{suffix}"
        )
      end

      warning_count = preflight_status['warningCount'].to_i
      if warning_count.positive?
        report[:warnings] << "Latest release_preflight still has #{warning_count} warning(s)"
      end

      report[:ok] = report[:issues].empty?
      report
    end

    def launch_readiness_live_release_state?(launch_calendar, classification)
      classification_text = classification.to_s.strip
      return true if classification_text == 'meaningfully_launched'

      current_release_state = metadata_node(launch_calendar, 'current_release_state')
      status = metadata_value(current_release_state, 'status').to_s.strip
      status.start_with?('live_')
    end

    def launch_readiness_launched_support_mode?(launch_calendar, classification)
      classification.to_s.strip == 'meaningfully_launched' && launch_readiness_live_release_state?(launch_calendar, classification)
    end

    def launch_readiness_add_release_proof_finding!(report, live_release_state:, message:)
      if live_release_state
        report[:warnings] << "#{message} (advisory for already-live product state)"
      else
        report[:issues] << message
      end
    end

    def validate_launch_offer_window!(launch_calendar, report)
      offer_window = metadata_node(launch_calendar, 'offer_window')
      return unless offer_window.is_a?(Hash)

      message = metadata_value(offer_window, 'message').to_s.strip
      ends = metadata_value(offer_window, 'ends').to_s.strip
      report[:warnings] << 'launch_calendar.offer_window.message is required for date-bound launch offer copy' if message.empty?
      if ends.empty?
        report[:warnings] << 'launch_calendar.offer_window.ends is required for date-bound launch offer copy'
        return
      end

      end_date = Date.parse(ends)
      if end_date < Date.today
        report[:issues] << "launch_calendar.offer_window ended on #{end_date}; remove or replace stale offer copy before launch work"
      end
    rescue ArgumentError
      report[:issues] << "launch_calendar.offer_window.ends is not a valid date: #{ends.inspect}"
    end

    def validate_launch_package!(outreach, report, launched_support_mode: false)
      launch_package = metadata_node(outreach, 'launch_package')
      unless launch_package.is_a?(Hash)
        report[:issues] << 'Missing launch_package in .outreach.yml'
        return
      end

      REQUIRED_LAUNCH_PACKAGE_FIELDS.each do |field|
        report[:issues] << "launch_package.#{field} is required" if launch_value_blank?(metadata_value(launch_package, field))
      end
      report[:issues] << 'launch_package.weak_launch_blockers is required' unless launch_package.key?('weak_launch_blockers')

      proof_assets = metadata_node(launch_package, 'proof_assets')
      if proof_assets.is_a?(Array) && !proof_assets.empty?
        proof_assets.each_with_index do |asset, index|
          unless asset.is_a?(Hash)
            report[:issues] << "launch_package.proof_assets[#{index}] must be a mapping"
            next
          end

          REQUIRED_LAUNCH_PROOF_ASSET_FIELDS.each do |field|
            report[:issues] << "launch_package.proof_assets[#{index}].#{field} is required" if launch_value_blank?(metadata_value(asset, field))
          end
          if launch_value_blank?(metadata_value(asset, 'path')) && launch_value_blank?(metadata_value(asset, 'url'))
            report[:issues] << "launch_package.proof_assets[#{index}] needs path or url"
          end
        end
      else
        report[:issues] << 'launch_package.proof_assets must contain at least one visual/video asset'
      end

      channel_plan = metadata_node(launch_package, 'channel_plan')
      unless channel_plan.is_a?(Hash) || channel_plan.is_a?(Array)
        report[:issues] << 'launch_package.channel_plan must be a mapping or list'
      end

      blockers = Array(metadata_node(launch_package, 'weak_launch_blockers')).map { |item| item.to_s.strip }.reject(&:empty?)
      blockers.each do |blocker|
        if launched_support_mode
          report[:warnings] << "Outstanding weak-launch blocker: #{blocker} (major-launch advisory only for already-launched product)"
        else
          report[:issues] << "Outstanding weak-launch blocker: #{blocker}"
        end
      end
    end

    def launch_value_blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
    end

    def metadata_node(hash, *keys)
      return nil unless hash.is_a?(Hash)

      keys.each do |key|
        key_str = key.to_s
        key_sym = key_str.to_sym
        return hash[key_str] if hash.key?(key_str)
        return hash[key_sym] if hash.key?(key_sym)
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

    def appstore_platforms(appstore_config)
      Array(appstore_config['platforms'] || ['macos'])
        .map { |platform| platform.to_s.downcase }
        .reject(&:empty?)
    end

    def ios_only_appstore_submission?(platforms)
      normalized = Array(platforms).map { |platform| platform.to_s.downcase }
      normalized.include?('ios') && !normalized.include?('macos')
    end

    def appstore_deployment_target_summary(config:, appstore_config:, project_yml_content:)
      explicit = config.dig('release', 'min_system_version') || appstore_config['min_system_version']
      platforms = appstore_platforms(appstore_config)
      return "macOS #{explicit}" if !explicit.to_s.empty? && platforms.include?('macos')
      return "iOS #{explicit}" if !explicit.to_s.empty? && ios_only_appstore_submission?(platforms)
      return explicit.to_s unless explicit.to_s.empty?

      if platforms.include?('ios')
        ios_target = project_yml_content[/deploymentTarget:\s*\n\s*iOS:\s*["']?([0-9.]+)/, 1] ||
                     project_yml_content[/IPHONEOS_DEPLOYMENT_TARGET:\s*["']?([0-9.]+)/, 1]
        return "iOS #{ios_target}" unless ios_target.to_s.empty?
      end

      nil
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

    def review_notes_explain_app_store_business_model?(notes)
      normalized = notes.to_s.downcase.gsub(/\s+/, ' ').strip
      sentences = normalized.split(/[.!?;\n]+/).map(&:strip).reject(&:empty?)

      contradictory_model = normalized.match?(%r{
        \bbasic(?:\s+(?:tier|mode|access))?\s+(?:is\s+not|isn't|isnt|remains\s+not)\s+free\b
        |
        \b(?:a\s+)?(?:\d+[- ]day\s+)?(?:pro\s+)?trial\s+(?:is\s+not|isn't|isnt|remains\s+not)\s+free\b
        |
        \b(?:no|without|not)\s+(?:an?\s+)?(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b
        |
        \bdoes(?:n't|\s+not)\s+(?:require|use)\s+(?:an?\s+)?(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b
        |
        \bin-app\s+purchase\b.{0,24}\b(?:is\s+not|are\s+not|isn't|isnt|aren't|arent)\s+(?:required|used|available)\b
        |
        \bpro\b.{0,24}\b(?:
          (?:cannot|can't|cant)\s+be\s+purchased
          |
          (?:is\s+not|isn't|isnt)\s+available\s+for\s+(?:an?\s+)?(?:in-app\s+)?purchase
          |
          is\s+unavailable\s+for\s+(?:an?\s+)?(?:in-app\s+)?purchase
        )\b
        |
        \b(?:pro\s+)?(?:can\s+be\s+)?purchas(?:e|ed)\s+(?:through|via|from|on)\s+(?:the\s+)?(?:website|web\s*site|external\s+checkout)\b
        |
        \b(?:website|web\s*site|external\s+checkout|license\s+keys?)\b.{0,40}\b(?:unlocks?|upgrades?)\s+(?:the\s+)?(?:app|pro)\b
      }x)
      return false if contradictory_model

      free_basic_path = sentences.any? do |sentence|
        sentence.match?(/\bbasic(?:\s+(?:tier|mode|access))?\s+(?:is|remains)\s+(?:available\s+)?free\b/)
      end
      included_actions_path = sentences.any? do |sentence|
        sentence.match?(/\b(?:the\s+)?app\s+includes\s+\d+\s+(?:built-in\s+)?actions?\b/) ||
          sentence.match?(/\b\d+\s+(?:built-in\s+)?actions?\s+(?:are|remain)\s+included\b/)
      end
      trial_offer = sentences.any? do |sentence|
        sentence.match?(/\b(?:a\s+)?(?:\d+[- ]day\s+)?(?:pro\s+)?trial\s+(?:starts|begins|is\s+available|is\s+included)\b/)
      end
      trial_conversion = sentences.any? do |sentence|
        sentence.match?(/\bafter\s+(?:the\s+)?trial\b.*\b(?:continued\s+(?:app\s+)?access\s+requires|pro\s+(?:access\s+)?requires|purchase|unlock)\b/)
      end
      app_store_purchase_path = sentences.any? do |sentence|
        sentence.match?(/\b(?:pro|unlocks?\s+pro|upgrade\s+to\s+pro|continued\s+(?:app\s+)?access)\b.*\b(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b/) ||
          sentence.match?(/\b(?:one-time\s+)?(?:app\s+store\s+)?in-app\s+purchase\b.*\b(?:unlocks?\s+pro|pro\s+unlock|continued\s+(?:app\s+)?access)\b/) ||
          sentence.match?(/\bpurchase\s+(?:through|via|from|in)\s+(?:the\s+)?app\s+store\b.*\b(?:unlocks?\s+pro|pro\s+unlock|continued\s+(?:app\s+)?access)\b/) ||
          sentence.match?(/\b(?:one-time\s+)?app\s+store\s+(?:in-app\s+)?purchase\b.*\b(?:adds?|unlocks?)\b/)
      end
      no_external_checkout = sentences.any? { |sentence| sentence.match?(/\bno\s+(?:external|website|web)\s+checkout\b/) }
      no_license_keys = sentences.any? do |sentence|
        sentence.match?(/\bno\s+license\s+keys?\b/) ||
          sentence.match?(/\bno\s+(?:external|website|web)\s+checkout\s+(?:or|and)\s+license\s+keys?\b/)
      end

      (free_basic_path || included_actions_path || (trial_offer && trial_conversion)) &&
        app_store_purchase_path && no_external_checkout && no_license_keys
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
        # Shared core files can reference LicenseService without being compiled
        # into a platform's purchase UI. Require an actual purchase surface
        # before imposing App Review's paid-unlock navigation requirements.
        platform_uses_license_service = platform_source.match?(/\bLicenseService\b/) &&
                                        platform_source.match?(/Unlock Pro|purchasePro\(|restorePurchases\(/i)
        notes_text = review_notes_for_platform(appstore_config, platform).to_s
        notes_downcase = notes_text.downcase
        no_account_path = notes_downcase.match?(/no account required|no api key required|no credentials required|no sign.?in required|no .*payment .*launch|no .*payment .*demo/)
        demo_path = notes_downcase.match?(/demo|sample data|try demo data|enable demo mode/)
        business_model_path = review_notes_explain_app_store_business_model?(notes_text)
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

        next unless platform_uses_license_service

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
          report[:issues] << "[#{platform}] Review notes do not clearly explain the App Store business model (included access, in-app unlock path, no website license flow)"
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
      verify_evidence = nil
      upgrade_path_evidence = nil
      defaults_files = []
      preflight_status_path = File.join(Dir.pwd, 'outputs', 'release_preflight_status.json')
      saneprocess_path = File.join(Dir.pwd, '.saneprocess')
      preflight_config = if File.exist?(saneprocess_path)
                           YAML.safe_load(safe_read(saneprocess_path)) || {}
                         else
                           {}
                         end
      preflight_app_name = metadata_value(preflight_config, 'name') || File.basename(Dir.pwd)

      # 0. Auto-reconcile stash gate
      print '  Auto-reconcile stashes... '
      routed_workspace = routed_workspace_context
      stash_reports = if routed_workspace && routed_workspace.key?('auto_reconcile_stash_reports')
                        Array(routed_workspace['auto_reconcile_stash_reports']).map do |report|
                          {
                            ref: report['ref'].to_s,
                            stash_sha: report['stash_sha'].to_s,
                            subject: report['subject'].to_s,
                            blocking_files: Array(report['blocking_files']).map(&:to_s)
                          }
                        end
                      else
                        auto_reconcile_stash_reports(repo_path: Dir.pwd)
                      end
      stash_reports = stash_reports.reject { |report| reviewed_auto_reconcile_stash?(preflight_config, report) }
      if stash_reports.empty?
        puts '✅ none blocking'
      else
        puts '❌ FAIL'
        stash_reports.each do |report|
          sample = report[:blocking_files].first(6).join(', ')
          hidden_count = report[:blocking_files].length - 6
          suffix = hidden_count.positive? ? " (+#{hidden_count} more)" : ''
          puts "    ↳ #{report[:ref]} #{sample}#{suffix}"
          issues << "Unreviewed auto-reconcile stash #{report[:ref]} contains release-relevant files"
        end
      end

      # 0. Repeated issue gate fixtures
      print '  Repeated issue gate fixtures... '
      gate_reports = release_gate_fixture_reports(preflight_app_name)
      failed_gate_reports = gate_reports.reject { |report| report[:passed] }
      if gate_reports.empty?
        puts '⏭️  none configured'
      elsif failed_gate_reports.empty?
        puts "✅ #{gate_reports.length} fixture(s)"
      else
        puts '❌ FAIL'
        failed_gate_reports.each do |report|
          issues << "Gate fixture failed: #{File.basename(report[:fixture].to_s)}"
        end
      end

      # 1. Project policy guardrails. Apps can expose a cheap policy-only QA mode
      # so release preflight catches cadence/regression blockers before verify.
      qa_script = release_project_qa_script
      qa_policy_only_supported = release_project_qa_policy_only_supported?(qa_script)
      print '  Project QA policy guardrails... '
      if qa_policy_only_supported
        puts
        qa_out, qa_status = capture_release_command_output(
          release_project_qa_env(app_name: preflight_app_name, policy_only: true),
          'ruby',
          qa_script,
          heartbeat_label: 'project QA policy guardrails'
        )
        if qa_status.success?
          puts "  Project QA policy guardrails... ✅ (#{qa_script})"
        else
          puts '  Project QA policy guardrails... ❌ FAIL'
          warn_line = summarized_output_tail(qa_out)
          puts "    ↳ #{warn_line}" unless warn_line.empty?
          issues << "Project QA policy guardrails failed (#{qa_script})"
        end
      elsif qa_script
        puts '⏭️  skipped (qa.rb has no policy-only mode)'
      else
        puts '⏭️  skipped (no qa.rb)'
      end

      # 1b. Customer-facing UI/UX action contract.
      ui_contract_report = nil
      print '  Customer UI action contract... '
      if respond_to?(:customer_ui_contract_report)
        ui_contract_report = customer_ui_contract_report(config: preflight_config)
        if ui_contract_report[:ok]
          puts "✅ #{ui_contract_report[:action_count]} action(s)"
        else
          puts '❌ FAIL'
          Array(ui_contract_report[:issues]).each do |issue|
            puts "    ↳ #{issue}"
            issues << "Customer UI action contract: #{issue}"
          end
        end
      else
        puts '❌ FAIL'
        issues << 'Customer UI action contract checker is not loaded'
      end

    # 1c. Monetization guardrails (protect against accidental full-free releases)
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

      # 1d. API availability compatibility guardrails
      print '  API compatibility... '
      api_compatibility = api_compatibility_guardrail_report(config: preflight_config)
      if api_compatibility[:applicable]
        if api_compatibility[:issues].empty?
          puts "✅ #{api_compatibility[:summary]}"
        else
          puts "❌ #{api_compatibility[:summary]}"
          api_compatibility[:issues].each { |m| issues << "API compatibility: #{m}" }
        end
        api_compatibility[:warnings].each { |m| warnings << "API compatibility: #{m}" }
      else
        puts "⏭️  skipped (#{api_compatibility[:summary]})"
      end

      # 2. Git clean
      print '  Git clean... '
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
      defaults_files = defaults_migration_changed_files_from_diff(
        recent_swift_diff_for_preflight(routed_workspace)
      )
      if defaults_files.any?
        puts "⚠️  #{defaults_files.count} file(s)"
        defaults_files.each { |f| puts "    - #{f}" }
        upgrade_report = upgrade_path_behavioral_proof_report(
          app_name: preflight_app_name,
          routed_workspace: routed_workspace,
          source_fingerprint: release_status_source_fingerprint
        )
        if upgrade_report[:ok]
          upgrade_path_evidence = upgrade_report[:evidence]
          puts "    ✅ Fresh behavioral upgrade proof: #{upgrade_report[:receipt_path]}"
        else
          puts "    ❌ #{upgrade_report[:error]}"
          issues << "UserDefaults/migration code changed without current behavioral upgrade-path proof: #{upgrade_report[:error]}"
        end
      else
        puts '✅ none'
      end

      # 4. Sparkle key in project config
      print '  Sparkle public key... '
      plist_paths = project_info_plist_paths
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
        informational_entries_missing_versions = informational_appcast_entries_missing_versions(safe_read(appcast_path))
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
        unless informational_entries_missing_versions.empty?
          gate_failures << "Informational appcast entries missing sparkle:version: #{informational_entries_missing_versions.join(', ')}"
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
        issue_json, issue_status = capture_github_command_with_timeout(
          { 'PATH' => tool_path },
          gh_bin, 'issue', 'list', '--repo', repo, '--state', 'open', '--json', 'number'
        )
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
        pr_json, pr_status = capture_github_command_with_timeout(
          { 'PATH' => tool_path },
          gh_bin, 'pr', 'list', '--repo', repo, '--state', 'open', '--json', 'number'
        )
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
        pending_json = fetch_text(
          'https://email-api.saneapps.com/api/emails/pending',
          headers: { 'Authorization' => "Bearer #{api_key}" }
        )
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
      ls_status, = Open3.capture2('curl', '--connect-timeout', '10', '--max-time', '20',
                                  '-sI', '-o', '/dev/null', '-w', '%{http_code}',
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
      tap_repo = homebrew_tap_repo(preflight_config)
      cask_url_base = "https://raw.githubusercontent.com/#{tap_repo}/main/Casks/#{cask_app}.rb"
      cask_commit = nil
      commits_api = "https://api.github.com/repos/#{tap_repo}/commits?path=Casks/#{cask_app}.rb&per_page=1"
      commits_json, commits_status = Open3.capture2(
        'curl', '--connect-timeout', '10', '--max-time', '20', '-fsSL', commits_api
      )
      if commits_status.success?
        commits = JSON.parse(commits_json) rescue []
        cask_commit = commits.first['sha'].to_s.strip if commits.is_a?(Array) && commits.first.is_a?(Hash)
      end
      cask_url = if cask_commit && !cask_commit.empty?
                   "https://raw.githubusercontent.com/#{tap_repo}/#{cask_commit}/Casks/#{cask_app}.rb"
                 else
                   cask_url_base
                 end
      tap_status, = Open3.capture2(
        'curl', '--connect-timeout', '10', '--max-time', '20',
        '-sI', '-o', '/dev/null', '-w', '%{http_code}', cask_url
      )
      tap_status = tap_status.strip
      cask_body = if tap_status == '200'
                    Open3.capture2(
                      'curl', '--connect-timeout', '10', '--max-time', '20', '-fsSL', cask_url
                    ).first
                  else
                    ''
                  end
      homebrew_result = homebrew_cask_preflight_result(
        config: preflight_config,
        tap_status: tap_status,
        cask_body: cask_body,
        project_version: project_marketing_version(project_yml_content),
        appcast_version: local_latest_appcast_version,
        min_system_version: release_min_system_version(preflight_config)
      )
      puts homebrew_result[:message]
      warnings.concat(homebrew_result[:warnings])
      issues.concat(homebrew_result[:issues])

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

      # 10a. Website download link version drift
      print '  Website download link version... '
      if website_domain.empty? || live_appcast_item[:version].to_s.empty?
        puts '⏭️  no website/appcast version'
      else
        website_version = website_versioned_archive_version_for_domain(
          app_name: preflight_app_name,
          website_domain: website_domain
        )
        if website_version.empty?
          puts '⚠️  no reachable versioned archive link found'
          warnings << "#{preflight_app_name} website has no reachable versioned archive link to compare against appcast"
        elsif website_version == live_appcast_item[:version]
          puts "✅ #{preflight_app_name} v#{website_version}"
        else
          puts "❌ DRIFT: website=#{website_version}, appcast=#{live_appcast_item[:version]}"
          issues << "Website download link serves #{preflight_app_name}-#{website_version} but live appcast is at #{live_appcast_item[:version]}"
        end
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

      # 11. Expensive verification runs last. If cheaper release blockers already
      # failed, do not spend build/test/runtime minutes on a release that cannot ship.
      print '  Tests... '
      if issues.any?
        puts '⏭️  skipped (fix cheap release blocker(s) first)'
      else
        verify_env = { 'SANEMASTER_RELEASE_PREFLIGHT' => '1' }
        puts
        verify_started_at = Time.now.utc
        out, status = capture_release_command_output(
          verify_env,
          './scripts/SaneMaster.rb',
          'verify',
          '--quiet',
          heartbeat_label: 'SaneMaster verify',
          heartbeat_seconds: 15,
          timeout_seconds: release_verify_timeout_seconds
        )
        verify_fingerprint = if respond_to?(:verify_source_fingerprint, true)
                               send(:verify_source_fingerprint).to_s
                             else
                               ''
                             end
        verify_evidence = release_verify_evidence_from_metrics(
          since: verify_started_at,
          source_fingerprint: verify_fingerprint
        )
        if release_verify_result_valid?(status: status, evidence: verify_evidence)
          puts '  Tests... ✅ (successful process + structured current verify receipt)'
        else
          puts '  Tests... ❌ FAIL'
          hint = summarized_output_tail(out)
          puts "    ↳ #{hint}" unless hint.empty?
          issues << if !status&.success?
                      'Tests failing or timed out'
                    else
                      'Verify completed without a structured current source-fingerprint receipt'
                    end
        end
      end

      print '  Project QA guardrails... '
      if qa_script.nil?
        puts '⏭️  skipped (no qa.rb)'
      elsif issues.any?
        puts '⏭️  skipped (fix earlier release blocker(s) first)'
      else
        puts
        skip_runtime_smoke = release_customer_ui_runtime_smoke_reusable?(
          ui_contract_report,
          app_name: preflight_app_name
        )
        if skip_runtime_smoke
          puts '    ↳ reusing fresh customer UI runtime proof; full QA will skip duplicate runtime smoke'
        end
        qa_out, qa_status = capture_release_command_output(
          release_project_qa_env(
            app_name: preflight_app_name,
            policy_only: false,
            skip_runtime_smoke: skip_runtime_smoke
          ),
          'ruby',
          qa_script,
          heartbeat_label: 'project QA guardrails'
        )
        if qa_status.success?
          puts "  Project QA guardrails... ✅ (#{qa_script})"
        else
          puts '  Project QA guardrails... ❌ FAIL'
          warn_line = summarized_output_tail(qa_out)
          puts "    ↳ #{warn_line}" unless warn_line.empty?
          issues << "Project QA guardrails failed (#{qa_script})"
        end
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
        warnings: warnings,
        verify_evidence: verify_evidence,
        migration_files: defaults_files,
        upgrade_path_evidence: upgrade_path_evidence
      )
      record_process_metric(
        'release_preflight',
        success: issues.empty?,
        app: preflight_app_name,
        issues_count: issues.length,
        warnings_count: warnings.length
      ) if respond_to?(:record_process_metric)

      exit 1 if issues.any?
    end

    def release_gate_fixture_reports(app_name)
      release_gate_fixture_paths(app_name).map do |fixture_path|
        review_gate_fixture(JSON.parse(File.read(fixture_path)), fixture_path: fixture_path)
      rescue JSON::ParserError, ArgumentError => e
        {
          fixture: fixture_path,
          passed: false,
          failed_count: 1,
          rules: [{ issues: [e.message] }]
        }
      end
    end

    def release_gate_fixture_paths(app_name)
      normalized = app_name.to_s.downcase.gsub(/[^a-z0-9]+/, '')
      return [] if normalized.empty?

      root = respond_to?(:saneprocess_repo_root) ? saneprocess_repo_root : File.expand_path('../..', __dir__)
      Dir.glob(File.join(root, 'test', 'fixtures', 'gates', "#{normalized}_*.json")).sort
    end

    # App Store submission preflight — validates deterministic release evidence
    # and known policy contradictions. Human App Review remains a separate gate.
    # Derived from Apple's App Review Guidelines + community rejection checklists.
    # Works for any SaneApps project with a .saneprocess config.
    def appstore_preflight(args)
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
      policy_freshness = store_policy_freshness_report(:apple)
      issues.concat(policy_freshness[:issues])
      warnings.concat(policy_freshness[:warnings])

      config_path = File.join(Dir.pwd, '.saneprocess')
      config = if File.exist?(config_path)
                 YAML.safe_load(File.read(config_path)) || {}
               else
                 {}
               end

      app_name = config['name'] || File.basename(Dir.pwd)
      appstore_config = config['appstore'] || {}
      platforms = appstore_platforms(appstore_config)

      unless appstore_config['enabled'] == true
        puts '  ⏭️  App Store lane disabled in .saneprocess; skipping App Store preflight.'
        puts '  Use release_preflight for direct-download release readiness.'
        puts '  Re-enable only after an explicit App Store strategy decision and fresh review of policy, pricing, and metadata.'
        return true
      end

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
      credentials = resolved_asc_credentials
      p8_path = credentials[:key_path]
      missing_credential_fields = []
      missing_credential_fields << 'ASC_AUTH_KEY_ID' if credentials[:key_id].empty?
      missing_credential_fields << 'ASC_AUTH_ISSUER_ID' if credentials[:issuer_id].empty?
      missing_credential_fields << 'ASC_AUTH_KEY_PATH' if p8_path.empty?
      if missing_credential_fields.empty? && File.exist?(p8_path)
        puts '✅'
      elsif !missing_credential_fields.empty?
        puts '❌ not configured'
        issues << "ASC API credentials missing: #{missing_credential_fields.join(', ')}. Set env vars or keychain services saneprocess.asc.key_id, saneprocess.asc.issuer_id, and saneprocess.asc.key_path."
      else
        puts '❌ not found'
        issues << "ASC_AUTH_KEY_PATH does not exist: #{p8_path}"
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

      # 1e. Mature third-party metadata heuristics (advisory tool, not release authority)
      print '  │ fastlane metadata precheck... '
      fastlane_report = fastlane_precheck_report(
        app_identifier: config['bundle_id'].to_s,
        platform: platforms.first.to_s == 'macos' ? 'osx' : 'ios',
        include_iap: !appstore_no_iap_policy?(appstore_config),
        credentials: credentials
      )
      if fastlane_report[:issues].empty?
        puts fastlane_report[:summary] == 'passed' ? '✅' : '⚠️  skipped'
      else
        puts '❌ FAIL'
      end
      issues.concat(fastlane_report[:issues])
      warnings.concat(fastlane_report[:warnings])

      # 1f. App-level territory availability
      print '  │ ASC app availability... '
      if asc_app_id.to_s.strip.empty?
        puts '⚠️  skipped (no ASC app_id)'
        warnings << 'Cannot verify app-level App Store availability without appstore.app_id'
      else
        app_availability = asc_app_availability_status(app_id: asc_app_id)
        case app_availability
        when Hash
          if !app_availability[:exists]
            puts '❌ missing'
            issues << 'App Store Connect app availability is missing — the app can be READY_FOR_SALE but invisible publicly. Run appstore_submit repair or create app availability before release.'
          elsif app_availability[:territory_total].to_i <= 0
            puts '❌ no territories'
            issues << 'App Store Connect app availability has no territory rows.'
          elsif app_availability[:all_territories_available]
            puts "✅ #{app_availability[:available_count]} territory(ies)"
          else
            counts = app_availability[:content_status_counts] || {}
            summary = counts.map { |status, count| "#{status}=#{count}" }.join(', ')
            puts "❌ #{summary.empty? ? 'not available' : summary}"
            issues << "App Store Connect app availability is not public-ready (#{summary.empty? ? 'unknown status' : summary})."
          end
        else
          puts '⚠️  lookup failed'
          warnings << 'Could not verify App Store Connect app availability.'
        end
      end

      puts '  │'

      # 1f. Strict customer-facing UI/action visual proof.
      print '  │ Customer UI strict visual contract... '
      if respond_to?(:customer_ui_contract_report)
        ui_contract_report = customer_ui_contract_report(config: config, strict_visual: true)
        if ui_contract_report[:ok]
          puts "✅ #{ui_contract_report[:action_count]} action(s)"
        else
          puts '❌ FAIL'
          Array(ui_contract_report[:issues]).each do |issue|
            puts "    ↳ #{issue}"
            issues << "Customer UI strict visual contract: #{issue}"
          end
        end
      else
        puts '❌ FAIL'
        issues << 'Customer UI strict visual contract checker is not loaded'
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
      submission_target = appstore_preflight_submission_target(
        args: args,
        version: version_str,
        build: build_num,
        platforms: platforms,
        issues: issues
      )
      if submission_target&.dig(:path)
        print '  │ Apple exact-package validation... '
        apple_validation = appstore_package_validation_report(
          package_path: submission_target[:path],
          platform: submission_target[:platform],
          credentials: credentials
        )
        if apple_validation[:issues].empty?
          puts '✅'
        else
          puts '❌ FAIL'
        end
        issues.concat(apple_validation[:issues])
        warnings.concat(apple_validation[:warnings])
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
      elsif ios_only_appstore_submission?(platforms)
        puts '✅ not required for iOS-only lane'
      else
        puts '❌ no .entitlements file found'
        issues << 'No entitlements file found'
      end

      # 2c. Privacy manifest (PrivacyInfo.xcprivacy)
      print '  │ Privacy manifest... '
      privacy_manifests = Dir.glob('**/PrivacyInfo.xcprivacy').reject { |p| p.include?('DerivedData') || p.include?('build/') }
      privacy_manifest_report = privacy_manifest_guardrail_report(
        manifest_paths: privacy_manifests,
        project_yml_content: project_yml_content
      )
      if privacy_manifest_report[:issues].empty?
        puts "✅ #{privacy_manifest_report[:summary]}"
        privacy_manifest_report[:warnings].each { |msg| warnings << "Privacy manifest: #{msg}" }
      else
        puts "❌ #{privacy_manifest_report[:issues].first}"
        privacy_manifest_report[:issues].each { |msg| issues << "Privacy manifest: #{msg}" }
        privacy_manifest_report[:warnings].each { |msg| warnings << "Privacy manifest: #{msg}" }
      end

      # 2d. Deployment target
      print '  │ Deployment target... '
      deployment_target = appstore_deployment_target_summary(
        config: config,
        appstore_config: appstore_config,
        project_yml_content: project_yml_content
      )
      if deployment_target
        puts "✅ #{deployment_target}"
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
              if files.count > 10
                screenshot_issues << "#{platform} has #{files.count} screenshots configured; Apple allows up to 10 per display/localization"
              end
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
                    if ipad_files.count > 10
                      screenshot_issues << "ipad has #{ipad_files.count} screenshots configured; Apple allows up to 10 per display/localization"
                    end
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

      # 3d. Required App Store metadata declarations
      print '  │ Required metadata declarations... '
      metadata_completeness = appstore_metadata_completeness_report(
        appstore_config: appstore_config,
        platforms: platforms
      )
      if metadata_completeness[:issues].empty?
        puts "✅ #{metadata_completeness[:summary]}"
      else
        puts "❌ #{metadata_completeness[:issues].first}"
        metadata_completeness[:issues].each { |msg| issues << "App Store metadata: #{msg}" }
      end
      metadata_completeness[:warnings].each { |msg| warnings << "App Store metadata: #{msg}" }

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
      plist_paths = project_info_plist_paths
      plist_content = plist_paths.map { |f| safe_read(f) }.join("\n")

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
      puts
      verify_started_at = Time.now.utc
      out, status = capture_release_command_output(
        verify_env,
        './scripts/SaneMaster.rb',
        'verify',
        '--quiet',
        heartbeat_label: 'SaneMaster verify',
        heartbeat_seconds: 15,
        timeout_seconds: release_verify_timeout_seconds
      )
      verify_fingerprint = if respond_to?(:verify_source_fingerprint, true)
                             send(:verify_source_fingerprint).to_s
                           else
                             ''
                           end
      verify_evidence = release_verify_evidence_from_metrics(
        since: verify_started_at,
        source_fingerprint: verify_fingerprint
      )
      if release_verify_result_valid?(status: status, evidence: verify_evidence)
        puts '  │ Tests... ✅ (successful process + structured current verify receipt)'
      else
        puts '  │ Tests... ❌ FAIL'
        hint = summarized_output_tail(out)
        puts "  │   ↳ #{hint}" unless hint.empty?
        if status.nil? || !status.success?
          issues << 'Tests failing or timed out — fix before submission'
        else
          issues << 'Tests completed without a structured current Mini verify receipt — fix before submission'
        end
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

      # 5c0b. Game Center must match the submitted binary entitlements.
      if platforms.include?('ios')
        print '  │ ASC Game Center... '
        if asc_app_id.to_s.strip.empty? || version_str.to_s.strip.empty?
          puts '⚠️  skipped'
          warnings << 'Cannot verify App Store Connect Game Center state without appstore.app_id and MARKETING_VERSION'
        else
          game_center_reports = Array(platforms).select { |platform| platform.to_s == 'ios' }.map do |platform|
            [platform, asc_game_center_guardrail_report(
              app_id: asc_app_id,
              platform: platform,
              version_string: version_str,
              entitlement_paths: entitlements,
              project_yml_content: project_yml_content
            )]
          end
          applicable_gc_reports = game_center_reports.select { |_platform, report| report[:applicable] }
          if applicable_gc_reports.empty?
            puts '✅ not enabled'
          else
            gc_issues = applicable_gc_reports.flat_map { |_platform, report| Array(report[:issues]) }
            gc_warnings = applicable_gc_reports.flat_map { |_platform, report| Array(report[:warnings]) }
            if gc_issues.empty?
              puts "✅ #{applicable_gc_reports.map { |_platform, report| report[:summary] }.join(' | ')}"
            else
              puts "❌ #{applicable_gc_reports.map { |_platform, report| report[:summary] }.join(' | ')}"
              gc_issues.each { |message| issues << "Game Center: #{message}" }
            end
            gc_warnings.each { |message| warnings << "Game Center: #{message}" }
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

      # 5d0. Explicit no-IAP policy (Stripe-only / enterprise companion apps)
      if appstore_no_iap_policy?(appstore_config)
        print '  │ No-IAP ASC policy... '
        no_iap_report = appstore_no_iap_preflight_report(
          app_id: asc_app_id,
          appstore_config: appstore_config,
          lane_reports: lane_reports,
          version_str: version_str
        )
        if no_iap_report[:issues].empty?
          puts "✅ #{no_iap_report[:summary]}"
        else
          puts "❌ #{no_iap_report[:issues].first}"
          no_iap_report[:issues].each { |msg| issues << "No-IAP policy: #{msg}" }
        end
        no_iap_report[:warnings].each { |msg| warnings << "No-IAP policy: #{msg}" }
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
      if appstore_no_iap_policy?(appstore_config)
        puts '⏭️  skipped (iap_policy: none)'
      elsif configured_product_id.empty?
        puts '⏭️  skipped (no appstore.product_id configured)'
      elsif asc_app_id.to_s.strip.empty?
        puts '⚠️  skipped (no ASC app_id)'
        warnings << 'Cannot verify IAP in App Store Connect without appstore.app_id'
      else
        subscription_product = appstore_iap_auto_renewable_subscription?(appstore_config)
        iap_status = if subscription_product
                       asc_subscription_status(app_id: asc_app_id, product_id: configured_product_id)
                     else
                       asc_iap_status(app_id: asc_app_id, product_id: configured_product_id)
                     end
        record_label = subscription_product ? 'subscription' : 'IAP'
        case iap_status
        when Hash
          if !iap_status[:exists]
            puts "❌ #{configured_product_id} not found"
            issues << "App Store Connect has no #{record_label} with product_id #{configured_product_id}"
          elsif iap_status[:rejected_localization]
            puts "❌ #{configured_product_id} (#{iap_status[:state]})"
            issues << "App Store Connect IAP #{configured_product_id} has a REJECTED localization — Apple requires a new product_id for a replacement IAP."
          elsif subscription_product && !iap_status[:has_localization]
            puts "❌ #{configured_product_id} (missing localization)"
            issues << "App Store Connect subscription #{configured_product_id} is missing localization metadata."
          elsif subscription_product && !iap_status[:has_price]
            puts "❌ #{configured_product_id} (missing price)"
            issues << "App Store Connect subscription #{configured_product_id} is missing subscription price metadata."
          elsif subscription_product && !iap_status[:has_availability]
            puts "❌ #{configured_product_id} (missing availability)"
            issues << "App Store Connect subscription #{configured_product_id} is missing territory availability."
          elsif subscription_product && !iap_status[:has_review_screenshot]
            puts "❌ #{configured_product_id} (missing review screenshot)"
            issues << "App Store Connect subscription #{configured_product_id} is missing its App Review screenshot."
          elsif %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_BINARY_APPROVAL APPROVED READY_FOR_SALE].include?(iap_status[:state])
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
              warnings << "App Store Connect still reports #{record_label} #{configured_product_id} as READY_TO_SUBMIT, but Brave verified it is attached under Included Assets for #{ready_lane_platform} #{version_str}"
            elsif ready_lane_platform && appstore_iap_attachment_receipt_valid?(
              app_id: asc_app_id,
              platform: ready_lane_platform,
              version: version_str,
              product_id: configured_product_id
            )
              puts "⚠️  #{configured_product_id} (READY_TO_SUBMIT, attachment receipt verified)"
              warnings << "App Store Connect still reports #{record_label} #{configured_product_id} as READY_TO_SUBMIT, but a fresh ASC attachment receipt verifies it is selected for #{ready_lane_platform} #{version_str}"
            else
              puts "❌ #{configured_product_id} (READY_TO_SUBMIT)"
              issues << "App Store Connect #{record_label} #{configured_product_id} is still READY_TO_SUBMIT — Apple requires it to be added to the app version's In-App Purchases and Subscriptions section before submission."
            end
          else
            puts "❌ #{configured_product_id} (#{iap_status[:state]})"
            issues << "App Store Connect #{record_label} #{configured_product_id} exists but is not review-ready (state=#{iap_status[:state]})"
          end
        when nil
          puts '⚠️  lookup failed'
          warnings << "Could not verify App Store Connect #{record_label} record for #{configured_product_id}"
        else
          puts "❌ #{configured_product_id} not found"
          issues << "App Store Connect has no #{record_label} with product_id #{configured_product_id}"
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

      # 5e1. Auto-renewable subscription purchase-flow disclosures
      print '  │ Subscription purchase flow... '
      subscription_flow_report = subscription_purchase_flow_guardrail_report(
        source_blob: all_source,
        appstore_config: appstore_config,
        config: config
      )
      if subscription_flow_report[:applicable]
        if subscription_flow_report[:issues].empty?
          puts "✅ #{subscription_flow_report[:summary]}"
        else
          puts "❌ #{subscription_flow_report[:issues].first}"
          subscription_flow_report[:issues].each { |msg| issues << "Subscription purchase flow: #{msg}" }
        end
        subscription_flow_report[:warnings].each { |msg| warnings << "Subscription purchase flow: #{msg}" }
      else
        puts '⏭️  skipped (no auto-renewable subscription configured)'
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
      compiled_artifact_verified_clean = false
      artifact_report = nil
      begin
        if submission_target && submission_target[:path]
          package_path = submission_target[:path].to_s
          actual_sha = File.file?(package_path) ? OpenSSL::Digest::SHA256.file(package_path).hexdigest : ''
          if actual_sha != submission_target[:sha256].to_s
            artifact_report = {
              verified: false,
              issues: ['Exact App Store package bytes changed after submissionTarget binding; rerun preflight for the selected package'],
              warnings: []
            }
          else
            appstore_with_submission_package_app(
              package_path,
              expected_bundle_ids: [submission_target[:bundleId]],
              expected_sha256: submission_target[:sha256]
            ) do |selection|
              artifact_report = if selection[:verified]
                                  appstore_compiled_artifact_report(
                                    app_dir: selection[:app_dir],
                                    platform: selection[:platform],
                                    expected_bundle_id: submission_target[:bundleId],
                                    review_notes_blob: review_notes_blob,
                                    configured_product_id: configured_product_id,
                                    uses_storekit_unlock: uses_storekit_unlock
                                  )
                                else
                                  { verified: false, issues: selection[:issues], warnings: [] }
                                end
            end
          end
        elsif platforms.include?('macos')
          with_launch_services_clean_tempdir('sanemaster_asc_audit') do |tmpdir|
            derived_data = File.join(tmpdir, 'DerivedData')
            configuration = (asc_config_name || appstore_config['configuration'] || 'Release-AppStore').to_s
            scheme = (appstore_config['scheme'] || config['scheme'] || app_name).to_s
            workspace = config['workspace']
            project = config['project'] || Dir.glob('*.xcodeproj').first
            signing_targets = appstore_macos_signing_targets(project_yml)
            named_targets = signing_targets.select { |target| target[:name].to_s == scheme }
            expected_bundle_ids = (named_targets.empty? ? signing_targets : named_targets)
              .map { |target| target[:bundle_id].to_s }.reject(&:empty?).uniq

            if expected_bundle_ids.length != 1
              artifact_report = {
                verified: false,
                issues: ["Cannot resolve one exact App Store bundle ID for scheme #{scheme} (found: #{expected_bundle_ids.join(', ')})"],
                warnings: []
              }
              next
            end

            build_cmd = ['xcodebuild']
            if workspace && File.exist?(workspace)
              build_cmd += ['-workspace', workspace]
            elsif project && File.exist?(project)
              build_cmd += ['-project', project]
            else
              artifact_report = { verified: false, issues: ['Cannot run compiled App Store artifact audit: missing workspace/project path'], warnings: [] }
              next
            end
            build_cmd += [
              '-scheme', scheme, '-configuration', configuration, '-destination', 'platform=macOS',
              '-derivedDataPath', derived_data, 'CODE_SIGNING_ALLOWED=NO', 'build'
            ]
            effective_build_flags = Array(appstore_config['build_flags']).map(&:to_s).reject(&:empty?)
            unless configured_product_id.empty? || effective_build_flags.any? { |flag| flag.start_with?('INFOPLIST_KEY_AppStoreProductID=') }
              effective_build_flags << "INFOPLIST_KEY_AppStoreProductID=#{configured_product_id}"
            end
            build_cmd.concat(effective_build_flags)
            build_cmd.concat(Array(appstore_config['archive_extra_args']).map(&:to_s).reject(&:empty?))
            build_out, build_status = Open3.capture2e(*build_cmd)
            unless build_status.success?
              hint = summarized_output_tail(build_out)
              message = "App Store artifact audit build failed for configuration #{configuration}"
              message += ": #{hint}" unless hint.empty?
              artifact_report = { verified: false, issues: [message], warnings: [] }
              next
            end

            candidates = Dir.glob(File.join(derived_data, 'Build', 'Products', configuration, '*.app'))
            selection = appstore_select_submission_app(
              app_dirs: candidates,
              expected_bundle_ids: expected_bundle_ids,
              platform: 'macos'
            )
            artifact_report = if selection[:verified]
                                appstore_compiled_artifact_report(
                                  app_dir: selection[:app_dir], platform: 'macos',
                                  expected_bundle_id: expected_bundle_ids.first,
                                  review_notes_blob: review_notes_blob,
                                  configured_product_id: configured_product_id,
                                  uses_storekit_unlock: uses_storekit_unlock
                                )
                              else
                                { verified: false, issues: selection[:issues], warnings: [] }
                              end
          end
        else
          puts '⏭️  skipped (unbound non-macOS diagnostic)'
        end
      rescue StandardError => e
        artifact_report = {
          verified: false,
          issues: ["Compiled App Store artifact audit failed unexpectedly: #{e.message}"],
          warnings: []
        }
      end

      if artifact_report
        compiled_artifact_verified_clean = artifact_report[:verified] == true
        if compiled_artifact_verified_clean
          puts '✅'
        else
          puts "❌ #{artifact_report[:issues].first}"
          Array(artifact_report[:issues]).each { |msg| issues << msg }
        end
        Array(artifact_report[:warnings]).each { |msg| warnings << msg }
      end
      if compiled_artifact_verified_clean
        warnings.delete('Policy guard: Source contains clipboard automation for non-App-Store builds, but the App Store build script strips automation usage descriptions and review notes describe manual paste. Verify the compiled App Store artifact before blocking submission.')
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
        puts '❌ not specified'
        issues << 'No appstore.category in .saneprocess — Apple requires a primary App Store category before submission'
      end

      # 6c. Age rating
      print '    Age rating... '
      age_rating = appstore_config['age_rating']
      if age_rating
        puts "✅ #{age_rating}"
      else
        puts '❌ not specified'
        issues << 'No appstore.age_rating in .saneprocess — Apple requires an age rating before submission'
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
        puts '  ✅ DETERMINISTIC CHECKS CLEAR — retain live reviewer-flow, semantic, and portal read-back receipts'
      elsif issues.empty?
        puts '  🟡 REVIEW WARNINGS — then proceed with submission'
      else
        puts '  🔴 FIX ISSUES ABOVE before submitting'
      end
      puts '═' * 55

      write_appstore_preflight_status_snapshot(
        path: File.join(Dir.pwd, 'outputs', 'appstore_preflight_status.json'),
        status: issues.empty? ? 'passed' : 'failed',
        issues: issues,
        warnings: warnings,
        app_name: app_name,
        app_id: asc_app_id,
        version: version_str,
        build: build_num,
        platforms: platforms,
        submission_target: submission_target
      )

      record_process_metric(
        'appstore_preflight',
        success: issues.empty?,
        app: app_name,
        issues_count: issues.length,
        warnings_count: warnings.length
      ) if respond_to?(:record_process_metric)

      exit 1 if issues.any?
    end
  end
end
