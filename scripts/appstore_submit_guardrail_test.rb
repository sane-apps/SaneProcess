#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

require_relative 'hooks/test/test_framework'
require_relative 'appstore_submit'

def with_env(overrides)
  previous = {}
  overrides.each_key { |key| previous[key] = ENV.key?(key) ? ENV[key] : :__missing__ }
  overrides.each do |key, value|
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
  yield
ensure
  previous.each do |key, value|
    value == :__missing__ ? ENV.delete(key) : ENV[key] = value
  end
end

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
    @stubbed_subscription_record = nil
    @stubbed_version_page_includes_iap = :__unset
    @stubbed_get_statuses = {}
    @stubbed_post_result = nil
    @last_post_args = nil
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

  def stub_get_status(path, code, resp)
    @stubbed_get_statuses[path] = [code, resp]
  end

  def asc_get_with_status(path, **_kwargs)
    @stubbed_get_statuses.fetch(path) do
      raise "missing get stub for #{path}"
    end
  end

  def stub_post_result(code, resp)
    @stubbed_post_result = [code, resp]
  end

  attr_reader :last_post_args

  def asc_post_with_status(*args, **kwargs)
    @last_post_args = { args: args, kwargs: kwargs }
    return @stubbed_post_result if @stubbed_post_result

    raise 'missing post stub'
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

  def stub_subscription_record(record)
    @stubbed_subscription_record = record
  end

  def find_subscription_by_product_id(*_args, **_kwargs)
    @stubbed_subscription_record
  end

  def ensure_subscription_review_screenshot(**_kwargs)
    true
  end

  def stub_version_page_includes_iap(value)
    @stubbed_version_page_includes_iap = value
  end

  def version_page_includes_iap?(*_args, **_kwargs)
    return @stubbed_version_page_includes_iap unless @stubbed_version_page_includes_iap == :__unset

    super
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

  test_category('ASC credential resolution') do
    test('uses env-provided ASC credentials without SaneApps defaults') do
      Dir.mktmpdir('asc-submit-credentials-') do |dir|
        key_path = File.join(dir, 'AuthKey_TEST.p8')
        File.write(key_path, 'not-a-real-key')
        with_env(
          'ASC_AUTH_KEY_ID' => 'TESTKEY123',
          'ASC_AUTH_ISSUER_ID' => '00000000-0000-0000-0000-000000000000',
          'ASC_AUTH_KEY_PATH' => key_path,
          'ASC_KEY_ID' => nil,
          'ASC_ISSUER_ID' => nil,
          'ASC_KEY_PATH' => nil
        ) do
          credentials = resolved_asc_credentials
          assert_eq(credentials[:key_id], 'TESTKEY123')
          assert_eq(credentials[:issuer_id], '00000000-0000-0000-0000-000000000000')
          assert_eq(credentials[:key_path], key_path)
        end
      end
      true
    end

    test('missing ASC credentials fail with generic diagnostics') do
      status = nil
      with_env(
        'ASC_AUTH_KEY_ID' => nil,
        'ASC_AUTH_ISSUER_ID' => nil,
        'ASC_AUTH_KEY_PATH' => nil,
        'ASC_KEY_ID' => nil,
        'ASC_ISSUER_ID' => nil,
        'ASC_KEY_PATH' => nil
      ) do
        begin
          require_asc_credentials!
        rescue SystemExit => e
          status = e.status
        end
      end

      assert_eq(status, 1)
      true
    end
  end

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
          <<~BASH
            #!/bin/bash
            echo "strict visual contract failed" >&2
            exit 1
          BASH
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
    test('creates missing app availability with JSON API local IDs') do
      subject.stub_get_status(
        '/apps/app-1/appAvailabilityV2',
        404,
        {
          'errors' => [
            { 'detail' => "There is no resource of type 'appAvailabilities' with id 'app-1'" }
          ]
        }
      )
      subject.stub_get_status(
        '/territories?limit=200',
        200,
        {
          'data' => [
            { 'id' => 'USA' },
            { 'id' => 'CAN' }
          ]
        }
      )
      subject.stub_post_result(
        201,
        {
          'data' => {
            'id' => 'app-1',
            'type' => 'appAvailabilities'
          }
        }
      )

      ok = subject.send(:ensure_app_availability, app_id: 'app-1', token: 'stub-token')

      assert_eq(ok, true)
      body = subject.last_post_args[:kwargs][:body]
      assert_eq(body.dig(:data, :type), 'appAvailabilities')
      assert_eq(body.dig(:data, :relationships, :app, :data, :id), 'app-1')
      assert_eq(body.dig(:data, :relationships, :territoryAvailabilities, :data).map { |row| row[:lid] }, ['territory-0', 'territory-1'])
      assert(!body.dig(:data, :relationships, :territoryAvailabilities, :data).any? { |row| row.key?(:id) }, 'new related territoryAvailability resources must use lid, not fake id')
      assert_eq(body[:included].map { |row| row[:lid] }, ['territory-0', 'territory-1'])
      assert(!body[:included].any? { |row| row.key?(:id) }, 'inline territoryAvailability resources must use lid, not fake id')
      assert_eq(body[:included].map { |row| row.dig(:attributes, :available) }, [true, true])
      assert_eq(body[:included].map { |row| row.dig(:attributes, :preOrderEnabled) }, [false, false])
      assert(!body[:included].any? { |row| row[:attributes].key?(:releaseDate) }, 'releaseDate must be omitted unless preorder is enabled')
      true
    end

    test('uses JSON API local IDs for inline app territory availability creation') do
      assert_eq(subject.send(:app_availability_local_id, 0), 'territory-0')
      assert_eq(subject.send(:app_availability_local_id, 12), 'territory-12')
      true
    end

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

    test('blocks first subscription that is ready but not attached to the app version') do
      subject.stub_subscription_record(
        {
          'id' => 'sub-1',
          'attributes' => {
            'state' => 'READY_TO_SUBMIT',
            'productId' => 'com.example.pro.yearly'
          }
        }
      )
      subject.stub_version_page_includes_iap(false)

      ok = subject.send(
        :ensure_subscription_readiness,
        app_id: 'app-1',
        product_id: 'com.example.pro.yearly',
        project_root: '/tmp',
        config: { 'appstore' => { 'iap' => { 'type' => 'auto_renewable_subscription' } } },
        token: 'stub-token',
        platform: 'ios',
        version_string: '1.0'
      )

      assert_eq(ok, :needs_version_attachment)
      true
    end

    test('allows first subscription only when Safari proves it is attached to the app version') do
      subject.stub_subscription_record(
        {
          'id' => 'sub-1',
          'attributes' => {
            'state' => 'READY_TO_SUBMIT',
            'productId' => 'com.example.pro.yearly'
          }
        }
      )
      subject.stub_version_page_includes_iap(true)

      ok = subject.send(
        :ensure_subscription_readiness,
        app_id: 'app-1',
        product_id: 'com.example.pro.yearly',
        project_root: '/tmp',
        config: { 'appstore' => { 'iap' => { 'type' => 'auto_renewable_subscription' } } },
        token: 'stub-token',
        platform: 'ios',
        version_string: '1.0'
      )

      assert_eq(ok, true)
      true
    end

    test('first subscription reports unknown when Safari attachment proof is unavailable') do
      subject.stub_subscription_record(
        {
          'id' => 'sub-1',
          'attributes' => {
            'state' => 'READY_TO_SUBMIT',
            'productId' => 'com.example.pro.yearly'
          }
        }
      )
      subject.stub_version_page_includes_iap(nil)

      ok = subject.send(
        :ensure_subscription_readiness,
        app_id: 'app-1',
        product_id: 'com.example.pro.yearly',
        project_root: '/tmp',
        config: { 'appstore' => { 'iap' => { 'type' => 'auto_renewable_subscription' } } },
        token: 'stub-token',
        platform: 'ios',
        version_string: '1.0'
      )

      assert_eq(ok, :version_attachment_unknown)
      true
    end

    test('version page IAP proof waits through partial Included Assets loads') do
      subject.stub_version_page_includes_iap(:__unset)
      subject.stub_safari_snapshots([
        { 'body' => 'Included Assets\nIn-App Purchases and Subscriptions\nLoading...' },
        { 'body' => 'Included Assets\nIn-App Purchases and Subscriptions\ncom.example.pro.yearly' }
      ])

      ok = subject.send(
        :version_page_includes_iap?,
        app_id: 'app-1',
        platform: 'ios',
        product_id: 'com.example.pro.yearly'
      )

      assert_eq(ok, true)
      assert_eq(subject.safari_snapshot_calls.length, 2)
      true
    end

    test('extracts review submission conflicts from associated ASC errors') do
      id = subject.send(
        :extract_conflict_submission_id,
        {
          'errors' => [
            {
              'detail' => 'This resource cannot be reviewed, please check associated errors to see why.',
              'meta' => {
                'associatedErrors' => {
                  '/appStoreVersions/123' => [
                    {
                      'detail' => 'appStoreVersions with id 123 was already added to another reviewSubmission with id e975c41c-37aa-434f-8e6b-4d220831c51a'
                    }
                  ]
                }
              }
            }
          ]
        }
      )

      assert_eq(id, 'e975c41c-37aa-434f-8e6b-4d220831c51a')
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

    test('submit recovery requires explicit approval before deleting draft submissions') do
      source = File.read(File.expand_path('appstore_submit.rb', __dir__))

      assert_includes(source, "SANEPROCESS_APPROVE_ASC_DRAFT_CLEANUP")
      assert_includes(source, 'Automatic Draft Submission cleanup is disabled')
      true
    end
  end
end)
