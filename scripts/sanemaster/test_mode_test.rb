#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'test_mode'

class TestModeHarness
  include SaneMasterModules::TestMode
end

include TestFramework

Status = Struct.new(:success?) unless defined?(Status)

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
end)
