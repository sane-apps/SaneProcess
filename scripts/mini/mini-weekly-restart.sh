#!/bin/bash
# Root-owned Sunday restart gate for the always-on Mac mini server.

set -euo pipefail

SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$SYSTEM_PATH"
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  PATH="${SANE_WEEKLY_RESTART_PATH:-$SYSTEM_PATH}"
fi
SERVER_USER="${SANE_SERVER_USER:-stephansmac}"
MIN_UPTIME_DAYS="${SANE_WEEKLY_RESTART_MIN_UPTIME_DAYS:-6}"
DRY_RUN=0
TEST_MODE="${SANE_WEEKLY_RESTART_TEST_MODE:-0}"
SERVER_HOME="/Users/$SERVER_USER"
if [ "$TEST_MODE" = "1" ]; then
  SERVER_HOME="${SANE_SERVER_HOME:-$SERVER_HOME}"
fi
MAINTENANCE_INHIBIT_MINUTES="${SANE_WEEKLY_RESTART_INHIBIT_MINUTES:-720}"
CODEX_ACTIVITY_MINUTES="${SANE_WEEKLY_RESTART_CODEX_ACTIVITY_MINUTES:-45}"
MAINTENANCE_DIR="$SERVER_HOME/.sanemaster"
MAINTENANCE_ACTIVE="$MAINTENANCE_DIR/maintenance-active"
RESTART_EXCLUSIVE="$MAINTENANCE_DIR/restart-exclusive"
RESTART_EXCLUSIVE_HELD=0
EXCLUSIVE_BUSY_REASON=""

if [ "$TEST_MODE" = "1" ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "Refusing test-mode power injection in a real root runtime" >&2
  exit 2
fi

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--dry-run]" >&2
  exit 2
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

release_restart_exclusive() {
  [ "$RESTART_EXCLUSIVE_HELD" -eq 1 ] || return 0
  rmdir "$RESTART_EXCLUSIVE" 2>/dev/null || true
  RESTART_EXCLUSIVE_HELD=0
}
trap release_restart_exclusive EXIT INT TERM

acquire_restart_exclusive() {
  local holder pid
  EXCLUSIVE_BUSY_REASON=""
  if [ ! -d "$MAINTENANCE_DIR" ] || [ -L "$MAINTENANCE_DIR" ] || [ -L "$MAINTENANCE_ACTIVE" ]; then
    EXCLUSIVE_BUSY_REASON="maintenance lock root is missing or unsafe"
    return 1
  fi
  if ! mkdir "$RESTART_EXCLUSIVE" 2>/dev/null; then
    EXCLUSIVE_BUSY_REASON="another restart gate already owns the exclusive lock"
    return 1
  fi
  RESTART_EXCLUSIVE_HELD=1

  if [ -d "$MAINTENANCE_ACTIVE" ]; then
    for holder in "$MAINTENANCE_ACTIVE"/*; do
      [ -f "$holder" ] || continue
      pid="$(basename "$holder")"
      if echo "$pid" | grep -Eq '^[0-9]+$' && kill -0 "$pid" 2>/dev/null; then
        EXCLUSIVE_BUSY_REASON="active SaneMaster maintenance holder pid=$pid"
        release_restart_exclusive
        return 1
      fi
      rm -f "$holder"
    done
  fi
  return 0
}

effective_uid() {
  if [ "$TEST_MODE" = "1" ]; then
    echo "${SANE_WEEKLY_RESTART_TEST_UID:-0}"
  else
    /usr/bin/id -u
  fi
}

restart_server() {
  if [ "$TEST_MODE" = "1" ]; then
    "${SANE_WEEKLY_RESTART_TEST_SHUTDOWN:?missing test shutdown executor}" -r now
  else
    /sbin/shutdown -r now
  fi
}

uptime_days() {
  local up
  up="$(uptime)"
  if echo "$up" | grep -q " day"; then
    echo "$up" | sed -E 's/.* up ([0-9]+) day.*/\1/'
  else
    echo 0
  fi
}

filevault_is_off() {
  fdesetup status 2>/dev/null | grep -q "FileVault is Off"
}

