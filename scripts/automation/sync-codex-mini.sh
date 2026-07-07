#!/bin/bash
# Sync SaneOps Codex automation config and active Codex skill metadata from the
# local machine to the Mac mini. Local role: paused (no duplicate runs). Mini
# role now mirrors that safe paused state by default so reconcile/start-workday
# cannot silently re-enable background runs. Explicit activation is opt-in.

set -euo pipefail

MINI_HOST="mini"
QUIET=0
RESTART_CODEX=1
REMOTE_AM_STATUS="PAUSED"
REMOTE_PM_STATUS="PAUSED"
DUMP_CONFIG=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet] [--no-restart]

Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
  $(basename "$0") mini --no-restart
  $(basename "$0") mini --activate-mini-runs
  $(basename "$0") mini --activate-mini-am
  $(basename "$0") mini --activate-mini-pm
  $(basename "$0") mini --pause-mini-am
  $(basename "$0") mini --pause-mini-pm
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
    --activate-mini-runs)
      REMOTE_AM_STATUS="ACTIVE"
      REMOTE_PM_STATUS="ACTIVE"
      shift
      ;;
    --activate-mini-am)
      REMOTE_AM_STATUS="ACTIVE"
      shift
      ;;
    --activate-mini-pm)
      REMOTE_PM_STATUS="ACTIVE"
      shift
      ;;
    --pause-mini-am)
      REMOTE_AM_STATUS="PAUSED"
      shift
      ;;
    --pause-mini-pm)
      REMOTE_PM_STATUS="PAUSED"
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
  printf 'REMOTE_AM_STATUS=%s\n' "$REMOTE_AM_STATUS"
  printf 'REMOTE_PM_STATUS=%s\n' "$REMOTE_PM_STATUS"
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
LOCAL_AM="$LOCAL_CODEX_DIR/automations/saneops-am-run/automation.toml"
LOCAL_PM="$LOCAL_CODEX_DIR/automations/saneops-pm-run/automation.toml"
LOCAL_DB="$LOCAL_CODEX_DIR/sqlite/codex-dev.db"
LOCAL_SKILLS_REGISTRY="$LOCAL_CODEX_DIR/SKILLS_REGISTRY.md"
LOCAL_SKILLS_DIR="$LOCAL_CODEX_DIR/skills"
LOCAL_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
LOCAL_KNOWLEDGE_GRAPH="$HOME/.claude/memory/knowledge-graph.jsonl"
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

[[ -f "$LOCAL_AM" ]] || die "Missing local automation file: $LOCAL_AM"
[[ -f "$LOCAL_PM" ]] || die "Missing local automation file: $LOCAL_PM"
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

ensure_local_codex_standalone

# Keep local Codex guard wiring consistent too.
mkdir -p "$HOME/.local/bin"
mkdir -p "$LOCAL_CODEX_BIN_DIR"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh" "$HOME/.local/bin/curl"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh" "$HOME/.local/bin/ssh"
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  cp "$REPO_CODEX_BIN_DIR/$bin_name" "$LOCAL_CODEX_BIN_DIR/$bin_name"
  chmod +x "$LOCAL_CODEX_BIN_DIR/$bin_name"
done

set_status_in_file() {
  local file="$1"
  local status="$2"
  perl -0pi -e "s/^status = \"[^\"]*\"/status = \"${status}\"/m" "$file"
}

# Local machine should never run these automatically.
set_status_in_file "$LOCAL_AM" "PAUSED"
set_status_in_file "$LOCAL_PM" "PAUSED"

if [[ -f "$LOCAL_DB" ]]; then
  sqlite3 "$LOCAL_DB" "
    UPDATE automations SET status='PAUSED', updated_at=(strftime('%s','now')*1000) WHERE id='saneops-am-run';
    UPDATE automations SET status='PAUSED', updated_at=(strftime('%s','now')*1000) WHERE id='saneops-pm-run';
  " >/dev/null 2>&1 || true
