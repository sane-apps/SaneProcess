#!/bin/bash
# LEGACY (owner retired the Safari exception 2026-07-15): ASC portal work runs
# through Brave on the Mini (Claude-in-Chrome widget / Codex Chrome lane), like
# ALL other agent browser work. Do not extend this script or point it at any
# portal — sane_bash_guards.rb blocks Safari automation, including this wrapper.
# Kept only as reference for the old ASC/Apple ID Safari tab flow.
set -euo pipefail

MINI_HOST="${MINI_HOST:-mini}"
MINI_HOST_FALLBACKS="${MINI_HOST_FALLBACKS:-stephansmac@Stephans-Mac-mini.local stephansmac@stephans-mac-mini.local}"

usage() {
  cat <<'EOF'
Usage:
  mini-safari.sh list-tabs
  mini-safari.sh open <url> [delay_seconds]
  mini-safari.sh open-current <url> [delay_seconds]
  mini-safari.sh read [tab_index] [char_limit]
  mini-safari.sh js [tab_index] <javascript>
  mini-safari.sh open-read <url> [delay_seconds] [char_limit]
  mini-safari.sh open-read-current <url> [delay_seconds] [char_limit]
  mini-safari.sh asc-login <apple_id_email> [url]

Notes:
  - Drives Safari on the Mac Mini via AppleScript.
  - App Store Connect and Apple Developer portal work must reuse the current tab
    with open-current/open-read-current. Opening fresh portal tabs can invalidate
    login state and lock Passwords/2FA flows.
  - `tab_index` is 1-based and defaults to the current tab.
  - `read` returns final URL, title, and a body-text snippet.
  - `asc-login` closes Finder/Preview clutter, captures a full-screen receipt,
    reuses the current Safari tab, and drives the saved-password login path.
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
  if is_current_mini; then
    if ! osascript <<EOF
$script
EOF
    then
      echo "Local Mini Safari automation is unavailable (Automation/TCC or Safari scripting access)." >&2
      return 1
    fi
    return $?
  fi
  ssh "$(resolve_mini_host)" <<EOF
osascript <<'APPLESCRIPT'
$script
APPLESCRIPT
EOF
}

is_current_mini() {
  local local_host
  [[ "${MINI_SAFARI_FORCE_LOCAL:-0}" == "1" ]] && return 0
  local_host="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || true)"
  case "${local_host}" in
    *Mac-mini*|*mac-mini*|*MacMini*|*macmini*) return 0 ;;
  esac
  return 1
}

resolve_mini_host() {
  local host="$MINI_HOST"
  local resolved_host=""
  local candidate=""
  local candidates=""

  if ssh -o BatchMode=yes -o ConnectTimeout=2 "$host" true >/dev/null 2>&1; then
    printf '%s' "$host"
    return 0
  fi

  candidates="${candidates}${host}
"
  resolved_host="$(ssh -G "$host" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  if [ -n "$resolved_host" ]; then
    candidates="${candidates}${resolved_host}
"
    case "$resolved_host" in
      *@*) ;;
      *) candidates="${candidates}stephansmac@${resolved_host}
" ;;
    esac
  fi

  for candidate in $MINI_HOST_FALLBACKS; do
    candidates="${candidates}${candidate}
"
  done

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "$candidate" true >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done <<EOF
$candidates
EOF

  echo "Could not reach the canonical Mini host." >&2
  echo "Set MINI_HOST=user@host and retry." >&2
  return 1
}

