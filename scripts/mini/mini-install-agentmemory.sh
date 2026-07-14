#!/usr/bin/env bash
set -euo pipefail

# Installs the shared AgentMemory worker as a restart-durable user LaunchAgent.
# The store remains loopback-only on port 3111; the Air reaches it through SSH.

LABEL="com.saneapps.agentmemory"
PLIST="${SANE_AGENTMEMORY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="${SANE_AGENTMEMORY_LOG_DIR:-$HOME/Library/Logs/SaneApps}"
AGENTMEMORY="${SANE_AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ -x "$AGENTMEMORY" ]] || { echo "Missing AgentMemory CLI: $AGENTMEMORY" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$AGENTMEMORY</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/agentmemory.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/agentmemory.err.log</string>
</dict>
</plist>
PLIST

chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Validated AgentMemory LaunchAgent: $PLIST"
  exit 0
fi

uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
"$AGENTMEMORY" stop --force >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$PLIST"
launchctl enable "gui/$uid/$LABEL" 2>/dev/null || true
echo "Installed $LABEL; waiting for AgentMemory health"
attempt=1
while [ "$attempt" -le 15 ]; do
  status_output="$($AGENTMEMORY status 2>&1 || true)"
  if printf '%s\n' "$status_output" | grep -Eq 'Health:[[:space:]].*healthy'; then
    echo "Started healthy $LABEL"
    exit 0
  fi
  sleep 2
  attempt=$((attempt + 1))
done

printf '%s\n' "$status_output" >&2
echo "AgentMemory did not become healthy within 30 seconds" >&2
exit 1
