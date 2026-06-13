#!/usr/bin/env bash
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
