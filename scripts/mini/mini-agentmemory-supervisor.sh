#!/bin/bash
set -uo pipefail

# AgentMemory's Node wrapper can remain alive after its iii engine disappears.
# Convert sustained health loss into a non-zero exit that launchd can restart.

AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
AGENTMEMORY_URL="${SANE_AGENTMEMORY_URL:-http://127.0.0.1:3111}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
RUBY="${SANE_RUBY_BIN:-/usr/bin/ruby}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_HEALTH_INTERVAL:-30}"
HEALTH_MISSES="${SANE_AGENTMEMORY_HEALTH_MISSES:-2}"
STARTUP_ATTEMPTS="${SANE_AGENTMEMORY_STARTUP_ATTEMPTS:-15}"
STARTUP_INTERVAL="${SANE_AGENTMEMORY_STARTUP_INTERVAL:-2}"
CHILD_PID=""

healthy() {
  local status_output count
  "$CURL" --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/livez" >/dev/null || return 1
  "$CURL" --silent --show-error --fail --max-time 2 \
    "$AGENTMEMORY_URL/agentmemory/health" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["service"] == "agentmemory" && value["status"] == "healthy" ? 0 : 1)' || return 1
  status_output="$($AGENTMEMORY status 2>&1 || true)"
  printf '%s\n' "$status_output" | /usr/bin/grep -Eq 'Health:[[:space:]].*healthy' || return 1
  count="$(printf '%s\n' "$status_output" | /usr/bin/sed -nE 's/.*Memories:[[:space:]]*([0-9][0-9,]*).*/\1/p' | /usr/bin/head -1 | /usr/bin/tr -d ',')"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || return 1
  "$CURL" --silent --show-error --fail --max-time 4 \
    -H 'Content-Type: application/json' \
    --data '{"query":"SaneApps","limit":1,"format":"compact"}' \
    "$AGENTMEMORY_URL/agentmemory/search" | \
    "$RUBY" -rjson -e 'value = JSON.parse(STDIN.read); exit(value.is_a?(Hash) && value["results"].is_a?(Array) && !value["results"].empty? ? 0 : 1)'
}

stop_child() {
  "$AGENTMEMORY" stop --force >/dev/null 2>&1 || true
  if [[ -n "$CHILD_PID" ]] && /bin/kill -0 "$CHILD_PID" 2>/dev/null; then
    /bin/kill -TERM "$CHILD_PID" 2>/dev/null || true
    attempt=1
    while [[ "$attempt" -le 10 ]] && /bin/kill -0 "$CHILD_PID" 2>/dev/null; do
      /bin/sleep 0.2
      attempt=$((attempt + 1))
    done
    /bin/kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  [[ -z "$CHILD_PID" ]] || wait "$CHILD_PID" 2>/dev/null || true
}

shutdown_cleanly() {
  stop_child
  exit 0
}
trap shutdown_cleanly INT TERM

"$AGENTMEMORY" &
CHILD_PID=$!

attempt=1
while [[ "$attempt" -le "$STARTUP_ATTEMPTS" ]]; do
  if ! /bin/kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "AgentMemory wrapper exited during startup" >&2
    stop_child
    exit 1
  fi
  healthy && break
  /bin/sleep "$STARTUP_INTERVAL"
  attempt=$((attempt + 1))
done

if ! healthy; then
  echo "AgentMemory failed its startup health deadline" >&2
  stop_child
  exit 1
fi

misses=0
while /bin/kill -0 "$CHILD_PID" 2>/dev/null; do
  /bin/sleep "$HEALTH_INTERVAL"
  if healthy; then
    misses=0
    continue
  fi
  misses=$((misses + 1))
  echo "AgentMemory health miss $misses/$HEALTH_MISSES" >&2
  if [[ "$misses" -ge "$HEALTH_MISSES" ]]; then
    echo "AgentMemory engine unhealthy; exiting for launchd restart" >&2
    stop_child
    exit 1
  fi
done

wait "$CHILD_PID" 2>/dev/null || true
echo "AgentMemory wrapper exited unexpectedly; requesting launchd restart" >&2
exit 1
