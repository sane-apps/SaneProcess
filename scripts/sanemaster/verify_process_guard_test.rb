#!/usr/bin/env ruby
# frozen_string_literal: true

# Process-table fixtures only: never inspect or signal live app/test processes.
require_relative '../hooks/test/test_framework'
require_relative 'verify'

class VerifyProcessGuardHarness
  include SaneMasterModules::Verify
  attr_reader :processes

  def initialize
    @processes = {
      '101' => ['/usr/bin/log', '/usr/bin/log stream --predicate process == "SaneClip" OR process == "xctest"'],
      '102' => ['/Xcode With Spaces/usr/bin/xctest', '/Xcode With Spaces/usr/bin/xctest /tmp/SaneClipTests.xctest'],
      '103' => ['/usr/bin/xcodebuild', 'xcodebuild -project SaneClip.xcodeproj -scheme SaneClip'],
      '104' => ['/usr/bin/xctest', 'xctest /tmp/SaneVideoTests.xctest'],
      '105' => ['/usr/bin/ruby', 'ruby monitor.rb SaneClip xcodebuild xctest'],
      '106' => ['/usr/libexec/testmanagerd', 'testmanagerd'],
      '107' => ['', 'xctest /tmp/SaneClipTests.xctest'],
      '108' => ['/usr/bin/not-xctest', 'not-xctest SaneClip']
    }
  end

  def project_name = 'SaneClip'
  def project_process_matchers = ['saneclip']
  def process_command_for_pid(pid) = @processes[pid]&.last
  def sleep(*) = nil

  define_method(96.chr.to_sym) do |query|
    case query
    when /\Apgrep /, /\Alsof / then @processes.keys.join("\n")
    when /\Aps -p (\d+) -o comm=/ then @processes[Regexp.last_match(1)]&.first.to_s
    else raise "Unexpected process query: #{query}"
    end
  end
end

include TestFramework

exit(run_tests('Verify Test Process Ownership') do
  test_category('Executable identity before project arguments') do
    test('stale selection retains log predicates and unrelated processes') do
      harness = VerifyProcessGuardHarness.new
      assert_eq(harness.send(:stale_test_processes), %w[102 103])
    end

    test('port cleanup uses the same executable ownership gate') do
      harness = VerifyProcessGuardHarness.new
      assert_eq(harness.send(:test_listeners_for_port, '8999'), %w[102 103])
    end

    test('preflight and timeout cleanup signal only owned test executables') do
      original_kill = Process.method(:kill)
      %i[terminate_stale_test_processes terminate_project_test_processes].each do |method|
        harness = VerifyProcessGuardHarness.new
        signals = []
        Process.define_singleton_method(:kill) do |signal, pid|
          signals << [signal, pid]
          harness.processes.delete(pid.to_s)
          1
        end
        args = method == :terminate_project_test_processes ? ['TERM'] : []
        harness.send(method, *args)
        assert_eq(signals, [['TERM', 102], ['TERM', 103]])
        assert(harness.processes.key?('101'), 'required log stream must remain alive')
        assert(harness.processes.key?('104'), 'another app test process must remain alive')
      end
    ensure
      Process.define_singleton_method(:kill, original_kill) if original_kill
    end
  end
end)
