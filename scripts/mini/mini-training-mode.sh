#!/bin/bash
# mini-training-mode.sh - Quiesce the Mini for overnight MLX training.
# Usage:
#   mini-training-mode.sh enter
#   mini-training-mode.sh exit
#   mini-training-mode.sh status

set -euo pipefail

ACTION="${1:-status}"
TRAINING_MODE_TAG="${TRAINING_MODE_TAG:-default}"
STATE_ROOT="${TRAINING_MODE_STATE_ROOT:-$HOME/.mini-training-mode}"
STATE_DIR="$STATE_ROOT/$TRAINING_MODE_TAG"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"
DRY_RUN="${TRAINING_MODE_DRY_RUN:-false}"
REOPEN_APPS="${TRAINING_MODE_REOPEN_APPS:-false}"
TRAINING_MODE_AGENT_SUSPEND_LIST="${TRAINING_MODE_AGENT_SUSPEND_LIST-com.saneapps.always-awake,com.saneapps.codex-keepalive,com.saneapps.evening,com.saneapps.git-sync-safe,com.saneapps.mcp-watchdog,com.saneapps.memory-guard,com.saneapps.morning,com.saneapps.nightly,com.saneapps.nv-benchmark,com.saneapps.training-daily-check,com.google.GoogleUpdater.wake,com.google.keystone.agent,com.google.keystone.xpcservice,com.grammarly.ProjectLlama.Shepherd,com.grammarly.ProjectLlama.cleanup,com.logos.LogosIndexer,com.logos.desktop.logosindexer}"
TRAINING_MODE_APP_QUIT_LIST="${TRAINING_MODE_APP_QUIT_LIST-Codex,Xcode,SaneBar,SaneClip,SaneHosts,Shottr,MenuMeters,gfxCardStatus,Safari}"
TRAINING_MODE_PROCESS_KILL_PATTERNS="${TRAINING_MODE_PROCESS_KILL_PATTERNS-xcodebuildmcp,validation_report.rb}"

trim() {
  printf '%s' "$1" | sed 's/^ *//; s/ *$//'
}

csv_to_lines() {
  printf '%s\n' "$1" | tr ',' '\n' | while IFS= read -r entry; do
    entry=$(trim "$entry")
    [ -n "$entry" ] && printf '%s\n' "$entry"
  done
}

safe_run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi

  "$@"
}

plist_for_label() {
  local label="$1"
  local plist_path="$LAUNCH_AGENTS_DIR/${label}.plist"
  if [ -f "$plist_path" ]; then
    printf '%s\n' "$plist_path"
    return 0
  fi

  return 1
}

launchctl_label_loaded() {
  local label="$1"
  launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1
}

restore_launch_agent() {
  local label="$1"
  local plist_path="$2"

  if launchctl_label_loaded "$label"; then
    return 0
  fi

  safe_run launchctl bootstrap "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
  safe_run launchctl enable "gui/$(id -u)/${label}" >/dev/null 2>&1 || true

  if launchctl_label_loaded "$label"; then
    return 0
  fi

  safe_run launchctl load -w "$plist_path" >/dev/null 2>&1 || true
  safe_run launchctl enable "gui/$(id -u)/${label}" >/dev/null 2>&1 || true

  launchctl_label_loaded "$label"
}

app_is_running() {
  local app_name="$1"
  pgrep -ix "$app_name" >/dev/null 2>&1
}

capture_top_processes() {
  ps axo rss,%mem,comm,args | sort -nr | awk 'NR <= 12 { print }'
}

kill_matching_processes() {
  local process_name="$1"
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] pkill -TERM -x %s\n' "$process_name"
    return 0
  fi

  pkill -TERM -x "$process_name" 2>/dev/null || true
  sleep 2
  if app_is_running "$process_name"; then
    pkill -KILL -x "$process_name" 2>/dev/null || true
  fi
}

kill_matching_patterns() {
  local pattern="$1"
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] pkill -TERM -f %s\n' "$pattern"
    return 0
  fi

  pkill -TERM -f "$pattern" 2>/dev/null || true
  sleep 2
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -KILL -f "$pattern" 2>/dev/null || true
  fi
}

quit_app() {
  local app_name="$1"
  if ! app_is_running "$app_name"; then
    return 1
  fi

  printf 'quitting app: %s\n' "$app_name"
  if [ "$DRY_RUN" = "true" ]; then
    printf '[dry-run] osascript quit %s\n' "$app_name"
    return 0
  fi

  osascript -e "tell application \"$app_name\" to quit" >/dev/null 2>&1 || true
  sleep 3
  kill_matching_processes "$app_name"
  return 0
}

