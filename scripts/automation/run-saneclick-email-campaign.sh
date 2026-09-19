#!/bin/bash
# Weekday SaneClick E2/E3 morning drip. Python only — does not remount Email 1.
set -euo pipefail
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
CAMPAIGN_DIR="${SANECLICK_CAMPAIGN_DIR:-$HOME/SaneApps/outputs/saneclick-apollo-2026-08-28/campaign}"
OUT_DIR="$HOME/SaneApps/outputs/recurring-agents"
LOCK_DIR="$OUT_DIR/saneclick-email-campaign.lock"
LOG="$OUT_DIR/saneclick-email-campaign.run.log"
ENV_FILE="${SANECLICK_ENV_FILE:-$HOME/.config/nv/env}"
mkdir -p "$OUT_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Iseconds) skip: prior SaneClick email run still holds lock" >>"$LOG"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
{
  echo "== $(date -Iseconds) saneclick-email-campaign =="
  /usr/bin/python3 "$CAMPAIGN_DIR/drip_morning.py" --send
} >>"$LOG" 2>&1
