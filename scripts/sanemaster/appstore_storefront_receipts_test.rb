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

def resource_fixture(root, family)
  directory = File.join(root, 'outputs', 'app-review-current-source', "#{family}-resource")
  FileUtils.mkdir_p(directory)
  artifact_path = File.join(directory, 'resource-soak.json')
  log_path = File.join(directory, 'resource-soak.log')
  bundle = 'com.sanelot.app'
  udid = family == 'iphone' ? 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' : '11111111-2222-3333-4444-555555555555'
  fingerprint = 'e' * 64
  artifact = {
    'status' => 'pass', 'schema_version' => 2, 'sample_count' => 3,
    'physical_sample_count' => 3, 'missing_sample_count' => 0, 'issues' => [],
    'candidate' => { 'bundle_id' => bundle, 'simulator_udid' => udid },
    'target' => {
      'kind' => 'ios-simulator', 'ownership' => 'attached',
      'source_binding' => { 'project' => File.basename(root), 'fingerprint' => fingerprint },
      'cleanup' => { 'result' => 'not_owned' }, 'timeout' => { 'reached' => true }
    }
  }
  File.write(artifact_path, JSON.generate(artifact), mode: 'wx', perm: 0o600)
  File.write(log_path, "resource pass\n", mode: 'wx', perm: 0o600)
  artifact_stat = File.stat(artifact_path)
  log_stat = File.stat(log_path)
  [{
    'status' => 'pass', 'target' => 'ios-simulator', 'bundle_id' => bundle,
    'simulator_udid' => udid, 'source_project' => File.basename(root),
    'source_fingerprint' => fingerprint, 'sample_count' => 3,
    'artifact_path' => artifact_path, 'artifact_sha256' => Digest::SHA256.file(artifact_path).hexdigest,
    'artifact_device' => artifact_stat.dev, 'artifact_inode' => artifact_stat.ino,
    'log_path' => log_path, 'log_sha256' => Digest::SHA256.file(log_path).hexdigest,
    'log_device' => log_stat.dev, 'log_inode' => log_stat.ino
  }, artifact_path]
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
  if family == 'iphone'
    receipt['resource_proof'], = resource_fixture(root, family)
    receipt['app_bundle_id'] = receipt['resource_proof']['bundle_id']
    receipt['simulator_udid'] = receipt['resource_proof']['simulator_udid']
  end
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
  ipad_visual_fixture(root, commit: commit, branch: branch) if family == 'ipad'
  [image, receipt_path]
end

def ipad_visual_fixture(root, commit:, branch:)
  directory = File.join(root, 'outputs', 'app-review-current-source')
  FileUtils.mkdir_p(directory)
  receipt_path = File.join(directory, 'ipad-release-receipt.json')
  resource_proof, = resource_fixture(root, 'ipad')
  receipt = {
    'status' => 'passed', 'git_commit' => commit, 'git_branch' => branch,
    'git_upstream_commit' => commit, 'git_pushed' => true, 'git_dirty' => false,
    'state_count' => 1, 'states' => [{ 'path' => 'state.png' }],
    'app_bundle_id' => resource_proof.fetch('bundle_id'),
    'simulator_udid' => resource_proof.fetch('simulator_udid'),
    'resource_proof' => resource_proof,
    'source_manifest_sha256' => 'd' * 64
  }
  File.write(receipt_path, JSON.pretty_generate(receipt))
  File.chmod(0o600, receipt_path)
  verdict = {
    'status' => 'passed', 'release_clearance' => true,
    'inspected_at_original_size' => true,
    'inspected_count' => 1, 'passed_count' => 1, 'failed_count' => 0,
    'failed_states' => [],
    'source_binding' => {
      'git_commit' => commit,
      'aggregate_receipt_sha256' => Digest::SHA256.file(receipt_path).hexdigest,
      'source_manifest_sha256' => receipt.fetch('source_manifest_sha256')
    }
  }
  verdict_path = File.join(directory, 'ipad-visual-verdict.json')
  File.write(verdict_path, JSON.pretty_generate(verdict))
  File.chmod(0o600, verdict_path)
end

exit(run_tests('App Store source-bound storefront receipts') do
  subject = StorefrontReceiptHarness.new
  identity = { commit: 'a' * 40, branch: 'release/test', clean: true, pushed: true }
  config = {
    'ios' => 'outputs/app-review-current-source/storefront-iphone/*.png',
    'ipad' => 'outputs/app-review-current-source/storefront-ipad/*.png',
    'ipad_gate_receipt' => 'outputs/app-review-current-source/ipad-release-receipt.json',
    'ipad_visual_verdict' => 'outputs/app-review-current-source/ipad-visual-verdict.json'
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

  test('rejects same-byte replacement of a bound resource artifact') do
    Dir.mktmpdir('storefront-resource-replaced-') do |root|
      _image, iphone_receipt = storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      receipt = JSON.parse(File.read(iphone_receipt))
      artifact_path = receipt.dig('resource_proof', 'artifact_path')
      bytes = File.binread(artifact_path)
      File.unlink(artifact_path)
      File.write(artifact_path, bytes, mode: 'wx', perm: 0o600)
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      assert_includes(report[:issues].join("\n"), 'resource proof is stale, incomplete, or changed')
    end
    true
  end

  test('rejects a failed, stale, or count-incomplete iPad visual verdict') do
    Dir.mktmpdir('storefront-visual-verdict-') do |root|
      storefront_fixture(root, family: 'iphone', commit: identity[:commit])
      storefront_fixture(root, family: 'ipad', commit: identity[:commit])
      verdict_path = File.join(root, config.fetch('ipad_visual_verdict'))
      verdict = JSON.parse(File.read(verdict_path))
      verdict['status'] = 'failed'
      verdict['release_clearance'] = false
      verdict['passed_count'] = 0
      verdict['failed_count'] = 1
      verdict['failed_states'] = ['chooser.png']
      verdict['source_binding']['git_commit'] = 'b' * 40
      File.write(verdict_path, JSON.pretty_generate(verdict))
      report = subject.appstore_storefront_receipt_report(
        root: root, screenshots_config: config,
        source_identity: identity, ios_supports_ipad: true
      )
      joined = report[:issues].join("\n")
      assert_includes(joined, 'ipad visual verdict status is not passed')
      assert_includes(joined, 'ipad visual verdict does not clear release')
      assert_includes(joined, 'ipad visual verdict counts do not prove every aggregate state passed')
      assert_includes(joined, 'ipad visual verdict commit does not match current pushed source')
    end
    true
  end
end)
