#!/bin/bash
# session-guardian.sh — periodic orphan/memory-hog reaper for the Mac workstation.
#
# WHY: macOS jetsam OOM-kills a Claude session on a transient RAM spike. The dead
# session's disposable children (node/uvx/python MCP servers, crashpad handlers,
# claude-code helpers) get reparented to launchd (ppid==1) and linger, eating RAM
# so the NEXT session starts closer to the OOM ceiling -> death spiral. The
# mcp-watchdog only reaps the MCP subset; this guardian reaps the rest.
#
# SAFETY MODEL (intentionally conservative — never kill live work):
#   ppid==1 is ambiguous on macOS because legitimate daemons detach to launchd.
#   A process is reaped ONLY if it has a durable ownership record binding its
#   pid, start time, and command digest to a now-dead session owner. Matching
#   ppid==1 processes without that proof are report-only. launchd-managed jobs,
#   live Claude sessions, Claude.app, and the user's own apps are never touched.
#
# Memory hogs that are NOT orphans are LOGGED, never auto-killed (could be the
# user's active session). Forensics live in the log so the next crash is explainable.

set -u
LOG="${SANE_SESSION_GUARDIAN_LOG:-${HOME}/Library/Logs/SaneApps/session-guardian.log}"
OWNERSHIP_FILE="${SANE_SESSION_GUARDIAN_OWNERSHIP_FILE:-${HOME}/Library/Application Support/SaneApps/session-guardian-ownership.tsv}"
# Trusted TSV schema: child_pid, child `ps lstart` token, command SHA-256,
# original session-owner pid. The file must be owned by this user and mode 0400/0600.
PS_BIN="${SANE_SESSION_GUARDIAN_PS_BIN:-/bin/ps}"
LAUNCHCTL_BIN="${SANE_SESSION_GUARDIAN_LAUNCHCTL_BIN:-/bin/launchctl}"
KILL_BIN="${SANE_SESSION_GUARDIAN_KILL_BIN:-/bin/kill}"
SLEEP_BIN="${SANE_SESSION_GUARDIAN_SLEEP_BIN:-/bin/sleep}"
MEMORY_PRESSURE_BIN="${SANE_SESSION_GUARDIAN_MEMORY_PRESSURE_BIN:-/usr/bin/memory_pressure}"
SHASUM_BIN="${SANE_SESSION_GUARDIAN_SHASUM_BIN:-/usr/bin/shasum}"
STAT_BIN="${SANE_SESSION_GUARDIAN_STAT_BIN:-/usr/bin/stat}"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# Disposable family: orphaned MCP servers + claude-code leftovers safe to reap when
# parentless. Deliberately specific — generic node/python match ONLY via MCP/uv paths.
# NOTE: chrome_crashpad_handler and "Claude Helper" are EXCLUDED on purpose: crashpad
# handlers detach to ppid==1 by design (so they outlive the app to record its crash),
# so a ppid==1 crashpad belongs to a LIVE app, not a dead session.
FAMILY='server-memory|mcp-memory-enhanced|mcp-central-memory|@modelcontextprotocol|/serena|start-mcp-server|\.cache/uv/|claude-code/[0-9].*/claude\.app'

case "${1:-}" in
  --health)
    [ "$#" -eq 1 ] || { echo "Usage: $(basename "$0") [--health]" >&2; exit 2; }
    [ -n "$FAMILY" ] || { echo "session-guardian unhealthy: disposable-family policy is empty" >&2; exit 1; }
    [ -x "$PS_BIN" ] || { echo "session-guardian unhealthy: ps missing" >&2; exit 1; }
    [ -x "$LAUNCHCTL_BIN" ] || { echo "session-guardian unhealthy: launchctl missing" >&2; exit 1; }
    [ -x "$KILL_BIN" ] || { echo "session-guardian unhealthy: kill missing" >&2; exit 1; }
    [ -x "$SLEEP_BIN" ] || { echo "session-guardian unhealthy: sleep missing" >&2; exit 1; }
    [ -x "$MEMORY_PRESSURE_BIN" ] || { echo "session-guardian unhealthy: memory_pressure missing" >&2; exit 1; }
    [ -x "$SHASUM_BIN" ] || { echo "session-guardian unhealthy: shasum missing" >&2; exit 1; }
    [ -x "$STAT_BIN" ] || { echo "session-guardian unhealthy: stat missing" >&2; exit 1; }
    echo "session-guardian healthy"
    exit 0
    ;;
  '') ;;
  *)
    echo "Usage: $(basename "$0") [--health]" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$LOG")"

