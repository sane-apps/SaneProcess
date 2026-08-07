#!/bin/bash
# Sync the Grok-visible SaneProcess surface through the canonical reviewed
# Air/Mini control-plane contract. Host-native Grok config remains host-owned.

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

REPO_ROOT="$HOME/SaneApps/infra/SaneProcess"
REPO_GROK_BIN_DIR="$REPO_ROOT/scripts/grok-bin"
LOCAL_GROK_DIR="$HOME/.grok"
LOCAL_GROK_BIN_DIR="$LOCAL_GROK_DIR/bin"
SHARED_SYNC="${SANE_GROK_SHARED_SYNC:-$REPO_ROOT/scripts/automation/sync-codex-mini.sh}"
SSH="${SANE_GROK_SSH_BIN:-ssh}"
RSYNC="${SANE_GROK_RSYNC_BIN:-rsync}"

[[ -x "$SHARED_SYNC" ]] || die "Missing canonical control-plane sync: $SHARED_SYNC"
[[ -d "$REPO_GROK_BIN_DIR" ]] || die "Missing repo grok-bin dir: $REPO_GROK_BIN_DIR"
command -v "$SSH" >/dev/null 2>&1 || die "ssh not found: $SSH"
command -v "$RSYNC" >/dev/null 2>&1 || die "rsync not found: $RSYNC"

