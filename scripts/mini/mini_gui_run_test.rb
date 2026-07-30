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

    test('runner can restore the previously frontmost app for screenshot-sensitive commands') do
      assert_includes(runner_source, '--restore-frontmost')
      assert_includes(runner_source, '--restore-bundle-id')
      assert_includes(runner_source, 'restore_frontmost=1')
      assert_includes(runner_source, 'restore_bundle_id=""')
      assert_includes(runner_source, 'focus_mode="restore-frontmost"')
      assert_includes(runner_source, 'focus_mode="restore-bundle-id:${restore_bundle_id}"')
      assert_includes(runner_source, '"$APPLESCRIPT_PATH" "$window_title" "$terminal_command" "$focus_mode"')
      assert_includes(apple_script_source, 'set focusMode to "finder"')
      assert_includes(apple_script_source, 'application processes whose frontmost is true')
      assert_includes(apple_script_source, 'focusMode starts with "restore-bundle-id:"')
      assert_includes(apple_script_source, 'on restoreBundleID(bundleID)')
      assert_includes(apple_script_source, 'repeat with candidateProcess in application processes')
      assert_includes(apple_script_source, 'set frontmost of candidateProcess to true')
      assert_includes(apple_script_source, 'tell application id bundleID to activate')
      assert_includes(apple_script_source, 'my restoreBundleID(explicitRestoreBundleID)')
      assert_includes(apple_script_source, 'my restoreBundleID(priorBundleID)')
      true
    end

    test('launcher hides its exact Terminal host before returning control') do
      assert_includes(apple_script_source, 'set targetWindow to first window whose selected tab is targetTab')
      assert_includes(apple_script_source, 'set targetWindowID to id of targetWindow')
      assert_includes(apple_script_source, 'set bounds of targetWindow to {-2200, 80, -1200, 720}')
      assert_includes(apple_script_source, 'set miniaturized of targetWindow to true')
      assert_includes(apple_script_source, 'set visible of process "Terminal" to false')

      hide_position = apple_script_source.index('set visible of process "Terminal" to false')
      return_position = apple_script_source.index('return (targetWindowID as string)')
      assert(hide_position && return_position && hide_position < return_position,
             'launcher must hide Terminal before returning the automation window id')
      true
    end

    test('runner waits for Terminal-launched shell to start before trusting idle state') do
      assert_includes(runner_source, 'window_busy_state()')
      assert_includes(runner_source, 'exists_state="$(')
      assert_includes(runner_source, '[ "$exists_state" = "true" ]')
      assert_includes(runner_source, 'return "idle"')
      assert_includes(runner_source, 'launch_grace_seconds="${MINI_GUI_RUN_LAUNCH_GRACE_SECONDS:-8}"')
      assert_includes(runner_source, 'inner_script_path="$tmp_dir/command.sh"')
      assert_includes(runner_source, 'terminal_command="bash $(shell_quote "$inner_script_path")"')
      assert_includes(runner_source, 'started_file="${status_file}.started"')
      assert_includes(runner_source, 'printf \'%s\\n\' "\\$\\$" > $(shell_quote "$started_file")')
      assert_includes(runner_source, '[ ! -f "$started_file" ] && [ "$elapsed_since_launch" -lt "$launch_grace_seconds" ]')
      assert_includes(runner_source, 'idle_poll_count=$((idle_poll_count + 1))')
      assert_includes(runner_source, '[ "$idle_poll_count" -ge 2 ] && break')
      assert_includes(runner_source, 'mini-gui-run: command finished without a status file')
      true
    end

    test('runner does not return while its automation window still exists') do
      assert_includes(runner_source, 'automation_window_is_accessible()')
      assert_includes(runner_source, 'if name of candidateWindow contains targetTitle then return true')
      assert_includes(runner_source, 'while automation_window_is_accessible "$window_title" && [ "$cleanup_poll_count" -lt 50 ]')
      assert_includes(runner_source, 'cleanup_poll_count=$((cleanup_poll_count + 1))')
      assert_includes(runner_source, 'mini-gui-run: automation window remained visible after focus-neutral cleanup')
      true
    end

    test('runner time-bounds post-command window cleanup') do
      assert_includes(runner_source, 'MINI_GUI_RUN_CLEANUP_TIMEOUT_SECONDS:-15')
      assert_includes(runner_source, 'run_with_timeout()')
      assert_includes(runner_source, 'run_with_timeout "$cleanup_timeout_seconds" "$RECLAIM_SCRIPT_PATH" --all --title "$title"')
      assert(!runner_source.include?('close_window_by_id()'),
             'runner must leave window closing to the focus-neutral reclaim helper')
      true
    end

    test('reclaim helper closes prefixed and legacy automation windows') do
      assert_includes(reclaim_source, 'AUTOMATION_PREFIX="${MINI_GUI_RUN_WINDOW_PREFIX:-SaneApps Automation: }"')
      assert_includes(reclaim_source, 'set tabDelimiter to ASCII character 9')
      assert_includes(reclaim_source, 'if not (exists process "Terminal") then return ""')
      assert_includes(reclaim_source, '--all --hide-terminal')
      assert_includes(reclaim_source, 'is_known_legacy_automation_window')
      assert_match(reclaim_source, /if \[ "\$reclaim_all" -eq 1 \]; then\s+if is_prefixed_window/m,
                   'prefixed windows outside the requested title must require --all')
      assert_includes(reclaim_source, "tell application \"Terminal\" to quit saving no")
      assert_includes(reclaim_source, '" App Store "')
      assert_includes(reclaim_source, '" GUI Capture "')
      true
    end

    test('reclaim helper verifies automation windows actually close') do
      assert_includes(reclaim_source, 'on windowStillExists(targetID)')
      assert_includes(reclaim_source, 'on closeThroughAccessibility(targetToken)')
      assert_includes(reclaim_source, 'on pressTerminateIfPresent(targetWindow)')
      assert_includes(reclaim_source, 'if title of candidateButton is "Terminate"')
      assert_includes(reclaim_source, 'perform action "AXPress" of closeButton')
      assert_includes(reclaim_source, 'repeat 20 times')
      assert_includes(reclaim_source, 'if my windowStillExists(targetID) is false then return "closed"')
      assert_includes(reclaim_source, 'return "still-open"')
      assert_includes(reclaim_source, 'warning: automation window still open after close attempt')
      assert_includes(reclaim_source, '/usr/bin/pkill -x Terminal')
      true
    end

    test('reclaim never exposes or foregrounds Terminal while cleaning up') do
      assert(!reclaim_source.include?('set miniaturized of w to false'),
             'reclaim must not expose a hidden automation window')
      assert(!reclaim_source.include?('set index of w to 1'),
             'reclaim must not raise an automation window above the app')
      assert(!reclaim_source.include?("\n        activate\n"),
             'reclaim must not foreground Terminal')
      assert(!reclaim_source.include?('keystroke "w" using command down'),
             'reclaim must not use a focus-stealing keyboard fallback')
      assert(!reclaim_source.include?('set frontmost of process "Terminal"'),
             'reclaim must not make Terminal frontmost')
      hide_position = reclaim_source.index('if [ "$hide_terminal" -eq 1 ] && [ "$dry_run" -ne 1 ]; then')
      list_position = reclaim_source.index('list_windows()')
      assert(hide_position && list_position && hide_position < list_position,
             'reclaim must hide Terminal before listing or closing windows')
      start_reclaim = runner_source.lines.find { |line| line.strip.start_with?('reclaim_windows') && !line.include?('()') }
      assert_eq(start_reclaim&.strip, 'reclaim_windows --hide-terminal',
                'runner must hide stale Terminal hosts before launching work')
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
      assert_includes(screenshot_wrapper_source, 'ssh "$host" "$runner"')
      assert_includes(screenshot_wrapper_source, 'run_remote_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$resolved_mini_host" "$runner_cmd"')
      true
    end

    test('capture wrapper time-bounds the remote Mini GUI runner') do
      assert_includes(screenshot_wrapper_source, 'MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS="${MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS:-120}"')
      assert_includes(screenshot_wrapper_source, 'run_remote_runner_with_timeout()')
      assert_includes(screenshot_wrapper_source, 'capture_output="$(run_remote_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$resolved_mini_host" "$runner_cmd")"')
      assert_includes(screenshot_wrapper_source, 'Mini screenshot capture timed out after ${timeout_seconds}s')
      assert_includes(screenshot_wrapper_source, 'return 124')
      true
    end

    test('capture wrapper avoids ssh when already running on the Mini') do
      assert_includes(screenshot_wrapper_source, 'running_on_mini()')
      assert_includes(screenshot_wrapper_source, 'MINI_SCREENSHOT_FORCE_SSH')
      assert_includes(screenshot_wrapper_source, 'scutil --get ComputerName')
      assert(!screenshot_wrapper_source.include?("ENV.fetch('USER'"),
             'Mini screenshot wrapper must not identify the Mini by shared username')
      assert_includes(screenshot_wrapper_source, 'use_local_runner=true')
      assert_includes(screenshot_wrapper_source, 'running_in_ssh_session()')
      assert_includes(screenshot_wrapper_source, 'if $use_local_runner && ! running_in_ssh_session; then')
      assert_includes(screenshot_wrapper_source, 'runner_cmd="$cmd"')
      assert_includes(screenshot_wrapper_source, 'run_local_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$runner_cmd"')
      true
    end

    test('capture wrapper can recover a screenshot path after GUI cleanup hangs') do
      assert_includes(screenshot_wrapper_source, 'printed_screenshot_path()')
      assert_includes(screenshot_wrapper_source, 'recovered_path="$(printf \'%s\\n\' "$capture_output" | printed_screenshot_path)"')
      assert_includes(screenshot_wrapper_source, 'Recovered screenshot path printed before runner failure')
      assert(!screenshot_wrapper_source.include?('latest_recent_screenshot_path'),
             'recovery must not accept unrelated recent temp screenshots')
      true
    end

    test('capture wrapper expands Mini-side tilde paths before shell-quoting') do
      assert_includes(screenshot_wrapper_source, 'expand_remote_home_path()')
      assert_includes(screenshot_wrapper_source, '${path#\~/}')
      assert_includes(screenshot_wrapper_source, 'remote_home="$(ssh "$resolved_mini_host"')
      assert_includes(screenshot_wrapper_source, 'REMOTE_MINI_GUI_RUN="$(expand_remote_home_path "$REMOTE_MINI_GUI_RUN" "$remote_home")"')
      assert_includes(screenshot_wrapper_source, 'REMOTE_VISUAL_GUARD="$(expand_remote_home_path "$REMOTE_VISUAL_GUARD" "$remote_home")"')
      assert_includes(screenshot_wrapper_source, 'runner_cmd="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN"')
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

    test('capture wrapper avoids local Codex-to-Terminal automation prompts') do
      assert_includes(screenshot_wrapper_source, 'guard_env=""')
      assert_includes(screenshot_wrapper_source, 'guard_env="MINI_VISUAL_AVOID_TERMINAL_AUTOMATION=1 "')
      assert_includes(screenshot_wrapper_source, '${guard_env}bash ${REMOTE_VISUAL_GUARD} --desktop --cleanup')
      assert_includes(screenshot_wrapper_source, '${guard_env}bash ${REMOTE_VISUAL_GUARD} --cleanup --app')
      assert_includes(visual_guard_source, 'avoid_terminal_automation()')
      assert_includes(visual_guard_source, 'MINI_VISUAL_AVOID_TERMINAL_AUTOMATION')
      assert_includes(visual_guard_source, 'avoid_terminal_automation && return 0')
      true
    end

    test('visual guard accepts Peekaboo-visible floating panels when System Events reports zero windows') do
      assert_includes(visual_guard_source, 'target_peekaboo_window_count()')
      assert_includes(visual_guard_source, 'peekaboo list windows --app "$TARGET_APP" --json')
      assert_includes(visual_guard_source, 'if ! $DESKTOP_MODE && [ "$target_windows" = "0" ]')
      assert_includes(visual_guard_source, 'target_windows="$peekaboo_target_windows"')
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
      assert_includes(visual_guard_source, '[ "$target_windows" != "0" ]')
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
      assert_includes(mini_safari_source, 'is_current_mini()')
      assert_includes(mini_safari_source, 'MINI_SAFARI_FORCE_LOCAL')
      assert_includes(mini_safari_source, 'Local Mini Safari automation is unavailable')
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
      assert_includes(apple_script_source, 'launch')
      assert_includes(apple_script_source, 'delay 0.5')
      assert_includes(apple_script_source, 'tell application "Finder" to activate')
      assert(!apple_script_source.include?('repeat with w in windows'),
             'mini-gui-run.applescript should not carry its own legacy window-sweep loop')
      true
    end
  end
end)
