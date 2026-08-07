# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'net/http'
require 'open3'
require 'optparse'
require 'tmpdir'
require 'uri'

module SaneMasterModules
  module StoreCompliance
    WEBSTORE_PREFLIGHT_PRODUCER = 'saneprocess.webstore_preflight.v1'
    STORE_POLICY_REVIEWED_ON = Date.new(2026, 8, 2)
    STORE_POLICY_MAX_AGE_DAYS = 30
    ADDONS_LINTER_VERSION = '10.9.0'
    FIREFOX_ONLY_LINTER_CODES = %w[
      ADDON_ID_REQUIRED
      MISSING_DATA_COLLECTION_PERMISSIONS
      RUNTIME_ONMESSAGEEXTERNAL
    ].freeze
    STORE_POLICY_SOURCES = {
      apple: [
        'https://developer.apple.com/app-store/review/guidelines/',
        'https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api',
        'https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/'
      ],
      chrome: [
        'https://developer.chrome.com/docs/webstore/program-policies/policies',
        'https://developer.chrome.com/docs/webstore/images',
        'https://developer.chrome.com/docs/webstore/program-policies/limited-use',
        'https://developer.chrome.com/docs/webstore/api/reference/rest'
      ]
    }.freeze

    def store_policy_freshness_report(store, today: Date.today)
      sources = STORE_POLICY_SOURCES.fetch(store.to_sym)
      age = (today - STORE_POLICY_REVIEWED_ON).to_i
      issues = []
      if age.negative?
        issues << "#{store} policy review date is in the future"
      elsif age > STORE_POLICY_MAX_AGE_DAYS
        issues << "#{store} policy mapping is #{age} days old; review official sources before release"
      end
      {
        issues: issues,
        warnings: [],
        reviewed_on: STORE_POLICY_REVIEWED_ON.iso8601,
        age_days: age,
        sources: sources
      }
    end

    def webstore_preflight(args)
      options = parse_webstore_preflight_options(args)
      root = File.realpath(Dir.pwd)
      issues = []
      warnings = []
      policy = store_policy_freshness_report(:chrome)
      issues.concat(policy[:issues])
      warnings.concat(policy[:warnings])

      package_path = compliance_input_file(options.fetch(:package), root: root, label: 'package', issues: issues)
      listing_path = compliance_input_file(options.fetch(:listing), root: root, label: 'listing', issues: issues)
      review_path = options[:review_instructions] && compliance_input_file(
        options[:review_instructions], root: root, label: 'review instructions', issues: issues
      )
      media_dir = compliance_input_directory(options.fetch(:media_dir), root: root, label: 'media directory', issues: issues)

      report = {
        package: nil,
        listing: listing_path && file_fingerprint(listing_path, root: root),
        media: [],
        privacy: nil,
        reviewerAccess: review_path && private_review_instructions_report(review_path, root: root, issues: issues),
        externalLinter: nil,
        policy: policy
      }

      listing_text = listing_path ? File.read(listing_path, encoding: Encoding::UTF_8) : ''
      audit_webstore_listing(listing_text, issues: issues, warnings: warnings)
      if listing_text.match?(/invite code|sign.?in|login|credential/i) && review_path.nil?
        issues << 'Gated extension listing requires protected reviewer instructions'
      end

      if package_path
        before_sha = Digest::SHA256.file(package_path).hexdigest
        Dir.mktmpdir('saneprocess-webstore-preflight') do |tmpdir|
          package_report = inspect_webstore_package(package_path, tmpdir: tmpdir, issues: issues, warnings: warnings)
          report[:package] = package_report.merge(
            sha256: before_sha,
            size: File.size(package_path),
            fileName: File.basename(package_path)
          )
          report[:externalLinter] = run_addons_linter(package_path, issues: issues, warnings: warnings)
        end
        after_sha = Digest::SHA256.file(package_path).hexdigest
        issues << 'Web Store package changed while preflight was running' unless before_sha == after_sha
      end

      report[:media] = inspect_webstore_media(media_dir, root: root, issues: issues, warnings: warnings) if media_dir
      report[:privacy] = inspect_webstore_privacy(options.fetch(:privacy_url), issues: issues)
      write_webstore_preflight_candidate(
        root: root,
        options: options,
        report: report,
        issues: issues.uniq,
        warnings: warnings.uniq
      )

      print_webstore_preflight_result(issues.uniq, warnings.uniq, report)
      exit 1 unless issues.empty?
      true
    rescue OptionParser::ParseError, KeyError, ArgumentError => e
      warn "❌ Web Store preflight configuration error: #{e.message}"
      exit 2
    end

    private

    def parse_webstore_preflight_options(args)
      options = {}
      OptionParser.new do |parser|
        parser.on('--package PATH') { |value| options[:package] = value }
        parser.on('--listing PATH') { |value| options[:listing] = value }
        parser.on('--media-dir PATH') { |value| options[:media_dir] = value }
        parser.on('--privacy-url URL') { |value| options[:privacy_url] = value }
        parser.on('--review-instructions PATH') { |value| options[:review_instructions] = value }
      end.parse!(Array(args).dup)
      %i[package listing media_dir privacy_url].each do |key|
        raise OptionParser::MissingArgument, "--#{key.to_s.tr('_', '-')}" if options[key].to_s.empty?
      end
      uri = URI.parse(options[:privacy_url])
      raise ArgumentError, 'privacy URL must use HTTPS' unless uri.is_a?(URI::HTTPS) && uri.host
      options
    end

    def compliance_input_file(path, root:, label:, issues:)
      resolved = File.realpath(File.expand_path(path, root))
      metadata = File.lstat(resolved)
      raise ArgumentError unless metadata.file? && !metadata.symlink? && path_beneath?(resolved, root)
      resolved
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      issues << "#{label.capitalize} must be a readable regular non-symlink file inside the project: #{path}"
      nil
    end

    def compliance_input_directory(path, root:, label:, issues:)
      resolved = File.realpath(File.expand_path(path, root))
      metadata = File.lstat(resolved)
      raise ArgumentError unless metadata.directory? && !metadata.symlink? && path_beneath?(resolved, root)
      resolved
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      issues << "#{label.capitalize} must be a readable non-symlink directory inside the project: #{path}"
      nil
    end

    def path_beneath?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def inspect_webstore_package(package_path, tmpdir:, issues:, warnings:)
      entries_out, entries_status = Open3.capture2e('unzip', '-Z1', package_path)
      unless entries_status.success?
        issues << 'Web Store package is not a readable ZIP archive'
        return {}
      end
      entries = entries_out.lines.map(&:strip).reject(&:empty?)
      unsafe = entries.select { |entry| entry.start_with?('/') || entry.split('/').include?('..') }
      issues << "Web Store package contains unsafe paths: #{unsafe.first(3).join(', ')}" unless unsafe.empty?
      issues << 'Web Store package must contain exactly one manifest.json at ZIP root' unless entries.count('manifest.json') == 1
      extracted = system('unzip', '-qq', '-o', package_path, '-d', tmpdir, out: File::NULL, err: File::NULL)
      unless extracted
        issues << 'Web Store package could not be extracted for inspection'
        return {}
      end
      symlinks = Dir.glob(File.join(tmpdir, '**', '*'), File::FNM_DOTMATCH).select { |path| File.symlink?(path) }
      issues << 'Web Store package contains symlinks' unless symlinks.empty?
      manifest_path = File.join(tmpdir, 'manifest.json')
      manifest = JSON.parse(File.read(manifest_path, encoding: Encoding::UTF_8))
      audit_webstore_manifest(manifest, tmpdir: tmpdir, issues: issues, warnings: warnings)
      audit_webstore_code(manifest, tmpdir: tmpdir, issues: issues, warnings: warnings)
      { manifestVersion: manifest['manifest_version'], version: manifest['version'], entryCount: entries.length }
    rescue JSON::ParserError => e
      issues << "manifest.json is invalid JSON: #{e.message}"
      {}
    end

    def audit_webstore_manifest(manifest, tmpdir:, issues:, warnings:)
      issues << 'Chrome Web Store package must use Manifest V3' unless manifest['manifest_version'] == 3
      %w[name description version].each do |key|
        issues << "manifest.json is missing #{key}" if manifest[key].to_s.strip.empty?
      end
      permissions = Array(manifest['permissions']).map(&:to_s)
      if permissions.include?('tabs') && permissions.include?('activeTab')
        issues << 'manifest requests both tabs and activeTab; remove redundant/excessive access or prove the exact sensitive tab fields required'
      end
      host_permissions = Array(manifest['host_permissions']).map(&:to_s)
      issues << 'manifest requests <all_urls>; use the narrowest supported hosts' if host_permissions.include?('<all_urls>')
      csp = manifest.dig('content_security_policy', 'extension_pages').to_s
      issues << 'Extension CSP allows unsafe-eval' if csp.include?("'unsafe-eval'")
      issues << 'External message listener requires explicit externally_connectable matches' if
        Dir.glob(File.join(tmpdir, '**', '*.{js,mjs}')).any? { |path| File.read(path).include?('onMessageExternal') } &&
        !manifest['externally_connectable'].is_a?(Hash)
      manifest_referenced_paths(manifest).each do |relative|
        issues << "manifest references missing package file: #{relative}" unless File.file?(File.join(tmpdir, relative))
      end
      warnings << 'No host_permissions declared; confirm the extension truly needs no site or API access' if host_permissions.empty?
    end

    def manifest_referenced_paths(manifest)
      paths = []
      paths.concat(Array(manifest.dig('icons')&.values))
      paths.concat(Array(manifest.dig('action', 'default_icon')&.values))
      paths << manifest.dig('action', 'default_popup')
      paths << manifest.dig('background', 'service_worker')
      Array(manifest['content_scripts']).each do |entry|
        paths.concat(Array(entry['js']))
        paths.concat(Array(entry['css']))
      end
      paths.compact.map(&:to_s).reject(&:empty?).uniq
    end

    def audit_webstore_code(manifest, tmpdir:, issues:, warnings:)
      files = Dir.glob(File.join(tmpdir, '**', '*')).select { |path| File.file?(path) && path.match?(/\.(?:js|mjs|html)$/i) }
      source = files.map { |path| File.read(path, encoding: Encoding::UTF_8) }.join("\n")
      remote_patterns = {
        'remote script source' => /<script[^>]+src\s*=\s*["']https?:/i,
        'remote dynamic import' => /\b(?:import|importScripts)\s*\(\s*["']https?:/i,
        'eval' => /\beval\s*\(/,
        'Function constructor' => /\bnew\s+Function\s*\(/,
        'fetched WebAssembly execution' => /WebAssembly\.(?:instantiateStreaming|compileStreaming)\s*\(\s*fetch\s*\(/
      }
      remote_patterns.each { |label, pattern| issues << "Package contains forbidden #{label}" if source.match?(pattern) }

      allowed_hosts = Array(manifest['host_permissions'])
      source.scan(%r{https://[A-Za-z0-9.-]+(?::\d+)?[^\s"'`)]*}).uniq.each do |url|
        uri = URI.parse(url)
        next if uri.host.nil? || host_covered_by_patterns?(uri.host, allowed_hosts)
        context_is_api = uri.host.start_with?('api.') || uri.path.match?(%r{/(?:api|services?)/}i)
        message = "Code references undeclared external host #{uri.host}; remove dead code or declare and disclose the live endpoint"
        context_is_api ? issues << message : warnings << message
      rescue URI::InvalidURIError
        next
      end
    end

    def host_covered_by_patterns?(host, patterns)
      Array(patterns).any? do |pattern|
        pattern_host = URI.parse(pattern.sub('*://', 'https://')).host rescue nil
        next false unless pattern_host
        pattern_host.start_with?('*.') ? (host == pattern_host[2..] || host.end_with?(pattern_host[1..])) : host == pattern_host
      end
    end

    def audit_webstore_listing(text, issues:, warnings:)
      public_copy = text[/^## Listing copy\s*$\n(.*?)(?=^##\s)/m, 1] || text
      issues << 'Listing file lacks a Name field' unless public_copy.match?(/^\*\*Name:\*\*/)
      issues << 'Listing file lacks a Summary field' unless public_copy.match?(/^\*\*Summary[^:]*:\*\*/)
      issues << 'Listing file lacks a Description field' unless public_copy.match?(/^\*\*Description:\*\*/)
      {
        'ranking claim' => /(?:#\s*\d+|number\s*one|top[- ]rated|best\s+extension)/i,
        'synthetic store metric' => /\b(?:\d{2,}|\d[\d,.]*[+,])\s*(?:users?|installs?|ratings?|reviews?)\b/i,
        'store endorsement/status claim' => /editor'?s choice|featured by chrome|chrome recommended/i,
        'placeholder copy' => /lorem ipsum|coming soon|text here|todo\b/i
      }.each { |label, pattern| issues << "Public listing contains #{label}" if public_copy.match?(pattern) }
      warnings << 'Listing does not record screenshot provenance as current real extension UI' unless
        text.match?(/captured from (?:the )?real extension UI/i)
    end

    def inspect_webstore_media(media_dir, root:, issues:, warnings:)
      images = Dir.glob(File.join(media_dir, '*.{png,jpg,jpeg}'), File::FNM_CASEFOLD).sort
      screenshots = images.select { |path| File.basename(path).match?(/screenshot/i) }
      issues << 'Chrome Web Store listing needs at least one screenshot' if screenshots.empty?
      issues << 'Chrome Web Store listing supports at most five screenshots' if screenshots.length > 5
      images.map do |path|
        width, height = store_image_dimensions(path)
        basename = File.basename(path)
        if basename.match?(/screenshot/i) && ![[1280, 800], [640, 400]].include?([width, height])
          issues << "Screenshot #{basename} must be 1280x800 or 640x400, got #{width}x#{height}"
        elsif basename.match?(/promo.*small|small.*promo/i) && [width, height] != [440, 280]
          issues << "Small promo image #{basename} must be 440x280, got #{width}x#{height}"
        elsif basename.match?(/icon-?128/i) && [width, height] != [128, 128]
          issues << "Store icon #{basename} must be 128x128, got #{width}x#{height}"
        end
        ocr = basename.match?(/screenshot|promo/i) ? store_image_ocr(path, issues: issues) : ''
        issues << "Media #{basename} contains a ranking claim" if ocr.match?(/(?:#\s*\d+|number\s*one|top[- ]rated)/i)
        issues << "Media #{basename} contains synthetic store metrics" if ocr.match?(/\b(?:\d{2,}|\d[\d,.]*[+,])\s*(?:users?|installs?|ratings?|reviews?)\b/i)
        warnings << "Media #{basename} contains Premium; attest that it is real in-product UI, not a store-status badge" if ocr.match?(/\bpremium\b/i)
        file_fingerprint(path, root: root).merge(width: width, height: height, ocrSha256: Digest::SHA256.hexdigest(ocr))
      end
    end

    def store_image_dimensions(path)
      output, status = Open3.capture2e('sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path)
      return [0, 0] unless status.success?
      [output[/pixelWidth:\s*(\d+)/, 1].to_i, output[/pixelHeight:\s*(\d+)/, 1].to_i]
    end

    def store_image_ocr(path, issues:)
      helper = File.expand_path('../webstore_media_ocr.swift', __dir__)
      result = capture_store_command(['xcrun', 'swift', helper, path], timeout_seconds: 120)
      if result[:timed_out] || !result[:exit_status].zero?
        issues << "Could not OCR listing media #{File.basename(path)}"
        return ''
      end
      result[:output].to_s
    end

    def inspect_webstore_privacy(url, issues:)
      body, final_url = fetch_https(url)
      limited_use = body.match?(/Chrome Web Store User Data Policy/i) && body.match?(/Limited Use/i)
      unless limited_use
        issues << 'Privacy policy lacks the affirmative Chrome Web Store User Data Policy / Limited Use statement'
      end
      { url: final_url, sha256: Digest::SHA256.hexdigest(body), limitedUse: limited_use }
    rescue StandardError => e
      issues << "Privacy policy could not be verified live: #{e.message}"
      { url: url, limitedUse: false }
    end

    def fetch_https(url, redirects: 3)
      raise 'too many redirects' if redirects.negative?
      uri = URI.parse(url)
      raise 'URL must use HTTPS' unless uri.is_a?(URI::HTTPS)
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'SaneProcess-StoreCompliance/1.0'
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end
      return fetch_https(URI.join(uri, response['location']).to_s, redirects: redirects - 1) if response.is_a?(Net::HTTPRedirection)
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      [response.body.to_s, uri.to_s]
    end

    def private_review_instructions_report(path, root:, issues:)
      metadata = File.stat(path)
      issues << 'Reviewer instructions must be mode 600' unless (metadata.mode & 0o077).zero?
      data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
      issues << 'Reviewer instructions indicate the invite is unavailable' unless data['ok'] == true
      raw_expiry = data['expiresAt'].to_s
      expires_at = if raw_expiry.match?(/\A\d{13}\z/)
                     Time.at(raw_expiry.to_i / 1000.0)
                   else
                     Time.parse(raw_expiry)
                   end
      issues << 'Reviewer invite expires in less than seven days' if expires_at < Time.now + (7 * 86_400)
      file_fingerprint(path, root: root).merge(expiresAt: expires_at.utc.iso8601)
    rescue JSON::ParserError, ArgumentError => e
      issues << "Reviewer instructions are invalid: #{e.message}"
      nil
    end

    def run_addons_linter(package_path, issues:, warnings:)
      command = [
        'npx', '--yes', "addons-linter@#{ADDONS_LINTER_VERSION}", '--output', 'json',
        '--enable-background-service-worker', package_path
      ]
      result = capture_store_command(command, timeout_seconds: 180)
      if result[:timed_out]
        issues << 'addons-linter timed out'
        return { version: ADDONS_LINTER_VERSION, status: 'timeout' }
      end
      json_payload = result[:output].to_s[/\{.*\}\s*\z/m]
      raise JSON::ParserError, 'no JSON object found in linter output' unless json_payload
      data = JSON.parse(json_payload)
      Array(data['errors']).each do |entry|
        next if FIREFOX_ONLY_LINTER_CODES.include?(entry['code'].to_s)
        issues << "addons-linter #{entry['code']}: #{entry['message']}"
      end
      Array(data['warnings']).each do |entry|
        next if FIREFOX_ONLY_LINTER_CODES.include?(entry['code'].to_s)
        warnings << "addons-linter #{entry['code']}: #{entry['message']} (#{entry['file']}:#{entry['line']})"
      end
      { version: ADDONS_LINTER_VERSION, summary: data['summary'], status: 'completed' }
    rescue JSON::ParserError, Errno::ENOENT => e
      issues << "addons-linter did not return usable JSON: #{e.message}"
      { version: ADDONS_LINTER_VERSION, status: 'failed' }
    end

    def capture_store_command(command, timeout_seconds:, environment: {})
      output = ''
      exit_status = 1
      timed_out = false
      Open3.popen2e(environment, *command, pgroup: true) do |stdin, stream, wait_thread|
        stdin.close
        reader = Thread.new { stream.read }
        if wait_thread.join(timeout_seconds)
          output = reader.value
          exit_status = wait_thread.value.exitstatus || 1
        else
          timed_out = true
          Process.kill('TERM', -wait_thread.pid) rescue nil
          wait_thread.join(2)
          Process.kill('KILL', -wait_thread.pid) rescue nil if wait_thread.alive?
          reader.join(2)
          output = reader.value if reader.status == false
        end
      end
      { output: output.to_s, exit_status: exit_status, timed_out: timed_out }
    end

    def sanitize_tool_output(output, secret_paths: [])
      clean = output.to_s.gsub(/\e\[[\d;]*m/, '')
      Array(secret_paths).each { |path| clean = clean.gsub(path.to_s, '[redacted-path]') }
      clean
    end

    def tool_output_tail(output)
      output.lines.map(&:strip).reject(&:empty?).last(6).join(' | ')[0, 900]
    end

    def file_fingerprint(path, root:)
      { path: path.delete_prefix("#{root}/"), sha256: Digest::SHA256.file(path).hexdigest, size: File.size(path) }
    end

    def write_webstore_preflight_candidate(root:, options:, report:, issues:, warnings:)
      payload = {
        type: 'webstore_preflight_status',
        generatedAt: Time.now.utc.iso8601,
        status: issues.empty? ? 'passed' : 'failed',
        issueCount: issues.length,
        warningCount: warnings.length,
        issues: issues,
        warnings: warnings,
        inputs: options.reject { |key, _value| key == :review_instructions },
        report: report
      }
      destination = File.join(root, 'outputs', 'webstore_preflight_status.json')
      ReleaseReceiptSigner.write_canonical_candidate!(destination, payload, producer: WEBSTORE_PREFLIGHT_PRODUCER)
    end

    def print_webstore_preflight_result(issues, warnings, report)
      puts '🧩 --- [ CHROME WEB STORE PREFLIGHT ] ---'
      puts "Package: #{report.dig(:package, :fileName) || 'unavailable'}"
      puts "Policy mapping reviewed: #{report.dig(:policy, :reviewed_on)}"
      issues.each { |issue| puts "  ❌ #{issue}" }
      warnings.each { |warning| puts "  ⚠️  #{warning}" }
      puts(issues.empty? ? '  ✅ Deterministic checks passed; retain the signed receipt with portal read-back.' : "  🔴 Blocked by #{issues.length} issue(s).")
    end
  end
end

require_relative 'store_compliance_apple'
