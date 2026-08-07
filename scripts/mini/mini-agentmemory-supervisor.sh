#!/bin/bash
set -uo pipefail

# AgentMemory's Node wrapper can remain alive after its iii engine disappears.
# Convert sustained health loss into a non-zero exit that launchd can restart.

AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
AGENTMEMORY_URL="${SANE_AGENTMEMORY_URL:-http://127.0.0.1:3111}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_LIB="${SANE_AGENTMEMORY_HEALTH_LIB:-$SCRIPT_DIR/mini-agentmemory-health.sh}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
RUBY="${SANE_RUBY_BIN:-/usr/bin/ruby}"
LSOF="${SANE_LSOF_BIN:-/usr/sbin/lsof}"
PS="${SANE_PS_BIN:-/bin/ps}"
KILL="${SANE_KILL_BIN:-/bin/kill}"
MKTEMP="${SANE_MKTEMP_BIN:-/usr/bin/mktemp}"
III_BIN="${SANE_AGENTMEMORY_III_BIN:-$HOME/.agentmemory/bin/iii}"
III_PIDFILE="${SANE_AGENTMEMORY_III_PIDFILE:-$HOME/.agentmemory/iii.pid}"
WORKER_PIDFILE="${SANE_AGENTMEMORY_WORKER_PIDFILE:-$HOME/.agentmemory/worker.pid}"
WORKER_TOKEN="${SANE_AGENTMEMORY_WORKER_TOKEN:-@agentmemory/agentmemory/dist/cli.mjs}"
CANONICAL_PORTS="${SANE_AGENTMEMORY_CANONICAL_PORTS:-3111 3112 3113 49134}"
LOG_DIR="${SANE_AGENTMEMORY_LOG_DIR:-$HOME/Library/Logs/SaneApps}"
LOG_MAX_BYTES="${SANE_AGENTMEMORY_LOG_MAX_BYTES:-10485760}"
LOG_KEEP_BYTES="${SANE_AGENTMEMORY_LOG_KEEP_BYTES:-2097152}"
CORPUS_MIN="${SANE_AGENTMEMORY_CORPUS_MIN:-1}"
HEALTH_INTERVAL="${SANE_AGENTMEMORY_HEALTH_INTERVAL:-30}"
HEALTH_MISSES="${SANE_AGENTMEMORY_HEALTH_MISSES:-2}"
STARTUP_ATTEMPTS="${SANE_AGENTMEMORY_STARTUP_ATTEMPTS:-15}"
STARTUP_INTERVAL="${SANE_AGENTMEMORY_STARTUP_INTERVAL:-2}"
STOP_INTERVAL="${SANE_AGENTMEMORY_STOP_INTERVAL:-0.2}"
WORKER_STOP_ATTEMPTS="${SANE_AGENTMEMORY_WORKER_STOP_ATTEMPTS:-25}"
ENGINE_STOP_ATTEMPTS="${SANE_AGENTMEMORY_ENGINE_STOP_ATTEMPTS:-15}"
KILL_STOP_ATTEMPTS="${SANE_AGENTMEMORY_KILL_STOP_ATTEMPTS:-10}"
CHILD_PID=""
OWNED_WORKERS=""
OWNED_ENGINES=""
OWNERSHIP_BLOCKERS=""
INSPECTION_FAILED=0
PID_STATE_DETAIL=""
usage() {
  echo "Usage: $(basename "$0") [--cleanup]" >&2
}

case "$#" in
  0) MODE="run" ;;
  1)
    [[ "$1" == "--cleanup" ]] || { usage; exit 2; }
    MODE="cleanup"
    ;;
  *) usage; exit 2 ;;