requires_single_portal_tab() {
  local url="$1"
  [[ "$url" =~ ^https://([^/]+\.)?(appstoreconnect\.apple\.com|developer\.apple\.com|idmsa\.apple\.com)(/|$) ]]
}

guard_new_portal_tab() {
  local url="$1"
  if requires_single_portal_tab "$url" && [[ "${MINI_SAFARI_ALLOW_NEW_PORTAL_TAB:-}" != "1" ]]; then
    cat >&2 <<'EOF'
Refusing to open a new Safari tab/window for an Apple portal URL.
Use `mini-safari.sh open-current` or `mini-safari.sh open-read-current` so
App Store Connect / Apple Developer login state stays in one Mini Safari tab.
Set MINI_SAFARI_ALLOW_NEW_PORTAL_TAB=1 only for deliberate manual recovery.
EOF
    exit 2
  fi
}

mini_screenshot() {
  "${BASH_SOURCE%/*}/capture-mini-screenshot.sh" "$@" | tail -1
}

apple_portal_loaded() {
  grep -Eq "App Store Connect|Users and Access|My Apps|Agreements|Certificates|Identifiers|Profiles|developer.apple.com|appstoreconnect.apple.com" <<<"$1"
}

close_portal_clutter() {
  run_remote_applescript '
tell application "Finder"
  close every window
end tell
tell application "Preview"
  if running then close every window
end tell
tell application "Safari"
  activate
end tell
'
}

safari_window_geometry() {
  "${BASH_SOURCE%/*}/capture-mini-screenshot.sh" --list-windows | awk '$2 == "Safari" { print $4; exit }'
}

coordinate_for() {
  local geom="$1"
  local x_ratio="$2"
  local y_ratio="$3"
  python3 - "$geom" "$x_ratio" "$y_ratio" <<'PY'
import re
import sys

geom, xr, yr = sys.argv[1:4]
match = re.match(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", geom)
if not match:
    raise SystemExit(f"invalid Safari geometry: {geom}")
w, h, x, y = map(int, match.groups())
print(f"{round(x + w * float(xr))},{round(y + h * float(yr))}")
PY
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
    guard_new_portal_tab "$url"
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
  open-current)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    url="$2"
    delay_s="${3:-4}"
    url_lit="$(json_escape "$url")"
    run_remote_applescript "
set targetURL to $url_lit
tell application \"Safari\"
  activate
  if (count of windows) is 0 then
    make new document with properties {URL:targetURL}
  else
    set URL of current tab of front window to targetURL
  end if
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
    guard_new_portal_tab "$url"
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
  open-read-current)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    url="$2"
    delay_s="${3:-5}"
    char_limit="${4:-1600}"
    url_lit="$(json_escape "$url")"
    run_remote_applescript "
set targetURL to $url_lit
tell application \"Safari\"
  activate
  if (count of windows) is 0 then
    make new document with properties {URL:targetURL}
  else
    set URL of current tab of front window to targetURL
  end if
end tell
delay $delay_s
tell application \"Safari\"
  set t to current tab of front window
  set out to (URL of t) & \"\\nTITLE:\" & (do JavaScript \"document.title\" in t) & \"\\nBODY:\\n\" & (do JavaScript \"document.body.innerText.slice(0,$char_limit)\" in t)
  return out
end tell
"
    ;;
  asc-login)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    email="$2"
    url="${3:-https://appstoreconnect.apple.com/}"
    requires_single_portal_tab "$url" || {
      echo "asc-login only accepts Apple portal URLs." >&2
      exit 2
    }

    close_portal_clutter >/dev/null
    before_shot="$(mini_screenshot --skip-cleanup --mode temp)"
    echo "Full-screen pre-login receipt: $before_shot"

    "$0" open-current "$url" 5 >/dev/null
    body="$("$0" read "" 2000 || true)"
    if ! grep -q "Email or Phone Number\\|Continue with Password\\|Sign in with Passkey" <<<"$body"; then
      if apple_portal_loaded "$body"; then
        echo "Safari appears to already be on an Apple portal page; no login click was needed."
        echo "$body" | sed -n '1,12p'
        exit 0
      fi
      echo "Safari is in an unexpected Apple auth state. Inspect the current page and screenshot receipt; do not assume login succeeded." >&2
      echo "$body" | sed -n '1,12p'
      exit 1
    fi

    geom="$(safari_window_geometry)"
    [[ -n "$geom" ]] || {
      echo "Could not locate Safari window geometry for login clicks." >&2
      exit 1
    }
    email_xy="$(coordinate_for "$geom" 0.50 0.50)"
    arrow_xy="$(coordinate_for "$geom" 0.65 0.50)"
    password_xy="$(coordinate_for "$geom" 0.405 0.56)"

    run_remote_applescript "
tell application \"Safari\" to activate
set the clipboard to \"$(printf '%s' "$email" | sed 's/\\/\\\\/g; s/"/\\"/g')\"
"
    ssh "$(resolve_mini_host)" "/opt/homebrew/bin/cliclick c:$email_xy; sleep 0.2; /opt/homebrew/bin/cliclick kd:cmd t:a ku:cmd; sleep 0.1; /opt/homebrew/bin/cliclick kd:cmd t:v ku:cmd; sleep 0.2; /opt/homebrew/bin/cliclick c:$arrow_xy; sleep 3; /opt/homebrew/bin/cliclick c:$password_xy; sleep 2"

    after_shot="$(mini_screenshot --skip-cleanup --mode temp)"
    echo "Full-screen post-login-click receipt: $after_shot"
    "$0" read "" 2000 || true
    ;;
  *)
    usage
    exit 1
    ;;
esac
