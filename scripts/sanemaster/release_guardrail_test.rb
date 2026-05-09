#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'

require_relative '../hooks/test/test_framework'
require_relative 'gate_review'
require_relative 'release'

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

class ReleaseGuardrailHarness
  include SaneMasterModules::GateReview
  include SaneMasterModules::Release

  def initialize
    @stubbed_url_statuses = {}
    @stubbed_asc_paths = {}
    @stubbed_jxa_result = nil
    @last_jxa_script = nil
    @saneprocess_repo_root = File.expand_path('../..', __dir__)
  end

  attr_writer :saneprocess_repo_root

  def saneprocess_repo_root
    @saneprocess_repo_root
  end

  def stub_url_status(url, code:, location: '', error: nil)
    @stubbed_url_statuses[url] = { code: code, location: location, error: error }
  end

  def appstore_fetch_url_status(url)
    @stubbed_url_statuses.fetch(url) do
      { code: 0, location: '', error: "missing stub for #{url}" }
    end
  end

  def stub_asc_json(path, payload)
    @stubbed_asc_paths[path] = payload
  end

  def appstore_connect_token
    'stub-token'
  end

  def ensure_research_gate_clear!(_command_name)
    true
  end

  def asc_get_json(path, token:, base: 'https://api.appstoreconnect.apple.com/v1')
    _ = token
    _ = base
    @stubbed_asc_paths[path]
  end

  def stub_osascript_jxa(output, success:)
    @stubbed_jxa_result = [output, success]
  end

  def run_osascript_jxa(_script)
    @last_jxa_script = _script
    output, success = @stubbed_jxa_result || ['', true]
    status = Struct.new(:success?).new(success)
    [output, status]
  end

  attr_reader :last_jxa_script
end

include TestFramework

