#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_INBOX="${HOME}/SaneApps/infra/scripts/check-inbox.sh"
SANE_MASTER="${REPO_ROOT}/SaneMaster.rb"
GITHUB_QUEUE="${SCRIPT_DIR}/github-queue.sh"
LISTING_JSON_PATH="${STATUS_LISTING_JSON_PATH:-}"
LISTING_JSON_CLEANUP=0

if [[ -z "$LISTING_JSON_PATH" ]]; then
  LISTING_JSON_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-listing.XXXXXX")"
  LISTING_JSON_CLEANUP=1
fi

cleanup() {
  if [[ "$LISTING_JSON_CLEANUP" -eq 1 ]]; then
    rm -f "$LISTING_JSON_PATH"
  fi
}

trap cleanup EXIT

printf '\nSane status cross-reference (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

printf '\n[1/5] Sales (last 30 days)\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" sales --days 30
else
  echo "SaneMaster sales not executable"
fi

printf '\n[2/5] Inbox status\n'
if [[ -x "$CHECK_INBOX" ]]; then
  "$CHECK_INBOX"
else
  echo "check-inbox.sh not found at $CHECK_INBOX"
fi

printf '\n[3/5] Listing actions\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" listing_actions --json-out "$LISTING_JSON_PATH" >/dev/null
  python3 - "$LISTING_JSON_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
current = payload.get("current_actions", [])
needs = [row for row in current if row.get("action_status") == "Needs action"]
optional = [row for row in current if row.get("action_status") == "Optional"]
monitor = [row for row in current if row.get("action_status") == "Monitor"]

print(f"Current actions: {len(current)}")
print(f"Needs action: {len(needs)} | Optional: {len(optional)} | Monitor: {len(monitor)}")
if needs:
    print("")
    for row in needs[:10]:
        print(
            f"- {row.get('site', '')}: {row.get('workflow', '')} "
            f"(email #{row.get('latest_email_id', '')})"
        )
else:
    print("No live listing/setup actions.")
PY
else
  echo "SaneMaster listing_actions not executable"
fi

printf '\n[4/5] Open GitHub issues (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" issues --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\n[5/5] Open GitHub PRs (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" prs --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\nDone.\n'
