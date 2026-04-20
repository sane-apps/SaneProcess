#!/bin/bash
set -euo pipefail

AUTOMATION_PREFIX="${MINI_GUI_RUN_WINDOW_PREFIX:-SaneApps Automation: }"

usage() {
  cat <<'EOF' >&2
Usage:
  mini-reclaim-automation-windows.sh [--title TEXT] [--all] [--hide-terminal] [--dry-run]

Examples:
  mini-reclaim-automation-windows.sh --title "SaneSales App Store Screenshots"
  mini-reclaim-automation-windows.sh --all --hide-terminal

Notes:
  - Closes Mini automation Terminal windows created by mini-gui-run.sh.
  - --title reclaims windows for one automation family.
  - --all reclaims every known automation window, including legacy pre-prefix titles.
EOF
  exit 2
}

requested_title=""
reclaim_all=0
hide_terminal=0
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --title)
      [ $# -ge 2 ] || usage
      requested_title="$2"
      shift 2
      ;;
    --all)
      reclaim_all=1
      shift
      ;;
    --hide-terminal)
      hide_terminal=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *)
      usage
      ;;
  esac
done

if [ "$reclaim_all" -ne 1 ] && [ -z "$requested_title" ]; then
  usage
fi

list_windows() {
  /usr/bin/osascript <<'OSA'
set outputLines to {}
set tabDelimiter to ASCII character 9
tell application "Terminal"
  repeat with w in windows
    set winID to ""
    set winName to ""
    set tabTitle to ""
    try
      set winID to (id of w as string)
    end try
    try
      set winName to name of w
    end try
    try
      set tabTitle to custom title of selected tab of w
    end try
    set end of outputLines to (winID & tabDelimiter & winName & tabDelimiter & tabTitle)
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return outputLines as text
OSA
}

is_prefixed_window() {
  local name="$1"
  local tab_title="$2"
  [[ "$name" == *"$AUTOMATION_PREFIX"* || "$tab_title" == *"$AUTOMATION_PREFIX"* ]]
}

is_requested_title_window() {
  local name="$1"
  local tab_title="$2"
  [ -n "$requested_title" ] && [[ "$name" == *"$requested_title"* || "$tab_title" == *"$requested_title"* ]]
}

is_known_legacy_automation_window() {
  local haystack="$1"
  case "$haystack" in
    *" App Store "*'['*'-'*']'*|*" GUI Capture "*'['*'-'*']'*|*" Mini Screenshot "*'['*'-'*']'*|*" Mini Desktop "*'['*'-'*']'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

close_window_by_id() {
  local target_id="$1"
  /usr/bin/osascript <<OSA >/dev/null
tell application "Terminal"
  repeat with w in windows
    try
      if id of w is equal to ${target_id} then
        close w saving no
        exit repeat
      end if
    end try
  end repeat
end tell
OSA
}

window_matches_reclaim_scope() {
  local name="$1"
  local tab_title="$2"

  if is_prefixed_window "$name" "$tab_title"; then
    return 0
  fi
  if is_requested_title_window "$name" "$tab_title"; then
    return 0
  fi
  if [ "$reclaim_all" -eq 1 ] && is_known_legacy_automation_window "${name} ${tab_title}"; then
    return 0
  fi

  return 1
}

quit_terminal_if_only_automation_windows_remain() {
  local saw_window=0
  local non_automation_window=0
  local window_id=""
  local window_name=""
  local tab_title=""

  while IFS=$'\t' read -r window_id window_name tab_title; do
    [ -n "${window_id:-}" ] || continue
    saw_window=1
    if ! window_matches_reclaim_scope "$window_name" "$tab_title"; then
      non_automation_window=1
      break
    fi
  done < <(list_windows)

  if [ "$saw_window" -eq 1 ] && [ "$non_automation_window" -eq 0 ]; then
    /usr/bin/osascript -e 'tell application "Terminal" to quit saving no' >/dev/null 2>&1 || true
  fi
}

closed_count=0

while IFS=$'\t' read -r window_id window_name tab_title; do
  [ -n "${window_id:-}" ] || continue

  should_close=1
  if window_matches_reclaim_scope "$window_name" "$tab_title"; then
    should_close=0
  fi

  if [ "$should_close" -eq 0 ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'would close %s\t%s\t%s\n' "$window_id" "$window_name" "$tab_title"
    else
      close_window_by_id "$window_id"
    fi
    closed_count=$((closed_count + 1))
  fi
done < <(list_windows)

if [ "$dry_run" -ne 1 ]; then
  quit_terminal_if_only_automation_windows_remain
fi

if [ "$hide_terminal" -eq 1 ] && [ "$dry_run" -ne 1 ]; then
  /usr/bin/osascript -e 'tell application "System Events" to set visible of process "Terminal" to false' >/dev/null 2>&1 || true
fi

if [ "$dry_run" -ne 1 ]; then
  printf 'closed=%s\n' "$closed_count"
fi