# launchd-managed pids (column 1 of `launchctl list`) — never reap these.
managed_pids=" $("$LAUNCHCTL_BIN" list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ') "

ownership_file_trusted() {
  local metadata owner mode
  [ -f "$OWNERSHIP_FILE" ] && [ -r "$OWNERSHIP_FILE" ] || return 1
  metadata="$("$STAT_BIN" -f '%u %Lp' "$OWNERSHIP_FILE" 2>/dev/null)" || return 1
  owner="${metadata%% *}"
  mode="${metadata##* }"
  [ "$owner" = "$(id -u)" ] || return 1
  case "$mode" in
    400|600) return 0 ;;
    *) return 1 ;;
  esac
}

process_start_token() {
  "$PS_BIN" -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

command_digest() {
  printf '%s' "$1" | "$SHASUM_BIN" -a 256 | awk '{print $1}'
}

has_dead_session_ownership() {
  local candidate_pid command current_start current_digest
  local evidence_pid evidence_start evidence_digest owner_pid extra
  candidate_pid="$1"
  command="$2"
  ownership_file_trusted || return 1
  current_start="$(process_start_token "$candidate_pid")"
  [ -n "$current_start" ] || return 1
  current_digest="$(command_digest "$command")" || return 1

  while IFS=$'\t' read -r evidence_pid evidence_start evidence_digest owner_pid extra; do
    [ -z "${extra:-}" ] || continue
    [ "$evidence_pid" = "$candidate_pid" ] || continue
    [ "$evidence_start" = "$current_start" ] || continue
    [ "$evidence_digest" = "$current_digest" ] || continue
    case "$owner_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$owner_pid" -gt 1 ] || continue
    "$KILL_BIN" -0 "$owner_pid" 2>/dev/null && continue
    return 0
  done < "$OWNERSHIP_FILE"
  return 1
}

reaped=0
# ppid==1 candidates in the disposable family. A match alone is never kill proof.
while read -r pid ppid rss command; do
  [ "$ppid" = "1" ] || continue
  case "$command" in *Claude.app/Contents/MacOS/Claude*) continue;; esac  # the desktop app itself
  echo "$command" | grep -Eq "$FAMILY" || continue
  case "$managed_pids" in *" $pid "*) continue;; esac                      # launchd-managed singleton
  mb=$((rss/1024))
  if ! has_dead_session_ownership "$pid" "$command"; then
    log "REPORT_ONLY ambiguous ppid=1 pid=$pid rss=${mb}MB cmd=$(echo "$command" | cut -c1-90)"
    continue
  fi
  "$KILL_BIN" -TERM "$pid" 2>/dev/null
  "$SLEEP_BIN" 1
  "$KILL_BIN" -0 "$pid" 2>/dev/null && "$KILL_BIN" -KILL "$pid" 2>/dev/null
  log "REAPED orphan pid=$pid rss=${mb}MB cmd=$(echo "$command" | cut -c1-90)"
  reaped=$((reaped+1))
done < <("$PS_BIN" -A -o pid=,ppid=,rss=,command=)

# Memory forensics every run (cheap; one line unless pressure).
free_pct=$("$MEMORY_PRESSURE_BIN" 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2}')
free_pct=${free_pct:-unknown}
if [ "$reaped" -gt 0 ]; then
  log "run complete: reaped=$reaped free=${free_pct}%"
fi
# Under pressure, record the top hogs (do NOT kill — may be a live session).
if [ "$free_pct" != "unknown" ] && [ "$free_pct" -lt 15 ] 2>/dev/null; then
  log "LOW MEMORY: free=${free_pct}% — top RSS:"
  "$PS_BIN" -A -o rss=,pid=,comm= -m | head -6 | while read -r r p c; do
    log "   $((r/1024))MB pid=$p $c"
  done
fi
exit 0
