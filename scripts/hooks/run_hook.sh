#!/usr/bin/env bash
# Shared Claude-native hook adapter.
# Call this from settings.json instead of inlining ${CLAUDECODE}:
# Grok imports Claude hooks and treats ${VAR} as a required env interpolation,
# which paints every tool call as a failed hook.
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
