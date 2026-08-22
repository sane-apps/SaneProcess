#!/bin/bash
# Report-only SaneLot X opportunity scout. Replaces Codex heartbeat
# `sanelot-x-opportunity-scout`. Never posts or performs public X actions.

set -euo pipefail

ROOT="$HOME/SaneApps/infra/SaneProcess"
OUT_DIR="$HOME/SaneApps/outputs/x-opportunity-scout"
LOCK_DIR="$OUT_DIR/.lock"
LOG="$OUT_DIR/run.log"
PY="$HOME/.local/share/x-api-venv/bin/python3"
SCRIPT="$ROOT/scripts/automation/x-opportunity-scout.py"

mkdir -p "$OUT_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Iseconds) skip: prior run still holds lock" >>"$LOG"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

{
  echo "== $(date -Iseconds) x-opportunity-scout =="
  "$PY" "$SCRIPT" \
    --root "$HOME/SaneApps" \
    --all-live \
    --limit 4 \
    --per-query 10 \
    --json
} >>"$LOG" 2>&1
