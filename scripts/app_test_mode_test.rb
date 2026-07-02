#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'hooks/test/test_framework'
require_relative 'sane_test'

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

  test_category('SaneClip signed runtime path') do
    test('sane_test treats SaneClip as a signed Release runtime app') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclick = SaneTest.allocate
      saneclick.instance_variable_set(:@app_name, 'SaneClick')

      assert(saneclip.send(:signed_release_runtime_required?))
      assert(!saneclick.send(:signed_release_runtime_required?))
      true
    end

    test('Release builds keep the production bundle id') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')

      assert(!saneclip.send(:dev_bundle_override_for_build?, 'Release'))
      assert(saneclip.send(:dev_bundle_override_for_build?, 'ProdDebug'))
      true
    end

    test('Release builds never receive unsigned debug overrides') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')

      assert(!saneclip.send(:unsigned_debug_overrides_for_build?, 'Release', false))
      assert(saneclip.send(:unsigned_debug_overrides_for_build?, 'Debug', false))
      assert(!saneclip.send(:unsigned_debug_overrides_for_build?, 'Debug', true))
      true
    end

    test('direct executable launch keeps wrapper environment') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclip.instance_variable_set(:@hardware, false)
      saneclip.instance_variable_set(:@free_mode, false)

      env = saneclip.send(:launch_env_hash)
      assert_eq(env['SANEAPPS_SKIP_MOVE_TO_APPLICATIONS'], '1')
      assert_eq(env['SANEAPPS_PERMISSIONLESS_AUTOMATION'], '1')
      assert_eq(env['SANEVIDEO_ENABLE_HARDWARE_TESTS'], '0')
      true
    end

    test('direct executable launch suppresses app move prompts') do
      saneclip = SaneTest.allocate
      saneclip.instance_variable_set(:@app_name, 'SaneClip')
      saneclip.instance_variable_set(:@allow_keychain, false)

      args = saneclip.send(:direct_launch_args)
      assert_includes(args, '--sane-skip-app-move')
      assert_includes(args, '--sane-no-keychain')

      saneclip.instance_variable_set(:@allow_keychain, true)
      assert_eq(saneclip.send(:direct_launch_args), ['--sane-skip-app-move'])
      true
    end

    test('sane_test direct-launches only quarantined local builds that LaunchServices would reject') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'launch_services_gatekeeper_rejected?(app_path)')
      assert_includes(source, 'return false unless quarantined?(app_path)')
      assert_includes(source, "Open3.capture3('xattr', '-p', 'com.apple.quarantine', app_path)")
      assert_includes(source, 'LaunchServices would show Gatekeeper')
      assert_includes(source, "spawn(launch_env_hash, executable, *direct_launch_args")
      true
    end

    test('sane_test does not SSH or rsync when already running on the Mini') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def running_on_mini_host?')
      assert_includes(source, 'Already running on Mac mini')
      assert_includes(source, "Socket.gethostname.to_s.downcase")
      assert_includes(source, "'/usr/sbin/scutil', '--get', 'ComputerName'")
      assert(
        source.index('running_on_mini_host?') < source.index('mini_reachable?'),
        'the Mini-local check must run before probing ssh mini'
      )
      assert(!source.include?("ENV.fetch('USER', '').downcase == 'stephansmac'"),
             'sane_test must not decide Mini identity from the shared account name')
      true
    end

    test('local pro-mode writes license fallback for the staged runtime bundle id') do
      source = File.read(SANE_TEST_PATH)

      assert_includes(source, 'def local_runtime_bundle_id')
      assert_includes(source, 'bundle_id_for_app(canonical_local_app_path)')
      assert_includes(source, 'bid = local_runtime_bundle_id')
      assert_includes(source, 'set_pro_fallback_local(bid)')
      assert(!source.include?('bid = @config[:dev]'),
             'local pro-mode must not write only the dev bundle id for signed release apps')
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
