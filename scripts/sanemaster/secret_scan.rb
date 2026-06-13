# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'shellwords'
require 'time'
require 'fileutils'

module SaneMasterModules
  # Secret scanning wrapper for host/repo hygiene.
  #
  # Automic Vault is the preferred engine, but SaneProcess owns the policy:
  # receipts are redacted, active auth stores are classified separately, and
  # plaintext shell/env/config/log leaks fail the command.
  module SecretScan
    EXPECTED_AUTOMIC_VAULT_VERSION = '1.18.2'
    RECEIPT_SCHEMA_VERSION = 1

    GENERATED_SKIP_NAMES = %w[
      .Trash
      .build
      .git
      .swiftpm
      .venv
      .venv-local
      Applications
      DerivedData
      Library
      Movies
      Music
      Pictures
      build
      node_modules
      releases
      vendor
      xcuserdata
    ].freeze

    ACTIVE_ACCESS_ALLOWLIST = [
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.ssh/[^/]+\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.private_keys/[^/]+\.p8\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.sanevideo-signing/keys/[^/]+\.key\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.local/share/containers/podman/machine/machine\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.codex/auth\.json\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.codex/secrets/[^/]+\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.gemini/oauth_creds\.json\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.factory/auth\.json\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.grok/user-settings\.json\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.hivello/myst/config-mainnet\.toml\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.config/cktool\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.config/gh/hosts\.yml\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.config/nv/env\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.config/saneprocess/secrets\.env\z},
      %r{\A#{Regexp.escape(File.expand_path('~'))}/\.peekaboo/credentials\z}
    ].freeze

    THIRD_PARTY_FALSE_POSITIVE_ALLOWLIST = [
      %r{/(?:\.venv(?:-[^/]+)?|site-packages|node_modules|\.build|DerivedData|vendor/bundle)/},
      %r{/\.nvm/},
      %r{/(?:transformers|sklearn|numba|PyJWT|pyjwt)-[^/]*/},
      %r{/\.claude/plugins/marketplaces/[^/]+/src/supervisor/env-sanitizer\.ts\z},
      %r{/\.grok/marketplace-cache/[^/]+/src/supervisor/env-sanitizer\.ts\z},
      %r{/skills/critic/prompts/security-auditor\.md\z},
      %r{/SaneClip/Tests/SaneClipTests\.swift\z},
      %r{/SaneClip-clean/Tests/SaneClipTests\.swift\z}
    ].freeze

    def secret_scan(args)
      options = parse_secret_scan_args(args)
      result = run_secret_scan(options)
      print_secret_scan_result(result, json: options[:json])
      exit(result[:exit_status])
    end

    def run_secret_scan(options)
      root = File.expand_path(options.fetch(:path))
      receipt_path = options[:receipt] || default_secret_scan_receipt_path(root, options[:output_dir])
      scanner = resolve_secret_scanner(options[:scanner])

      unless scanner
        receipt = missing_secret_scanner_receipt(root, receipt_path)
        write_secret_scan_receipt(receipt_path, receipt)
        return receipt.merge(exit_status: 2)
      end

      command = build_secret_scan_command(scanner[:path], root, options[:skip_paths])
      stdout, stderr, status = Open3.capture3(*command)
      findings = status.success? ? parse_secret_scan_findings(stdout) : []
      classified = classify_secret_findings(findings, strict: options[:strict])
      receipt = {
        schema_version: RECEIPT_SCHEMA_VERSION,
        generated_at: Time.now.utc.iso8601,
        status: classified[:actionable].empty? && status.success? ? 'pass' : 'fail',
        root_path: root,
        receipt_path: receipt_path,
        scanner: scanner.merge(expected_version: EXPECTED_AUTOMIC_VAULT_VERSION),
        command: redacted_secret_scan_command(command),
        skipped_paths: command.each_cons(2).select { |a, _b| a == '--skip' }.map(&:last),
        findings_total: findings.length,
        actionable_count: classified[:actionable].length,
        preserved_count: classified[:preserved].length,
        ignored_count: classified[:ignored].length,
        by_severity: findings.each_with_object(Hash.new(0)) do |finding, counts|
          counts[safe_finding_severity(finding)] += 1
        end.sort.to_h,
        actionable_findings: classified[:actionable],
        preserved_findings: classified[:preserved],
        ignored_findings: classified[:ignored],
        scanner_error: status.success? ? nil : stderr.to_s.lines.first(5).join.strip
      }

      write_secret_scan_receipt(receipt_path, receipt)
      exit_status = if !status.success?
                      status.exitstatus || 1
                    elsif classified[:actionable].empty?
                      0
                    else
                      1
                    end
      receipt.merge(exit_status: exit_status)
    end

    def latest_secret_scan_receipt(output_root = File.join(saneprocess_repo_root, 'outputs', 'secret-scan'))
      Dir.glob(File.join(output_root, '*.json')).max_by { |path| File.mtime(path) }
    end

    private

    def parse_secret_scan_args(args)
      options = {
        path: Dir.pwd,
        output_dir: nil,
        receipt: nil,
        scanner: ENV['SANEMASTER_AUTOMIC_VAULT_CLI'],
        skip_paths: [],
        json: false,
        strict: false
      }

      OptionParser.new do |opts|
        opts.banner = 'Usage: SaneMaster.rb secret_scan [--path PATH] [--scanner PATH] [--json] [--strict]'
        opts.on('--path PATH', 'Root to scan (default: current directory)') { |value| options[:path] = value }
        opts.on('--scanner PATH', 'Automic Vault CLI path, or set SANEMASTER_AUTOMIC_VAULT_CLI') { |value| options[:scanner] = value }
        opts.on('--output-dir PATH', 'Receipt directory (default: <path>/outputs/secret-scan)') { |value| options[:output_dir] = value }
        opts.on('--receipt PATH', 'Exact receipt JSON path') { |value| options[:receipt] = value }
        opts.on('--skip PATH', 'Additional path to pass through to the scanner skip list') { |value| options[:skip_paths] << value }
        opts.on('--strict', 'Fail on preserved active-access findings too') { options[:strict] = true }
        opts.on('--json', 'Print compact JSON summary') { options[:json] = true }
      end.parse!(args)

      options
    end

    def resolve_secret_scanner(explicit_path = nil)
      unless explicit_path.to_s.strip.empty?
        scanner_path = File.expand_path(explicit_path)
        return nil unless File.executable?(scanner_path)

        return { name: 'automic-vault', path: scanner_path, version: secret_scanner_version(scanner_path) }
      end

      candidates = []
      candidates << File.expand_path("~/.sanemaster/tools/automic-vault/#{EXPECTED_AUTOMIC_VAULT_VERSION}/av")
      path_candidate = `command -v av 2>/dev/null`.strip
      candidates << path_candidate unless path_candidate.empty?
      candidates << '/Applications/Automic Vault.app/Contents/Resources/av'
      candidates << '/Volumes/Automic Vault/Automic Vault.app/Contents/Resources/av'

      scanner_path = candidates.compact.map { |path| File.expand_path(path) }.find { |path| File.executable?(path) }
      return nil unless scanner_path

      version = secret_scanner_version(scanner_path)
      { name: 'automic-vault', path: scanner_path, version: version }
    end

    def secret_scanner_version(scanner_path)
      stdout, _stderr, status = Open3.capture3(scanner_path, '--version')
      return stdout.strip.lines.first.to_s.strip if status.success? && !stdout.strip.empty?

      'unknown'
    rescue StandardError
      'unknown'
    end

    def build_secret_scan_command(scanner_path, root, extra_skip_paths)
      command = [scanner_path, 'scan', '--path', root]
      secret_scan_skip_paths(root, extra_skip_paths).each do |skip_path|
        command.concat(['--skip', skip_path])
      end
      command << '--json'
      command
    end

    def secret_scan_skip_paths(root, extra_skip_paths)
      explicit = Array(extra_skip_paths).map { |path| File.expand_path(path) }
      generated = GENERATED_SKIP_NAMES.map { |name| File.join(root, name) }
      generated.concat(Dir.glob(File.join(root, '*', '{.git,.build,DerivedData,node_modules,.venv,.venv-local}')))
      (generated + explicit).uniq.select { |path| File.exist?(path) }
    end

    def parse_secret_scan_findings(stdout)
      data = JSON.parse(stdout.to_s)
      findings = if data.is_a?(Hash)
                   data['findings'] || data['results'] || data['secrets'] || []
                 elsif data.is_a?(Array)
                   data
                 else
                   []
                 end
      findings.is_a?(Array) ? findings : []
    rescue JSON::ParserError
      []
    end

    def classify_secret_findings(findings, strict: false)
      findings.each_with_object({ actionable: [], preserved: [], ignored: [] }) do |finding, groups|
        safe = safe_secret_finding(finding)
        if !strict && active_access_finding?(safe)
          groups[:preserved] << safe.merge(classification: 'preserved_active_access')
        elsif !strict && third_party_false_positive_finding?(safe)
          groups[:ignored] << safe.merge(classification: 'ignored_third_party_or_generated')
        else
          groups[:actionable] << safe.merge(classification: 'actionable_plaintext_secret')
        end
      end
    end

    def safe_secret_finding(finding)
      {
        severity: safe_finding_severity(finding),
        kind: safe_finding_value(finding, 'kind', 'type', 'rule', 'rule_id'),
        path: safe_finding_path(finding),
        message: safe_finding_value(finding, 'message', 'description', 'title'),
        source: safe_finding_value(finding, 'source')
      }.compact
    end

    def safe_finding_severity(finding)
      safe_finding_value(finding, 'severity', 'Severity', 'level') || 'unknown'
    end

    def safe_finding_value(finding, *keys)
      return nil unless finding.is_a?(Hash)

      keys.each do |key|
        value = finding[key]
        return value.to_s if value && !value.to_s.empty?
      end
      nil
    end

    def safe_finding_path(finding)
      return '' unless finding.is_a?(Hash)

      value = finding['path'] || finding['file'] || finding['filename'] || finding['File']
      value = value['path'] || value['file'] if value.is_a?(Hash)
      value = finding.dig('location', 'path') if value.to_s.empty? && finding['location'].is_a?(Hash)
      File.expand_path(value.to_s)
    end

    def active_access_finding?(finding)
      path = finding[:path].to_s
      ACTIVE_ACCESS_ALLOWLIST.any? { |pattern| path.match?(pattern) }
    end

    def third_party_false_positive_finding?(finding)
      path = finding[:path].to_s
      THIRD_PARTY_FALSE_POSITIVE_ALLOWLIST.any? { |pattern| path.match?(pattern) }
    end

    def default_secret_scan_receipt_path(root, output_dir)
      dir = output_dir || File.join(root, 'outputs', 'secret-scan')
      timestamp = Time.now.utc.strftime('%Y%m%d-%H%M%S')
      File.join(File.expand_path(dir), "#{timestamp}-secret-scan.json")
    end

    def missing_secret_scanner_receipt(root, receipt_path)
      {
        schema_version: RECEIPT_SCHEMA_VERSION,
        generated_at: Time.now.utc.iso8601,
        status: 'scanner_missing',
        root_path: root,
        scanner: {
          name: 'automic-vault',
          expected_version: EXPECTED_AUTOMIC_VAULT_VERSION,
          install: 'Install Automic Vault from https://github.com/automic-vault/automic-vault/releases or set SANEMASTER_AUTOMIC_VAULT_CLI to the av binary.'
        },
        findings_total: 0,
        actionable_count: 0,
        preserved_count: 0,
        ignored_count: 0,
        actionable_findings: [],
        preserved_findings: [],
        ignored_findings: [],
        receipt_path: receipt_path
      }
    end

    def write_secret_scan_receipt(path, receipt)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(receipt))
      File.chmod(0o600, path)
    end

    def redacted_secret_scan_command(command)
      command.map { |part| part.to_s.include?(Dir.home) ? part.to_s.sub(Dir.home, '~') : part.to_s }
    end

    def print_secret_scan_result(result, json: false)
      if json
        puts JSON.generate(
          status: result[:status],
          findings_total: result[:findings_total],
          actionable_count: result[:actionable_count],
          preserved_count: result[:preserved_count],
          ignored_count: result[:ignored_count],
          receipt_path: result[:receipt_path] || result[:receipt]
        )
        return
      end

      puts '🔐 --- [ SECRET SCAN ] ---'
      puts "Status: #{result[:status]}"
      puts "Findings: #{result[:findings_total]} total, #{result[:actionable_count]} actionable, #{result[:preserved_count]} preserved, #{result[:ignored_count]} ignored"
      puts "Receipt: #{result[:receipt_path] || result[:receipt]}"
      return unless result[:status] == 'scanner_missing'

      puts 'Automic Vault CLI not found.'
      puts result.dig(:scanner, :install)
    end
  end
end
