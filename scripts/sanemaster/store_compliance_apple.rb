# frozen_string_literal: true

require 'tempfile'

module SaneMasterModules
  module StoreCompliance
    def fastlane_precheck_report(app_identifier:, platform:, include_iap:, credentials:)
      report = { issues: [], warnings: [], summary: 'not run', tool: 'fastlane precheck' }
      unless system('command', '-v', 'fastlane', out: File::NULL, err: File::NULL)
        report[:issues] << 'fastlane is unavailable; install it before App Store submission'
        return report
      end
      if app_identifier.to_s.empty? || credentials.values_at(:key_id, :issuer_id, :key_path).any? { |value| value.to_s.empty? }
        report[:warnings] << 'fastlane precheck skipped because bundle ID or ASC API credentials are incomplete'
        return report
      end

      key_path = File.realpath(credentials.fetch(:key_path))
      Tempfile.create(['fastlane-api-key', '.json']) do |file|
        file.chmod(0o600)
        file.write(JSON.generate(
                     key_id: credentials.fetch(:key_id),
                     issuer_id: credentials.fetch(:issuer_id),
                     key: File.read(key_path, encoding: Encoding::UTF_8),
                     in_house: false
                   ))
        file.flush
        command = [
          'fastlane', 'run', 'precheck',
          "api_key_path:#{file.path}",
          "app_identifier:#{app_identifier}",
          "platform:#{platform}",
          "include_in_app_purchases:#{include_iap}",
          'default_rule_level:error'
        ]
        result = capture_store_command(
          command,
          timeout_seconds: 300,
          environment: { 'FASTLANE_SKIP_UPDATE_CHECK' => '1', 'FASTLANE_HIDE_CHANGELOG' => '1' }
        )
        clean = sanitize_tool_output(result[:output], secret_paths: [file.path, key_path])
        if result[:timed_out]
          report[:issues] << 'fastlane precheck timed out after 300 seconds'
        elsif result[:exit_status].zero?
          report[:summary] = 'passed'
        else
          report[:issues] << "fastlane precheck failed: #{tool_output_tail(clean)}"
        end
      end
      report
    rescue Errno::ENOENT, Errno::EACCES, JSON::GeneratorError => e
      report[:issues] << "fastlane precheck could not run safely: #{e.message}"
      report
    end

    def appstore_package_validation_report(package_path:, platform:, credentials:)
      report = { issues: [], warnings: [], summary: 'not run', tool: 'Apple altool --validate-app' }
      return report if package_path.to_s.empty?

      missing = credentials.values_at(:key_id, :issuer_id).any? { |value| value.to_s.empty? }
      if missing
        report[:issues] << 'Apple package validation requires ASC key ID and issuer ID'
        return report
      end
      before_sha = Digest::SHA256.file(package_path).hexdigest
      command = [
        'xcrun', 'altool', '--validate-app', '-f', package_path,
        '-t', platform.to_s == 'macos' ? 'osx' : 'ios',
        '--apiKey', credentials.fetch(:key_id), '--apiIssuer', credentials.fetch(:issuer_id)
      ]
      result = capture_store_command(command, timeout_seconds: 900)
      clean = sanitize_tool_output(result[:output], secret_paths: [package_path])
      if result[:timed_out]
        report[:issues] << 'Apple altool validation timed out after 900 seconds'
      elsif result[:exit_status].zero?
        report[:summary] = 'passed'
      else
        report[:issues] << "Apple altool validation failed: #{tool_output_tail(clean)}"
      end
      after_sha = Digest::SHA256.file(package_path).hexdigest
      report[:issues] << 'App Store package changed during Apple validation' unless before_sha == after_sha
      report[:sha256] = before_sha
      report
    rescue Errno::ENOENT, Errno::EACCES => e
      report[:issues] << "Apple altool validation could not run: #{e.message}"
      report
    end
  end
end
