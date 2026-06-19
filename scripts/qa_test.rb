#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require_relative 'qa'

class SaneProcessQATest < Minitest::Test
  def test_top_level_hook_dependencies_uses_derived_hook_file_manifest
    source = File.read(File.join(__dir__, 'qa.rb'), encoding: Encoding::UTF_8)

    assert_includes source, 'sources = ALL_HOOK_FILES'
    refute_includes source, 'EXPECTED_HOOKS + SHARED_MODULES + SELF_TEST_MODULES'

    dependencies = SaneProcessQA.new.send(:top_level_hook_dependencies)

    assert_kind_of Array, dependencies
  end

  def test_capture_qa_command_times_out_stuck_children
    output, success = SaneProcessQA.new.send(
      :capture_qa_command,
      RbConfig.ruby,
      '-e',
      'sleep 2',
      timeout: 0.1
    )

    refute success
    assert_includes output, 'Timed out after 0.1s'
  end

  def test_qa_child_commands_are_bounded_and_not_shell_backticks
    source = File.read(File.join(__dir__, 'qa.rb'), encoding: Encoding::UTF_8)
    drift_source = File.read(File.join(__dir__, 'qa_drift_checks.rb'), encoding: Encoding::UTF_8)

    assert_includes source, 'Open3.popen3'
    assert_includes source, 'wait_thr.join(timeout)'
    refute_includes source, '`ruby #{hook_path} --self-test 2>&1`'
    refute_includes drift_source, '`ruby #{hook_path} --self-test 2>&1`'
  end
end
