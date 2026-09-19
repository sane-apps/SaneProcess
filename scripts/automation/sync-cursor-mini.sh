#!/bin/bash
# Sync Cursor controller hooks/skills and shared agent skills to the Mac Mini.
# Primary operator client is Cursor on the Air; Grok runs Mini heartbeats.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-control-plane.sh"

MINI_HOST="mini"
QUIET=0
DUMP_CONFIG=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet]
Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
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
  exit 0
fi

command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v rsync >/dev/null 2>&1 || die "rsync not found"

LOCAL_CURSOR_DIR="$HOME/.cursor"
LOCAL_CURSOR_HOOKS="$LOCAL_CURSOR_DIR/hooks"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
REPO_ROOT="$HOME/SaneApps/infra/SaneProcess"
REPO_CURSOR_HOOKS="$REPO_ROOT/scripts/hooks/cursor"

sync_peer_home || die "Could not verify Mini identity"
log "Checking Cursor control-plane files on $MINI_HOST..."
if [[ -f "$LOCAL_CURSOR_DIR/hooks.json" ]]; then
  sync_preserve_profile "$REMOTE_HOME/.cursor/hooks.json"
fi
ssh "$MINI_HOST" "mkdir -p ~/.agents/skills ~/.cursor/hooks"
if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  sync_copy_missing "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/"
fi
if [[ -d "$LOCAL_CURSOR_HOOKS" ]]; then
  sync_copy_missing "$LOCAL_CURSOR_HOOKS/" "$MINI_HOST:$REMOTE_HOME/.cursor/hooks/"
else
  sync_copy_missing "$REPO_CURSOR_HOOKS/" "$MINI_HOST:$REMOTE_HOME/.cursor/hooks/"
fi
UNIVERSAL_SCRIPTS=(
  "scripts/SaneMaster.rb"
  "scripts/validation_report.rb"
  "scripts/automation/recurring-jobs.md"
  "scripts/automation/install-recurring-agents.sh"
  "scripts/automation/agent-heartbeat.sh"
  "scripts/automation/run-app-review-watch.sh"
  "scripts/automation/run-x-opportunity-scout.sh"
  "scripts/hooks/sane_curl_guard.sh"
)
for rel in "${UNIVERSAL_SCRIPTS[@]}"; do
  if [[ -f "$REPO_ROOT/$rel" ]]; then
    sync_copy_missing "$REPO_ROOT/$rel" "$MINI_HOST:$REMOTE_HOME/SaneApps/infra/SaneProcess/$rel"
  fi
done
sync_copy_missing "$REPO_ROOT/scripts/automation/heartbeats/" "$MINI_HOST:$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/automation/heartbeats/"
log "Cursor shared files verified; Mini profile and peer-only files preserved."