autologin_user() {
  defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true
}

recent_file_exists() {
  local root="$1" minutes="$2"
  [ -e "$root" ] || return 1
  find "$root" -type f -mmin "-$minutes" -print -quit 2>/dev/null | grep -q .
}

busy_reason() {
  local process_pattern matched_process
  process_pattern='mlx_lm|mini-train|xcodebuild|swift( |$)|git( |$)|rsync( |$)|SaneMaster|release\.sh|notarytool|altool|ffmpeg|screencapture|SaneVideo|mini-nightly\.sh|process_intake\.py|queue[_-]worker|wrangler.*deploy|codex exec|Codex.*--resume|sshd:.*@|softwareupdate.*(--install|-i)|startosinstall|InstallAssistant|/usr/sbin/installer'
  matched_process="$(pgrep -fl "$process_pattern" 2>/dev/null | head -1 || true)"

  if [ -n "$matched_process" ]; then
    echo "active work process: $matched_process"
    return 0
  fi
  if recent_file_exists "$SERVER_HOME/.sanemaster/restart-inhibit" "$MAINTENANCE_INHIBIT_MINUTES"; then
    echo "recent SaneMaster maintenance inhibit is active"
    return 0
  fi
  if recent_file_exists "$SERVER_HOME/.codex/sessions" "$CODEX_ACTIVITY_MINUTES"; then
    echo "Codex task state changed within the last ${CODEX_ACTIVITY_MINUTES} minutes"
    return 0
  fi
  if [ "$(effective_uid)" -eq 0 ] && [ "${SANE_WEEKLY_RESTART_TEST_SKIP_HID:-0}" != "1" ]; then
    local idle_ns
    idle_ns="$(/usr/sbin/ioreg -c IOHIDSystem 2>/dev/null | /usr/bin/awk '/HIDIdleTime/ {gsub(/[^0-9]/, "", $NF); print $NF; exit}')"
    if [ -n "$idle_ns" ] && [ "$idle_ns" -lt 1800000000000 ]; then
      echo "local keyboard or mouse activity occurred within the last 30 minutes"
      return 0
    fi
  fi
  echo ""
}

main() {
  local weekday current_uptime login_user busy
  weekday="${SANE_WEEKDAY_OVERRIDE:-$(date +%w)}"
  current_uptime="$(uptime_days)"
  login_user="$(autologin_user)"

  log "Weekly restart preflight start (dry_run=$DRY_RUN uptime_days=$current_uptime)"

  if [ "$weekday" -ne 0 ]; then
    log "Skipped: today is not Sunday"
    return 0
  fi
  if [ "$(effective_uid)" -ne 0 ] && [ "$DRY_RUN" -ne 1 ]; then
    log "Blocked: restart helper must run as root"
    return 1
  fi
  if ! filevault_is_off; then
    log "Skipped: FileVault is still enabled; unattended reboot would strand the server"
    return 0
  fi
  if [ "$login_user" != "$SERVER_USER" ]; then
    log "Skipped: automatic login is not configured for $SERVER_USER"
    return 0
  fi
  if [ "$current_uptime" -lt "$MIN_UPTIME_DAYS" ]; then
    log "Skipped: uptime is only ${current_uptime}d (minimum ${MIN_UPTIME_DAYS}d)"
    return 0
  fi

  busy="$(busy_reason)"
  if [ -n "$busy" ]; then
    log "Skipped: $busy (next retry is later today or next Sunday)"
    return 0
  fi

  if ! acquire_restart_exclusive; then
    log "Skipped: $EXCLUSIVE_BUSY_REASON (next retry is later today or next Sunday)"
    return 0
  fi

  busy="$(busy_reason)"
  if [ -n "$busy" ]; then
    log "Skipped after exclusive-lock recheck: $busy (next retry is later today or next Sunday)"
    release_restart_exclusive
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: server is eligible for a guarded restart"
    release_restart_exclusive
    return 0
  fi

  log "Preflight passed; restarting with /sbin/shutdown -r now"
  /bin/sync
  restart_server
}

main "$@"
