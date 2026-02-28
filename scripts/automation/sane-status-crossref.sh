#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_INBOX="${HOME}/SaneApps/infra/scripts/check-inbox.sh"
SANE_MASTER="${REPO_ROOT}/SaneMaster.rb"

printf '\nSane status cross-reference (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

printf '\n[1/3] Sales (last 30 days)\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" sales --days 30
else
  echo "SaneMaster sales not executable"
fi

printf '\n[2/3] Inbox status\n'
if [[ -x "$CHECK_INBOX" ]]; then
  "$CHECK_INBOX"
else
  echo "check-inbox.sh not found at $CHECK_INBOX"
fi

printf '\n[3/4] Open GitHub issues (sane-apps org)\n'
if command -v gh >/dev/null 2>&1; then
  for repo in SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo; do
    echo "\n## $repo"
    gh issue list -R "sane-apps/${repo}" --state open --limit 10 || echo "  Unable to fetch issues for ${repo} (auth missing or no issues)."
  done
else
  echo "GitHub CLI (gh) not installed"
fi

printf '\n[4/4] Open GitHub PRs (sane-apps org)\n'
if command -v gh >/dev/null 2>&1; then
  for repo in SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo; do
    echo "\n## $repo"
    gh pr list -R "sane-apps/${repo}" --state open --limit 10 || echo "  Unable to fetch PRs for ${repo} (auth missing or no PRs)."
  done
else
  echo "GitHub CLI (gh) not installed"
fi

printf '\nDone.\n'
