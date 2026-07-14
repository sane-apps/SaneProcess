#!/bin/bash
# mini-memory-guard.sh - Daily Mac mini hygiene for the always-on server
# Intended to run via LaunchAgent in early-morning hours.
#
# Goals:
# - Keep the mini responsive as a build server.
# - Kill stale dev app binaries from DerivedData.
# - Prune stale routed release workspaces and validation output.
# - Rotate oversized logs.
# - Never shut down or restart the Mini automatically.
# - Bound deep cleanup so morning availability is predictable.
set -euo pipefail
DRY_RUN=0
COMPILER_SERVICES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --compiler-services-only) COMPILER_SERVICES_ONLY=1 ;;
    *)
      echo "Usage: $0 [--dry-run] [--compiler-services-only]" >&2
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
path_size_mb() {
  local mb
  mb="$(du -sm "$1" 2>/dev/null | awk '{print $1}')" || mb=0
  echo "${mb:-0}"
}

is_server_work_active() {
  pgrep -f "mini-nightly.sh" >/dev/null 2>&1 || \
    pgrep -f "xcodebuild .*Sane" >/dev/null 2>&1 || \
    pgrep -f "swift (build|test)" >/dev/null 2>&1 || \
    pgrep -f "SaneMaster.*(verify|launch|release|test_mode)" >/dev/null 2>&1 || \
    pgrep -f '/DerivedData/.*/Sane[^ ]*\.app/Contents/MacOS/Sane' >/dev/null 2>&1
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
    "$HOME/.codex-sync-backups/"*)
      ;;
    *)
      log "Refusing delete outside safe roots: $path"
      return 1
      ;;
  esac

  local component="$path"
  while [ "$component" != "$HOME" ] && [ "$component" != "/" ]; do
    if [ -L "$component" ]; then
      log "Refusing cleanup through symlinked path component: $component"
      return 1
    fi
    component="$(dirname "$component")"
  done

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN: would remove $path"
    return 0
  fi

  /usr/bin/trash "$path"
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
    dir_mb=$(path_size_mb "$dir")
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

cleanup_orphaned_compiler_services() {
  local service_name pids pid ppid rss_kb killed_count failed_count found_count large_count reboot_marker threshold_kb

  if is_server_work_active; then
    log "Compiler service cleanup skipped because a build is active."
    return 0
  fi

  reboot_marker="$OUTPUT_DIR/.compiler_service_reboot_required"
  threshold_kb="${COMPILER_SERVICE_REBOOT_RSS_KB:-262144}"
  killed_count=0
  failed_count=0
  found_count=0
  large_count=0
  for service_name in ANECompilerService MTLCompilerService; do
    pids=$(pgrep -x "$service_name" 2>/dev/null || true)
    for pid in $pids; do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$ppid" = "1" ] || continue

      found_count=$((found_count + 1))
      rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}')
      case "$rss_kb" in
        ''|*[!0-9]*)
          rss_kb=0
          ;;
      esac
      if [ "$rss_kb" -lt "$threshold_kb" ]; then
        log "Leaving normal-sized $service_name pid=$pid rss_kb=$rss_kb below threshold_kb=$threshold_kb"
        continue
      fi
      large_count=$((large_count + 1))
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY RUN: would reap orphaned $service_name pid=$pid rss_kb=${rss_kb:-unknown}"
      else
        log "Reaping orphaned $service_name pid=$pid rss_kb=${rss_kb:-unknown}"
        if kill -TERM "$pid" 2>/dev/null; then
          killed_count=$((killed_count + 1))
        else
          log "Unable to reap root-owned $service_name pid=$pid; marking Mini restart required."
          failed_count=$((failed_count + 1))
        fi
      fi
    done
  done

  if [ "$found_count" -eq 0 ] || [ "$large_count" -eq 0 ]; then
    rm -f "$reboot_marker" 2>/dev/null || true
    return 0
  fi
  if [ "$failed_count" -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') compiler services require Mini restart" > "$reboot_marker" 2>/dev/null || true
  fi

  [ "$killed_count" -gt 0 ] || return 0
  [ "$DRY_RUN" -eq 1 ] && return 0
  sleep 1

  for service_name in ANECompilerService MTLCompilerService; do
    pids=$(pgrep -x "$service_name" 2>/dev/null || true)
    for pid in $pids; do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$ppid" = "1" ] || continue
      if ! kill -KILL "$pid" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') compiler services require Mini restart" > "$reboot_marker" 2>/dev/null || true
      fi
    done
  done

  if command -v purge > /dev/null 2>&1; then
    purge 2>/dev/null || true
  fi
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
  devices_mb=$(path_size_mb "$devices_root")
  [ -n "$devices_mb" ] || devices_mb=0

  local max_mb=$((max_gb * 1024))
  if [ "$devices_mb" -le "$max_mb" ]; then
    log "CoreSimulator devices within limit (${devices_mb}MB <= ${max_mb}MB)"
    return 0
  fi

  if is_server_work_active; then
    log "CoreSimulator devices are large (${devices_mb}MB) but a build is active; skipping cleanup."
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
  [ -d "$trash_root" ] || return 0

  local trash_mb
  trash_mb=$(path_size_mb "$trash_root")
  [ -n "$trash_mb" ] || trash_mb=0
  log "Trash preserved (${trash_mb}MB); automatic server hygiene never permanently deletes user Trash."
}

