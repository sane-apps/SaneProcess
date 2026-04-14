#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'

include TestFramework

SCRIPT_PATH = File.expand_path('dedupe_sane_apps.rb', __dir__)

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
end)
