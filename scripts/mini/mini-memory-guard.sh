#!/bin/bash
# mini-memory-guard.sh - Daily Mac mini hygiene + safe reboot gate
# Intended to run via LaunchAgent in early-morning hours.
#
# Goals:
# - Keep the mini responsive as a build server.
# - Kill stale dev app binaries from DerivedData.
# - Prune stale routed release workspaces and validation output.
# - Rotate oversized logs.
# - Reboot only when safe (night window, no critical jobs).

set -euo pipefail

DRY_RUN=0
FORCE_REBOOT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force-reboot) FORCE_REBOOT=1 ;;
    *)
      echo "Usage: $0 [--dry-run] [--force-reboot]" >&2
      exit 2
      ;;
  esac
done

OUTPUT_DIR="$HOME/SaneApps/outputs"
LOG_FILE="$OUTPUT_DIR/mini_memory_guard.log"
mkdir -p "$OUTPUT_DIR"

log() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" | tee -a "$LOG_FILE"
}

get_load1() {
  uptime | awk -F'load averages: ' '{print $2}' | tr -d ',' | awk '{print $1}'
}

get_swap_used_mb() {
  sysctl vm.swapusage | awk -F'used = ' '{print $2}' | awk '{gsub(/M/,"",$1); print $1}'
}

get_free_pct() {
  memory_pressure -Q 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2; exit}'
}

get_uptime_days() {
  local up
  up="$(uptime)"
  if echo "$up" | grep -q " day"; then
    echo "$up" | sed -E 's/.* up ([0-9]+) day.*/\1/'
  else
    echo "0"
  fi
}

get_data_disk_free_gb() {
  df -g /System/Volumes/Data | tail -1 | awk '{print $4}'
}

is_training_running() {
  pgrep -f "mlx_lm lora --train" >/dev/null 2>&1 || \
    pgrep -f "mini-train.sh" >/dev/null 2>&1 || \
    pgrep -f "mini-train-all.sh" >/dev/null 2>&1
}

is_nightly_running() {
  pgrep -f "mini-nightly.sh" >/dev/null 2>&1 || \
    pgrep -f "xcodebuild .*Sane" >/dev/null 2>&1
}

rotate_if_large() {
  local file="$1"
  local max_bytes="$2"
  local keep_bytes="$3"

  [ -f "$file" ] || return 0
  local size
  size=$(stat -f%z "$file" 2>/dev/null || echo 0)
  if [ "$size" -gt "$max_bytes" ]; then
    local tmp="${file}.tmp"
    tail -c "$keep_bytes" "$file" > "$tmp" && mv "$tmp" "$file"
    log "Rotated $file (size=${size}B, kept last ${keep_bytes}B)"
  fi
}

safe_remove_path() {
  local path="$1"
  case "$path" in
    "$HOME/SaneApps/apps/"*|\
    "$HOME/SaneApps-automation/apps/"*|\
    "$HOME/SaneApps/outputs/setapp_review/"*|\
    "$HOME/SaneApps/outputs/automation-smoke/"*|\
    "$HOME/SaneApps/tmp/"*|\
    "$HOME/tmp/"*|\
    "$HOME/Library/Developer/Xcode/DerivedData/"*|\
    "$HOME/Library/Developer/CoreSimulator/Devices/"*|\
    "$HOME/.sanemaster/routed-workspaces/"*|\
    "$HOME/.codex-sync-backups/"*|\
    "$HOME/.Trash/"*)
      ;;
    *)
      log "Refusing delete outside safe roots: $path"
      return 1
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: would remove $path"
    return 0
  fi

  rm -rf "$path"
}

