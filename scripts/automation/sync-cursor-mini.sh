#!/bin/bash
# Sync Cursor controller hooks/skills and shared agent skills to the Mac Mini.
# Primary operator client is Cursor on the Air; Grok runs Mini heartbeats.

set -euo pipefail

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

log "Syncing Cursor control-plane profile to $MINI_HOST..."

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  rsync -az --delete "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:~/.agents/skills/" \
    2>/dev/null || log "  ! .agents/skills rsync to mini (non-fatal if mini not reachable)"
  log "  + .agents/skills mirrored to mini"
fi

if [[ -d "$LOCAL_CURSOR_HOOKS" ]]; then
  ssh "$MINI_HOST" "mkdir -p ~/.cursor/hooks" 2>/dev/null || true
  rsync -az "$LOCAL_CURSOR_HOOKS/" "$MINI_HOST:~/.cursor/hooks/" \
    2>/dev/null || log "  ! ~/.cursor/hooks rsync to mini (non-fatal)"
  log "  + Cursor hook adapters mirrored to mini"
else
  ssh "$MINI_HOST" "mkdir -p ~/.cursor/hooks" 2>/dev/null || true
  rsync -az "$REPO_CURSOR_HOOKS/" "$MINI_HOST:~/.cursor/hooks/" \
    2>/dev/null || log "  ! repo cursor hooks rsync to mini (non-fatal)"
  log "  + repo Cursor hook adapters mirrored to mini (no local ~/.cursor/hooks)"
fi

if [[ -f "$LOCAL_CURSOR_DIR/hooks.json" ]]; then
  rsync -az "$LOCAL_CURSOR_DIR/hooks.json" "$MINI_HOST:~/.cursor/hooks.json" \
    2>/dev/null || log "  ! ~/.cursor/hooks.json rsync failed (non-fatal)"
  log "  + Cursor hooks.json mirrored when present"
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
    rsync -az "$REPO_ROOT/$rel" "$MINI_HOST:~/SaneApps/infra/SaneProcess/$rel" 2>/dev/null || true
  fi
done
rsync -az "$REPO_ROOT/scripts/automation/heartbeats/" "$MINI_HOST:~/SaneApps/infra/SaneProcess/scripts/automation/heartbeats/" 2>/dev/null || true
log "  + recurring automation scripts mirrored (best-effort)"

log ""
log "Cursor profile sync complete (best-effort mini)."
log "Cursor Automations remain UI-owned on the controller; Mini recurring jobs use LaunchAgents (see recurring-jobs.md)."
