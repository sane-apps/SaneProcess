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
  /usr/bin/osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  key code 53
  delay 0.1
  key code 53
end tell
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
