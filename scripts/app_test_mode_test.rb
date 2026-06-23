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

  test_category('Gatekeeper launch guard') do
    test('sane_test blocks ad-hoc launches that can show unidentified-developer dialogs') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'Refusing to launch ad-hoc signed')
      assert_includes(source, 'SANETEST_ALLOW_ADHOC_GATEKEEPER_DIALOG')
      assert_includes(source, "'ditto', '--noextattr', '--noacl'")
      true
    end
  end

  test_category('Canonical launch owner') do
    test('app_test_mode delegates Basic and Pro launches to sane_test') do
      source = File.read(SCRIPT_PATH)

      assert_includes(source, 'local launcher="$HOME/SaneApps/infra/SaneProcess/scripts/sane_test.rb"')
      assert_includes(source, 'launcher_args=("$app" "--local" "--release" "--no-logs")')
      assert_includes(source, 'launcher_args+=("--free-mode")')
      assert_includes(source, 'launcher_args+=("--pro-mode")')
      assert_includes(source, 'ruby "$launcher" "${launcher_args[@]}"')
      assert(!source.include?('launch_app_local()'), 'mode launch should not duplicate local app launching')
      assert(!source.include?('launch_app_remote()'), 'mode launch should not duplicate remote app launching')
      true
    end
  end

  test_category('Mini sync preserves tracked Xcode metadata') do
    test('sane_test keeps tracked project workspace metadata even when app .gitignore ignores it') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, "'--include', '*/project.xcworkspace/contents.xcworkspacedata'")
      assert(
        source.index("'--include', '*/project.xcworkspace/contents.xcworkspacedata'") <
          source.index("'--filter', ':- .gitignore'"),
        'tracked Xcode workspace metadata must be included before .gitignore filters can exclude it'
      )
      true
    end
  end
end)
