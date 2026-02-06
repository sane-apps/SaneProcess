#!/bin/bash
# nv-readme-check.sh - Check if README reflects shipped features
# Usage: nv-readme-check.sh [path-to-repo] [--since TAG_OR_DATE]
#
# Compares recent features (from git log) against README.md and flags gaps.
# Uses nv (free AI) to detect undocumented features.
# Designed as a pre-release gate: run before tagging a new version.

set -euo pipefail

NV_BIN="/Users/sj/.local/bin/nv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
REPO_PATH="${1:-.}"
SINCE=""
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -x "$NV_BIN" ]]; then
  echo "Error: nv CLI not found at $NV_BIN" >&2
  exit 1
fi

cd "$REPO_PATH"

if [[ ! -d ".git" ]]; then
  echo "Error: Not a git repository" >&2
  exit 1
fi

REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

# Determine comparison range
if [[ -n "$SINCE" ]]; then
  RANGE="$SINCE..HEAD"
elif git describe --tags --abbrev=0 >/dev/null 2>&1; then
  LATEST_TAG=$(git describe --tags --abbrev=0)
  RANGE="$LATEST_TAG..HEAD"
else
  # No tags — use last 30 days
  RANGE="$(git log --since='30 days ago' --format=%H | tail -1)..HEAD"
fi

echo "Checking README sync for: $REPO_NAME"
echo "Range: $RANGE"
echo ""

# Collect feature commits (filter out chore/docs/ci)
FEATURE_COMMITS=$(git log --oneline --no-merges "$RANGE" 2>/dev/null | grep -iE '^[a-f0-9]+ (feat|fix|add|update|improve|implement|enable|support)' || true)

if [[ -z "$FEATURE_COMMITS" ]]; then
  echo "No feature commits found in range. README is up to date."
  exit 0
fi

COMMIT_COUNT=$(echo "$FEATURE_COMMITS" | wc -l | tr -d ' ')
echo "Found $COMMIT_COUNT feature commits to check against README."
echo ""

# Read README
README_FILE=""
for candidate in README.md readme.md Readme.md; do
  if [[ -f "$candidate" ]]; then
    README_FILE="$candidate"
    break
  fi
done

if [[ -z "$README_FILE" ]]; then
  echo "WARNING: No README.md found in $REPO_NAME"
  echo "Feature commits not reflected anywhere:"
  echo "$FEATURE_COMMITS"
  exit 2
fi

README_CONTENT=$(cat "$README_FILE")

# Also check CHANGELOG if it exists
CHANGELOG=""
for candidate in CHANGELOG.md changelog.md CHANGES.md; do
  if [[ -f "$candidate" ]]; then
    CHANGELOG=$(head -100 "$candidate")
    break
  fi
done

# Build the prompt
PROMPT="You are a documentation auditor. Compare these recent feature commits against the README content below.

TASK: List any features from the commits that are NOT mentioned or reflected in the README.
Only flag genuine gaps — if a commit is a bug fix or internal refactoring, it doesn't need README mention.
Features that users would care about MUST be in the README.

OUTPUT FORMAT:
- If all features are documented: print ONLY 'README_CURRENT'
- If gaps exist, print each gap as:
  GAP: [commit summary] -> [suggested README section]

Be strict: undocumented user-facing features are gaps. Internal changes are not.

COMMITS:
$FEATURE_COMMITS

README ($README_FILE):
$README_CONTENT"

if [[ -n "$CHANGELOG" ]]; then
  PROMPT="$PROMPT

CHANGELOG (first 100 lines):
$CHANGELOG"
fi

# Run through nv
echo "Analyzing with nv..."
echo ""

RESULT=$("$NV_BIN" "$PROMPT" 2>/dev/null || echo "ERROR: nv query failed")

if echo "$RESULT" | grep -q "README_CURRENT"; then
  echo "README is up to date with all shipped features."
  exit 0
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "README GAPS DETECTED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "$RESULT"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Run before release: update $README_FILE with the gaps above."
exit 1
