#!/bin/bash
# Sync the Codex control-plane profile from the local machine to the Mac Mini.
# Automation records are deliberately outside this sync boundary: production
# automation mutations must go through Codex automation_update.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-control-plane.sh"

MINI_HOST="mini"
QUIET=0
RESTART_CODEX=0
DUMP_CONFIG=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet] [--restart]

Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
  $(basename "$0") mini --restart
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
    --no-restart)
      RESTART_CODEX=0
      shift
      ;;
    --restart)
      RESTART_CODEX=1
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
  printf 'RESTART_CODEX=%s\n' "$RESTART_CODEX"
  exit 0
fi

command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v scp >/dev/null 2>&1 || die "scp not found"
command -v rsync >/dev/null 2>&1 || die "rsync not found"

LOCAL_CODEX_DIR="$HOME/.codex"
LOCAL_CODEX_CONFIG="$LOCAL_CODEX_DIR/config.toml"
LOCAL_CODEX_BIN_DIR="$LOCAL_CODEX_DIR/bin"
LOCAL_CODEX_STANDALONE_BIN="$LOCAL_CODEX_DIR/packages/standalone/current/codex"
MIN_CODEX_CLI_VERSION="0.139.0"
REPO_CODEX_BIN_DIR="$HOME/SaneApps/infra/SaneProcess/scripts/codex-bin"
LOCAL_SKILLS_REGISTRY="$LOCAL_CODEX_DIR/SKILLS_REGISTRY.md"
LOCAL_SKILLS_DIR="$LOCAL_CODEX_DIR/skills"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
CODEX_BIN_FILES=(
  "check-mcps"
  "github-mcp-bridge.mjs"
  "xcode-mcpbridge-wrapper.sh"
)
CONTROL_PLANE_REL_FILES=(
  "SaneApps/infra/scripts/check-inbox.sh"
  "SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"
  "SaneApps/infra/SaneProcess/scripts/automation/reconcile-air-mini.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/mini/mini-reclaim-automation-windows.sh"
  "SaneApps/infra/SaneProcess/scripts/mini/mini-nightly.sh"
  "SaneApps/infra/SaneProcess/scripts/mini/mini-prepare-automation-root.sh"
  "SaneApps/infra/SaneProcess/scripts/validation_report.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb"
)

[[ -f "$LOCAL_CODEX_CONFIG" ]] || die "Missing local Codex config: $LOCAL_CODEX_CONFIG"
[[ -f "$LOCAL_SKILLS_REGISTRY" ]] || die "Missing local Codex skills registry: $LOCAL_SKILLS_REGISTRY"
[[ -d "$LOCAL_SKILLS_DIR" ]] || die "Missing local Codex skills dir: $LOCAL_SKILLS_DIR"
[[ -d "$REPO_CODEX_BIN_DIR" ]] || die "Missing repo Codex bin dir: $REPO_CODEX_BIN_DIR"

for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  [[ -f "$HOME/$rel" ]] || die "Missing control-plane file: $HOME/$rel"
done

for bin_name in "${CODEX_BIN_FILES[@]}"; do
  [[ -f "$REPO_CODEX_BIN_DIR/$bin_name" ]] || die "Missing repo Codex bin helper: $REPO_CODEX_BIN_DIR/$bin_name"
done

version_needs_update() {
  local version="$1"
  python3 - "$version" "$MIN_CODEX_CLI_VERSION" <<'PY'
import re
import sys

current = sys.argv[1]
minimum = sys.argv[2]

def parts(value):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())

current_parts = parts(current)
minimum_parts = parts(minimum)
if current_parts is None or minimum_parts is None or current_parts < minimum_parts:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

install_codex_standalone() {
  local installer
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX") || die "Could not create Codex installer temp file"
  if ! CODEX_NON_INTERACTIVE=1 curl --fail --show-error --silent --proto '=https' --tlsv1.2 --location --max-redirs 0 \
    --output "$installer" \
    https://chatgpt.com/codex/install.sh; then
    rm -f "$installer"
    return 1
  fi
  chmod 600 "$installer"
  if CODEX_NON_INTERACTIVE=1 sh "$installer"; then
    rm -f "$installer"
    return 0
  fi
  local status=$?
  rm -f "$installer"
  return "$status"
}

