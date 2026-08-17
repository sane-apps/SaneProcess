#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

WRAPPER = File.read(File.expand_path('capture-mini-screenshot.sh', __dir__))
HELPER = File.read(File.expand_path('mini-screenshot-evidence-helper.sh', __dir__))

exit(run_tests('Mini Screenshot Evidence Tests') do
  test_category('Locked evidence') do
    test('wrapper selects a clean non-login private helper lane') do
      assert_includes(WRAPPER, '--locked-evidence')
      assert_includes(WRAPPER, 'CWS_SCREENSHOT_EXPECTED_HELPER_SHA256')
      assert_includes(WRAPPER, '--no-login-shell')
      assert_includes(WRAPPER, '/usr/bin/env -i')
      assert_includes(WRAPPER, 'if [ "$capture_status" -ne 0 ] && ! $locked_evidence; then')
      locked_block = WRAPPER[/if \$locked_evidence; then\n  locked_cmd=.*?^elif \$use_local_runner/m]
      assert(locked_block, 'locked evidence branch must be present')
      assert_includes(locked_block, 'if running_in_ssh_session; then')
      assert_includes(locked_block, 'runner_cmd="$cmd"')
      assert_includes(WRAPPER, 'MINI_SCREENSHOT_REQUIRE_GUI_RUNNER')
      assert(locked_block.index('running_in_ssh_session') < locked_block.index('REMOTE_MINI_GUI_RUN'),
             'only an SSH-owned locked run may delegate through Terminal')
      true
    end

    test('helper executes only a byte-bound isolated tree') do
      assert_includes(HELPER, '/private/tmp/sanelot-cws-screenshot.XXXXXX')
      assert_includes(HELPER, '/usr/bin/python3 -I')
      assert_includes(HELPER, 'cws_sticky_window_info.swift')
      assert_includes(HELPER, '--activate-pid "$activate_pid"')
      assert_includes(HELPER, '--window-title "$window_title" >/dev/null')
      assert(HELPER.index('ensure_macos_permissions.sh') <
             HELPER.rindex('cws_sticky_window_info.swift'),
             'exact Brave raise must run after permission check')
      assert(HELPER.rindex('cws_sticky_window_info.swift') < HELPER.index('/usr/bin/python3 -I'),
             'exact Brave raise must run immediately before the screenshot helper')
      assert_includes(HELPER, 'validate_tree "$stage_dir"')
      assert_includes(HELPER, 'tree_sha "$stage_dir"')
      assert(!HELPER.include?('/tmp/codex-screenshot-scripts'),
             'locked evidence must not reuse the shared screenshot helper directory')
      true
    end
  end
end)