fi

REMOTE_HOME=$(ssh -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || die "Could not reach $MINI_HOST"
REMOTE_NODE=$(ssh -o ConnectTimeout=8 "$MINI_HOST" 'command -v node') || die "Could not resolve node on $MINI_HOST"
ensure_remote_codex_standalone

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_CONFIG="$TMP_DIR/config.toml"
TMP_AM="$TMP_DIR/saneops-am-run.toml"
TMP_PM="$TMP_DIR/saneops-pm-run.toml"
cp "$LOCAL_CODEX_CONFIG" "$TMP_CONFIG"
cp "$LOCAL_AM" "$TMP_AM"
cp "$LOCAL_PM" "$TMP_PM"

rewrite_paths() {
  local file="$1"
  python3 - "$file" "$HOME" "$REMOTE_HOME" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
local_home = sys.argv[2].rstrip("/")
remote_home = sys.argv[3].rstrip("/")
text = path.read_text(encoding="utf-8")
text = text.replace(local_home, remote_home)
path.write_text(text, encoding="utf-8")
PY
}

rewrite_codex_config() {
  local file="$1"
  local remote_node="$2"
  python3 - "$file" "$remote_node" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
remote_node = sys.argv[2]
text = path.read_text(encoding="utf-8")
text = re.sub(r'^command = ".*node"$', f'command = "{remote_node}"', text, flags=re.MULTILINE)
path.write_text(text, encoding="utf-8")
PY
}

rewrite_paths "$TMP_CONFIG"
rewrite_codex_config "$TMP_CONFIG" "$REMOTE_NODE"
rewrite_paths "$TMP_AM"
rewrite_paths "$TMP_PM"

# Mini role: active unattended runner unless explicitly paused.
set_status_in_file "$TMP_AM" "$REMOTE_AM_STATUS"
set_status_in_file "$TMP_PM" "$REMOTE_PM_STATUS"

log "Syncing SaneOps automation files to $MINI_HOST..."
scp -q "$TMP_AM" "$TMP_PM" "$MINI_HOST:$REMOTE_HOME/"

log "Syncing Codex skill registry and skills to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/skills\""
scp -q "$TMP_CONFIG" "$MINI_HOST:$REMOTE_HOME/.codex/config.toml"
scp -q "$LOCAL_SKILLS_REGISTRY" "$MINI_HOST:$REMOTE_HOME/.codex/SKILLS_REGISTRY.md"
rsync -a --delete "$LOCAL_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.codex/skills/"

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  log "Syncing shared agent skills to $MINI_HOST..."
  ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.agents/skills\""
  rsync -a --delete "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/"
fi

log "Syncing Codex control-plane helpers to $MINI_HOST..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.codex/bin\""
for bin_name in "${CODEX_BIN_FILES[@]}"; do
  scp -q "$REPO_CODEX_BIN_DIR/$bin_name" "$MINI_HOST:$REMOTE_HOME/.codex/bin/$bin_name"
done

if [[ -f "$LOCAL_KNOWLEDGE_GRAPH" ]]; then
  log "Seeding knowledge graph cache on $MINI_HOST..."
  ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.claude/memory\""
  scp -q "$LOCAL_KNOWLEDGE_GRAPH" "$MINI_HOST:$REMOTE_HOME/.claude/memory/knowledge-graph.jsonl"
fi

# Pre-push validation gate: never sync a check-inbox.sh that fails its contract
# suite, so the always-on Mini auto-close automation can't run a broken script.
CHECK_INBOX_REL="SaneApps/infra/scripts/check-inbox.sh"
CHECK_INBOX_TEST="$HOME/SaneApps/infra/SaneProcess/scripts/automation/check_inbox_report_test.py"
SKIP_CHECK_INBOX=0
if [[ -f "$CHECK_INBOX_TEST" ]]; then
  log "Validating check-inbox.sh against its contract suite before pushing..."
  if ! python3 "$CHECK_INBOX_TEST" >/tmp/check_inbox_gate.log 2>&1; then
    SKIP_CHECK_INBOX=1
    printf '⚠️  check-inbox.sh FAILED its contract suite — NOT pushing it to %s (Mini keeps last-good copy). See /tmp/check_inbox_gate.log\n' "$MINI_HOST" >&2
  fi
fi

log "Syncing control-plane files to $MINI_HOST..."
for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  if [[ "$rel" == "$CHECK_INBOX_REL" && "$SKIP_CHECK_INBOX" -eq 1 ]]; then
    log "Skipping $rel (failed pre-push validation; Mini keeps last-good copy)"
    continue
  fi
  local_path="$HOME/$rel"
  remote_path="$REMOTE_HOME/$rel"
  remote_dir=$(dirname "$remote_path")
  ssh "$MINI_HOST" "mkdir -p \"$remote_dir\""
  scp -q "$local_path" "$MINI_HOST:$remote_path"
done

ssh "$MINI_HOST" "
  set -e
  mkdir -p \"$REMOTE_HOME/.codex/automations/saneops-am-run\" \"$REMOTE_HOME/.codex/automations/saneops-pm-run\"
  cp \"$REMOTE_HOME/saneops-am-run.toml\" \"$REMOTE_HOME/.codex/automations/saneops-am-run/automation.toml\"
  cp \"$REMOTE_HOME/saneops-pm-run.toml\" \"$REMOTE_HOME/.codex/automations/saneops-pm-run/automation.toml\"
  chmod +x \"$REMOTE_HOME/.codex/bin/check-mcps\"
  chmod +x \"$REMOTE_HOME/.codex/bin/github-mcp-bridge.mjs\"
  chmod +x \"$REMOTE_HOME/.codex/bin/xcode-mcpbridge-wrapper.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/scripts/check-inbox.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/automation/reconcile-air-mini.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-nightly.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-prepare-automation-root.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/validation_report.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb\"
  mkdir -p \"$REMOTE_HOME/.local/bin\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh\" \"$REMOTE_HOME/.local/bin/curl\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_ssh_guard.sh\" \"$REMOTE_HOME/.local/bin/ssh\"
  rm -f \"$REMOTE_HOME/saneops-am-run.toml\" \"$REMOTE_HOME/saneops-pm-run.toml\"
" || die "Remote copy failed"

ssh "$MINI_HOST" python3 - "$REMOTE_HOME" <<'PY'
import sqlite3
import sys
import time
from pathlib import Path

remote_home = Path(sys.argv[1])
db_path = remote_home / ".codex/sqlite/codex-dev.db"
am_path = remote_home / ".codex/automations/saneops-am-run/automation.toml"
pm_path = remote_home / ".codex/automations/saneops-pm-run/automation.toml"

if not db_path.exists():
    raise SystemExit(f"Missing automation DB: {db_path}")


def parse_toml(path: Path):
    data = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if key in {"id", "name", "prompt", "status", "rrule"}:
            if value.startswith('"') and value.endswith('"'):
                data[key] = value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        elif key == "cwds":
            data[key] = value
    missing = [k for k in ("id", "name", "prompt", "status", "rrule", "cwds") if k not in data]
    if missing:
        raise ValueError(f"{path}: missing keys {missing}")
    return data


def upsert(conn: sqlite3.Connection, data: dict):
    now_ms = int(time.time() * 1000)
    existing = conn.execute(
        "SELECT 1 FROM automations WHERE id = ?",
        (data["id"],),
    ).fetchone()

    if existing:
        conn.execute(
            """
            UPDATE automations
               SET name = ?,
                   prompt = ?,
                   status = ?,
                   cwds = ?,
                   rrule = ?,
                   updated_at = ?
             WHERE id = ?
            """,
            (
                data["name"],
                data["prompt"],
                data["status"],
                data["cwds"],
                data["rrule"],
                now_ms,
                data["id"],
            ),
        )
    else:
        conn.execute(
            """
            INSERT INTO automations
              (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, created_at, updated_at)
            VALUES
              (?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)
            """,
            (
                data["id"],
                data["name"],
                data["prompt"],
                data["status"],
                data["cwds"],
                data["rrule"],
                now_ms,
                now_ms,
            ),
        )


am = parse_toml(am_path)
pm = parse_toml(pm_path)

conn = sqlite3.connect(str(db_path))
try:
    upsert(conn, am)
    upsert(conn, pm)
    conn.commit()
finally:
    conn.close()
PY

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

local_config_hash=$(shasum -a 256 "$TMP_CONFIG" | cut -d' ' -f1)
remote_config_hash=$(ssh "$MINI_HOST" "shasum -a 256 \"$REMOTE_HOME/.codex/config.toml\" | cut -d' ' -f1" 2>/dev/null || echo "")
[[ -n "$remote_config_hash" && "$local_config_hash" == "$remote_config_hash" ]] || die "Codex config parity check failed"

skills_dry_run=$(rsync -a --delete --checksum --dry-run "$LOCAL_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.codex/skills/" 2>/dev/null || true)
if [[ -n "${skills_dry_run//[[:space:]]/}" ]]; then
  echo "$skills_dry_run" >&2
  die "Codex skills parity check failed"
fi

if [[ -d "$LOCAL_AGENTS_SKILLS_DIR" ]]; then
  agents_skills_dry_run=$(rsync -a --delete --checksum --dry-run "$LOCAL_AGENTS_SKILLS_DIR/" "$MINI_HOST:$REMOTE_HOME/.agents/skills/" 2>/dev/null || true)
  if [[ -n "${agents_skills_dry_run//[[:space:]]/}" ]]; then
    echo "$agents_skills_dry_run" >&2
    die "Shared agent skills parity check failed"
  fi
fi

if [[ "$RESTART_CODEX" -eq 1 ]]; then
  log "Restarting Codex on $MINI_HOST to reload automation definitions..."
  ssh "$MINI_HOST" 'pkill -f "/Applications/Codex.app/Contents/MacOS/Codex" >/dev/null 2>&1 || true; sleep 1; open -ga Codex'
  sleep 3
fi

log ""
log "Local status (should be paused):"
grep -n '^name\|^status\|^rrule' "$LOCAL_AM" "$LOCAL_PM"

log ""
log "Mini status files:"
ssh "$MINI_HOST" "grep -n '^name\\|^status\\|^rrule' \"$REMOTE_HOME/.codex/automations/saneops-am-run/automation.toml\" \"$REMOTE_HOME/.codex/automations/saneops-pm-run/automation.toml\""

log ""
log "Mini scheduler DB:"
ssh "$MINI_HOST" "sqlite3 -header -column \"$REMOTE_HOME/.codex/sqlite/codex-dev.db\" \"SELECT id,name,status,datetime(next_run_at/1000,'unixepoch','localtime') AS next_run_local, datetime(last_run_at/1000,'unixepoch','localtime') AS last_run_local FROM automations;\""

log ""
if [[ "$REMOTE_AM_STATUS" == "ACTIVE" && "$REMOTE_PM_STATUS" == "ACTIVE" ]]; then
  log "Done. Mini AM and PM automations are ACTIVE; local automations remain paused."
elif [[ "$REMOTE_AM_STATUS" == "ACTIVE" ]]; then
  log "Done. Mini AM automation is ACTIVE and Mini PM is PAUSED; local automations remain paused."
elif [[ "$REMOTE_PM_STATUS" == "ACTIVE" ]]; then
  log "Done. Mini PM automation is ACTIVE and Mini AM is PAUSED; local automations remain paused."
else
  log "Done. Mini AM and PM automations are PAUSED; local automations remain paused."
fi
