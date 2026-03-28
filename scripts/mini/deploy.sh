#!/bin/bash
# deploy.sh — Deploy mini scripts to the Mac mini build server
# Usage: bash scripts/mini/deploy.sh
#
# Copies the mini runtime scripts from this directory to the mini,
# verifies they arrived intact, and runs syntax checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_PRIMARY_DIR="~/SaneApps/infra/SaneProcess/scripts/mini"
REMOTE_LEGACY_DIR="~/SaneApps/infra/scripts"

echo "Deploying mini scripts to Mac mini..."

DEPLOYED=0
DEPLOY_FILES=(
  "$SCRIPT_DIR"/mini-*.sh
  "$SCRIPT_DIR"/evaluate_model.py
)

for script in "${DEPLOY_FILES[@]}"; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  echo "  $name"
  scp -q "$script" "mini:$REMOTE_PRIMARY_DIR/$name"
  ssh mini "if [ -d $REMOTE_LEGACY_DIR ]; then cp $REMOTE_PRIMARY_DIR/$name $REMOTE_LEGACY_DIR/$name; fi" >/dev/null 2>&1 || true
  DEPLOYED=$((DEPLOYED + 1))
done

echo ""
echo "Verifying on mini..."

# Syntax check all deployed scripts
ssh mini "
for f in $REMOTE_PRIMARY_DIR/mini-*.sh; do
  /bin/bash -n \"\$f\" && echo \"  OK: \$(basename \$f)\" || echo \"  FAIL: \$(basename \$f)\"
done
if [ -f $REMOTE_PRIMARY_DIR/evaluate_model.py ]; then
  python3 -m py_compile $REMOTE_PRIMARY_DIR/evaluate_model.py && echo \"  OK: evaluate_model.py\" || echo \"  FAIL: evaluate_model.py\"
fi
"

# Checksum comparison
echo ""
echo "Checksums (local → remote):"
for script in "${DEPLOY_FILES[@]}"; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  LOCAL_MD5=$(md5 -q "$script")
  REMOTE_MD5=$(ssh mini "md5 -q $REMOTE_PRIMARY_DIR/$name")
  if [ "$LOCAL_MD5" = "$REMOTE_MD5" ]; then
    echo "  $name: MATCH"
  else
    echo "  $name: MISMATCH (local=$LOCAL_MD5 remote=$REMOTE_MD5)"
  fi
done

echo ""
echo "Deployed $DEPLOYED scripts."

echo ""
echo "Preparing clean automation root on mini..."
PREPARE_FAILED=0
if ! ssh mini "if [ -f $REMOTE_PRIMARY_DIR/mini-prepare-automation-root.sh ]; then AUTOMATION_ROOT=\$HOME/SaneApps-automation SANE_SOURCE_ROOT=\$HOME/SaneApps bash $REMOTE_PRIMARY_DIR/mini-prepare-automation-root.sh; fi"; then
  PREPARE_FAILED=1
  echo "WARNING: automation root prep failed; continuing with agent refresh using the existing root." >&2
fi

echo ""
echo "Refreshing launch agents on mini..."
ssh mini "if [ -f $REMOTE_PRIMARY_DIR/mini-install-nightly-agent.sh ]; then NIGHTLY_HOUR=8 NIGHTLY_MINUTE=45 SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs bash $REMOTE_PRIMARY_DIR/mini-install-nightly-agent.sh; fi"
ssh mini "if [ -f $REMOTE_PRIMARY_DIR/mini-install-training-agents.sh ]; then SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs ENABLE_WEEKLY_TRAINING=true TRAIN_HARD_STOP_TIME=08:30 CHALLENGER_APP=SaneAI CHALLENGER_SELECTION_MODE=alternate CHALLENGER_ROTATION_ANCHOR_DATE=2026-03-12 CHALLENGER_ROTATION_ORDER=llama32-3b,smollm3-3b CHALLENGER_BUDGET_MIN=0 CHALLENGER_SKIP_WEEKDAY=0 RUN_CHALLENGERS_AFTER_WEEKLY=false WEEKLY_TRAIN_HOUR=1 WEEKLY_TRAIN_MINUTE=0 READINESS_TARGET_APP=SaneSync TRAIN_ALERT_NOTIFY=true TRAIN_EXAMPLE_DROP_MAX_PCT=20 VALID_EXAMPLE_DROP_MAX_PCT=20 bash $REMOTE_PRIMARY_DIR/mini-install-training-agents.sh; fi"
ssh mini "if [ -f $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh ]; then bash $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh; fi"

# Sync global Claude config (skills, commands, templates, CLAUDE.md)
echo ""
echo "Syncing global Claude config..."
bash "$SCRIPT_DIR/sync-claude-config.sh"

if [ "$PREPARE_FAILED" -ne 0 ]; then
  exit 1
fi
