#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'

include TestFramework

SCRIPT_PATH = File.expand_path('app_test_mode.sh', __dir__)
SANE_TEST_PATH = File.expand_path('sane_test.rb', __dir__)

exit(run_tests('App Test Mode Bootstrap Tests') do
  test_category('Bootstrap install path') do
    test('local bootstrap uses release test_mode staging instead of debug launch') do
      source = File.read(SCRIPT_PATH)

      assert_includes(
        source,
        'SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs'
      )
      assert(!source.include?('SANEMASTER_CANONICAL_APP_PATH="$HOME/Applications/${app}.app" ./scripts/SaneMaster.rb launch'),
             'bootstrap should not rely on launch without a prebuilt Debug app')
      true
    end

    test('remote bootstrap uses release test_mode staging instead of debug launch') do
      source = File.read(SCRIPT_PATH)

      assert_includes(
        source,
        'SANEMASTER_CANONICAL_APP_PATH="/Applications/${app}.app" ./scripts/SaneMaster.rb test_mode --release --no-logs >/tmp/$(to_lower "$app")-bootstrap.log 2>&1'
      )
      true
    end
  end

  test_category('No user Applications fallback') do
    test('app_test_mode avoids ~/Applications installs and transient duplicates') do
      source = File.read(SCRIPT_PATH)

      assert(!source.include?('$HOME/Applications/${app}.app'),
             'app_test_mode should not stage runtime copies into ~/Applications')
      assert_includes(source, '/tmp/saneapps-staging.noindex/${app}.app')
      true
    end
  end

  test_category('No-keychain fallback domain') do
    test('app_test_mode writes fallback data into the app defaults domain and clears legacy domain') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'echo "${bundle_id}"')
      assert_includes(source, 'echo "${bundle_id}.no-keychain"')
      assert(source.include?('defaults delete "$legacy_domain" "$key_key"'),
             'app_test_mode should clear legacy no-keychain fallback keys after writing current defaults')
      true
    end

    test('sane_test writes fallback data into the app defaults domain and clears legacy domain') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def fallback_domain(bundle_id)')
      assert_includes(source, 'bundle_id')
      assert_includes(source, 'def legacy_fallback_domain(bundle_id)')
      assert(source.include?("system('defaults', 'delete', legacy_domain, key"),
             'sane_test should clear legacy no-keychain fallback keys after writing current defaults')
      true
    end
  end

  test_category('Hardware verification mode') do
    test('sane_test supports real SaneVideo camera launches') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, "@hardware = args.include?('--hardware')")
      assert_includes(source, 'SANEAPPS_PERMISSIONLESS_AUTOMATION=#{permissionless_automation}')
      assert_includes(source, 'SANEVIDEO_ENABLE_HARDWARE_TESTS=#{hardware_tests}')
      assert_includes(source, 'Allow real hardware/permission prompts for SaneVideo camera verification')
      true
    end
  end
end)
