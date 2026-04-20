#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'yaml'

require_relative 'hooks/test/test_framework'
require_relative 'appstore_public_screenshot_audit'

include TestFramework

def write_manifest(root, app_id: '1234567890', name: 'SaneTest')
  File.write(
    File.join(root, '.saneprocess'),
    {
      'name' => name,
      'appstore' => { 'app_id' => app_id }
    }.to_yaml
  )
end

def write_storyboard(root)
  docs = File.join(root, 'docs')
  FileUtils.mkdir_p(docs)
  File.write(
    File.join(docs, 'appstore_screenshot_storyboard.yml'),
    {
      'platforms' => {
        'macos' => [
          {
            'file' => 'docs/appstore-mac-01.png',
            'title' => 'Shot 1',
            'purpose' => 'Show the main screen',
            'must_show' => ['main UI']
          },
          {
            'file' => 'docs/appstore-mac-02.png',
            'title' => 'Shot 2',
            'purpose' => 'Show the upgrade path',
            'must_show' => ['upgrade CTA']
          }
        ],
        'ios' => [
          {
            'file' => 'docs/appstore-01-6.7.png',
            'title' => 'Phone shot',
            'purpose' => 'Show phone UI',
            'must_show' => ['phone UI']
          }
        ]
      }
    }.to_yaml
  )
end

exit(run_tests('Public App Store Screenshot Audit Tests') do
  test_category('Live page extraction') do
    test('dedupes repeated screenshot widths and ignores app icons/placeholders') do
      Dir.mktmpdir('appstore-public-audit') do |tmpdir|
        write_manifest(tmpdir)
        write_storyboard(tmpdir)
        subject = AppStorePublicScreenshotAudit.new(project_root: tmpdir)
        html = <<~HTML
          <img src="https://is1-ssl.mzstatic.com/image/thumb/Purple111/v4/foo/AppIcon-0-0.png/1200x630bb.png" />
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-mac-01.png/643x402bb-60.jpg" />
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-mac-01.png/1286x804bb-60.jpg" />
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-01-6.7.png/460x998bb-60.jpg" />
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/Placeholder.mill/1200x630wa.jpg" />
        HTML

        entries = subject.extract_live_entries(html)
        assert_eq(entries.map { |entry| entry[:basename] }, ['appstore-mac-01.png', 'appstore-01-6.7.png'])
        assert_eq(entries.map { |entry| entry[:width] }, [1286, 460])
        assert_eq(entries.map { |entry| entry[:platform] }, ['macos', 'ios'])
      end

      true
    end

    test('materializes template screenshot urls for wider platform coverage') do
      Dir.mktmpdir('appstore-public-audit-template') do |tmpdir|
        write_manifest(tmpdir)
        write_storyboard(tmpdir)
        subject = AppStorePublicScreenshotAudit.new(project_root: tmpdir)
        html = <<~HTML
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-mac-02.png/{w}x{h}{c}.{f}" />
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-01-6.7.png/{w}x{h}{c}.{f}" />
        HTML

        entries = subject.extract_live_entries(html)
        assert_eq(entries.map { |entry| entry[:url] }, [
                    'https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-mac-02.png/1286x804bb-60.jpg',
                    'https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/appstore-01-6.7.png/600x1300bb-60.jpg'
                  ])
      end

      true
    end

    test('treats legacy generic screenshot names as macos when a mac lane exists') do
      Dir.mktmpdir('appstore-public-audit-legacy-mac') do |tmpdir|
        write_manifest(tmpdir)
        write_storyboard(tmpdir)
        subject = AppStorePublicScreenshotAudit.new(project_root: tmpdir)
        html = <<~HTML
          <img src="https://is1-ssl.mzstatic.com/image/thumb/PurpleSource111/v4/foo/screenshot-menu.png/{w}x{h}{c}.{f}" />
        HTML

        entries = subject.extract_live_entries(html)
        assert_eq(entries.first[:platform], 'macos')
      end

      true
    end
  end

  test_category('Mismatch detection') do
    test('flags live count and slot mismatches against the storyboard') do
      Dir.mktmpdir('appstore-public-audit-mismatch') do |tmpdir|
        write_manifest(tmpdir)
        write_storyboard(tmpdir)
        subject = AppStorePublicScreenshotAudit.new(project_root: tmpdir)
        storyboard = subject.storyboard_entries_by_platform
        live = [
          { basename: 'appstore-mac-99.png', platform: 'macos', url: 'https://example.com/a.jpg', order: 0, width: 1286 }
        ]

        issues = subject.audit_issues(storyboard, live)
        assert(issues.any? { |issue| issue.include?('[ios] live public page shows 0 screenshot(s); storyboard expects 1') })
        assert(issues.any? { |issue| issue.include?('[macos] live public page shows 1 screenshot(s); storyboard expects 2') })
        assert(issues.any? { |issue| issue.include?('[macos] slot 1 mismatch: live appstore-mac-99.png vs expected appstore-mac-01.png') })
      end

      true
    end
  end
end)
