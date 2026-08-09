#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative 'appstore_storefront_receipts'

include TestFramework

class StorefrontReceiptHarness
  include SaneMasterModules::AppStoreStorefrontReceipts
end

def storefront_fixture(root, family:, commit:, branch: 'release/test', bind_images: true, relative_path: false,
                       evidence_key: 'states')
  directory = File.join(root, 'outputs', 'app-review-current-source', "storefront-#{family}")
  FileUtils.mkdir_p(directory)
  image = File.join(directory, '01.png')
  File.binwrite(image, "#{family}-pixels")
  receipt = {
    'status' => 'passed',
    'git_commit' => commit,
    'git_branch' => branch,
    'git_tracking_commit' => 'c' * 40,
    'git_upstream_commit' => commit,
    'git_pushed' => true,
    'git_dirty' => false,
    evidence_key => []
  }
  receipt['schema'] = 'sanelot.app_store_ipad_selection.v1' if evidence_key == 'entries'
  if bind_images
    receipt[evidence_key] << {
      'path' => relative_path ? image.delete_prefix("#{root}/") : image,
      'sha256' => Digest::SHA256.file(image).hexdigest,
      'bytes' => File.size(image)
    }
  end
  receipt_path = File.join(File.dirname(directory), "storefront-#{family}-receipt.json")
  File.write(receipt_path, JSON.pretty_generate(receipt))
  File.chmod(0o600, receipt_path)
  [image, receipt_path]
end

exit(run_tests('App Store source-bound storefront receipts') do
  subject = StorefrontReceiptHarness.new
  identity = { commit: 'a' * 40, branch: 'release/test', clean: true, pushed: true }
  config = {
    'ios' => 'outputs/app-review-current-source/storefront-iphone/*.png',
    'ipad' => 'outputs/app-review-current-source/storefront-ipad/*.png'
  }

  test('accepts exact private receipts that bind both device-family images and pushed source') do
    Dir.mktmpdir('storefront-receipts-') do |root|
      storefront_fixture(root, family: 'iphone', commit: identity[:commit], relative_path: true)
      storefront_fixture(root, family: 'ipad', commit: identity[:commit], evidence_key: 'entries')
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert(report[:ok], report[:issues].join("\n"))
      assert_eq(report[:family_count], 2)
    end
    true
  end

  test('rejects ambiguous receipt evidence arrays') do
    Dir.mktmpdir('storefront-receipts-ambiguous-') do |root|
      _image, receipt_path = storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit], evidence_key: 'entries')
      receipt = JSON.parse(File.read(receipt_path))
      receipt['entries'] = receipt.fetch('states').map(&:dup)
      File.write(receipt_path, JSON.pretty_generate(receipt))
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert_includes(report[:issues].join("\n"), 'image evidence is ambiguous')
    end
    true
  end

  test('rejects duplicate and extra receipt image rows outside the exact selected set') do
    Dir.mktmpdir('storefront-receipts-exact-set-') do |root|
      _image, receipt_path = storefront_fixture(
        root, family: 'iphone', commit: identity[:commit], relative_path: true
      )
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      receipt = JSON.parse(File.read(receipt_path))
      receipt['states'] << receipt['states'].first.dup
      extra = File.join(root, 'outputs', 'app-review-current-source', 'not-selected.png')
      File.binwrite(extra, 'extra-pixels')
      receipt['states'] << {
        'path' => extra.delete_prefix("#{root}/"),
        'sha256' => Digest::SHA256.file(extra).hexdigest,
        'bytes' => File.size(extra)
      }
      File.write(receipt_path, JSON.pretty_generate(receipt))
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      joined = report[:issues].join("\n")
      assert_includes(joined, 'binds screenshot path more than once')
      assert_includes(joined, 'binds unselected screenshot:')
    end
    true
  end

  test('rejects stale source and an iPad receipt that omits screenshot-byte binding') do
    Dir.mktmpdir('storefront-receipts-stale-') do |root|
      storefront_fixture(root, family: 'iphone', commit: 'b' * 40)
      storefront_fixture(root, family: 'ipad', commit: identity[:commit], bind_images: false)
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert(!report[:ok])
      assert_includes(report[:issues].join("\n"), 'iphone storefront receipt commit does not match')
      assert_includes(report[:issues].join("\n"), 'ipad storefront receipt does not bind screenshot 01.png')
    end
    true
  end

  test('rejects a selected image row that omits only its byte count') do
    Dir.mktmpdir('storefront-receipts-missing-bytes-') do |root|
      _image, receipt_path = storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      receipt = JSON.parse(File.read(receipt_path))
      receipt.fetch('states').first.delete('bytes')
      File.write(receipt_path, JSON.pretty_generate(receipt))
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert_includes(report[:issues].join("\n"), 'byte count is missing for 01.png')
    end
    true
  end

  test('rejects receipts when the preflight source itself is dirty or not live-pushed') do
    Dir.mktmpdir('storefront-receipts-source-') do |root|
      storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity.merge(clean: false, pushed: false), ios_supports_ipad: true
      )
      assert_includes(report[:issues], 'storefront receipts require clean source')
      assert_includes(report[:issues], 'storefront receipts require exact live pushed source')
    end
    true
  end

  test('rejects public or symlinked receipt files') do
    Dir.mktmpdir('storefront-receipts-unsafe-') do |root|
      _image, iphone_receipt = storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      File.chmod(0o644, iphone_receipt)
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert_includes(report[:issues].join("\n"), 'iphone storefront receipt mode is not 0600')

      target = "#{iphone_receipt}.target"
      File.rename(iphone_receipt, target)
      File.symlink(target, iphone_receipt)
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert_includes(report[:issues].join("\n"), 'iphone storefront receipt path contains a symlink')
    end
    true
  end
end)
