#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

ENV['CLAUDE_HOOK_SECRET'] ||= 'release-readiness-test-secret'

require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

TEST_RELEASE_RECEIPT_SIGNER = ReleaseReceiptSigner.test_signer(secret: 'release-readiness-test-secret')

class ReleaseReadinessHarness < SaneMaster
  attr_writer :apps_root

  def release_readiness_apps_root
    @apps_root
  end

  def release_readiness_receipt_signer
    TEST_RELEASE_RECEIPT_SIGNER
  end
end

include TestFramework

def init_release_readiness_app(root, name, preflight:, qa: nil, dirty: false)
  app = File.join(root, name)
  FileUtils.mkdir_p(File.join(app, 'outputs'))
  File.write(File.join(app, '.saneprocess'), "name: #{name}\n")
  File.write(File.join(app, 'README.md'), "#{name}\n")
  preflight = preflight.merge('type' => 'release_preflight_status')
  TEST_RELEASE_RECEIPT_SIGNER.write(
    File.join(app, 'outputs', 'release_preflight_status.json'),
    preflight.dup,
    producer: 'saneprocess.release_preflight.v1'
  )
  File.write(File.join(app, 'outputs', 'qa_status.json'), JSON.pretty_generate(qa)) if qa

  system('git', '-C', app, 'init', '-q')
  system('git', '-C', app, 'config', 'user.email', 'test@example.invalid')
  system('git', '-C', app, 'config', 'user.name', 'SaneProcess Test')
  system('git', '-C', app, 'add', '.')
  system('git', '-C', app, 'commit', '-q', '-m', 'fixture')
  if preflight['sourceFingerprint'] == '__CURRENT__'
    harness = ReleaseReadinessHarness.new
    preflight = preflight.merge('sourceFingerprint' => harness.send(:release_status_source_fingerprint, app))
    TEST_RELEASE_RECEIPT_SIGNER.write(
      File.join(app, 'outputs', 'release_preflight_status.json'),
      preflight,
      producer: 'saneprocess.release_preflight.v1'
    )
  end
  File.write(File.join(app, 'dirty.txt'), "dirty\n") if dirty
  app
end