# The canonical sync owns same-HEAD, clean-peer, reviewed-dirty, preimage,
# shared-skill, guard, and failure semantics. Grok must not grow a second,
# incompatible copy of that policy.
shared_args=("$MINI_HOST" "--no-restart")
if [[ "$QUIET" -eq 1 ]]; then
  shared_args[${#shared_args[@]}]="--quiet"
fi
"$SHARED_SYNC" "${shared_args[@]}" || \
  die "Canonical control-plane sync refused or failed; Grok helper promotion was not attempted"

REMOTE_HOME=$("$SSH" -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || \
  die "Could not resolve $MINI_HOST home"
[[ -n "$REMOTE_HOME" ]] || die "Peer home is empty"

RUN_TAG="$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$LOCAL_GROK_DIR"
LOCAL_STAGE=$(mktemp -d "$LOCAL_GROK_DIR/.bin-stage.XXXXXX") || die "Could not create local Grok stage"
LOCAL_OLD="$LOCAL_GROK_DIR/.bin-old-$RUN_TAG"
LOCAL_BACKUP="$LOCAL_GROK_DIR/backups/bin-$RUN_TAG"
REMOTE_GROK_DIR="$REMOTE_HOME/.grok"
REMOTE_STAGE="$REMOTE_GROK_DIR/.bin-stage-$RUN_TAG"
REMOTE_OLD="$REMOTE_GROK_DIR/.bin-old-$RUN_TAG"
REMOTE_BACKUP="$REMOTE_GROK_DIR/backups/bin-$RUN_TAG"
LOCAL_PROMOTED=0

preserve_failed_local_stage() {
  local failed="$LOCAL_GROK_DIR/failed-bin-$RUN_TAG"
  if [[ -d "$LOCAL_STAGE" ]]; then
    mv "$LOCAL_STAGE" "$failed" 2>/dev/null || true
  fi
}

rollback_local_promotion() {
  local failed="$LOCAL_GROK_DIR/failed-bin-$RUN_TAG"
  if [[ "$LOCAL_PROMOTED" -eq 1 && -d "$LOCAL_GROK_BIN_DIR" ]]; then
    mv "$LOCAL_GROK_BIN_DIR" "$failed" 2>/dev/null || true
  fi
  if [[ -d "$LOCAL_OLD" ]]; then
    mv "$LOCAL_OLD" "$LOCAL_GROK_BIN_DIR" 2>/dev/null || true
  fi
  LOCAL_PROMOTED=0
}

fail_before_promotion() {
  preserve_failed_local_stage
  die "$1"
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ "$status" -ne 0 && "$LOCAL_PROMOTED" -eq 1 ]]; then
    rollback_local_promotion
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

if [[ -d "$LOCAL_GROK_BIN_DIR" ]]; then
  cp -Rp "$LOCAL_GROK_BIN_DIR/." "$LOCAL_STAGE/"
fi
"$RSYNC" -a "$REPO_GROK_BIN_DIR/" "$LOCAL_STAGE/" || \
  fail_before_promotion "Could not stage local Grok helpers"

# Build the peer stage from its current directory first so peer-only helpers are
# retained. Only the hidden stage is touched until every copy succeeds.
if ! "$SSH" -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" \
  "STAGE='$REMOTE_STAGE' DEST='$REMOTE_GROK_DIR/bin' /bin/bash -s" <<'REMOTE_PREP'
set -euo pipefail
mkdir -p "$(dirname "$STAGE")" "$STAGE"
if [ -d "$DEST" ]; then
  cp -Rp "$DEST/." "$STAGE/"
fi
REMOTE_PREP
then
  fail_before_promotion "Could not prepare peer Grok helper stage"
fi

if ! "$RSYNC" -a "$REPO_GROK_BIN_DIR/" "$MINI_HOST:$REMOTE_STAGE/"; then
  fail_before_promotion "Could not stage peer Grok helpers; live helper directories are unchanged"
fi

stage_delta=$("$RSYNC" -a --checksum --dry-run "$REPO_GROK_BIN_DIR/" "$MINI_HOST:$REMOTE_STAGE/" 2>/dev/null) || \
  fail_before_promotion "Could not verify peer Grok helper stage"
[[ -z "${stage_delta//[[:space:]]/}" ]] || \
  fail_before_promotion "Peer Grok helper stage does not match canonical files"

# Promote locally while retaining the old directory until the peer promotion
# succeeds. A peer promotion error restores the exact local predecessor.
if [[ -d "$LOCAL_GROK_BIN_DIR" ]]; then
  mv "$LOCAL_GROK_BIN_DIR" "$LOCAL_OLD" || fail_before_promotion "Could not preserve local Grok helpers"
fi
if ! mv "$LOCAL_STAGE" "$LOCAL_GROK_BIN_DIR"; then
  [[ ! -d "$LOCAL_OLD" ]] || mv "$LOCAL_OLD" "$LOCAL_GROK_BIN_DIR" 2>/dev/null || true
  die "Could not promote local Grok helpers"
fi
LOCAL_PROMOTED=1

if ! "$SSH" -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" \
  "STAGE='$REMOTE_STAGE' DEST='$REMOTE_GROK_DIR/bin' OLD='$REMOTE_OLD' BACKUP='$REMOTE_BACKUP' /bin/bash -s" <<'REMOTE_PROMOTE'
set -euo pipefail
rollback() {
  if [ ! -e "$DEST" ] && [ -d "$OLD" ]; then
    mv "$OLD" "$DEST" 2>/dev/null || true
  fi
}
trap rollback EXIT
if [ -d "$DEST" ]; then
  mv "$DEST" "$OLD"
fi
mv "$STAGE" "$DEST"
mkdir -p "$(dirname "$BACKUP")"
if [ -d "$OLD" ]; then
  mv "$OLD" "$BACKUP"
fi
trap - EXIT
REMOTE_PROMOTE
then
  rollback_local_promotion
  die "Peer Grok helper promotion failed; local helpers were restored"
fi

# Both live directories now contain the staged overlay. From this point a
# process interruption must retain the matching pair, not roll back one host.
LOCAL_PROMOTED=0

if [[ -d "$LOCAL_OLD" ]]; then
  mkdir -p "$(dirname "$LOCAL_BACKUP")"
  mv "$LOCAL_OLD" "$LOCAL_BACKUP"
fi

final_delta=$("$RSYNC" -a --checksum --dry-run "$REPO_GROK_BIN_DIR/" "$MINI_HOST:$REMOTE_GROK_DIR/bin/" 2>/dev/null) || \
  die "Could not verify installed peer Grok helpers"
[[ -z "${final_delta//[[:space:]]/}" ]] || die "Installed peer Grok helpers do not match canonical files"

trap - EXIT INT TERM

log "Grok control plane synchronized through the canonical safety gate."
log "Grok helper overlays were staged and promoted without deleting peer-only files."
log "Host-managed ~/.grok/config.toml files were not copied or changed."
