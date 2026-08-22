#!/bin/bash
set -euo pipefail
set +m
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

TARGET_APP=""
CLEANUP=false
JSON=false
ALLOW_WINDOWLESS_TARGET=false
DESKTOP_MODE=false

usage() {
  cat <<'EOF' >&2
Usage:
  mini-visual-workspace-guard.sh --app AppName [--cleanup] [--allow-windowless-target] [--json]
  mini-visual-workspace-guard.sh --desktop [--cleanup] [--json]

Blocks contaminated Mini visual evidence by rejecting or cleaning visible helper
windows and stale SaneApps processes before screenshots are taken.
Also blocks unresolved macOS permission/security prompts, including prompts that
are outside an app-window crop or hidden behind the target app window.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      TARGET_APP="${2:-}"
      [ -n "$TARGET_APP" ] || usage
      shift 2
      ;;
    --app=*)
      TARGET_APP="${1#--app=}"
      shift
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    --desktop)
      DESKTOP_MODE=true
      shift
      ;;
    --allow-windowless-target)
      ALLOW_WINDOWLESS_TARGET=true
      shift
      ;;
    --json)
      JSON=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

if ! $DESKTOP_MODE; then
  [ -n "$TARGET_APP" ] || usage
fi

SANE_APPS="SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo"
WINDOWLESS_TARGET_APPS="SaneBar"
CLUTTER_APPS="Preview Safari TextEdit QuickTime Player Notes"
# Operator/agent GUI apps that must NOT be quit (they are the operator's own
# tools) but MUST be hidden before capture so they never contaminate the shot.
# cleanup hides these, so the post-cleanup re-check passes deterministically
# instead of refusing forever while one of them is on screen.
HIDE_ONLY_APPS="Codex Cursor"
DESKTOP_ARTIFACT_PATTERNS=$(cat <<'EOF'
SaneProcess-rsync-misfire-*
SaneUI-test-output-*.txt
SaneClip OCR final proof *.txt
EOF
)
DESKTOP_EMAIL_MEDIA_PATTERNS=$(cat <<'EOF'
email-review-media*
email*-linked-media*
email[0-9]*
*email*signature*
*signature-spam*
EOF
)

json_escape() {
  printf '%s' "$1" | ruby -rjson -e 'print JSON.generate(STDIN.read)[1...-1]'
}

local_air_fallback_approved() {
  [ "${SANE_APPROVE_LOCAL_UI_ON_AIR:-}" = "MR. SANE APPROVES LOCAL UI ON AIR" ]
}

avoid_terminal_automation() {
  [ "${MINI_VISUAL_AVOID_TERMINAL_AUTOMATION:-0}" = "1" ]
}

run_with_timeout() {
  local seconds="$1"
  shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.2
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" >/dev/null 2>&1
}

osascript_with_timeout() {
  local seconds="$1"
  local script_tmp
  local output_tmp
  local pid
  local elapsed=0
  local status=0
  shift

  script_tmp="$(mktemp "${TMPDIR:-/tmp}/mini-visual-osascript.XXXXXX")"
  output_tmp="$(mktemp "${TMPDIR:-/tmp}/mini-visual-osascript-output.XXXXXX")"
  cat > "$script_tmp"
  /usr/bin/osascript "$script_tmp" > "$output_tmp" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$seconds" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 0.2
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      rm -f "$script_tmp" "$output_tmp"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" >/dev/null 2>&1 || status=$?
  cat "$output_tmp"
  rm -f "$script_tmp" "$output_tmp"
  return "$status"
}

quit_app() {
  run_with_timeout 3 /usr/bin/osascript -e "tell application \"$1\" to quit" || true
  /usr/bin/pkill -x "$1" >/dev/null 2>&1 || true
}

kill_non_target_sane_apps() {
  $DESKTOP_MODE && return 0

  for app in $SANE_APPS; do
    if [ "$app" != "$TARGET_APP" ]; then
      /usr/bin/pkill -x "$app" >/dev/null 2>&1 || true
      /usr/bin/pkill -f "/Applications/${app}.app/Contents/MacOS/${app}" >/dev/null 2>&1 || true
    fi
  done
}

cleanup_prompt_processes() {
  # Permission, Keychain, and Apple ID prompt hosts are evidence, not clutter.
  # Detect them below and block the capture instead of killing or disabling
  # system agents, which can hide the real blocker and drift the Mini state.
  return 0
}

