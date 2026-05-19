#!/bin/bash
set -euo pipefail

TARGET_APP=""
CLEANUP=false
JSON=false

usage() {
  cat <<'EOF' >&2
Usage:
  mini-visual-workspace-guard.sh --app AppName [--cleanup] [--json]

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

[ -n "$TARGET_APP" ] || usage

SANE_APPS="SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo"
CLUTTER_APPS="Preview Safari TextEdit QuickTime Player"
DESKTOP_ARTIFACT_PATTERNS=$(cat <<'EOF'
SaneProcess-rsync-misfire-*
SaneUI-test-output-*.txt
SaneClip OCR final proof *.txt
EOF
)

json_escape() {
  printf '%s' "$1" | ruby -rjson -e 'print JSON.generate(STDIN.read)[1...-1]'
}

quit_app() {
  /usr/bin/osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true
}

hide_terminal() {
  /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "Terminal" then set visible of process "Terminal" to false
end tell
APPLESCRIPT
}

dismiss_system_popovers() {
  # Do not press Escape when a real permission/security prompt is pending.
  # Escape can dismiss the prompt and turn a required customer-flow click into
  # false evidence.
  if [ -n "$(system_prompt_blockers)" ]; then
    return 0
  fi

  /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
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
  /usr/bin/osascript <<APPLESCRIPT 2>/dev/null || true
set hits to {}
set targetAppName to "${TARGET_APP}"
set promptProcessNames to {"SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter", "NotificationCenter", "System Settings", "System Preferences", "loginwindow", targetAppName}

tell application "System Events"
  repeat with procName in promptProcessNames
    set procNameText to procName as text
    if procNameText is not "" and exists process procNameText then
      tell process procNameText
        repeat with candidateWindow in windows
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
            if (combinedText contains "Allow" or combinedText contains "Don’t Allow" or combinedText contains "Don't Allow" or combinedText contains "Always Allow" or combinedText contains "Deny") and (combinedText contains "would like to access" or combinedText contains "wants to use" or combinedText contains "confidential information" or combinedText contains "login keychain" or combinedText contains "Screen Recording" or combinedText contains "Camera" or combinedText contains "Microphone" or combinedText contains "Documents folder" or combinedText contains "permission") then
              set end of hits to (procNameText & " has an unresolved macOS permission/security prompt")
            end if
          end if
        end repeat
      end tell
    end if
  end repeat
end tell
return hits
APPLESCRIPT
}

cleanup_workspace() {
  for app in $SANE_APPS; do
    if [ "$app" != "$TARGET_APP" ]; then
      quit_app "$app"
      /usr/bin/pkill -x "$app" >/dev/null 2>&1 || true
    fi
  done

  if [ "$TARGET_APP" != "SaneClick" ]; then
    /usr/bin/pkill -x "SaneClickExtension" >/dev/null 2>&1 || true
    /usr/bin/pkill -f "/SaneClickExtension\\.appex/" >/dev/null 2>&1 || true
  fi
  if [ "$TARGET_APP" != "SaneSync" ]; then
    /usr/bin/pkill -f "/SaneSync/scripts/inference_server.py" >/dev/null 2>&1 || true
  fi

  for app in $CLUTTER_APPS; do
    quit_app "$app"
  done
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    find "$HOME/Desktop" -maxdepth 1 -name "$pattern" -exec sh -c '
      for path do
        mv "$path" "$HOME/.Trash/$(basename "$path").$(date +%s)" 2>/dev/null || true
      done
    ' sh {} + 2>/dev/null || true
  done <<EOF
$DESKTOP_ARTIFACT_PATTERNS
EOF
  dismiss_system_popovers
  hide_terminal
  /usr/bin/osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
  sleep 1
}

visible_processes() {
  /usr/bin/osascript <<'APPLESCRIPT' 2>/dev/null || true
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
IFS=',' read -r -a visible_names <<< "$visible_raw"
for raw in "${visible_names[@]}"; do
  name="$(printf '%s' "$raw" | sed 's/^ *//;s/ *$//')"
  [ -n "$name" ] || continue
  case "$name" in
    Finder|SystemUIServer|ControlCenter|Dock|NotificationCenter)
      ;;
    "$TARGET_APP")
      ;;
    Terminal)
      issues+=("Terminal is visible; hide or close automation windows before capture")
      ;;
    SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneSync|SaneVideo)
      issues+=("Visible stale SaneApps window: $name while testing $TARGET_APP")
      ;;
    Preview|Safari|TextEdit|QuickTime\ Player)
      issues+=("Visible helper app can contaminate screenshot: $name")
      ;;
  esac
done

while IFS= read -r prompt_issue; do
  prompt_issue="$(printf '%s' "$prompt_issue" | sed 's/^ *//;s/ *$//')"
  [ -n "$prompt_issue" ] || continue
  issues+=("$prompt_issue")
done < <(system_prompt_blockers | tr ',' '\n')

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    *"/Applications/${TARGET_APP}.app/"*|*" ${TARGET_APP} "*)
      ;;
    *"SaneClickExtension"*)
      [ "$TARGET_APP" = "SaneClick" ] || issues+=("Stale SaneClickExtension helper is still running")
      ;;
    *"/SaneSync/scripts/inference_server.py"*)
      [ "$TARGET_APP" = "SaneSync" ] || issues+=("Stale SaneSync inference server is still running")
      ;;
    *"/Applications/SaneBar.app/"*|*"/Applications/SaneClick.app/"*|*"/Applications/SaneClip.app/"*|*"/Applications/SaneHosts.app/"*|*"/Applications/SaneSales.app/"*|*"/Applications/SaneSync.app/"*|*"/Applications/SaneVideo.app/"*)
      issues+=("Stale SaneApps process while testing $TARGET_APP: $line")
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

count="$(issue_count)"

if $JSON; then
  printf '{"ok":%s,"target_app":"%s","issues":[' "$( [ "$count" -eq 0 ] && printf true || printf false )" "$(json_escape "$TARGET_APP")"
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
    echo "✅ Mini visual workspace clean for $TARGET_APP"
  else
    echo "❌ Mini visual workspace dirty for $TARGET_APP"
    set +u
    for issue in "${issues[@]}"; do
      echo " - $issue"
    done
    set -u
  fi
fi

[ "$count" -eq 0 ]