esac
[[ -x "$LSOF" ]] || { echo "Missing listener inspector: $LSOF" >&2; exit 1; }
[[ -x "$PS" ]] || { echo "Missing process inspector: $PS" >&2; exit 1; }
[[ -x "$KILL" ]] || { echo "Missing process signal tool: $KILL" >&2; exit 1; }
[[ -x "$MKTEMP" ]] || { echo "Missing secure temporary-file tool: $MKTEMP" >&2; exit 1; }
[[ -r "$HEALTH_LIB" ]] || { echo "Missing AgentMemory health helper: $HEALTH_LIB" >&2; exit 1; }
[[ "$LOG_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid log size ceiling: $LOG_MAX_BYTES" >&2; exit 2; }
[[ "$LOG_KEEP_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid retained log size: $LOG_KEEP_BYTES" >&2; exit 2; }
[[ "$LOG_KEEP_BYTES" -le "$LOG_MAX_BYTES" ]] || { echo "Retained log size exceeds ceiling" >&2; exit 2; }
[[ "$CORPUS_MIN" =~ ^[0-9]+$ ]] || { echo "Invalid AgentMemory corpus minimum: $CORPUS_MIN" >&2; exit 2; }
[[ "$STOP_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Invalid stop interval: $STOP_INTERVAL" >&2; exit 2; }
[[ "$WORKER_STOP_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$ENGINE_STOP_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$KILL_STOP_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid stop attempt count" >&2; exit 2; }
source "$HEALTH_LIB"
append_unique() {
  local list_name value current
  list_name="$1"
  value="$2"
  eval "current=\${$list_name:-}"
  case " $current " in
    *" $value "*) ;;
    *) eval "$list_name=\"$current $value\"" ;;
  esac
}
numeric_pid() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}
pid_command() {
  "$PS" -p "$1" -o command= 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# Returns 0 when the PID exists, 1 only for a proven ESRCH/absence, and 2 when
# existence cannot be determined. A permission failure must never look dead.
pid_state() {
  local pid command probe status
  pid="$1"
  PID_STATE_DETAIL=""
  numeric_pid "$pid" || { PID_STATE_DETAIL="invalid pid"; return 2; }
  command="$(pid_command "$pid")"
  [[ -z "$command" ]] || return 0
  probe="$("$KILL" -0 "$pid" 2>&1)"
  status=$?
  [[ "$status" -ne 0 ]] || return 0
  case "$probe" in
    *"No such process"*|*"no such process"*) return 1 ;;
    *)
      PID_STATE_DETAIL="${probe:-process existence probe failed}"
      return 2
      ;;
  esac
}
pid_is_engine() {
  local command
  command="$(pid_command "$1")"
  case "$command" in
    "$III_BIN"|"$III_BIN "*) return 0 ;;
    *) return 1 ;;
  esac
}
pid_is_worker() {
  local command
  command="$(pid_command "$1")"
  case "$command" in
    "$AGENTMEMORY"|*" $AGENTMEMORY"|*"$WORKER_TOKEN") return 0 ;;
    *) return 1 ;;
  esac
}

listener_pids() {
  local port output status pid
  port="$1"
  output="$("$LSOF" -nP -tiTCP:"$port" -sTCP:LISTEN 2>&1)"
  status=$?
  if [[ "$status" -ne 0 && "$status" -ne 1 ]]; then
    echo "Listener inspection failed for port $port${output:+: $output}" >&2
    return 2
  fi
  # lsof uses exit 1 with no stderr for a normal no-match result.
  [[ "$status" -eq 0 || ( "$status" -eq 1 && -z "$output" ) ]] || return 2
  for pid in $output; do
    numeric_pid "$pid" || {
      echo "Listener inspection returned an invalid pid for port $port" >&2
      return 2
    }
  done
  printf '%s\n' "$output" | /usr/bin/sed -nE '/^[0-9]+$/p' | /usr/bin/sort -u
}

record_blocker() {
  OWNERSHIP_BLOCKERS="${OWNERSHIP_BLOCKERS}${OWNERSHIP_BLOCKERS:+; }$1"
}

read_pidfile() {
  local contents pid
  [[ -f "$1" ]] || return 1
  contents="$(/bin/cat "$1" 2>/dev/null)" || return 1
  [[ "$contents" =~ ^[[:space:]]*([1-9][0-9]*)[[:space:]]*$ ]] || return 1
  pid="${BASH_REMATCH[1]}"
  numeric_pid "$pid" || return 1
  printf '%s\n' "$pid"
}

