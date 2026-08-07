#!/bin/bash
set -uo pipefail

# AgentMemory's Node wrapper can remain alive after its iii engine disappears.
# Convert sustained health loss into a non-zero exit that launchd can restart.

AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
LIVEZ_URL="${SANE_AGENTMEMORY_LIVEZ_URL:-http://127.0.0.1:3111/agentmemory/livez}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_HEALTH_INTERVAL:-30}"
HEALTH_MISSES="${SANE_AGENTMEMORY_HEALTH_MISSES:-2}"
STARTUP_ATTEMPTS="${SANE_AGENTMEMORY_STARTUP_ATTEMPTS:-15}"
STARTUP_INTERVAL="${SANE_AGENTMEMORY_STARTUP_INTERVAL:-2}"
CHILD_PID=""

healthy() {
  "$CURL" -fsS --max-time 3 "$LIVEZ_URL" >/dev/null 2>&1
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
