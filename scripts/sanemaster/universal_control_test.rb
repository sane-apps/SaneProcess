#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'universal_control'

class UniversalControlHarness
  include SaneMasterModules::Base
  include SaneMasterModules::UniversalControl
end

include TestFramework

exit(run_tests('SaneMaster Universal Control Recovery Tests') do
  subject = UniversalControlHarness.new

  test_category('Option parsing') do
    test('defaults to resetting both local and mini hosts') do
      options = subject.send(:parse_universal_control_reset_options, [])

      assert_eq(options[:local], true)
      assert_eq(options[:mini], true)
      assert_eq(options[:status], false)
      assert_eq(options[:dry_run], false)
      true
    end

    test('mini-only reboot request disables local target and enables mini reboot') do
      options = subject.send(:parse_universal_control_reset_options, ['--mini-only', '--reboot-mini'])

      assert_eq(options[:local], false)
      assert_eq(options[:mini], true)
      assert_eq(options[:reboot_mini], true)
      true
    end
  end

  test_category('Reset script generation') do
    test('includes continuity reset and Wi-Fi bounce steps') do
      script = subject.send(:universal_control_reset_script, wifi_device: 'en0', cleanup_windows: false)

      assert_includes(script, 'defaults -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true')
      assert_includes(script, 'defaults -currentHost delete com.apple.UniversalControl')
      assert_includes(script, 'killall UniversalControl sharingd useractivityd bluetoothd ControlCenter')
      assert_includes(script, 'networksetup -setairportpower en0 off')
      assert_includes(script, 'networksetup -setairportpower en0 on')
      true
    end

    test('adds mini cleanup steps when requested') do
      script = subject.send(:universal_control_reset_script, wifi_device: 'en1', cleanup_windows: true)

      assert_includes(script, 'pkill -x Preview')
      assert_includes(script, 'pkill -x Safari')
      assert_includes(script, 'set visible of process "Terminal" to false')
      assert_includes(script, 'set visible of process "Codex" to false')
      true
    end
  end
end)