classify_runtime() {
  local pid port pids state worker_pidfile_pid engine_pidfile_pid
  OWNED_WORKERS=""
  OWNED_ENGINES=""
  OWNERSHIP_BLOCKERS=""
  INSPECTION_FAILED=0

  if [[ -n "$CHILD_PID" ]]; then
    pid_state "$CHILD_PID"
    state=$?
    if [[ "$state" -eq 0 ]]; then
      if pid_is_worker "$CHILD_PID"; then
        append_unique OWNED_WORKERS "$CHILD_PID"
      else
        record_blocker "supervised child pid $CHILD_PID no longer matches the AgentMemory worker"
      fi
    elif [[ "$state" -eq 2 ]]; then
      INSPECTION_FAILED=1
      record_blocker "could not determine supervised child pid $CHILD_PID state: $PID_STATE_DETAIL"
    fi
  fi

  worker_pidfile_pid=""
  engine_pidfile_pid=""
  pid="$(read_pidfile "$WORKER_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    pid_state "$pid"
    state=$?
    if [[ "$state" -eq 0 ]]; then
      if pid_is_worker "$pid"; then
        worker_pidfile_pid="$pid"
      else
        record_blocker "worker pidfile points to unrelated pid $pid"
      fi
    elif [[ "$state" -eq 2 ]]; then
      INSPECTION_FAILED=1
      record_blocker "could not determine worker pidfile pid $pid state: $PID_STATE_DETAIL"
    fi
  fi

  pid="$(read_pidfile "$III_PIDFILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    pid_state "$pid"
    state=$?
    if [[ "$state" -eq 0 ]]; then
      if pid_is_engine "$pid"; then
        engine_pidfile_pid="$pid"
      else
        record_blocker "iii pidfile points to unrelated pid $pid"
      fi
    elif [[ "$state" -eq 2 ]]; then
      INSPECTION_FAILED=1
      record_blocker "could not determine iii pidfile pid $pid state: $PID_STATE_DETAIL"
    fi
  fi

  for port in $CANONICAL_PORTS; do
    pids="$(listener_pids "$port")"
    if [[ "$?" -ne 0 ]]; then
      INSPECTION_FAILED=1
      record_blocker "could not inspect canonical port $port"
      continue
    fi
    for pid in $pids; do
      pid_state "$pid"
      state=$?
      [[ "$state" -ne 1 ]] || continue
      if [[ "$state" -eq 2 ]]; then
        INSPECTION_FAILED=1
        record_blocker "could not determine listener pid $pid state on port $port: $PID_STATE_DETAIL"
        continue
      fi
      case "$port" in
        3113)
          if pid_is_worker "$pid"; then
            append_unique OWNED_WORKERS "$pid"
          else
            record_blocker "unrelated pid $pid owns AgentMemory viewer port $port"
          fi
          ;;
        3111|3112|49134)
          if pid_is_engine "$pid"; then
            append_unique OWNED_ENGINES "$pid"
          else
            record_blocker "unrelated pid $pid owns AgentMemory engine port $port"
          fi
          ;;
        *) record_blocker "unsupported canonical port $port" ;;
      esac
    done
  done

  if [[ -n "$worker_pidfile_pid" ]]; then
    case " $OWNED_WORKERS " in
      *" $worker_pidfile_pid "*) ;;
      *) record_blocker "worker pidfile pid $worker_pidfile_pid is not correlated to the supervised child or viewer listener" ;;
    esac
  fi
  if [[ -n "$engine_pidfile_pid" ]]; then
    case " $OWNED_ENGINES " in
      *" $engine_pidfile_pid "*) ;;
      *) record_blocker "iii pidfile pid $engine_pidfile_pid is not correlated to an engine listener" ;;
    esac
  fi
}

signal_owned() {
  local signal pid role state signal_error failed
  signal="$1"
  role="$2"
  shift 2
  failed=0
  for pid in "$@"; do
    numeric_pid "$pid" || continue
    pid_state "$pid"
    state=$?
    [[ "$state" -ne 1 ]] || continue
    if [[ "$state" -eq 2 ]]; then
      record_blocker "could not determine $role pid $pid state before $signal: $PID_STATE_DETAIL"
      failed=1
      continue
    fi
    if [[ "$role" == "worker" ]]; then
      # A changed command means the original PID exited and was reused. Never
      # signal the replacement process.
      pid_is_worker "$pid" || continue
    else
      pid_is_engine "$pid" || continue
    fi
    signal_error="$("$KILL" "-$signal" "$pid" 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      record_blocker "failed to send $signal to $role pid $pid${signal_error:+: $signal_error}"
      failed=1
    fi
  done
  return "$failed"
}

wait_for_pids_exit() {
  local attempts interval attempt pid any_alive pids state
  attempts="$1"
  interval="$2"
  shift 2
  pids="$*"
  attempt=1
  while [[ "$attempt" -le "$attempts" ]]; do
    any_alive=0
    for pid in $pids; do
      pid_state "$pid"
      state=$?
      if [[ "$state" -eq 0 ]]; then
        any_alive=1
      elif [[ "$state" -eq 2 ]]; then
        record_blocker "could not determine pid $pid state while waiting: $PID_STATE_DETAIL"
        return 2
      fi
    done
    [[ "$any_alive" -eq 0 ]] && return 0
    /bin/sleep "$interval"
    attempt=$((attempt + 1))
  done
  return 1
}

stop_owned_pids() {
  local role attempts pids
  role="$1"
  attempts="$2"
  shift 2
  pids="$*"
  # shellcheck disable=SC2086
  signal_owned TERM "$role" $pids || true
  # shellcheck disable=SC2086
  if ! wait_for_pids_exit "$attempts" "$STOP_INTERVAL" $pids; then
    # shellcheck disable=SC2086
    signal_owned KILL "$role" $pids || true
    # shellcheck disable=SC2086
    wait_for_pids_exit "$KILL_STOP_ATTEMPTS" "$STOP_INTERVAL" $pids || true
  fi
  # shellcheck disable=SC2086
  verify_owned_pids_stopped "$role" $pids || true
}

