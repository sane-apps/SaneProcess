#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

RUNNER_PATH = File.expand_path('mini-gui-run.sh', __dir__)
APPLE_SCRIPT_PATH = File.expand_path('mini-gui-run.applescript', __dir__)
RECLAIM_PATH = File.expand_path('mini-reclaim-automation-windows.sh', __dir__)
SCREENSHOT_WRAPPER_PATH = File.expand_path('capture-mini-screenshot.sh', __dir__)
VISUAL_GUARD_PATH = File.expand_path('mini-visual-workspace-guard.sh', __dir__)

runner_source = File.read(RUNNER_PATH)
apple_script_source = File.read(APPLE_SCRIPT_PATH)
reclaim_source = File.read(RECLAIM_PATH)
screenshot_wrapper_source = File.read(SCREENSHOT_WRAPPER_PATH)
visual_guard_source = File.read(VISUAL_GUARD_PATH)

exit(run_tests('Mini GUI Runner Tests') do
  test_category('Automation window reclaim') do
    test('runner tags windows with the shared automation prefix and reclaims them') do
      assert_includes(runner_source, 'AUTOMATION_WINDOW_PREFIX="${MINI_GUI_RUN_WINDOW_PREFIX:-SaneApps Automation: }"')
      assert_includes(runner_source, 'window_title="${AUTOMATION_WINDOW_PREFIX}${title}"')
      assert_includes(runner_source, 'reclaim_windows()')
      assert_includes(runner_source, 'reclaim_windows --hide-terminal')
      true
    end

    test('reclaim helper closes prefixed and legacy automation windows') do
      assert_includes(reclaim_source, 'AUTOMATION_PREFIX="${MINI_GUI_RUN_WINDOW_PREFIX:-SaneApps Automation: }"')
      assert_includes(reclaim_source, 'set tabDelimiter to ASCII character 9')
      assert_includes(reclaim_source, '--all --hide-terminal')
      assert_includes(reclaim_source, 'is_known_legacy_automation_window')
      assert_includes(reclaim_source, "tell application \"Terminal\" to quit saving no")
      assert_includes(reclaim_source, '" App Store "')
      assert_includes(reclaim_source, '" GUI Capture "')
      true
    end
  end

  test_category('Screenshot wrapper safety') do
    test('capture wrapper resolves the Mini host before rsync and ssh') do
      assert_includes(screenshot_wrapper_source, 'resolve_mini_host()')
      assert_includes(screenshot_wrapper_source, 'resolved_mini_host="$(resolve_mini_host "$MINI_HOST")"')
      assert_includes(screenshot_wrapper_source, 'rsync -az "$LOCAL_SKILL_DIR/" "${resolved_mini_host}:${REMOTE_HELPER_DIR}/"')
      assert_includes(screenshot_wrapper_source, 'ssh "$resolved_mini_host" "$remote_runner"')
      true
    end

    test('capture wrapper requests a full automation reclaim before taking screenshots') do
      assert_includes(screenshot_wrapper_source, '--title "Mini Screenshot" --reclaim-all --close-window')
      true
    end

    test('capture wrapper runs the Mini visual workspace guard for app-targeted screenshots') do
      assert_includes(screenshot_wrapper_source, 'REMOTE_VISUAL_GUARD')
      assert_includes(screenshot_wrapper_source, 'mini-visual-workspace-guard.sh')
      assert_includes(screenshot_wrapper_source, 'bash ${REMOTE_VISUAL_GUARD} --cleanup --app')
      true
    end

    test('visual workspace guard blocks stale SaneApps and helper windows') do
      assert_includes(visual_guard_source, 'Visible stale SaneApps window')
      assert_includes(visual_guard_source, 'Stale SaneClickExtension helper is still running')
      assert_includes(visual_guard_source, '/SaneClickExtension\\\\.appex/')
      assert_includes(visual_guard_source, 'Stale SaneSync inference server is still running')
      assert_includes(visual_guard_source, 'Visible helper app can contaminate screenshot')
      true
    end
  end

  test_category('Launch focus') do
    test('AppleScript hands focus back to Finder after launching the hidden Terminal window') do
      assert_includes(apple_script_source, 'tell application "Finder" to activate')
      assert(!apple_script_source.include?('repeat with w in windows'),
             'mini-gui-run.applescript should not carry its own legacy window-sweep loop')
      true
    end
  end
end)
