#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'test_mode'

class TestModeHarness
  include SaneMasterModules::Base
  include SaneMasterModules::TestMode
end

include TestFramework

Status = Struct.new(:success?) unless defined?(Status)
TEST_MODE_PATH = File.expand_path('test_mode.rb', __dir__)

exit(run_tests('SaneMaster Test Mode Fallback Tests') do
  subject = TestModeHarness.new

  test_category('Unsigned fallback detection') do
    test('project name comes from manifest in suffixed worktree directories') do
      Dir.mktmpdir('SaneBar-2.1.62-audit-') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneBar\nscheme: SaneBar\n")

        Dir.chdir(dir) do
          harness = TestModeHarness.new

          assert_eq(harness.send(:project_name), 'SaneBar')
          assert_eq(harness.send(:project_scheme), 'SaneBar')
        end
      end

      true
    end

    test('retries unsigned debug after provisioning-profile iCloud failure') do
      ENV['SANEMASTER_HEADLESS'] = '1'
      ENV.delete('SANEMASTER_UNSIGNED_FALLBACK_ACTIVE')

      output = <<~TEXT
        /Users/tester/SaneClip.xcodeproj: error: "SaneClip" requires a provisioning profile with the iCloud feature.
        Automatic signing is disabled and unable to generate a profile.
      TEXT

      result = subject.send(
        :should_retry_unsigned_debug?,
        build_config: 'Release',
        output: output,
        status: Status.new(false)
      )

      assert(result, 'expected provisioning-profile failure to trigger unsigned fallback')
      true
    ensure
      ENV.delete('SANEMASTER_HEADLESS')
      ENV.delete('SANEMASTER_UNSIGNED_FALLBACK_ACTIVE')
    end

    test('SaneClip does not retry unsigned debug after signing failure') do
      ENV['SANEMASTER_HEADLESS'] = '1'
      ENV.delete('SANEMASTER_UNSIGNED_FALLBACK_ACTIVE')

      output = <<~TEXT
        /Users/tester/SaneClip.xcodeproj: error: "SaneClip" requires a provisioning profile with the iCloud feature.
        Automatic signing is disabled and unable to generate a profile.
      TEXT

      Dir.mktmpdir('sanemaster-saneclip-runtime') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneClip\nscheme: SaneClip\n")

        Dir.chdir(dir) do
          harness = TestModeHarness.new
          result = harness.send(
            :should_retry_unsigned_debug?,
            build_config: 'Release',
            output: output,
            status: Status.new(false)
          )

          assert(!result, 'SaneClip must fail closed instead of launching unsigned Debug')
        end
      end

      true
    ensure
      ENV.delete('SANEMASTER_HEADLESS')
      ENV.delete('SANEMASTER_UNSIGNED_FALLBACK_ACTIVE')
    end

    test('does not retry when build already succeeded') do
      ENV['SANEMASTER_HEADLESS'] = '1'

      result = subject.send(
        :should_retry_unsigned_debug?,
        build_config: 'Release',
        output: 'BUILD SUCCEEDED',
        status: Status.new(true)
      )

      assert(!result, 'successful builds should never trigger unsigned fallback')
      true
    ensure
      ENV.delete('SANEMASTER_HEADLESS')
    end
  end

  test_category('Launch mode preservation') do
    test('SaneClip test_mode always selects signed Release runtime') do
      saved_config = ENV['SANEMASTER_BUILD_CONFIG']

      Dir.mktmpdir('sanemaster-saneclip-launch') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneClip\nscheme: SaneClip\n")

        Dir.chdir(dir) do
          harness = TestModeHarness.new

          assert_eq(harness.send(:launch_build_config, []), 'Release')
          assert_eq(harness.send(:launch_build_config, ['--proddebug']), 'Release')

          ENV['SANEMASTER_BUILD_CONFIG'] = 'Debug'
          assert_eq(harness.send(:launch_build_config, []), 'Release')
        end
      end

      true
    ensure
      if saved_config.nil?
        ENV.delete('SANEMASTER_BUILD_CONFIG')
      else
        ENV['SANEMASTER_BUILD_CONFIG'] = saved_config
      end
    end

    test('launch can reuse existing canonical app when DerivedData product was cleaned') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "canonical_existing_app = File.join('/Applications', \"\#{project_name}.app\")")
      assert_includes(source, 'Using existing canonical app')
      true
    end

    test('launch finds build products under an isolated CFFIXED_USER_HOME') do
      saved_fixed_home = ENV['CFFIXED_USER_HOME']

      Dir.mktmpdir('sanemaster-isolated-home') do |dir|
        project_dir = File.join(dir, 'project')
        fixed_home = File.join(dir, 'fixture-home')
        app_path = File.join(
          fixed_home,
          'Library/Developer/Xcode/DerivedData/SaneHosts-test/Build/Products/Release/SaneHosts.app'
        )
        executable = File.join(app_path, 'Contents/MacOS/SaneHosts')
        FileUtils.mkdir_p([project_dir, File.dirname(executable)])
        File.write(File.join(project_dir, '.saneprocess'), "name: SaneHosts\nscheme: SaneHosts\n")
        File.write(executable, "#!/bin/sh\n")
        FileUtils.chmod(0o755, executable)
        ENV['CFFIXED_USER_HOME'] = fixed_home

        Dir.chdir(project_dir) do
          harness = TestModeHarness.new

          assert_includes(harness.send(:built_app_candidates, 'Release'), app_path)
          assert(harness.send(:app_bundle_executable?, app_path), 'isolated app must have a runnable executable')
        end
      end

      true
    ensure
      saved_fixed_home.nil? ? ENV.delete('CFFIXED_USER_HOME') : ENV['CFFIXED_USER_HOME'] = saved_fixed_home
    end

    test('canonical app override rejects arbitrary directories') do
      saved_override = ENV['SANEMASTER_CANONICAL_APP_PATH']

      Dir.mktmpdir('sanemaster-unsafe-stage') do |dir|
        File.write(File.join(dir, '.saneprocess'), "name: SaneHosts\nscheme: SaneHosts\n")
        ENV['SANEMASTER_CANONICAL_APP_PATH'] = dir

        error = Dir.chdir(dir) do
          begin
            TestModeHarness.new.send(:canonical_local_app_path)
            nil
          rescue ArgumentError => e
            e
          end
        end

        assert(error, 'arbitrary override must fail closed')
        assert_includes(error.message, 'Unsafe canonical app override')
      end

      true
    ensure
      saved_override.nil? ? ENV.delete('SANEMASTER_CANONICAL_APP_PATH') : ENV['SANEMASTER_CANONICAL_APP_PATH'] = saved_override
    end

    test('signing secret loader imports only signing credentials') do
      saved_home = ENV['HOME']
      saved_signing = ENV.delete('ASC_AUTH_KEY_ID')
      saved_unrelated = ENV.delete('LEMONSQUEEZY_API_KEY')

      Dir.mktmpdir('sanemaster-signing-secrets') do |dir|
        secrets_dir = File.join(dir, '.config', 'saneprocess')
        FileUtils.mkdir_p(secrets_dir)
        File.write(
          File.join(secrets_dir, 'secrets.env'),
          "ASC_AUTH_KEY_ID=TEST_KEY\nLEMONSQUEEZY_API_KEY=must_not_load\n"
        )
        ENV['HOME'] = dir

        TestModeHarness.new.send(:load_saneprocess_secrets_env)

        assert_eq(ENV['ASC_AUTH_KEY_ID'], 'TEST_KEY')
        assert_eq(ENV['LEMONSQUEEZY_API_KEY'], nil)
      end

      true
    ensure
      ENV['HOME'] = saved_home
      saved_signing.nil? ? ENV.delete('ASC_AUTH_KEY_ID') : ENV['ASC_AUTH_KEY_ID'] = saved_signing
      saved_unrelated.nil? ? ENV.delete('LEMONSQUEEZY_API_KEY') : ENV['LEMONSQUEEZY_API_KEY'] = saved_unrelated
    end

    test('no-keychain launch state is passed through LaunchServices open') do
      result = subject.send(
        :open_launch_env_pairs,
        allow_keychain: false,
        force_free_mode: false
      )

      assert_includes(result, '--env')
      assert_includes(result, 'SANEAPPS_SKIP_MOVE_TO_APPLICATIONS=1')
      assert_includes(result, 'SANEAPPS_DISABLE_KEYCHAIN=1')
      true
    end

    test('plain keychain-enabled launch still skips move-to-Applications prompt') do
      # Isolate from a license-debug shell: SANEAPPS_FORCE_LICENSE_CHECK is an
      # allowlisted passthrough var, so if the caller exports it (the owner sets
      # it for license debugging) it legitimately lands in the args and breaks
      # this exact-match. Control it so the assertion is deterministic anywhere.
      saved = ENV.delete('SANEAPPS_FORCE_LICENSE_CHECK')
      begin
        result = subject.send(
          :open_launch_env_pairs,
          allow_keychain: true,
          force_free_mode: false
        )

        assert_eq(result, ['--env', 'SANEAPPS_SKIP_MOVE_TO_APPLICATIONS=1'])
      ensure
        ENV['SANEAPPS_FORCE_LICENSE_CHECK'] = saved unless saved.nil?
      end
      true
    end

    test('license-check override passes through LaunchServices open') do
      ENV['SANEAPPS_FORCE_LICENSE_CHECK'] = '1'

      result = subject.send(
        :open_launch_env_pairs,
        allow_keychain: false,
        force_free_mode: false
      )

      assert_includes(result, 'SANEAPPS_FORCE_LICENSE_CHECK=1')
      assert_includes(result, 'SANEAPPS_SKIP_MOVE_TO_APPLICATIONS=1')
      assert_includes(result, 'SANEAPPS_DISABLE_KEYCHAIN=1')
      true
    ensure
      ENV.delete('SANEAPPS_FORCE_LICENSE_CHECK')
    end

    test('sample asset automation vars pass through LaunchServices open') do
      ENV['TEST_ASSET_NAME'] = 'test_video.mp4'
      ENV['PROJECT_DIR'] = '/tmp/SaneVideo'
      ENV['AUTOMATION_TRANSCRIPT_PATH'] = '/tmp/captions.srt'

      result = subject.send(
        :open_launch_env_pairs,
        allow_keychain: false,
        force_free_mode: false
      )

      assert_includes(result, '--env')
      assert_includes(result, 'TEST_ASSET_NAME=test_video.mp4')
      assert_includes(result, 'PROJECT_DIR=/tmp/SaneVideo')
      assert_includes(result, 'AUTOMATION_TRANSCRIPT_PATH=/tmp/captions.srt')
      true
    ensure
      ENV.delete('TEST_ASSET_NAME')
      ENV.delete('PROJECT_DIR')
      ENV.delete('AUTOMATION_TRANSCRIPT_PATH')
    end

    test('test mode launch args suppress app mover dialogs') do
      no_keychain_args = subject.send(:launch_binary_args, allow_keychain: false)
      keychain_args = subject.send(:launch_binary_args, allow_keychain: true)

      assert_includes(no_keychain_args, '--sane-skip-app-move')
      assert_includes(no_keychain_args, '--sane-no-keychain')
      assert_eq(keychain_args, ['--sane-skip-app-move'])
      true
    end

    test('release test mode does not mutate login keychain state by default') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "ENV['SANEMASTER_MUTATE_LOGIN_KEYCHAIN_STATE'] == '1'")
      assert_includes(source, "ENV['SANEMASTER_GRANT_KEYCHAIN_PARTITION_ACCESS'] == '1'")
      assert_includes(source, 'keychain_partition_stamp_file(login_keychain, identities)')
      assert_includes(source, 'Digest::SHA256.hexdigest("#{login_keychain}\n#{normalized_identities}")')
      assert_includes(source, 'grant_keychain_partition_access(login_keychain, keychain_password)')
      assert_includes(source, "ENV.fetch('SANEPROCESS_KEYCHAIN_PARTITION_TIMEOUT', '8')")
      assert(!source.include?("'-D', identity"), 'test_mode should not run one partition grant per identity')
      assert(!source.include?('identities.each_line do |line|'), 'test_mode should not loop over every keychain identity')
      true
    end

    test('shared wrapper gates and caches partition grants') do
      prelude = File.read(File.expand_path('../sanemaster-wrapper-prelude.sh', __dir__))

      assert_includes(prelude, 'SANEPROCESS_GRANT_KEYCHAIN_PARTITION_ACCESS')
      assert_includes(prelude, 'SANEMASTER_GRANT_KEYCHAIN_PARTITION_ACCESS')
      assert_includes(prelude, 'keychain_mtime="$(stat -f %m "${keychain}"')
      assert_includes(prelude, 'printf \'%s\\n%s\\n%s\\n\' "${keychain}" "${keychain_mtime}" "${identities}"')
      assert_includes(prelude, 'saneprocess_run_with_timeout "${partition_timeout}"')
      assert_includes(prelude, 'SANEPROCESS_KEYCHAIN_PARTITION_TIMEOUT:-8')
      assert(!prelude.include?('-D "${identity}"'), 'prelude should not run one partition grant per identity')
      true
    end

    test('transient debug apps bypass LaunchServices open') do
      assert(subject.send(:direct_binary_launch_required?, '/tmp/saneapps-staging.noindex/SaneVideo.app'),
             'transient debug apps should launch by executable path to avoid Gatekeeper dialogs')
      true
    end

    test('Gatekeeper guard allows direct-launch transient apps') do
      subject.define_singleton_method(:ad_hoc_signed?) { |_path| true }

      assert(subject.send(:launch_path_gatekeeper_ready?, '/tmp/saneapps-staging.noindex/SaneVideo.app', direct_launch: true),
             'direct-launch transient apps should not be rejected before executable launch')
      true
    ensure
      subject.singleton_class.remove_method(:ad_hoc_signed?) rescue nil
    end

    test('runtime staging strips extended attributes') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "'ditto', '--noextattr', '--noacl'")
      assert_includes(source, "'xattr', '-cr'")
      true
    end

    test('ad-hoc signed runtime apps are blocked by default') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, 'Refusing to launch ad-hoc signed')
      assert_includes(source, 'test_mode --release')
      true
    end
  end

  test_category('Release runtime signing') do
    test('test_mode build uses single-threaded command capture with timeout') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, 'capture2e_without_reader_thread(*cmd')
      assert_includes(source, 'SANEMASTER_TEST_MODE_BUILD_TIMEOUT')
      assert_includes(source, 'Open3.popen2e(*cmd, pgroup: true)')
      assert_includes(source, 'terminate_process_group(wait_thr)')
      assert(!source.include?('stdout, status = Open3.capture2e(*cmd)'),
             'test_mode build should avoid Open3.capture2e reader-thread crashes')
      assert(!source.include?('fallback_stdout, fallback_status = Open3.capture2e(*fallback_cmd)'),
             'test_mode fallback build should avoid Open3.capture2e reader-thread crashes')
      true
    end

    test('release test_mode build uses archive signing args from .saneprocess') do
      Dir.mktmpdir('sanemaster-test-mode-signing') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            name: ExampleApp
            release:
              archive_extra_args:
                - DEVELOPMENT_TEAM=M78L6FXD48
                - CODE_SIGN_STYLE=Manual
                - "CODE_SIGN_IDENTITY=Developer ID Application"
          YAML
        )

        Dir.chdir(dir) do
          harness = TestModeHarness.new
          args = harness.send(:release_runtime_build_args, 'Release')

          assert_includes(args, 'DEVELOPMENT_TEAM=M78L6FXD48')
          assert_includes(args, 'CODE_SIGN_STYLE=Manual')
          assert_includes(args, 'CODE_SIGN_IDENTITY=Developer ID Application')
        end
      end

      true
    end

    test('release test_mode uses generic destination and authenticated provisioning updates') do
      saved = %w[ASC_AUTH_KEY_PATH ASC_AUTH_KEY_ID ASC_AUTH_ISSUER_ID].to_h { |key| [key, ENV[key]] }

      Dir.mktmpdir('sanemaster-test-mode-auth') do |dir|
        key_path = File.join(dir, 'AuthKey_TEST.p8')
        File.write(key_path, 'test fixture')
        ENV['ASC_AUTH_KEY_PATH'] = key_path
        ENV['ASC_AUTH_KEY_ID'] = 'TEST_KEY_ID'
        ENV['ASC_AUTH_ISSUER_ID'] = 'TEST_ISSUER_ID'

        args = subject.send(:release_runtime_provisioning_args, 'Release')

        assert_eq(subject.send(:test_mode_build_destination, 'Release'), 'generic/platform=macOS')
        assert_eq(
          args,
          [
            '-allowProvisioningUpdates',
            '-authenticationKeyPath', key_path,
            '-authenticationKeyID', 'TEST_KEY_ID',
            '-authenticationKeyIssuerID', 'TEST_ISSUER_ID'
          ]
        )

        rendered = subject.send(:redact_test_mode_signing_auth, args.join(' '))
        assert(!rendered.include?(key_path), 'output must redact the authentication key path')
        assert(!rendered.include?('TEST_KEY_ID'), 'output must redact the authentication key id')
        assert(!rendered.include?('TEST_ISSUER_ID'), 'output must redact the authentication issuer id')
        assert_includes(rendered, '-authenticationKeyPath [REDACTED]')
      end

      true
    ensure
      saved&.each do |key, value|
        value.nil? ? ENV.delete(key) : ENV[key] = value
      end
    end

    test('debug test_mode build does not inherit release signing args') do
      Dir.mktmpdir('sanemaster-test-mode-debug-signing') do |dir|
        File.write(
          File.join(dir, '.saneprocess'),
          <<~YAML
            release:
              archive_extra_args:
                - CODE_SIGN_STYLE=Manual
          YAML
        )

        Dir.chdir(dir) do
          harness = TestModeHarness.new

          assert(harness.send(:release_runtime_build_args, 'Debug').empty?)
          assert(harness.send(:release_runtime_provisioning_args, 'Debug').empty?)
          assert_eq(harness.send(:test_mode_build_destination, 'Debug'), 'platform=macOS')
        end
      end

      true
    end
  end

  test_category('Transient staging path') do
    test('test_mode uses transient noindex path instead of ~/Applications for unsigned fallback') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "File.expand_path(File.join('/tmp/saneapps-staging.noindex', \"\#{project_name}.app\"))")
      assert(!source.include?("File.expand_path(File.join('~/Applications', \"\#{project_name}.app\"))"),
             'unsigned fallback should not use ~/Applications for runtime staging')
      true
    end

    test('runtime path comparison resolves symlinks before matching launched app') do
      Dir.mktmpdir('sanemaster-test-mode-realpath') do |dir|
        real_dir = File.join(dir, 'real')
        link_dir = File.join(dir, 'link')
        FileUtils.mkdir_p(real_dir)
        File.symlink(real_dir, link_dir)

        assert_eq(subject.send(:canonical_runtime_path, link_dir), File.realpath(real_dir))
      end
      true
    end
  end

  test_category('Launch Services refresh') do
    test('test_mode uses supported lsregister refresh flags') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "'-r', '-f', '-apps', 'local,user,system'")
      assert(!source.include?("'-kill', '-r'"), 'lsregister -kill is removed on current macOS')
      assert_includes(source, 'Launch Services refresh failed')
      true
    end
  end

  test_category('Mini visual workspace cleanup') do
    test('test_mode closes other SaneApps and stale helpers before launch') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, 'SANEAPPS_TEST_MODE_APPS')
      assert_includes(source, 'kill_other_saneapps_processes')
      assert_includes(source, 'SaneClickExtension')
      assert(!source.include?('SaneSync'))
      assert_includes(source, 'Closing other SaneApps before testing')
      true
    end
  end

  test_category('TCC identity protection') do
    test('SaneClick is protected from trusted-install identity drift') do
      original_name = subject.instance_variable_get(:@project_name)
      subject.instance_variable_set(:@project_name, 'SaneClick')

      assert(subject.send(:tcc_identity_sensitive_project?), 'expected SaneClick to be TCC identity sensitive')
      true
    ensure
      subject.instance_variable_set(:@project_name, original_name)
    end

    test('unknown apps are not marked TCC identity sensitive') do
      original_name = subject.instance_variable_get(:@project_name)
      subject.instance_variable_set(:@project_name, 'ExampleApp')

      assert(!subject.send(:tcc_identity_sensitive_project?), 'unexpected TCC identity sensitivity for unrelated app')
      true
    ensure
      subject.instance_variable_set(:@project_name, original_name)
    end
  end
end)
