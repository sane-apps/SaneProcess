#!/usr/bin/env ruby
# frozen_string_literal: true

# Pin UTF-8 defaults before the source-reads below. Mirrors the entry-point
# pin in the scripts themselves and the sibling Setapp test files.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require 'fileutils'
require 'tmpdir'
require_relative 'hooks/test/test_framework'
require_relative 'setapp_config'

include TestFramework

def expect_abort_includes(expected)
  begin
    yield
  rescue SystemExit => e
    assert(!e.success?, 'Expected abort to exit nonzero')
    assert_includes(e.message, expected)
    return true
  end
  raise "Expected abort containing #{expected.inspect}"
end

def write_manifest(apps_root, dir_name, setapp_body)
  dir = File.join(apps_root, dir_name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, '.saneprocess'), setapp_body)
end

ENABLED_MANIFEST = <<~YAML.freeze
  setapp:
    enabled: true
    app_id: "%<app_id>s"
    version_id: "1"
    bundle_id: "com.example.%<slug>s"
YAML

DISABLED_MANIFEST = <<~YAML
  setapp:
    enabled: false
YAML

def build_apps_root(peer_dirs: [])
  Dir.mktmpdir('setapp-config-test') do |root|
    apps_root = File.join(root, 'apps')
    # SaneClip/SaneBar are always resolved (SetappConfig::APP_DIRS), so the
    # isolated root must provide their manifests. SaneBar stays disabled.
    write_manifest(apps_root, 'SaneClip', format(ENABLED_MANIFEST, app_id: '9001', slug: 'canon'))
    write_manifest(apps_root, 'SaneBar', DISABLED_MANIFEST)
    peer_dirs.each do |peer|
      write_manifest(apps_root, peer, format(ENABLED_MANIFEST, app_id: '9002', slug: peer.downcase))
    end
    yield root
  end
end

exit(run_tests('Setapp Config Tests') do
  test_category('portal targets') do
    test('resolves the canonical app for a unique app id') do
      build_apps_root do |root|
        target = SetappConfig.portal_targets(root: root)['9001']
        assert_eq(target[:app_name], 'SaneClip')
        assert(target[:app_root].end_with?('apps/SaneClip'), target[:app_root])
      end
      true
    end

    test('aborts on duplicate app ids instead of last-wins overwrite') do
      build_apps_root(peer_dirs: %w[PeerA PeerB]) do |root|
        expect_abort_includes('Duplicate Setapp app id 9002') do
          SetappConfig.portal_targets(root: root)
        end
      end
      true
    end
  end
end)