move_path_to_trash() {
  local path="$1"
  local target
  [ -e "$path" ] || return 0
  target="$HOME/.Trash/$(basename "$path").$(date +%Y%m%d%H%M%S)"
  /bin/mv "$path" "$target" 2>/dev/null || true
}

cleanup_desktop_artifacts() {
  local pattern=""
  local root=""

  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    /usr/bin/find "$HOME/Desktop" -maxdepth 1 -name "$pattern" -print0 2>/dev/null |
      while IFS= read -r -d '' artifact; do
        move_path_to_trash "$artifact"
      done
  done <<EOF
$DESKTOP_ARTIFACT_PATTERNS
EOF

  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    for root in "$HOME/Desktop" "$HOME/Desktop/Screenshots"; do
      [ -d "$root" ] || continue
      /usr/bin/find "$root" -maxdepth 3 -name "$pattern" -print0 2>/dev/null |
        while IFS= read -r -d '' artifact; do
          move_path_to_trash "$artifact"
        done
    done
  done <<EOF
$DESKTOP_EMAIL_MEDIA_PATTERNS
EOF
}

hide_terminal() {
  avoid_terminal_automation && return 0

  osascript_with_timeout 3 <<'APPLESCRIPT' >/dev/null || true
tell application "System Events"
  if exists process "Terminal" then set visible of process "Terminal" to false
end tell
APPLESCRIPT
}

# Hide (do NOT quit) an operator/agent GUI app so it can't contaminate a
# screenshot. Quitting would kill the operator's tools; hiding is reversible.
hide_app() {
  local app="$1"
  [ -n "$app" ] || return 0
  osascript_with_timeout 3 <<APPLESCRIPT >/dev/null || true
tell application "System Events"
  if exists process "${app}" then set visible of process "${app}" to false
end tell
APPLESCRIPT
}

dismiss_system_popovers() {
  # Do not press Escape when a real permission/security prompt is pending.
  # Escape can dismiss the prompt and turn a required customer-flow click into
  # false evidence.
  if [ -n "$(target_app_prompt_blockers_timeout 3 || true)" ]; then
    return 0
  fi

  osascript_with_timeout 3 <<'APPLESCRIPT' >/dev/null || true
tell application "System Events"
  key code 53
  delay 0.1
  key code 53
end tell
APPLESCRIPT
}

system_prompt_blockers() {
  # App-window-only screenshots are insufficient: permission/security prompts
  # can sit above, outside, or behind the target window.
  osascript_with_timeout 5 <<APPLESCRIPT || true
set hits to {}
set targetAppName to "${TARGET_APP}"
set promptProcessNames to {"SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter", "NotificationCenter", "System Settings", "System Preferences", "loginwindow", targetAppName}

tell application "System Events"
  repeat with procName in promptProcessNames
    set procNameText to procName as text
    if procNameText is not "" and exists process procNameText then
      with timeout of 2 seconds
        tell process procNameText
          set candidateWindows to windows
          repeat with candidateWindow in candidateWindows
            set windowName to ""
            set windowRole to ""
            set windowSubrole to ""
            set windowDescription to ""
            try
              set windowName to name of candidateWindow as text
            end try
            try
              set windowRole to role of candidateWindow as text
            end try
            try
              set windowSubrole to subrole of candidateWindow as text
            end try
            try
              set windowDescription to description of candidateWindow as text
            end try

            set isSystemPromptHost to procNameText is "SecurityAgent" or procNameText is "CoreServicesUIAgent" or procNameText is "UserNotificationCenter" or procNameText is "NotificationCenter" or procNameText is "loginwindow"
            if isSystemPromptHost and (windowSubrole contains "AXSystemDialog" or windowRole contains "AXDialog" or windowDescription contains "alert") then
              set end of hits to (procNameText & " has an unresolved macOS permission/security prompt")
            else
              set buttonNames to {}
              set staticTextValues to {}
              try
                set buttonNames to name of buttons of candidateWindow
              end try
              try
                set staticTextValues to value of static texts of candidateWindow
              end try
              set combinedText to (windowName & " " & windowDescription & " " & (buttonNames as text) & " " & (staticTextValues as text))
              if procNameText is targetAppName and (combinedText contains "Move to Applications" or combinedText contains "Could Not Move" or combinedText contains "Applications folder" or combinedText contains "works best from your Applications folder" or combinedText contains "move it there manually" or combinedText contains "You may be asked for your password" or combinedText contains "Not Now") then
                set end of hits to (procNameText & " has an unresolved app install/move prompt")
              else if (combinedText contains "Allow" or combinedText contains "Don’t Allow" or combinedText contains "Don't Allow" or combinedText contains "Always Allow" or combinedText contains "Deny") and (combinedText contains "would like to access" or combinedText contains "wants to use" or combinedText contains "confidential information" or combinedText contains "login keychain" or combinedText contains "Screen Recording" or combinedText contains "Camera" or combinedText contains "Microphone" or combinedText contains "Documents folder" or combinedText contains "permission") then
                set end of hits to (procNameText & " has an unresolved macOS permission/security prompt")
              else if procNameText is targetAppName and (combinedText contains "Check for updates automatically?" or combinedText contains "Check Automatically" or combinedText contains "Don’t Check" or combinedText contains "Don't Check") then
                set end of hits to (procNameText & " has an unresolved Sparkle update-check prompt")
              end if
            end if
          end repeat
        end tell
      end timeout
    end if
  end repeat
end tell
return hits
APPLESCRIPT
}

