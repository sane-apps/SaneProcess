#!/usr/bin/env ruby
# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'json'
require 'fileutils'

require_relative '../hooks/test/test_framework'
require_relative 'base'
require_relative 'meta'

class MetaHarness
  include SaneMasterModules::Base
  include SaneMasterModules::Meta
end

include TestFramework

def capture_stdout
  original_stdout = $stdout
  buffer = StringIO.new
  $stdout = buffer
  yield
  buffer.string
ensure
  $stdout = original_stdout
end

exit(run_tests('SaneMaster Meta Tests') do
  test_category('mcp health') do
    test('uses live check-mcps probe instead of treating project config as complete truth') do
      subject = MetaHarness.new
      subject.define_singleton_method(:mcp_live_probe_snapshot) do
        {
          available: true,
          command: '/tmp/check-mcps',
          results: [
            { status: 'PASS', name: 'context7', detail: 'ok' },
            { status: 'PASS', name: 'central-memory', detail: 'ok' },
            { status: 'PASS', name: 'xcode', detail: 'ok' }
          ]
        }
      end

      Dir.mktmpdir('meta-mcp-') do |dir|
        File.write(File.join(dir, '.mcp.json'), JSON.generate('mcpServers' => {}))
        Dir.chdir(dir) do
          output = capture_stdout do
            result = subject.send(:check_mcp_health)
            assert_eq(result[:status], :ok)
            assert_eq(result[:source], '/tmp/check-mcps')
          end

          assert_includes(output, 'context7: ok')
          assert(!output.include?('context7: missing'), output)
        end
      end
      true
    end

    test('falls back to project-local mcp config when live probe is unavailable') do
      subject = MetaHarness.new
      subject.define_singleton_method(:mcp_live_probe_snapshot) { { available: false, results: [] } }

      Dir.mktmpdir('meta-mcp-fallback-') do |dir|
        File.write(File.join(dir, '.mcp.json'), JSON.pretty_generate('mcpServers' => { 'apple-docs' => {} }))
        Dir.chdir(dir) do
          output = capture_stdout do
            result = subject.send(:check_mcp_health)
            assert_eq(result[:status], :ok)
            assert_eq(result[:configured], ['apple-docs'])
          end

          assert_includes(output, 'apple-docs: project configured')
          assert(!output.include?('context7: missing'), output)
        end
      end
      true
    end
  end

  test_category('test quality scan') do
    test('flags executable tautologies but ignores comments and fixture strings') do
      subject = MetaHarness.new

      Dir.mktmpdir('meta-test-scan-') do |dir|
        scripts_dir = File.join(dir, 'scripts', 'hooks')
        FileUtils.mkdir_p(scripts_dir)
        File.write(File.join(scripts_dir, 'fixture_test.rb'), <<~RUBY)
          # #expect(true) in a comment is documentation, not executable test code.
          FIXTURE = {
            new_string: '@Test func bad() { #expect(true) }'
          }

          def test_real_tautology
            assert(true, 'this is a real always-true assertion')
          end
        RUBY

        Dir.chdir(dir) do
          result = nil
          capture_stdout do
            result = subject.send(:scan_test_quality, verbose: false)
          end

          assert_eq(result[:blocking_count], 1)
          assert_eq(result[:issues][:tautologies].length, 1)
          assert_eq(result[:issues][:tautologies].first[:line], 7)
          assert_eq(result[:issues][:tautologies].first[:pattern], 'assert(true)')
        end
      end
      true
    end

    test('flags real Swift Testing tautologies') do
      subject = MetaHarness.new

      Dir.mktmpdir('meta-swift-scan-') do |dir|
        test_dir = File.join(dir, 'SaneProcessTests')
        FileUtils.mkdir_p(test_dir)
        File.write(File.join(test_dir, 'ExampleTests.swift'), <<~SWIFT)
          import Testing

          @Test func badExample() {
            #expect(true)
          }
        SWIFT

        Dir.chdir(dir) do
          subject.instance_variable_set(:@project_tests_dir, 'SaneProcessTests')
          result = nil
          capture_stdout do
            result = subject.send(:scan_test_quality, verbose: false)
          end

          assert_eq(result[:blocking_count], 1)
          assert_eq(result[:issues][:tautologies].first[:file], 'ExampleTests.swift')
          assert_eq(result[:issues][:tautologies].first[:line], 4)
        end
      end
      true
    end

    test('ignores heredoc fixture payloads in Ruby scanner tests') do
      subject = MetaHarness.new

      Dir.mktmpdir('meta-heredoc-scan-') do |dir|
        scripts_dir = File.join(dir, 'scripts')
        FileUtils.mkdir_p(scripts_dir)
        File.write(File.join(scripts_dir, 'heredoc_test.rb'), <<~RUBY)
          def test_checker_fixture
            fixture = <<~SWIFT
              @Test func badExample() {
                #expect(true)
              }
            SWIFT
            assert(fixture.include?('badExample'))
          end
        RUBY

        Dir.chdir(dir) do
          result = nil
          capture_stdout do
            result = subject.send(:scan_test_quality, verbose: false)
          end

          assert_eq(result[:blocking_count], 0)
          assert_eq(result[:issues][:tautologies].length, 0)
        end
      end
      true
    end
  end
end)
