#!/usr/bin/env bash
# Claude SOP hook adapter. Call this from Claude settings.json instead of
# inlining ${CLAUDECODE}. Grok no longer imports Claude hooks; it uses native
# ~/.grok/hooks (scripts/hooks/grok/hooks.json). Keep this wrapper so a leftover
# ${VAR} in Claude settings cannot fail-open as a required env on any client.
set -u

hook_name="${1:-}"
case "$hook_name" in
  *.rb) ;;
  *) exit 0 ;;
esac

if [ -z "${CLAUDECODE:-}${CLAUDE_CODE:-}" ]; then
  exit 0
fi

if [ ! -f .saneprocess ]; then
  exit 0
fi

hook_dir="${SANEPROCESS_HOOK_DIR:-$HOME/SaneApps/infra/SaneProcess/scripts/hooks}"
hook_path="$hook_dir/$hook_name"

if [ ! -f "$hook_path" ]; then
  exit 0
fi

exec ruby "$hook_path"