verify_owned_pids_stopped() {
  local role pid state failed pids
  role="$1"
  shift
  pids="$*"
  failed=0
  for pid in $pids; do
    pid_state "$pid"
    state=$?
    if [[ "$state" -eq 2 ]]; then
      record_blocker "could not prove original $role pid $pid stopped: $PID_STATE_DETAIL"
      failed=1
      continue
    fi
    [[ "$state" -ne 1 ]] || continue
    if [[ "$role" == "worker" ]]; then
      pid_is_worker "$pid" || continue
    else
      pid_is_engine "$pid" || continue
    fi
    record_blocker "managed $role pid $pid survived TERM and KILL"
    failed=1
  done
  return "$failed"
}

ports_free() {
  local port pids
  for port in $CANONICAL_PORTS; do
    pids="$(listener_pids "$port")" || return 2
    [[ -z "$pids" ]] || return 1
  done
}

cleanup_managed_runtime() {
  local context blockers worker_pids engine_pids rediscovered_workers
  context="$1"
  classify_runtime
  blockers="$OWNERSHIP_BLOCKERS"
  worker_pids="$OWNED_WORKERS"

  if [[ "$INSPECTION_FAILED" -eq 1 ]]; then
    echo "AgentMemory $context blocked: $OWNERSHIP_BLOCKERS" >&2
    return 1
  fi

  # Stop the worker before iii so it cannot reconnect without replaying its
  # HTTP registrations. Never delegate this to v0.9.27 `stop --force`: that
  # command preserves a listening-but-unresponsive engine (upstream #624).
  # shellcheck disable=SC2086
  stop_owned_pids worker "$WORKER_STOP_ATTEMPTS" $worker_pids

  # Reclassify after the worker is gone. This is both the ordering barrier and
  # the ownership revalidation immediately before iii receives TERM/KILL.
  blockers="$OWNERSHIP_BLOCKERS"
  classify_runtime
  OWNERSHIP_BLOCKERS="${blockers}${blockers:+; }$OWNERSHIP_BLOCKERS"
  if [[ "$INSPECTION_FAILED" -eq 1 ]]; then
    echo "AgentMemory $context blocked after worker stop: $OWNERSHIP_BLOCKERS" >&2
    return 1
  fi
  rediscovered_workers="$OWNED_WORKERS"
  if [[ -n "$rediscovered_workers" ]]; then
    # A worker may reconnect or respawn during the first stop phase. It must be
    # stopped before iii; one repeated rediscovery fails closed.
    # shellcheck disable=SC2086
    stop_owned_pids worker "$WORKER_STOP_ATTEMPTS" $rediscovered_workers
    blockers="$OWNERSHIP_BLOCKERS"
    classify_runtime
    OWNERSHIP_BLOCKERS="${blockers}${blockers:+; }$OWNERSHIP_BLOCKERS"
    if [[ "$INSPECTION_FAILED" -eq 1 || -n "$OWNED_WORKERS" ]]; then
      record_blocker "managed worker remained or respawned before engine shutdown"
      echo "AgentMemory $context blocked before engine stop: $OWNERSHIP_BLOCKERS" >&2
      return 1
    fi
  fi
  engine_pids="$OWNED_ENGINES"
  # shellcheck disable=SC2086
  stop_owned_pids engine "$ENGINE_STOP_ATTEMPTS" $engine_pids

  if [[ -n "$OWNERSHIP_BLOCKERS" ]]; then
    echo "AgentMemory $context blocked: $OWNERSHIP_BLOCKERS" >&2
    return 1
  fi
  if ! ports_free; then
    classify_runtime
    echo "AgentMemory $context blocked: canonical ports remain occupied${OWNERSHIP_BLOCKERS:+ ($OWNERSHIP_BLOCKERS)}" >&2
    return 1
  fi

  # Remove only stale AgentMemory pidfiles after every canonical port is free.
  /bin/rm -f "$III_PIDFILE" "$WORKER_PIDFILE"
  return 0
}

stop_child() {
  local cleanup_status child_state
  cleanup_managed_runtime "shutdown"
  cleanup_status=$?
  if [[ -n "$CHILD_PID" ]]; then
    pid_state "$CHILD_PID"
    child_state=$?
    # Reap only after absence is proven. An acknowledged survivor or
    # indeterminate PID must not turn supervisor shutdown into an unbounded wait.
    [[ "$child_state" -ne 1 ]] || wait "$CHILD_PID" 2>/dev/null || true
  fi
  return "$cleanup_status"
}

shutdown_cleanly() {
  stop_child
  exit $?
}
trap shutdown_cleanly INT TERM

if [[ "$MODE" == "cleanup" ]]; then
  cleanup_managed_runtime "cleanup"
  exit $?
fi

compact_log "$LOG_DIR/agentmemory.out.log"
compact_log "$LOG_DIR/agentmemory.err.log"
if ! cleanup_managed_runtime "startup"; then
  exit 1
fi

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
