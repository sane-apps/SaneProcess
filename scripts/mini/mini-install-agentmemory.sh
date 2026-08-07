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
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
SUDO="${SANE_SUDO_BIN:-/usr/bin/sudo}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
RUBY="${SANE_RUBY_BIN:-/usr/bin/ruby}"
PLUTIL="${SANE_PLUTIL_BIN:-/usr/bin/plutil}"
HEALTH_ATTEMPTS="${SANE_AGENTMEMORY_INSTALL_HEALTH_ATTEMPTS:-15}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_INSTALL_HEALTH_INTERVAL:-2}"
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
[[ -x "$CURL" ]] || { echo "Missing curl: $CURL" >&2; exit 1; }
[[ -x "$RUBY" ]] || { echo "Missing Ruby JSON parser: $RUBY" >&2; exit 1; }
[[ -x "$PLUTIL" ]] || { echo "Missing plist validator: $PLUTIL" >&2; exit 1; }
[[ "$HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid health attempt count: $HEALTH_ATTEMPTS" >&2; exit 2; }
[[ "$HEALTH_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid health interval: $HEALTH_INTERVAL" >&2; exit 2; }

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
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agentmemory.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agentmemory.err.log</string>
</dict>
</plist>
PLIST
}

json_health_healthy() {
  "$CURL" --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/health" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["service"] == "agentmemory" && value["status"] == "healthy" ? 0 : 1)'
}

search_canary_healthy() {
  "$CURL" --silent --show-error --fail --max-time 4 \
    -H 'Content-Type: application/json' \
    --data '{"query":"SaneApps","limit":1,"format":"compact"}' \
    "$AGENTMEMORY_URL/agentmemory/search" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["results"].is_a?(Array) && !value["results"].empty? ? 0 : 1)'
}

status_and_corpus_healthy() {
  local status_output count
  status_output="$($AGENTMEMORY status 2>&1 || true)"
  printf '%s\n' "$status_output" | grep -Eq 'Health:[[:space:]].*healthy' || return 1
  count="$(printf '%s\n' "$status_output" | sed -nE 's/.*Memories:[[:space:]]*([0-9][0-9,]*).*/\1/p' | head -1 | tr -d ',')"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]
}

runtime_healthy() {
  launchd_service_healthy &&
    "$CURL" --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/livez" >/dev/null &&
    json_health_healthy &&
    status_and_corpus_healthy &&
    search_canary_healthy
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
  render_plist | "$PLUTIL" -lint - >/dev/null
  echo "Validated AgentMemory LaunchAgent: $PLIST"
  exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$(dirname "$SUPERVISOR")"
uid="$(id -u)"
domain="gui/$uid/$LABEL"
plist_temp="$(mktemp "${PLIST}.new.XXXXXX")"
supervisor_temp="$(mktemp "${SUPERVISOR}.new.XXXXXX")"
plist_backup="$(mktemp "${PLIST}.backup.XXXXXX")"
supervisor_backup="$(mktemp "${SUPERVISOR}.backup.XXXXXX")"
had_plist=0
had_supervisor=0
previous_loaded=0
mutation_started=0
committed=0

cleanup_transaction_files() {
  [[ -z "${plist_temp:-}" ]] || rm -f "$plist_temp"
  [[ -z "${supervisor_temp:-}" ]] || rm -f "$supervisor_temp"
  [[ -z "${plist_backup:-}" ]] || rm -f "$plist_backup"
  [[ -z "${supervisor_backup:-}" ]] || rm -f "$supervisor_backup"
}

restore_file() {
  local target backup had_file restore_temp
  target="$1"
  backup="$2"
  had_file="$3"
  if [[ "$had_file" -eq 1 ]]; then
    restore_temp="$(mktemp "${target}.rollback.XXXXXX")"
    cp -p "$backup" "$restore_temp"
    mv -f "$restore_temp" "$target"
  else
    rm -f "$target"
  fi
}

rollback_install() {
  local original_status
  original_status="$1"
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$mutation_started" -eq 1 && "$committed" -eq 0 ]]; then
    echo "AgentMemory install failed; restoring the previous supervised service" >&2
    "$LAUNCHCTL" bootout "$domain" >/dev/null 2>&1 || \
      "$SUDO" -n "$LAUNCHCTL" bootout "$domain" >/dev/null 2>&1 || true
    "$AGENTMEMORY" stop --force >/dev/null 2>&1 || true
    restore_file "$PLIST" "$plist_backup" "$had_plist"
    restore_file "$SUPERVISOR" "$supervisor_backup" "$had_supervisor"
    if [[ "$previous_loaded" -eq 1 && "$had_plist" -eq 1 ]]; then
      if ! "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" >/dev/null 2>&1; then
        "$SUDO" -n "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" >/dev/null 2>&1 || \
          echo "WARNING: previous AgentMemory service could not be re-bootstrapped" >&2
      fi
    fi
  fi
  cleanup_transaction_files
  exit "$original_status"
}

trap 'status=$?; rollback_install "$status"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

install -m 755 "$SUPERVISOR_SOURCE" "$supervisor_temp"
/bin/bash -n "$supervisor_temp"
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
if "$LAUNCHCTL" print "$domain" >/dev/null 2>&1; then
  previous_loaded=1
fi

mutation_started=1
if [[ "$previous_loaded" -eq 1 ]]; then
  if ! "$LAUNCHCTL" bootout "$domain" 2>/dev/null; then
    "$SUDO" -n "$LAUNCHCTL" bootout "$domain" 2>/dev/null
  fi
else
  "$LAUNCHCTL" bootout "$domain" 2>/dev/null || \
    "$SUDO" -n "$LAUNCHCTL" bootout "$domain" 2>/dev/null || true
fi
mv -f "$supervisor_temp" "$SUPERVISOR"
supervisor_temp=""
mv -f "$plist_temp" "$PLIST"
plist_temp=""
"$AGENTMEMORY" stop --force >/dev/null 2>&1 || true
if ! bootstrap_error="$("$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" 2>&1)"; then
  if "$SUDO" -n "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST"; then
    echo "Loaded $LABEL through the noninteractive admin fallback."
  else
    printf '%s\n' "$bootstrap_error" >&2
    echo "Could not load $LABEL from this session. Run this installer once in the logged-in Mini Terminal." >&2
    exit 1
  fi
fi
"$LAUNCHCTL" enable "gui/$uid/$LABEL" 2>/dev/null || \
  "$SUDO" -n "$LAUNCHCTL" enable "gui/$uid/$LABEL" 2>/dev/null || true
echo "Installed $LABEL; waiting for AgentMemory health"
attempt=1
while [ "$attempt" -le "$HEALTH_ATTEMPTS" ]; do
  if runtime_healthy; then
    committed=1
    echo "Started healthy $LABEL (livez, health, corpus, and search verified)"
    exit 0
  fi
  sleep "$HEALTH_INTERVAL"
  attempt=$((attempt + 1))
done

status_output="$($AGENTMEMORY status 2>&1 || true)"
printf '%s\n' "$status_output" >&2
echo "AgentMemory did not pass launchd ownership/path/state plus livez, health, corpus, and search" >&2
exit 1