system_prompt_blockers_timeout() {
  local seconds="${1:-5}"
  local prompt_tmp
  local prompt_pid
  local prompt_elapsed=0
  local prompt_status=0

  prompt_tmp="$(mktemp "${TMPDIR:-/tmp}/mini-visual-prompts.XXXXXX")"
  (system_prompt_blockers > "$prompt_tmp" 2>/dev/null) &
  prompt_pid=$!
  while kill -0 "$prompt_pid" >/dev/null 2>&1; do
    if [ "$prompt_elapsed" -ge "$seconds" ]; then
      kill "$prompt_pid" >/dev/null 2>&1 || true
      sleep 0.2
      kill -9 "$prompt_pid" >/dev/null 2>&1 || true
      wait "$prompt_pid" >/dev/null 2>&1 || true
      rm -f "$prompt_tmp"
      return 124
    fi
    sleep 1
    prompt_elapsed=$((prompt_elapsed + 1))
  done
  wait "$prompt_pid" >/dev/null 2>&1 || prompt_status=$?
  cat "$prompt_tmp"
  rm -f "$prompt_tmp"
  return "$prompt_status"
}

target_app_prompt_blockers() {
  osascript_with_timeout 4 <<APPLESCRIPT || true
set hits to {}
set targetAppName to "${TARGET_APP}"

tell application "System Events"
  if exists process targetAppName then
    tell process targetAppName
      repeat with candidateWindow in windows
        set windowName to ""
        set windowDescription to ""
        set buttonNames to {}
        set staticTextValues to {}
        try
          set windowName to name of candidateWindow as text
        end try
        try
          set windowDescription to description of candidateWindow as text
        end try
        try
          set buttonNames to name of buttons of candidateWindow
        end try
        try
          set staticTextValues to value of static texts of candidateWindow
        end try
        set combinedText to (windowName & " " & windowDescription & " " & (buttonNames as text) & " " & (staticTextValues as text))
        if combinedText contains "Move to Applications" or combinedText contains "Could Not Move" or combinedText contains "Applications folder" or combinedText contains "works best from your Applications folder" or combinedText contains "move it there manually" or combinedText contains "You may be asked for your password" or combinedText contains "Not Now" then
          set end of hits to (targetAppName & " has an unresolved app install/move prompt")
        else if combinedText contains "Check for updates automatically?" or combinedText contains "Check Automatically" or combinedText contains "Don’t Check" or combinedText contains "Don't Check" then
          set end of hits to (targetAppName & " has an unresolved Sparkle update-check prompt")
        else if (combinedText contains "Allow" or combinedText contains "Don’t Allow" or combinedText contains "Don't Allow" or combinedText contains "Always Allow" or combinedText contains "Deny") and (combinedText contains "would like to access" or combinedText contains "wants to use" or combinedText contains "confidential information" or combinedText contains "login keychain" or combinedText contains "Screen Recording" or combinedText contains "Camera" or combinedText contains "Microphone" or combinedText contains "Documents folder" or combinedText contains "permission") then
          set end of hits to (targetAppName & " has an unresolved permission/security prompt")
        end if
      end repeat
    end tell
  end if
end tell
return hits
APPLESCRIPT
}

