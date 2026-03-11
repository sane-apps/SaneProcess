#!/bin/bash
# sane_security_guard.sh
# Shell-level guard for Codex/Claude sessions where native PreToolUse hooks may be unavailable.
# Prevents repeated Keychain secret reads from flooding the user with prompts.

set -euo pipefail

REAL_SECURITY="${SANE_REAL_SECURITY:-/usr/bin/security}"
GUARD_DIR="${TMPDIR:-/tmp}/sane-security-guard"
LOCK_DIR="${GUARD_DIR}/lock"
STAMP_FILE="${GUARD_DIR}/last_lookup"
COOLDOWN_SECONDS="${SANE_SECURITY_COOLDOWN_SECONDS:-120}"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" ]]
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

ensure_guard_dir() {
  mkdir -p "$GUARD_DIR"
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

last_lookup_is_recent() {
  [[ -f "$STAMP_FILE" ]] || return 1

  local now last_ts
  now=$(date +%s)
  last_ts=$(awk -F'|' 'NR==1 { print $1 }' "$STAMP_FILE" 2>/dev/null || true)
  [[ "$last_ts" =~ ^[0-9]+$ ]] || return 1

  (( now - last_ts < COOLDOWN_SECONDS ))
}

write_stamp() {
  local now cmd
  now=$(date +%s)
  cmd=$(printf '%s ' "$@")
  printf '%s|%s\n' "$now" "${cmd% }" > "$STAMP_FILE"
}

guarded=0

if is_ai_session && is_secret_read "${1:-}"; then
  guarded=1
  ensure_guard_dir
  acquire_lock

  if [[ "${SANE_SECURITY_ALLOW_REPEAT:-0}" != "1" ]] && last_lookup_is_recent; then
    local_prev=$(cut -d'|' -f2- "$STAMP_FILE" 2>/dev/null || echo "unknown")
    echo "🔴 BLOCKED: Repeated Keychain lookup too soon." >&2
    echo "   Rule: one intentional Keychain prompt per task. Reuse the first value instead of probing again." >&2
    echo "   Last lookup: $local_prev" >&2
    echo "   If you truly need another prompt right now, explain it first and rerun once with SANE_SECURITY_ALLOW_REPEAT=1." >&2
    exit 2
  fi

  write_stamp "$@"
fi

if [[ "$guarded" == "1" ]]; then
  "$REAL_SECURITY" "$@"
  exit $?
fi

exec "$REAL_SECURITY" "$@"
