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

# Sync global Claude config (skills, commands, templates, CLAUDE.md)
echo ""
echo "Syncing global Claude config..."
bash "$SCRIPT_DIR/sync-claude-config.sh"
