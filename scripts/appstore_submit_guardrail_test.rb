#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

require_relative 'hooks/test/test_framework'
require_relative 'hooks/release_receipt_signer'
require_relative 'appstore_submit'

APPSTORE_PREFLIGHT_TEST_SIGNER = ReleaseReceiptSigner.test_signer(secret: 'appstore-preflight-guardrail-test')
APPSTORE_PREFLIGHT_ASC_TARGET = {
  'type' => 'package',
  'platform' => 'ios',
  'version' => '1.0',
  'build' => '100',
  'fileName' => 'Example.ipa',
  'sha256' => 'a' * 64,
  'size' => 42,
  'bundleId' => 'com.example.app'
}.freeze

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

def write_submit_test_plist(path, bundle_id:)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(
    path,
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>#{bundle_id}</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundleVersion</key><string>100</string>
      </dict></plist>
    PLIST
  )
end

class AppStoreSubmitGuardrailHarness
  def initialize
    @stubbed_url_statuses = {}
    @stubbed_brave_snapshot = nil
    @stubbed_brave_snapshots = nil
    @brave_snapshot_calls = []
    @stubbed_brave_javascript = nil
    @stubbed_patch_result = nil
    @stubbed_iap_record = nil
    @stubbed_iap_records = nil
    @stubbed_subscription_record = nil
    @stubbed_subscription_records = nil
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

  def stub_brave_snapshot(snapshot)
    @stubbed_brave_snapshot = snapshot
  end

  def stub_brave_snapshots(snapshots)
    @stubbed_brave_snapshots = Array(snapshots).dup
    @brave_snapshot_calls = []
  end

  attr_reader :brave_snapshot_calls

  def brave_page_snapshot(url:, delay_seconds: 8, navigate: true)
    @brave_snapshot_calls << {
      url: url,
      delay_seconds: delay_seconds,
      navigate: navigate
    }
    if @stubbed_brave_snapshots && !@stubbed_brave_snapshots.empty?
      return @stubbed_brave_snapshots.shift
    end
    @stubbed_brave_snapshot || { 'url' => '', 'body' => '' }
  end

  def stub_brave_javascript(output)
    @stubbed_brave_javascript = output
    @brave_snapshot_calls = []
  end

  def run_brave_javascript(url:, javascript:, delay_seconds: 8, navigate: true)
    @brave_snapshot_calls << {
      url: url,
      delay_seconds: delay_seconds,
      navigate: navigate,
      javascript: javascript
    }
    _ = javascript
    if @stubbed_brave_javascript.is_a?(Array) && !@stubbed_brave_javascript.empty?
      return @stubbed_brave_javascript.shift
    end

    @stubbed_brave_javascript || JSON.generate('url' => '', 'clicks' => [], 'body' => '')
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

  def stub_subscription_records(records)
    @stubbed_subscription_records = records
  end

  def list_app_subscriptions(*_args, **_kwargs)
    @stubbed_subscription_records || []
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

class BraveSnapshotGuardHarness
  def initialize(payload)
    @payload = payload
  end

  def run_brave_javascript(**_kwargs)
    JSON.generate(@payload)
  end
end

class BraveRawResultHarness
  def initialize(raw)
    @raw = raw
  end

  def run_brave_javascript(**_kwargs)
    @raw
  end
end

class ObsoleteSubscriptionDeletionHarness
  attr_reader :delete_paths

  def initialize(get_responses:, delete_responses:)
    @get_responses = Hash.new { |hash, key| hash[key] = [] }
    get_responses.each { |path, responses| @get_responses[path] = Array(responses).dup }
    @delete_responses = delete_responses.transform_values { |responses| Array(responses).dup }
    @delete_paths = []
  end

  def asc_get_with_status(path, **_kwargs)
    responses = @get_responses[path]
    raise "missing get response for #{path}" if responses.empty?

    responses.shift
  end

  def asc_delete_with_status(path, **_kwargs)
    @delete_paths << path
    responses = @delete_responses.fetch(path) { raise "missing delete response for #{path}" }
    raise "exhausted delete responses for #{path}" if responses.empty?

    responses.shift
  end
end

class ReviewDetailHarness
  attr_reader :get_paths, :patch_calls, :post_calls

  def initialize(existing: nil, post_result: { 'data' => { 'id' => 'created-detail' } })
    @existing = existing
    @post_result = post_result
    @get_paths = []
    @patch_calls = []
    @post_calls = []
  end

  def asc_get(path, **_kwargs)
    @get_paths << path
    return {} unless @existing

    {
      'data' => {
        'id' => 'detail-1',
        'attributes' => @existing
      }
    }
  end

  def asc_patch(path, body:, **_kwargs)
    @patch_calls << { path: path, body: body }
    { 'data' => { 'id' => 'detail-1' } }
  end

  def asc_post(path, body:, **_kwargs)
    @post_calls << { path: path, body: body }
    @post_result
  end
end

class AppStoreBuildWaitHarness
  def initialize(response)
    @response = response
  end

  def asc_get(*_args, **_kwargs)
    @response
  end
end

