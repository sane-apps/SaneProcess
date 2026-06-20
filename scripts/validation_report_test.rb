#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'validation_report'
require 'tmpdir'
require 'stringio'

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

class WebsiteDistributionHarness < ValidationReport
  attr_reader :issues, :warnings, :metrics

  def initialize(products:, statuses: {}, bodies: {}, resolved: {}, ok_links: [], redirect_base: '', checkout_base: '', bundles: {}, store_base: '')
    super()
    @products = products
    @statuses = statuses
    @bodies = bodies
    @resolved = resolved
    @ok_links = ok_links
    @redirect_base = redirect_base
    @checkout_base = checkout_base
    @bundles = bundles
    @store_base = store_base
    @metrics[:website_distribution] = { issues: 0 }
  end

  def product_definitions
    @products
  end

  def released_product_definitions
    @products.select { |product| product_released?(product) }
  end

  def load_product_config
    { products: {}, bundles: @bundles, store_base: @store_base, checkout_base: @checkout_base, redirect_base: @redirect_base, all_domains: [] }
  end

  def product_checkout_url(product, checkout_base = @checkout_base)
    explicit_url = (product[:checkout_url] || product['checkout_url']).to_s
    return explicit_url unless explicit_url.empty?

    uuid = (product[:checkout_uuid] || product['checkout_uuid']).to_s
    return '' if uuid.empty? || checkout_base.to_s.empty?

    "#{checkout_base}/#{uuid}"
  end

  def product_released?(product)
    !((product[:checkout_url] || product['checkout_url']).to_s.empty? &&
      (product[:checkout_uuid] || product['checkout_uuid']).to_s.empty?)
  end

  def check_url_status(url, follow_redirects: false)
    @statuses.fetch(url, '200')
  end

  def fetch_url_text(url, headers: {})
    return @bodies[url] if @bodies.key?(url)
    return "User-agent: *\nAllow: /\n" if url.end_with?('/robots.txt')
    return '<urlset></urlset>' if url.end_with?('/sitemap.xml')

    ''
  end

  def ssl_certificate_error?(_url)
    false
  end

  def link_resolves_to_live_release?(link, expected_name)
    @resolved[link] == expected_name
  end

  def link_status_ok?(link)
    @ok_links.include?(link) || @statuses.fetch(link, nil).to_s.start_with?('2', '3')
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

class ReleaseIntegrityHarness < ValidationReport
  def check_url_status(_url, follow_redirects: false)
    '200'
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

class ValidationOutputHarness < ValidationReport
  attr_reader :release_checklists_called

  def collect_data
    @data = {}
  end

  def run_hard_analysis
    @issues = []
    @warnings = []
    @metrics = {
      config_consistency: { issues: 0, details: [] },
      block_accuracy: { total: 0 },
      doom_loop_prevention: { caught: 0, missed: 0, catch_rate: nil, breaker_trips: 0, repeat_error_patterns: 0 },
      score_integrity: { status: 'NO DATA' },
      test_outcomes: { total_sessions: 0 },
      trend: { status: 'NO DATA', snapshots: 0 },
      release_integrity: { issues: 0, warnings: 0, details: [] },
      website_distribution: { issues: 0, warnings: 0, details: [] },
      code_signing: { issues: 0, warnings: 0, details: [] },
      support_infrastructure: { issues: 0, warnings: 0, details: [] },
      documentation_currency: { issues: 0, warnings: 0, details: [] },
      cross_channel_consistency: { table: [], canonical_issues: 0, hosted_file_actions: 0 },
      customer_reality_contracts: { issues: 0, warnings: 0, checked: 0, details: [] },
      secret_scan: { issues: 0, warnings: 0, actionable_count: 0, preserved_count: 0, ignored_count: 0 },
      red_noise_budget: { stale_count: 0, details: [] }
    }
    @verdict = {
      color: :green,
      status: 'WORKING',
      detail: 'test harness',
      sections: {
        system_health: { status: 'PASS', detail: 'No open findings', label: 'System Health' },
        release_readiness: { status: 'PASS', detail: 'No open findings', label: 'Release Readiness' },
        app_readiness: { status: 'PASS', detail: 'No open findings', label: 'App Readiness' },
        advisory: { status: 'PASS', detail: 'No open findings', label: 'Advisory' }
      }
    }
  end

  def output_release_checklists
    @release_checklists_called = true
    puts 'release checklists called'
  end

  def save_snapshot; end
