#!/bin/bash
# sane_security_guard.sh
# Shell-level guard for Codex/Claude sessions where native PreToolUse hooks may be unavailable.
# Prevents repeated Keychain secret reads from flooding the user with prompts.

set -euo pipefail

REAL_SECURITY="${SANE_REAL_SECURITY:-/usr/bin/security}"
GUARD_DIR="${TMPDIR:-/tmp}/sane-security-guard"
LOCK_DIR="${GUARD_DIR}/lock"
STAMP_FILE="${GUARD_DIR}/last_lookup"
HISTORY_FILE="${GUARD_DIR}/history"
REPEAT_COOLDOWN_SECONDS="${SANE_SECURITY_REPEAT_COOLDOWN_SECONDS:-30}"
BURST_WINDOW_SECONDS="${SANE_SECURITY_BURST_WINDOW_SECONDS:-60}"
BURST_MAX_LOOKUPS="${SANE_SECURITY_BURST_MAX_LOOKUPS:-12}"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" || -n "${GROK_HOOK_EVENT:-}" || -n "${GROK_SESSION_ID:-}" ]]
}

is_secret_read() {
  local subcommand="${1:-}"
  case "$subcommand" in
    find-generic-password|find-internet-password|dump-keychain)
      return 0
      ;;
  esac
  return 1
}

is_claude_auth() {
  # Never throttle Claude Code's own Keychain auth reads. Blocking these makes
  # Claude Code read its OAuth token as "missing" and triggers a login loop.
  [[ "${1:-}" == "find-generic-password" ]] || return 1
  caller_is_claude_code || return 1
  security_lookup_targets_claude_auth "$@"
}

caller_is_claude_code() {
  local pid="${PPID:-}"
  local depth=0
  local args=""
  while [[ -n "$pid" && "$pid" != "0" && "$depth" -lt 8 ]]; do
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"Claude Code"*|*claude-code*|*"/Claude.app/"*|*"Claude.app/Contents"*) return 0 ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    depth=$((depth + 1))
  done
  return 1
}

security_lookup_targets_claude_auth() {
  local previous=""
  local service=""
  local server=""
  for arg in "$@"; do
    case "$previous" in
      -s)
        service="$arg"
        ;;
      -r)
        server="$arg"
        ;;
    esac
    previous="$arg"
  done

  [[ "$service" == "Claude Code" || "$server" == "claude.ai" ]]
}

ensure_guard_dir() {
  mkdir -p "$GUARD_DIR"
}

command_string() {
  printf '%s ' "$@"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
    return 0
  fi

  echo "🔴 BLOCKED: Another Keychain lookup is already in flight." >&2
  echo "   Rule: one Keychain prompt at a time. Wait for the first one to finish." >&2
  exit 2
}

same_lookup_is_recent() {
  local current_cmd="$1"
  [[ -f "$STAMP_FILE" ]] || return 1

  local now last_ts last_cmd
  now=$(date +%s)
  last_ts=$(awk -F'|' 'NR==1 { print $1 }' "$STAMP_FILE" 2>/dev/null || true)
  last_cmd=$(cut -d'|' -f2- "$STAMP_FILE" 2>/dev/null || true)
  [[ "$last_ts" =~ ^[0-9]+$ ]] || return 1

  [[ "$last_cmd" == "$current_cmd" ]] || return 1
  (( now - last_ts < REPEAT_COOLDOWN_SECONDS ))
}

write_stamp() {
  local now cmd
  now=$(date +%s)
  cmd=$(command_string "$@")
  printf '%s|%s\n' "$now" "${cmd% }" > "$STAMP_FILE"
}

append_history() {
  local now cmd cutoff tmp_file
  now=$(date +%s)
  cmd=$(command_string "$@")
  printf '%s|%s\n' "$now" "${cmd% }" >> "$HISTORY_FILE"

  cutoff=$(( now - BURST_WINDOW_SECONDS ))
  tmp_file="${HISTORY_FILE}.tmp"
  awk -F'|' -v cutoff="$cutoff" '($1 ~ /^[0-9]+$/) && ($1 >= cutoff) { print }' "$HISTORY_FILE" > "$tmp_file" 2>/dev/null || true
  mv "$tmp_file" "$HISTORY_FILE"
}

recent_lookup_count() {
  [[ -f "$HISTORY_FILE" ]] || { echo 0; return; }

  local now cutoff
  now=$(date +%s)
  cutoff=$(( now - BURST_WINDOW_SECONDS ))
  awk -F'|' -v cutoff="$cutoff" '($1 ~ /^[0-9]+$/) && ($1 >= cutoff) { count++ } END { print count + 0 }' "$HISTORY_FILE"
}

guarded=0

if is_ai_session && is_secret_read "${1:-}" && ! is_claude_auth "$@"; then
  guarded=1
  ensure_guard_dir
  acquire_lock

  current_cmd=$(command_string "$@")
  current_cmd="${current_cmd% }"

  if [[ "${SANE_SECURITY_ALLOW_REPEAT:-0}" != "1" ]] && same_lookup_is_recent "$current_cmd"; then
    local_prev=$(cut -d'|' -f2- "$STAMP_FILE" 2>/dev/null || echo "unknown")
    echo "🔴 BLOCKED: Repeated Keychain lookup too soon." >&2
    echo "   Rule: avoid repeated probes of the same secret. Reuse the value you already fetched." >&2
    echo "   Last lookup: $local_prev" >&2
    echo "   Different secrets are allowed sequentially. This block only applies to rapid repeats of the same lookup." >&2
    exit 2
  fi

  if [[ "${SANE_SECURITY_ALLOW_REPEAT:-0}" != "1" ]]; then
    recent_count=$(recent_lookup_count)
    if (( recent_count >= BURST_MAX_LOOKUPS )); then
      echo "🔴 BLOCKED: Too many Keychain lookups in a short burst." >&2
      echo "   Rule: sequential lookups are fine when needed, but loops/retries/prompt floods are not." >&2
      echo "   Recent lookups: $recent_count in ${BURST_WINDOW_SECONDS}s (limit ${BURST_MAX_LOOKUPS})." >&2
      echo "   Reuse cached secrets or slow down instead of hammering Keychain." >&2
      exit 2
    fi
  fi

  write_stamp "$@"
  append_history "$@"
fi

if [[ "$guarded" == "1" ]]; then
  "$REAL_SECURITY" "$@"
  exit $?
fi

exec "$REAL_SECURITY" "$@"
