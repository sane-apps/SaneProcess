#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'validation_report'
require 'tmpdir'

class ValidationReportHarness < ValidationReport
  attr_reader :issues, :warnings, :metrics, :verdict

  def initialize(products:, appcast_versions:, website_versions:, webhook_versions:, cask_versions:, lemonsqueezy_snapshot:)
    super()
    @products = products
    @appcast_versions = appcast_versions
    @website_versions = website_versions
    @webhook_versions = webhook_versions
    @cask_versions = cask_versions
    @lemonsqueezy_snapshot = lemonsqueezy_snapshot
    @metrics[:release_integrity] = { issues: 0 }
    @metrics[:website_distribution] = { issues: 0 }
    @metrics[:code_signing] = { issues: 0 }
  end

  def released_product_definitions
    @products
  end

  def fetch_live_email_worker_snapshot
    {
      'products' => @webhook_versions.each_with_object({}) do |(name, version), snapshot|
        snapshot[name] = { 'version' => version }
      end
    }
  end

  def fetch_live_lemonsqueezy_hosted_versions
    @lemonsqueezy_snapshot
  end

  def fetch_homebrew_cask_body(slug)
    version = @cask_versions[slug]
    version ? %(cask "#{slug}" do\n  version "#{version}"\nend\n) : ''
  end

  def fetch_url_text(url, headers: {})
    case url
    when /\/appcast\.xml\z/
      domain = URI(url).host
      version = @appcast_versions.fetch(domain)
      %(<?xml version="1.0"?><rss><channel><item sparkle:shortVersionString="#{version}"></item></channel></rss>)
    else
      domain = URI(url).host
      version = @website_versions[domain]
      app_name = @products.find { |product| product[:domain] == domain }[:name]
      version ? %(<a href="https://dist.#{domain}/updates/#{app_name}-#{version}.zip">Download</a>) : ''
    end
  end
end

class HostedVersionSnapshotHarness < ValidationReport
  def initialize(products:, products_response:, variants_response:, files_response:)
    super()
    @products = products
    @products_response = products_response
    @variants_response = variants_response
    @files_response = files_response
  end

  def released_product_definitions
    @products
  end

  def resolve_secret_value(_service, _account, _env_name)
    'token'
  end

  def fetch_lemonsqueezy_collection(path, _api_key)
    return @products_response if path == '/v1/products?page[size]=100'
    return @variants_response if path == '/v1/variants?page[size]=100'

    @files_response.fetch(path)
  end
end

class DownloadRedirectValidationHarness < ValidationReport
  def initialize(resolved: {}, landing_pages: {}, ok_links: [])
    super()
    @resolved = resolved
    @landing_pages = landing_pages
    @ok_links = ok_links
  end

  def link_resolves_to_live_release?(link, expected_name)
    @resolved[link] == expected_name
  end

  def fetch_url_text(link)
    @landing_pages[link].to_s
  end

  def link_status_ok?(link)
    @ok_links.include?(link)
  end
end

class SisterAppsHarness < ValidationReport
  attr_reader :metrics

  def initialize(root:, projects:, products:)
    super()
    @root = root
    @projects = projects
    @products = products
  end

  def sane_apps_root
    @root
  end

  def validation_projects
    @projects
  end

  def product_definitions
    @products
  end
end

class WorkflowPolicyHarness < ValidationReport
  def initialize(root:, workflow_exceptions: nil)
    super()
    @root = root
    @workflow_exceptions = workflow_exceptions
  end

  def sane_apps_root
    @root
  end

  def github_workflow_exceptions
    @workflow_exceptions || super
  end
end

class ProcessMetricsValidationHarness < ValidationReport
  attr_reader :metrics, :warnings

  def initialize(events)
    super()
    @events = events
  end

  def process_metric_events(type: nil)
    return @events unless type

    @events.select { |event| event['type'] == type.to_s }
  end
end

include TestFramework

def product_definition(name, slug:, domain:)
  { name: name, slug: slug, domain: domain, project_exists: true }
end

