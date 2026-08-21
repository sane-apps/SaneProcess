#!/bin/bash
# Canonical GET-only App Store + Chrome Web Store review watchers.
# Replaces the former Codex heartbeat `saneapps-app-review-watch`.
# Emails on state transitions; never mutates store state.
# App Store and Chrome Web Store run independently so one store's
# failure cannot skip the other store's email.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

ROOT="$HOME/SaneApps/infra/SaneProcess"
OUT_DIR="$HOME/SaneApps/outputs/app-review-watch"
LOCK_DIR="$OUT_DIR/.lock"
LOG="$OUT_DIR/run.log"
RUBY="${SANEPROCESS_RUBY:-/opt/homebrew/opt/ruby/bin/ruby}"

mkdir -p "$OUT_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Iseconds) skip: prior run still holds lock" >>"$LOG"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

echo "== $(date -Iseconds) app-review-watch ==" >>"$LOG"

asc=0
cws=0
"$RUBY" "$ROOT/scripts/automation/app_review_watch.rb" >>"$LOG" 2>&1 || asc=$?
"$RUBY" "$ROOT/scripts/automation/cws_review_watch.rb" >>"$LOG" 2>&1 || cws=$?

if [ "$asc" -ne 0 ]; then
  echo "$(date -Iseconds) app_review_watch.rb exit $asc" >>"$LOG"
fi
if [ "$cws" -ne 0 ]; then
  echo "$(date -Iseconds) cws_review_watch.rb exit $cws" >>"$LOG"
fi

if [ "$asc" -ne 0 ] || [ "$cws" -ne 0 ]; then
  exit 1
fi
