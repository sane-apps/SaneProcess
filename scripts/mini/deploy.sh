#!/bin/bash
# deploy.sh — Deploy mini scripts to the Mac mini build server
# Usage: bash scripts/mini/deploy.sh
#
# Copies all mini-*.sh scripts from this directory to the mini,
# verifies they arrived intact, and runs a syntax check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="~/SaneApps/infra/scripts"

echo "Deploying mini scripts to Mac mini..."

DEPLOYED=0
for script in "$SCRIPT_DIR"/mini-*.sh; do
  name=$(basename "$script")
  echo "  $name"
  scp -q "$script" "mini:$REMOTE_DIR/$name"
  DEPLOYED=$((DEPLOYED + 1))
done

echo ""
echo "Verifying on mini..."

# Syntax check all deployed scripts
ssh mini "for f in $REMOTE_DIR/mini-*.sh; do /bin/bash -n \"\$f\" && echo \"  OK: \$(basename \$f)\" || echo \"  FAIL: \$(basename \$f)\"; done"

# Checksum comparison
echo ""
echo "Checksums (local → remote):"
for script in "$SCRIPT_DIR"/mini-*.sh; do
  name=$(basename "$script")
  LOCAL_MD5=$(md5 -q "$script")
  REMOTE_MD5=$(ssh mini "md5 -q $REMOTE_DIR/$name")
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
ssh mini "if [ -f $REMOTE_DIR/mini-prepare-automation-root.sh ]; then AUTOMATION_ROOT=\$HOME/SaneApps-automation SANE_SOURCE_ROOT=\$HOME/SaneApps bash $REMOTE_DIR/mini-prepare-automation-root.sh; fi"

echo ""
echo "Refreshing launch agents on mini..."
ssh mini "if [ -f $REMOTE_DIR/mini-install-nightly-agent.sh ]; then SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs bash $REMOTE_DIR/mini-install-nightly-agent.sh; fi"
ssh mini "if [ -f $REMOTE_DIR/mini-install-training-agents.sh ]; then SANE_ROOT=\$HOME/SaneApps-automation SANE_OUTPUT_DIR=\$HOME/SaneApps/outputs bash $REMOTE_DIR/mini-install-training-agents.sh; fi"
ssh mini "if [ -f $REMOTE_DIR/mini-install-memory-guard.sh ]; then bash $REMOTE_DIR/mini-install-memory-guard.sh; fi"

# Sync global Claude config (skills, commands, templates, CLAUDE.md)
echo ""
echo "Syncing global Claude config..."
bash "$SCRIPT_DIR/sync-claude-config.sh"
