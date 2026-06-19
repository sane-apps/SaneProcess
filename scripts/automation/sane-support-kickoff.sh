#!/usr/bin/env bash
set -euo pipefail

CHECK_INBOX="${CHECK_INBOX:-${HOME}/SaneApps/infra/scripts/check-inbox.sh}"

printf '\nSane support kickoff (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

if [[ -x "$CHECK_INBOX" ]]; then
  REPORT_TMP=$(mktemp /tmp/sane_support_kickoff_XXXXXX)
  trap 'rm -f "$REPORT_TMP"' EXIT
  "$CHECK_INBOX" | tee "$REPORT_TMP"
  echo
  echo 'High-signal support items:'
  python3 - "$REPORT_TMP" <<'PY'
import sys

path = sys.argv[1]
include_markers = (
    "POSITIVE FEEDBACK",
    "BOUNCED OUTBOUND",
    "NEEDS REPLY",
    "AUTO-REPLIED ONLY",
    "ESCALATE TO USER",
    "NEEDS REVIEW BEFORE RESOLVE",
    "REPLIED — PENDING CONFIRMATION",
    "RESOLVED HIGH-VALUE HISTORY",
)
stop_markers = (
    "LOW-RISK",
    "Total:",
    "GITHUB ISSUES",
    "ACTIONS",
)

printing = False
for line in open(path, encoding="utf-8", errors="replace"):
    stripped = line.strip()
    if any(marker in stripped for marker in stop_markers):
        if printing:
            print()
        printing = False
    if any(marker in stripped for marker in include_markers):
        printing = True
    if printing:
        print(line, end="")
PY
else
  echo "check-inbox.sh not found at $CHECK_INBOX"
fi

printf '\nDone.\n'