prune_old_dirs_by_mtime() {
  local root="$1"
  local pattern="$2"
  local keep_days="$3"
  local label="$4"
  local min_keep="$5"

  [ -d "$root" ] || return 0
  [[ "$keep_days" =~ ^[0-9]+$ ]] || keep_days=3
  [[ "$min_keep" =~ ^[0-9]+$ ]] || min_keep=1

  local matches=()
  local path
  shopt -s nullglob
  for path in "$root"/$pattern; do
    [ -d "$path" ] || continue
    matches+=("$path")
  done
  shopt -u nullglob

  [ "${#matches[@]}" -gt 0 ] || return 0

  local removed=0
  local freed_mb=0
  local idx=0
  local dir
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    idx=$((idx + 1))
    if [ "$idx" -le "$min_keep" ]; then
      continue
    fi
    if [ -z "$(find "$dir" -maxdepth 0 -mtime +"$keep_days" -print -quit 2>/dev/null)" ]; then
      continue
    fi
    local dir_mb
    dir_mb=$(du -sm "$dir" 2>/dev/null | awk '{print $1}')
    safe_remove_path "$dir" || continue
    removed=$((removed + 1))
    freed_mb=$((freed_mb + dir_mb))
  done < <(printf '%s\n' "${matches[@]}" | xargs ls -1dt 2>/dev/null)

  if [ "$removed" -gt 0 ]; then
    log "Pruned $removed ${label} dir(s), freed ${freed_mb}MB (keep_days=$keep_days min_keep=$min_keep)"
  else
    log "No ${label} dirs older than ${keep_days} day(s) beyond min_keep=$min_keep"
  fi
}

prune_sweep_dirs() {
  local sweeps_root="$1"
  local keep_days="$2"
  local label="$3"
  local min_keep="$4"

  [ -d "$sweeps_root" ] || return 0
  [[ "$keep_days" =~ ^[0-9]+$ ]] || keep_days=3
  [[ "$min_keep" =~ ^[0-9]+$ ]] || min_keep=4

  local cutoff
  cutoff=$(date -v-"${keep_days}"d +"%Y-%m-%d")
  local removed=0
  local freed_mb=0

  local sweep_idx=0
  for sweep_dir in $(ls -1dt "$sweeps_root"/sweep_* "$sweeps_root"/challenger_* 2>/dev/null); do
    [ -d "$sweep_dir" ] || continue
    sweep_idx=$((sweep_idx + 1))
    if [ "$sweep_idx" -le "$min_keep" ]; then
      continue
    fi

    local sweep_date
    sweep_date=$(basename "$sweep_dir" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ -z "$sweep_date" ] && continue

    if [[ "$sweep_date" < "$cutoff" ]]; then
      local dir_mb
      dir_mb=$(du -sm "$sweep_dir" 2>/dev/null | awk '{print $1}')
      safe_remove_path "$sweep_dir" || continue
      removed=$((removed + 1))
      freed_mb=$((freed_mb + dir_mb))
    fi
  done

  if [ "$removed" -gt 0 ]; then
    log "Pruned $removed ${label} dir(s), freed ${freed_mb}MB (keep_days=$keep_days min_keep=$min_keep)"
  else
    log "No ${label} dirs older than ${keep_days} day(s) beyond min_keep=$min_keep"
  fi
}

cleanup_training_artifacts() {
  # Production sweeps should be short-lived checkpoints; keep recent history only.
  for sane_root in "$HOME/SaneApps" "$HOME/SaneApps-automation"; do
    [ -d "$sane_root/apps" ] || continue

    prune_sweep_dirs "$sane_root/apps/SaneAI/models/sweeps" "${SANEAI_SWEEP_KEEP_DAYS:-3}" "SaneAI sweep" "${SANEAI_SWEEP_MIN_KEEP:-4}"
    prune_sweep_dirs "$sane_root/apps/SaneSync/models/sweeps" "${SANESYNC_SWEEP_KEEP_DAYS:-7}" "SaneSync sweep" "${SANESYNC_SWEEP_MIN_KEEP:-4}"

    # Temporary fusion test outputs can be multi-GB and are safe to discard.
    for tmp_dir in "$sane_root/apps/SaneSync/models"/_fuse_test_*; do
      [ -d "$tmp_dir" ] || continue
      local dir_mb
      dir_mb=$(du -sm "$tmp_dir" 2>/dev/null | awk '{print $1}')
      safe_remove_path "$tmp_dir" || continue
      log "Removed temporary fusion dir $(basename "$tmp_dir") (${dir_mb}MB)"
    done
  done
}