ensure_local_codex_standalone() {
  local current_version=""
  if [[ -x "$LOCAL_CODEX_STANDALONE_BIN" ]]; then
    current_version=$("$LOCAL_CODEX_STANDALONE_BIN" --version 2>/dev/null || true)
  fi

  if version_needs_update "$current_version"; then
    log "Installing/updating local Codex standalone CLI for app-server daemon..."
    install_codex_standalone
  fi
}

ensure_remote_codex_standalone() {
  ssh "$MINI_HOST" "MIN_CODEX_CLI_VERSION='$MIN_CODEX_CLI_VERSION' bash -s" <<'REMOTE'
set -euo pipefail

codex_bin="$HOME/.codex/packages/standalone/current/codex"
current_version=""
if [ -x "$codex_bin" ]; then
  current_version=$("$codex_bin" --version 2>/dev/null || true)
fi

needs_update=$(python3 - "$current_version" "$MIN_CODEX_CLI_VERSION" <<'PY'
import re
import sys

current = sys.argv[1]
minimum = sys.argv[2]

def parts(value):
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())

current_parts = parts(current)
minimum_parts = parts(minimum)
print("1" if current_parts is None or current_parts < minimum_parts else "0")
PY
)

install_codex_standalone() {
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX") || return 1
  if ! CODEX_NON_INTERACTIVE=1 curl --fail --show-error --silent --proto '=https' --tlsv1.2 --location --max-redirs 0 \
    --output "$installer" \
    https://chatgpt.com/codex/install.sh; then
    rm -f "$installer"
    return 1
  fi
  chmod 600 "$installer"
  if CODEX_NON_INTERACTIVE=1 sh "$installer"; then
    rm -f "$installer"
    return 0
  fi
  status=$?
  rm -f "$installer"
  return "$status"
}

if [ "$needs_update" = "1" ]; then
  install_codex_standalone
fi
REMOTE
}

sync_peer_home || die "Could not verify Mini identity"
sync_preserve_profile "$REMOTE_HOME/.codex/config.toml"
ensure_local_codex_standalone
ensure_remote_codex_standalone

# Keep local Codex guard wiring consistent too.
mkdir -p "$HOME/.local/bin"
mkdir -p "$LOCAL_CODEX_BIN_DIR"
sync_link_missing "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh" "$HOME/.local/bin/curl"
sync_link_missing "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh" "$HOME/.local/bin/ssh"
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  sync_copy_missing "$REPO_CODEX_BIN_DIR/$bin_name" "$LOCAL_CODEX_BIN_DIR/$bin_name"
  chmod +x "$LOCAL_CODEX_BIN_DIR/$bin_name"
done

log "Syncing Codex skill registry and skills to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/skills\""
sync_copy_missing "$LOCAL_SKILLS_REGISTRY" "$MINI_HOST:$REMOTE_HOME/.codex/SKILLS_REGISTRY.md"
sync_copy_missing "$LOCAL_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.codex/skills/"

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  log "Syncing shared agent skills to $MINI_HOST..."
  ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.agents/skills\""
  sync_copy_missing "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/"
fi

log "Syncing Codex control-plane helpers to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/bin\""
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  sync_copy_missing "$REPO_CODEX_BIN_DIR/$bin_name" "$MINI_HOST:$REMOTE_HOME/.codex/bin/$bin_name"
done

# Pre-push validation gate: never sync a check-inbox.sh that fails its contract
# suite, so Mini support workflows keep their last-known-good classifier route.
CHECK_INBOX_REL="SaneApps/infra/scripts/check-inbox.sh"
CHECK_INBOX_TEST="$HOME/SaneApps/infra/SaneProcess/scripts/automation/check_inbox_report_test.py"
if [[ -f "$CHECK_INBOX_TEST" ]]; then
  log "Validating check-inbox.sh against its contract suite before pushing..."
  if ! python3 "$CHECK_INBOX_TEST" >/tmp/check_inbox_gate.log 2>&1; then
    die "check-inbox.sh failed its contract suite; Mini copy preserved. See /tmp/check_inbox_gate.log"
  fi
