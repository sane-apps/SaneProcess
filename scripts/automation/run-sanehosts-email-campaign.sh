#!/bin/bash
# Weekday SaneHosts 12-week sender. Python only — does not depend on Grok.
# Empty-day exit 2 is a real failure, not a quiet skip.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

ROOT="$HOME/SaneApps/infra/SaneProcess"
CAMPAIGN_DIR="${SANEHOSTS_CAMPAIGN_DIR:-$HOME/SaneApps/outputs/sanehosts-apollo-2026-08-27/campaign}"
OUT_DIR="$HOME/SaneApps/outputs/recurring-agents"
LOCK_DIR="$OUT_DIR/sanehosts-email-campaign.lock"
LOG="$OUT_DIR/sanehosts-email-campaign.run.log"
SCRIPT="$ROOT/scripts/automation/sanehosts_email_campaign.py"
ENV_FILE="${SANEHOSTS_ENV_FILE:-$HOME/.config/nv/env}"

mkdir -p "$OUT_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Iseconds) skip: prior SaneHosts email run still holds lock" >>"$LOG"
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
  echo "== $(date -Iseconds) sanehosts-email-campaign =="
  /usr/bin/python3 "$SCRIPT" --dir "$CAMPAIGN_DIR" --send
} >>"$LOG" 2>&1
