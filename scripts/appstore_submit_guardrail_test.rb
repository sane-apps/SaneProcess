#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

require_relative 'hooks/test/test_framework'
require_relative 'appstore_submit'

class AppStoreSubmitGuardrailHarness
  def initialize
    @stubbed_url_statuses = {}
    @stubbed_safari_snapshot = nil
    @stubbed_safari_snapshots = nil
    @safari_snapshot_calls = []
    @stubbed_safari_javascript = nil
    @stubbed_patch_result = nil
    @stubbed_iap_record = nil
    @stubbed_iap_records = nil
  end

  def stub_url_status(url, code:, location: '', error: nil)
    @stubbed_url_statuses[url] = { code: code, location: location, error: error }
  end

  def metadata_fetch_url_status(url, method: :head)
    _ = method
    @stubbed_url_statuses.fetch(url) do
      { code: 0, location: '', error: "missing stub for #{url}" }
    end
  end

  def stub_safari_snapshot(snapshot)
    @stubbed_safari_snapshot = snapshot
  end

  def stub_safari_snapshots(snapshots)
    @stubbed_safari_snapshots = Array(snapshots).dup
    @safari_snapshot_calls = []
  end

  attr_reader :safari_snapshot_calls

  def safari_page_snapshot(url:, delay_seconds: 8, navigate: true)
    @safari_snapshot_calls << {
      url: url,
      delay_seconds: delay_seconds,
      navigate: navigate
    }
    if @stubbed_safari_snapshots && !@stubbed_safari_snapshots.empty?
      return @stubbed_safari_snapshots.shift
    end
    @stubbed_safari_snapshot || { 'url' => '', 'body' => '' }
  end

  def stub_safari_javascript(output)
    @stubbed_safari_javascript = output
    @safari_snapshot_calls = []
  end

  def run_safari_javascript(url:, javascript:, delay_seconds: 8, navigate: true)
    @safari_snapshot_calls << {
      url: url,
      delay_seconds: delay_seconds,
      navigate: navigate,
      javascript: javascript
    }
    _ = javascript
    if @stubbed_safari_javascript.is_a?(Array) && !@stubbed_safari_javascript.empty?
      return @stubbed_safari_javascript.shift
    end

    @stubbed_safari_javascript || JSON.generate('url' => '', 'clicks' => [], 'body' => '')
  end

  def stub_patch_result(code, resp)
    @stubbed_patch_result = [code, resp]
  end

  def asc_patch_with_status(*_args, **_kwargs)
    return @stubbed_patch_result if @stubbed_patch_result

    raise 'missing patch stub'
  end

  def stub_iap_record(record)
    @stubbed_iap_record = record
  end

  def stub_iap_records(records)
    @stubbed_iap_records = records
  end

  def find_iap_by_product_id(*_args, **_kwargs)
    @stubbed_iap_record
  end

  def list_app_iaps(*_args, **_kwargs)
    @stubbed_iap_records || []
  end

  def ensure_iap_localization(**_kwargs)
    true
  end

  def ensure_iap_price_schedule(**_kwargs)
    true
  end

  def ensure_iap_review_screenshot(**_kwargs)
    true
  end

  def ensure_iap_availability(**_kwargs)
    true
  end

  def ensure_iap_review_note(**_kwargs)
    true
  end

  def generate_jwt
    'stub-jwt'
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

  test_category('Mandatory preflight receipt') do
    test('blocks submission when App Store preflight receipt is missing') do
      Dir.mktmpdir('missing-appstore-preflight-') do |dir|
        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios'
        )

        assert(!ok, 'expected missing preflight receipt to block submission')
        assert_includes(detail, 'appstore_preflight_status.json')
      end
      true
    end

    test('accepts a fresh passing receipt for the current worktree') do
      Dir.mktmpdir('fresh-appstore-preflight-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: Example\n")
        fingerprint = appstore_worktree_fingerprint(dir)
        File.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          JSON.pretty_generate(
            generatedAt: Time.now.iso8601,
            status: 'passed',
            appId: '123',
            version: '1.0',
            platforms: ['ios'],
            worktreeFingerprint: fingerprint,
            issueCount: 0,
            warningCount: 0,
            issues: [],
            warnings: []
          )
        )

        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios'
        )

        assert(ok, "expected fresh preflight receipt to pass: #{detail}")
      end
      true
    end

    test('blocks App Store upload when strict customer UI contract fails') do
      Dir.mktmpdir('appstore-strict-ui-contract-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        File.write(
          File.join(dir, 'scripts', 'SaneMaster.rb'),
          <<~RUBY
            #!/usr/bin/env ruby
            abort "strict visual contract failed"
          RUBY
        )

        assert(!ensure_strict_customer_ui_contract!(dir), 'expected failed strict UI contract to block upload')
      end
      true
    end
  end

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

  test_category('IAP submission guardrails') do
    test('detects an attached IAP from the live version page snapshot') do
      subject.stub_safari_snapshot(
        'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/macos/version/inflight',
        'body' => "Included Assets\nIn-App Purchases and Subscriptions\ncom.example.pro.unlock\n"
      )

      found = subject.send(
        :version_page_includes_iap?,
        app_id: '123',
        platform: 'macos',
        product_id: 'com.example.pro.unlock'
      )

      assert_eq(found, true)
      true
    end

    test('treats locked IAP review-note fields as non-fatal') do
      subject.stub_patch_result(
        409,
        {
          'errors' => [
            {
              'detail' => 'The field (APP_STORE_REVIEW_INFO) can not be modified'
            }
          ]
        }
      )

      ok = subject.send(
        :ensure_iap_review_note,
        iap_id: 'iap-1',
        review_note: 'Test note',
        token: 'stub-token'
      )

      assert_eq(ok, true)
      true
    end

    test('treats IN_REVIEW as already review-ready') do
      subject.stub_iap_record(
        {
          'id' => 'iap-1',
          'attributes' => {
            'state' => 'IN_REVIEW',
            'name' => 'Example Pro',
            'productId' => 'com.example.pro'
          }
        }
      )
      subject.stub_iap_records(
        [
          {
            'id' => 'iap-1',
            'attributes' => {
              'state' => 'IN_REVIEW',
              'name' => 'Example Pro',
              'productId' => 'com.example.pro'
            }
          }
        ]
      )

      ok = subject.send(
        :ensure_iap_readiness,
        app_id: 'app-1',
        product_id: 'com.example.pro',
        project_root: '/tmp',
        config: { 'appstore' => { 'iap' => { 'display_name' => 'Example Pro' } } },
        token: 'stub-token',
        price_usd: '6.99',
        platform: 'macos',
        version_string: '1.0.0'
      )

      assert_eq(ok, true)
      true
    end

    test('fails when extra active IAP records exist for the app') do
      subject.stub_iap_record(
        {
          'id' => 'iap-1',
          'attributes' => {
            'state' => 'WAITING_FOR_REVIEW',
            'name' => 'Example Pro',
            'productId' => 'com.example.pro'
          }
        }
      )
      subject.stub_iap_records(
        [
          {
            'id' => 'iap-1',
            'attributes' => {
              'state' => 'WAITING_FOR_REVIEW',
              'name' => 'Example Pro',
              'productId' => 'com.example.pro'
            }
          },
          {
            'id' => 'iap-2',
            'attributes' => {
              'state' => 'WAITING_FOR_REVIEW',
              'name' => 'Old Pro Unlock',
              'productId' => 'com.example.pro.old'
            }
          }
        ]
      )

      ok = subject.send(
        :ensure_iap_readiness,
        app_id: 'app-1',
        product_id: 'com.example.pro',
        project_root: '/tmp',
        config: { 'appstore' => { 'iap' => { 'display_name' => 'Example Pro' } } },
        token: 'stub-token',
        price_usd: '6.99',
        platform: 'macos',
        version_string: '1.0.0'
      )

      assert_eq(ok, false)
      true
    end
  end

  test_category('Review package capture') do
    test('polls the review page without renavigating after the first Safari load') do
      subject.stub_safari_snapshots(
        [
          {
            'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
            'body' => "SaneSales\nDistribution\n"
          },
          {
            'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
            'body' => "Messages (1)\nApple\nHello,\nSubmission ID: sub-1\n"
          }
        ]
      )

      review_text = subject.send(
        :fetch_review_message_from_safari,
        app_id: '123',
        submission_id: 'sub-1'
      )

      assert_includes(review_text, 'Messages (1)')
      assert_eq(subject.safari_snapshot_calls.length, 2)
      assert_eq(subject.safari_snapshot_calls[0][:navigate], true)
      assert_eq(subject.safari_snapshot_calls[1][:navigate], false)
      true
    end

    test('does not accept a submission header without the actual reviewer message') do
      subject.stub_safari_snapshots(
        [
          {
            'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
            'body' => "App Review\nSubmission ID: sub-1\nDraft Submissions (3)\n"
          },
          {
            'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
            'body' => "Messages (1)\nAppleYesterday 2:46 PM\nHello,\nSubmission ID: sub-1\n"
          }
        ]
      )

      review_text = subject.send(
        :fetch_review_message_from_safari,
        app_id: '123',
        submission_id: 'sub-1'
      )

      assert_includes(review_text, 'Hello,')
      assert_eq(subject.safari_snapshot_calls.length, 2)
      true
    end

    test('captures review evidence and copies downloaded attachments') do
      subject.stub_safari_snapshot(
        'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
        'body' => "Messages (1)\nApple\nHello,\nGuideline 2.4.5(vii)\n"
      )
      subject.stub_safari_javascript(
        JSON.generate(
          'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
          'clicks' => ['Download screenshot'],
          'body' => "Messages (1)\nApple\nHello,\nGuideline 2.4.5(vii)\n"
        )
      )

      Dir.mktmpdir('appstore-review-package') do |dir|
        downloads_dir = File.join(dir, 'Downloads')
        output_dir = File.join(dir, 'output')
        FileUtils.mkdir_p(downloads_dir)
        File.write(File.join(downloads_dir, 'Screenshot-0326-125858.png'), 'fresh attachment')

        package = subject.send(
          :fetch_review_package_from_safari,
          app_id: '123',
          submission_id: 'sub-1',
          downloads_dir: downloads_dir,
          download_wait_seconds: 0
        )
        package['downloaded_files'] = [File.join(downloads_dir, 'Screenshot-0326-125858.png')]

        summary = subject.send(:persist_review_package, package: package, output_dir: output_dir)

        assert_eq(summary['download_clicks'], ['Download screenshot'])
        assert_eq(summary['downloaded_files'].length, 1)
        assert(File.exist?(File.join(output_dir, 'review_message.txt')), 'expected review message file')
        assert(File.exist?(File.join(output_dir, 'summary.json')), 'expected summary file')
      end
      true
    end

    test('clears every visible empty draft submission before reporting success') do
      subject.stub_safari_javascript(
        [
          JSON.generate('action' => 'clicked', 'remainingBefore' => 2),
          JSON.generate('action' => 'clicked', 'remainingBefore' => 1),
          JSON.generate('action' => 'none', 'remaining' => 0, 'body' => "App Review\nDraft Submissions (0)\n")
        ]
      )

      result = subject.send(:delete_empty_draft_submissions_from_safari, app_id: '123')

      assert_eq(result[:deleted_count], 2)
      assert_eq(result[:remaining_count], 0)
      assert_eq(subject.safari_snapshot_calls.length, 3)
      assert_eq(subject.safari_snapshot_calls[0][:navigate], true)
      assert_eq(subject.safari_snapshot_calls[1][:navigate], false)
      assert_eq(subject.safari_snapshot_calls[2][:navigate], false)
      true
    end
  end
end)