end

class UrlStatusHarness < ValidationReport
  attr_reader :commands

  def initialize(results)
    super()
    @results = results.dup
    @commands = []
  end

  def curl_status_command(command)
    @commands << command
    @results.shift || '200'
  end
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

def product_definition(name, slug:, domain:)
  {
    name: name,
    slug: slug,
    domain: domain,
    dist_domain: '',
    checkout_uuid: '',
    checkout_url: '',
    project_path: Dir.tmpdir,
    project_exists: true
  }
end

def init_git_fixture(path)
  system('git', '-C', path, 'init', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'config', 'user.email', 'test@saneapps.local', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'config', 'user.name', 'SaneApps Test', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'add', '.', out: File::NULL, err: File::NULL)
  system('git', '-C', path, 'commit', '-m', 'initial fixture', out: File::NULL, err: File::NULL)
end

def write_qa_status(path, source_fingerprint: nil, extra: {})
  FileUtils.mkdir_p(File.join(path, 'outputs'))
  payload = {
    'generatedAt' => Time.now.utc.iso8601,
    'status' => 'passed'
  }.merge(extra)
  payload['sourceFingerprint'] = source_fingerprint if source_fingerprint
  File.write(File.join(path, 'outputs', 'qa_status.json'), JSON.pretty_generate(payload))
end