exit(run_tests('SaneMaster App Store Guardrail Tests') do
  subject = ReleaseGuardrailHarness.new

  test_category('App Store lane gating') do
    test('appstore preflight skips projects whose App Store lane is disabled') do
      Dir.mktmpdir('disabled-appstore-lane-') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: DirectOnlyApp
            appstore:
              enabled: false
              app_id: "1234567890"
          YAML
        )

        result = nil
        output = nil
        Dir.chdir(dir) do
          output = capture_stdout { result = subject.appstore_preflight([]) }
        end

        assert_eq(result, true)
        assert_includes(output, 'App Store lane disabled in .saneprocess')
        assert_includes(output, 'Use release_preflight for direct-download release readiness')
      end
      true
    end
  end

  test_category('Metadata URL health') do
    test('follows redirects to a healthy final URL') do
      subject.stub_url_status('https://example.com/support', code: 301, location: '/help')
      subject.stub_url_status('https://example.com/help', code: 200)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(report[:ok], 'expected redirect chain to be treated as healthy')
      assert_eq(report[:code], 200)
      assert_eq(report[:final_url], 'https://example.com/help')
      true
    end

    test('fails on HTTP errors') do
      subject.stub_url_status('https://example.com/support', code: 404)

      report = subject.send(:appstore_url_health, 'https://example.com/support')

      assert(!report[:ok], 'expected 404 to fail')
      assert_eq(report[:error], 'HTTP 404')
      true
    end
  end

  test_category('Release test lane policy') do
    test('release preflight blocks macOS 26 ScreenCaptureKit symbols below the release minimum') do
      Dir.mktmpdir('api-compat-') do |dir|
        source = File.join(dir, 'ScreenCaptureService.swift')
        File.write(source, "let configuration = SCScreenshotConfiguration()\n")

        report = subject.send(
          :api_compatibility_guardrail_report,
          config: { 'release' => { 'min_system_version' => '15.0' } },
          source_files: [source]
        )

        assert(report[:applicable], 'expected release API compatibility report to apply')
        assert_eq(report[:issues].length, 1)
        assert_includes(report[:issues].first, 'requires macOS 26.0')
        assert_includes(report[:issues].first, 'release.min_system_version is 15.0')
      end
      true
    end

    test('release preflight allows macOS 26 symbols when the release minimum is high enough') do
      Dir.mktmpdir('api-compat-') do |dir|
        source = File.join(dir, 'ScreenCaptureService.swift')
        File.write(source, "let configuration = SCScreenshotConfiguration()\n")

        report = subject.send(
          :api_compatibility_guardrail_report,
          config: { 'release' => { 'min_system_version' => '26.0' } },
          source_files: [source]
        )

        assert(report[:applicable], 'expected release API compatibility report to apply')
        assert_eq(report[:issues], [])
      end
      true
    end

    test('release preflight treats auto-reconcile source stashes as release blockers') do
      files = [
        'SaneClick/SaneClickApp.swift',
        'Tests/AppStoreReviewGuardrailTests.swift',
        '.DS_Store',
        'fastlane/report.xml',
        '.claude/tool_count.json'
      ]

      blocking = subject.send(:blocking_auto_reconcile_stash_files, files)

      assert_eq(blocking, ['SaneClick/SaneClickApp.swift', 'Tests/AppStoreReviewGuardrailTests.swift'])
      true
    end

    test('release preflight allows only known generated noise in auto-reconcile stashes') do
      files = [
        './.DS_Store',
        'default.profraw',
        'fastlane/reports/rubocop.html',
        '.claude/audit_log.jsonl',
        '.claude/research.md'
      ]

      blocking = subject.send(:blocking_auto_reconcile_stash_files, files)

      assert_eq(blocking, ['.claude/research.md'])
      true
    end

    test('release preflight detects real auto-reconcile git stashes') do
      Dir.mktmpdir('auto-reconcile-stash-') do |dir|
        git = lambda do |*args|
          output, status = Open3.capture2e('git', '-C', dir, *args)
          assert(status.success?, "git #{args.join(' ')} failed: #{output}")
          output
        end

        git.call('init')
        git.call('config', 'user.email', 'test@example.invalid')
        git.call('config', 'user.name', 'SaneProcess Test')
        FileUtils.mkdir_p(File.join(dir, 'SaneClick'))
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = true\n")
        git.call('add', '.')
        git.call('commit', '-m', 'baseline')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('stash', 'push', '-m', 'auto-reconcile-20260509-test')

        reports = subject.send(:auto_reconcile_stash_reports, repo_path: dir)

        assert_eq(reports.length, 1)
        assert_eq(reports.first[:ref], 'stash@{0}')
        assert(reports.first[:stash_sha].to_s.match?(/\A[0-9a-f]{40}\z/), 'expected stash SHA in report')
        assert_eq(reports.first[:blocking_files], ['SaneClick/SaneClickApp.swift'])
      end
      true
    end

    test('release preflight can mark an exact auto-reconcile stash as reviewed') do
      report = {
        ref: 'stash@{0}',
        stash_sha: 'abc123',
        subject: 'On main: auto-reconcile-20260509-test',
        blocking_files: ['SaneClick/SaneClickApp.swift']
      }
      config = {
        'release' => {
          'reviewed_auto_reconcile_stashes' => [
            {
              'stash_sha' => 'abc123',
              'subject' => 'On main: auto-reconcile-20260509-test',
              'decision' => 'superseded',
              'reason' => 'Reviewed against current release candidate; stale App Store-only branch work is not part of direct release.'
            }
          ]
        }
      }

      assert(subject.send(:reviewed_auto_reconcile_stash?, config, report), 'expected exact reviewed stash to be allowed')
      true
    end

    test('release preflight refuses reviewed auto-reconcile entries without a reason') do
      report = {
        ref: 'stash@{0}',
        stash_sha: 'abc123',
        subject: 'On main: auto-reconcile-20260509-test',
        blocking_files: ['SaneClick/SaneClickApp.swift']
      }
      config = {
        'release' => {
          'reviewed_auto_reconcile_stashes' => [
            {
              'stash_sha' => 'abc123',
              'subject' => 'On main: auto-reconcile-20260509-test',
              'decision' => 'superseded',
              'reason' => ''
            }
          ]
        }
      }

      assert(!subject.send(:reviewed_auto_reconcile_stash?, config, report), 'expected missing review reason to keep blocking')
      true
    end

    test('release preflight ignores auto-reconcile stash content already present in HEAD') do
      Dir.mktmpdir('auto-reconcile-stash-applied-') do |dir|
        git = lambda do |*args|
          output, status = Open3.capture2e('git', '-C', dir, *args)
          assert(status.success?, "git #{args.join(' ')} failed: #{output}")
          output
        end

        git.call('init')
        git.call('config', 'user.email', 'test@example.invalid')
        git.call('config', 'user.name', 'SaneProcess Test')
        FileUtils.mkdir_p(File.join(dir, 'SaneClick'))
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = true\n")
        git.call('add', '.')
        git.call('commit', '-m', 'baseline')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('stash', 'push', '-m', 'auto-reconcile-20260509-test')
        File.write(File.join(dir, 'SaneClick', 'SaneClickApp.swift'), "let shipped = false\n")
        git.call('add', '.')
        git.call('commit', '-m', 'recover stashed work')

        reports = subject.send(:auto_reconcile_stash_reports, repo_path: dir)

        assert_eq(reports.length, 0)
      end
      true
    end

    test('release.sh prefers SaneMaster verify before raw xcodebuild fallbacks') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      verify_index = release_script.index('Using SaneMaster verify as the authoritative release test lane.')
      xcodebuild_index = release_script.index('xcodebuild "${args[@]}"')

      assert(!verify_index.nil?, 'expected release.sh to invoke SaneMaster verify first')
      assert(!xcodebuild_index.nil?, 'expected raw xcodebuild fallback to remain available')
      assert(verify_index < xcodebuild_index, 'expected SaneMaster verify path before raw xcodebuild fallback')
      true
    end

    test('release.sh commits website metadata pages alongside appcast updates') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, '"docs/index.html"')
      assert_includes(release_script, '"docs/download.html"')
      assert_includes(release_script, '"website/index.html"')
      assert_includes(release_script, '"website/download.html"')
      assert_includes(release_script, 'sync release metadata for v${VERSION}')
      true
    end

    test('release.sh accepts websites that route downloads through /download') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'local download_page_url="https://${SITE_HOST}/download"')
      assert_includes(release_script, 'local homepage_download_ver=""')
      assert_includes(release_script, 'Website download link points to v${homepage_download_ver}, expected v${VERSION}: ${site_url}')
      assert_includes(release_script, 'Website download flow verified via ${download_page_url}: ${expected_download_url}')
      true
    end

    test('release.sh falls back to a clean webhook clone when the local worker checkout is dirty or behind') do
      release_script = File.read(File.expand_path('../release.sh', __dir__))

      assert_includes(release_script, 'resolve_release_webhook_checkout()')
      assert_includes(release_script, 'using a clean temporary clone for webhook release sync')
      assert_includes(release_script, 'git clone --no-checkout "${remote_url}" "${clean_repo}"')
      assert_includes(release_script, 'WEBHOOK_WORK_DIR="${clean_repo}"')
      assert(!release_script.include?('Refusing to deploy a mixed Worker checkout.'),
             'expected the old hard stop on dirty sane-email-automation checkout to be removed')
      true
    end
  end

  test_category('Release gate fixtures') do
    test('finds app-specific gate fixtures in the SaneProcess fixture registry') do
      Dir.mktmpdir('release-gates-') do |dir|
        fixtures_dir = File.join(dir, 'test', 'fixtures', 'gates')
        FileUtils.mkdir_p(fixtures_dir)
        File.write(
          File.join(fixtures_dir, 'sanebar_icon_visibility_drag.json'),
          JSON.generate(
            'rules' => [
              {
                'id' => 'sanebar-icon',
                'trigger' => 'SaneBar icon visibility drag',
                'seed' => 'SaneBar icon visibility drag regressed',
                'block' => ['Release SaneBar icon visibility drag without coverage'],
                'allow' => ['Release SaneClip listing update']
              }
            ]
          )
        )
        File.write(File.join(fixtures_dir, 'saneclip_listing.json'), '{}')
        subject.saneprocess_repo_root = dir

        paths = subject.send(:release_gate_fixture_paths, 'SaneBar')
        reports = subject.send(:release_gate_fixture_reports, 'SaneBar')

        assert_eq(paths.length, 1)
        assert(paths.first.end_with?('sanebar_icon_visibility_drag.json'))
        assert_eq(reports.length, 1)
        assert(reports.first[:passed], "expected fixture to pass: #{reports.first.inspect}")
      end
      true
    end

    test('reports malformed app-specific gate fixtures as failed release evidence') do
      Dir.mktmpdir('release-gates-bad-') do |dir|
        fixtures_dir = File.join(dir, 'test', 'fixtures', 'gates')
        FileUtils.mkdir_p(fixtures_dir)
        File.write(File.join(fixtures_dir, 'sanebar_bad.json'), '{"rules": [')
        subject.saneprocess_repo_root = dir

        reports = subject.send(:release_gate_fixture_reports, 'SaneBar')

        assert_eq(reports.length, 1)
        assert_eq(reports.first[:passed], false)
      end
      true
    end
  end

  test_category('Artifact marker detection') do
    test('detects donation and support markers in App Store artifacts') do
      hits = subject.send(
        :appstore_donation_markers,
        "Sponsor on GitHub\nSupport independent development\nBTC"
      )

      assert_includes(hits, 'GitHub Sponsors link/copy')
      assert_includes(hits, 'supporter appeal copy')
      assert_includes(hits, 'crypto donation copy')
      true
    end

    test('detects outside-update markers in App Store artifacts') do
      hits = subject.send(
        :appstore_update_markers,
        strings_out: "SaneSparkleRow\nCheck for updates automatically\nSoftware Updates\nUpdateService",
        otool_out: "@rpath/Sparkle.framework/Versions/B/Sparkle"
      )

      assert_includes(hits, 'Sparkle framework linkage')
      assert_includes(hits, 'Sparkle settings UI')
      assert_includes(hits, 'updater service type')
      true
    end

    test('ignores generic updater copy without a real updater signal') do
      hits = subject.send(
        :appstore_update_markers,
        strings_out: "SaneSparkleRow\nCheck for updates automatically\nCheck for updates right now\nSoftware Updates",
        otool_out: ''
      )

      assert_eq(hits, [])
      true
    end

    test('detects direct purchase markers in App Store artifacts') do
      hits = subject.send(
        :appstore_direct_purchase_markers,
        "Use Purchase Key\nActivation Code\nhttps://go.saneapps.com/buy/saneclick"
      )

      assert_includes(hits, 'website checkout URL')
      assert_includes(hits, 'purchase key entry copy')
      true
    end

    test('ignores generic license-key copy when StoreKit unlock is configured') do
      hits = subject.send(
        :appstore_direct_purchase_markers,
        "Enter License Key\nLicense",
        built_product_id: 'com.example.unlock'
      )

      assert_eq(hits, [])
      true
    end

    test('warns when watch marketing icon edges are too dark') do
      subject.define_singleton_method(:image_edge_luminance_report) do |_path|
        {
          'average_edge_luminance' => 18.0,
          'min_edge_luminance' => 4.0
        }
      end

      warning = subject.send(:watch_marketing_icon_warning, '/tmp/watch-marketing-1024.png')

      assert_includes(warning, 'Watch marketing icon edges are very dark')
      true
    end
  end

  test_category('Appcast guardrails') do
    test('flags informational appcast entries that cannot route to a manual download page') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_links, xml)

      assert_eq(hits, ['2.2.12'])
      true
    end

    test('accepts informational appcast entries that include a manual download link') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_missing_links, xml)

      assert_eq(hits, [])
      true
    end

    test('flags informational appcast entries that compare display versions against numeric build versions') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2.2.8</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_mismatched_constraint_versions, xml)

      assert_eq(hits, ['2.2.12'])
      true
    end

    test('accepts informational appcast entries that compare against numeric build cutoffs') do
      xml = <<~XML
        <rss><channel>
          <item>
            <title>2.2.12</title>
            <link>https://example.com/download</link>
            <sparkle:informationalUpdate>
              <sparkle:belowVersion>2208</sparkle:belowVersion>
            </sparkle:informationalUpdate>
            <enclosure url="https://example.com/SaneClip-2.2.12.zip"
                       sparkle:version="2212"
                       sparkle:shortVersionString="2.2.12" />
          </item>
        </channel></rss>
      XML

      hits = subject.send(:informational_appcast_entries_mismatched_constraint_versions, xml)

      assert_eq(hits, [])
      true
    end
  end

  test_category('Provisioning profile installer') do
    test('keeps the newest duplicate download and installs it by UUID') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(downloads_dir)

        older = File.join(downloads_dir, 'SaneClick_Mac_App_Store.provisionprofile')
        newer = File.join(downloads_dir, 'SaneClick_Mac_App_Store-2.provisionprofile')
        File.write(older, 'older')
        File.write(newer, 'newer')
        File.utime(Time.now - 60, Time.now - 60, older)
        File.utime(Time.now, Time.now, newer)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          {
            'Name' => 'SaneClick Mac App Store',
            'UUID' => (path.end_with?('-2.provisionprofile') || path.include?('uuid-new')) ? 'uuid-new' : 'uuid-old'
          }
        end

        results = subject.send(
          :install_provisioning_profiles,
          [older, newer],
          remove_source: false,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        installed = results.find { |result| !result[:skipped] }
        skipped = results.find { |result| result[:skipped] }

        assert_eq(installed[:uuid], 'uuid-new')
        assert_eq(installed[:ok], true)
        assert(File.exist?(File.join(xcode_dir, 'uuid-new.provisionprofile')))
        assert_eq(skipped[:reason], 'older duplicate download')
      end
      true
    end

    test('removes skipped duplicate downloads when delete-source is enabled') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(downloads_dir)

        older = File.join(downloads_dir, 'SaneClick_Finder_Sync_Mac_App_Store.provisionprofile')
        newer = File.join(downloads_dir, 'SaneClick_Finder_Sync_Mac_App_Store-2.provisionprofile')
        File.write(older, 'older')
        File.write(newer, 'newer')
        File.utime(Time.now - 60, Time.now - 60, older)
        File.utime(Time.now, Time.now, newer)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          {
            'Name' => 'SaneClick Finder Sync Mac App Store',
            'UUID' => (path.end_with?('-2.provisionprofile') || path.include?('uuid-new')) ? 'uuid-new' : 'uuid-old'
          }
        end

        results = subject.send(
          :install_provisioning_profiles,
          [older, newer],
          remove_source: true,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        skipped = results.find { |result| result[:skipped] }
        installed = results.find { |result| !result[:skipped] }

        assert(!File.exist?(older), 'expected skipped duplicate source to be deleted')
        assert(!File.exist?(newer), 'expected installed source to be deleted')
        assert_eq(skipped[:removed_source], true)
        assert_eq(installed[:removed_source], true)
      end
      true
    end

    test('breaks duplicate ties by the newer profile lifetime instead of filesystem order') do
      Dir.mktmpdir do |dir|
        first = File.join(dir, 'A-SaneClip.mobileprovision')
        second = File.join(dir, 'B-SaneClip.mobileprovision')
        File.write(first, 'first')
        File.write(second, 'second')
        same_time = Time.now
        File.utime(same_time, same_time, first)
        File.utime(same_time, same_time, second)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.end_with?('A-SaneClip.mobileprovision')
            {
              'Name' => 'SaneClip iOS App Store',
              'UUID' => 'uuid-old',
              'CreationDate' => '2026-04-01 12:00:00 +0000',
              'ExpirationDate' => '2026-04-15 12:00:00 +0000'
            }
          else
            {
              'Name' => 'SaneClip iOS App Store',
              'UUID' => 'uuid-new',
              'CreationDate' => '2026-04-02 12:00:00 +0000',
              'ExpirationDate' => '2026-05-15 12:00:00 +0000'
            }
          end
        end

        selection = subject.send(:canonicalize_provisioning_profile_inputs, [first, second])

        assert_eq(selection[:chosen].length, 1)
        assert_eq(selection[:chosen].first[:uuid], 'uuid-new')
        assert_eq(selection[:skipped].first[:uuid], 'uuid-old')
      end
      true
    end

    test('prefers Apple Distribution app store profiles over stale 3rd party profiles with the same name') do
      Dir.mktmpdir do |dir|
        legacy = File.join(dir, 'SaneClick_Finder_Sync_Mac_App_Store.provisionprofile')
        modern = File.join(dir, 'SaneClick_Finder_Sync_Mac_App_Store-2.provisionprofile')
        File.write(legacy, 'legacy')
        File.write(modern, 'modern')
        same_time = Time.now
        File.utime(same_time, same_time, legacy)
        File.utime(same_time, same_time, modern)

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.end_with?('-2.provisionprofile')
            {
              'Name' => 'SaneClick Finder Sync Mac App Store',
              'UUID' => 'uuid-modern',
              'CreationDate' => '2026-04-03 19:06:58 +0000',
              'ExpirationDate' => '2027-03-09 21:13:27 +0000',
              'DeveloperCertificates' => [{ 'CommonName' => 'Apple Distribution: Stephan Joseph (M78L6FXD48)' }]
            }
          else
            {
              'Name' => 'SaneClick Finder Sync Mac App Store',
              'UUID' => 'uuid-legacy',
              'CreationDate' => '2026-03-26 17:29:29 +0000',
              'ExpirationDate' => '2027-03-09 21:17:04 +0000',
              'DeveloperCertificates' => [{ 'CommonName' => '3rd Party Mac Developer Application: Stephan Joseph (M78L6FXD48)' }]
            }
          end
        end

        selection = subject.send(:canonicalize_provisioning_profile_inputs, [legacy, modern])

        assert_eq(selection[:chosen].length, 1)
        assert_eq(selection[:chosen].first[:uuid], 'uuid-modern')
        assert_eq(selection[:skipped].first[:uuid], 'uuid-legacy')
      end
      true
    end

    test('removes stale installed copies with the same name before copying the new profile') do
      Dir.mktmpdir do |dir|
        mobile_dir = File.join(dir, 'mobile')
        xcode_dir = File.join(dir, 'xcode')
        downloads_dir = File.join(dir, 'downloads')
        FileUtils.mkdir_p(mobile_dir)
        FileUtils.mkdir_p(downloads_dir)

        stale = File.join(mobile_dir, 'uuid-old.mobileprovision')
        fresh = File.join(downloads_dir, 'SaneClip_iOS_App_Store.mobileprovision')
        File.write(stale, 'stale')
        File.write(fresh, 'fresh')

        subject.define_singleton_method(:decode_mobileprovision) do |path|
          if path.include?('uuid-old')
            { 'Name' => 'SaneClip iOS App Store', 'UUID' => 'uuid-old' }
          else
            { 'Name' => 'SaneClip iOS App Store', 'UUID' => 'uuid-new' }
          end
        end

        results = subject.send(
          :install_provisioning_profiles,
          [fresh],
          remove_source: true,
          destination_roots: {
            mobileprovision: mobile_dir,
            provisionprofile: xcode_dir
          }
        )

        installed = results.find { |result| result[:ok] && !result[:skipped] }
        assert(!File.exist?(stale), 'expected stale installed profile to be removed')
        assert(File.exist?(File.join(mobile_dir, 'uuid-new.mobileprovision')))
        assert(!File.exist?(fresh), 'expected source download to be deleted after successful install')
        assert_includes(installed[:removed_existing], stale)
      end
      true
    end
  end

  test_category('App Store target graph audit') do
    test('fails when the App Store scheme reuses the direct macOS target') do
      manifest = {
        'schemes' => {
          'SaneClick' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } },
          'SaneClick-AppStore' => { 'build' => { 'targets' => { 'SaneClick' => 'all' } } }
        },
        'targets' => {
          'SaneClick' => {
            'type' => 'application',
            'platform' => 'macOS',
            'dependencies' => [{ 'package' => 'Sparkle' }]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneClick',
        appstore_scheme: 'SaneClick-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store scheme SaneClick-AppStore reuses direct application target(s): SaneClick')
      assert_includes(hits, 'App Store target SaneClick still links Sparkle at the target graph level')
      true
    end

    test('fails when the App Store target still relies on strip scripts or Sparkle plist keys') do
      manifest = {
        'schemes' => {
          'SaneSales' => { 'build' => { 'targets' => { 'SaneSales' => 'all' } } },
          'SaneSales-AppStore' => { 'build' => { 'targets' => { 'SaneSalesAppStore' => 'all' } } }
        },
        'targets' => {
          'SaneSales' => {
            'type' => 'application',
            'platform' => 'macOS'
          },
          'SaneSalesAppStore' => {
            'type' => 'application',
            'platform' => 'macOS',
            'info' => { 'properties' => { 'SUFeedURL' => 'https://example.com/appcast.xml' } },
            'postBuildScripts' => [
              { 'name' => 'Strip Sparkle for App Store', 'script' => 'ruby weaken_sparkle.rb "$APP_BINARY"' }
            ]
          }
        }
      }

      hits = subject.send(
        :appstore_target_graph_issues,
        manifest: manifest,
        direct_scheme: 'SaneSales',
        appstore_scheme: 'SaneSales-AppStore',
        platform: 'macOS'
      )

      assert_includes(hits, 'App Store target SaneSalesAppStore still declares Sparkle Info.plist keys (SUFeedURL)')
      assert_includes(hits, 'App Store target SaneSalesAppStore still relies on Sparkle strip/weaken scripts')
      true
    end
  end

  test_category('Reviewer IAP path guardrails') do
    test('accepts FOUND from Safari probe even if Safari exits non-zero') do
      subject.stub_osascript_jxa("FOUND\nERROR:Error: Can't convert types.\n", success: false)

      found = subject.send(
        :appstore_version_ui_includes_iap?,
        app_id: '123',
        platform: 'macos',
        product_id: 'com.example.unlock'
      )

      assert_eq(found, true)
      true
    end

    test('scopes Safari IAP probe to the requested platform version page URL') do
      subject.stub_osascript_jxa("MISSING\n", success: true)

      subject.send(
        :appstore_version_ui_includes_iap?,
        app_id: '123',
        platform: 'macos',
        product_id: 'com.example.unlock'
      )

      assert_includes(subject.last_jxa_script, 'location.href')
      assert_includes(subject.last_jxa_script, 'https://appstoreconnect.apple.com/apps/123/distribution/macos/version/inflight')
      true
    end

    test('fails when review notes do not tell App Review where to find Pro') do
      report = subject.send(
        :reviewer_access_guardrail_report,
        source_blob: {
          'all' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n",
          'macos' => "import Foundation\nfinal class LicenseService {}\nstruct WelcomeGateView {}\nlet hasSeenWelcome = true\nfunc purchasePro() {}\n"
        },
        appstore_config: {
          'review_notes' => 'Basic is free. Pro is a one-time in-app purchase. No external checkout or license keys.'
        },
        platforms: ['macos']
      )

      assert_includes(
        report[:issues],
        '[macos] Review notes do not tell App Review where to find the optional Pro unlock (for example Settings > License or another visible Unlock Pro path)'
      )
      assert_includes(
        report[:warnings],
        '[macos] Onboarding paywall appears one-shot in code, but review notes do not mention a durable post-onboarding upgrade path like Settings > License'
      )
      true
    end

    test('fails when review notes mention Settings > License but source has no license surface') do
      report = subject.send(
        :reviewer_access_guardrail_report,
        source_blob: {
          'all' => "import Foundation\nfinal class LicenseService {}\nfunc purchasePro() {}\n",
          'ios' => "import Foundation\nfinal class LicenseService {}\nfunc purchasePro() {}\n"
        },
        appstore_config: {
          'review_notes_by_platform' => {
            'ios' => 'Basic is free. Unlock Pro is optional. Open Settings > License and tap Unlock Pro. No external checkout or license keys.'
          }
        },
        platforms: ['ios']
      )

      assert_includes(
        report[:issues],
        '[ios] Review notes mention a License screen/section, but no License surface exists in the ios source'
      )
      true
    end

  end

  test_category('ASC version lane guardrails') do
    test('fails when a different editable ASC lane exists for the platform') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-1', 'attributes' => { 'versionString' => '1.2.2', 'appStoreState' => 'REJECTED' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '1.2.3'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], 'conflict: 1.2.2 (REJECTED)')
      assert_includes(
        report[:issues],
        'App Store Connect has editable macos lane(s) 1.2.2 (REJECTED), but local target is 1.2.3. Retarget or clear that lane before submission.'
      )
      true
    end

    test('passes when the target ASC lane already matches the local version') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=IOS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-2', 'attributes' => { 'versionString' => '2.0.0', 'appStoreState' => 'READY_FOR_REVIEW' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'ios',
        version_string: '2.0.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '2.0.0 (READY_FOR_REVIEW)')
      assert_eq(report[:issues], [])
      true
    end

    test('fails when the local version already exists in a final ASC state') do
      subject.stub_asc_json(
        '/apps/123/appStoreVersions?filter[platform]=MAC_OS&limit=200',
        {
          'data' => [
            { 'id' => 'lane-3', 'attributes' => { 'versionString' => '3.1.0', 'appStoreState' => 'READY_FOR_SALE' } }
          ]
        }
      )

      report = subject.send(
        :asc_version_lane_guardrail_report,
        app_id: '123',
        platform: 'macos',
        version_string: '3.1.0'
      )

      assert(report[:applicable], 'expected report to apply')
      assert_eq(report[:summary], '3.1.0 (READY_FOR_SALE)')
      assert_includes(
        report[:issues],
        'App Store Connect already has macos version 3.1.0 in final state READY_FOR_SALE — bump MARKETING_VERSION before submission.'
      )
      true
    end
  end

  test_category('macOS App Store signing audit') do
    test('ignores test bundles when collecting macOS App Store signing targets') do
      Dir.mktmpdir do |dir|
        project_yml = File.join(dir, 'project.yml')
        File.write(project_yml, <<~YAML)
          targets:
            MainApp:
              type: application
              platform: macOS
              bundleId: com.example.app
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "Apple Distribution"
            MainAppTests:
              type: bundle.unit-test
              platform: macOS
              bundleId: com.example.appTests
              settings:
                configs:
                  Release-AppStore:
                    CODE_SIGN_STYLE: Automatic
                    CODE_SIGN_IDENTITY: "-"
        YAML

        targets = subject.send(:appstore_macos_signing_targets, project_yml)

        assert_eq(targets.length, 1)
        assert_eq(targets.first[:name], 'MainApp')
      end
      true
    end
  end

  test_category('Verify output parsing') do
    test('does not treat mixed pass and failure output as a release-safe success') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
        /tmp/SaneVideoTests.swift:42: error: -[SaneVideoTests.ExampleTests testExample] : XCTAssertTrue failed
        ** TEST FAILED **
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'expected failure markers to be detected')
      assert(!subject.send(:verify_output_indicates_success?, body), 'mixed output must not be treated as success')
      true
    end

    test('accepts a clean Swift Testing summary when no failure markers are present') do
      body = <<~LOG
        ✔ Test run with 686 tests in 101 suites passed after 14.545 seconds.
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'clean output should not report failure')
      assert(subject.send(:verify_output_indicates_success?, body), 'clean output should still count as success')
      true
    end

    test('accepts verify clean-pass override even when raw runner failure markers are present') do
      body = <<~LOG
        ** TEST FAILED **
        ✅ 7 targets (clean pass despite a non-zero runner exit)
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detectable')
      assert(subject.send(:verify_output_indicates_success?, body), 'clean-pass override should win for release preflight parsing')
      true
    end

    test('treats auto-dedupe-only verify output as release-safe cleanup') do
      body = <<~LOG
        🧹 Auto-deduping runtime app copies for SaneBar...
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
            - /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
      LOG

      assert(!subject.send(:verify_output_indicates_failure?, body), 'dedupe cleanup should not look like a test failure')
      assert(subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'dedupe-only cleanup should count as release-safe cleanup')
      true
    end

    test('does not treat mixed test failure plus dedupe cleanup as release-safe cleanup') do
      body = <<~LOG
        ** TEST FAILED **
        Trashing /Users/example/Library/Developer/Xcode/DerivedData/SaneBar/Build/Products/Debug/SaneBar.app
        Refreshing Launch Services
        🧹 Auto-deduping runtime app copies for SaneBar...
        SaneBar:
          canonical: /Applications/SaneBar.app
          present:   true
          trashed:   1
      LOG

      assert(subject.send(:verify_output_indicates_failure?, body), 'raw failure markers should still be detected')
      assert(!subject.send(:verify_output_indicates_runtime_dedupe_cleanup?, body, app_name: 'SaneBar'),
             'real test failures must not be treated as dedupe-only cleanup')
      true
    end
  end
end)
