#!/bin/bash
set -uo pipefail

# AgentMemory's Node wrapper can remain alive after its iii engine disappears.
# Convert sustained health loss into a non-zero exit that launchd can restart.
# Also reclaim orphan listeners on :3111 (hung `iii`) so the next start can bind.

AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_HEALTH_INTERVAL:-30}"
HEALTH_MISSES="${SANE_AGENTMEMORY_HEALTH_MISSES:-2}"
STARTUP_ATTEMPTS="${SANE_AGENTMEMORY_STARTUP_ATTEMPTS:-30}"
STARTUP_INTERVAL="${SANE_AGENTMEMORY_STARTUP_INTERVAL:-2}"
PORT="${SANE_AGENTMEMORY_PORT:-3111}"
LIVEZ_URL="${SANE_AGENTMEMORY_LIVEZ_URL:-http://127.0.0.1:${PORT}/agentmemory/livez}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
LSOF="${SANE_LSOF_BIN:-/usr/sbin/lsof}"
KILL="${SANE_KILL_BIN:-/bin/kill}"
CHILD_PID=""

livez_ok() {
  "$CURL" --silent --fail --max-time 2 "$LIVEZ_URL" >/dev/null 2>&1
}

# Kill anything listening on the AgentMemory port except our supervised child.
# Never match by process name over SSH — reclaim by exact lsof PIDs only.
reclaim_orphaned_listeners() {
  local pids pid
  pids="$("$LSOF" -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -z "$pids" ]] && return 0
  for pid in $pids; do
    [[ -n "$CHILD_PID" && "$pid" == "$CHILD_PID" ]] && continue
    echo "Reclaiming orphan listener pid=$pid on :$PORT" >&2
    "$KILL" -TERM "$pid" 2>/dev/null || true
  done
  /bin/sleep 0.5
  pids="$("$LSOF" -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  for pid in $pids; do
    [[ -n "$CHILD_PID" && "$pid" == "$CHILD_PID" ]] && continue
    echo "Force reclaiming orphan listener pid=$pid on :$PORT" >&2
    "$KILL" -KILL "$pid" 2>/dev/null || true
  done
}

healthy() {
  # Port listen / CLI "Connected" alone is a false green (hung iii, 2026-09-03).
  # livez HTTP 200 is required. CLI status remains a secondary signal.
  if ! livez_ok; then
    return 1
  fi
  local out
  out="$("$AGENTMEMORY" status 2>&1 || true)"
  printf '%s\n' "$out" | /usr/bin/grep -Eq 'Health:[[:space:]].*healthy' && return 0
  printf '%s\n' "$out" | /usr/bin/grep -q 'Not running' && return 1
  printf '%s\n' "$out" | /usr/bin/grep -q 'Connected' && return 0
  return 1
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
  CHILD_PID=""
  reclaim_orphaned_listeners
}

shutdown_cleanly() {
  stop_child
  exit 0
}
trap shutdown_cleanly INT TERM

reclaim_orphaned_listeners
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
CHILD_PID=""
reclaim_orphaned_listeners
echo "AgentMemory wrapper exited unexpectedly; requesting launchd restart" >&2
exit 1
