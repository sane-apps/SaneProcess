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
MINI_HOST="${MINI_HOST:-mini}"
MINI_SSH_OPTS="${MINI_SSH_OPTS:-}"
ENABLE_MINI_TRAINING_AGENTS="${ENABLE_MINI_TRAINING_AGENTS:-0}"
MINI_SSH_ARGS=()

if [ -n "$MINI_SSH_OPTS" ]; then
  old_ifs="$IFS"
  IFS=' '
  set -- $MINI_SSH_OPTS
  IFS="$old_ifs"
  while [ "$#" -gt 0 ]; do
    MINI_SSH_ARGS[${#MINI_SSH_ARGS[@]}]="$1"
    shift
  done
fi

mini_ssh() {
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    ssh "${MINI_SSH_ARGS[@]}" "$MINI_HOST" "$@"
  else
    ssh "$MINI_HOST" "$@"
  fi
}

mini_scp() {
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    scp -q "${MINI_SSH_ARGS[@]}" "$1" "$MINI_HOST:$2"
  else
    scp -q "$1" "$MINI_HOST:$2"
  fi
}

mini_ping() {
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    ssh "${MINI_SSH_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$MINI_HOST" 'printf ok'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MINI_HOST" 'printf ok'
  fi
}

echo "Deploying mini scripts to Mac mini..."

if ! mini_ping >/dev/null 2>&1; then
  echo "ERROR: Could not reach Mini host '$MINI_HOST'. Set MINI_HOST=user@host and MINI_SSH_OPTS if the ssh alias or key is unavailable." >&2
  exit 1
fi

DEPLOYED=0
DEPLOY_FILES=(
  "$SCRIPT_DIR"/mini-*.sh
  "$SCRIPT_DIR"/evaluate_model.py
)

for script in "${DEPLOY_FILES[@]}"; do
  [ -f "$script" ] || continue
  name=$(basename "$script")
  echo "  $name"
  mini_scp "$script" "$REMOTE_PRIMARY_DIR/$name"
  mini_ssh "if [ -d $REMOTE_LEGACY_DIR ]; then cp $REMOTE_PRIMARY_DIR/$name $REMOTE_LEGACY_DIR/$name; fi" >/dev/null 2>&1 || true
  DEPLOYED=$((DEPLOYED + 1))
done

echo ""
echo "Verifying on mini..."

# Syntax check all deployed scripts
mini_ssh "
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
  REMOTE_MD5=$(mini_ssh "md5 -q $REMOTE_PRIMARY_DIR/$name")
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
if ! mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-prepare-automation-root.sh ]; then AUTOMATION_ROOT=\$HOME/SaneApps-automation SANE_SOURCE_ROOT=\$HOME/SaneApps bash $REMOTE_PRIMARY_DIR/mini-prepare-automation-root.sh; fi"; then
  PREPARE_FAILED=1
  echo "WARNING: automation root prep failed; continuing with agent refresh using the existing root." >&2
fi

echo ""
echo "Refreshing launch agents on mini..."
mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-install-nightly-agent.sh ]; then NIGHTLY_HOUR=8 NIGHTLY_MINUTE=45 SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs bash $REMOTE_PRIMARY_DIR/mini-install-nightly-agent.sh; fi"
if [ "$ENABLE_MINI_TRAINING_AGENTS" = "1" ]; then
  mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-install-training-agents.sh ]; then SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs ENABLE_WEEKLY_TRAINING=true TRAIN_HARD_STOP_TIME=09:00 CHALLENGER_APP=SaneAI CHALLENGER_SELECTION_MODE=alternate CHALLENGER_ROTATION_ANCHOR_DATE=2026-05-02 CHALLENGER_ROTATION_ORDER=llama32-3b CHALLENGER_BUDGET_MIN=0 CHALLENGER_SKIP_WEEKDAY=0 RUN_CHALLENGERS_AFTER_WEEKLY=false CHALLENGER_HOUR=23 CHALLENGER_MINUTE=0 WEEKLY_TRAIN_HOUR=23 WEEKLY_TRAIN_MINUTE=0 READINESS_TARGET_APP=SaneSync TRAIN_ALERT_NOTIFY=true TRAIN_EXAMPLE_DROP_MAX_PCT=20 VALID_EXAMPLE_DROP_MAX_PCT=20 TRAINING_MODE_APP_QUIT_LIST=Xcode,SaneBar,SaneClick,SaneClip,SaneHosts,SaneSales,SaneSync,SaneVideo,Shottr,MenuMeters,gfxCardStatus,Safari bash $REMOTE_PRIMARY_DIR/mini-install-training-agents.sh; fi"
else
  echo "Skipped training agent refresh (set ENABLE_MINI_TRAINING_AGENTS=1 to re-enable)."
fi
mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh ]; then bash $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh; fi"

echo ""
echo "Skipped legacy Claude global-config sync."
echo "Use scripts/automation/sync-codex-mini.sh for the active Codex control-plane sync path."

if [ "$PREPARE_FAILED" -ne 0 ]; then
  exit 1
fi
