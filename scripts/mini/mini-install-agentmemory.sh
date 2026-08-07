#!/usr/bin/env bash
set -euo pipefail

# Installs the shared AgentMemory worker as a restart-durable user LaunchAgent.
# The store remains loopback-only on port 3111; the Air reaches it through SSH.

LABEL="com.saneapps.agentmemory"
PLIST="${SANE_AGENTMEMORY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="${SANE_AGENTMEMORY_LOG_DIR:-$HOME/Library/Logs/SaneApps}"
AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
AGENTMEMORY_URL="${SANE_AGENTMEMORY_URL:-http://127.0.0.1:3111}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_SOURCE="${SANE_AGENTMEMORY_SUPERVISOR_SOURCE:-$SCRIPT_DIR/mini-agentmemory-supervisor.sh}"
SUPERVISOR="${SANE_AGENTMEMORY_SUPERVISOR:-$HOME/.local/libexec/sane-agentmemory-supervisor}"
HEALTH_LIB_SOURCE="${SANE_AGENTMEMORY_HEALTH_LIB_SOURCE:-$SCRIPT_DIR/mini-agentmemory-health.sh}"
HEALTH_LIB="${SANE_AGENTMEMORY_HEALTH_LIB:-$(dirname "$SUPERVISOR")/mini-agentmemory-health.sh}"
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
SUDO="${SANE_SUDO_BIN:-/usr/bin/sudo}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
RUBY="${SANE_RUBY_BIN:-/usr/bin/ruby}"
PLUTIL="${SANE_PLUTIL_BIN:-/usr/bin/plutil}"
LSOF="${SANE_LSOF_BIN:-/usr/sbin/lsof}"
PS="${SANE_PS_BIN:-/bin/ps}"
KILL="${SANE_KILL_BIN:-/bin/kill}"
MKTEMP="${SANE_MKTEMP_BIN:-/usr/bin/mktemp}"
EXPECTED_VERSION="${SANE_AGENTMEMORY_EXPECTED_VERSION:-0.9.28}"
RESTORE_CP="${SANE_AGENTMEMORY_RESTORE_CP_BIN:-/bin/cp}"
RESTORE_MV="${SANE_AGENTMEMORY_RESTORE_MV_BIN:-/bin/mv}"
RESTORE_RM="${SANE_AGENTMEMORY_RESTORE_RM_BIN:-/bin/rm}"
HEALTH_ATTEMPTS="${SANE_AGENTMEMORY_INSTALL_HEALTH_ATTEMPTS:-15}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_INSTALL_HEALTH_INTERVAL:-2}"
CORPUS_MIN="${SANE_AGENTMEMORY_CORPUS_MIN:-1}"
DRY_RUN=0

usage() {
  echo "Usage: $(basename "$0") [--dry-run]" >&2
}

case "$#" in
  0) ;;
  1)
    [[ "$1" == "--dry-run" ]] || { usage; exit 2; }
    DRY_RUN=1
    ;;
  *)
    usage
    exit 2
    ;;
esac

