#!/bin/bash
# sane_open_guard.sh
# Shell-level guard for Codex/Claude sessions where native PreToolUse hooks may be unavailable.
# Blocks local MacBook Air GUI openings for SaneApps release/dashboard work that must happen on the Mini.

set -euo pipefail

REAL_OPEN="${SANE_REAL_OPEN:-/usr/bin/open}"
LOCAL_UI_APPROVAL="MR. SANE APPROVES LOCAL UI ON AIR"
MINI_UNAVAILABLE_APPROVAL="MR. SANE CONFIRMS MINI UNAVAILABLE"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" || -n "${SANE_OPEN_GUARD_TEST:-}" || -n "${GROK_HOOK_EVENT:-}" || -n "${GROK_SESSION_ID:-}" ]]
}

running_on_macbook_air() {
  [[ "${SANE_FORCE_MACBOOK_AIR_FOR_TEST:-}" == "1" ]] && return 0
  [[ "${SANE_FORCE_MAC_MINI_FOR_TEST:-}" == "1" ]] && return 1

  local host
  host="$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  [[ "$host" != *mini* ]]
}

approved_local_fallback() {
  [[ "${SANE_APPROVE_LOCAL_UI_ON_AIR:-}" == "$LOCAL_UI_APPROVAL" ]] ||
    [[ "${SANE_MINI_UNAVAILABLE:-}" == "$MINI_UNAVAILABLE_APPROVAL" ]]
}

matches_sane_app_bundle() {
  local value="$1"
  [[ "$value" =~ (SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneScan|SaneSync|SaneVideo)\.app($|/|[[:space:]]) ]]
}

matches_sane_app_name_or_bundle_id() {
  local value="$1"
  [[ "$value" =~ ^(SaneBar|SaneClick|SaneClip|SaneHosts|SaneSales|SaneScan|SaneSync|SaneVideo)$ ]] && return 0
  [[ "$value" =~ ^com\.(sanebar|saneclick|saneclip|mrsane\.SaneHosts|sanesales|sanesync|sanevideo)\. ]] && return 0
  return 1
}

block_reason_for_arg() {
  local arg="$1"

  case "$arg" in
    https://app.lemonsqueezy.com*|http://app.lemonsqueezy.com*|https://auth.lemonsqueezy.com*|http://auth.lemonsqueezy.com*)
      printf 'Lemon Squeezy dashboard URL: %s' "$arg"
      return 0
      ;;
    https://appstoreconnect.apple.com*|http://appstoreconnect.apple.com*|https://developer.apple.com*|http://developer.apple.com*|https://idmsa.apple.com*|http://idmsa.apple.com*)
      printf 'Apple portal URL: %s' "$arg"
      return 0
      ;;
    *LemonSqueezy-Uploads*)
      printf 'Lemon Squeezy upload artifact path: %s' "$arg"
      return 0
      ;;
  esac

  if matches_sane_app_bundle "$arg"; then
    printf 'SaneApps app bundle launch/reveal: %s' "$arg"
    return 0
  fi

  if matches_sane_app_name_or_bundle_id "$arg"; then
    printf 'SaneApps app launch by name/bundle id: %s' "$arg"
    return 0
  fi

  return 1
}

combined_command() {
  printf '%s ' "$@"
}

if is_ai_session && running_on_macbook_air && ! approved_local_fallback; then
  for arg in "$@"; do
    reason="$(block_reason_for_arg "$arg" || true)"
    if [[ -n "$reason" ]]; then
      echo "🔴 BLOCKED: Mini-first SaneApps GUI guard" >&2
      echo "   $reason" >&2
      echo "" >&2
      echo "   This would open or reveal release/dashboard state on the MacBook Air." >&2
      echo "   Use the Mini instead:" >&2
      echo "     Brave on the Mini (Claude-in-Chrome widget / Codex Chrome lane) for dashboards," >&2
      echo "     including App Store Connect (owner retired the ASC Safari exception 2026-07-15)" >&2
      echo "     ssh mini 'open -R /path/on/mini'" >&2
      echo "" >&2
      echo "   Fallback requires explicit approval via:" >&2
      echo "     SANE_MINI_UNAVAILABLE='$MINI_UNAVAILABLE_APPROVAL'" >&2
      echo "     or SANE_APPROVE_LOCAL_UI_ON_AIR='$LOCAL_UI_APPROVAL'" >&2
      exit 2
    fi
  done

  command_text="$(combined_command "$@")"
  if [[ "$command_text" == *"app.lemonsqueezy.com"* || "$command_text" == *"auth.lemonsqueezy.com"* || "$command_text" == *"LemonSqueezy-Uploads"* ]]; then
    echo "🔴 BLOCKED: Mini-first SaneApps GUI guard" >&2
    echo "   Command: ${command_text% }" >&2
    echo "   Use Brave on the Mini (Claude-in-Chrome widget / Codex Chrome lane) + Mini Finder for Lemon Squeezy dashboard sync work. Never Safari." >&2
    exit 2
  fi
fi

if [[ "${SANE_OPEN_GUARD_TEST:-}" == "1" ]]; then
  echo "OPEN_ALLOWED $*"
  exit 0
fi

exec "$REAL_OPEN" "$@"