exit(run_tests('Validation report tests') do
  test_category('Q11 cross-channel drift classification') do
    test('treats hosted-file drift as dashboard action instead of critical pipeline break') do
      products = [product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com')]
      subject = ValidationReportHarness.new(
        products: products,
        appcast_versions: { 'sanebar.com' => '2.1.39' },
        website_versions: { 'sanebar.com' => '2.1.39' },
        webhook_versions: { 'SaneBar' => '2.1.39' },
        cask_versions: { 'sanebar' => '2.1.39' },
        lemonsqueezy_snapshot: {
          'SaneBar' => {
            'filename' => 'SaneBar-2.1.36.zip',
            'version' => '2.1.36',
            'product_id' => '123',
            'product_slug' => 'sanebar',
            'variant_id' => '456'
          }
        }
      )

      subject.send(:q11_cross_channel_version_consistency)
      subject.send(:calculate_final_verdict)

      assert_eq(subject.metrics[:cross_channel_consistency][:canonical_issues], 0)
      assert_eq(subject.metrics[:cross_channel_consistency][:hosted_file_actions], 1)
      assert_eq(subject.verdict[:status], 'NEEDS DASHBOARD SYNC')
      assert(subject.issues.grep(/Q11 DRIFT:/).empty?, 'hosted-file drift should not be recorded as a critical issue')
      assert(subject.warnings.any? { |warning| warning.include?('Q11 HOSTED FILE ACTION: [SaneBar]') })
      true
    end

    test('keeps website drift as a broken release pipeline issue') do
      products = [product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com')]
      subject = ValidationReportHarness.new(
        products: products,
        appcast_versions: { 'sanebar.com' => '2.1.39' },
        website_versions: { 'sanebar.com' => '2.1.38' },
        webhook_versions: { 'SaneBar' => '2.1.39' },
        cask_versions: { 'sanebar' => '2.1.39' },
        lemonsqueezy_snapshot: {
          'SaneBar' => {
            'filename' => 'SaneBar-2.1.39.zip',
            'version' => '2.1.39'
          }
        }
      )

      subject.send(:q11_cross_channel_version_consistency)
      subject.send(:calculate_final_verdict)

      assert_eq(subject.metrics[:cross_channel_consistency][:canonical_issues], 1)
      assert_eq(subject.metrics[:cross_channel_consistency][:hosted_file_actions], 0)
      assert_eq(subject.verdict[:status], 'BROKEN RELEASE PIPELINE')
      assert(subject.issues.any? { |issue| issue.include?('Website download link') })
      true
    end
  end

  test_category('Lemon Squeezy hosted snapshot enrichment') do
    test('captures product and variant references for hosted-file action follow-up') do
      subject = HostedVersionSnapshotHarness.new(
        products: [product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com')],
        products_response: [
          {
            'id' => '123',
            'attributes' => {
              'name' => 'SaneBar',
              'slug' => 'sanebar'
            }
          }
        ],
        variants_response: [
          {
            'id' => '456',
            'attributes' => {
              'product_id' => 123
            }
          }
        ],
        files_response: {
          '/v1/variants/456/files?page[size]=100' => [
            {
              'attributes' => {
                'status' => 'published',
                'name' => 'SaneBar-2.1.36.zip'
              }
            }
          ]
        }
      )

      snapshot = subject.send(:fetch_live_lemonsqueezy_hosted_versions)

      assert_eq(snapshot['SaneBar']['filename'], 'SaneBar-2.1.36.zip')
      assert_eq(snapshot['SaneBar']['version'], '2.1.36')
      assert_eq(snapshot['SaneBar']['product_id'], '123')
      assert_eq(snapshot['SaneBar']['product_slug'], 'sanebar')
      assert_eq(snapshot['SaneBar']['variant_id'], '456')
      true
    end
  end

  test_category('Q0 sister app list checks') do
    test('skips private local CLAUDE files when checking sister app completeness') do
      Dir.mktmpdir('validation-report-sister-apps') do |tmpdir|
        infra_dir = File.join(tmpdir, 'infra/SaneProcess')
        app_dir = File.join(tmpdir, 'apps/SaneBar')
        FileUtils.mkdir_p(infra_dir)
        FileUtils.mkdir_p(app_dir)

        File.write(
          File.join(infra_dir, 'CLAUDE.md'),
          <<~MD
            # SaneProcess - Claude Code Instructions (PRIVATE / LOCAL ONLY)
            This file is private to your local environment and is intentionally not tracked in git.
            Public guidance lives in `CLAUDE_PUBLIC.md`.
            **Apps using this:** SaneBar
          MD
        )

        File.write(
          File.join(app_dir, 'CLAUDE.md'),
          '**Sister apps:** SaneClip, SaneVideo, SaneSync, SaneHosts, SaneAI, SaneClick, SaneSales'
        )

        subject = SisterAppsHarness.new(
          root: tmpdir,
          projects: ['infra/SaneProcess', 'apps/SaneBar'],
          products: [
            product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com'),
            product_definition('SaneClip', slug: 'saneclip', domain: 'saneclip.com'),
            product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com'),
            product_definition('SaneSync', slug: 'sanesync', domain: 'sanesync.com'),
            product_definition('SaneHosts', slug: 'sanehosts', domain: 'sanehosts.com'),
            product_definition('SaneClick', slug: 'saneclick', domain: 'saneclick.com'),
            product_definition('SaneAI', slug: 'saneai', domain: 'saneai.com'),
            product_definition('SaneSales', slug: 'sanesales', domain: 'sanesales.com')
          ]
        )

        issues = []
        subject.send(:check_sister_apps_lists, issues)

        assert_eq(issues, [])
      end

      true
    end
  end

  test_category('Q0 GitHub workflow policy checks') do
    test('flags automatic GitHub workflow triggers without an explicit exception') do
      Dir.mktmpdir('validation-report-workflow-policy') do |tmpdir|
        workflow_dir = File.join(tmpdir, 'apps/SaneBar/.github/workflows')
        FileUtils.mkdir_p(workflow_dir)
        File.write(
          File.join(workflow_dir, 'ci.yml'),
          <<~YAML
            name: CI
            on:
              push:
                branches: [main]
              workflow_dispatch:
            jobs:
              verify:
                runs-on: macos-latest
                steps:
                  - run: echo hi
          YAML
        )

        subject = WorkflowPolicyHarness.new(root: tmpdir)
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues.length, 1)
        assert(issues.first.include?('automatic GitHub triggers (push)'))
      end

      true
    end

    test('allows manual-only workflows') do
      Dir.mktmpdir('validation-report-workflow-manual') do |tmpdir|
        workflow_dir = File.join(tmpdir, 'mcp/Sane-Mem/.github/workflows')
        FileUtils.mkdir_p(workflow_dir)
        File.write(
          File.join(workflow_dir, 'summary.yml'),
          <<~YAML
            name: Summary
            on:
              workflow_dispatch:
                inputs:
                  issue_number:
                    required: true
                    type: number
            jobs:
              summary:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
          YAML
        )

        subject = WorkflowPolicyHarness.new(root: tmpdir)
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues, [])
      end

      true
    end

    test('allows documented hosted exceptions') do
      Dir.mktmpdir('validation-report-workflow-exception') do |tmpdir|
        workflow_dir = File.join(tmpdir, 'infra/SaneProcess/.github/workflows')
        FileUtils.mkdir_p(workflow_dir)
        File.write(
          File.join(workflow_dir, 'nightly.yml'),
          <<~YAML
            # SANEAPPS_GITHUB_HOSTED_EXCEPTION: required for externally visible nightly artifact publication
            name: Nightly
            on:
              schedule:
                - cron: "0 3 * * *"
            jobs:
              nightly:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
          YAML
        )

        subject = WorkflowPolicyHarness.new(root: tmpdir)
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues, [])
      end

      true
    end

    test('allows central hosted workflow exceptions with reasons') do
      Dir.mktmpdir('validation-report-workflow-central-exception') do |tmpdir|
        workflow_dir = File.join(tmpdir, 'mcp/Sane-AppleDocs/.github/workflows')
        FileUtils.mkdir_p(workflow_dir)
        File.write(
          File.join(workflow_dir, 'ci.yml'),
          <<~YAML
            name: CI
            on:
              push:
                branches: [main]
              pull_request:
            jobs:
              verify:
                runs-on: macos-latest
                steps:
                  - run: echo hi
          YAML
        )

        subject = WorkflowPolicyHarness.new(
          root: tmpdir,
          workflow_exceptions: {
            'repositories' => {
              'mcp/Sane-AppleDocs' => {
                'workflows' => {
                  'ci.yml' => { 'reason' => 'Public MCP repo needs hosted CI for contributors.' }
                }
              }
            }
          }
        )
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues, [])
      end

      true
    end

    test('flags repo-level dependabot automation and covers web repos too') do
      Dir.mktmpdir('validation-report-dependabot') do |tmpdir|
        github_dir = File.join(tmpdir, 'web/saneapps.com/.github')
        FileUtils.mkdir_p(github_dir)
        File.write(
          File.join(github_dir, 'dependabot.yml'),
          <<~YAML
            version: 2
            updates:
              - package-ecosystem: "npm"
                directory: "/"
                schedule:
                  interval: "weekly"
          YAML
        )

        subject = WorkflowPolicyHarness.new(root: tmpdir)
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues.length, 1)
        assert(issues.first.include?('dependabot.yml enables automatic GitHub dependency PR automation'))
      end

      true
    end

    test('allows documented dependabot exceptions') do
      Dir.mktmpdir('validation-report-dependabot-exception') do |tmpdir|
        github_dir = File.join(tmpdir, 'apps/SaneBar/.github')
        FileUtils.mkdir_p(github_dir)
        File.write(
          File.join(github_dir, 'dependabot.yml'),
          <<~YAML
            # SANEAPPS_GITHUB_HOSTED_EXCEPTION: temporary external dependency audit while local sweep is being replaced
            version: 2
            updates:
              - package-ecosystem: "bundler"
                directory: "/"
                schedule:
                  interval: "weekly"
          YAML
        )

        subject = WorkflowPolicyHarness.new(root: tmpdir)
        issues = []
        subject.send(:check_github_workflow_policy, issues)

        assert_eq(issues, [])
      end

      true
    end
  end

  test_category('Q10 context size checks') do
    test('flags bloated active context files before instructions silently degrade') do
      Dir.mktmpdir('validation-report-context-size') do |tmpdir|
        File.write(File.join(tmpdir, 'AGENTS.md'), ("short instruction\n" * 451))
        File.write(File.join(tmpdir, 'SESSION_HANDOFF.md'), ("old session\n" * 801))
        FileUtils.mkdir_p(File.join(tmpdir, '.claude'))
        File.write(File.join(tmpdir, '.claude', 'research.md'), ("verified finding\n" * 201))

        subject = ValidationReport.new
        issues = []
        warnings = []
        subject.send(:check_context_file_sizes, tmpdir, 'SaneProcess', issues, warnings)

        assert(warnings.any? { |warning| warning.include?('AGENTS.md') && warning.include?('nearing Codex') })
        assert(issues.any? { |issue| issue.include?('.claude/research.md is 201 lines') })
        assert(issues.any? { |issue| issue.include?('SESSION_HANDOFF.md is 801 lines') })
      end

      true
    end

    test('checks non-product validation projects such as SaneProcess') do
      Dir.mktmpdir('validation-report-context-projects') do |tmpdir|
        process_dir = File.join(tmpdir, 'infra/SaneProcess')
        FileUtils.mkdir_p(process_dir)
        File.write(File.join(process_dir, 'SESSION_HANDOFF.md'), ("old session\n" * 801))

        subject = SisterAppsHarness.new(root: tmpdir, projects: ['infra/SaneProcess'], products: [])
        subject.send(:q10_documentation_currency)

        assert(subject.metrics[:documentation_currency][:details].any? do |detail|
          detail.include?('[SaneProcess] SESSION_HANDOFF.md is 801 lines')
        end)
      end

      true
    end
  end

  test_category('Q4 process metrics') do
    test('reports verify attempt churn separately from final grouped outcomes') do
      subject = ProcessMetricsValidationHarness.new(
        [
          { 'type' => 'verify', 'success' => false, 'tests_run' => 0, 'timestamp' => '2026-05-04T10:00:00Z', 'project' => 'SaneBar' },
          { 'type' => 'verify', 'success' => true, 'tests_run' => 10, 'timestamp' => '2026-05-04T10:05:00Z', 'project' => 'SaneBar' },
          { 'type' => 'verify', 'success' => false, 'tests_run' => 9, 'timestamp' => '2026-05-04T10:10:00Z', 'project' => 'SaneClip' },
          { 'type' => 'gate_review', 'success' => true, 'timestamp' => '2026-05-04T10:11:00Z', 'project' => 'SaneClip' }
        ]
      )

      subject.send(:q4_test_outcomes)

      assert_eq(subject.metrics[:test_outcomes][:process_metric_verify_attempts], 3)
      assert_eq(subject.metrics[:test_outcomes][:process_metric_verify_passes], 1)
      assert_eq(subject.metrics[:test_outcomes][:verify_attempt_pass_rate], 33.3)
      assert_eq(subject.metrics[:test_outcomes][:verify_zero_test_failures], 1)
      assert_eq(subject.metrics[:test_outcomes][:day_project_final_verify_groups], 2)
      assert_eq(subject.metrics[:test_outcomes][:day_project_final_verify_pass_rate], 50.0)
      true
    end

    test('summarizes session quality from session_end metrics') do
      subject = ProcessMetricsValidationHarness.new(
        [
          { 'type' => 'session_end', 'success' => true, 'sop_score' => 10, 'edits' => 2, 'verify_failures' => 0, 'timestamp' => '2026-05-04T10:00:00Z' },
          { 'type' => 'session_end', 'success' => true, 'sop_score' => 8, 'edits' => 4, 'verify_failures' => 1, 'timestamp' => '2026-05-04T11:00:00Z' },
          { 'type' => 'session_end', 'success' => false, 'sop_score' => 6, 'edits' => 1, 'verify_failures' => 1, 'timestamp' => '2026-05-04T12:00:00Z' }
        ]
      )

      quality = subject.send(:session_quality_metrics)

      assert_eq(quality[:sample_size], 3)
      assert_eq(quality[:clean_green], 1)
      assert_eq(quality[:recovered_green], 1)
      assert_eq(quality[:unrecovered_failures], 1)
      assert_eq(quality[:clean_green_rate], 33.3)
      assert_eq(quality[:average_sop_score], 8.0)
      true
    end
  end

  test_category('Finding classification') do
    test('detects app category declared through xcconfig Info.plist build settings') do
      Dir.mktmpdir('saneprocess-category-test') do |dir|
        config_dir = File.join(dir, 'Config')
        Dir.mkdir(config_dir)
        File.write(
          File.join(config_dir, 'Shared.xcconfig'),
          "INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities\n"
        )

        assert(
          ValidationReport.new.send(:project_declares_app_category?, dir),
          'expected xcconfig Info.plist category setting to satisfy app category check'
        )
      end
      true
    end

    test('accepts canonical website download redirects for live release links') do
      subject = DownloadRedirectValidationHarness.new(
        resolved: { 'https://saneclip.com/download' => 'SaneClip-2.3.2.zip' }
      )

      assert(
        subject.send(
          :page_has_live_download_link?,
          ['https://saneclip.com/download'],
          'https://dist.saneclip.com/updates/SaneClip-2.3.2.zip'
        ),
        'expected /download redirect to satisfy website download check'
      )
      true
    end

    test('rejects generic download links that do not resolve to the live release archive') do
      subject = DownloadRedirectValidationHarness.new(
        resolved: { 'https://saneclip.com/download' => 'SaneClip-2.3.1.zip' }
      )

      assert(
        !subject.send(
          :page_has_live_download_link?,
          ['https://saneclip.com/download'],
          'https://dist.saneclip.com/updates/SaneClip-2.3.2.zip'
        ),
        'expected stale /download redirect to fail website download check'
      )
      true
    end

    test('accepts download landing pages that link to the live release archive') do
      subject = DownloadRedirectValidationHarness.new(
        landing_pages: {
          'https://saneclip.com/download' => '<a href="https://dist.saneclip.com/updates/SaneClip-2.3.2.zip">Download</a>'
        },
        ok_links: ['https://dist.saneclip.com/updates/SaneClip-2.3.2.zip']
      )

      assert(
        subject.send(
          :page_has_live_download_link?,
          ['https://saneclip.com/download'],
          'https://dist.saneclip.com/updates/SaneClip-2.3.2.zip'
        ),
        'expected /download landing page to satisfy website download check'
      )
      true
    end

    test('classifies process and release findings separately with actions') do
      subject = ValidationReport.new

      process_area = subject.send(:finding_area, 'Q4 FAIL: Only 66.1% verify attempts pass.')
      release_area = subject.send(:finding_area, 'Q6 RELEASE: [SaneBar] Live release archive missing')
      action = subject.send(:finding_action, 'Q6 RELEASE: [SaneBar] Latest project QA gate is current (snapshot stale)')

      assert_eq(process_area, :system_health)
      assert_eq(release_area, :release_readiness)
      assert(action.include?('refresh_qa_snapshots'))
      true
    end

    test('keeps app-readiness blockers separate from process-health verdicts') do
      subject = ValidationReport.new
      subject.instance_variable_set(:@data, { 'infra/SaneProcess' => {}, 'apps/SaneBar' => {}, 'apps/SaneClip' => {} })
      subject.instance_variable_set(:@issues, ['Q10 DOCS: [SaneClip] CHANGELOG missing version 2.3.0'])
      subject.instance_variable_set(:@warnings, ['Q4: Only 66.2% verify attempts pass.'])
      subject.instance_variable_set(:@metrics, {
        release_integrity: { issues: 0 },
        website_distribution: { issues: 0 },
        code_signing: { issues: 0 },
        cross_channel_consistency: { canonical_issues: 0, hosted_file_actions: 0 }
      })

      subject.send(:calculate_final_verdict)
      verdict = subject.instance_variable_get(:@verdict)

      assert_eq(verdict[:status], 'APP READINESS BLOCKED')
      assert_eq(verdict[:sections][:system_health][:status], 'WARN')
      assert_eq(verdict[:sections][:app_readiness][:status], 'BLOCKED')
      true
    end
  end
end)