[[ -x "$AGENTMEMORY" ]] || { echo "Missing AgentMemory CLI: $AGENTMEMORY" >&2; exit 1; }
[[ -x "$SUPERVISOR_SOURCE" ]] || { echo "Missing AgentMemory supervisor: $SUPERVISOR_SOURCE" >&2; exit 1; }
[[ -r "$HEALTH_LIB_SOURCE" ]] || { echo "Missing AgentMemory health helper: $HEALTH_LIB_SOURCE" >&2; exit 1; }
[[ -x "$CURL" ]] || { echo "Missing curl: $CURL" >&2; exit 1; }
[[ -x "$RUBY" ]] || { echo "Missing Ruby JSON parser: $RUBY" >&2; exit 1; }
[[ -x "$PLUTIL" ]] || { echo "Missing plist validator: $PLUTIL" >&2; exit 1; }
[[ -x "$LSOF" ]] || { echo "Missing listener inspector: $LSOF" >&2; exit 1; }
[[ -x "$PS" ]] || { echo "Missing process inspector: $PS" >&2; exit 1; }
[[ -x "$KILL" ]] || { echo "Missing process signal tool: $KILL" >&2; exit 1; }
[[ -x "$MKTEMP" ]] || { echo "Missing secure temporary-file tool: $MKTEMP" >&2; exit 1; }
[[ -x "$RESTORE_CP" ]] || { echo "Missing rollback copy tool: $RESTORE_CP" >&2; exit 1; }
[[ -x "$RESTORE_MV" ]] || { echo "Missing rollback move tool: $RESTORE_MV" >&2; exit 1; }
[[ -x "$RESTORE_RM" ]] || { echo "Missing rollback removal tool: $RESTORE_RM" >&2; exit 1; }
[[ "$HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health attempt count: $HEALTH_ATTEMPTS" >&2; exit 2; }
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid health interval: $HEALTH_INTERVAL" >&2; exit 2; }
[[ "$CORPUS_MIN" =~ ^[0-9]+$ ]] || { echo "Invalid AgentMemory corpus minimum: $CORPUS_MIN" >&2; exit 2; }
version_output="$($AGENTMEMORY --version 2>&1)" || { echo "Could not read AgentMemory version" >&2; exit 1; }
[[ "$version_output" == "$EXPECTED_VERSION" || "$version_output" == "v$EXPECTED_VERSION" ]] || {
  echo "AgentMemory version mismatch: expected $EXPECTED_VERSION" >&2
  exit 1
}
source "$HEALTH_LIB_SOURCE"

render_plist() {
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SUPERVISOR</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SANE_AGENTMEMORY_BIN</key>
    <string>$AGENTMEMORY</string>
    <key>SANE_AGENTMEMORY_LOG_DIR</key>
    <string>$LOG_DIR</string>
    <key>SANE_AGENTMEMORY_CORPUS_MIN</key>
    <string>$CORPUS_MIN</string>
    <key>SANE_AGENTMEMORY_HEALTH_LIB</key>
    <string>$HEALTH_LIB</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agentmemory.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agentmemory.err.log</string>
</dict>
</plist>
PLIST
}

runtime_healthy() {
  launchd_service_healthy && healthy
}

launchd_service_healthy() {
  local service_output domain
  domain="gui/$uid/$LABEL"
  service_output="$("$LAUNCHCTL" print "$domain" 2>/dev/null)" || return 1
  printf '%s\n' "$service_output" | grep -Fq "$domain = {" || return 1
  printf '%s\n' "$service_output" | grep -Fq "path = $PLIST" || return 1
  printf '%s\n' "$service_output" | grep -Fq "state = running" || return 1
  printf '%s\n' "$service_output" | grep -Fq "program = $SUPERVISOR" || return 1
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  /bin/bash -n "$SUPERVISOR_SOURCE"
  /bin/bash -n "$HEALTH_LIB_SOURCE"
  render_plist | "$PLUTIL" -lint - >/dev/null
  echo "Validated AgentMemory LaunchAgent: $PLIST"
  exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$(dirname "$SUPERVISOR")" "$(dirname "$HEALTH_LIB")"
uid="$(id -u)"
domain="gui/$uid/$LABEL"
plist_temp="$(mktemp "${PLIST}.new.XXXXXX")"
supervisor_temp="$(mktemp "${SUPERVISOR}.new.XXXXXX")"
health_lib_temp="$(mktemp "${HEALTH_LIB}.new.XXXXXX")"
plist_backup="$(mktemp "${PLIST}.backup.XXXXXX")"
supervisor_backup="$(mktemp "${SUPERVISOR}.backup.XXXXXX")"
health_lib_backup="$(mktemp "${HEALTH_LIB}.backup.XXXXXX")"
had_plist=0
had_supervisor=0
had_health_lib=0
previous_loaded=0
previous_enablement_state="unspecified"
disabled_state_captured=0
mutation_started=0
committed=0

cleanup_transaction_files() {
  [[ -z "${plist_temp:-}" ]] || rm -f "$plist_temp"
  [[ -z "${supervisor_temp:-}" ]] || rm -f "$supervisor_temp"
  [[ -z "${health_lib_temp:-}" ]] || rm -f "$health_lib_temp"
  [[ -z "${plist_backup:-}" ]] || rm -f "$plist_backup"
  [[ -z "${supervisor_backup:-}" ]] || rm -f "$supervisor_backup"
  [[ -z "${health_lib_backup:-}" ]] || rm -f "$health_lib_backup"
}

restore_file() {
  local target backup had_file restore_temp
  target="$1"
  backup="$2"
  had_file="$3"
  if [[ "$had_file" -eq 1 ]]; then
    restore_temp="$(mktemp "${target}.rollback.XXXXXX")" || return 1
    if ! "$RESTORE_CP" -p "$backup" "$restore_temp"; then
      "$RESTORE_RM" -f "$restore_temp" >/dev/null 2>&1 || true
      return 1
    fi
    if ! "$RESTORE_MV" -f "$restore_temp" "$target"; then
      "$RESTORE_RM" -f "$restore_temp" >/dev/null 2>&1 || true
      return 1
    fi
  else
    "$RESTORE_RM" -f "$target" || return 1
  fi
  return 0
}

launchctl_mutation() {
  local action target
  action="$1"
  target="$2"
  "$LAUNCHCTL" "$action" "$target" 2>/dev/null || \
    "$SUDO" -n "$LAUNCHCTL" "$action" "$target" 2>/dev/null
}

launchctl_reports_domain_absent() {
  local output line found
  output="$1"
  found=0
  while IFS= read -r line; do
    case "$line" in
      ""|"Bad request.") ;;
      "Could not find service"|"Could not find service \"$LABEL\" in domain for user gui: $uid"|"Boot-out failed: 3: No such process") found=1 ;;
      *) return 1 ;;
    esac
  done <<OUTPUT
