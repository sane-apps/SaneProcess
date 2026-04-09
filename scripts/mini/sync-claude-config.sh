#!/usr/bin/env bash
# Legacy wrapper kept only so old muscle-memory commands fail safe.
# Canonical Mini control-plane sync is scripts/automation/sync-codex-mini.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_SCRIPT="${SCRIPT_DIR%/mini}/automation/sync-codex-mini.sh"

usage() {
  cat <<'USAGE'
Legacy wrapper: use the canonical path instead.

  bash scripts/automation/sync-codex-mini.sh mini --no-restart

This wrapper only accepts:
  --dry-run     Print the canonical command and exit
  --quiet       Pass through to the canonical command
  --no-restart  Pass through to the canonical command
USAGE
}

[[ -x "$CANONICAL_SCRIPT" ]] || {
  echo "ERROR: Missing canonical sync script: $CANONICAL_SCRIPT" >&2
  exit 1
}

PASSTHROUGH_ARGS=("mini" "--no-restart")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      echo "DEPRECATED: scripts/mini/sync-claude-config.sh"
      echo "Use: bash scripts/automation/sync-codex-mini.sh mini --no-restart"
      exit 0
      ;;
    --quiet|--no-restart)
      PASSTHROUGH_ARGS+=("$1")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unsupported legacy arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

echo "DEPRECATED: scripts/mini/sync-claude-config.sh"
echo "Routing to scripts/automation/sync-codex-mini.sh instead."
exec bash "$CANONICAL_SCRIPT" "${PASSTHROUGH_ARGS[@]}"
