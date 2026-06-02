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

class AppChecklistHarness < ValidationReport
  def initialize(page_html:)
    super()
    @page_html = page_html
  end

  def fetch_live_appcast_snapshot(_site_host)
    raise 'App Store products must not fetch Sparkle appcasts'
  end

  def inspect_live_release_artifact(_url)
    raise 'App Store products must not inspect direct-download release artifacts'
  end

  def fetch_url_text(_url, headers: {})
    @page_html
  end

  def check_url_status(_url, follow_redirects: false)
    '200'
  end

  def link_status_ok?(_url)
    true
  end

  def github_repo_exists?(_github_repo)
    true
  end

  def github_repo_has_issues?(_github_repo)
    true
  end

  def latest_project_qa_status(_project_path)
    { 'generatedAt' => '2026-05-18T10:00:00Z', 'status' => 'passed', 'staleReasons' => [] }
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

class CustomerRealityHarness < ValidationReport
  attr_reader :issues, :warnings, :metrics, :verdict

  def initialize(products:, snapshots:)
    super()
    @products = products
    @snapshots = snapshots
  end

  def released_product_definitions
    @products
  end

  def customer_ui_contract_snapshot(project_path)
    @snapshots.fetch(project_path)
  end
end

class CodexSkillHealthHarness < ValidationReport
  attr_reader :warnings

  def initialize(skill_root:, registry_path:)
    super()
    @skill_root = skill_root
    @registry_path = registry_path
  end

  def codex_skill_root
    @skill_root
  end

  def codex_skills_registry_path
    @registry_path
  end
end

class SopPolicyDiffHarness < ValidationReport
  attr_reader :warnings

  def initialize(repo_root:)
    super()
    @repo_root = repo_root
  end

  def saneprocess_repo_root
    @repo_root
  end
end

include TestFramework

def product_definition(name, slug:, domain:)
  { name: name, slug: slug, domain: domain, project_exists: true }
end

def init_git_fixture(path)
  system('git', '-C', path, 'init', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'config', 'user.email', 'test@saneapps.local', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'config', 'user.name', 'SaneApps Test', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'add', '.', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'commit', '-m', 'initial fixture', out: File::NULL, err: File::NULL)
end

def write_qa_status(path, source_fingerprint: nil)
  FileUtils.mkdir_p(File.join(path, 'outputs'))
  payload = {
    'generatedAt' => Time.now.utc.iso8601,
    'status' => 'passed'
  }
  payload['sourceFingerprint'] = source_fingerprint if source_fingerprint
  File.write(File.join(path, 'outputs', 'qa_status.json'), JSON.pretty_generate(payload))
end

