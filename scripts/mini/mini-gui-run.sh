#!/bin/bash
# Run a shell command inside the logged-in Mini GUI Terminal session.
# Use this for App Store archive/export/upload work when plain ssh shell
# codesign fails with errSecInternalComponent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLESCRIPT_PATH="$SCRIPT_DIR/mini-gui-run.applescript"
RECLAIM_SCRIPT_PATH="$SCRIPT_DIR/mini-reclaim-automation-windows.sh"
AUTOMATION_WINDOW_PREFIX="${MINI_GUI_RUN_WINDOW_PREFIX:-SaneApps Automation: }"

usage() {
  cat <<'EOF' >&2
Usage:
  mini-gui-run.sh [--log-file PATH] [--status-file PATH] [--title TEXT] [--keep-window] [--reclaim-all] [--poll-seconds N] -- "shell command"

Examples:
  mini-gui-run.sh --close-window --title "codesign probe" -- "codesign --force --sign \"Apple Distribution: ...\" /tmp/probe"
  mini-gui-run.sh --log-file /tmp/sanesales-archive.log --title "SaneSales archive" -- "cd ~/SaneApps/apps/SaneSales && xcodebuild archive ..."
EOF
  exit 2
}

shell_quote() {
  printf "%q" "$1"
}

close_window=1
poll_seconds=1
start_delay_seconds="${MINI_GUI_RUN_START_DELAY:-0.6}"
log_file=""
status_file=""
title="Mini GUI Run"
reclaim_all=0

while [ $# -gt 0 ]; do
  case "$1" in
    --log-file)
      [ $# -ge 2 ] || usage
      log_file="$2"
      shift 2
      ;;
    --status-file)
      [ $# -ge 2 ] || usage
      status_file="$2"
      shift 2
      ;;
    --title)
      [ $# -ge 2 ] || usage
      title="$2"
      shift 2
      ;;
    --keep-window)
      close_window=0
      shift
      ;;
    --reclaim-all)
      reclaim_all=1
      shift
      ;;
    --close-window)
      close_window=1
      shift
      ;;
    --poll-seconds)
      [ $# -ge 2 ] || usage
      poll_seconds="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
done

[ $# -gt 0 ] || usage

command_string="$*"
window_title="${AUTOMATION_WINDOW_PREFIX}${title}"
quoted_command="$(shell_quote "$command_string")"
tmp_dir=""
cleanup_tmp=0
if [ -z "$log_file" ] || [ -z "$status_file" ]; then
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mini-gui-run.XXXXXX")"
  cleanup_tmp=1
fi

if [ -z "$log_file" ]; then
  log_file="$tmp_dir/output.log"
fi
if [ -z "$status_file" ]; then
  status_file="$tmp_dir/status.txt"
fi

mkdir -p "$(dirname "$log_file")" "$(dirname "$status_file")"
: > "$log_file"
rm -f "$status_file"

trap 'if [ "$cleanup_tmp" -eq 1 ] && [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ]; then rm -rf "$tmp_dir"; fi' EXIT

reclaim_windows() {
  [ -x "$RECLAIM_SCRIPT_PATH" ] || return 0

  if [ "$reclaim_all" -eq 1 ]; then
    "$RECLAIM_SCRIPT_PATH" --all --title "$title" "$@" >/dev/null 2>&1 || true
  else
    "$RECLAIM_SCRIPT_PATH" --title "$title" "$@" >/dev/null 2>&1 || true
  fi
}

reclaim_windows

inner_script=$(cat <<EOF
printf '\\033]1;%s\\007\\033]2;%s\\007' $(shell_quote "$window_title") $(shell_quote "$window_title")
set -o pipefail
sleep $(shell_quote "$start_delay_seconds")
bash -lc ${quoted_command} 2>&1 | tee -a $(shell_quote "$log_file")
__mini_gui_status=\${PIPESTATUS[0]}
printf '%s\n' "\$__mini_gui_status" > $(shell_quote "$status_file")
exit "\$__mini_gui_status"
EOF
)

terminal_command="bash -lc $(shell_quote "$inner_script")"

window_id="$(
  /usr/bin/osascript "$APPLESCRIPT_PATH" "$window_title" "$terminal_command"
)"

window_still_exists() {
  local target_id="$1"
  /usr/bin/osascript <<EOF >/dev/null 2>&1
tell application "Terminal"
  repeat with w in windows
    try
      if id of w is equal to ${target_id} then return true
    end try
  end repeat
end tell
return false
EOF
}

close_window_by_id() {
  local target_id="$1"
  /usr/bin/osascript <<EOF >/dev/null 2>&1
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
EOF
}

while [ ! -f "$status_file" ]; do
  sleep "$poll_seconds"
  if ! window_still_exists "$window_id"; then
    break
  fi
done

if [ "$close_window" -eq 1 ] && [ -n "${window_id:-}" ]; then
  close_window_by_id "$window_id"
fi

reclaim_windows --hide-terminal

if [ ! -f "$status_file" ]; then
  echo "mini-gui-run: command finished without a status file: $status_file" >&2
  [ -s "$log_file" ] && cat "$log_file" >&2
  exit 1
fi

status_code="$(tr -d '\r\n' < "$status_file")"
[ -s "$log_file" ] && cat "$log_file"

case "$status_code" in
  ''|*[!0-9]*)
    echo "mini-gui-run: invalid status code: $status_code" >&2
    exit 1
    ;;
  *)
    exit "$status_code"
    ;;
esac
