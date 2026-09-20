#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

GUARD = File.read(File.expand_path('mini-visual-workspace-guard.sh', __dir__)).freeze

exit(run_tests('Mini Visual Workspace Guard Tests') do
  test_category('unmanaged Terminal handling') do
    test('Terminal-visible check degrades to a warning when Terminal automation is avoided') do
      terminal_branch = GUARD[/Terminal\)\n(.*?)\n\s+;;/m, 1]
      assert(
        !terminal_branch.nil?,
        'guard must still have a Terminal branch in the visible-process check'
      )
      assert_includes(
        terminal_branch,
        'avoid_terminal_automation',
        'Terminal branch must consult avoid_terminal_automation (local runs never hide Terminal)'
      )
      assert_match(
        terminal_branch,
        /issues\+=\("Terminal is visible/,
        'non-avoid path must still record a blocking issue'
      )
      assert_match(
        terminal_branch,
        />&2/,
        'avoid path must warn on stderr so JSON stdout stays clean'
      )
    end

    test('hide_terminal still skips Terminal under the avoid flag') do
      hide_fn = GUARD[/hide_terminal\(\) \{\n(.*?)\n\}/m, 1]
      assert(
        !hide_fn.nil?,
        'guard must still define hide_terminal'
      )
      assert_includes(
        hide_fn,
        'avoid_terminal_automation && return 0',
        'hide_terminal must keep skipping Terminal under MINI_VISUAL_AVOID_TERMINAL_AUTOMATION=1'
      )
    end
  end
end)
