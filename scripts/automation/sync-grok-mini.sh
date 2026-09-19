#!/bin/bash
# Sync SaneOps Grok automation config and active Grok-visible helpers from the
# local machine to the Mac mini.
# Mirrors the structure and safety model of sync-codex-mini.sh but for the
# Grok surface (lighter footprint on first pass).

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

LOCAL_GROK_DIR="$HOME/.grok"
LOCAL_GROK_BIN_DIR="$LOCAL_GROK_DIR/bin"
LOCAL_GROK_CONFIG="$LOCAL_GROK_DIR/config.toml"
REPO_GROK_BIN_DIR="$HOME/SaneApps/infra/SaneProcess/scripts/grok-bin"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
REPO_ROOT="$HOME/SaneApps/infra/SaneProcess"

[[ -d "$REPO_GROK_BIN_DIR" ]] || die "Missing repo grok-bin dir: $REPO_GROK_BIN_DIR"
sync_peer_home || die "Could not verify Mini identity"
if [[ -f "$LOCAL_GROK_CONFIG" ]]; then
  sync_preserve_profile "$REMOTE_HOME/.grok/config.toml"
fi
mkdir -p "$LOCAL_GROK_BIN_DIR"
sync_copy_missing "$REPO_GROK_BIN_DIR/" "$LOCAL_GROK_BIN_DIR/"
ssh "$MINI_HOST" "mkdir -p ~/.agents/skills ~/.grok/bin"
if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  sync_copy_missing "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/"
fi
sync_copy_missing "$REPO_GROK_BIN_DIR/" "$MINI_HOST:$REMOTE_HOME/.grok/bin/"
# Preserve the native Grok hook adapter previously installed by the Air lane.
if [[ -f "$REPO_ROOT/scripts/hooks/grok/hooks.json" ]]; then
  (
    hook_stage=$(mktemp -d "${TMPDIR:-/tmp}/sane-grok-hooks.XXXXXX")
    trap 'rm -f "$hook_stage/sane-guards.json"; rmdir "$hook_stage"' EXIT
    cp "$REPO_ROOT/scripts/hooks/grok/hooks.json" "$hook_stage/sane-guards.json"
    mkdir -p "$LOCAL_GROK_DIR/hooks"
    ssh "$MINI_HOST" "mkdir -p ~/.grok/hooks"
    sync_copy_missing "$hook_stage/sane-guards.json" "$LOCAL_GROK_DIR/hooks/sane-guards.json"
    sync_copy_missing "$hook_stage/sane-guards.json" "$MINI_HOST:$REMOTE_HOME/.grok/hooks/sane-guards.json"
  )
fi
UNIVERSAL_SCRIPTS=(
  "scripts/SaneMaster.rb"
  "scripts/validation_report.rb"
  "scripts/hooks/sane_curl_guard.sh"
)
for rel in "${UNIVERSAL_SCRIPTS[@]}"; do
  if [[ -f "$REPO_ROOT/$rel" ]]; then
    sync_copy_missing "$REPO_ROOT/$rel" "$MINI_HOST:$REMOTE_HOME/SaneApps/infra/SaneProcess/$rel"
  fi
done
log "Grok shared files verified; Mini profile and peer-only files preserved."
