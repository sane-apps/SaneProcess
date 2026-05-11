# frozen_string_literal: true

require 'digest'
require 'date'
require 'json'
require 'open3'
require 'time'
require 'yaml'

module SaneMasterModules
  # Release-blocking customer-facing UI/UX action contract.
  module CustomerUIContract
    CUSTOMER_UI_MANIFEST_PATHS = [
      'Tests/CustomerUIActions.yml',
      'tests/customer_ui_actions.yml',
      'config/customer_ui_actions.yml',
      '.sane/customer_ui_actions.yml'
    ].freeze
    CUSTOMER_UI_RECEIPT_PATHS = [
      'outputs/customer_ui_action_receipt.json',
      '.sane/customer_ui_action_receipt.json'
    ].freeze
    CUSTOMER_UI_SOURCE_EXTENSIONS = %w[
      .swift .rb .sh .yml .yaml .json .plist .xcconfig .entitlements .xcstrings
    ].freeze

    def customer_ui_contract(args = [])
      report = customer_ui_contract_report(config: current_saneprocess_config)
      if args.include?('--json')
        puts JSON.pretty_generate(report)
      else
        puts format_customer_ui_contract_report(report)
      end
      exit 1 unless report[:ok] || args.include?('--no-exit')
      report
    end

    def customer_ui_contract_report(config:)
      app_name = metadata_value(config, 'name') || File.basename(Dir.pwd)
      manifest_path = CUSTOMER_UI_MANIFEST_PATHS.find { |path| File.exist?(path) }
      receipt_path = CUSTOMER_UI_RECEIPT_PATHS.find { |path| File.exist?(path) }
      issues = []
      warnings = []

      unless manifest_path
        return {
          ok: false,
          app: app_name,
          manifest_path: nil,
          receipt_path: receipt_path,
          issues: ["Missing customer UI action contract (expected one of: #{CUSTOMER_UI_MANIFEST_PATHS.join(', ')})"],
          warnings: warnings
        }
      end

      manifest = read_customer_ui_yaml(manifest_path)
      actions = Array(manifest['actions'])
      required_actions = actions.reject { |action| action['release_required'] == false }

      issues << 'Customer UI action contract has no release-required actions' if required_actions.empty?
      issues.concat(customer_ui_manifest_issues(manifest_path, manifest, required_actions))

      manifest_sha = Digest::SHA256.file(manifest_path).hexdigest
      source_fingerprint = customer_ui_source_fingerprint

      unless receipt_path
        issues << 'Missing fresh customer UI QA receipt (run the app-specific Mini click/screenshot sweep)'
        return {
          ok: false,
          app: app_name,
          manifest_path: manifest_path,
          receipt_path: nil,
          manifest_sha256: manifest_sha,
          source_fingerprint: source_fingerprint,
          action_count: required_actions.length,
          issues: issues,
          warnings: warnings
        }
      end

      receipt = read_customer_ui_json(receipt_path)
      issues.concat(customer_ui_receipt_issues(
        app_name: app_name,
        manifest_sha: manifest_sha,
        source_fingerprint: source_fingerprint,
        required_actions: required_actions,
        receipt: receipt
      ))

      {
        ok: issues.empty?,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        manifest_sha256: manifest_sha,
        source_fingerprint: source_fingerprint,
        action_count: required_actions.length,
        receipt_generated_at: receipt['generated_at'],
        issues: issues,
        warnings: warnings
      }
    rescue Psych::SyntaxError, JSON::ParserError => e
      {
        ok: false,
        app: app_name,
        manifest_path: manifest_path,
        receipt_path: receipt_path,
        issues: ["Customer UI QA contract parse failure: #{e.message}"],
        warnings: warnings
      }
    end

    def format_customer_ui_contract_report(report)
      lines = []
      lines << '🧭 --- [ CUSTOMER UI ACTION CONTRACT ] ---'
      lines << "App: #{report[:app]}"
      if report[:ok]
        lines << "✅ #{report[:action_count]} release-required action(s) covered"
        lines << "   Manifest: #{report[:manifest_path]}"
        lines << "   Receipt: #{report[:receipt_path]}"
        lines << "   Generated: #{report[:receipt_generated_at]}"
      else
        lines << '❌ FAIL'
        Array(report[:issues]).each { |issue| lines << "   - #{issue}" }
      end
      Array(report[:warnings]).each { |warning| lines << "⚠️  #{warning}" }
      lines.join("\n")
    end

    private

    def current_saneprocess_config
      path = File.join(Dir.pwd, '.saneprocess')
      return {} unless File.exist?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end

    def read_customer_ui_yaml(path)
      YAML.safe_load(File.read(path), permitted_classes: [Time, Date], aliases: false) || {}
    end

    def read_customer_ui_json(path)
      JSON.parse(File.read(path))
    end

    def customer_ui_manifest_issues(manifest_path, manifest, required_actions)
      issues = []
      issues << "Manifest app does not match .saneprocess name" if manifest['app'] && manifest['app'].to_s != (metadata_value(current_saneprocess_config, 'name') || File.basename(Dir.pwd)).to_s

      ids = []
      required_actions.each_with_index do |action, index|
        id = action['id'].to_s.strip
        ids << id
        prefix = id.empty? ? "action ##{index + 1}" : id
        issues << "#{prefix}: missing id" if id.empty?
        issues << "#{prefix}: missing title" if action['title'].to_s.strip.empty?
        issues << "#{prefix}: missing customer surface" if Array(action['surfaces']).empty?
        issues << "#{prefix}: missing click/interaction steps" if Array(action['steps']).empty?
        issues << "#{prefix}: missing assertions" if Array(action['assertions']).empty?
        issues << "#{prefix}: missing evidence requirement" if Array(action['evidence']).empty?
      end

      id_counts = Hash.new(0)
      ids.reject(&:empty?).each { |id| id_counts[id] += 1 }
      duplicate_ids = id_counts.select { |_id, count| count > 1 }.keys
      issues << "Duplicate customer UI action ids: #{duplicate_ids.join(', ')}" unless duplicate_ids.empty?
      issues << "#{manifest_path}: version must be 1" unless manifest['version'].to_i == 1
      issues
    end

    def customer_ui_receipt_issues(app_name:, manifest_sha:, source_fingerprint:, required_actions:, receipt:)
      issues = []
      issues << "Receipt app #{receipt['app']} does not match #{app_name}" if receipt['app'].to_s != app_name.to_s
      issues << "Receipt status is #{receipt['status'].inspect}, expected \"passed\"" unless receipt['status'].to_s == 'passed'
      issues << 'Receipt was not generated on the Mini' unless receipt['host'].to_s.downcase == 'mini'
      issues << 'Receipt manifest hash is stale' unless receipt['manifest_sha256'].to_s == manifest_sha
      issues << 'Receipt source fingerprint is stale; rerun customer UI QA after the latest code change' unless receipt['source_fingerprint'].to_s == source_fingerprint
      issues << 'Receipt is missing screenshot evidence' if Array(receipt['screenshots']).empty?

      tested_ids = Array(receipt['tested_action_ids']).map(&:to_s)
      required_ids = required_actions.map { |action| action['id'].to_s }.reject(&:empty?)
      missing_ids = required_ids - tested_ids
      issues << "Receipt does not cover release-required action(s): #{missing_ids.join(', ')}" unless missing_ids.empty?

      begin
        generated_at = Time.parse(receipt['generated_at'].to_s)
        issues << 'Receipt is older than 12 hours; rerun customer UI QA for this release' if Time.now - generated_at > 12 * 60 * 60
      rescue ArgumentError
        issues << 'Receipt generated_at is missing or invalid'
      end

      issues
    end

    def customer_ui_source_fingerprint
      digest = Digest::SHA256.new
      customer_ui_source_files.each do |path|
        next unless File.file?(path)

        digest.update(path)
        digest.update("\0")
        digest.update(Digest::SHA256.file(path).hexdigest)
        digest.update("\0")
      end
      digest.hexdigest
    end

    def customer_ui_source_files
      files = git_list_customer_ui_files
      files = filesystem_customer_ui_files if files.empty?
      files.select { |path| customer_ui_source_file?(path) }.uniq.sort
    end

    def git_list_customer_ui_files
      tracked, tracked_status = Open3.capture2e('git', 'ls-files', '-z')
      others, others_status = Open3.capture2e('git', 'ls-files', '--others', '--exclude-standard', '-z')
      files = []
      files.concat(tracked.split("\0")) if tracked_status.success?
      files.concat(others.split("\0")) if others_status.success?
      files
    rescue StandardError
      []
    end

    def filesystem_customer_ui_files
      Dir.glob('**/*', File::FNM_DOTMATCH).reject do |path|
        path.start_with?('.git/') || path.start_with?('outputs/') || File.directory?(path)
      end
    end

    def customer_ui_source_file?(path)
      return false if CUSTOMER_UI_RECEIPT_PATHS.include?(path)
      return false if path.start_with?('.sanemaster/')
      return true if CUSTOMER_UI_MANIFEST_PATHS.include?(path)
      return true if path == '.saneprocess' || path == 'project.yml' || path == 'Package.swift'
      return true if path.end_with?('.xcodeproj/project.pbxproj')
      return true if path.start_with?('Sane') || path.start_with?('Shared/')
      return true if path.start_with?('Sources/') || path.start_with?('Tests/')
      return true if path == 'scripts/qa.rb' || path == 'Scripts/qa.rb'
      return true if path.start_with?('scripts/customer_ui_qa') || path.start_with?('Scripts/customer_ui_qa')

      CUSTOMER_UI_SOURCE_EXTENSIONS.include?(File.extname(path)) &&
        !path.start_with?('docs/') &&
        !path.start_with?('website/') &&
        !path.start_with?('outputs/')
    end
  end
end
