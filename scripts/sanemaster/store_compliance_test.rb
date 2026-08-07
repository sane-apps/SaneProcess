#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative 'store_compliance'

include TestFramework

class StoreComplianceHarness
  include SaneMasterModules::StoreCompliance
end

def write_extension_zip(root, manifest:, files: {})
  source = File.join(root, 'source')
  FileUtils.mkdir_p(source)
  File.write(File.join(source, 'manifest.json'), JSON.pretty_generate(manifest))
  files.each do |relative, contents|
    path = File.join(source, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
  zip = File.join(root, 'candidate.zip')
  raise 'zip fixture failed' unless system('zip', '-qr', zip, '.', chdir: source)

  zip
end

exit(run_tests('Store Compliance Tests') do
  test_category('policy freshness') do
    test('fresh policy mapping passes and stale mapping blocks') do
      subject = StoreComplianceHarness.new
      fresh = subject.send(:store_policy_freshness_report, :chrome, today: Date.new(2026, 8, 20))
      stale = subject.send(:store_policy_freshness_report, :chrome, today: Date.new(2026, 9, 5))

      assert_eq(fresh[:issues], [])
      assert_includes(stale[:issues].join('\n'), '34 days old')
      assert(stale[:sources].all? { |url| url.start_with?('https://developer.chrome.com/') })
      true
    end
  end

  test_category('Chrome package checks') do
    test('package scan catches redundant permissions, undeclared API host, and unusable external messaging') do
      Dir.mktmpdir('webstore-risky-') do |dir|
        manifest = {
          'manifest_version' => 3,
          'name' => 'Example',
          'description' => 'Example extension',
          'version' => '1.0.0',
          'permissions' => %w[tabs activeTab],
          'host_permissions' => ['https://auction.example.com/*'],
          'background' => { 'service_worker' => 'background.js' }
        }
        zip = write_extension_zip(
          dir,
          manifest: manifest,
          files: {
            'background.js' => <<~JS
              const AUTH_API_BASE_URL = "https://api.example.com/services/auth";
              chrome.runtime.onMessageExternal.addListener(() => {});
            JS
          }
        )
        issues = []
        warnings = []
        report = nil
        Dir.mktmpdir('webstore-extract-') do |tmpdir|
          report = StoreComplianceHarness.new.send(
            :inspect_webstore_package, zip, tmpdir: tmpdir, issues: issues, warnings: warnings
          )
        end

        assert_eq(report[:manifestVersion], 3)
        assert_includes(issues.join('\n'), 'both tabs and activeTab')
        assert_includes(issues.join('\n'), 'api.example.com')
        assert_includes(issues.join('\n'), 'externally_connectable')
      end
      true
    end

    test('package scan accepts a narrow MV3 package with only local executable code') do
      Dir.mktmpdir('webstore-clean-') do |dir|
        manifest = {
          'manifest_version' => 3,
          'name' => 'Example',
          'description' => 'Example extension',
          'version' => '1.0.0',
          'permissions' => ['storage'],
          'host_permissions' => ['https://auction.example.com/*'],
          'background' => { 'service_worker' => 'background.js' }
        }
        zip = write_extension_zip(dir, manifest: manifest, files: { 'background.js' => 'const enabled = true;' })
        issues = []
        warnings = []
        Dir.mktmpdir('webstore-extract-') do |tmpdir|
          StoreComplianceHarness.new.send(
            :inspect_webstore_package, zip, tmpdir: tmpdir, issues: issues, warnings: warnings
          )
        end

        assert_eq(issues, [])
      end
      true
    end
  end

  test_category('listing, privacy, and media truth') do
    test('public listing blocks fake metrics but internal denylist prose does not self-trigger') do
      subject = StoreComplianceHarness.new
      safe = <<~MARKDOWN
        ## Listing copy
        **Name:** Example
        **Summary (≤132 chars):** Useful extension
        **Description:** Shows current values.
        1. Install the extension.
        ## Assets
        No rating stars, user counts, or ranking claims.
        Screenshot captured from the real extension UI.
      MARKDOWN
      unsafe = safe.sub('Shows current values.', 'Rated by 12,000+ users. #1 extension.')
      safe_issues = []
      safe_warnings = []
      unsafe_issues = []

      subject.send(:audit_webstore_listing, safe, issues: safe_issues, warnings: safe_warnings)
      subject.send(:audit_webstore_listing, unsafe, issues: unsafe_issues, warnings: [])

      assert_eq(safe_issues, [])
      assert_includes(unsafe_issues.join('\n'), 'ranking claim')
      assert_includes(unsafe_issues.join('\n'), 'synthetic store metric')
      true
    end

    test('privacy check requires both the User Data Policy and Limited Use commitment') do
      subject = StoreComplianceHarness.new
      subject.define_singleton_method(:fetch_https) do |_url, redirects: 3|
        raise 'unexpected redirects' unless redirects == 3
        ['We describe data collection but omit the required commitment.', 'https://example.com/privacy']
      end
      issues = []

      report = subject.send(:inspect_webstore_privacy, 'https://example.com/privacy', issues: issues)

      assert_eq(report[:limitedUse], false)
      assert_includes(issues.join('\n'), 'Limited Use statement')
      true
    end

    test('media OCR blocks synthetic counts and rankings and records exact image digest') do
      Dir.mktmpdir('webstore-media-') do |dir|
        path = File.join(dir, 'screenshot-1.png')
        File.binwrite(path, 'fixture-image')
        subject = StoreComplianceHarness.new
        subject.define_singleton_method(:store_image_dimensions) { |_path| [1280, 800] }
        subject.define_singleton_method(:store_image_ocr) do |_path, issues:|
          raise 'issues must be mutable' unless issues.is_a?(Array)
          'Trusted by 10,000+ users. #1 auction extension.'
        end
        issues = []
        warnings = []

        rows = subject.send(:inspect_webstore_media, dir, root: dir, issues: issues, warnings: warnings)

        assert_eq(rows.first[:width], 1280)
        assert_eq(rows.first[:sha256], Digest::SHA256.hexdigest('fixture-image'))
        assert_includes(issues.join('\n'), 'synthetic store metrics')
        assert_includes(issues.join('\n'), 'ranking claim')
      end
      true
    end

    test('reviewer invite accepts epoch-millisecond expiry and enforces private mode') do
      Dir.mktmpdir('webstore-review-') do |dir|
        path = File.join(dir, 'review.json')
        expiry_ms = ((Time.now + (10 * 86_400)).to_f * 1000).to_i
        File.write(path, JSON.generate('ok' => true, 'expiresAt' => expiry_ms.to_s))
        File.chmod(0o600, path)
        issues = []

        report = StoreComplianceHarness.new.send(
          :private_review_instructions_report, path, root: dir, issues: issues
        )

        assert_eq(issues, [])
        assert(report[:expiresAt].end_with?('Z'))
      end
      true
    end

    test('addons-linter parser tolerates npm notices before the JSON payload') do
      subject = StoreComplianceHarness.new
      subject.define_singleton_method(:capture_store_command) do |_command, timeout_seconds:|
        raise 'wrong timeout' unless timeout_seconds == 180
        {
          output: "npm warn cached package\n{\"summary\":{\"errors\":0,\"warnings\":0},\"errors\":[],\"warnings\":[]}",
          exit_status: 0,
          timed_out: false
        }
      end
      issues = []
      warnings = []

      report = subject.send(:run_addons_linter, '/tmp/example.zip', issues: issues, warnings: warnings)

      assert_eq(report[:status], 'completed')
      assert_eq(issues, [])
      assert_eq(warnings, [])
      true
    end
  end

  test_category('Apple adopted validators') do
    test('Apple exact-package validation binds the same bytes and invokes altool validation') do
      Dir.mktmpdir('apple-validation-') do |dir|
        package = File.join(dir, 'Example.ipa')
        File.binwrite(package, 'exact-package')
        subject = StoreComplianceHarness.new
        observed = nil
        subject.define_singleton_method(:capture_store_command) do |command, timeout_seconds:, environment: {}|
          observed = [command, timeout_seconds, environment]
          { output: 'No errors validating archive', exit_status: 0, timed_out: false }
        end

        report = subject.send(
          :appstore_package_validation_report,
          package_path: package,
          platform: 'ios',
          credentials: { key_id: 'KEY123', issuer_id: 'issuer-123' }
        )

        assert_eq(report[:issues], [])
        assert_eq(report[:sha256], Digest::SHA256.hexdigest('exact-package'))
        assert_eq(observed[0][0, 4], ['xcrun', 'altool', '--validate-app', '-f'])
        assert_includes(observed[0], '--apiKey')
        assert_eq(observed[1], 900)
      end
      true
    end
  end
end)
