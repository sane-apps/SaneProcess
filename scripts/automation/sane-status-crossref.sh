#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_INBOX="${HOME}/SaneApps/infra/scripts/check-inbox.sh"
SANE_MASTER="${REPO_ROOT}/SaneMaster.rb"

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
  ruby "$SANE_MASTER" listing_actions --json | python3 - <<'PY'
import json
import sys

payload = json.load(sys.stdin)
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
if command -v gh >/dev/null 2>&1; then
  for repo in SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo; do
    echo "\n## $repo"
    gh issue list -R "sane-apps/${repo}" --state open --limit 10 || echo "  Unable to fetch issues for ${repo} (auth missing or no issues)."
  done
else
  echo "GitHub CLI (gh) not installed"
fi

printf '\n[5/5] Open GitHub PRs (sane-apps org)\n'
if command -v gh >/dev/null 2>&1; then
  for repo in SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo; do
    echo "\n## $repo"
    gh pr list -R "sane-apps/${repo}" --state open --limit 10 || echo "  Unable to fetch PRs for ${repo} (auth missing or no PRs)."
  done
else
  echo "GitHub CLI (gh) not installed"
fi

printf '\nDone.\n'
