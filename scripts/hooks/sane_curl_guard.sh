#!/bin/bash
# sane_curl_guard.sh
# Shell-level guard for Codex/Claude sessions where native PreToolUse hooks may be unavailable.
# Blocks direct WRITE requests to SaneApps email endpoints unless an approved worker path sets
# SANE_EMAIL_WORKER_ALLOWED=1.

set -euo pipefail

REAL_CURL="/usr/bin/curl"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" ]]
}

is_write_request() {
  local args=("$@")
  local i arg next next_upper
  for ((i = 0; i < ${#args[@]}; i++)); do
    arg="${args[$i]}"
    case "$arg" in
      -d|--data|--data-binary|--data-raw|--form|-F)
        return 0
        ;;
      -X|--request)
        next="${args[$((i + 1))]:-}"
        next_upper=$(printf '%s' "$next" | tr '[:lower:]' '[:upper:]')
        case "$next_upper" in
          POST|PUT|PATCH|DELETE)
            return 0
            ;;
        esac
        ;;
    esac
  done
  return 1
}

targets_email_api() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *email-api.saneapps.com*) return 0 ;;
    esac
  done
  return 1
}

targets_resend_send() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      *api.resend.com/emails*) return 0 ;;
    esac
  done
  return 1
}

if is_ai_session && [[ "${SANE_EMAIL_WORKER_ALLOWED:-0}" != "1" ]] && is_write_request "$@"; then
  if targets_email_api "$@"; then
    echo "🔴 BLOCKED: Direct write to email API" >&2
    echo "   Use: ~/SaneApps/infra/scripts/check-inbox.sh reply|compose|resolve" >&2
    exit 2
  fi

  if targets_resend_send "$@"; then
    echo "🔴 BLOCKED: Direct email send via Resend API" >&2
    echo "   Use: ~/SaneApps/infra/scripts/check-inbox.sh reply|compose" >&2
    exit 2
  fi
fi

exec "$REAL_CURL" "$@"
