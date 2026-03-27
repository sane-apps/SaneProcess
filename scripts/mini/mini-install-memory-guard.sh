#!/bin/bash
# mini-install-memory-guard.sh - Install/update the memory guard LaunchAgent on mini
# Usage:
#   bash ~/SaneApps/infra/SaneProcess/scripts/mini/mini-install-memory-guard.sh

set -euo pipefail

AGENT_LABEL="com.saneapps.memory-guard"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
SCRIPT_PATH="$HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-memory-guard.sh"
OUTPUT_DIR="$HOME/SaneApps/outputs"

mkdir -p "$HOME/Library/LaunchAgents" "$OUTPUT_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${AGENT_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>5</integer>
    <key>Minute</key>
    <integer>40</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/memory-guard.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/memory-guard.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true

echo "Installed ${AGENT_LABEL}"
defaults read "$PLIST" StartCalendarInterval