$output
OUTPUT
  [[ "$found" -eq 1 ]]
}

rollback_bootout() {
  local output fallback_output status
  output="$($LAUNCHCTL bootout "$domain" 2>&1)"
  status=$?
  [[ "$status" -ne 0 ]] || return 0
  launchctl_reports_domain_absent "$output" && return 0
  fallback_output="$($SUDO -n "$LAUNCHCTL" bootout "$domain" 2>&1)"
  status=$?
  [[ "$status" -ne 0 ]] || return 0
  launchctl_reports_domain_absent "$fallback_output" && return 0
  printf '%s\n' "${fallback_output:-$output}" >&2
  return 1
}

capture_disabled_state() {
  local disabled_output label_state
  if ! disabled_output="$("$LAUNCHCTL" print-disabled "gui/$uid" 2>/dev/null)"; then
    if ! disabled_output="$("$SUDO" -n "$LAUNCHCTL" print-disabled "gui/$uid" 2>/dev/null)"; then
      echo "Could not determine the persisted launchd enablement state for $LABEL" >&2
      return 1
    fi
  fi

  # macOS versions have emitted both word and boolean forms. Require one exact
  # three-token entry; duplicates and unfamiliar formats remain fail-closed.
  label_state="$(printf '%s\n' "$disabled_output" | awk -v label="\"$LABEL\"" '
    index($0, label) {
      if ($1 != label || $2 != "=>" || NF != 3) print "__INVALID__"
      else print $3
    }
  ')"
  case "$label_state" in
    disabled|true) previous_enablement_state="disabled" ;;
    enabled|false) previous_enablement_state="enabled" ;;
    '') previous_enablement_state="unspecified" ;;
    *)
      echo "Could not parse the persisted launchd enablement state for $LABEL" >&2
      return 1
      ;;
  esac
  disabled_state_captured=1
}

restore_disabled_state() {
  [[ "$disabled_state_captured" -eq 1 ]] || return 1
  case "$previous_enablement_state" in
    disabled) launchctl_mutation disable "$domain" ;;
    enabled) launchctl_mutation enable "$domain" ;;
    unspecified) return 0 ;;
    *) return 1 ;;
  esac
}

rollback_install() {
  local original_status rollback_failed cleanup_safe files_restored candidate_unloaded
  original_status="$1"
  rollback_failed=0
  cleanup_safe=1
  files_restored=1
  candidate_unloaded=1
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$mutation_started" -eq 1 && "$committed" -eq 0 ]]; then
    echo "AgentMemory install failed; restoring the previous supervised service" >&2
    if ! rollback_bootout; then
      echo "ERROR: candidate AgentMemory launchd job could not be unloaded during rollback" >&2
      rollback_failed=1
      cleanup_safe=0
      candidate_unloaded=0
    fi
    if ! "$SUPERVISOR_SOURCE" --cleanup >/dev/null 2>&1; then
      echo "ERROR: candidate AgentMemory cleanup could not prove canonical ports safe during rollback" >&2
      rollback_failed=1
      cleanup_safe=0
    fi
    if ! restore_file "$PLIST" "$plist_backup" "$had_plist"; then
      echo "ERROR: previous AgentMemory plist could not be restored" >&2
      rollback_failed=1
      files_restored=0
    fi
    if ! restore_file "$SUPERVISOR" "$supervisor_backup" "$had_supervisor"; then
      echo "ERROR: previous AgentMemory supervisor could not be restored" >&2
      rollback_failed=1
      files_restored=0
    fi
    if ! restore_file "$HEALTH_LIB" "$health_lib_backup" "$had_health_lib"; then
      echo "ERROR: previous AgentMemory health helper could not be restored" >&2
      rollback_failed=1
      files_restored=0
    fi
    if [[ "$previous_loaded" -eq 1 && "$had_plist" -eq 1 ]]; then
      # A previously loaded-but-disabled service must be enabled temporarily
      # for bootstrap, then returned to its prior persisted disabled state.
      if [[ "$cleanup_safe" -ne 1 || "$candidate_unloaded" -ne 1 || "$files_restored" -ne 1 ]]; then
        echo "ERROR: previous AgentMemory service bootstrap skipped because rollback safety is unproven" >&2
        rollback_failed=1
      elif [[ "$previous_enablement_state" == "disabled" ]] && ! launchctl_mutation enable "$domain"; then
        echo "ERROR: previous AgentMemory service could not be enabled for rollback" >&2
        rollback_failed=1
      elif ! "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" >/dev/null 2>&1 && \
           ! "$SUDO" -n "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" >/dev/null 2>&1; then
        echo "ERROR: previous AgentMemory service could not be re-bootstrapped" >&2
        rollback_failed=1
      fi
    fi
    if ! restore_disabled_state; then
      echo "ERROR: previous launchd enablement state could not be restored for $LABEL" >&2
      rollback_failed=1
    fi
    if [[ "$rollback_failed" -eq 1 ]]; then
      echo "AgentMemory rollback failed closed; manual repair is required" >&2
    fi
  fi
  cleanup_transaction_files
  exit "$original_status"
}

