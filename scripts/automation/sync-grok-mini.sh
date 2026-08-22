#!/bin/bash
# Sync SaneOps Grok automation config and active Grok-visible helpers from the
# local machine to the Mac mini.
# Mirrors the structure and safety model of sync-codex-mini.sh but for the
# Grok surface (lighter footprint on first pass).

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

LOCAL_GROK_DIR="$HOME/.grok"
LOCAL_GROK_BIN_DIR="$LOCAL_GROK_DIR/bin"
LOCAL_GROK_CONFIG="$LOCAL_GROK_DIR/config.toml"
REPO_GROK_BIN_DIR="$HOME/SaneApps/infra/SaneProcess/scripts/grok-bin"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
REPO_ROOT="$HOME/SaneApps/infra/SaneProcess"

log "Syncing Grok control-plane profile to $MINI_HOST..."

# Ensure repo grok-bin exists (the thing we actually keep in git)
[[ -d "$REPO_GROK_BIN_DIR" ]] || die "Missing repo grok-bin dir: $REPO_GROK_BIN_DIR"

# Overlay git-owned helpers onto ~/.grok/bin. Never --delete: the official Grok
# CLI binary/symlinks live here too, and --delete once wiped them.
mkdir -p "$LOCAL_GROK_BIN_DIR"
rsync -az "$REPO_GROK_BIN_DIR/" "$LOCAL_GROK_BIN_DIR/" || die "rsync of local grok-bin failed"
log "  + grok-bin helpers synced locally"

REPO_GROK_HOOKS="$REPO_ROOT/scripts/hooks/grok/hooks.json"
LOCAL_GROK_HOOKS_DIR="$LOCAL_GROK_DIR/hooks"
if [[ -f "$REPO_GROK_HOOKS" ]]; then
  mkdir -p "$LOCAL_GROK_HOOKS_DIR"
  rsync -az "$REPO_GROK_HOOKS" "$LOCAL_GROK_HOOKS_DIR/sane-guards.json" || die "rsync of local grok hooks failed"
  ssh "$MINI_HOST" "mkdir -p ~/.grok/hooks" 2>/dev/null || true
  rsync -az "$REPO_GROK_HOOKS" "$MINI_HOST:~/.grok/hooks/sane-guards.json" 2>/dev/null || log "  ! grok hooks rsync to mini (non-fatal if mini not reachable)"
  log "  + native Grok hooks synced locally and mirrored to mini"
fi

if [[ -f "$LOCAL_GROK_CONFIG" ]]; then
  ssh "$MINI_HOST" "mkdir -p ~/.grok" 2>/dev/null || true
  rsync -az "$LOCAL_GROK_CONFIG" "$MINI_HOST:~/.grok/config.toml" 2>/dev/null || log "  ! ~/.grok/config.toml rsync to mini failed (restart Grok after manual sync)"
  log "  + Grok native config mirrored to mini (where reachable)"
else
  log "  ! no local ~/.grok/config.toml found; sync_grok only mirrors helpers and skills"
fi

# Mirror .agents/skills (neutral SaneProcess skills) — these are what init.sh --client grok populates
if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  rsync -az --delete "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:~/.agents/skills/" 2>/dev/null || log "  ! .agents/skills rsync to mini (non-fatal if mini not reachable)"
  log "  + .agents/skills mirrored to mini (where present)"
fi

# Overlay helpers onto Mini ~/.grok/bin without deleting the Mini Grok CLI binary.
ssh "$MINI_HOST" "mkdir -p ~/.grok/bin" 2>/dev/null || true
rsync -az "$REPO_GROK_BIN_DIR/" "$MINI_HOST:~/.grok/bin/" 2>/dev/null || log "  ! grok-bin rsync to mini (non-fatal if mini not reachable)"
log "  + grok-bin mirrored to mini"

# Push a small set of universal SaneProcess scripts that Grok sessions commonly invoke
UNIVERSAL_SCRIPTS=(
  "scripts/SaneMaster.rb"
  "scripts/validation_report.rb"
  "scripts/hooks/sane_curl_guard.sh"
)
for rel in "${UNIVERSAL_SCRIPTS[@]}"; do
  if [[ -f "$REPO_ROOT/$rel" ]]; then
    rsync -az "$REPO_ROOT/$rel" "$MINI_HOST:~/SaneApps/infra/SaneProcess/$rel" 2>/dev/null || true
  fi
done
log "  + core SaneMaster + guards mirrored (best-effort)"

log ""
log "Grok profile sync complete (local + best-effort mini)."
log "On the Mini, ensure ~/.grok/bin is on PATH for Grok sessions."
log "Restart active Grok TUI sessions on target machines after config/helper changes."

# Note: full restart of Grok TUI processes on Mini is left to the operator (no reliable remote "killall grok" without side effects).
