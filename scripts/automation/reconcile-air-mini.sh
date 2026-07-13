#!/bin/bash
# Reconcile canonical SaneApps repos across the local machine and the Mini.

set -euo pipefail

MINI_HOST="mini"
QUIET=0
SYNC_CONTROL_PLANE=1
DUMP_CONFIG=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet] [--no-sync-control-plane]

Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
  $(basename "$0") mini --no-sync-control-plane
  $(basename "$0") --dump-config
USAGE
}

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$@"
  fi
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --no-sync-control-plane)
      SYNC_CONTROL_PLANE=0
      shift
      ;;
    --dump-config)
      DUMP_CONFIG=1
      shift
      ;;
    --*)
      die "Unknown option: $1"
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done

if [[ "$DUMP_CONFIG" -eq 1 ]]; then
  printf 'MINI_HOST=%s\n' "$MINI_HOST"
  printf 'QUIET=%s\n' "$QUIET"
  printf 'SYNC_CONTROL_PLANE=%s\n' "$SYNC_CONTROL_PLANE"
  exit 0
fi

ROOT="$HOME/SaneApps/infra/SaneProcess"
SYNC_SCRIPT="$ROOT/scripts/automation/sync-codex-mini.sh"
GIT_SYNC_SCRIPT="$ROOT/scripts/automation/git-sync-safe.sh"

[[ -x "$GIT_SYNC_SCRIPT" ]] || die "Missing local sync script: $GIT_SYNC_SCRIPT"

if [[ "$SYNC_CONTROL_PLANE" -eq 1 ]]; then
  [[ -x "$SYNC_SCRIPT" ]] || die "Missing control-plane sync script: $SYNC_SCRIPT"
  log "1) Syncing control-plane files to $MINI_HOST..."
  bash "$SYNC_SCRIPT" "$MINI_HOST" --quiet --no-restart
fi

remote_home=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || die "Could not resolve $MINI_HOST home"
remote_git_sync="$remote_home/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"

log "2) Reconciling canonical repos on $MINI_HOST..."
ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" "bash \"$remote_git_sync\""

log "3) Reconciling canonical repos locally and verifying parity with $MINI_HOST..."
bash "$GIT_SYNC_SCRIPT" --peer "$MINI_HOST"

log "Air/Mini reconcile complete."