trap 'status=$?; rollback_install "$status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

install -m 755 "$SUPERVISOR_SOURCE" "$supervisor_temp"
install -m 600 "$HEALTH_LIB_SOURCE" "$health_lib_temp"
/bin/bash -n "$supervisor_temp"
/bin/bash -n "$health_lib_temp"
render_plist > "$plist_temp"
chmod 600 "$plist_temp"
"$PLUTIL" -lint "$plist_temp" >/dev/null

if [[ -e "$PLIST" ]]; then
  cp -p "$PLIST" "$plist_backup"
  had_plist=1
fi
if [[ -e "$SUPERVISOR" ]]; then
  cp -p "$SUPERVISOR" "$supervisor_backup"
  had_supervisor=1
fi
if [[ -e "$HEALTH_LIB" ]]; then
  cp -p "$HEALTH_LIB" "$health_lib_backup"
  had_health_lib=1
fi
if launchctl_print_output="$($LAUNCHCTL print "$domain" 2>&1)"; then
  launchctl_print_status=0
else
  launchctl_print_status=$?
fi
if [[ "$launchctl_print_status" -eq 0 ]]; then
  previous_loaded=1
elif launchctl_reports_domain_absent "$launchctl_print_output"; then
  previous_loaded=0
else
  echo "Could not determine whether $LABEL is loaded: ${launchctl_print_output:-launchctl print failed}" >&2
  exit 1
fi
capture_disabled_state

mutation_started=1
if [[ "$previous_loaded" -eq 1 ]]; then
  if ! "$LAUNCHCTL" bootout "$domain" 2>/dev/null; then
    "$SUDO" -n "$LAUNCHCTL" bootout "$domain" 2>/dev/null
  fi
else
  "$LAUNCHCTL" bootout "$domain" 2>/dev/null || \
    "$SUDO" -n "$LAUNCHCTL" bootout "$domain" 2>/dev/null || true
fi
if ! "$SUPERVISOR_SOURCE" --cleanup; then
  echo "AgentMemory install stopped: canonical ports are not safely owned and free" >&2
  exit 1
fi
mv -f "$supervisor_temp" "$SUPERVISOR"
supervisor_temp=""
mv -f "$health_lib_temp" "$HEALTH_LIB"
health_lib_temp=""
mv -f "$plist_temp" "$PLIST"
plist_temp=""
if [[ "$previous_enablement_state" == "disabled" ]]; then
  if ! launchctl_mutation enable "$domain"; then
    echo "Could not enable $LABEL before launchd bootstrap" >&2
    exit 1
  fi
  echo "Enabled previously disabled $LABEL before launchd bootstrap"
fi
if ! bootstrap_error="$("$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" 2>&1)"; then
  if "$SUDO" -n "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST"; then
    echo "Loaded $LABEL through the noninteractive admin fallback."
  else
    printf '%s\n' "$bootstrap_error" >&2
    echo "Could not load $LABEL from this session. Run this installer once in the logged-in Mini Terminal." >&2
    exit 1
  fi
fi
echo "Installed $LABEL; waiting for AgentMemory health"
attempt=1
while [ "$attempt" -le "$HEALTH_ATTEMPTS" ]; do
  if runtime_healthy; then
    committed=1
    echo "Started healthy $LABEL (livez, health, corpus, and search route verified)"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  attempt=$((attempt + 1))
done

status_output="$($AGENTMEMORY status 2>&1 || true)"
printf '%s\n' "$status_output" >&2
echo "AgentMemory did not pass launchd ownership/path/state plus livez, health, corpus, and search" >&2
exit 1
