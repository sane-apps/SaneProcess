#!/bin/bash
# Reconcile canonical SaneApps repos across the local machine and the Mini.

set -euo pipefail

MINI_HOST="mini"
QUIET=0
SYNC_CONTROL_PLANE=0
DUMP_CONFIG=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet] [--sync-control-plane]

Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
  $(basename "$0") mini --sync-control-plane
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
    --sync-control-plane)
      SYNC_CONTROL_PLANE=1
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

remote_home=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || die "Could not resolve $MINI_HOST home"
remote_git_sync="$remote_home/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"

log "1) Capturing non-mutating dirty-work snapshots on both hosts..."
issues=0
ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" "bash \"$remote_git_sync\" --snapshot-only" || issues=$((issues + 1))
bash "$GIT_SYNC_SCRIPT" --snapshot-only || issues=$((issues + 1))

remote_host=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'hostname -s 2>/dev/null || hostname' 2>/dev/null || echo mini)
snapshot_dest="$ROOT/outputs/peer-dirty-backups/$remote_host"
mkdir -p "$snapshot_dest"
rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=8" \
  "$MINI_HOST:$remote_home/SaneApps/infra/SaneProcess/outputs/dirty-work-snapshots/" \
  "$snapshot_dest/" 2>/dev/null || true

if [[ "$issues" -gt 0 ]]; then
  die "Air/Mini reconcile could not capture $issues dirty-work snapshot group(s); no repo or control-plane mutation performed"
fi

log "2) Reconciling canonical repos on $MINI_HOST..."
issues=0
ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" "bash \"$remote_git_sync\"" || issues=$((issues + 1))

log "3) Reconciling canonical repos locally and verifying parity with $MINI_HOST..."
bash "$GIT_SYNC_SCRIPT" --peer "$MINI_HOST" || issues=$((issues + 1))

if [[ "$issues" -gt 0 ]]; then
  die "Air/Mini reconcile preserved dirty-work snapshots but found $issues repo issue group(s)"
fi

if [[ "$SYNC_CONTROL_PLANE" -eq 1 ]]; then
  [[ -x "$SYNC_SCRIPT" ]] || die "Missing control-plane sync script: $SYNC_SCRIPT"
  log "4) Syncing the reviewed control-plane after clean Git reconciliation..."
  bash "$SYNC_SCRIPT" "$MINI_HOST" --quiet --no-restart
fi
log "Air/Mini reconcile complete."