exit(run_tests('Validation report tests') do
  test_category('CLI routing') do
    test('parses help without running the full report') do
      options = ValidationReport.parse_cli_args(['--help'])

      assert_eq(options[:help], true)
      assert_includes(options[:usage], '--release-checklists')
      true
    end

    test('skips deep release checklists by default') do
      subject = ValidationOutputHarness.new
      output = capture_stdout { subject.run(format: :text) }

      assert_eq(subject.release_checklists_called, nil)
      assert_includes(output, 'Release readiness checklists skipped')
      assert_includes(output, '--release-checklists')
      true
    end

    test('runs deep release checklists only when requested') do
      subject = ValidationOutputHarness.new
      output = capture_stdout { subject.run(format: :text, include_release_checklists: true) }

      assert_eq(subject.release_checklists_called, true)
      assert_includes(output, 'release checklists called')
      true
    end
  end

  test_category('live URL probe efficiency') do
    test('caches successful URL status checks within a report') do
      subject = UrlStatusHarness.new(['200'])

      assert_eq(subject.send(:check_url_status, 'https://example.test'), '200')
      assert_eq(subject.send(:check_url_status, 'https://example.test'), '200')
      assert_eq(subject.commands.length, 1)
      true
    end

    test('does not retry terminal non-success HTTP statuses') do
      subject = UrlStatusHarness.new(['404'])

      assert_eq(subject.send(:check_url_status, 'https://example.test/missing'), '404')
      assert_eq(subject.commands.length, 1)
      true
    end

    test('retries retryable failures and accepts a GET recovery') do
      subject = UrlStatusHarness.new(['000', '200'])

      assert_eq(subject.send(:check_url_status, 'https://example.test/flaky'), '200')
      assert_eq(subject.commands.length, 2)
      true
    end

    test('falls back to GET after transport error output from HEAD') do
      subject = UrlStatusHarness.new(['curl: (28) Operation timed out', '200'])

      assert_eq(subject.send(:check_url_status, 'https://example.test/flaky-get'), '200')
      assert_eq(subject.commands.length, 2)
      assert_includes(subject.commands.last, ' -s ')
      true
    end

    test('escapes SSL probe URL before shelling out') do
      malicious_url = "https://example.test/'; touch /tmp/sane-validation-pwn; echo '"
      subject = UrlStatusHarness.new(['ok'])

      assert_eq(subject.send(:ssl_certificate_error?, malicious_url), false)
      assert_eq(subject.commands.length, 1)
      assert_includes(subject.commands.first, Shellwords.shellescape(malicious_url))
      true
    end
  end

  test_category('Q6 release minimum OS warnings') do
    test('warns when a released app accidentally raises the macOS floor above Sonoma') do
      subject = ReleaseIntegrityHarness.new
      issues = []
      warnings = []
      product = product_definition('SaneBar', slug: 'sanebar', domain: 'sanebar.com')
      snapshot = {
        body: '<rss><channel><item></item></channel></rss>',
        latest_item: '<item></item>',
        enclosure_url: 'https://dist.sanebar.com/updates/SaneBar-2.1.68.zip',
        has_signature: true,
        minimum_system_version: '15.0'
      }

      subject.send(:check_live_appcast_snapshot, snapshot, product, issues, warnings)

      assert_eq(issues, [])
      assert(warnings.any? { |warning| warning.include?('SaneBar') && warning.include?('macOS 15.0') })
      true
    end

    test('accepts a documented product-specific macOS floor exception') do
      subject = ReleaseIntegrityHarness.new
      issues = []
      warnings = []
      product = product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com').merge(
        minimum_macos_exception: {
          version: '15.0',
          reason: 'Intentional v1 floor documented in README and CHANGELOG.'
        }
      )
      snapshot = {
        body: '<rss><channel><item></item></channel></rss>',
        latest_item: '<item></item>',
        enclosure_url: 'https://dist.sanevideo.com/updates/SaneVideo-1.0.1.zip',
        has_signature: true,
        minimum_system_version: '15.0'
      }

      subject.send(:check_live_appcast_snapshot, snapshot, product, issues, warnings)

      assert_eq(issues, [])
      assert_eq(warnings, [])
      true
    end
  end

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
      assert_eq(subject.verdict[:status], 'NOT READY FOR RELEASE')
      assert(subject.issues.any? { |issue| issue.include?('Q11 HOSTED FILE ACTION: [SaneBar]') })
      assert(subject.warnings.grep(/Q11 HOSTED FILE ACTION:/).empty?, 'hosted-file drift should not be downgraded to a warning')
      true
    end

    test('keeps website drift as a release-readiness blocker') do
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
      assert_eq(subject.verdict[:status], 'NOT READY FOR RELEASE')
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
      assert_eq(subject.verdict[:status], 'NOT READY FOR RELEASE')
      assert(subject.issues.any? { |issue| issue.include?('stale published file') })
      assert(subject.issues.any? { |issue| issue.include?('SaneSales-1.3.7.zip') })
      true
    end

    test('flags configured Lemon Squeezy variants with no published hosted file') do
      products = [product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com')]
      subject = ValidationReportHarness.new(
        products: products,
        appcast_versions: { 'sanevideo.com' => '1.0.1' },
        website_versions: { 'sanevideo.com' => '1.0.1' },
        webhook_versions: { 'SaneVideo' => '1.0.1' },
        cask_versions: { 'sanevideo' => nil },
        lemonsqueezy_snapshot: {
          'SaneVideo' => {
            'filename' => nil,
            'version' => nil,
            'published_file_count' => 0,
            'published_filenames' => [],
            'product_id' => '1087460',
            'product_slug' => 'sanevideo-pro',
            'variant_id' => '1703963'
          }
        }
      )

      subject.send(:q11_cross_channel_version_consistency)
      subject.send(:calculate_final_verdict)

      assert_eq(subject.metrics[:cross_channel_consistency][:canonical_issues], 0)
      assert_eq(subject.metrics[:cross_channel_consistency][:hosted_file_actions], 1)
      assert_eq(subject.verdict[:status], 'NOT READY FOR RELEASE')
      assert(subject.issues.any? { |issue| issue.include?('[SaneVideo] Lemon Squeezy hosted has v— but appcast is v1.0.1') })
      assert(subject.issues.any? { |issue| issue.include?('variant_id=1703963') })
      true
    end
  end

  test_category('Q7 website distribution semantics') do
    test('flags 200 appcasts with no active release item') do
      product = product_definition('SaneSync', slug: 'sanesync', domain: 'sanesync.com').merge(
        checkout_uuid: 'sync-checkout'
      )
      subject = WebsiteDistributionHarness.new(
        products: [product],
        bodies: {
          'https://sanesync.com' => '<a href="/download">Download</a>',
          'https://sanesync.com/appcast.xml' => '<?xml version="1.0"?><rss><channel></channel></rss>',
          'https://sanesync.com/robots.txt' => "User-agent: *\nAllow: /\n",
          'https://sanesync.com/sitemap.xml' => '<urlset></urlset>'
        }
      )

      subject.send(:q7_website_distribution)

      assert(subject.issues.any? { |issue| issue.include?('SaneSync appcast') && issue.include?('no active release item') })
      assert_eq(1, subject.metrics[:website_distribution][:issues])
      true
    end

    test('flags placeholder download pages that do not resolve to latest appcast archive') do
      product = product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com').merge(
        checkout_uuid: 'video-checkout'
      )
      subject = WebsiteDistributionHarness.new(
        products: [product],
        bodies: {
          'https://sanevideo.com' => '<a href="/download">Download</a>',
          'https://sanevideo.com/download' => '<html><body>Coming soon</body></html>',
          'https://sanevideo.com/appcast.xml' => <<~XML,
            <?xml version="1.0"?>
            <rss><channel><item sparkle:shortVersionString="1.0.1" sparkle:version="101">
              <enclosure url="https://dist.sanevideo.com/updates/SaneVideo-1.0.1.zip" sparkle:edSignature="abc" />
            </item></channel></rss>
          XML
          'https://sanevideo.com/robots.txt' => "User-agent: *\nAllow: /\n",
          'https://sanevideo.com/sitemap.xml' => '<urlset></urlset>'
        }
      )

      subject.send(:q7_website_distribution)

      assert(subject.issues.any? { |issue| issue.include?('SaneVideo website download') && issue.include?('SaneVideo-1.0.1.zip') })
      assert_eq(1, subject.metrics[:website_distribution][:issues])
      true
    end

    test('flags crawler assets that serve the website HTML fallback') do
      product = product_definition('SaneSync', slug: 'sanesync', domain: 'sanesync.com')
      subject = WebsiteDistributionHarness.new(
        products: [product],
        bodies: {
          'https://sanesync.com' => '<html><body>Coming soon</body></html>',
          'https://sanesync.com/robots.txt' => '<html><body>Coming soon</body></html>',
          'https://sanesync.com/sitemap.xml' => '<html><body>Coming soon</body></html>'
        }
      )

      subject.send(:q7_website_distribution)

      assert(subject.issues.any? { |issue| issue.include?('[SaneSync] robots.txt') })
      assert(subject.issues.any? { |issue| issue.include?('[SaneSync] sitemap.xml') })
      assert_eq(2, subject.metrics[:website_distribution][:issues])
      assert_eq(0, subject.metrics[:website_distribution][:warnings])
      true
    end

    test('accepts checkout links on linked download landing pages') do
      product = product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com').merge(
        checkout_uuid: 'video-checkout'
      )
      checkout_url = 'https://go.saneapps.com/buy/sanevideo?ref=download-page'
      subject = WebsiteDistributionHarness.new(
        products: [product],
        bodies: {
          'https://sanevideo.com/download' => %(<a href="#{checkout_url}">Support early Pro</a>)
        },
        ok_links: [checkout_url],
        redirect_base: 'https://go.saneapps.com/buy'
      )
      links = subject.send(:extract_page_links, '<a href="/download">Download</a>', base_url: 'https://sanevideo.com')

      assert(subject.send(:page_has_checkout_link?, links, product, base_url: 'https://sanevideo.com'))
      true
    end

    test('accepts explicit Lemon Squeezy custom checkout URLs') do
      custom_checkout_url = 'https://saneapps.lemonsqueezy.com/checkout/custom/custom-id?signature=abc'
      product = product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com').merge(
        checkout_url: custom_checkout_url
      )
      landing_checkout_url = "#{custom_checkout_url}&ref=download-page"
      subject = WebsiteDistributionHarness.new(
        products: [product],
        bodies: {
          'https://sanevideo.com/download' => %(<a href="#{landing_checkout_url}">Support Pro</a>)
        },
        ok_links: [landing_checkout_url]
      )
      links = subject.send(:extract_page_links, '<a href="/download">Download</a>', base_url: 'https://sanevideo.com')

      assert(subject.send(:page_has_checkout_link?, links, product, base_url: 'https://sanevideo.com'))
      assert_eq([product], subject.released_product_definitions)
      true
    end

    test('checks configured bundle checkout and redirect routes as revenue-critical') do
      bundle_checkout_url = 'https://saneapps.lemonsqueezy.com/checkout/custom/bundle-id?signature=abc'
      bundle_route = 'https://go.saneapps.com/buy/bundle'
      subject = WebsiteDistributionHarness.new(
        products: [],
        statuses: {
          'https://saneapps.com' => '200',
          bundle_checkout_url => '200',
          bundle_route => '404'
        },
        bundles: {
          'bundle' => {
            'name' => 'SaneApps Everything Bundle',
            'checkout_url' => bundle_checkout_url,
            'route' => bundle_route
          }
        }
      )

      subject.send(:q7_website_distribution)

      assert(subject.issues.any? { |issue| issue.include?('SaneApps Everything Bundle redirect') && issue.include?('returns 404') })
      assert_eq(1, subject.metrics[:website_distribution][:issues])
      true
    end

    test('flags unknown source checkout redirect routes') do
      subject = WebsiteDistributionHarness.new(products: [], redirect_base: 'https://go.saneapps.com/buy')
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'index.html'), '<a href="https://go.saneapps.com/buy/old-bundle?ref=test">Buy</a>')
        issues = []
        config = {
          products: {
            'sanebar' => { 'checkout_uuid' => 'bar-checkout' }
          },
          bundles: {
            'bundle' => { 'name' => 'SaneApps Everything Bundle' }
          },
          checkout_base: 'https://saneapps.lemonsqueezy.com/checkout/buy',
          redirect_base: 'https://go.saneapps.com/buy'
        }

        subject.send(:validate_q7_source_checkout_routes, [dir], config, issues)

        assert(issues.any? { |issue| issue.include?("Unknown checkout redirect route 'old-bundle'") })
      end
      true
    end
  end

  test_category('Lemon Squeezy hosted snapshot enrichment') do
    test('matches Lemon Squeezy products with Pro suffix names and slugs') do
      subject = HostedVersionSnapshotHarness.new(
        products: [],
        products_response: [],
        variants_response: [],
        files_response: {}
      )
      product = product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com')
      record = {
        'attributes' => {
          'name' => 'SaneVideo Pro',
          'slug' => 'sanevideo-pro'
        }
      }

      assert(subject.send(:lemonsqueezy_product_matches?, record, product))
      true
    end

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

    test('keeps configured variants when no hosted files are published') do
      subject = HostedVersionSnapshotHarness.new(
        products: [product_definition('SaneVideo', slug: 'sanevideo', domain: 'sanevideo.com')],
        products_response: [
          {
            'id' => '1087460',
            'attributes' => {
              'name' => 'SaneVideo',
              'slug' => 'sanevideo-pro'
            }
          }
        ],
        variants_response: [
          {
            'id' => '1703963',
            'attributes' => {
              'product_id' => 1_087_460
            }
          }
        ],
        files_response: {
          '/v1/variants/1703963/files?page[size]=100' => []
        }
      )

      snapshot = subject.send(:fetch_live_lemonsqueezy_hosted_versions)

      assert_eq(snapshot['SaneVideo']['filename'], '')
      assert_eq(snapshot['SaneVideo']['version'], nil)
      assert_eq(snapshot['SaneVideo']['published_file_count'], 0)
      assert_eq(snapshot['SaneVideo']['published_filenames'], [])
      assert_eq(snapshot['SaneVideo']['product_id'], '1087460')
      assert_eq(snapshot['SaneVideo']['product_slug'], 'sanevideo-pro')
      assert_eq(snapshot['SaneVideo']['variant_id'], '1703963')
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
        assert_eq(subject.verdict[:status], 'NOT READY FOR RELEASE')
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

    test('flags sane-audit without historical regression lane') do
      Dir.mktmpdir('codex-skill-health') do |tmpdir|
        skill_root = File.join(tmpdir, 'skills')
        sane_audit_dir = File.join(skill_root, 'sane-audit')
        FileUtils.mkdir_p(sane_audit_dir)
        File.write(
          File.join(sane_audit_dir, 'SKILL.md'),
          <<~MD
            ---
            name: sane-audit
            description: Audit SaneApps.
            ---

            Run release and docs checks.
          MD
        )
        registry_path = File.join(tmpdir, 'SKILLS_REGISTRY.md')
        File.write(registry_path, "| `sane-audit` | audit | #{File.join(sane_audit_dir, 'SKILL.md')} |\n")

        subject = CodexSkillHealthHarness.new(skill_root: skill_root, registry_path: registry_path)
        issues = []
        subject.send(:check_codex_skill_health, issues)

        assert(issues.any? { |issue| issue.include?('sane-audit missing historical regression prompt') })
      end
      true
    end

    test('accepts sane-audit with historical regression lane') do
      Dir.mktmpdir('codex-skill-health') do |tmpdir|
        skill_root = File.join(tmpdir, 'skills')
        prompt_dir = File.join(skill_root, 'sane-audit', 'prompts')
        FileUtils.mkdir_p(prompt_dir)
        File.write(
          File.join(skill_root, 'sane-audit', 'SKILL.md'),
          <<~MD
            ---
            name: sane-audit
            description: Audit SaneApps.
            ---

            Require historical root-cause GitHub and support coverage.
          MD
        )
        %w[
          q0-config.md
          q6-release.md
          q7-website.md
          q8-signing.md
          q9-support.md
          q10-docs.md
          q11-tooling.md
          q12-runtime-resources.md
        ].each do |prompt_file|
          File.write(File.join(prompt_dir, prompt_file), "#{prompt_file}\n")
        end
        File.write(
          File.join(prompt_dir, 'q13-historical-regression.md'),
          "GitHub support root cause Root-Cause Matrix Per-Perspective Scores Current Coverage Would Catch Today? Checked Evidence No issue cluster can be called fixed without named current coverage\n"
        )
        registry_path = File.join(tmpdir, 'SKILLS_REGISTRY.md')
        File.write(registry_path, "| `sane-audit` | audit | #{File.join(skill_root, 'sane-audit', 'SKILL.md')} |\n")

        subject = CodexSkillHealthHarness.new(skill_root: skill_root, registry_path: registry_path)
        issues = []
        subject.send(:check_codex_skill_health, issues)

        assert_eq(issues, [])
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
    test('Claude install copies the whole hook tree so modules cannot drift') do
      # init.sh switched from hand-maintained module lists (went 8 files
      # stale, shipped LoadError installs) to wholesale glob copy; the
      # research gate rides along with every other require_relative target.
      init_source = File.read(File.expand_path('init.sh', __dir__), encoding: Encoding::UTF_8)

      assert_includes(init_source, '"$SRC"/*.rb')
      assert_includes(init_source, '"$SRC"/core/*.rb')
      true
    end

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
        assert(warnings.any? { |warning| warning.include?('.claude/research.md is 201 lines') })
        assert(warnings.any? { |warning| warning.include?('SESSION_HANDOFF.md is 801 lines') })
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

    test('SaneProcess AGENTS keeps non-hook client anchors while staying compact') do
      path = File.expand_path('../AGENTS.md', __dir__)
      content = File.read(path)
      lines = content.lines.length
      bytes = content.bytesize

      assert(lines < 350, "expected AGENTS.md under 350 lines, got #{lines}")
      assert(bytes < 24 * 1024, "expected AGENTS.md under 24 KiB, got #{bytes}")
      [
        'Session Start',
        'Subagents',
        'Tool Discovery',
        'Mini-First Rule',
        'Visual/UI Proof',
        'Canonical Routes'
      ].each do |anchor|
        assert_includes(content, anchor)
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
          { 'type' => 'verify', 'success' => true, 'tests_run' => 10, 'evidence_strength' => 'tested', 'host' => 'mini', 'timestamp' => '2026-05-04T10:05:00Z', 'project' => 'SaneBar' },
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

    test('verify success without authoritative Mini proof is excluded from pass rate') do
      subject = ProcessMetricsValidationHarness.new(
        [
          { 'type' => 'verify', 'success' => true, 'tests_run' => 12, 'evidence_strength' => 'tested', 'host' => 'local', 'timestamp' => '2026-05-04T10:00:00Z', 'project' => 'SaneBar' },
          { 'type' => 'verify', 'success' => true, 'tests_run' => 12, 'evidence_strength' => 'build_only', 'host' => 'mini', 'timestamp' => '2026-05-04T11:00:00Z', 'project' => 'SaneClip' },
          { 'type' => 'verify', 'success' => true, 'tests_run' => 12, 'evidence_strength' => 'tested', 'host' => 'mini', 'timestamp' => '2026-05-04T12:00:00Z', 'project' => 'SaneProcess' }
        ]
      )

      subject.send(:q4_test_outcomes)

      outcomes = subject.metrics[:test_outcomes]
      warnings = subject.warnings.join("\n")
      assert_eq(outcomes[:process_metric_verify_attempts], 3)
      assert_eq(outcomes[:process_metric_verify_passes], 1)
      assert_eq(outcomes[:verify_attempt_pass_rate], 33.3)
      assert_eq(outcomes[:verify_weak_successes], 2)
      assert_includes(warnings, '2 verify success metric(s) lacked authoritative Mini/fallback tested proof')
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

    test('validation honors SANEMASTER_PROCESS_METRICS_PATH for process metrics') do
      Dir.mktmpdir('validation-process-metrics-path-') do |dir|
        metrics_path = File.join(dir, 'process_metrics.jsonl')
        File.write(metrics_path, JSON.generate(
          'type' => 'verify',
          'success' => true,
          'tests_run' => 12,
          'timestamp' => '2026-06-11T10:00:00Z',
          'project' => 'SaneProcess'
        ) + "\n")
        old_path = ENV['SANEMASTER_PROCESS_METRICS_PATH']
        ENV['SANEMASTER_PROCESS_METRICS_PATH'] = metrics_path

        subject = ValidationReport.new
        events = subject.send(:process_metric_events, type: 'verify')

        assert_eq(subject.send(:process_metrics_path), metrics_path)
        assert_eq(events.length, 1)
        assert_eq(events.first['tests_run'], 12)
      ensure
        if old_path
          ENV['SANEMASTER_PROCESS_METRICS_PATH'] = old_path
        else
          ENV.delete('SANEMASTER_PROCESS_METRICS_PATH')
        end
      end
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

    test('marks policy-only project QA receipts stale for release readiness') do
      Dir.mktmpdir('qa-policy-only-') do |dir|
        FileUtils.mkdir_p(File.join(dir, 'SaneScan'))
        File.write(File.join(dir, 'SaneScan', 'App.swift'), "import SwiftUI\n")
        init_git_fixture(dir)

        subject = ValidationReport.new
        write_qa_status(
          dir,
          source_fingerprint: subject.send(:project_qa_source_fingerprint, dir),
          extra: { 'policyOnlyMode' => true }
        )

        status = subject.send(:latest_project_qa_status, dir)

        assert(status['staleReasons'].include?('latest QA receipt is policy-only'))
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
      hosted_action = subject.send(:finding_action, 'Q11 HOSTED FILE ACTION: [SaneVideo] Lemon Squeezy hosted has v— but appcast is v1.0.1')

      assert_eq(process_area, :system_health)
      assert_eq(release_area, :release_readiness)
      assert(action.include?('refresh_qa_snapshots'))
      assert(hosted_action.include?('hosted-file dashboard action export'))
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
      subject.define_singleton_method(:process_abtest_receipts) { [] }

      subject.send(:q1_block_accuracy)
      metrics = subject.instance_variable_get(:@metrics)[:block_accuracy]

      assert_eq(metrics[:source], 'process_metrics_hook_block')
      assert_eq(metrics[:total], 2)
      assert_eq(metrics[:correct], 2)
      assert_eq(metrics[:wrong], 0)
      true
    end

    test('block accuracy includes audited A/B validation receipts') do
      subject = ValidationReport.new
      subject.instance_variable_set(:@data, {})
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@metrics, {})
      subject.define_singleton_method(:process_metric_events) { |type: nil| [] }
      subject.define_singleton_method(:reset_audit_events) { [] }
      subject.define_singleton_method(:process_abtest_receipts) do
        [
          {
            'validation_delta' => {
              'blocks_that_were_correct' => 3,
              'blocks_that_were_wrong' => 0
            }
          }
        ]
      end

      subject.send(:q1_block_accuracy)
      metrics = subject.instance_variable_get(:@metrics)[:block_accuracy]

      assert_eq(metrics[:source], 'state_validation+abtest_receipts')
      assert_eq(metrics[:total], 3)
      assert_eq(metrics[:correct], 3)
      assert_eq(metrics[:wrong], 0)
      assert_eq(metrics[:abtest_receipts], 1)
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

    test('secret scan receipt passes when latest receipt has no actionable findings') do
      Dir.mktmpdir('validation-secret-scan-') do |dir|
        File.write(File.join(dir, 'clean.json'), JSON.pretty_generate(
          'generated_at' => Time.now.utc.iso8601,
          'status' => 'pass',
          'actionable_count' => 0,
          'preserved_count' => 2,
          'ignored_count' => 3
        ))
        subject = ValidationReport.new
        subject.define_singleton_method(:secret_scan_receipt_dir) { dir }
        subject.instance_variable_set(:@issues, [])
        subject.instance_variable_set(:@warnings, [])
        subject.instance_variable_set(:@metrics, {})

        subject.send(:q15_secret_scan_receipt)

        assert_eq(subject.instance_variable_get(:@issues), [])
        assert_eq(subject.instance_variable_get(:@warnings), [])
        assert_eq(subject.instance_variable_get(:@metrics)[:secret_scan][:status], 'pass')
      end
      true
    end

    test('secret scan receipt blocks validation when actionable findings remain') do
      Dir.mktmpdir('validation-secret-scan-') do |dir|
        File.write(File.join(dir, 'fail.json'), JSON.pretty_generate(
          'generated_at' => Time.now.utc.iso8601,
          'status' => 'fail',
          'actionable_count' => 1,
          'preserved_count' => 0,
          'ignored_count' => 0
        ))
        subject = ValidationReport.new
        subject.define_singleton_method(:secret_scan_receipt_dir) { dir }
        subject.instance_variable_set(:@issues, [])
        subject.instance_variable_set(:@warnings, [])
        subject.instance_variable_set(:@metrics, {})

        subject.send(:q15_secret_scan_receipt)

        issues = subject.instance_variable_get(:@issues).join("\n")
        assert_includes(issues, 'Q15 SECRET SCAN')
        assert_includes(issues, '1 actionable')
      end
      true
    end

    test('validation report defaults to no keychain fallback') do
      source = File.read(__dir__ + '/validation_report.rb')

      assert_includes(source, "ENV.fetch('SANE_KEYCHAIN_FALLBACK', '0')")
      assert_includes(source, "ENV['SANE_ALLOW_KEYCHAIN_PROMPTS'] == '1'")
      true
    end

    test('code-signing validation skips keychain and notary checks without explicit prompt opt-in') do
      old_allow = ENV.delete('SANE_ALLOW_KEYCHAIN_PROMPTS')
      old_no_keychain = ENV.delete('SANE_NO_KEYCHAIN')
      old_fallback = ENV.delete('SANE_KEYCHAIN_FALLBACK')

      subject = ValidationReport.new
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@metrics, {})

      subject.send(:q8_code_signing)
      warnings = subject.instance_variable_get(:@warnings).join("\n")

      assert_includes(warnings, 'Code-signing keychain/notary checks skipped in no-prompt validation mode')
      true
    ensure
      ENV['SANE_ALLOW_KEYCHAIN_PROMPTS'] = old_allow if old_allow
      ENV['SANE_NO_KEYCHAIN'] = old_no_keychain if old_no_keychain
      ENV['SANE_KEYCHAIN_FALLBACK'] = old_fallback if old_fallback
    end

    test('support validation reports skipped live credential checks in no-prompt mode') do
      old_allow = ENV.delete('SANE_ALLOW_KEYCHAIN_PROMPTS')
      old_no_keychain = ENV.delete('SANE_NO_KEYCHAIN')
      old_fallback = ENV.delete('SANE_KEYCHAIN_FALLBACK')
      old_cf = ENV.delete('CLOUDFLARE_API_TOKEN')
      old_resend = ENV.delete('RESEND_API_KEY')
      old_ls = ENV.delete('LEMONSQUEEZY_API_KEY')

      subject = ValidationReport.new
      subject.instance_variable_set(:@issues, [])
      subject.instance_variable_set(:@warnings, [])
      subject.instance_variable_set(:@metrics, {})
      subject.define_singleton_method(:resolve_secret_value) { |_service, _account, *_env_names| '' }

      subject.send(:q9_support_infrastructure)
      issues = subject.instance_variable_get(:@issues).join("\n")
      warnings = subject.instance_variable_get(:@warnings).join("\n")

      assert(!issues.include?('key missing'), issues)
      assert_includes(warnings, 'Q9 SUPPORT: Cloudflare API live credential check skipped in no-prompt validation mode')
      assert_includes(warnings, 'Q9 SUPPORT: Resend Email API live credential check skipped in no-prompt validation mode')
      assert_includes(warnings, 'Q9 SUPPORT: Lemon Squeezy API live credential check skipped in no-prompt validation mode')
      true
    ensure
      ENV['SANE_ALLOW_KEYCHAIN_PROMPTS'] = old_allow if old_allow
      ENV['SANE_NO_KEYCHAIN'] = old_no_keychain if old_no_keychain
      ENV['SANE_KEYCHAIN_FALLBACK'] = old_fallback if old_fallback
      ENV['CLOUDFLARE_API_TOKEN'] = old_cf if old_cf
      ENV['RESEND_API_KEY'] = old_resend if old_resend
      ENV['LEMONSQUEEZY_API_KEY'] = old_ls if old_ls
    end
  end
end)