cleanup_routed_workspaces() {
  prune_old_dirs_by_mtime "$HOME/.sanemaster/routed-workspaces" "*" "${ROUTED_WORKSPACE_KEEP_DAYS:-2}" "routed workspace" "${ROUTED_WORKSPACE_MIN_KEEP:-1}"
}

cleanup_sanevideo_outputs() {
  local outputs_root="$HOME/SaneApps/apps/SaneVideo/outputs"
  [ -d "$outputs_root" ] || return 0
  prune_old_dirs_by_mtime "$outputs_root" "recording_validation_*" "${SANEVIDEO_OUTPUT_KEEP_DAYS:-2}" "SaneVideo recording validation" 0
  prune_old_dirs_by_mtime "$outputs_root" "local_air_*" "${SANEVIDEO_OUTPUT_KEEP_DAYS:-2}" "SaneVideo local Air build" 0
  prune_old_dirs_by_mtime "$outputs_root" "hardware_validation" "${SANEVIDEO_OUTPUT_KEEP_DAYS:-2}" "SaneVideo hardware validation" 0
}

cleanup_codex_sync_backups() {
  prune_old_dirs_by_mtime "$HOME/.codex-sync-backups" "*" "${CODEX_BACKUP_KEEP_DAYS:-14}" "Codex sync backup" "${CODEX_BACKUP_MIN_KEEP:-1}"
}

