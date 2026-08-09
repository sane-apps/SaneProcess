#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative 'release'

include TestFramework

class ReleaseGuardrailSigningHarness
  include SaneMasterModules::Release
end

status = run_tests('SaneMaster Release Guardrails: Signing and verify output') do
  subject = ReleaseGuardrailSigningHarness.new

  test_category("macOS App Store signing audit") do
    test('ignores test bundles when collecting macOS App Store signing targets') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          targets:
            MainApp:
              type: application
              platform: macOS
              bundleId: com.example.app
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "Apple Distribution"
            MainAppTests:
              type: bundle.unit-test
              platform: macOS
              bundleId: com.example.appTests
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "-"
        YAML

        targets = subject.send(:appstore_macos_signing_targets, project_yml)

        assert_eq(targets.length, 1)
        assert_eq(targets.first[:name], 'MainApp')
      end
      true
    end
    test('ignores app extensions when collecting macOS App Store signing targets') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          targets:
            MainApp:
              type: application
              platform: macOS
              bundleId: com.example.app
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "Apple Distribution"
            MainAppWidget:
              type: app-extension
              platform: macOS
              bundleId: com.example.app.widget
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "Apple Distribution"
        YAML

        targets = subject.send(:appstore_macos_signing_targets, project_yml)

        assert_eq(targets.length, 1)
        assert_eq(targets.first[:name], 'MainApp')
      end
      true
    end
  end

  test_category('Mobile App Store signing audit') do
    test('does not require the macOS App Sandbox entitlement for an iOS-only lane') do
      Dir.mktmpdir do |dir|
        entitlement = File.join(dir, 'SaneLot.entitlements')
        File.write(entitlement, <<~PLIST)
          <?xml version="1.0" encoding="UTF-8"?>
          <plist version="1.0"><dict><key>aps-environment</key><string>production</string></dict></plist>
        PLIST

        report = subject.send(
          :appstore_entitlements_report,
          entitlements: [entitlement],
          app_name: 'SaneLot',
          platforms: ['ios']
        )

        assert_eq(report[:issues], [])
        assert_eq(report[:warnings], [])
        assert_eq(report[:summary], entitlement)
      end
      true
    end

    test('detects an iOS application using inherited automatic signing and warns explicitly') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          settings:
            DEVELOPMENT_TEAM: EXAMPLETEAM
            CODE_SIGN_STYLE: Automatic
          targets:
            SaneLot:
              type: application
              platform: iOS
              settings:
                base:
                  PRODUCT_BUNDLE_IDENTIFIER: com.example.sanelot
            SaneLotTests:
              type: bundle.unit-test
              platform: iOS
        YAML

        targets = subject.send(:appstore_mobile_signing_targets, project_yml)
        assert_eq(targets.length, 1)
        assert_eq(targets.first[:name], 'SaneLot')
        assert_eq(targets.first[:bundle_id], 'com.example.sanelot')
        assert_eq(targets.first[:code_sign_style], 'Automatic')

        report = subject.send(:appstore_mobile_signing_target_report, targets.first, profile_cache: {})
        assert_eq(report[:issues], [])
        assert(report[:warnings].any? { |warning| warning.include?('uses automatic signing') })
      end
      true
    end

    test('preserves explicit manual Release-AppStore overrides and profile checks') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          settings:
            CODE_SIGN_STYLE: Automatic
          targets:
            MainApp:
              type: application
              platform: iOS
              settings:
                base:
                  PRODUCT_BUNDLE_IDENTIFIER: com.example.base
                configs:
                  Release-AppStore:
                    PRODUCT_BUNDLE_IDENTIFIER: com.example.store
                    CODE_SIGN_STYLE: Manual
                    CODE_SIGN_IDENTITY: Apple Distribution
                    PROVISIONING_PROFILE_SPECIFIER: Example App Store
        YAML

        targets = subject.send(:appstore_mobile_signing_targets, project_yml)
        assert_eq(targets.length, 1)
        assert_eq(targets.first[:bundle_id], 'com.example.store')
        assert_eq(targets.first[:code_sign_style], 'Manual')
        assert_eq(targets.first[:provisioning_profile], 'Example App Store')

        manual_subject = Class.new(ReleaseGuardrailSigningHarness) do
          def installed_mobileprovision_by_name(_name, _cache)
            { 'Entitlements' => {} }
          end
        end.new
        report = manual_subject.send(:appstore_mobile_signing_target_report, targets.first, profile_cache: {})
        assert_eq(report, { issues: [], warnings: [] })
      end
      true
    end
  end

  test_category("Verify output parsing") do
    test('does not treat mixed pass and failure output as a release-safe success') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
        /tmp/SaneVideoTests.swift:42: error: -[SaneVideoTests.ExampleTests testExample] : XCTAssertTrue failed
        ** TEST FAILED **
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'expected failure markers to be detected')
      assert(!subject.send(:verify_output_indicates_success?, body), 'mixed output must not be treated as success')
      true
    end
    test('accepts a clean Swift Testing summary when no failure markers are present') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'clean output should not report failure')
      assert(subject.send(:verify_output_indicates_success?, body), 'clean output should still count as success')
      true
    end
    test('rejects verify clean-pass text when raw runner failure markers are present') do
      body = <<~LOG
        ** TEST FAILED **
        ✅ 7 targets (clean pass despite a non-zero runner exit)
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detectable')
      assert(!subject.send(:verify_output_indicates_success?, body), 'pass-looking log text must never override failure evidence')
      true
    end
    test('treats auto-dedupe-only verify output as release-safe cleanup') do
      body = <<~LOG
        🧹 Auto-deduping runtime app copies for SaneBar...
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
            - /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'dedupe cleanup should not look like a test failure')
      assert(subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'dedupe-only cleanup should count as release-safe cleanup')
      true
    end
    test('does not treat mixed test failure plus dedupe cleanup as release-safe cleanup') do
      body = <<~LOG
        ** TEST FAILED **
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detected')
      assert(!subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'real test failures must not be treated as dedupe-only cleanup')
      true
    end
  end

end

exit(status) if __FILE__ == $PROGRAM_NAME
