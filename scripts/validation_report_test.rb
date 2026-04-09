#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'validation_report'

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

class SisterAppsHarness < ValidationReport
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
end)
