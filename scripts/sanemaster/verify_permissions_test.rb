#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'stringio'
require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'verify'

# Behavioral regression coverage for the TCC-preservation fix: verify's
# grant_test_permissions must NOT run `tccutil reset` on every run. The test
# build shares the release bundle id, so resetting on each verify wiped the
# installed app's real user grants and ran the suite against a
# reset-then-auto-granted state instead of the real granted path.
class VerifyPermissionsHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Verify
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = original_stdout
end

# Runs grant_test_permissions while recording every `system` invocation the
# instance makes and neutralising the osascript monitor spawn, so the test can
# assert on the real command surface instead of a source-string grep.
def run_grant_capturing_system(subject)
  system_calls = []
  subject.define_singleton_method(:system) do |*args, **_opts|
    system_calls << args
    true
  end

  spawn_calls = []
  original_spawn = Process.method(:spawn)
  original_detach = Process.method(:detach)
  Process.define_singleton_method(:spawn) do |*args, **_opts|
    spawn_calls << args
    424_242
  end
  Process.define_singleton_method(:detach) { |_pid| nil }

  result = nil
  output = capture_stdout do
    result = subject.send(:grant_test_permissions, timeout_seconds: 60)
  end

  { system_calls: system_calls, spawn_calls: spawn_calls, result: result, output: output }
ensure
  # Restore the real Process.spawn/detach by redefining the singleton methods
  # back to the originals captured above (idempotent, no remove_method dance).
  Process.define_singleton_method(:spawn, original_spawn) if original_spawn
  Process.define_singleton_method(:detach, original_detach) if original_detach
end

exit(run_tests('SaneMaster Verify Permission Preservation Tests') do
  test_category('TCC preservation') do
    test('grant_test_permissions never issues a tccutil reset') do
      subject = VerifyPermissionsHarness.new
      subject.define_singleton_method(:project_name) { 'SaneClip' }
      subject.instance_variable_set(:@bundle_id, 'com.saneclip.app')

      captured = run_grant_capturing_system(subject)

      tccutil_calls = captured[:system_calls].select { |args| args.first == 'tccutil' }
      assert_eq(tccutil_calls, [])
      reset_calls = captured[:system_calls].select { |args| args.include?('reset') }
      assert_eq(reset_calls, [])
      true
    end

    test('grant_test_permissions still arms the first-run permission monitor') do
      subject = VerifyPermissionsHarness.new
      subject.define_singleton_method(:project_name) { 'SaneClip' }
      subject.instance_variable_set(:@bundle_id, 'com.saneclip.app')

      captured = run_grant_capturing_system(subject)

      # The applescript monitor ships in scripts/, so the osascript monitor
      # should still be spawned to auto-answer a genuine first-run prompt.
      osascript_spawns = captured[:spawn_calls].select { |args| args.first == 'osascript' }
      assert(osascript_spawns.length == 1, 'expected exactly one osascript permission monitor spawn')
      assert(captured[:result].is_a?(Hash), 'grant_test_permissions should return the monitor hash')
      assert_eq(captured[:result][:pid], 424_242)
      true
    end

    test('grant_test_permissions announces it preserves existing grants') do
      subject = VerifyPermissionsHarness.new
      subject.define_singleton_method(:project_name) { 'SaneClip' }
      subject.instance_variable_set(:@bundle_id, 'com.saneclip.app')

      captured = run_grant_capturing_system(subject)

      assert_includes(captured[:output], 'preserving existing grants')
      assert(!captured[:output].include?('Granting test permissions'), 'stale reset-era status text must be gone')
      true
    end
  end
end)
