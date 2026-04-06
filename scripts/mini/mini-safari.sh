#!/bin/bash
set -euo pipefail

MINI_HOST="${MINI_HOST:-mini}"

usage() {
  cat <<'EOF'
Usage:
  mini-safari.sh list-tabs
  mini-safari.sh open <url> [delay_seconds]
  mini-safari.sh read [tab_index] [char_limit]
  mini-safari.sh js [tab_index] <javascript>
  mini-safari.sh open-read <url> [delay_seconds] [char_limit]

Notes:
  - Drives Safari on the Mac Mini via AppleScript.
  - `tab_index` is 1-based and defaults to the current tab.
  - `read` returns final URL, title, and a body-text snippet.
EOF
}

json_escape() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

run_remote_applescript() {
  local script="$1"
  ssh "$MINI_HOST" <<EOF
osascript <<'APPLESCRIPT'
$script
APPLESCRIPT
EOF
}

cmd="${1:-}"
case "$cmd" in
  list-tabs)
    run_remote_applescript '
tell application "Safari"
  set out to {}
  set i to 1
  repeat with t in tabs of front window
    set end of out to (i as text) & ": " & (URL of t) & " | " & (name of t)
    set i to i + 1
  end repeat
  return out as text
end tell
'
    ;;
  open)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    url="$2"
    delay_s="${3:-4}"
    url_lit="$(json_escape "$url")"
    run_remote_applescript "
set targetURL to $url_lit
tell application \"Safari\"
  activate
  tell front window
    set current tab to (make new tab with properties {URL:targetURL})
  end tell
end tell
delay $delay_s
tell application \"Safari\"
  return URL of current tab of front window
end tell
"
    ;;
  read)
    tab_idx="${2:-}"
    char_limit="${3:-1600}"
    if [[ -n "$tab_idx" ]]; then
      tab_ref="tab $tab_idx of front window"
    else
      tab_ref="current tab of front window"
    fi
    run_remote_applescript "
tell application \"Safari\"
  set t to $tab_ref
  set out to (URL of t) & \"\\nTITLE:\" & (do JavaScript \"document.title\" in t) & \"\\nBODY:\\n\" & (do JavaScript \"document.body.innerText.slice(0,$char_limit)\" in t)
  return out
end tell
"
    ;;
  js)
    [[ $# -ge 3 ]] || { usage; exit 1; }
    tab_idx="$2"
    shift 2
    js="$*"
    js_lit="$(json_escape "$js")"
    run_remote_applescript "
set jsCode to $js_lit
tell application \"Safari\"
  do JavaScript jsCode in tab $tab_idx of front window
end tell
"
    ;;
  open-read)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    url="$2"
    delay_s="${3:-5}"
    char_limit="${4:-1600}"
    url_lit="$(json_escape "$url")"
    run_remote_applescript "
set targetURL to $url_lit
tell application \"Safari\"
  activate
  tell front window
    set current tab to (make new tab with properties {URL:targetURL})
  end tell
end tell
delay $delay_s
tell application \"Safari\"
  set t to current tab of front window
  set out to (URL of t) & \"\\nTITLE:\" & (do JavaScript \"document.title\" in t) & \"\\nBODY:\\n\" & (do JavaScript \"document.body.innerText.slice(0,$char_limit)\" in t)
  return out
end tell
"
    ;;
  *)
    usage
    exit 1
    ;;
esac
