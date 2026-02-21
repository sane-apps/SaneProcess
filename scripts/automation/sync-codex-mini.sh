#!/bin/bash
# Sync SaneOps Codex automation config from local machine to Mac mini.
# Local role: paused (no duplicate runs). Mini role: AM active, PM paused.

set -euo pipefail

MINI_HOST="mini"
QUIET=0
RESTART_CODEX=1

usage() {
  cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet] [--no-restart]

Examples:
  $(basename "$0")
  $(basename "$0") mini --quiet
  $(basename "$0") mini --no-restart
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
    --*)
      die "Unknown option: $1"
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done

command -v ssh >/dev/null 2>&1 || die "ssh not found"
command -v scp >/dev/null 2>&1 || die "scp not found"

LOCAL_CODEX_DIR="$HOME/.codex"
LOCAL_AM="$LOCAL_CODEX_DIR/automations/saneops-am-run/automation.toml"
LOCAL_PM="$LOCAL_CODEX_DIR/automations/saneops-pm-run/automation.toml"
LOCAL_DB="$LOCAL_CODEX_DIR/sqlite/codex-dev.db"
CONTROL_PLANE_REL_FILES=(
  "SaneApps/infra/scripts/check-inbox.sh"
  "SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"
  "SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh"
  "SaneApps/infra/SaneProcess/scripts/validation_report.rb"
  "SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb"
  "SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb"
)

[[ -f "$LOCAL_AM" ]] || die "Missing local automation file: $LOCAL_AM"
[[ -f "$LOCAL_PM" ]] || die "Missing local automation file: $LOCAL_PM"

for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
  [[ -f "$HOME/$rel" ]] || die "Missing control-plane file: $HOME/$rel"
done

# Keep local Codex guard wiring consistent too.
mkdir -p "$HOME/.local/bin"
ln -sfn "$HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh" "$HOME/.local/bin/curl"

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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

TMP_AM="$TMP_DIR/saneops-am-run.toml"
TMP_PM="$TMP_DIR/saneops-pm-run.toml"
cp "$LOCAL_AM" "$TMP_AM"
cp "$LOCAL_PM" "$TMP_PM"

rewrite_paths() {
  local file="$1"
  python3 - "$file" "$HOME" "$REMOTE_HOME" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
local_home = sys.argv[2].rstrip("/") + "/"
remote_home = sys.argv[3].rstrip("/") + "/"
text = path.read_text(encoding="utf-8")
text = text.replace(local_home, remote_home)
path.write_text(text, encoding="utf-8")
PY
}

rewrite_paths "$TMP_AM"
rewrite_paths "$TMP_PM"

# Mini role: AM active, PM paused.
set_status_in_file "$TMP_AM" "ACTIVE"
set_status_in_file "$TMP_PM" "PAUSED"

log "Syncing SaneOps automation files to $MINI_HOST..."
scp -q "$TMP_AM" "$TMP_PM" "$MINI_HOST:$REMOTE_HOME/"

log "Syncing control-plane files to $MINI_HOST..."
for rel in "${CONTROL_PLANE_REL_FILES[@]}"; do
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
  chmod +x \"$REMOTE_HOME/SaneApps/infra/scripts/check-inbox.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/validation_report.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/sanemaster/meta.rb\"
  chmod +x \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/sanemaster/verify.rb\"
  mkdir -p \"$REMOTE_HOME/.local/bin\"
  ln -sfn \"$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/hooks/sane_curl_guard.sh\" \"$REMOTE_HOME/.local/bin/curl\"
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
log "Done. Mini is the active runner; local automations remain paused."
