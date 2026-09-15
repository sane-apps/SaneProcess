#!/bin/bash
# Sync primary operator control plane (Cursor + Grok) to the Mini.
# Legacy Codex sync remains available as sync_mini for compatibility only.

set -euo pipefail

MINI_HOST="mini"
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet]
Syncs Cursor hooks/skills and Grok helpers to the Mini.
USAGE
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done

ROOT="$HOME/SaneApps/infra/SaneProcess"
ARGS=()
[[ "$QUIET" -eq 1 ]] && ARGS+=(--quiet)

bash "$ROOT/scripts/automation/sync-cursor-mini.sh" "$MINI_HOST" "${ARGS[@]}"
bash "$ROOT/scripts/automation/sync-grok-mini.sh" "$MINI_HOST" "${ARGS[@]}"
