#!/bin/bash
# sane_build_tool_guard.sh
# Shell-level guard for raw xcodebuild/swift build-test commands in AI sessions.

set -euo pipefail

TOOL_NAME="${SANE_BUILD_TOOL_NAME:-$(basename "$0")}"
REAL_TOOL="/usr/bin/${TOOL_NAME}"

is_ai_session() {
  [[ -n "${CODEX_SHELL:-}" || -n "${CLAUDE_CODE:-}" || -n "${CLAUDE_WORKTREES:-}" || -n "${SANE_BUILD_TOOL_GUARD_TEST:-}" || -n "${GROK_HOOK_EVENT:-}" || -n "${GROK_SESSION_ID:-}" ]]
}

in_saneprocess_repo() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    [[ -f "$dir/.saneprocess" ]] && return 0
    dir="$(dirname "$dir")"
  done
  return 1
}

ancestor_allows_raw_tool() {
  local pid="${PPID:-}"
  local depth=0
  local cmd=""
  while [[ -n "$pid" && "$pid" != "0" && "$depth" -lt 8 ]]; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$cmd" =~ (SaneMaster\.rb|sane_test\.rb|release\.sh|mini-nightly\.sh|app_test_mode\.sh|swift_format\.rb|xcodebuildmcp|Xcode\.app) ]]; then
      return 0
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    depth=$((depth + 1))
  done
  return 1
}

read_only_xcodebuild() {
  [[ "$TOOL_NAME" != "xcodebuild" ]] && return 1
  local joined=" $* "
  [[ "$joined" =~ [[:space:]]-(list|version|showsdks|showBuildSettings)[[:space:]] ]]
}

raw_swift_build_test() {
  [[ "$TOOL_NAME" != "swift" ]] && return 1
  case "${1:-}" in
    build|test|run) return 0 ;;
    *) return 1 ;;
  esac
}

raw_xcodebuild_build_test() {
  [[ "$TOOL_NAME" != "xcodebuild" ]] && return 1
  read_only_xcodebuild "$@" && return 1
  return 0
}

if is_ai_session && in_saneprocess_repo &&
   { [[ "${SANE_BUILD_TOOL_GUARD_STRICT_TEST:-}" == "1" ]] || ! ancestor_allows_raw_tool; }; then
  if raw_xcodebuild_build_test "$@" || raw_swift_build_test "$@"; then
    echo "🔴 BLOCKED: Non-canonical SaneApps build/test command" >&2
    echo "   Command: $TOOL_NAME $*" >&2
    echo "" >&2
    echo "   Raw build/test commands can test stale checkouts or leave no workflow proof." >&2
    echo "   Use instead:" >&2
    echo "     ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb verify" >&2
    echo "   Runtime launch proof:" >&2
    echo "     ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb test_mode" >&2
    exit 2
  fi
fi

if [[ "${SANE_BUILD_TOOL_GUARD_TEST:-}" == "1" ]]; then
  echo "${TOOL_NAME}_ALLOWED $*"
  exit 0
fi

exec "$REAL_TOOL" "$@"
