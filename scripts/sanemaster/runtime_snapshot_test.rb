#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'

require_relative '../hooks/test/test_framework'
require_relative 'runtime_snapshot'

class RuntimeSnapshotHarness
  include SaneMasterModules::RuntimeSnapshot

  def project_name
    'RuntimeSnapshotTest'
  end
end

include TestFramework

exit(run_tests('SaneMaster Runtime Snapshot Tests') do
  subject = RuntimeSnapshotHarness.new

  test_category('Argument parsing') do
    test('parses executable breakpoints expressions and args') do
      Dir.mktmpdir do |dir|
        source = File.join(dir, 'Repro.swift')
        File.write(source, "let value = 42\nprint(value)\n")

        options = subject.parse_runtime_snapshot_args(
          [
            '--executable', './Repro',
            '--break', 'Repro.swift:2',
            '--expr', 'value',
            '--arg', 'sample',
            '--cwd', dir,
            '--timeout', '5'
          ]
        )

        assert_eq(options.executable, File.join(dir, 'Repro'))
        assert_eq(options.breakpoints.first[:file], source)
        assert_eq(options.breakpoints.first[:line], 2)
        assert_eq(options.expressions, ['value'])
        assert_eq(options.program_args, ['sample'])
        assert_eq(options.timeout, 5)
      end
      true
    end

    test('rejects pid and executable together') do
      raised = false
      begin
        subject.parse_runtime_snapshot_args(%w[--pid 123 --executable /tmp/repro])
      rescue ArgumentError
        raised = true
      end

      assert(raised, 'expected mutually exclusive pid/executable validation')
      true
    end
  end

  test_category('LLDB command generation') do
    test('writes an executable plan without launching through SaneMaster app paths') do
      Dir.mktmpdir do |dir|
        source = File.join(dir, 'Repro.swift')
        executable = File.join(dir, 'Repro')
        File.write(source, "let value = 42\nprint(value)\n")

        options = subject.parse_runtime_snapshot_args(
          [
            '--executable', executable,
            '--break', "#{source}:2",
            '--expr', 'value',
            '--cwd', dir,
            '--output', File.join(dir, 'outputs'),
            '--dry-run'
          ]
        )
        result = subject.build_runtime_snapshot(options)
        commands = File.read(File.join(result[:snapshot_dir], 'lldb_commands.txt'))
        summary = File.read(result[:summary])

        assert(result[:ok], 'dry-run snapshots should succeed')
        assert_includes(commands, "target create #{executable}")
        assert_includes(commands, "breakpoint set --file #{source} --line 2")
        assert_includes(commands, 'expression -- value')
        assert(!commands.include?('SaneMaster.rb test_mode'), 'runtime evidence must not launch apps')
        assert(!commands.include?('open '), 'runtime evidence must not use LaunchServices open')
        assert_includes(summary, 'No runtime target was executed')
      end
      true
    end

    test('uses outputs debug directory by default') do
      Dir.mktmpdir do |dir|
        options = subject.parse_runtime_snapshot_args(['--cwd', dir, '--dry-run'])
        result = subject.build_runtime_snapshot(options)

        assert(result[:snapshot_dir].start_with?(File.join(dir, 'outputs', 'debug')),
               "expected snapshot under outputs/debug, got #{result[:snapshot_dir]}")
      end
      true
    end
  end
end)
