#!/bin/bash
# Install Mini LaunchAgents for Cursor+Grok recurring jobs.
# Run on the Mac Mini only.

set -euo pipefail

if [[ "$(hostname -s)" != "Stephans-Mac-mini" && "$(hostname)" != "mini.local" ]]; then
  echo "WARNING: expected Mac Mini; continuing because hostname=$(hostname)" >&2
fi

ROOT="$HOME/SaneApps/infra/SaneProcess"
AGENTS_DIR="$HOME/Library/LaunchAgents"
OUT="$HOME/SaneApps/outputs/recurring-agents"

chmod +x \
  "$ROOT/scripts/automation/run-app-review-watch.sh" \
  "$ROOT/scripts/automation/run-x-opportunity-scout.sh" \
  "$ROOT/scripts/automation/agent-heartbeat.sh" \
  "$ROOT/scripts/automation/pause-codex-heartbeats.sh"

mkdir -p "$AGENTS_DIR" "$OUT"

# App + CWS review watch — every 15 minutes
python3 - <<'PY'
import plistlib, pathlib
root = pathlib.Path.home() / "SaneApps/infra/SaneProcess"
out = pathlib.Path.home() / "SaneApps/outputs/recurring-agents"
out.mkdir(parents=True, exist_ok=True)
data = {
    "Label": "com.saneapps.app-review-watch",
    "ProgramArguments": ["/bin/bash", str(root / "scripts/automation/run-app-review-watch.sh")],
    "StartInterval": 900,
    "RunAtLoad": False,
    "StandardOutPath": str(out / "app-review-watch.stdout.log"),
    "StandardErrorPath": str(out / "app-review-watch.stderr.log"),
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    },
}
path = pathlib.Path.home() / "Library/LaunchAgents/com.saneapps.app-review-watch.plist"
with path.open("wb") as fh:
    plistlib.dump(data, fh)
print(path)
PY
launchctl bootout "gui/$(id -u)/com.saneapps.app-review-watch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS_DIR/com.saneapps.app-review-watch.plist"

heartbeat_plist() {
  local label="$1"
  local id="$2"
  local hour="$3"
  local minute="$4"
  local prompt="$ROOT/scripts/automation/heartbeats/${id}.md"
  [[ -f "$prompt" ]] || { echo "missing prompt: $prompt" >&2; exit 1; }
  python3 - "$label" "$id" "$hour" "$minute" "$ROOT" "$OUT" <<'PY'
import plistlib, pathlib, sys
label, job_id, hour, minute, root, out = sys.argv[1:7]
root = pathlib.Path(root)
out = pathlib.Path(out)
out.mkdir(parents=True, exist_ok=True)
data = {
    "Label": label,
    "ProgramArguments": [
        "/bin/bash",
        str(root / "scripts/automation/agent-heartbeat.sh"),
        "--id", job_id,
        "--prompt-file", str(root / "scripts/automation/heartbeats" / f"{job_id}.md"),
        "--cwd", str(root),
    ],
    "StartCalendarInterval": {"Hour": int(hour), "Minute": int(minute)},
    "RunAtLoad": False,
    "StandardOutPath": str(out / f"{job_id}.stdout.log"),
    "StandardErrorPath": str(out / f"{job_id}.stderr.log"),
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    },
}
path = pathlib.Path.home() / "Library/LaunchAgents" / f"{label}.plist"
with path.open("wb") as fh:
    plistlib.dump(data, fh)
print(path)
PY
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS_DIR/${label}.plist"
  echo "installed ${label}"
}

heartbeat_plist com.saneapps.agent-heartbeat.launch-ops saneapps-launch-ops 8 30
heartbeat_plist com.saneapps.agent-heartbeat.prophecy-ledger prophecy-ledger-transcript-batch-resume 20 20
launchctl bootout "gui/$(id -u)/com.saneapps.x-opportunity-scout" 2>/dev/null || true
leftover_scout="$AGENTS_DIR/com.saneapps.x-opportunity-scout.plist"
if [[ -f "$leftover_scout" ]]; then
  if command -v trash >/dev/null 2>&1; then
    trash "$leftover_scout"
  else
    mkdir -p "$HOME/.Trash"
    mv "$leftover_scout" "$HOME/.Trash/com.saneapps.x-opportunity-scout.plist"
  fi
  echo "removed leftover $leftover_scout"
fi
heartbeat_plist com.saneapps.agent-heartbeat.x-scout sanelot-x-opportunity-scout 10 0

python3 - <<'PY'
import plistlib, pathlib
root = pathlib.Path.home() / "SaneApps/infra/SaneProcess"
out = pathlib.Path.home() / "SaneApps/outputs/recurring-agents"
job_id = "saneapps-ga-llc-annual-registration-reminder"
data = {
    "Label": "com.saneapps.agent-heartbeat.ga-llc",
    "ProgramArguments": [
        "/bin/bash",
        str(root / "scripts/automation/agent-heartbeat.sh"),
        "--id", job_id,
        "--prompt-file", str(root / "scripts/automation/heartbeats" / f"{job_id}.md"),
        "--cwd", str(root),
    ],
    "StartCalendarInterval": {"Month": 1, "Day": 6, "Hour": 9, "Minute": 7},
    "RunAtLoad": False,
    "StandardOutPath": str(out / f"{job_id}.stdout.log"),
    "StandardErrorPath": str(out / f"{job_id}.stderr.log"),
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    },
}
path = pathlib.Path.home() / "Library/LaunchAgents/com.saneapps.agent-heartbeat.ga-llc.plist"
with path.open("wb") as fh:
    plistlib.dump(data, fh)
print(path)
PY
launchctl bootout "gui/$(id -u)/com.saneapps.agent-heartbeat.ga-llc" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS_DIR/com.saneapps.agent-heartbeat.ga-llc.plist"

bash "$ROOT/scripts/automation/pause-codex-heartbeats.sh"

echo "Recurring Mini LaunchAgents installed. See scripts/automation/recurring-jobs.md"
