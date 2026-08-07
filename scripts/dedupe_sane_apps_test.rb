#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'dedupe_sane_apps'

include TestFramework

SCRIPT_PATH = File.expand_path('dedupe_sane_apps.rb', __dir__)
RELEASE_SCRIPT_PATH = File.expand_path('release.sh', __dir__)

exit(run_tests('Dedupe Sane Apps Tests') do
  test_category('Candidate coverage') do
    test('dedupe scans transient staging and release artifact roots') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, "TRANSIENT_STAGE_ROOT = File.expand_path('/tmp/saneapps-staging.noindex')")
      assert_includes(source, "File.expand_path(\"~/SaneApps/apps/\#{app}/outputs/**/\#{app}.app\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/release/**/\#{app}.app\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/release-publish/**/\#{app}.app\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/release-worktrees/**/\#{app}.app\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/tmp/**/\#{app}.app\")")
      true
    end
  end

  test_category('Canonical install policy') do
    test('dedupe always targets /Applications and can promote from artifact roots when missing') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'source = choose_promotion_source(paths, canonical)')
      assert_includes(source, '"/Applications/#{app}.app"')
      assert(!source.include?('return user_path if File.exist?(user_path)'),
             'dedupe should not fall back to ~/Applications as the canonical install target')
      true
    end
  end

  test_category('Index suppression') do
    test('dedupe marks artifact roots as never-index') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, "NEVER_INDEX_MARKER = '.metadata_never_index'")
      assert_includes(source, "File.expand_path(\"~/Library/Developer/Xcode/DerivedData\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/apps/\#{app}/build\")")
      assert_includes(source, "File.expand_path(\"~/SaneApps/apps/\#{app}/outputs\")")
      assert_includes(source, "File.expand_path('~/SaneApps/release')")
      assert_includes(source, 'File.write(marker, \'\')')
      true
    end
  end

  test_category('Launch Services hygiene') do
    test('launch-services-only mode never promotes or trashes app bundles') do
      dedupe = DedupeSaneApps.new(['--apps', 'SaneClip', '--launch-services-only'])
      calls = []
      dedupe.define_singleton_method(:dedupe_app) do |_app|
        raise 'launch-services-only mode attempted destructive dedupe'
      end
      dedupe.define_singleton_method(:flush_launch_services) { calls << :flush_launch_services }
      dedupe.define_singleton_method(:print_results) { |results| calls << [:print_results, results] }

      dedupe.run

      assert_eq(calls, [:flush_launch_services, [:print_results, []]])
      true
    end

    test('dedupe unregisters removed bundles and never resets the whole database') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, "Dir.glob(File.join(root, '**', '*.app'))")
      assert_includes(source, "system(LSREGISTER, '-u', bundle")
      assert_includes(source, "system(LSREGISTER, '-f', canonical")
      assert_includes(source, "system(LSREGISTER, '-gc'")
      assert(!source.include?("'-kill', '-r'"), 'lsregister -kill is removed on current macOS')
      true
    end

    test('dedupe removes stale recorded paths even when their bundles no longer exist') do
      dedupe = DedupeSaneApps.new(['--apps', 'SaneClip', '--launch-services-only'])
      dump = <<~TEXT
        path:                       /Users/tester/.Trash/SaneClip old.app (0x111)
        path:                       /Applications/SaneClip.app (0x112)
        path:                       /Applications/SaneClip.app/Contents/PlugIns/SaneClipWidgets.appex (0x113)
        path:                       /Users/tester/Library/Developer/Xcode/DerivedData/SaneClip-a/Build/Products/Debug/SaneClip.app (0x114)
        path:                       /Applications/SaneBar.app (0x115)
      TEXT
      removed = []
      dedupe.define_singleton_method(:launch_services_dump) { dump }
      dedupe.define_singleton_method(:unregister_launch_services_path) { |path| removed << path }

      dedupe.send(:unregister_recorded_noncanonical_bundles)

      assert_eq(
        removed.sort,
        [
          '/Users/tester/.Trash/SaneClip old.app',
          '/Users/tester/Library/Developer/Xcode/DerivedData/SaneClip-a/Build/Products/Debug/SaneClip.app'
        ].sort
      )
      true
    end

    test('dedupe unregisters trashed app copies without deleting recoverable Trash') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'unregister_trashed_app_bundles')
      assert_includes(source, "File.expand_path('~/.Trash')")
      assert_includes(source, "File.join(trash_root, '**', \"\#{app}*.app\")")
      assert_includes(source, 'unregister_launch_services_path(path)')
      assert(!source.include?("FileUtils.rm_rf(trash_root)"),
             'Launch Services cleanup must not empty or delete the user Trash')
      true
    end

    test('dedupe unregisters release artifacts without deleting them') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'unregister_noncanonical_artifact_bundles')
      assert_includes(source, "File.expand_path(\"~/SaneApps/apps/\#{app}*/build/**/\#{app}.app\")")
      assert_includes(source, "File.expand_path(\"~/Library/Developer/Xcode/DerivedData/\#{app}-*/Build/**/\#{app}.app\")")
      assert_includes(source, '.each { |path| unregister_launch_services_path(path) }')
      method_source = source[/def unregister_noncanonical_artifact_bundles.*?(?=\n  def )/m]
      assert(!method_source.to_s.include?('trash('),
             'release artifacts must be unregistered without deleting the signed outputs')
      true
    end

    test('release finalization always dedupes Launch Services and refreshes the Dock') do
      source = File.read(RELEASE_SCRIPT_PATH)

      assert_includes(source, 'cleanup_release_launch_services')
      assert_includes(source, 'dedupe_sane_apps.rb')
      assert_includes(source, '/usr/bin/killall Dock')
      assert_includes(source, 'cleanup_release_launch_services >/dev/null 2>&1 || true')
      true
    end
  end
end)
