#!/usr/bin/env bash
# Reap ephemeral agent dev/test servers (RAM discipline) — for DELIBERATE mid/end-session cleanup by the agent.
# The SessionStart hook (session_start_cleanup.rb) auto-reaps LEAKED ones across sessions; this is the manual
# "I'm done with my test servers now" tool. POSITIVE ALLOWLIST ONLY — narrow named test-harness signatures +
# the 8800-8899 QA static-server range — so it can never match a build (wrangler/npm/next/vite/xcodebuild/
# Docker) or a real app server. Scoped to the current user. DRY-RUN by default; pass --kill to act.
# Usage:  reap-dev-servers.sh            # list what would be reaped
#         reap-dev-servers.sh --kill     # reap them
set -uo pipefail

MODE="${1:-}"
# `-m http.server 88XX` is unambiguously python's stdlib dev server (robust to binary name/case).
PATTERN='(/dev/(mockserver|entserver)\.mjs)|(websites/[^/ ]+/dev/[^/ ]*server[^/ ]*\.mjs)|(-m http\.server 88[0-9][0-9])'

found=0
while IFS= read -r line; do
  pid="${line%% *}"
  cmd="${line#* }"
  # never match this script, a grep line, or anything without a pid
  case "$cmd" in *reap-dev-servers* | *grep*) continue ;; esac
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  if [[ "$cmd" =~ $PATTERN ]]; then
    found=$((found + 1))
    short="${cmd:0:90}"
    if [[ "$MODE" == "--kill" ]]; then
      if kill "$pid" 2>/dev/null; then
        echo "reaped  $pid  $short"
      else
        echo "failed  $pid  $short"
      fi
    else
      echo "would reap  $pid  $short"
    fi
  fi
done < <(ps -u "$(id -un)" -o pid=,command=)

if [[ "$found" -eq 0 ]]; then
  echo "no agent dev/test servers running"
elif [[ "$MODE" != "--kill" ]]; then
  echo "(dry run — pass --kill to reap these $found)"
fi
exit 0
