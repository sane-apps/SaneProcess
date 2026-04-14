#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'test_mode'

class TestModeHarness
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

  test_category('Transient staging path') do
    test('test_mode uses transient noindex path instead of ~/Applications for unsigned fallback') do
      source = File.read(TEST_MODE_PATH)

      assert_includes(source, "File.expand_path(File.join('/tmp/saneapps-staging.noindex', \"\#{project_name}.app\"))")
      assert(!source.include?("File.expand_path(File.join('~/Applications', \"\#{project_name}.app\"))"),
             'unsigned fallback should not use ~/Applications for runtime staging')
      true
    end
  end
end)
