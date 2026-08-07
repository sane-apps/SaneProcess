#!/bin/bash
# sane_ssh_guard.sh
# Shell-level guard for Codex/Claude sessions where native PreToolUse hooks may be unavailable.
# Blocks raw Mini screenshot capture over ssh; use the canonical GUI-session wrapper instead.

set -euo pipefail

REAL_SSH="${SANE_REAL_SSH:-/usr/bin/ssh}"
RAW_SCREENSHOT_APPROVAL="MR. SANE APPROVES RAW MINI SCREENSHOT"
CANONICAL_SCREENSHOT="${HOME}/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || "${CODEX_CI:-}" == "1" || "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" == "Codex Desktop" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" || -n "${CURSOR_AGENT:-}" || -n "${CURSOR_SESSION_ID:-}" || -n "${CURSOR_TRACE_ID:-}" || -n "${GROK_HOOK_EVENT:-}" || -n "${GROK_SESSION_ID:-}" || -n "${SANE_SSH_GUARD_TEST:-}" ]]
}

is_option_with_value() {
  case "$1" in
    -b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w)
      return 0
      ;;
  esac
  return 1
}

host_is_mini() {
  local host="$1"
  host="${host#*@}"
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"

  case "$host" in
    mini|mini.*|*mac-mini*|*stephans-mac-mini*|*stephens-mac-mini*)
      return 0
      ;;
  esac
  return 1
}

remote_command_for_args() {
  local args=("$@")
  local i=0
  local host=""
  local remote=()

  while (( i < ${#args[@]} )); do
    local arg="${args[$i]}"

    if [[ "$arg" == "--" ]]; then
      i=$((i + 1))
      break
    fi

    if [[ "$arg" == --*=* ]]; then
      i=$((i + 1))
      continue
    fi

    if [[ "$arg" == -* ]]; then
      if is_option_with_value "$arg"; then
        i=$((i + 2))
      else
        i=$((i + 1))
      fi
      continue
    fi

    host="$arg"
    i=$((i + 1))
    break
  done

  [[ -n "$host" ]] || return 1
  host_is_mini "$host" || return 1

  while (( i < ${#args[@]} )); do
    remote+=("${args[$i]}")
    i=$((i + 1))
  done

  if (( ${#remote[@]} > 0 )); then
    printf '%s' "${remote[*]}"
  fi
}

remote_uses_raw_screencapture() {
  local remote="$1"
  [[ -n "$remote" ]] || return 1

  # Normalize shell quoting and separators so forms like
  # `ssh mini "bash -lc 'screencapture ...'"` do not slip past the guard.
  local normalized="$remote"
  normalized="${normalized//\'/ }"
  normalized="${normalized//\"/ }"
  normalized="${normalized//;/ }"
  normalized="${normalized//&/ }"
  normalized="${normalized//|/ }"
  normalized="${normalized//(/ }"
  normalized="${normalized//)/ }"
  [[ "$normalized" =~ (^|[[:space:]/])screencapture([[:space:]]|$) ]]
}

remote_uses_detached_saneapps_qa() {
  local remote="$1"
  [[ -n "$remote" ]] || return 1
  [[ "$remote" == *"launchctl submit"* ]] || return 1
  [[ "$remote" == *"run_sanebar_qa"* ||
     "$remote" == *"Scripts/qa.rb"* ||
     "$remote" == *"SANEBAR_RUN_RUNTIME_SMOKE"* ||
     "$remote" == *"SaneMaster.rb release_preflight"* ]]
}

if is_ai_session; then
  remote_command="$(remote_command_for_args "$@" || true)"
  if [[ "${SANE_ALLOW_RAW_MINI_SCREENSHOT:-}" != "$RAW_SCREENSHOT_APPROVAL" ]] &&
     remote_uses_raw_screencapture "$remote_command"; then
    cat >&2 <<EOF
🔴 BLOCKED: raw Mini screenshot over ssh.

This path runs outside the canonical Mini GUI-session screenshot wrapper and
has repeatedly produced false failures.

Use:
  ${CANONICAL_SCREENSHOT} desktop
  ${CANONICAL_SCREENSHOT} --app "SaneBar" --mode temp

If the canonical wrapper is genuinely broken or missing, fix that tool first.
Temporary override for diagnosis only:
  SANE_ALLOW_RAW_MINI_SCREENSHOT='${RAW_SCREENSHOT_APPROVAL}'
EOF
    exit 2
  fi

  if remote_uses_detached_saneapps_qa "$remote_command"; then
    cat >&2 <<EOF
🔴 BLOCKED: detached Mini SaneApps QA via launchctl.

Do not run release/runtime QA through self-restarting launchctl jobs. That path
leaves stale jobs, shifting PIDs, and ambiguous receipts.

Use a foreground canonical receipt instead:
  ssh mini 'cd ~/SaneApps/apps/SaneBar && ./scripts/SaneMaster.rb release_preflight'
  ssh mini 'cd ~/SaneApps/apps/SaneBar && SANEBAR_RUN_RUNTIME_SMOKE=1 SANEBAR_RELEASE_SMOKE_SCREENSHOTS=1 ruby Scripts/qa.rb'

If a foreground canonical command is unreliable, fix that command or SaneProcess
before adding a detached runner.
EOF
    exit 2
  fi
fi

if [[ "${SANE_SSH_GUARD_DRY_RUN:-0}" == "1" ]]; then
  echo "SSH_ALLOWED $*"
  exit 0
fi

exec "$REAL_SSH" "$@"
