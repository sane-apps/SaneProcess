#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'release'

class ReleaseGuardrailHarness
  include SaneMasterModules::Release

  def initialize
    @stubbed_url_statuses = {}
    @stubbed_asc_paths = {}
  end

  def stub_url_status(url, code:, location: '', error: nil)
    @stubbed_url_statuses[url] = { code:, location:, error: }
  end

  def appstore_fetch_url_status(url)
    @stubbed_url_statuses.fetch(url) do
      { code: 0, location: '', error: "missing stub for #{url}" }
    end
  end

  def stub_asc_json(path, payload)
    @stubbed_asc_paths[path] = payload
  end

  def appstore_connect_token
    'stub-token'
  end

  def asc_get_json(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
    _ = token
    _ = base
    @stubbed_asc_paths[path]
  end
end

include TestFramework

exit(run_tests('SaneMaster App Store Guardrail Tests') do
  subject = ReleaseGuardrailHarness.new

  test_category('Metadata URL health') do
    test('follows redirects to a healthy final URL') do
      subject.stub_url_status('https://example.com/support', code: 301, location: '/help')
      subject.stub_url_status('https://example.com/help', code: 200)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(report[:ok], 'expected redirect chain to be treated as healthy')
      assert_eq(report[:code], 200)
      assert_eq(report[:final_url], 'https://example.com/help')
      true
    end

    test('fails on HTTP errors') do
      subject.stub_url_status('https://example.com/support', code: 404)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(!report[:ok], 'expected 404 to fail')
      assert_eq(report[:error], 'HTTP 404')
      true
    end
  end

  test_category('Artifact marker detection') do
    test('detects donation and support markers in App Store artifacts') do
      hits = subject.send(
        :appstore_donation_markers,
        "Sponsor on GitHub\nSupport independent development\nBTC"
      )

      assert_includes(hits, 'GitHub Sponsors link/copy')
      assert_includes(hits, 'supporter appeal copy')
      assert_includes(hits, 'crypto donation copy')
      true
    end

    test('detects outside-update markers in App Store artifacts') do
      hits = subject.send(
        :appstore_update_markers,
        strings_out: "SaneSparkleRow\nCheck for updates automatically\nUpdateService",
        otool_out: "@rpath/Sparkle.framework/Versions/B/Sparkle"
      )

      assert_includes(hits, 'Sparkle framework linkage')
      assert_includes(hits, 'Sparkle settings UI')
      assert_includes(hits, 'updater service type')
      true
    end

    test('detects direct purchase markers in App Store artifacts') do
      hits = subject.send(
        :appstore_direct_purchase_markers,
        "Use Purchase Key\nActivation Code\nhttps://go.saneapps.com/buy/saneclick"
      )

      assert_includes(hits, 'website checkout URL')
      assert_includes(hits, 'purchase key entry copy')
      true
    end
  end

  test_category('App Store target graph audit') do
    test('fails when the App Store scheme reuses the direct macOS target') do
      manifest = {
        'schemes' => {
          'SaneClick' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } },
          'SaneClick-AppStore' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } }
        },
        'targets' => {
          'SaneClick' => {
            'type' => 'application',
            'platform' => 'macOS',
            'dependencies' => [{ 'package' => 'Sparkle' }]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneClick',
        appstore_scheme: 'SaneClick-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store scheme SaneClick-AppStore reuses direct application target(s): SaneClick')
      assert_includes(hits, 'App Store target SaneClick still links Sparkle at the target graph level')
      true
    end

    test('fails when the App Store target still relies on strip scripts or Sparkle plist keys') do
      manifest = {
        'schemes' => {
          'SaneSales' => { 'build' => { 'targets' => { 'SaneSales' => 'all' } } },
          'SaneSales-AppStore' => { 'build' => { 'targets' => { 'SaneSalesAppStore' => 'all' } } }
        },
        'targets' => {
          'SaneSales' => {
            'type' => 'application',
            'platform' => 'macOS'
          },
          'SaneSalesAppStore' => {
            'type' => 'application',
            'platform' => 'macOS',
            'info' => { 'properties' => { 'SUFeedURL' => 'https://example.com/appcast.xml' } },
            'postBuildScripts' => [
              { 'name' => 'Strip Sparkle for App Store', 'script' => 'ruby weaken_sparkle.rb "$APP_BINARY"' }
            ]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneSales',
        appstore_scheme: 'SaneSales-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store target SaneSalesAppStore still declares Sparkle Info.plist keys (SUFeedURL)')
      assert_includes(hits, 'App Store target SaneSalesAppStore still relies on Sparkle strip/weaken scripts')
      true
    end
  end

  test_category('Reviewer IAP path guardrails') do
    test('fails when review notes do not tell App Review where to find Pro') do
      report = subject.send(
        :reviewer_access_guardrail_report,
        source_blob: {
          'all' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n",
          'macos' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        },
        appstore_config: {
          'review_notes' => 'Basic is free. Pro is a one-time in-app purchase. No external checkout or license keys.'
        },
        platforms: ['macos']
      )

      assert_includes(
        report[:issues],
        '[macos] Review notes do not tell App Review where to find the optional Pro unlock (for example Settings > License or another visible Unlock Pro path)'
      )
      assert_includes(
        report[:warnings],
        '[macos] Onboarding paywall appears one-shot in code, but review notes do not mention a durable post-onboarding upgrade path like Settings > License'
      )
      true
    end
  end

  test_category('ASC version lane guardrails') do
    test('fails when a different editable ASC lane exists for the platform') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-1', 'attributes' => { 'versionString' => '1.2.2', 'appStoreState' => 'REJECTED' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '1.2.3'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], 'conflict: 1.2.2 (REJECTED)')
      assert_includes(
        report[:issues],
        'App Store Connect has editable macos lane(s) 1.2.2 (REJECTED), but local target is 1.2.3. Retarget or clear that lane before submission.'
      )
      true
    end

    test('passes when the target ASC lane already matches the local version') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=IOS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-2', 'attributes' => { 'versionString' => '2.0.0', 'appStoreState' => 'READY_FOR_REVIEW' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'ios',
        version_string: '2.0.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '2.0.0 (READY_FOR_REVIEW)')
      assert_eq(report[:issues], [])
      true
    end

    test('fails when the local version already exists in a final ASC state') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-3', 'attributes' => { 'versionString' => '3.1.0', 'appStoreState' => 'READY_FOR_SALE' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '3.1.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '3.1.0 (READY_FOR_SALE)')
      assert_includes(
        report[:issues],
        'App Store Connect already has macos version 3.1.0 in final state READY_FOR_SALE — bump MARKETING_VERSION before submission.'
      )
      true
    end
  end
end)