cleanup_stale_automation_git_locks() {
  local automation_root="${AUTOMATION_ROOT:-$HOME/SaneApps-automation}"
  local stale_after_min="${GIT_INDEX_LOCK_STALE_MIN:-30}"
  local removed=0
  local lock_file

  [ -d "$automation_root" ] || return 0

  if ps axww -o pid= -o comm= -o command= | awk -v root="$automation_root" '
    $2 ~ /(^|\/)git$/ && index($0, root) { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    log "Automation git process is active; skipping stale index lock cleanup."
    return 0
  fi

  while IFS= read -r lock_file; do
    [ -n "$lock_file" ] || continue
    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY RUN: would remove stale automation git lock $lock_file"
    else
      rm -f "$lock_file"
      log "Removed stale automation git lock: $lock_file"
    fi
    removed=$((removed + 1))
  done < <(find "$automation_root" -path "*/.git/index.lock" -mmin +"$stale_after_min" -print 2>/dev/null)

  if [ "$removed" -eq 0 ]; then
    log "No stale automation git index locks older than ${stale_after_min} minute(s)"
  fi
}

cleanup_setapp_review_outputs() {
  prune_old_dirs_by_mtime "$HOME/SaneApps/outputs/setapp_review" "*" "${SETAPP_REVIEW_KEEP_DAYS:-1}" "Setapp review output" "${SETAPP_REVIEW_MIN_KEEP:-2}"
}

cleanup_tmp_workspaces() {
  prune_old_dirs_by_mtime "$HOME/tmp" "*" "${TMP_WORKSPACE_KEEP_DAYS:-3}" "home tmp workspace" "${TMP_WORKSPACE_MIN_KEEP:-2}"
  prune_old_dirs_by_mtime "$HOME/SaneApps/tmp" "*" "${SANEAPPS_TMP_KEEP_DAYS:-3}" "SaneApps tmp workspace" "${SANEAPPS_TMP_MIN_KEEP:-2}"
}

cleanup_coresimulator_devices() {
  local devices_root="$HOME/Library/Developer/CoreSimulator/Devices"
  local max_gb="${CORESIMULATOR_DEVICES_MAX_GB:-8}"
  [ -d "$devices_root" ] || return 0

  local devices_mb
  devices_mb=$(du -sm "$devices_root" 2>/dev/null | awk '{print $1}')
  [ -n "$devices_mb" ] || devices_mb=0

  local max_mb=$((max_gb * 1024))
  if [ "$devices_mb" -le "$max_mb" ]; then
    log "CoreSimulator devices within limit (${devices_mb}MB <= ${max_mb}MB)"
    return 0
  fi

  if is_training_running || is_nightly_running; then
    log "CoreSimulator devices are large (${devices_mb}MB) but build/training is active; skipping cleanup."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: would shutdown and delete all CoreSimulator devices (${devices_mb}MB)"
    return 0
  fi

  xcrun simctl shutdown all >/dev/null 2>&1 || true
  xcrun simctl delete all >/dev/null 2>&1 || true
  xcrun simctl delete unavailable >/dev/null 2>&1 || true
  log "CoreSimulator cleanup deleted devices (pre-clean size: ${devices_mb}MB)"
}

cleanup_trash() {
  local trash_root="$HOME/.Trash"
  local max_mb="${TRASH_MAX_MB:-256}"
  [ -d "$trash_root" ] || return 0

  local trash_mb
  trash_mb=$(du -sm "$trash_root" 2>/dev/null | awk '{print $1}')
  [ -n "$trash_mb" ] || trash_mb=0
  if [ "$trash_mb" -le "$max_mb" ]; then
    log "Trash within limit (${trash_mb}MB <= ${max_mb}MB)"
    return 0
  fi

  local removed=0
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    safe_remove_path "$path" || continue
    removed=$((removed + 1))
  done < <(find "$trash_root" -mindepth 1 -maxdepth 1 -print)

  log "Trash cleanup removed $removed path(s) (pre-clean size: ${trash_mb}MB)"
}

cleanup_large_deriveddata() {
  local dd_root="$HOME/Library/Developer/Xcode/DerivedData"
  local max_gb="${DERIVEDDATA_MAX_GB:-5}"
  [ -d "$dd_root" ] || return 0

  local dd_mb
  dd_mb=$(du -sm "$dd_root" 2>/dev/null | awk '{print $1}')
  [ -n "$dd_mb" ] || dd_mb=0

  local max_mb=$((max_gb * 1024))
  if [ "$dd_mb" -le "$max_mb" ]; then
    log "DerivedData within limit (${dd_mb}MB <= ${max_mb}MB)"
    return 0
  fi

  if is_training_running || is_nightly_running; then
    log "DerivedData is large (${dd_mb}MB) but build/training is active; skipping cleanup."
    return 0
  fi

  local removed=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    safe_remove_path "$path" || continue
    removed=$((removed + 1))
  done < <(find "$dd_root" -mindepth 1 -maxdepth 1 -print)

  log "DerivedData cleanup removed $removed path(s) (pre-clean size: ${dd_mb}MB)"
}

cleanup_stale_deriveddata_apps() {
  local stale_count
  stale_count=$(ps -axo command | awk '/\/DerivedData\/.*\/Sane[^ ]*\.app\/Contents\/MacOS\/Sane/{count++} END{print count+0}')
  if [ "$stale_count" -eq 0 ]; then
    log "No stale DerivedData Sane app processes"
    return 0
  fi

  log "Found $stale_count stale DerivedData Sane app process(es)"
  if [ "$DRY_RUN" -eq 1 ]; then
    ps -axo pid,etime,command | grep -E '/DerivedData/.*/Sane[^ ]*\.app/Contents/MacOS/Sane' | grep -v grep | tee -a "$LOG_FILE" || true
    return 0
  fi

  pkill -f '/DerivedData/.*/Sane[^ ]*\.app/Contents/MacOS/Sane' || true
  sleep 1
  log "Killed stale DerivedData Sane app process(es)"
}

in_reboot_window() {
  local hour
  hour=$(date +%H)
  hour=$((10#$hour))
  # Reboot window: 05:00-05:59 local
  [ "$hour" -eq 5 ]
}

should_reboot() {
  local load1 swap_mb free_pct uptime_days
  load1="$(get_load1)"
  swap_mb="$(get_swap_used_mb)"
  free_pct="$(get_free_pct)"
  uptime_days="$(get_uptime_days)"

  local reasons=""
  if awk "BEGIN {exit !($swap_mb >= 3072)}"; then
    reasons="high swap (${swap_mb}MB)"
  fi
  if [ "$uptime_days" -ge 7 ]; then
    if [ -n "$reasons" ]; then reasons="$reasons, "; fi
    reasons="${reasons}long uptime (${uptime_days}d)"
  fi
  if awk "BEGIN {exit !($load1 >= 14)}"; then
    if [ -n "$reasons" ]; then reasons="$reasons, "; fi
    reasons="${reasons}high load (${load1})"
  fi

  if [ "$FORCE_REBOOT" -eq 1 ]; then
    reasons="forced by operator"
  fi

  if [ -z "$reasons" ]; then
    echo ""
  else
    echo "$reasons"
  fi
}

maybe_reboot() {
  local reasons
  reasons="$(should_reboot)"
  if [ -z "$reasons" ]; then
    log "Reboot not needed"
    return 0
  fi

  if ! in_reboot_window; then
    log "Reboot needed ($reasons) but outside safe window (05:00-05:59). Skipping."
    return 0
  fi

  if is_training_running; then
    log "Reboot needed ($reasons) but training is active. Skipping."
    return 0
  fi

  if is_nightly_running; then
    log "Reboot needed ($reasons) but nightly build/test is active. Skipping."
    return 0
  fi

  log "Reboot approved ($reasons)"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: would restart now via System Events"
    return 0
  fi

  if /usr/bin/osascript -e 'tell application "System Events" to restart' >/dev/null 2>&1; then
    log "Restart command sent successfully"
  else
    log "Restart command failed (osascript/System Events denied)"
    return 1
  fi
}

main() {
  local load1 swap_mb free_pct uptime_days disk_free_gb
  load1="$(get_load1)"
  swap_mb="$(get_swap_used_mb)"
  free_pct="$(get_free_pct)"
  uptime_days="$(get_uptime_days)"
  disk_free_gb="$(get_data_disk_free_gb)"

  log "mini-memory-guard start (dry_run=$DRY_RUN force_reboot=$FORCE_REBOOT)"
  log "Health before: load1=$load1 swap_used_mb=$swap_mb free_pct=${free_pct:-unknown} uptime_days=$uptime_days disk_free_gb=${disk_free_gb:-unknown}"

  rotate_if_large "$OUTPUT_DIR/training.stdout.log" 31457280 8388608
  rotate_if_large "$OUTPUT_DIR/training.stderr.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/training-challengers.stdout.log" 20971520 4194304
  rotate_if_large "$OUTPUT_DIR/training-challengers.stderr.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/training-weekly.stdout.log" 20971520 4194304
  rotate_if_large "$OUTPUT_DIR/training-weekly.stderr.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/nightly.stdout.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/nightly.stderr.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/memory-guard.stdout.log" 5242880 1048576
  rotate_if_large "$OUTPUT_DIR/memory-guard.stderr.log" 2097152 524288
  rotate_if_large "$OUTPUT_DIR/mini_memory_guard.log" 5242880 1048576
  rotate_if_large "$OUTPUT_DIR/alerts/training/history.log" 5242880 524288

  cleanup_training_artifacts
  cleanup_routed_workspaces
  cleanup_sanevideo_outputs
  cleanup_codex_sync_backups
  cleanup_stale_automation_git_locks
  cleanup_setapp_review_outputs
  cleanup_tmp_workspaces
  cleanup_trash
  cleanup_coresimulator_devices
  cleanup_large_deriveddata
  cleanup_stale_deriveddata_apps
  maybe_reboot

  load1="$(get_load1)"
  swap_mb="$(get_swap_used_mb)"
  free_pct="$(get_free_pct)"
  uptime_days="$(get_uptime_days)"
  disk_free_gb="$(get_data_disk_free_gb)"
  log "Health after: load1=$load1 swap_used_mb=$swap_mb free_pct=${free_pct:-unknown} uptime_days=$uptime_days disk_free_gb=${disk_free_gb:-unknown}"
  log "mini-memory-guard complete"
}

main "$@"
