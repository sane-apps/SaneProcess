#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../hooks/test/test_framework'

include TestFramework

RUNNER_PATH = File.expand_path('mini-gui-run.sh', __dir__)
APPLE_SCRIPT_PATH = File.expand_path('mini-gui-run.applescript', __dir__)
RECLAIM_PATH = File.expand_path('mini-reclaim-automation-windows.sh', __dir__)
SCREENSHOT_WRAPPER_PATH = File.expand_path('capture-mini-screenshot.sh', __dir__)
VISUAL_GUARD_PATH = File.expand_path('mini-visual-workspace-guard.sh', __dir__)
MINI_SAFARI_PATH = File.expand_path('mini-safari.sh', __dir__)

runner_source = File.read(RUNNER_PATH)
apple_script_source = File.read(APPLE_SCRIPT_PATH)
reclaim_source = File.read(RECLAIM_PATH)
screenshot_wrapper_source = File.read(SCREENSHOT_WRAPPER_PATH)
visual_guard_source = File.read(VISUAL_GUARD_PATH)
mini_safari_source = File.read(MINI_SAFARI_PATH)

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
      assert_includes(screenshot_wrapper_source, 'MINI_HOST_FALLBACKS')
      assert_includes(screenshot_wrapper_source, 'LOCAL_SCREENSHOT_HELPER_DIR')
      assert_includes(screenshot_wrapper_source, 'resolved_mini_host="$(resolve_mini_host "$MINI_HOST")"')
      assert_includes(screenshot_wrapper_source, 'Could not reach the canonical Mini host.')
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

    test('capture wrapper runs desktop hygiene for full-screen captures') do
      assert_includes(screenshot_wrapper_source, 'capture-mini-screenshot.sh desktop')
      assert_includes(screenshot_wrapper_source, 'set -- --mode temp "$@"')
      assert_includes(screenshot_wrapper_source, 'Unsupported Mini screenshot flag: $1')
      assert_includes(screenshot_wrapper_source, 'Use the canonical desktop path instead: capture-mini-screenshot.sh desktop')
      assert_includes(screenshot_wrapper_source, 'bash ${REMOTE_VISUAL_GUARD} --desktop --cleanup')
      true
    end

    test('capture wrapper owns local copy support instead of forwarding it to the helper') do
      assert_includes(screenshot_wrapper_source, '--copy-to LOCAL_DIR')
      assert_includes(screenshot_wrapper_source, 'local_copy_to=""')
      assert_includes(screenshot_wrapper_source, 'rsync -az "${resolved_mini_host}:${remote_path}" "$local_copy_to/"')
      assert_includes(screenshot_wrapper_source, 'No screenshot path was printed by the Mini capture helper')
      true
    end

    test('capture wrapper refuses to spawn macOS permission prompts during automation') do
      assert_includes(screenshot_wrapper_source, 'CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh')
      assert_includes(screenshot_wrapper_source, 'CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 python3 ${REMOTE_HELPER_DIR}/take_screenshot.py')
      true
    end

    test('visual workspace guard blocks stale SaneApps and helper windows') do
      assert_includes(visual_guard_source, 'Visible stale SaneApps window')
      assert_includes(visual_guard_source, 'Stale SaneClickExtension helper is still running')
      assert_includes(visual_guard_source, '/SaneClickExtension\\\\.appex/')
      assert_includes(visual_guard_source, 'Stale SaneSync inference server is still running')
      assert_includes(visual_guard_source, 'Visible helper app can contaminate screenshot')
      assert_includes(visual_guard_source, '/org.sparkle-project.Sparkle/Launcher/')
      assert_includes(visual_guard_source, ' /Applications/${TARGET_APP}.app')
      true
    end

    test('visual workspace guard allows Codex only for explicit local Air fallback') do
      assert_includes(visual_guard_source, 'local_air_fallback_approved()')
      assert_includes(visual_guard_source, 'SANE_APPROVE_LOCAL_UI_ON_AIR')
      assert_includes(visual_guard_source, 'MR. SANE APPROVES LOCAL UI ON AIR')
      assert_includes(visual_guard_source, 'Codex)')
      assert_includes(visual_guard_source, 'if ! local_air_fallback_approved; then')
      assert(!visual_guard_source.include?('CLUTTER_APPS="Preview Safari TextEdit QuickTime Player Notes Codex"'),
             'Codex must not be in the quit-app clutter list; approved Air fallback should minimize/ignore it, not quit it')
      true
    end

    test('visual workspace guard time-bounds helper app quit attempts') do
      assert_includes(visual_guard_source, 'run_with_timeout()')
      assert_includes(visual_guard_source, 'run_with_timeout 3 /usr/bin/osascript -e "tell application \\"$1\\" to quit"')
      assert_includes(visual_guard_source, '/usr/bin/pkill -x "$1"')
      assert_includes(visual_guard_source, 'kill_non_target_sane_apps()')
      assert_includes(visual_guard_source, '/usr/bin/pkill -f "/Applications/${app}.app/Contents/MacOS/${app}"')
      true
    end

    test('visual workspace guard checks full-desktop macOS prompts before trusting app captures') do
      assert_includes(visual_guard_source, 'system_prompt_blockers()')
      assert_includes(visual_guard_source, 'osascript_with_timeout()')
      assert_includes(visual_guard_source, 'osascript_with_timeout 5 <<APPLESCRIPT')
      assert_includes(visual_guard_source, 'SecurityAgent')
      assert_includes(visual_guard_source, 'CoreServicesUIAgent')
      assert_includes(visual_guard_source, 'UserNotificationCenter')
      assert_includes(visual_guard_source, 'isSystemPromptHost')
      assert_includes(visual_guard_source, 'windowSubrole contains "AXSystemDialog"')
      assert_includes(visual_guard_source, 'has an unresolved macOS permission/security prompt')
      assert_includes(visual_guard_source, 'App-window-only screenshots are insufficient')
      assert_includes(visual_guard_source, 'Do not press Escape when a real permission/security prompt is pending')
      true
    end

    test('visual workspace guard treats app-owned Move to Applications dialogs as blockers') do
      assert_includes(visual_guard_source, 'Move to Applications')
      assert_includes(visual_guard_source, 'Could Not Move')
      assert_includes(visual_guard_source, 'works best from your Applications folder')
      assert_includes(visual_guard_source, 'move it there manually')
      assert_includes(visual_guard_source, 'You may be asked for your password')
      assert_includes(visual_guard_source, 'has an unresolved app install/move prompt')
      true
    end

    test('visual workspace guard has an explicit customer-sweep windowless target mode') do
      assert_includes(visual_guard_source, '--allow-windowless-target')
      assert_includes(visual_guard_source, 'ALLOW_WINDOWLESS_TARGET=true')
      assert_includes(visual_guard_source, 'if $ALLOW_WINDOWLESS_TARGET; then')
      true
    end

    test('visual workspace guard cleans desktop email media and prompt sources') do
      assert_includes(visual_guard_source, '--desktop')
      assert_includes(visual_guard_source, 'DESKTOP_EMAIL_MEDIA_PATTERNS')
      assert_includes(visual_guard_source, 'email-review-media*')
      assert_includes(visual_guard_source, 'email*-linked-media*')
      assert_includes(visual_guard_source, 'cleanup_prompt_processes()')
      assert_includes(visual_guard_source, 'Permission, Keychain, and Apple ID prompt hosts are evidence')
      assert_includes(visual_guard_source, 'return 0')
      assert_includes(visual_guard_source, 'Desktop contains leftover email review media')
      true
    end

    test('capture wrapper supports no-cleanup receipts for Apple portal flows') do
      assert_includes(screenshot_wrapper_source, '--skip-cleanup')
      assert_includes(screenshot_wrapper_source, 'SKIP_CLEANUP=true')
      assert_includes(screenshot_wrapper_source, 'if ! $SKIP_CLEANUP; then')
      true
    end

    test('mini-safari login receipts preserve Safari and use resolved Mini host') do
      assert_includes(mini_safari_source, 'resolve_mini_host()')
      assert_includes(mini_safari_source, 'mini_screenshot --skip-cleanup --mode temp')
      assert_includes(mini_safari_source, 'ssh "$(resolve_mini_host)"')
      assert_includes(mini_safari_source, 'unexpected Apple auth state')
      true
    end

    test('desktop capture mode does not kill or block active Sane app work') do
      assert_includes(visual_guard_source, '$DESKTOP_MODE && return 0')
      assert_includes(visual_guard_source, '$DESKTOP_MODE || issues+=("Visible stale SaneApps window')
      assert_includes(visual_guard_source, '$DESKTOP_MODE || [ "$TARGET_APP" = "SaneClick" ]')
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
