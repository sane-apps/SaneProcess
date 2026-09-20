#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

SCRIPT = File.expand_path('morning-report.sh', __dir__).freeze
OPERATOR_BRIEF = File.expand_path('../sanemaster/operator_brief.rb', __dir__).freeze
MINI_NIGHTLY = File.expand_path('../mini/mini-nightly.sh', __dir__).freeze

exit(run_tests('Morning Report Paths Tests') do
  test_category('writer honors SANE_OUTPUT_DIR') do
    test('REPORT_FILE derives from SANE_OUTPUT_DIR with SaneProcess fallback') do
      content = File.read(SCRIPT)
      assert_includes(
        content,
        'REPORT_DIR="${SANE_OUTPUT_DIR:-$OUTPUT_DIR}"',
        'morning-report.sh must resolve its report dir from SANE_OUTPUT_DIR'
      )
      assert_includes(
        content,
        'REPORT_FILE="$REPORT_DIR/morning_report.md"',
        'REPORT_FILE must live under REPORT_DIR'
      )
    end

    test('REPORT_DIR is created before writing') do
      content = File.read(SCRIPT)
      mkdir_line = content.lines.find { |line| line.start_with?('mkdir -p') }
      assert(
        !mkdir_line.nil? && mkdir_line.include?('$REPORT_DIR'),
        'morning-report.sh must mkdir REPORT_DIR (it may differ from OUTPUT_DIR)'
      )
    end
  end

  test_category('writer/reader agreement') do
    test('operator_brief default reads top-level outputs') do
      content = File.read(OPERATOR_BRIEF)
      assert_includes(
        content,
        'SaneApps/outputs/morning_report.md',
        'operator_brief.rb must default to ~/SaneApps/outputs/morning_report.md'
      )
    end

    test('mini-nightly passes top-level outputs morning report') do
      content = File.read(MINI_NIGHTLY)
      assert_includes(
        content,
        'SANE_OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"',
        'mini-nightly.sh must default SANE_OUTPUT_DIR to ~/SaneApps/outputs'
      )
      assert_includes(
        content,
        '--morning-report "$OUTPUT_DIR/morning_report.md"',
        'mini-nightly.sh must pass the top-level morning report path'
      )
    end
  end
end)