target_app_prompt_blockers_timeout() {
  local seconds="${1:-3}"
  local prompt_tmp
  local prompt_pid
  local prompt_elapsed=0
  local prompt_status=0

  prompt_tmp="$(mktemp "${TMPDIR:-/tmp}/mini-visual-target-prompts.XXXXXX")"
  (target_app_prompt_blockers > "$prompt_tmp" 2>/dev/null) &
  prompt_pid=$!
  while kill -0 "$prompt_pid" >/dev/null 2>&1; do
    if [ "$prompt_elapsed" -ge "$seconds" ]; then
      kill "$prompt_pid" >/dev/null 2>&1 || true
      sleep 0.2
      kill -9 "$prompt_pid" >/dev/null 2>&1 || true
      wait "$prompt_pid" >/dev/null 2>&1 || true
      rm -f "$prompt_tmp"
      return 124
    fi
    sleep 1
    prompt_elapsed=$((prompt_elapsed + 1))
  done
  wait "$prompt_pid" >/dev/null 2>&1 || prompt_status=$?
  cat "$prompt_tmp"
  rm -f "$prompt_tmp"
  return "$prompt_status"
}

cleanup_workspace() {
  cleanup_prompt_processes

  if ! $DESKTOP_MODE; then
    for app in $SANE_APPS; do
      if [ "$app" != "$TARGET_APP" ]; then
        quit_app "$app"
      fi
    done
  fi
  kill_non_target_sane_apps

  if ! $DESKTOP_MODE && [ "$TARGET_APP" != "SaneClick" ]; then
    stop_stale_helper "SaneClickExtension" "/SaneClickExtension\\.appex/"
  fi
  if ! $DESKTOP_MODE && [ "$TARGET_APP" != "SaneSync" ]; then
    stop_stale_helper "" "/SaneSync/scripts/inference_server.py"
  fi

  for app in $CLUTTER_APPS; do
    quit_app "$app"
  done
  cleanup_desktop_artifacts
  dismiss_system_popovers
  hide_terminal
  for app in $HIDE_ONLY_APPS; do
    hide_app "$app"
  done
  if ! $DESKTOP_MODE; then
    osascript_with_timeout 3 <<APPLESCRIPT >/dev/null || true
tell application "System Events"
  if exists process "${TARGET_APP}" then set frontmost of process "${TARGET_APP}" to true
end tell
APPLESCRIPT
  fi
  sleep 1
  kill_non_target_sane_apps
  sleep 1
}

stop_stale_helper() {
  local exact_name="$1"
  local process_pattern="$2"
  local attempts=0

  if [ -n "$exact_name" ]; then
    /usr/bin/pkill -x "$exact_name" >/dev/null 2>&1 || true
  fi
  if [ -n "$process_pattern" ]; then
    /usr/bin/pkill -f "$process_pattern" >/dev/null 2>&1 || true
  fi

  while [ "$attempts" -lt 10 ]; do
    if ! stale_helper_running "$exact_name" "$process_pattern"; then
      return 0
    fi
    sleep 0.2
    attempts=$((attempts + 1))
  done

  if [ -n "$exact_name" ]; then
    /usr/bin/pkill -9 -x "$exact_name" >/dev/null 2>&1 || true
  fi
  if [ -n "$process_pattern" ]; then
    /usr/bin/pkill -9 -f "$process_pattern" >/dev/null 2>&1 || true
  fi
}