def build_metadata_config(
  marketing_url: nil,
  review_notes: 'Basic is free. This App Store build unlocks Pro with an in-app purchase. No external checkout or license key is used.'
)
  {
    'name' => 'SaneTest',
    'appstore' => {
      'privacy_policy_url' => 'https://example.com/privacy',
      'review_notes' => review_notes,
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

    test('default review contact is the real-name compliance identity') do
      # Owner ruling 2026-07-15: Apple review/compliance is a real-name vendor
      # lane — the default contact is Stephan Joseph, never the Mr. Sane alias.
      with_env(
        'APPSTORE_CONTACT_NAME' => nil,
        'APPSTORE_CONTACT_PHONE' => '727-758-9785',
        'APPSTORE_CONTACT_EMAIL' => nil
      ) do
        contact = resolve_review_contact({})
        assert_eq(contact[:first_name], 'Stephan')
        assert_eq(contact[:last_name], 'Joseph')
        assert_eq(contact[:email], 'hi@saneapps.com')
      end
      true
    end
  end

  test_category('Protected App Review demo credentials') do
    contact = {
      first_name: 'Review',
      last_name: 'Contact',
      phone: '+15555550100',
      email: 'review@example.com',
      notes: 'Enter the protected connection code.'
    }

    test('resolves a configured password from an owner-only file') do
      Dir.mktmpdir('appstore-review-password-') do |dir|
        secret_path = File.join(dir, 'review-code.txt')
        File.write(secret_path, "fixture-connection-code\n")
        File.chmod(0o600, secret_path)
        config = {
          'appstore' => {
            'review_demo_account' => {
              'name' => 'Example App Review',
              'password_file' => secret_path
            }
          }
        }

        account = resolve_review_demo_account(config, project_root: dir)

        assert_eq(account[:name], 'Example App Review')
        assert_eq(account[:password], 'fixture-connection-code')
      end
      true
    end

    test('fails closed for missing or insecure password files') do
      Dir.mktmpdir('appstore-review-password-invalid-') do |dir|
        missing_config = {
          'appstore' => {
            'review_demo_account' => {
              'name' => 'Example App Review',
              'password_file' => File.join(dir, 'missing.txt')
            }
          }
        }
        begin
          resolve_review_demo_account(missing_config, project_root: dir)
          assert(false, 'expected a missing review password file to fail')
        rescue ArgumentError => e
          assert_includes(e.message, 'missing or is not a regular file')
        end

        insecure_path = File.join(dir, 'insecure.txt')
        File.write(insecure_path, 'fixture-secret-must-not-appear')
        File.chmod(0o644, insecure_path)
        insecure_config = {
          'appstore' => {
            'review_demo_account' => {
              'name' => 'Example App Review',
              'password_file' => insecure_path
            }
          }
        }
        begin
          resolve_review_demo_account(insecure_config, project_root: dir)
          assert(false, 'expected an insecure review password file to fail')
        rescue ArgumentError => e
          assert_includes(e.message, 'permissions 600')
          assert(!e.message.include?('fixture-secret-must-not-appear'), 'diagnostic must not expose secret contents')
        end
      end
      true
    end

    test('creates review detail with protected demo account fields') do
      harness = ReviewDetailHarness.new
      protected_contact = contact.merge(
        demo_account: {
          name: 'Example App Review',
          password: 'fixture-connection-code'
        }
      )

      assert(harness.send(:ensure_review_detail, 'version-1', protected_contact, 'token'))
      assert_eq(harness.post_calls.length, 1)
      attributes = harness.post_calls.first[:body].dig(:data, :attributes)
      assert_eq(attributes[:demoAccountRequired], true)
      assert_eq(attributes[:demoAccountName], 'Example App Review')
      assert_eq(attributes[:demoAccountPassword], 'fixture-connection-code')
      true
    end

    test('updates changed protected demo account fields') do
      harness = ReviewDetailHarness.new(
        existing: {
          'contactFirstName' => contact[:first_name],
          'contactLastName' => contact[:last_name],
          'contactPhone' => contact[:phone],
          'contactEmail' => contact[:email],
          'notes' => contact[:notes],
          'demoAccountRequired' => false
        }
      )
      protected_contact = contact.merge(
        demo_account: {
          name: 'Example App Review',
          password: 'fixture-connection-code'
        }
      )

      assert(harness.send(:ensure_review_detail, 'version-1', protected_contact, 'token'))
      assert_eq(harness.patch_calls.length, 1)
      attributes = harness.patch_calls.first[:body].dig(:data, :attributes)
      assert_eq(attributes[:demoAccountRequired], true)
      assert_eq(attributes[:demoAccountName], 'Example App Review')
      assert_eq(attributes[:demoAccountPassword], 'fixture-connection-code')
      true
    end

    test('does not update an already matching protected demo account') do
      protected_contact = contact.merge(
        demo_account: {
          name: 'Example App Review',
          password: 'fixture-connection-code'
        }
      )
      harness = ReviewDetailHarness.new(
        existing: {
          'contactFirstName' => contact[:first_name],
          'contactLastName' => contact[:last_name],
          'contactPhone' => contact[:phone],
          'contactEmail' => contact[:email],
          'notes' => contact[:notes],
          'demoAccountRequired' => true,
          'demoAccountName' => 'Example App Review',
          'demoAccountPassword' => 'fixture-connection-code'
        }
      )

      assert(harness.send(:ensure_review_detail, 'version-1', protected_contact, 'token'))
      assert_eq(harness.patch_calls, [])
      true
    end

    test('preserves demoAccountRequired false when no demo account is configured') do
      harness = ReviewDetailHarness.new

      assert(harness.send(:ensure_review_detail, 'version-1', contact, 'token'))
      attributes = harness.post_calls.first[:body].dig(:data, :attributes)
      assert_eq(attributes[:demoAccountRequired], false)
      assert(!attributes.key?(:demoAccountName), 'unconfigured apps must not send a demo account name')
      assert(!attributes.key?(:demoAccountPassword), 'unconfigured apps must not send a demo account password')
      true
    end

    test('redacts the configured demo password from ASC error excerpts') do
      body = {
        data: {
          attributes: {
            demoAccountPassword: 'fixture-connection-code'
          }
        }
      }
      response = 'Rejected password fixture-connection-code in request'
      redacted = redact_asc_response_body(response, body)

      assert_eq(redacted, 'Rejected password [REDACTED] in request')
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
          platform: 'ios',
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
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
        APPSTORE_PREFLIGHT_TEST_SIGNER.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          {
            'type' => 'appstore_preflight_status',
            'generatedAt' => Time.now.iso8601,
            'status' => 'passed',
            'appId' => '123',
            'version' => '1.0',
            'platforms' => ['ios'],
            'submissionTarget' => APPSTORE_PREFLIGHT_ASC_TARGET,
            'worktreeFingerprint' => fingerprint,
            'issueCount' => 0,
            'warningCount' => 0,
            'issues' => [],
            'warnings' => []
          },
          producer: 'saneprocess.appstore_preflight.v1'
        )

        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios',
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
        )

        assert(ok, "expected fresh preflight receipt to pass: #{detail}")
      end
      true
    end

    test('rejects a receipt bound to different exact package bytes') do
      Dir.mktmpdir('mismatched-appstore-build-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: Example\n")
        APPSTORE_PREFLIGHT_TEST_SIGNER.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          {
            'type' => 'appstore_preflight_status',
            'generatedAt' => Time.now.iso8601,
            'status' => 'passed',
            'appId' => '123',
            'version' => '1.0',
            'platforms' => ['ios'],
            'submissionTarget' => APPSTORE_PREFLIGHT_ASC_TARGET,
            'worktreeFingerprint' => appstore_worktree_fingerprint(dir),
            'issues' => []
          },
          producer: 'saneprocess.appstore_preflight.v1'
        )

        different_target = APPSTORE_PREFLIGHT_ASC_TARGET.merge('sha256' => 'b' * 64)
        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios',
          submission_target: different_target,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
        )

        assert(!ok, 'expected different package bytes to invalidate preflight authorization')
        assert_includes(detail, 'exact fresh package')
      end
      true
    end

    test('--skip-upload is retired with actionable fresh-build guidance') do
      output, status = Open3.capture2e(
        RbConfig.ruby,
        File.expand_path('appstore_submit.rb', __dir__),
        '--skip-upload', '--app-id', '123', '--version', '1.0',
        '--platform', 'ios', '--project-root', Dir.tmpdir
      )
      assert(!status.success?)
      assert_includes(output, '--skip-upload is retired')
      assert_includes(output, 'exact remote ASC bytes cannot be proven')
      assert_includes(output, 'Increment the build number')
      true
    end

    test('package binding compares digest and metadata exactly') do
      target = {
        'type' => 'package',
        'platform' => 'macos',
        'fileName' => 'Example.pkg',
        'sha256' => 'a' * 64,
        'size' => 42,
        'bundleId' => 'com.example.app',
        'version' => '1.0',
        'build' => '100'
      }

      assert(appstore_submission_targets_match?(target, target.dup), 'exact package identity should match')
      assert(
        !appstore_submission_targets_match?(target, target.merge('sha256' => 'b' * 64)),
        'different package bytes must not share authorization'
      )
      true
    end

    test('refuses package bytes changed after exact-target preflight') do
      Dir.mktmpdir('appstore-package-byte-binding-') do |dir|
        path = File.join(dir, 'Example.ipa')
        File.write(path, 'audited bytes')
        target = {
          'type' => 'package',
          'sha256' => Digest::SHA256.file(path).hexdigest,
          'size' => File.size(path)
        }

        assert(appstore_package_bytes_match_target?(path, target))
        File.write(path, 'different unaudited bytes')
        assert(!appstore_package_bytes_match_target?(path, target))
      end
      true
    end

    test('uploads from a private read-only verified staging copy immune to source mutation') do
      Dir.mktmpdir('appstore-package-staging-') do |dir|
        source = File.join(dir, 'Example.ipa')
        File.write(source, 'audited bytes')
        target = {
          'type' => 'package',
          'sha256' => Digest::SHA256.file(source).hexdigest,
          'size' => File.size(source)
        }
        fingerprint_before_staging = appstore_worktree_fingerprint(dir)
        staged = stage_appstore_package(source, project_root: dir)
        assert(staged, 'expected verified staging to succeed')
        assert(staged.start_with?(File.join(File.realpath(dir), 'outputs', 'appstore-preflight-bindings')))
        assert_eq(File.stat(File.dirname(staged)).mode & 0o777, 0o700)
        assert_eq(File.stat(staged).mode & 0o777, 0o400)
        assert_eq(appstore_worktree_fingerprint(dir), fingerprint_before_staging)

        File.write(source, 'mutated source bytes')
        assert(appstore_package_bytes_match_target?(staged, target))
        assert(!appstore_package_bytes_match_target?(source, target))
        assert_eq(File.read(staged), 'audited bytes')
      end
      true
    end

    test('classifies new duplicate and failed uploads distinctly') do
      assert_eq(classify_appstore_upload_output(success: true, output: 'No errors uploading'), :uploaded)
      assert_eq(classify_appstore_upload_output(success: false, output: 'Bundle already exists'), :duplicate)
      assert_eq(classify_appstore_upload_output(success: true, output: 'Upload succeeded but bundle already exists'), :duplicate)
      assert_eq(classify_appstore_upload_output(success: false, output: 'Validation failed'), :failed)
      true
    end

    test('has no generic upload fallback when exact package identity cannot be reparsed') do
      Dir.mktmpdir('appstore-exact-upload-command-') do |dir|
        invalid = File.join(dir, 'Invalid.ipa')
        File.write(invalid, 'not an ipa')
        command = exact_appstore_upload_command(
          invalid,
          app_id: '123',
          credentials: { key_id: 'KEY', issuer_id: 'ISSUER' }
        )
        assert_eq(command, nil)
      end
      true
    end

    test('fingerprint changes when git-untracked content changes without size or mtime drift') do
      Dir.mktmpdir('git-untracked-appstore-fingerprint-') do |dir|
        Open3.capture2e('git', '-C', dir, 'init')
        path = File.join(dir, 'candidate.txt')
        File.write(path, 'AAAA')
        fixed_time = Time.at(1_700_000_000)
        File.utime(fixed_time, fixed_time, path)
        before = appstore_worktree_fingerprint(dir)

        File.write(path, 'BBBB')
        File.utime(fixed_time, fixed_time, path)
        after = appstore_worktree_fingerprint(dir)

        assert(before != after, 'git fingerprint must hash untracked file contents')
      end
      true
    end

    test('non-git fingerprint hashes file contents instead of size and mtime only') do
      Dir.mktmpdir('non-git-appstore-fingerprint-') do |dir|
        path = File.join(dir, 'candidate.txt')
        File.write(path, 'AAAA')
        fixed_time = Time.at(1_700_000_000)
        File.utime(fixed_time, fixed_time, path)
        before = appstore_worktree_fingerprint(dir)

        File.write(path, 'BBBB')
        File.utime(fixed_time, fixed_time, path)
        after = appstore_worktree_fingerprint(dir)

        assert(before != after, 'non-git fingerprint must hash file contents')
      end
      true
    end

    test('rejects unsigned App Store preflight receipts') do
      Dir.mktmpdir('unsigned-appstore-preflight-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: Example\n")
        File.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          JSON.generate(
            generatedAt: Time.now.iso8601,
            status: 'passed',
            appId: '123',
            version: '1.0',
            platforms: ['ios'],
            worktreeFingerprint: appstore_worktree_fingerprint(dir),
            issues: []
          )
        )

        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios',
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
        )

        assert(!ok, 'expected unsigned receipt to be rejected')
        assert_includes(detail, 'signed')
      end
      true
    end

    test('rejects App Store preflight receipts with missing target bindings') do
      Dir.mktmpdir('unbound-appstore-preflight-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: Example\n")
        APPSTORE_PREFLIGHT_TEST_SIGNER.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          {
            'type' => 'appstore_preflight_status',
            'generatedAt' => Time.now.iso8601,
            'status' => 'passed',
            'appId' => '',
            'version' => '',
            'platforms' => [],
            'worktreeFingerprint' => '',
            'issues' => []
          },
          producer: 'saneprocess.appstore_preflight.v1'
        )

        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios',
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
        )

        assert(!ok, 'expected missing target bindings to be rejected')
        assert_match(detail, /appId|version|platform|fingerprint/)
      end
      true
    end

    test('rejects correctly signed App Store preflight receipts four minutes in the future') do
      Dir.mktmpdir('future-appstore-preflight-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'outputs'))
        File.write(File.join(dir, '.saneprocess'), "name: Example\n")
        fingerprint = appstore_worktree_fingerprint(dir)
        APPSTORE_PREFLIGHT_TEST_SIGNER.write(
          File.join(dir, 'outputs', 'appstore_preflight_status.json'),
          {
            'type' => 'appstore_preflight_status',
            'generatedAt' => (Time.now.utc + (4 * 60)).iso8601,
            'status' => 'passed',
            'appId' => '123',
            'version' => '1.0',
            'platforms' => ['ios'],
            'submissionTarget' => APPSTORE_PREFLIGHT_ASC_TARGET,
            'worktreeFingerprint' => fingerprint,
            'issues' => []
          },
          producer: 'saneprocess.appstore_preflight.v1'
        )

        ok, detail = fresh_appstore_preflight_receipt?(
          project_root: dir,
          app_id: '123',
          version: '1.0',
          platform: 'ios',
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET,
          receipt_signer: APPSTORE_PREFLIGHT_TEST_SIGNER
        )

        assert(!ok, 'expected future-dated receipt to be rejected')
        assert_includes(detail, 'future')
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

  test_category('Package identity selection') do
    test('selects a unique expected app identity instead of the first plist') do
      Dir.mktmpdir('submit-package-selection-') do |dir|
        helper = File.join(dir, 'AHelper.app', 'Info.plist')
        submitted = File.join(dir, 'ZSubmitted.app', 'Info.plist')
        write_submit_test_plist(helper, bundle_id: 'com.example.helper')
        write_submit_test_plist(submitted, bundle_id: 'com.example.submitted')

        info = select_unique_package_app_info(
          [helper, submitted],
          expected_bundle_id: 'com.example.submitted'
        )

        assert_eq(info[:bundle_id], 'com.example.submitted')
      end
      true
    end

    test('fails closed when package identity is ambiguous or unreadable') do
      Dir.mktmpdir('submit-package-ambiguous-') do |dir|
        first = File.join(dir, 'First.app', 'Info.plist')
        second = File.join(dir, 'Second.app', 'Info.plist')
        write_submit_test_plist(first, bundle_id: 'com.example.same')
        write_submit_test_plist(second, bundle_id: 'com.example.same')

        assert_eq(select_unique_package_app_info([first, second]), nil)
        File.write(first, 'not a plist')
        assert_eq(select_unique_package_app_info([first]), nil)
      end
      true
    end

    test('finds pkg app identities below install roots and excludes nested helper apps') do
      Dir.mktmpdir('submit-pkg-layout-') do |dir|
        submitted = File.join(dir, 'component', 'Payload', 'Applications', 'Submitted.app', 'Contents', 'Info.plist')
        nested = File.join(
          dir, 'component', 'Payload', 'Applications', 'Submitted.app', 'Contents',
          'Helpers', 'Nested.app', 'Contents', 'Info.plist'
        )
        write_submit_test_plist(submitted, bundle_id: 'com.example.submitted')
        write_submit_test_plist(nested, bundle_id: 'com.example.nested')

        assert_eq(top_level_pkg_app_info_paths(dir), [submitted])
      end
      true
    end
  end

  test_category('Exact package preflight binding') do
    test('refreshes package binding through a bash project SaneMaster wrapper') do
      Dir.mktmpdir('appstore-binding-wrapper-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'scripts'))
        wrapper = File.join(dir, 'scripts', 'SaneMaster.rb')
        File.write(wrapper, "#!/bin/bash\nexit 0\n")
        FileUtils.chmod('+x', wrapper)
        captured = nil

        success, = refresh_appstore_preflight_binding(
          project_root: dir,
          submission_target: APPSTORE_PREFLIGHT_ASC_TARGET.merge('path' => '/tmp/Example.pkg'),
          command_runner: lambda do |command|
            captured = command
            true
          end
        )

        assert(success, 'expected binding refresh to accept the canonical wrapper')
        assert_eq(captured.first(2), ['bash', wrapper])
        assert_eq(captured.drop(2), [
          'appstore_preflight', '--platform', 'ios', '--pkg', '/tmp/Example.pkg'
        ])
      end
      true
    end
  end

  test_category('Exact ASC build identity') do
    test('requires build number marketing version and platform to match one included identity') do
      response = {
        'data' => [{
          'id' => 'build-1',
          'type' => 'builds',
          'attributes' => { 'version' => '100', 'processingState' => 'VALID' },
          'relationships' => { 'preReleaseVersion' => { 'data' => { 'id' => 'pre-1' } } }
        }],
        'included' => [{
          'id' => 'pre-1',
          'type' => 'preReleaseVersions',
          'attributes' => { 'version' => '1.0', 'platform' => 'IOS' }
        }]
      }
      harness = AppStoreBuildWaitHarness.new(response)
      build_id = harness.send(
        :wait_for_build,
        'app-1', '100', 'IOS', 'token',
        expected_marketing_version: '1.0'
      )
      assert_eq(build_id, 'build-1')
      true
    end

    test('rejects duplicate build numbers belonging to another marketing version') do
      response = {
        'data' => [{
          'id' => 'wrong-version',
          'attributes' => { 'version' => '100', 'processingState' => 'VALID' },
          'relationships' => { 'preReleaseVersion' => { 'data' => { 'id' => 'pre-old' } } }
        }],
        'included' => [{
          'id' => 'pre-old',
          'type' => 'preReleaseVersions',
          'attributes' => { 'version' => '0.9', 'platform' => 'IOS' }
        }]
      }
      build_id = AppStoreBuildWaitHarness.new(response).send(
        :wait_for_build,
        'app-1', '100', 'IOS', 'token',
        expected_marketing_version: '1.0'
      )
      assert_eq(build_id, nil)
      true
    end

    test('fails closed when ASC omits included pre-release identity') do
      response = {
        'data' => [{
          'id' => 'unbound-build',
          'attributes' => { 'version' => '100', 'processingState' => 'VALID' },
          'relationships' => { 'preReleaseVersion' => { 'data' => { 'id' => 'missing' } } }
        }],
        'included' => []
      }
      build_id = AppStoreBuildWaitHarness.new(response).send(
        :wait_for_build,
        'app-1', '100', 'IOS', 'token',
        expected_marketing_version: '1.0'
      )
      assert_eq(build_id, nil)
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

    test('accepts an accurately documented trial-then-purchase business model') do
      subject.stub_url_status('https://example.com/support', code: 200)
      subject.stub_url_status('https://example.com/privacy', code: 200)

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(
          File.join(dir, 'Dummy.swift'),
          "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nstruct LicenseSettingsView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        )

        config = build_metadata_config(
          review_notes: 'A 14-day Pro trial starts on launch. After the trial, continued app access requires an optional one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.'
        )
        config['appstore']['product_id'] = 'com.example.app.pro'

        report = subject.send(
          :metadata_review_readiness_report,
          config: config,
          asc_platform: 'MAC_OS',
          app_name: 'SaneTest',
          project_root: dir
        )

        assert(!report[:issues].include?('macOS review notes do not fully explain the App Store business model'))
      end
      true
    end

    test('does not treat a bare App Store mention as an explicit purchase path') do
      subject.stub_url_status('https://example.com/support', code: 200)
      subject.stub_url_status('https://example.com/privacy', code: 200)

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(
          File.join(dir, 'Dummy.swift'),
          "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nstruct LicenseSettingsView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        )
        config = build_metadata_config(
          review_notes: 'A 14-day trial is available in this App Store build. After the trial, continued access requires Pro access. No external checkout or license keys are used.'
        )
        config['appstore']['product_id'] = 'com.example.app.pro'

        report = subject.send(
          :metadata_review_readiness_report,
          config: config,
          asc_platform: 'MAC_OS',
          app_name: 'SaneTest',
          project_root: dir
        )

        assert_includes(report[:issues], 'macOS review notes do not fully explain the App Store business model')
      end
      true
    end

    test('rejects negated or contradictory App Store business-model claims') do
      subject.stub_url_status('https://example.com/support', code: 200)
      subject.stub_url_status('https://example.com/privacy', code: 200)

      invalid_notes = [
        'Basic is not free. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        'A 14-day Pro trial starts on launch. The trial is not free. After the trial, continued app access requires a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        'Basic is free. Pro is not an in-app purchase. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        'Basic is free. An App Store in-app purchase is not required. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        'Basic is free. Pro cannot be purchased in the app. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        "Basic is free. Pro isn't available for purchase in the app. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.",
        'Basic is free. Pro is not available for purchase in the app. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used.',
        'Basic is free. Pro is a one-time App Store in-app purchase available in Settings > License. No external checkout or license keys are used. Pro can be purchased through the website.'
      ]

      Dir.mktmpdir('appstore-submit-guardrails') do |dir|
        File.write(
          File.join(dir, 'Dummy.swift'),
          "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nstruct LicenseSettingsView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        )

        invalid_notes.each do |review_notes|
          config = build_metadata_config(review_notes: review_notes)
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
            'macOS review notes do not fully explain the App Store business model',
            "expected rejection for: #{review_notes}"
          )
        end
      end
      true
    end
  end

  test_category('IAP submission guardrails') do
    test('explicit no-IAP policy requires retired subscriptions to be unavailable and detached') do
      product_id = 'com.example.retired.monthly'
      subject.stub_subscription_records([
        {
          'type' => 'subscriptions',
          'id' => 'sub-1',
          'attributes' => {
            'productId' => product_id,
            'state' => 'READY_TO_SUBMIT'
          }
        }
      ])
      subject.stub_iap_records([])
      subject.stub_version_page_includes_iap(false)
      subject.stub_get_status(
        '/subscriptions/sub-1/subscriptionAvailability?include=availableTerritories&limit[availableTerritories]=50',
        200,
        {
          'data' => {
            'attributes' => { 'availableInNewTerritories' => false },
            'relationships' => {
              'availableTerritories' => {
                'meta' => { 'paging' => { 'total' => 0 } },
                'data' => []
              }
            }
          }
        }
      )
      subject.stub_get_status(
        '/reviewSubmissions/review-1/items?include=appStoreVersion&limit=200',
        200,
        {
          'data' => [
            {
              'relationships' => {
                'appStoreVersion' => {
                  'data' => { 'type' => 'appStoreVersions', 'id' => 'version-1' }
                }
              }
            }
          ]
        }
      )

      ok = subject.send(
        :ensure_no_iap_readiness,
        app_id: 'app-1',
        version_id: 'version-1',
        platform: 'ios',
        config: {
          'appstore' => {
            'iap_policy' => 'none',
            'retired_product_ids' => [product_id]
          }
        },
        token: 'stub-jwt',
        linked_submission: { id: 'review-1' }
      )

      assert_eq(ok, true)
      true
    end

    test('explicit no-IAP policy fails when a retired subscription is attached') do
      product_id = 'com.example.retired.monthly'
      subject.stub_subscription_records([
        {
          'type' => 'subscriptions',
          'id' => 'sub-1',
          'attributes' => { 'productId' => product_id }
        }
      ])
      subject.stub_iap_records([])
      subject.stub_version_page_includes_iap(true)
      subject.stub_get_status(
        '/subscriptions/sub-1/subscriptionAvailability?include=availableTerritories&limit[availableTerritories]=50',
        200,
        {
          'data' => {
            'attributes' => { 'availableInNewTerritories' => false },
            'relationships' => {
              'availableTerritories' => {
                'meta' => { 'paging' => { 'total' => 0 } },
                'data' => []
              }
            }
          }
        }
      )

      ok = subject.send(
        :ensure_no_iap_readiness,
        app_id: 'app-1',
        version_id: 'version-1',
        platform: 'ios',
        config: {
          'appstore' => {
            'iap_policy' => 'none',
            'retired_product_ids' => [product_id]
          }
        },
        token: 'stub-jwt'
      )

      assert_eq(ok, false)
      true
    end

    test('explicit no-IAP policy rejects extra App Store products') do
      subject.stub_subscription_records([])
      subject.stub_iap_records([
        {
          'type' => 'inAppPurchases',
          'id' => 'iap-1',
          'attributes' => { 'productId' => 'com.example.unexpected' }
        }
      ])

      ok = subject.send(
        :ensure_no_iap_readiness,
        app_id: 'app-1',
        version_id: 'version-1',
        platform: 'ios',
        config: { 'appstore' => { 'iap_policy' => 'none' } },
        token: 'stub-jwt'
      )

      assert_eq(ok, false)
      true
    end

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
      subject.stub_brave_snapshot(
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

    test('allows first subscription only when Brave proves it is attached to the app version') do
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

    test('first subscription reports unknown when Brave attachment proof is unavailable') do
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
      subject.stub_brave_snapshots([
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
      assert_eq(subject.brave_snapshot_calls.length, 2)
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

  test_category('Obsolete subscription deletion') do
    test('deletes only the exact READY_TO_SUBMIT subscription then its verified-empty group') do
      app_id = 'app-1'
      subscription_id = 'sub-1'
      group_id = 'group-1'
      product_id = 'com.example.monthly'
      group_members_path = "/subscriptionGroups/#{group_id}/subscriptions?limit=200"
      app_groups_path = "/apps/#{app_id}/subscriptionGroups?include=subscriptions&limit=200"
      harness = ObsoleteSubscriptionDeletionHarness.new(
        get_responses: {
          "/subscriptions/#{subscription_id}" => [
            [200, {
              'data' => {
                'id' => subscription_id,
                'type' => 'subscriptions',
                'attributes' => {
                  'name' => 'Example Monthly',
                  'productId' => product_id,
                  'state' => 'READY_TO_SUBMIT'
                }
              }
            }],
            [404, { 'errors' => [] }]
          ],
          "/subscriptions/#{subscription_id}/versions?limit=200" => [[200, { 'data' => [] }]],
          "/subscriptionGroups/#{group_id}" => [
            [200, {
              'data' => {
                'id' => group_id,
                'type' => 'subscriptionGroups',
                'attributes' => { 'referenceName' => 'Example Plans' }
              }
            }],
            [404, { 'errors' => [] }]
          ],
          group_members_path => [
            [200, {
              'data' => [{
                'id' => subscription_id,
                'type' => 'subscriptions',
                'attributes' => { 'productId' => product_id }
              }]
            }],
            [200, { 'data' => [] }]
          ],
          app_groups_path => [
            [200, {
              'data' => [{ 'id' => group_id, 'type' => 'subscriptionGroups' }],
              'included' => [{ 'id' => subscription_id, 'type' => 'subscriptions' }]
            }],
            [200, { 'data' => [], 'included' => [] }]
          ]
        },
        delete_responses: {
          "/subscriptions/#{subscription_id}" => [[204, { 'raw' => '' }]],
          "/subscriptionGroups/#{group_id}" => [[204, { 'raw' => '' }]]
        }
      )

      result = harness.send(
        :delete_obsolete_draft_subscription_and_group,
        app_id: app_id,
        subscription_id: subscription_id,
        group_id: group_id,
        expected_product_id: product_id,
        expected_name: 'Example Monthly',
        token: 'token'
      )

      assert_eq(
        harness.delete_paths,
        ["/subscriptions/#{subscription_id}", "/subscriptionGroups/#{group_id}"]
      )
      assert_eq(result[:subscription_readback_http], 404)
      assert_eq(result[:group_readback_http], 404)
      true
    end

    test('refuses deletion when the live product identity does not match') do
      harness = ObsoleteSubscriptionDeletionHarness.new(
        get_responses: {
          '/subscriptions/sub-1' => [[200, {
            'data' => {
              'id' => 'sub-1',
              'type' => 'subscriptions',
              'attributes' => {
                'name' => 'Example Monthly',
                'productId' => 'com.example.different',
                'state' => 'READY_TO_SUBMIT'
              }
            }
          }]]
        },
        delete_responses: {}
      )

      begin
        harness.send(
          :delete_obsolete_draft_subscription_and_group,
          app_id: 'app-1',
          subscription_id: 'sub-1',
          group_id: 'group-1',
          expected_product_id: 'com.example.monthly',
          expected_name: 'Example Monthly',
          token: 'token'
        )
        assert(false, 'expected product mismatch to block deletion')
      rescue StandardError => e
        assert_includes(e.message, 'identity/state mismatch')
      end

      assert_eq(harness.delete_paths, [])
      true
    end

    test('refuses group deletion when the group contains any additional subscription') do
      group_members_path = '/subscriptionGroups/group-1/subscriptions?limit=200'
      harness = ObsoleteSubscriptionDeletionHarness.new(
        get_responses: {
          '/subscriptions/sub-1' => [[200, {
            'data' => {
              'id' => 'sub-1',
              'type' => 'subscriptions',
              'attributes' => {
                'name' => 'Example Monthly',
                'productId' => 'com.example.monthly',
                'state' => 'READY_TO_SUBMIT'
              }
            }
          }]],
          '/subscriptions/sub-1/versions?limit=200' => [[200, { 'data' => [] }]],
          '/subscriptionGroups/group-1' => [[200, {
            'data' => { 'id' => 'group-1', 'type' => 'subscriptionGroups' }
          }]],
          group_members_path => [[200, {
            'data' => [
              {
                'id' => 'sub-1',
                'type' => 'subscriptions',
                'attributes' => { 'productId' => 'com.example.monthly' }
              },
              {
                'id' => 'sub-2',
                'type' => 'subscriptions',
                'attributes' => { 'productId' => 'com.example.annual' }
              }
            ]
          }]]
        },
        delete_responses: {}
      )

      begin
        harness.send(
          :delete_obsolete_draft_subscription_and_group,
          app_id: 'app-1',
          subscription_id: 'sub-1',
          group_id: 'group-1',
          expected_product_id: 'com.example.monthly',
          expected_name: 'Example Monthly',
          token: 'token'
        )
        assert(false, 'expected extra group member to block deletion')
      rescue StandardError => e
        assert_includes(e.message, 'must contain only subscription')
      end

      assert_eq(harness.delete_paths, [])
      true
    end

    test('refuses API deletion for a Developer Rejected subscription version') do
      harness = ObsoleteSubscriptionDeletionHarness.new(
        get_responses: {
          '/subscriptions/sub-1' => [[200, {
            'data' => {
              'id' => 'sub-1',
              'type' => 'subscriptions',
              'attributes' => {
                'name' => 'Example Monthly',
                'productId' => 'com.example.monthly',
                'state' => 'READY_TO_SUBMIT'
              }
            }
          }]],
          '/subscriptions/sub-1/versions?limit=200' => [[200, {
            'data' => [{
              'id' => 'version-1',
              'type' => 'subscriptionVersions',
              'attributes' => { 'state' => 'DEVELOPER_REJECTED' }
            }]
          }]]
        },
        delete_responses: {}
      )

      begin
        harness.send(
          :delete_obsolete_draft_subscription_and_group,
          app_id: 'app-1',
          subscription_id: 'sub-1',
          group_id: 'group-1',
          expected_product_id: 'com.example.monthly',
          expected_name: 'Example Monthly',
          token: 'token'
        )
        assert(false, 'expected Developer Rejected subscription to block permanent deletion')
      rescue StandardError => e
        assert_includes(e.message, 'DEVELOPER_REJECTED')
        assert_includes(e.message, 'remove it from sale')
      end

      assert_eq(harness.delete_paths, [])
      true
    end
  end

  test_category('Review package capture') do
    test('production adapter is Brave-only and requires an existing ASC tab') do
      source = File.read(File.expand_path('appstore_submit.rb', __dir__))

      assert_includes(source, 'tell application "Brave Browser"')
      assert_includes(source, 'Brave Browser has no open App Store Connect tab.')
      assert(!source.match?(/tell\s+application\s+["']Safari["']/i), 'App Store submitter must not embed Safari')
      true
    end

    test('fails closed when Brave returns an authentication page') do
      harness = BraveSnapshotGuardHarness.new(
        'url' => 'https://appstoreconnect.apple.com/',
        'body' => 'authResult=FAILED Sign In with your Apple Account'
      )
      begin
        harness.send(:brave_page_snapshot, url: 'https://appstoreconnect.apple.com/apps/123')
        assert(false, 'expected expired Brave auth to fail closed')
      rescue StandardError => e
        assert_includes(e.message, 'authentication is expired')
      end
      true
    end

    test('fails closed when Brave returns a non-ASC host') do
      harness = BraveSnapshotGuardHarness.new(
        'url' => 'https://idmsa.apple.com/appleauth/auth/signin',
        'body' => 'Sign In'
      )
      begin
        harness.send(:brave_page_snapshot, url: 'https://appstoreconnect.apple.com/apps/123')
        assert(false, 'expected wrong Brave host to fail closed')
      rescue StandardError => e
        assert_includes(e.message, 'unexpected App Store Connect URL')
      end
      true
    end

    test('fails closed when Brave returns malformed download metadata') do
      harness = BraveRawResultHarness.new('not-json')
      begin
        harness.send(:click_review_downloads_in_brave, app_id: '123', submission_id: 'sub-1')
        assert(false, 'expected malformed Brave download metadata to fail closed')
      rescue StandardError => e
        assert_includes(e.message, 'invalid App Review download metadata')
      end
      true
    end

    test('polls the review page without renavigating after the first Brave load') do
      subject.stub_brave_snapshots(
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
        :fetch_review_message_from_brave,
        app_id: '123',
        submission_id: 'sub-1'
      )

      assert_includes(review_text, 'Messages (1)')
      assert_eq(subject.brave_snapshot_calls.length, 2)
      assert_eq(subject.brave_snapshot_calls[0][:navigate], true)
      assert_eq(subject.brave_snapshot_calls[1][:navigate], false)
      true
    end

    test('does not accept a submission header without the actual reviewer message') do
      subject.stub_brave_snapshots(
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
        :fetch_review_message_from_brave,
        app_id: '123',
        submission_id: 'sub-1'
      )

      assert_includes(review_text, 'Hello,')
      assert_eq(subject.brave_snapshot_calls.length, 2)
      true
    end

    test('captures review evidence and copies downloaded attachments') do
      subject.stub_brave_snapshot(
        'url' => 'https://appstoreconnect.apple.com/apps/123/distribution/reviewsubmissions/details/sub-1',
        'body' => "Messages (1)\nApple\nHello,\nGuideline 2.4.5(vii)\n"
      )
      subject.stub_brave_javascript(
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
          :fetch_review_package_from_brave,
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
      subject.stub_brave_javascript(
        [
          JSON.generate('action' => 'clicked', 'remainingBefore' => 2),
          JSON.generate('action' => 'clicked', 'remainingBefore' => 1),
          JSON.generate('action' => 'none', 'remaining' => 0, 'body' => "App Review\nDraft Submissions (0)\n")
        ]
      )

      result = subject.send(:delete_empty_draft_submissions_from_brave, app_id: '123')

      assert_eq(result[:deleted_count], 2)
      assert_eq(result[:remaining_count], 0)
      assert_eq(subject.brave_snapshot_calls.length, 3)
      assert_eq(subject.brave_snapshot_calls[0][:navigate], true)
      assert_eq(subject.brave_snapshot_calls[1][:navigate], false)
      assert_eq(subject.brave_snapshot_calls[2][:navigate], false)
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
