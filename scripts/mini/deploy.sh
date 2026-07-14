#!/bin/bash
# deploy.sh — Deploy mini scripts to the Mac mini build server
# Usage: bash scripts/mini/deploy.sh [--local]
#
# Copies the mini runtime scripts from this directory to the mini,
# verifies they arrived intact, and runs syntax checks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_PRIMARY_DIR="~/SaneApps/infra/SaneProcess/scripts/mini"
REMOTE_LEGACY_DIR="~/SaneApps/infra/scripts"
MINI_HOST="${MINI_HOST:-mini}"
MINI_SSH_OPTS="${MINI_SSH_OPTS:-}"
MINI_SSH_ARGS=()
LOCAL_MODE=0

case "${1:-}" in
  --local)
    LOCAL_MODE=1
    shift
    ;;
  "") ;;
  *)
    echo "Usage: bash scripts/mini/deploy.sh [--local]" >&2
    exit 64
    ;;
esac

if [ "$LOCAL_MODE" -eq 1 ]; then
  REMOTE_PRIMARY_DIR="$SCRIPT_DIR"
fi

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
  if [ "$LOCAL_MODE" -eq 1 ]; then
    /bin/bash -lc "$*"
    return
  fi
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    ssh "${MINI_SSH_ARGS[@]}" "$MINI_HOST" "$@"
  else
    ssh "$MINI_HOST" "$@"
  fi
}

mini_scp() {
  if [ "$LOCAL_MODE" -eq 1 ]; then
    return
  fi
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    scp -q "${MINI_SSH_ARGS[@]}" "$1" "$MINI_HOST:$2"
  else
    scp -q "$1" "$MINI_HOST:$2"
  fi
}

mini_ping() {
  if [ "$LOCAL_MODE" -eq 1 ]; then
    printf ok
    return
  fi
  if [ "${#MINI_SSH_ARGS[@]}" -gt 0 ]; then
    ssh "${MINI_SSH_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=5 "$MINI_HOST" 'printf ok'
  else
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$MINI_HOST" 'printf ok'
  fi
}

configure_local_login_keychain() {
  [ "$LOCAL_MODE" -eq 1 ] || return 0

  keychain="$HOME/Library/Keychains/login.keychain-db"
  echo ""
  echo "Configuring the login keychain for unattended SSH sessions..."
  echo "macOS may ask once for your login password; the script never reads or stores it."
  security unlock-keychain "$keychain"
  security set-keychain-settings "$keychain"
  security show-keychain-info "$keychain"
}

if [ "$LOCAL_MODE" -eq 1 ]; then
  echo "Deploying Mini services locally (no self-SSH)..."
else
  echo "Deploying mini scripts to Mac mini over SSH..."
fi

if ! mini_ping >/dev/null 2>&1; then
  echo "ERROR: Could not reach Mini host '$MINI_HOST'. Set MINI_HOST=user@host and MINI_SSH_OPTS if the ssh alias or key is unavailable." >&2
  exit 1
fi

DEPLOYED=0
DEPLOY_FILES=(
  "$SCRIPT_DIR"/mini-*.sh
)

is_retired_training_file() {
  case "$(basename "$1")" in
    mini-install-training-agents.sh|mini-train-all.sh|mini-train-challengers.sh|mini-train.sh|mini-training-mode.sh)
      return 0 ;;
    *) return 1 ;;
  esac
}

for script in "${DEPLOY_FILES[@]}"; do
  [ -f "$script" ] || continue
  is_retired_training_file "$script" && continue
  name=$(basename "$script")
  echo "  $name"
  if [ "$LOCAL_MODE" -eq 0 ]; then
    mini_scp "$script" "$REMOTE_PRIMARY_DIR/$name"
    mini_ssh "if [ -d $REMOTE_LEGACY_DIR ]; then cp $REMOTE_PRIMARY_DIR/$name $REMOTE_LEGACY_DIR/$name; fi" >/dev/null 2>&1 || true
  fi
  DEPLOYED=$((DEPLOYED + 1))
done

echo ""
echo "Verifying on mini..."

mini_ssh '
uid=$(id -u)
for label in com.saneapps.training com.saneapps.training-daily-check com.saneapps.training-challengers com.saneapps.training-weekly com.saneapps.saneai-weekend-training-watchdog com.saneapps.nv-benchmark; do
  launchctl disable "gui/$uid/$label" 2>/dev/null || true
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ ! -e "$plist" ] || /usr/bin/trash "$plist"
done
for path in "$HOME/SaneApps-automation/apps/SaneAI" "$HOME/SaneApps-automation/apps/SaneSync"; do
  [ ! -e "$path" ] || /usr/bin/trash "$path"
done
'

# Syntax check all deployed scripts
mini_ssh "
for f in $REMOTE_PRIMARY_DIR/mini-*.sh; do
  case \"\$(basename \"\$f\")\" in mini-install-training-agents.sh|mini-train-all.sh|mini-train-challengers.sh|mini-train.sh|mini-training-mode.sh) continue ;; esac
  /bin/bash -n \"\$f\" && echo \"  OK: \$(basename \$f)\" || echo \"  FAIL: \$(basename \$f)\"
done
"

# Checksum comparison
echo ""
echo "Checksums (local → remote):"
for script in "${DEPLOY_FILES[@]}"; do
  [ -f "$script" ] || continue
  is_retired_training_file "$script" && continue
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
echo "Training agents are retired and are never installed by deploy.sh."
mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh ]; then bash $REMOTE_PRIMARY_DIR/mini-install-memory-guard.sh; fi"
mini_ssh "if [ -f $REMOTE_PRIMARY_DIR/mini-install-weekly-restart.sh ]; then bash $REMOTE_PRIMARY_DIR/mini-install-weekly-restart.sh; fi"
configure_local_login_keychain

echo ""
echo "Skipped legacy Claude global-config sync."
echo "Use scripts/automation/sync-codex-mini.sh for the active Codex control-plane sync path."

if [ "$PREPARE_FAILED" -ne 0 ]; then
  exit 1
fi
