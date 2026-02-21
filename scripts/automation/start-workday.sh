#!/bin/bash
# Start-of-day workflow from MacBook Air while Mini runs automation.

set -euo pipefail

MINI_HOST="mini"
OPEN_FILES=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--no-open]

Examples:
  $(basename "$0")
  $(basename "$0") mini --no-open
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --no-open)
      OPEN_FILES=0
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
SYNC_SCRIPT="$ROOT/scripts/automation/sync-codex-mini.sh"
GIT_SYNC_SCRIPT="$ROOT/scripts/automation/git-sync-safe.sh"
OUT_DIR="$ROOT/outputs"
LOCAL_INBOX="$HOME/SaneApps/infra/scripts/check-inbox.sh"

[[ -x "$SYNC_SCRIPT" ]] || { echo "ERROR: Missing sync script: $SYNC_SCRIPT" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo "== SaneOps Workday Start =="
echo "1) Syncing automation config to Mini..."
bash "$SYNC_SCRIPT" "$MINI_HOST"

echo ""
echo "2) Air↔Mini git drift check (advisory)..."
if [[ -x "$GIT_SYNC_SCRIPT" ]]; then
  "$GIT_SYNC_SCRIPT" --peer "$MINI_HOST" || true
else
  echo "git-sync-safe.sh not found at $GIT_SYNC_SCRIPT"
fi

echo ""
echo "3) Fetching Mini reports..."
scp -q "$MINI_HOST:~/SaneApps/infra/SaneProcess/outputs/morning_report.md" "$OUT_DIR/morning_report.mini.md" 2>/dev/null || true
scp -q "$MINI_HOST:~/SaneApps/infra/SaneProcess/outputs/nightly_report.md" "$OUT_DIR/nightly_report.mini.md" 2>/dev/null || true

echo ""
echo "4) Mini automation status:"
ssh "$MINI_HOST" 'sqlite3 -header -column ~/.codex/sqlite/codex-dev.db "SELECT id,name,status,datetime(next_run_at/1000,\"unixepoch\",\"localtime\") AS next_run_local, datetime(last_run_at/1000,\"unixepoch\",\"localtime\") AS last_run_local FROM automations;"'

echo ""
echo "5) Inbox summary (local):"
if [[ -x "$LOCAL_INBOX" ]]; then
  "$LOCAL_INBOX" || true
else
  echo "check-inbox.sh not found at $LOCAL_INBOX"
fi

if [[ "$OPEN_FILES" -eq 1 ]]; then
  [[ -f "$OUT_DIR/morning_report.mini.md" ]] && open "$OUT_DIR/morning_report.mini.md" || true
  [[ -f "$OUT_DIR/nightly_report.mini.md" ]] && open "$OUT_DIR/nightly_report.mini.md" || true
  open -ga Codex || true
fi

echo ""
echo "Next steps:"
echo "  1. Review the latest report(s) from Mini."
echo "  2. Review pending inbox items and approve/edit drafts."
echo "  3. Only ship if release gates are clearly green."
