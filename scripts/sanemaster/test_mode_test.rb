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
    test('direct launch is required when launch state depends on env vars or args') do
      result = subject.send(
        :should_direct_launch?,
        env_vars: { 'SANEAPPS_DISABLE_KEYCHAIN' => '1' },
        launch_args: ['--sane-no-keychain']
      )

      assert(result, 'expected no-keychain launches to bypass LaunchServices open so args/env survive')
      true
    end

    test('plain keychain-enabled launches can still use LaunchServices open') do
      result = subject.send(
        :should_direct_launch?,
        env_vars: {},
        launch_args: []
      )

      assert(!result, 'expected default launches without special env/args to keep using open')
      true
    end
  end

  test_category('Release runtime signing') do
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
  end

  test_category('Mini visual workspace cleanup') do
    test('test_mode closes other SaneApps and stale helpers before launch') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, 'SANEAPPS_TEST_MODE_APPS')
      assert_includes(source, 'kill_other_saneapps_processes')
      assert_includes(source, 'SaneClickExtension')
      assert_includes(source, '/SaneSync/scripts/inference_server.py')
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
