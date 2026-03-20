#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

require_relative 'hooks/test/test_framework'
require_relative 'appstore_submit'

class AppStoreSubmitGuardrailHarness
  def initialize
    @stubbed_url_statuses = {}
  end

  def stub_url_status(url, code:, location: '', error: nil)
    @stubbed_url_statuses[url] = { code:, location:, error: }
  end

  def metadata_fetch_url_status(url)
    @stubbed_url_statuses.fetch(url) do
      { code: 0, location: '', error: "missing stub for #{url}" }
    end
  end
end

def build_metadata_config(marketing_url: nil)
  {
    'name' => 'SaneTest',
    'appstore' => {
      'privacy_policy_url' => 'https://example.com/privacy',
      'review_notes' => 'Basic is free. This App Store build unlocks Pro with an in-app purchase. No external checkout or license key is used.',
      'metadata' => {
        'macos' => {
          'description' => 'Short focused description for the Mac app.',
          'keywords' => 'menu,bar,productivity,focus,workflow',
          'subtitle' => 'Stay organized',
          'promotional_text' => 'Helpful sales copy that stays within App Store metadata limits.',
          'support_url' => 'https://example.com/support',
          'marketing_url' => marketing_url
        }
      }
    }
  }
end

include TestFramework

exit(run_tests('App Store Submit Guardrail Tests') do
  subject = AppStoreSubmitGuardrailHarness.new

  test_category('Metadata URL health') do
    test('follows redirects to a healthy final URL') do
      subject.stub_url_status('https://example.com/support', code: 301, location: '/help')
      subject.stub_url_status('https://example.com/help', code: 200)

      report = subject.send(:metadata_url_health, 'https://example.com/support')

      assert(report[:ok], 'expected redirect chain to be treated as healthy')
      assert_eq(report[:code], 200)
      assert_eq(report[:final_url], 'https://example.com/help')
      true
    end

    test('fails on HTTP errors') do
      subject.stub_url_status('https://example.com/support', code: 404)

      report = subject.send(:metadata_url_health, 'https://example.com/support')

      assert(!report[:ok], 'expected 404 to fail')
      assert_eq(report[:error], 'HTTP 404')
      true
    end
  end

  test_category('Metadata readiness') do
    test('flags broken support and privacy URLs as hard issues') do
      subject.stub_url_status('https://example.com/support', code: 404)
      subject.stub_url_status('https://example.com/privacy', code: 500)

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(File.join(dir, 'Dummy.swift'), "import Foundation\n")

        report = subject.send(
          :metadata_review_readiness_report,
          config: build_metadata_config,
          asc_platform: 'MAC_OS',
          app_name: 'SaneTest',
          project_root: dir
        )

        assert_includes(
          report[:issues],
          'macOS support URL https://example.com/support did not resolve successfully (HTTP 404)'
        )
        assert_includes(
          report[:issues],
          'macOS privacy policy URL https://example.com/privacy did not resolve successfully (HTTP 500)'
        )
      end
      true
    end

    test('downgrades broken marketing URL to a warning') do
      subject.stub_url_status('https://example.com/support', code: 200)
      subject.stub_url_status('https://example.com/privacy', code: 200)
      subject.stub_url_status('https://example.com/marketing', code: 404)

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(File.join(dir, 'Dummy.swift'), "import Foundation\n")

        report = subject.send(
          :metadata_review_readiness_report,
          config: build_metadata_config(marketing_url: 'https://example.com/marketing'),
          asc_platform: 'MAC_OS',
          app_name: 'SaneTest',
          project_root: dir
        )

        assert_includes(
          report[:warnings],
          'macOS marketing URL https://example.com/marketing did not resolve successfully (HTTP 404)'
        )
      end
      true
    end

    test('fails when review notes do not show App Review where to find Pro') do
      subject.stub_url_status('https://example.com/support', code: 200)
      subject.stub_url_status('https://example.com/privacy', code: 200)

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(
          File.join(dir, 'Dummy.swift'),
          "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        )

        config = build_metadata_config
        config['appstore']['product_id'] = 'com.example.app.pro'

        report = subject.send(
          :metadata_review_readiness_report,
          config: config,
          asc_platform: 'MAC_OS',
          app_name: 'SaneTest',
          project_root: dir
        )

        assert_includes(
          report[:issues],
          'macOS review notes do not tell App Review where to find the optional Pro unlock'
        )
        assert_includes(
          report[:warnings],
          'macOS onboarding paywall appears one-shot; review notes should mention a durable post-onboarding upgrade path like Settings > License'
        )
      end
      true
    end
  end
end)
