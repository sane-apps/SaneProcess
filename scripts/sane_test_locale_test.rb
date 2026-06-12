#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression tests: sane_test.rb and SaneMaster.rb must survive C-locale
# shells (hooks, launchd, non-login ssh to the Mini). 2026-06-11: xcodebuild
# output hitting the failure-line regex in build_debug raised
# "invalid byte sequence in US-ASCII" and aborted a SaneBar launch mid-run.

require 'open3'
require 'rbconfig'

require_relative 'hooks/test/test_framework'

include TestFramework

SANE_TEST_SCRIPT = File.expand_path('sane_test.rb', __dir__)
C_LOCALE_ENV = { 'LC_ALL' => 'C', 'LANG' => 'C', 'LC_CTYPE' => nil }.freeze

def run_probe(probe)
  Open3.capture3(C_LOCALE_ENV, RbConfig.ruby, '--disable-gems', '-e', probe)
end

exit(run_tests('sane_test C-locale survival') do
  test_category('Encoding pin') do
    test('sane_test.rb pins UTF-8 defaults under a C locale') do
      probe = <<~RUBY
        ARGV.replace(['--help'])
        begin
          load #{SANE_TEST_SCRIPT.dump}
        rescue SystemExit
        end
        abort 'default_external not UTF-8' unless Encoding.default_external == Encoding::UTF_8
        abort 'default_internal not UTF-8' unless Encoding.default_internal == Encoding::UTF_8
        print 'ENC_OK'
      RUBY
      stdout, stderr, status = run_probe(probe)
      assert(status.success?, "probe failed: #{stderr}")
      assert_includes(stdout, 'ENC_OK')
      true
    end
  end

  test_category('Build-output normalization') do
    test('mis-tagged US-ASCII xcodebuild output survives the failure-line regex') do
      probe = <<~RUBY
        ARGV.replace(['--help'])
        begin
          load #{SANE_TEST_SCRIPT.dump}
        rescue SystemExit
        end
        # Original crash shape: UTF-8 bytes (em dash) in a string tagged with
        # the locale default, fed to build_debug's failure-line regex.
        line = (+"error: Lexikal \\xE2\\x80\\x94 failed").force_encoding(Encoding::US_ASCII)
        normalized = SaneTest.normalize_command_output(line)
        abort 'regex raised or missed' unless normalized.lines.any? { |l| l.match?(/error:|BUILD FAILED/) }
        print 'REGEX_OK'
      RUBY
      stdout, stderr, status = run_probe(probe)
      assert(status.success?, "probe failed: #{stderr}")
      assert_includes(stdout, 'REGEX_OK')
      true
    end

    test('invalid bytes are scrubbed instead of raising') do
      probe = <<~RUBY
        ARGV.replace(['--help'])
        begin
          load #{SANE_TEST_SCRIPT.dump}
        rescue SystemExit
        end
        bad = (+"error: \\xFF broken").force_encoding(Encoding::UTF_8)
        normalized = SaneTest.normalize_command_output(bad)
        abort 'not valid after scrub' unless normalized.valid_encoding?
        abort 'regex raised or missed' unless normalized.match?(/error:/)
        print 'SCRUB_OK'
      RUBY
      stdout, stderr, status = run_probe(probe)
      assert(status.success?, "probe failed: #{stderr}")
      assert_includes(stdout, 'SCRUB_OK')
      true
    end
  end

  test_category('Entry-point pins') do
    # Static checks (no subprocess): running these scripts' real entry paths in
    # a test is too heavy/side-effectful, so assert the pin sits above the
    # first require for every directly-run script that parses UTF-8 content.
    %w[
      SaneMaster.rb
      qa.rb
      validation_report.rb
      link_monitor.rb
      automation/tool_discovery_receipt.rb
    ].each do |relative|
      test("#{relative} pins UTF-8 defaults before loading anything") do
        src = File.read(File.expand_path(relative, __dir__), encoding: Encoding::UTF_8)
        header = src.lines.take_while { |l| !l.start_with?('require') }.join
        assert_includes(header, 'Encoding.default_external = Encoding::UTF_8')
        assert_includes(header, 'Encoding.default_internal = Encoding::UTF_8')
        true
      end
    end
  end

  test_category('Hook stdin reads') do
    test('every hook $stdin.read is tagged UTF-8') do
      # A US-ASCII-tagged stdin payload with non-ASCII bytes raises
      # Encoding::InvalidByteSequenceError inside JSON.parse — which the
      # hooks' `rescue JSON::ParserError` clauses do NOT catch.
      offenders = []
      Dir.glob(File.expand_path('hooks/**/*.rb', __dir__)).each do |path|
        next if File.basename(path).end_with?('_test.rb') || path.include?('/test/')

        File.readlines(path, encoding: Encoding::UTF_8).each_with_index do |line, index|
          next unless line.include?('$stdin.read')
          next if line.include?('force_encoding(Encoding::UTF_8)')

          offenders << "#{path.split('scripts/').last}:#{index + 1}"
        end
      end
      assert_eq(offenders, [])
      true
    end

    test('sane_launch_guard survives em-dash payload under C locale') do
      guard = File.expand_path('hooks/sane_launch_guard.rb', __dir__)
      payload = '{"tool_name":"Read","tool_input":{"file_path":"/tmp/notes — draft.txt"}}'
      _stdout, stderr, status = Open3.capture3(C_LOCALE_ENV, RbConfig.ruby, guard, stdin_data: payload)
      assert(status.success?, "guard failed: #{stderr}")
      assert(!stderr.include?('invalid byte sequence'), "encoding raise leaked: #{stderr}")
      true
    end
  end
end)
