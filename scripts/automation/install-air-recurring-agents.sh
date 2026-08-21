#!/bin/bash
# Air-side LaunchAgents that replace leftover Codex/Claude scheduled jobs.
# Run on the MacBook Air only.

set -euo pipefail

host="$(hostname -s 2>/dev/null || hostname)"
if [[ "$host" == *[Mm]ini* ]]; then
  echo "Refusing Air recurring-agent install on Mini host $host" >&2
  exit 2
fi

ROOT="$HOME/SaneApps/infra/SaneProcess"
AGENTS_DIR="$HOME/Library/LaunchAgents"
OUT="$HOME/SaneApps/outputs/recurring-agents"
RUBY="/opt/homebrew/opt/ruby/bin/ruby"

chmod +x \
  "$ROOT/scripts/automation/run-sanecite-monday-sweep.sh" \
  "$ROOT/scripts/automation/run-sanebar-macos27-watch.sh"

mkdir -p "$AGENTS_DIR" "$OUT"

python3 - <<PY
import plistlib, pathlib
root = pathlib.Path("$ROOT")
out = pathlib.Path("$OUT")
home = pathlib.Path.home()
env = {
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "HOME": str(home),
}
jobs = [
    {
        "Label": "com.saneapps.sanecite-monday-sweep",
        "ProgramArguments": ["/bin/bash", str(root / "scripts/automation/run-sanecite-monday-sweep.sh"), "--email"],
        "StartCalendarInterval": {"Weekday": 1, "Hour": 7, "Minute": 0},
        "stdout": "sanecite-monday-sweep.stdout.log",
        "stderr": "sanecite-monday-sweep.stderr.log",
    },
    {
        "Label": "com.saneapps.sanebar-macos27-watch",
        "ProgramArguments": ["/bin/bash", str(root / "scripts/automation/run-sanebar-macos27-watch.sh")],
        "StartCalendarInterval": {"Hour": 9, "Minute": 0},
        "stdout": "sanebar-macos27-watch.stdout.log",
        "stderr": "sanebar-macos27-watch.stderr.log",
    },
]
for job in jobs:
    data = {
        "Label": job["Label"],
        "ProgramArguments": job["ProgramArguments"],
        "StartCalendarInterval": job["StartCalendarInterval"],
        "RunAtLoad": False,
        "Nice": 10,
        "StandardOutPath": str(out / job["stdout"]),
        "StandardErrorPath": str(out / job["stderr"]),
        "EnvironmentVariables": env,
    }
    path = home / "Library/LaunchAgents" / f'{job["Label"]}.plist'
    with path.open("wb") as fh:
        plistlib.dump(data, fh)
    print(path)
PY

uid="$(id -u)"
for label in com.saneapps.sanecite-monday-sweep com.saneapps.sanebar-macos27-watch; do
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$AGENTS_DIR/${label}.plist"
  launchctl enable "gui/$uid/$label" 2>/dev/null || true
  echo "installed $label"
done