fi

log "Syncing control-plane files to $MINI_HOST..."
for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  local_path="$HOME/$rel"
  remote_path="$REMOTE_HOME/$rel"
  remote_dir=$(dirname "$remote_path")
  ssh "$MINI_HOST" "mkdir -p \"$remote_dir\""
  sync_copy_missing "$local_path" "$MINI_HOST:$remote_path"
done

ssh "$MINI_HOST" "$(declare -f sync_link_missing)
  set -e
  mkdir -p $(printf '%q' "$REMOTE_HOME/.local/bin")
  sync_link_missing $(printf '%q' "$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh") $(printf '%q' "$REMOTE_HOME/.local/bin/curl")
  sync_link_missing $(printf '%q' "$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh") $(printf '%q' "$REMOTE_HOME/.local/bin/ssh")
" || die "Remote guard wiring differs or failed"

log "Verifying control-plane parity (Air ↔ Mini)..."
mismatches=0
for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  local_hash=$(shasum -a 256 "$HOME/$rel" | cut -d' ' -f1)
  remote_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/$rel\" | cut -d' ' -f1" 2>/dev/null || echo "")
  if [[ -z "$remote_hash" || "$local_hash" != "$remote_hash" ]]; then
    echo "MISMATCH: $rel" >&2
    mismatches=$((mismatches + 1))
  fi
done
if [[ "$mismatches" -gt 0 ]]; then
  die "Control-plane parity check failed ($mismatches mismatch(es))"
fi

local_registry_hash=$(shasum -a 256 "$LOCAL_SKILLS_REGISTRY" | cut -d' ' -f1)
remote_registry_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/.codex/SKILLS_REGISTRY.md\" | cut -d' ' -f1" 2>/dev/null || echo "")
[[ -n "$remote_registry_hash" && "$local_registry_hash" == "$remote_registry_hash" ]] || die "Codex skills registry parity check failed"

for bin_name in "${CODEX_BIN_FILES[@]}"; do
  local_bin_hash=$(shasum -a 256 "$REPO_CODEX_BIN_DIR/$bin_name" | cut -d' ' -f1)
  remote_bin_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/.codex/bin/$bin_name\" | cut -d' ' -f1" 2>/dev/null || echo "")
  [[ -n "$remote_bin_hash" && "$local_bin_hash" == "$remote_bin_hash" ]] || die "Codex bin parity check failed for $bin_name"
done

local_codex_cli=$("$HOME/.local/bin/codex" --version 2>/dev/null || true)
remote_codex_cli=$(ssh "$MINI_HOST" "\"$REMOTE_HOME/.local/bin/codex\" --version" 2>/dev/null || true)
[[ -n "$local_codex_cli" ]] || die "Local Codex CLI entrypoint is not usable"
[[ -n "$remote_codex_cli" ]] || die "Mini Codex CLI entrypoint is not usable"
case "$local_codex_cli" in
  *" 0.13"[0-8].*) die "Local Codex CLI is too old: $local_codex_cli" ;;
esac
case "$remote_codex_cli" in
  *" 0.13"[0-8].*) die "Mini Codex CLI is too old: $remote_codex_cli" ;;
esac

if [[ "$RESTART_CODEX" -eq 1 ]]; then
  log "Restarting Codex on $MINI_HOST to reload the control-plane profile..."
  ssh "$MINI_HOST" 'pkill -f "/Applications/Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 || true; sleep 1; open -ga Codex'
  sleep 3
fi

log ""
log "Codex shared files verified; Mini profile and peer-only files preserved."
log "File-backed memories use the separate conflict-preserving sync-memory-mini.sh lane."
log "Automation records were not inspected or changed; use automation_update for production mutations."