exit(run_tests('Validation report tests') do
  test_category('Q11 cross-channel drift classification') do
    test('treats hosted-file drift as customer-facing release break') do
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
      assert_eq(subject.verdict[:status], 'BROKEN RELEASE PIPELINE')
      assert(subject.issues.any? { |issue| issue.include?('Q11 HOSTED FILE ACTION: [SaneBar]') })
      assert(subject.warnings.grep(/Q11 HOSTED FILE ACTION:/).empty?, 'hosted-file drift should not be downgraded to a warning')
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

    test('flags stale Lemon Squeezy files even when latest hosted file is present') do
      products = [product_definition('SaneSales', slug: 'sanesales', domain: 'sanesales.com')]
      subject = ValidationReportHarness.new(
        products: products,
        appcast_versions: { 'sanesales.com' => '1.3.8' },
        website_versions: { 'sanesales.com' => '1.3.8' },
        webhook_versions: { 'SaneSales' => '1.3.8' },
        cask_versions: { 'sanesales' => '1.3.8' },
        lemonsqueezy_snapshot: {
          'SaneSales' => {
            'filename' => 'SaneSales-1.3.8.zip',
            'version' => '1.3.8',
            'published_file_count' => 2,
            'published_filenames' => ['SaneSales-1.3.8.zip', 'SaneSales-1.3.7.zip'],
            'product_id' => '822714',
            'product_slug' => 'sanesales',
            'variant_id' => '1296644'
          }
        }
      )

      subject.send(:q11_cross_channel_version_consistency)
      subject.send(:calculate_final_verdict)

      assert_eq(subject.metrics[:cross_channel_consistency][:canonical_issues], 0)
      assert_eq(subject.metrics[:cross_channel_consistency][:hosted_file_actions], 1)
      assert_eq(subject.verdict[:status], 'BROKEN RELEASE PIPELINE')
      assert(subject.issues.any? { |issue| issue.include?('stale published file') })
      assert(subject.issues.any? { |issue| issue.include?('SaneSales-1.3.7.zip') })
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
      assert_eq(snapshot['SaneBar']['published_file_count'], 1)
      assert_eq(snapshot['SaneBar']['published_filenames'], ['SaneBar-2.1.36.zip'])
      assert_eq(snapshot['SaneBar']['product_id'], '123')
      assert_eq(snapshot['SaneBar']['product_slug'], 'sanebar')
      assert_eq(snapshot['SaneBar']['variant_id'], '456')
      true
    end
  end

  test_category('Q13 customer reality contracts') do
    test('records red release-readiness issue when customer UI contract is not green') do
      Dir.mktmpdir('customer-reality-') do |dir|
        project_path = File.join(dir, 'SaneBar')
        FileUtils.mkdir_p(File.join(project_path, 'Tests'))
        File.write(File.join(project_path, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneBar\n")
        product = product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com').merge(project_path: project_path)
        subject = CustomerRealityHarness.new(
          products: [product],
          snapshots: {
            project_path => { ok: false, issues: ['Receipt source fingerprint is stale'] }
          }
        )

        subject.send(:q13_customer_reality_contracts)
        subject.instance_variable_set(:@data, { 'infra/SaneProcess' => {}, 'apps/SaneBar' => {}, 'apps/SaneClip' => {} })
        subject.instance_variable_set(:@metrics, subject.metrics.merge(
          release_integrity: { issues: 0 },
          website_distribution: { issues: 0 },
          code_signing: { issues: 0 },
          cross_channel_consistency: { canonical_issues: 0, hosted_file_actions: 0 }
        ))
        subject.send(:calculate_final_verdict)

        assert_eq(subject.metrics[:customer_reality_contracts][:issues], 1)
        assert_eq(subject.metrics[:final][:customer_ui_contract_issues], 1)
        assert_eq(subject.verdict[:status], 'BROKEN RELEASE PIPELINE')
        assert(subject.issues.any? { |issue| issue.include?('Q13 CUSTOMER REALITY: [SaneBar] Customer UI contract') })
        assert_eq(subject.send(:finding_area, subject.issues.first), :release_readiness)
      end
      true
    end

    test('counts raw Q13 blockers while capping surfaced summary lines') do
      Dir.mktmpdir('customer-reality-many-') do |dir|
        project_path = File.join(dir, 'SaneBar')
        FileUtils.mkdir_p(File.join(project_path, 'Tests'))
        File.write(File.join(project_path, 'Tests', 'CustomerUIActions.yml'), "version: 1\napp: SaneBar\n")
        product = product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com').merge(project_path: project_path)
        issues = 20.times.map { |i| "workflow blocker #{i + 1}" }
        subject = CustomerRealityHarness.new(
          products: [product],
          snapshots: {
            project_path => { ok: false, issues: issues }
          }
        )

        subject.send(:q13_customer_reality_contracts)

        assert_eq(subject.metrics[:customer_reality_contracts][:issues], 20)
        assert_eq(subject.metrics[:customer_reality_contracts][:surfaced_issues], 13)
        assert(subject.metrics[:customer_reality_contracts][:details].last.include?('8 more issue(s) omitted'))
      end
      true
    end

    test('ignores Codex runtime placeholder skill directory') do
      Dir.mktmpdir('codex-skill-health') do |tmpdir|
        skill_root = File.join(tmpdir, 'skills')
        FileUtils.mkdir_p(File.join(skill_root, 'codex-primary-runtime'))
        FileUtils.mkdir_p(File.join(skill_root, 'verify'))
        File.write(
          File.join(skill_root, 'verify', 'SKILL.md'),
          <<~MD
            ---
            name: verify
            description: Verify the project.
            ---
          MD
        )
        registry_path = File.join(tmpdir, 'SKILLS_REGISTRY.md')
        File.write(registry_path, "| `verify` | verify | #{File.join(skill_root, 'verify', 'SKILL.md')} |\n")

        subject = CodexSkillHealthHarness.new(skill_root: skill_root, registry_path: registry_path)
        issues = []
        subject.send(:check_codex_skill_health, issues)

        assert_eq(issues, [])
        assert(subject.warnings.none? { |warning| warning.include?('codex-primary-runtime') })
      end
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
        File.write(File.join(tmpdir, 'DEVELOPMENT.md'), ("deep walkthrough\n" * 801))
        FileUtils.mkdir_p(File.join(tmpdir, '.claude'))
        File.write(File.join(tmpdir, '.claude', 'research.md'), ("verified finding\n" * 201))

        subject = ValidationReport.new
        issues = []
        warnings = []
        subject.send(:check_context_file_sizes, tmpdir, 'SaneProcess', issues, warnings)

        assert(warnings.any? { |warning| warning.include?('AGENTS.md') && warning.include?('nearing Codex') })
        assert(issues.any? { |issue| issue.include?('.claude/research.md is 201 lines') })
        assert(issues.any? { |issue| issue.include?('SESSION_HANDOFF.md is 801 lines') })
        assert(issues.any? { |issue| issue.include?('DEVELOPMENT.md is 801 lines') })
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

    test('flags SOP policy wording changes without an enforcement surface') do
      Dir.mktmpdir('validation-report-sop-policy') do |tmpdir|
        File.write(File.join(tmpdir, 'AGENTS.md'), "# Rules\n\nExisting guidance.\n")
        init_git_fixture(tmpdir)
        File.write(File.join(tmpdir, 'AGENTS.md'), "# Rules\n\nAgents must update the SOP after mistakes.\n")

        subject = SopPolicyDiffHarness.new(repo_root: tmpdir)
        issues = []
        warnings = []
        subject.send(:check_sop_policy_changes_need_enforcement, issues, warnings)

        assert(issues.any? { |issue| issue.include?('SOP policy wording changed without enforcement surface') })
      end

      true
    end

    test('allows SOP policy wording changes paired with enforcement changes') do
      Dir.mktmpdir('validation-report-sop-enforced') do |tmpdir|
        FileUtils.mkdir_p(File.join(tmpdir, 'scripts'))
        File.write(File.join(tmpdir, 'AGENTS.md'), "# Rules\n\nExisting guidance.\n")
        File.write(File.join(tmpdir, 'scripts', 'agent_eval_fixtures.json'), '{"version":1,"cases":[]}')
        init_git_fixture(tmpdir)
        File.write(File.join(tmpdir, 'AGENTS.md'), "# Rules\n\nAgents must update hooks or evals after process mistakes.\n")
        File.write(File.join(tmpdir, 'scripts', 'agent_eval_fixtures.json'), '{"version":1,"cases":[{"id":"sop"}]}')

        subject = SopPolicyDiffHarness.new(repo_root: tmpdir)
        issues = []
        warnings = []
        subject.send(:check_sop_policy_changes_need_enforcement, issues, warnings)

        assert_eq(issues, [])
      end

      true
    end

    test('allows explicit prose-only SOP policy exceptions with a reason marker') do
      Dir.mktmpdir('validation-report-sop-prose-only') do |tmpdir|
        File.write(File.join(tmpdir, 'DEVELOPMENT.md'), "# Development\n\nExisting guidance.\n")
        init_git_fixture(tmpdir)
        File.write(
          File.join(tmpdir, 'DEVELOPMENT.md'),
          "# Development\n\nSANEPROCESS_PROSE_ONLY_POLICY: public glossary note, no workflow behavior changed.\nAgents must know the term means documentation only here.\n"
        )

        subject = SopPolicyDiffHarness.new(repo_root: tmpdir)
        issues = []
        warnings = []
        subject.send(:check_sop_policy_changes_need_enforcement, issues, warnings)

        assert_eq(issues, [])
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

    test('ignores legacy empty session_end placeholders') do
      subject = ProcessMetricsValidationHarness.new(
        [
          { 'type' => 'session_end', 'success' => nil, 'edits' => 0, 'timestamp' => '2026-05-04T09:00:00Z' },
          { 'type' => 'session_end', 'success' => nil, 'edits' => 0, 'timestamp' => '2026-05-04T09:00:01Z' },
          { 'type' => 'session_end', 'success' => true, 'sop_score' => 9, 'edits' => 2, 'verify_failures' => 0, 'timestamp' => '2026-05-04T10:00:00Z' }
        ]
      )

      quality = subject.send(:session_quality_metrics)

      assert_eq(quality[:sample_size], 1)
      assert_eq(quality[:clean_green], 1)
      assert_eq(quality[:clean_green_rate], 100.0)
      true
    end

    test('classifies edited sessions without final verify as unverified, not failed') do
      subject = ProcessMetricsValidationHarness.new(
        [
          { 'type' => 'session_end', 'success' => nil, 'sop_score' => 10, 'edits' => 2, 'verify_failures' => 0, 'final_verify_success' => nil, 'timestamp' => '2026-05-04T10:00:00Z' },
          { 'type' => 'session_end', 'success' => nil, 'sop_score' => 9, 'edits' => 1, 'verify_failures' => 0, 'final_verify_success' => true, 'timestamp' => '2026-05-04T11:00:00Z' },
          { 'type' => 'session_end', 'success' => nil, 'sop_score' => 6, 'edits' => 1, 'verify_failures' => 1, 'final_verify_success' => false, 'timestamp' => '2026-05-04T12:00:00Z' }
        ]
      )

      quality = subject.send(:session_quality_metrics)

      assert_eq(quality[:sample_size], 3)
      assert_eq(quality[:clean_green], 1)
      assert_eq(quality[:unverified_with_edits], 1)
      assert_eq(quality[:unrecovered_failures], 1)
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

    test('accepts dirty project QA receipts when the source fingerprint still matches') do
      Dir.mktmpdir('qa-fingerprint-clean-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneScan'))
        File.write(File.join(dir, 'SaneScan', 'App.swift'), "import SwiftUI\n")
        init_git_fixture(dir)

        subject = ValidationReport.new
        fingerprint = subject.send(:project_qa_source_fingerprint, dir)
        write_qa_status(dir, source_fingerprint: fingerprint)
        File.write(File.join(dir, 'SESSION_HANDOFF.md'), "dirty operational handoff\n")

        status = subject.send(:latest_project_qa_status, dir)

        assert_eq([], status['staleReasons'])
        assert_eq(fingerprint, status['currentSourceFingerprint'])
      end
      true
    end

    test('ignores release-preflight excluded operational folders in project QA fingerprints') do
      Dir.mktmpdir('qa-fingerprint-operational-folders-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneVideo'))
        File.write(File.join(dir, 'SaneVideo', 'App.swift'), "import SwiftUI\n")
        init_git_fixture(dir)

        subject = ValidationReport.new
        fingerprint = subject.send(:project_qa_source_fingerprint, dir)
        write_qa_status(dir, source_fingerprint: fingerprint)

        FileUtils.mkdir_p(File.join(dir, '.serena', 'memories'))
        File.write(File.join(dir, '.serena', 'memories', 'release.md'), "operational memory\n")
        FileUtils.mkdir_p(File.join(dir, 'releases'))
        File.write(File.join(dir, 'releases', 'release.log'), "release output\n")
        FileUtils.mkdir_p(File.join(dir, 'fastlane', 'test_output'))
        File.write(File.join(dir, 'fastlane', 'test_output', 'report.xml'), "<testsuite />\n")

        status = subject.send(:latest_project_qa_status, dir)

        assert_eq([], status['staleReasons'])
        assert_eq(fingerprint, status['currentSourceFingerprint'])
      end
      true
    end

    test('marks project QA receipts stale when the source fingerprint changes') do
      Dir.mktmpdir('qa-fingerprint-stale-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneScan'))
        source_path = File.join(dir, 'SaneScan', 'App.swift')
        File.write(source_path, "import SwiftUI\n")
        init_git_fixture(dir)

        subject = ValidationReport.new
        write_qa_status(dir, source_fingerprint: subject.send(:project_qa_source_fingerprint, dir))
        File.write(source_path, "import SwiftUI\nstruct Changed {}\n")

        status = subject.send(:latest_project_qa_status, dir)

        assert(status['staleReasons'].include?('source fingerprint changed since QA receipt'))
      end
      true
    end

    test('preserves dirty tree fallback for project QA receipts without fingerprints') do
      Dir.mktmpdir('qa-fingerprint-legacy-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneScan'))
        File.write(File.join(dir, 'SaneScan', 'App.swift'), "import SwiftUI\n")
        init_git_fixture(dir)
        write_qa_status(dir)
        File.write(File.join(dir, 'SESSION_HANDOFF.md'), "dirty operational handoff\n")

        status = ValidationReport.new.send(:latest_project_qa_status, dir)

        assert(status['staleReasons'].include?('repository has uncommitted changes'))
      end
      true
    end

    test('uses App Store readiness checks for iOS products') do
      Dir.mktmpdir('sanescan-checklist') do |dir|
        File.write(File.join(dir, 'README.md'), "# SaneScan\n")
        product = {
          name: 'SaneScan',
          slug: 'sanescan',
          type: 'ios_app',
          domain: 'sanescan.saneapps.com',
          github_repo: 'sane-apps/SaneScan',
          checkout_uuid: '',
          appstore_id: '6770391054',
          storekit_product_id: 'com.sanescan.app.pro.annual',
          appstore_category: 'public.app-category.productivity',
          privacy_policy_url: 'https://sanescan.saneapps.com/privacy/',
          appstore_release_notes: 'Initial release.',
          project_path: dir,
          project_exists: true
        }
        subject = AppChecklistHarness.new(
          page_html: '<a data-appstore-ios-link href="mailto:hi@saneapps.com">Contact</a><a href="/privacy/">Privacy</a>'
        )

        names = subject.send(:generate_app_checklist, product).map { |item| item[:name] }

        assert(names.include?('App Store lane configured'))
        assert(names.include?('App Store Connect app ID configured'))
        assert(names.include?('StoreKit product configured'))
        assert(names.include?('App Store release notes configured'))
        assert(names.include?('Public privacy policy URL configured'))
        assert(names.include?('Website has App Store/contact CTA'))
        [
          'Hardened runtime enabled',
          'Entitlements file exists',
          'Live release archive',
          'Live appcast.xml with active entry',
          'Live Sparkle EdDSA signature',
          'Live release URL accessible',
          'CHANGELOG.md',
          'PRIVACY.md',
          'Website has download link',
          'Lemon Squeezy store configured'
        ].each do |unexpected|
          assert(!names.include?(unexpected), "did not expect iOS checklist to include #{unexpected}")
        end
      end
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

    test('score integrity ignores legacy clean-session CSV rows when structured receipts exist') do
      subject = ValidationReport.new
      subject.instance_variable_set(:@data, {})
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@metrics, {})
      subject.define_singleton_method(:trustworthy_session_score_events) { [] }
      subject.define_singleton_method(:sop_jsonl_session_events) do
        [
          { 'timestamp' => '2026-05-20T10:00:00Z', 'session_id' => 'a', 'sop_score' => 7, 'verify_attempts' => 1 },
          { 'timestamp' => '2026-05-20T11:00:00Z', 'session_id' => 'b', 'sop_score' => 8, 'verify_attempts' => 1 }
        ]
      end
      subject.define_singleton_method(:sop_csv_score_rows) do
        [
          { score: 10.0, note: 'clean session', trusted: false },
          { score: 10.0, note: 'clean session', trusted: false }
        ]
      end

      subject.send(:q3_score_integrity)
      metrics = subject.instance_variable_get(:@metrics)[:score_integrity]
      warnings = subject.instance_variable_get(:@warnings)

      assert_eq(metrics[:score_source], :sop_jsonl)
      assert_eq(metrics[:average], 7.5)
      assert_eq(metrics[:legacy_csv_rows_ignored], 2)
      assert(warnings.any? { |item| item.include?('Ignored 2 legacy SOP score row') })
      true
    end

    test('score integrity ignores SOP jsonl score rows without behavioral evidence') do
      subject = ValidationReport.new
      subject.instance_variable_set(:@data, {})
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@metrics, {})
      subject.define_singleton_method(:trustworthy_session_score_events) { [] }
      subject.define_singleton_method(:sop_jsonl_session_events) do
        [
          { 'timestamp' => '2026-05-20T10:00:00Z', 'session_id' => 'a', 'sop_score' => 10, 'verify_attempts' => 0, 'edits' => 0 },
          { 'timestamp' => '2026-05-20T11:00:00Z', 'session_id' => 'b', 'sop_score' => 8, 'verify_attempts' => 1, 'edits' => 0 },
          { 'timestamp' => '2026-05-20T12:00:00Z', 'session_id' => 'c', 'sop_score' => 6, 'verify_attempts' => 0, 'edits' => 2 }
        ]
      end
      subject.define_singleton_method(:sop_csv_score_rows) { [] }

      subject.send(:q3_score_integrity)
      metrics = subject.instance_variable_get(:@metrics)[:score_integrity]

      assert_eq(metrics[:score_source], :sop_jsonl)
      assert_eq(metrics[:sample_size], 2)
      assert_eq(metrics[:average], 7.0)
      assert_eq(metrics[:sop_jsonl_rows_ignored], 1)
      true
    end

    test('block accuracy uses hook-block telemetry when state counters are empty') do
      subject = ValidationReport.new
      subject.instance_variable_set(:@data, {})
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@metrics, {})
      subject.define_singleton_method(:process_metric_events) do |type: nil|
        next [] unless type.to_s == 'hook_block'

        [
          { 'timestamp' => '2026-05-20T10:00:00Z', 'type' => 'hook_block', 'rule' => 'session_docs' },
          { 'timestamp' => '2026-05-20T10:10:00Z', 'type' => 'hook_block', 'rule' => 'visual_proof' }
        ]
      end
      subject.define_singleton_method(:reset_audit_events) { [] }

      subject.send(:q1_block_accuracy)
      metrics = subject.instance_variable_get(:@metrics)[:block_accuracy]

      assert_eq(metrics[:source], 'process_metrics_hook_block')
      assert_eq(metrics[:total], 2)
      assert_eq(metrics[:correct], 2)
      assert_eq(metrics[:wrong], 0)
      true
    end

    test('session quality can use structured SOP jsonl when process session receipts are absent') do
      subject = ValidationReport.new
      subject.define_singleton_method(:process_metric_events) { |type: nil| [] }
      subject.define_singleton_method(:sop_jsonl_session_events) do
        [
          { 'timestamp' => '2026-05-20T10:00:00Z', 'success' => true, 'verify_failures' => 0, 'edits' => 2, 'sop_score' => 8 },
          { 'timestamp' => '2026-05-20T11:00:00Z', 'success' => true, 'verify_failures' => 1, 'edits' => 3, 'sop_score' => 7 }
        ]
      end

      metrics = subject.send(:session_quality_metrics)

      assert_eq(metrics[:sample_size], 2)
      assert_eq(metrics[:clean_green], 1)
      assert_eq(metrics[:recovered_green], 1)
      assert_eq(metrics[:unverified_with_edits], 0)
      assert_eq(metrics[:average_sop_score], 7.5)
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