stale_helper_running() {
  local exact_name="$1"
  local process_pattern="$2"

  if [ -n "$exact_name" ] && /bin/ps -axo comm= | /usr/bin/grep -Fxq "$exact_name"; then
    return 0
  fi
  if [ -n "$process_pattern" ] && /bin/ps -axo args= | /usr/bin/grep -E "$process_pattern" | /usr/bin/grep -v grep >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

visible_processes() {
  osascript_with_timeout 4 <<'APPLESCRIPT' || true
set output to {}
tell application "System Events"
  repeat with proc in application processes
    try
      if visible of proc is true then set end of output to name of proc
    end try
  end repeat
end tell
return output
APPLESCRIPT
}

frontmost_process() {
  osascript_with_timeout 3 <<'APPLESCRIPT' || true
tell application "System Events"
  set frontApps to name of application processes whose frontmost is true
end tell
if (count of frontApps) is 0 then return ""
return item 1 of frontApps
APPLESCRIPT
}

target_window_count() {
  osascript_with_timeout 3 <<APPLESCRIPT || true
set targetAppName to "${TARGET_APP}"
tell application "System Events"
  if exists process targetAppName then
    tell process targetAppName
      return count of windows
    end tell
  end if
end tell
return 0
APPLESCRIPT
}

target_peekaboo_window_count() {
  command -v peekaboo >/dev/null 2>&1 || return 0
  peekaboo list windows --app "$TARGET_APP" --json 2>/dev/null | ruby -rjson -e '
    data = JSON.parse(STDIN.read) rescue {}
    windows = data.dig("data", "windows") || []
    count = windows.count do |window|
      window["isOnScreen"] != false && window["isMinimized"] != true
    end
    puts count
  ' 2>/dev/null || true
}

running_sane_processes() {
  /usr/bin/pgrep -fl "Sane(Bar|Click|Clip|Hosts|Sales|Sync|Video)" 2>/dev/null || true
  /usr/bin/pgrep -fl "/SaneSync/scripts/inference_server.py" 2>/dev/null || true
}

$CLEANUP && cleanup_workspace

issues=()

issue_count() {
  set +u
  local count=${#issues[@]}
  set -u
  printf '%s' "$count"
}

visible_raw="$(visible_processes)"
visible_names=()
if [ -n "$visible_raw" ]; then
  IFS=',' read -r -a visible_names <<< "$visible_raw"
fi
target_visible=false
target_visible_via_process=false
if [ -n "$visible_raw" ]; then
  for raw in "${visible_names[@]}"; do
    name="$(printf '%s' "$raw" | sed 's/^ *//;s/ *$//')"
    [ -n "$name" ] || continue
    if [ "$name" = "$TARGET_APP" ]; then
      target_visible=true
      target_visible_via_process=true
    fi
    case "$name" in
      Finder|SystemUIServer|ControlCenter|Dock|NotificationCenter)
        ;;
      "$TARGET_APP")
        ;;
      Terminal)
        issues+=("Terminal is visible; hide or close automation windows before capture")
        ;;
      SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneSync|SaneVideo)
        $DESKTOP_MODE || issues+=("Visible stale SaneApps window: $name while testing $TARGET_APP")
        ;;
      Preview|Safari|TextEdit|QuickTime\ Player)
        issues+=("Visible helper app can contaminate screenshot: $name")
        ;;
      Notes)
        issues+=("Visible helper app can contaminate screenshot: $name")
        ;;
      Codex)
        if ! local_air_fallback_approved; then
          issues+=("Visible helper app can contaminate screenshot: $name")
        fi
        ;;
      SecurityAgent|CoreServicesUIAgent|UserNotificationCenter|NotificationCenter|System\ Settings|System\ Preferences|loginwindow)
        issues+=("Visible macOS permission/security prompt host can contaminate screenshot: $name")
        ;;
    esac
  done
fi

frontmost_name="$(frontmost_process | sed 's/^ *//;s/ *$//')"
if $DESKTOP_MODE; then
  target_windows=0
else
  target_windows="$(target_window_count | sed 's/^ *//;s/ *$//')"
fi
[ -n "$target_windows" ] || target_windows=0
if ! $DESKTOP_MODE && [ "$target_windows" = "0" ]; then
  peekaboo_target_windows="$(target_peekaboo_window_count | sed 's/^ *//;s/ *$//')"
  case "$peekaboo_target_windows" in
    ''|*[!0-9]*)
      ;;
    *)
      if [ "$peekaboo_target_windows" -gt 0 ]; then
        target_windows="$peekaboo_target_windows"
      fi
      ;;
  esac
fi
[ "$target_windows" = "0" ] || target_visible=true

windowless_target=false
if $ALLOW_WINDOWLESS_TARGET; then
  windowless_target=true
fi
for app in $WINDOWLESS_TARGET_APPS; do
  if [ "$TARGET_APP" = "$app" ]; then
    windowless_target=true
    break
  fi
done

if $DESKTOP_MODE; then
  windowless_target=true
elif ! $windowless_target; then
  if ! $target_visible || [ "$target_windows" = "0" ]; then
    issues+=("$TARGET_APP is not visible with an inspectable window; launch and focus it before capture")
  elif $target_visible_via_process && [ "$frontmost_name" != "$TARGET_APP" ]; then
    issues+=("$TARGET_APP is not frontmost; frontmost app is ${frontmost_name:-unknown}")
  fi
