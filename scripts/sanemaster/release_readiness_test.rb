#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative '../SaneMaster'

class ReleaseReadinessHarness < SaneMaster
  attr_writer :apps_root

  def release_readiness_apps_root
    @apps_root
  end
end

include TestFramework

def init_release_readiness_app(root, name, preflight:, qa: nil, dirty: false)
  app = File.join(root, name)
  FileUtils.mkdir_p(File.join(app, 'outputs'))
  File.write(File.join(app, '.saneprocess'), "name: #{name}\n")
  File.write(File.join(app, 'README.md'), "#{name}\n")
  File.write(File.join(app, 'outputs', 'release_preflight_status.json'), JSON.pretty_generate(preflight))
  File.write(File.join(app, 'outputs', 'qa_status.json'), JSON.pretty_generate(qa)) if qa

  system('git', '-C', app, 'init', '-q')
  system('git', '-C', app, 'config', 'user.email', 'test@example.invalid')
  system('git', '-C', app, 'config', 'user.name', 'SaneProcess Test')
  system('git', '-C', app, 'add', '.')
  system('git', '-C', app, 'commit', '-q', '-m', 'fixture')
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

    test('SaneMaster release_readiness --json prints parseable JSON in local mode') do
      Dir.mktmpdir('release-readiness-cli-') do |root|
        app = init_release_readiness_app(
          root,
          'SaneExample',
          preflight: {
            'generatedAt' => Time.now.utc.iso8601,
            'status' => 'passed',
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
        assert(status.success?, "expected green candidate exit 0, got stderr=#{stderr.inspect}")
        assert_eq(parsed.dig('summary', 'ready'), true)
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
