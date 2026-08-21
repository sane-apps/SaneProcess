#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'
require 'fileutils'
require 'open3'
require 'tmpdir'

include TestFramework

WRAPPER = File.read(File.expand_path('capture-mini-screenshot.sh', __dir__))
HELPER = File.read(File.expand_path('mini-screenshot-evidence-helper.sh', __dir__))
HELPER_FILES = %w[ensure_macos_permissions.sh macos_permissions.swift macos_display_info.swift
                  macos_window_info.swift take_screenshot.py cws_sticky_window_info.swift].freeze

exit(run_tests('Mini Screenshot Evidence Tests') do
  test_category('Locked evidence') do
    test('wrapper selects a clean non-login private helper lane') do
      assert_includes(WRAPPER, '--locked-evidence')
      assert_includes(WRAPPER, 'CWS_SCREENSHOT_EXPECTED_HELPER_SHA256')
      assert_includes(WRAPPER, '--no-login-shell')
      assert_includes(WRAPPER, '/usr/bin/env -i')
      assert_includes(WRAPPER, 'if [ "$capture_status" -ne 0 ] && ! $locked_evidence; then')
      locked_block = WRAPPER[/if \$locked_evidence; then\n  \$preserve_frontmost.*?^elif \$use_local_runner/m]
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

    test('default locked lane still requires an exact activation target') do
      env = { 'CWS_SCREENSHOT_EXPECTED_HELPER_SHA256' => '0' * 64 }
      _stdout, stderr, status = Open3.capture3(env, File.expand_path('capture-mini-screenshot.sh', __dir__),
                                               '--locked-evidence', 'desktop')
      assert(!status.success?, 'missing activation target must fail')
      assert_includes(stderr, 'requires an exact Brave PID and window title')
      true
    end

    test('preserve-frontmost lane reaches the locked helper without activation') do
      Dir.mktmpdir('mini-screenshot-evidence-', '/private/tmp') do |helper_dir|
        source_dir = File.join(Dir.home, '.codex/skills/screenshot/scripts')
        HELPER_FILES.each do |file|
          source = if file == 'cws_sticky_window_info.swift'
                     File.expand_path('../../../../SaneLotAuctionRelease/extension/scripts/cws_sticky_window_info.swift', __dir__)
                   else
                     File.join(source_dir, file)
                   end
          FileUtils.cp(source, File.join(helper_dir, file))
          File.chmod(0o600, File.join(helper_dir, file))
        end
        env = { 'CWS_SCREENSHOT_EXPECTED_HELPER_SHA256' => '0' * 64,
                'LOCAL_SCREENSHOT_HELPER_DIR' => helper_dir }
        stdout, stderr, status = Open3.capture3(env, File.expand_path('capture-mini-screenshot.sh', __dir__),
                                                '--skip-cleanup', '--locked-evidence', '--preserve-frontmost', 'desktop')
        output = stdout + stderr
        assert(!status.success?, 'deliberately wrong helper hash must fail')
        assert(output.include?('source hash does not match'), "locked helper was not reached: #{output.inspect}")
        assert(!output.include?('requires an exact Brave PID'), 'preserve mode must not require activation')
      end
      true
    end

    test('preserve-frontmost is locked-only and mutually exclusive with activation') do
      wrapper = File.expand_path('capture-mini-screenshot.sh', __dir__)
      _stdout, stderr, status = Open3.capture3(wrapper, '--preserve-frontmost', 'desktop')
      assert(!status.success?, 'unlocked preserve mode must fail')
      assert_includes(stderr, 'requires --locked-evidence')
      env = { 'CWS_SCREENSHOT_EXPECTED_HELPER_SHA256' => '0' * 64 }
      _stdout, stderr, status = Open3.capture3(env, wrapper, '--locked-evidence', '--preserve-frontmost',
                                               '--activate-pid', Process.pid.to_s, '--window-title', 'Brave', 'desktop')
      assert(!status.success?, 'preserve mode plus activation must fail')
      assert_includes(stderr, 'cannot also activate a window')
      true
    end
  end
end)