cleanup_large_deriveddata() {
  local dd_root="$HOME/Library/Developer/Xcode/DerivedData"
  local max_gb="${DERIVEDDATA_MAX_GB:-5}"
  [ -d "$dd_root" ] || return 0

  local dd_mb
  dd_mb=$(path_size_mb "$dd_root")
  [ -n "$dd_mb" ] || dd_mb=0

  local max_mb=$((max_gb * 1024))
  if [ "$dd_mb" -le "$max_mb" ]; then
    log "DerivedData within limit (${dd_mb}MB <= ${max_mb}MB)"
    return 0
  fi

  if is_server_work_active; then
    log "DerivedData is large (${dd_mb}MB) but a build is active; skipping cleanup."
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

run_sanemaster_server_cleanup() {
  local sanemaster="$HOME/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb"
  local timeout_seconds="${MACHINE_CLEANUP_TIMEOUT_SECONDS:-1200}"
  [ -f "$sanemaster" ] || {
    log "SaneMaster server cleanup skipped; missing $sanemaster"
    return 0
  }

  if is_server_work_active; then
    log "SaneMaster server cleanup skipped because a build is active."
    return 0
  fi

  log "Running bounded SaneMaster machine_cleanup --server (timeout=${timeout_seconds}s)"
  local command=(ruby "$sanemaster" machine_cleanup --host local --server --json)
  if [ "$DRY_RUN" -eq 0 ]; then
    command=(ruby "$sanemaster" machine_cleanup --host local --server --apply --quiet --json)
  fi

  set +e
  ruby -ropen3 -e '
    timeout = Integer(ARGV.shift)
    command = ARGV
    status = nil
    Open3.popen2e(*command, pgroup: true) do |stdin, output, wait_thr|
      stdin.close
      reader = Thread.new { IO.copy_stream(output, STDOUT) }
      unless wait_thr.join(timeout)
        Process.kill("TERM", -wait_thr.pid) rescue nil
        wait_thr.join(5)
        # Kill the group even if only its leader honored TERM.
        Process.kill("KILL", -wait_thr.pid) rescue nil
        wait_thr.join(5)
        reader.join(2)
        exit 124
      end
      reader.join
      status = wait_thr.value
    end
    exit(status&.exitstatus || 1)
  ' "$timeout_seconds" "${command[@]}" >> "$LOG_FILE" 2>&1
  local cleanup_status=$?
  set -e

  if [ "$cleanup_status" -eq 124 ]; then
    log "SaneMaster server cleanup timed out after ${timeout_seconds}s; remaining hygiene will continue"
    return 0
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    log "SaneMaster server cleanup failed (status=$cleanup_status); remaining hygiene will continue"
    return 0
  fi

  log "SaneMaster server cleanup complete"
}

main() {
  local load1 swap_mb free_pct uptime_days disk_free_gb
  load1="$(get_load1)"
  swap_mb="$(get_swap_used_mb)"
  free_pct="$(get_free_pct)"
  uptime_days="$(get_uptime_days)"
  disk_free_gb="$(get_data_disk_free_gb)"

  log "mini-memory-guard start (dry_run=$DRY_RUN auto_restart=disabled)"
  log "Health before: load1=$load1 swap_used_mb=$swap_mb free_pct=${free_pct:-unknown} uptime_days=$uptime_days disk_free_gb=${disk_free_gb:-unknown}"

  if [ "$COMPILER_SERVICES_ONLY" -eq 1 ]; then
    cleanup_orphaned_compiler_services
    load1="$(get_load1)"
    swap_mb="$(get_swap_used_mb)"
    free_pct="$(get_free_pct)"
    disk_free_gb="$(get_data_disk_free_gb)"
    log "Health after compiler-service cleanup: load1=$load1 swap_used_mb=$swap_mb free_pct=${free_pct:-unknown} disk_free_gb=${disk_free_gb:-unknown}"
    log "mini-memory-guard complete"
    return 0
  fi

  rotate_if_large "$OUTPUT_DIR/nightly.stdout.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/nightly.stderr.log" 10485760 2097152
  rotate_if_large "$OUTPUT_DIR/memory-guard.stdout.log" 5242880 1048576
  rotate_if_large "$OUTPUT_DIR/memory-guard.stderr.log" 2097152 524288
  rotate_if_large "$OUTPUT_DIR/mini_memory_guard.log" 5242880 1048576

  cleanup_orphaned_compiler_services
  cleanup_routed_workspaces
  cleanup_sanevideo_outputs
  cleanup_codex_sync_backups
  cleanup_stale_automation_git_locks
  cleanup_setapp_review_outputs
  cleanup_tmp_workspaces
  run_sanemaster_server_cleanup
  cleanup_trash
  cleanup_coresimulator_devices
  cleanup_large_deriveddata
  load1="$(get_load1)"
  swap_mb="$(get_swap_used_mb)"
  free_pct="$(get_free_pct)"
  uptime_days="$(get_uptime_days)"
  disk_free_gb="$(get_data_disk_free_gb)"
  log "Health after: load1=$load1 swap_used_mb=$swap_mb free_pct=${free_pct:-unknown} uptime_days=$uptime_days disk_free_gb=${disk_free_gb:-unknown}"
  log "mini-memory-guard complete"
}

main "$@"