elif $target_visible_via_process && [ "$frontmost_name" != "$TARGET_APP" ] && [ "$target_windows" != "0" ]; then
  issues+=("$TARGET_APP is not frontmost; frontmost app is ${frontmost_name:-unknown}")
fi

if ! $DESKTOP_MODE; then
if ! $windowless_target || [ "$target_windows" != "0" ]; then
  prompt_output=""
  prompt_status=0
  prompt_output="$(target_app_prompt_blockers_timeout 3)" || prompt_status=$?
  if [ "$prompt_status" -eq 124 ]; then
    issues+=("$TARGET_APP prompt/blocker scan timed out; inspect the live screen before capture")
  else
    while IFS= read -r prompt_issue; do
      prompt_issue="$(printf '%s' "$prompt_issue" | sed 's/^ *//;s/ *$//')"
      [ -n "$prompt_issue" ] || continue
      issues+=("$prompt_issue")
    done < <(printf '%s' "$prompt_output" | tr ',' '\n')
  fi
fi
fi

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *"/org.sparkle-project.Sparkle/Launcher/"*"/Updater.app/"*" /Applications/${TARGET_APP}.app"*)
      ;;
    *".appex/"*)
      ;;
    *"/Applications/${TARGET_APP}.app/"*|*" ${TARGET_APP} "*)
      ;;
    *"SaneClickExtension"*)
      $DESKTOP_MODE || [ "$TARGET_APP" = "SaneClick" ] || issues+=("Stale SaneClickExtension helper is still running")
      ;;
    *"/SaneSync/scripts/inference_server.py"*)
      $DESKTOP_MODE || [ "$TARGET_APP" = "SaneSync" ] || issues+=("Stale SaneSync inference server is still running")
      ;;
    *"/Applications/SaneBar.app/"*|*"/Applications/SaneClick.app/"*|*"/Applications/SaneClip.app/"*|*"/Applications/SaneHosts.app/"*|*"/Applications/SaneSales.app/"*|*"/Applications/SaneSync.app/"*|*"/Applications/SaneVideo.app/"*)
      $DESKTOP_MODE || issues+=("Stale SaneApps process while testing $TARGET_APP: $line")
      ;;
  esac
done < <(running_sane_processes)

while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    issues+=("Desktop contains leftover test artifact: $(basename "$artifact")")
  done < <(find "$HOME/Desktop" -maxdepth 1 -name "$pattern" -print 2>/dev/null || true)
done <<EOF
$DESKTOP_ARTIFACT_PATTERNS
EOF

while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue
  for root in "$HOME/Desktop" "$HOME/Desktop/Screenshots"; do
    [ -d "$root" ] || continue
    while IFS= read -r artifact; do
      [ -n "$artifact" ] || continue
      issues+=("Desktop contains leftover email review media: $(basename "$artifact")")
    done < <(/usr/bin/find "$root" -maxdepth 3 -name "$pattern" -print 2>/dev/null || true)
  done
done <<EOF
$DESKTOP_EMAIL_MEDIA_PATTERNS
EOF

count="$(issue_count)"

if $JSON; then
  printf '{"ok":%s,"target_app":"%s","desktop":%s,"issues":[' "$( [ "$count" -eq 0 ] && printf true || printf false )" "$(json_escape "$TARGET_APP")" "$( $DESKTOP_MODE && printf true || printf false )"
  first=true
  set +u
  for issue in "${issues[@]}"; do
    $first || printf ','
    first=false
    printf '"%s"' "$(json_escape "$issue")"
  done
  set -u
  printf ']}\n'
else
  if [ "$count" -eq 0 ]; then
    if $DESKTOP_MODE; then
      echo "✅ Mini visual workspace clean for desktop capture"
    else
      echo "✅ Mini visual workspace clean for $TARGET_APP"
    fi
  else
    if $DESKTOP_MODE; then
      echo "❌ Mini visual workspace dirty for desktop capture"
    else
      echo "❌ Mini visual workspace dirty for $TARGET_APP"
    fi
    set +u
    for issue in "${issues[@]}"; do
      echo " - $issue"
    done
    set -u
  fi
fi

[ "$count" -eq 0 ]