enter_training_mode() {
  local label plist_path app_name
  local suspended_agents_file quit_apps_file before_file after_file log_file

  mkdir -p "$STATE_DIR"
  suspended_agents_file="$STATE_DIR/suspended_agents.txt"
  quit_apps_file="$STATE_DIR/quit_apps.txt"
  before_file="$STATE_DIR/top_before.txt"
  after_file="$STATE_DIR/top_after.txt"
  log_file="$STATE_DIR/enter.log"

  : > "$suspended_agents_file"
  : > "$quit_apps_file"
  : > "$log_file"
  date +"%Y-%m-%d %H:%M:%S" > "$STATE_DIR/entered_at.txt"
  capture_top_processes > "$before_file"

  printf 'training mode tag: %s\n' "$TRAINING_MODE_TAG" | tee -a "$log_file"
  printf 'top processes before isolation:\n' | tee -a "$log_file"
  cat "$before_file" | tee -a "$log_file"

  csv_to_lines "$TRAINING_MODE_AGENT_SUSPEND_LIST" | while IFS= read -r label; do
    [ -n "$label" ] || continue
    if ! plist_path=$(plist_for_label "$label"); then
      continue
    fi
    if ! launchctl_label_loaded "$label"; then
      continue
    fi
    printf 'suspending agent: %s\n' "$label" | tee -a "$log_file"
    if safe_run launchctl bootout "gui/$(id -u)/${label}"; then
      printf '%s\n' "$label" >> "$suspended_agents_file"
    fi
  done

  csv_to_lines "$TRAINING_MODE_APP_QUIT_LIST" | while IFS= read -r app_name; do
    [ -n "$app_name" ] || continue
    if quit_app "$app_name"; then
      printf '%s\n' "$app_name" >> "$quit_apps_file"
    fi
  done

  csv_to_lines "$TRAINING_MODE_PROCESS_KILL_PATTERNS" | while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      printf 'draining process pattern: %s\n' "$pattern" | tee -a "$log_file"
      kill_matching_patterns "$pattern"
    fi
  done

  if command -v purge >/dev/null 2>&1; then
    printf 'purging inactive filesystem cache\n' | tee -a "$log_file"
    safe_run purge >/dev/null 2>&1 || true
  fi

  capture_top_processes > "$after_file"
  printf 'top processes after isolation:\n' | tee -a "$log_file"
  cat "$after_file" | tee -a "$log_file"
}

exit_training_mode() {
  local label plist_path app_name
  local suspended_agents_file quit_apps_file log_file

  suspended_agents_file="$STATE_DIR/suspended_agents.txt"
  quit_apps_file="$STATE_DIR/quit_apps.txt"
  log_file="$STATE_DIR/exit.log"
  : > "$log_file"

  if [ -f "$suspended_agents_file" ]; then
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      if ! plist_path=$(plist_for_label "$label"); then
        continue
      fi
      printf 'restoring agent: %s\n' "$label" | tee -a "$log_file"
      restore_launch_agent "$label" "$plist_path" || true
    done < "$suspended_agents_file"
  fi

  if [ "$REOPEN_APPS" = "true" ] && [ -f "$quit_apps_file" ]; then
    while IFS= read -r app_name; do
      [ -n "$app_name" ] || continue
      printf 'reopening app: %s\n' "$app_name" | tee -a "$log_file"
      if [ "$DRY_RUN" = "true" ]; then
        printf '[dry-run] open -a %s\n' "$app_name"
      else
        open -a "$app_name" >/dev/null 2>&1 || true
      fi
    done < "$quit_apps_file"
  fi
}

status_training_mode() {
  printf 'training mode tag: %s\n' "$TRAINING_MODE_TAG"
  if [ -d "$STATE_DIR" ]; then
    printf 'state dir: %s\n' "$STATE_DIR"
    [ -f "$STATE_DIR/entered_at.txt" ] && printf 'entered at: %s\n' "$(cat "$STATE_DIR/entered_at.txt")"
    if [ -f "$STATE_DIR/suspended_agents.txt" ]; then
      printf 'suspended agents:\n'
      sed 's/^/  - /' "$STATE_DIR/suspended_agents.txt"
    fi
    if [ -f "$STATE_DIR/quit_apps.txt" ]; then
      printf 'quit apps:\n'
      sed 's/^/  - /' "$STATE_DIR/quit_apps.txt"
    fi
  else
    printf 'state dir: not present\n'
  fi

  printf 'top current processes:\n'
  capture_top_processes
}

case "$ACTION" in
  enter)
    enter_training_mode
    ;;
  exit)
    exit_training_mode
    ;;
  status)
    status_training_mode
    ;;
  *)
    echo "Usage: $0 {enter|exit|status}" >&2
    exit 2
    ;;
esac
