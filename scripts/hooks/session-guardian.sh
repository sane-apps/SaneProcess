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
#   A process is reaped ONLY if ALL hold:
#     1. ppid == 1            (its real parent is DEAD; a live session has ppid != 1)
#     2. command matches the disposable family regex below
#     3. its pid is NOT a launchd-managed job (excludes the mcp-singleton bridges)
#   Live Claude sessions, Claude.app, the MCP singleton bridge, and the user's
#   own apps are therefore never touched.
#
# Memory hogs that are NOT orphans are LOGGED, never auto-killed (could be the
# user's active session). Forensics live in the log so the next crash is explainable.

set -u
LOG="${HOME}/Library/Logs/SaneApps/session-guardian.log"
mkdir -p "$(dirname "$LOG")"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# Disposable family: orphaned MCP servers + claude-code leftovers safe to reap when
# parentless. Deliberately specific — generic node/python match ONLY via MCP/uv paths.
# NOTE: chrome_crashpad_handler and "Claude Helper" are EXCLUDED on purpose: crashpad
# handlers detach to ppid==1 by design (so they outlive the app to record its crash),
# so a ppid==1 crashpad belongs to a LIVE app, not a dead session.
FAMILY='server-memory|mcp-memory-enhanced|mcp-central-memory|@modelcontextprotocol|/serena|start-mcp-server|\.cache/uv/|claude-code/[0-9].*/claude\.app'

# launchd-managed pids (column 1 of `launchctl list`) — never reap these.
managed_pids=" $(launchctl list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' | tr '\n' ' ') "

reaped=0
# ppid==1 candidates in the disposable family.
while read -r pid ppid rss command; do
  [ "$ppid" = "1" ] || continue
  case "$command" in *Claude.app/Contents/MacOS/Claude*) continue;; esac  # the desktop app itself
  echo "$command" | grep -Eq "$FAMILY" || continue
  case "$managed_pids" in *" $pid "*) continue;; esac                      # launchd-managed singleton
  mb=$((rss/1024))
  kill -TERM "$pid" 2>/dev/null
  sleep 1
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  log "REAPED orphan pid=$pid rss=${mb}MB cmd=$(echo "$command" | cut -c1-90)"
  reaped=$((reaped+1))
done < <(ps -A -o pid=,ppid=,rss=,command=)

# Memory forensics every run (cheap; one line unless pressure).
free_pct=$(memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub(/%/,"",$2); print $2}')
free_pct=${free_pct:-unknown}
if [ "$reaped" -gt 0 ]; then
  log "run complete: reaped=$reaped free=${free_pct}%"
fi
# Under pressure, record the top hogs (do NOT kill — may be a live session).
if [ "$free_pct" != "unknown" ] && [ "$free_pct" -lt 15 ] 2>/dev/null; then
  log "LOW MEMORY: free=${free_pct}% — top RSS:"
  ps -A -o rss=,pid=,comm= -m | head -6 | while read -r r p c; do
    log "   $((r/1024))MB pid=$p $c"
  done
fi
exit 0