exit(run_tests('SaneMaster Release Readiness Tests') do
  test_category('release readiness report') do
    test('separates candidate blockers from portfolio health blockers') do
      Dir.mktmpdir('release-readiness-') do |root|
        init_release_readiness_app(
          root,
          'SaneExample',
          dirty: true,
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'failed',
            'issues' => [
              'Project QA policy guardrails failed (Scripts/qa.rb)',
              'Customer UI action contract: Receipt source fingerprint is stale'
            ],
            'warningCount' => 1
          },
          qa: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'failed',
            'policyOnlyMode' => true,
            'errors' => ['Release cadence guard: 18.9h since v2.1.70 (<24h).']
          }
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')
        app_report = report[:apps].first

        assert_eq(report.dig(:summary, :ready), false)
        assert_eq(report.dig(:summary, :candidate_ready), false)
        assert_eq(report.dig(:summary, :portfolio_ok), false)
        assert(app_report.dig(:candidate_readiness, :blockers).any? { |item| item.include?('Project QA policy') })
        assert(app_report.dig(:candidate_readiness, :blockers).any? { |item| item.include?('policy QA: Release cadence') })
        assert(app_report.dig(:portfolio_health, :blockers).any? { |item| item.include?('customer UI proof') })
        assert_eq(app_report.dig(:git, :dirty), true)
      end
      true
    end

    test('reports a clean passing candidate as ready') do
      Dir.mktmpdir('release-readiness-') do |root|
        init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '__CURRENT__',
            'issues' => [],
            'warningCount' => 0
          },
          qa: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'policyOnlyMode' => false
          }
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')

        assert_eq(report.dig(:summary, :ready), true)
        assert_eq(report.dig(:summary, :candidate_ready), true)
        assert_eq(report.dig(:summary, :portfolio_ok), true)
        assert_eq(report.dig(:apps, 0, :candidate_readiness, :status), 'ready')
        assert(report.dig(:apps, 0, :portfolio_health, :blockers).empty?)
      end
      true
    end

    test('blocks candidate readiness when release_preflight source fingerprint is stale') do
      Dir.mktmpdir('release-readiness-stale-') do |root|
        init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '0' * 64,
            'issues' => [],
            'warningCount' => 0
          }
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')
        blockers = report.dig(:apps, 0, :candidate_readiness, :blockers)

        assert_eq(report.dig(:summary, :ready), false)
        assert(blockers.any? { |item| item.include?('release_preflight source fingerprint is stale') })
      end
      true
    end

    test('stale failed release_preflight reports freshness instead of obsolete issues') do
      Dir.mktmpdir('release-readiness-stale-failed-') do |root|
        init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'failed',
            'sourceFingerprint' => '0' * 64,
            'issues' => ['Project QA guardrails failed (Scripts/qa.rb)'],
            'warningCount' => 0
          },
          qa: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed_with_warnings',
            'policyOnlyMode' => false,
            'warningCount' => 6
          }
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')
        blockers = report.dig(:apps, 0, :candidate_readiness, :blockers)

        assert(blockers.any? { |item| item.include?('release_preflight source fingerprint is stale') })
        assert(!blockers.any? { |item| item.include?('Project QA guardrails failed') })
      end
      true
    end

    test('blocks candidate readiness when release_preflight receipt is too old') do
      Dir.mktmpdir('release-readiness-old-preflight-') do |root|
        init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => (Time.now.utc - (7 * 60 * 60)).iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '__CURRENT__',
            'issues' => [],
            'warningCount' => 0
          }
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')
        blockers = report.dig(:apps, 0, :candidate_readiness, :blockers)

        assert_eq(report.dig(:summary, :ready), false)
        assert(blockers.any? { |item| item.include?('release_preflight receipt is stale') })
      end
      true
    end

    test('blocks candidate readiness when underlying customer UI receipt is stale') do
      Dir.mktmpdir('release-readiness-stale-ui-', File.realpath(Dir.tmpdir)) do |root|
        app = init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '__CURRENT__',
            'issues' => [],
            'warningCount' => 0
          }
        )
        FileUtils.mkdir_p(File.join(app, 'Tests'))
        File.write(File.join(app, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneExample\nactions: []\n")
        File.write(
          File.join(app, 'outputs', 'customer_ui_action_receipt.json'),
          JSON.pretty_generate('generated_at' => (Time.now.utc - 13 * 60 * 60).iso8601)
        )
        preflight_path = File.join(app, 'outputs', 'release_preflight_status.json')
        preflight_payload = JSON.parse(File.read(preflight_path))
        preflight_payload['sourceFingerprint'] = ReleaseReadinessHarness.new.send(:release_status_source_fingerprint, app)
        TEST_RELEASE_RECEIPT_SIGNER.write(
          preflight_path,
          preflight_payload,
          producer: 'saneprocess.release_preflight.v1'
        )

        subject = ReleaseReadinessHarness.new
        subject.apps_root = root
        report = subject.send(:release_readiness_report, app: 'SaneExample', scope: 'candidate')
        blockers = report.dig(:apps, 0, :candidate_readiness, :blockers)

        assert_eq(report.dig(:summary, :ready), false)
        assert(blockers.any? { |item| item.include?('customer UI receipt is stale') })
      end
      true
    end

    test('candidate freshness fingerprint includes shared SaneProcess harness source') do
      Dir.mktmpdir('release-readiness-harness-fingerprint-') do |root|
        app = init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '__CURRENT__',
            'issues' => [],
            'warningCount' => 0
          }
        )

        subject = ReleaseReadinessHarness.new
        entries = subject.send(:release_status_source_entries, app)
        digest_paths = entries.map { |entry| entry[:digest_path] }

        assert(digest_paths.any? { |path| path == 'SaneProcess/scripts/sanemaster/release.rb' })
        assert(digest_paths.any? { |path| path == 'SaneProcess/scripts/sanemaster/release_readiness.rb' })
        assert(digest_paths.any? { |path| path == 'SaneProcess/scripts/release.sh' })
      end
      true
    end

    test('rejects malformed CLI arguments instead of changing scope silently') do
      subject = ReleaseReadinessHarness.new

      [
        ['--app'],
        ['--app', '--json'],
        ['--app='],
        ['--scope'],
        ['--scope', '--json'],
        ['--scope='],
        ['--scope', 'banana'],
        ['--scope=banana']
      ].each do |args|
        begin
          subject.send(:parse_release_readiness_args, args)
          raise "expected #{args.inspect} to fail"
        rescue ArgumentError
          next
        end
      end

      true
    end

    test('SaneMaster release_readiness CLI rejects test-only signatures and keeps JSON parseable') do
      Dir.mktmpdir('release-readiness-cli-') do |root|
        app = init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
            'sourceFingerprint' => '__CURRENT__',
            'issues' => [],
            'warningCount' => 0
          }
        )

        script = File.expand_path('../SaneMaster.rb', __dir__)
        stdout, stderr, status = Open3.capture3(
          { 'SANEMASTER_DISABLE_MINI_ROUTING' => '1' },
          'ruby',
          script,
          'release_readiness',
          '--json',
          chdir: app
        )

        parsed = JSON.parse(stdout)
        assert(!status.success?, 'production CLI must reject a test-mode release authorization receipt')
        assert_eq(parsed.dig('summary', 'ready'), false)
        blockers = parsed.dig('apps', 0, 'candidate_readiness', 'blockers') || []
        assert(blockers.any? { |item| item.include?('release_preflight receipt missing') })
        assert(stdout.lstrip.start_with?('{'), 'JSON stdout should not be prefixed by commentary')
      end
      true
    end

    test('Mini routing sends JSON-mode route commentary through route_log') do
      source = File.read(File.expand_path('../SaneMaster.rb', __dir__))
      assert_includes(source, '@route_logs_to_stderr = machine_json_output_requested?(args)')
      assert_includes(source, 'def route_log(message)')
      assert_includes(source, 'warn message')
      assert_includes(source, 'route_log("📍 Mini-first routing: #{command} -> mini (#{execution_repo})")')
      assert(!source.include?('puts "📍 Mini-first routing: #{command} -> mini'), 'Mini routing banner must not use stdout directly')
      assert(!source.include?('puts "🔄 Syncing local workspace snapshot to mini'), 'Mini sync banner must not use stdout directly')
      true
    end
  end
end)
