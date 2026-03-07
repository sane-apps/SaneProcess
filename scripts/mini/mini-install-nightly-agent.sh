#!/bin/bash
# mini-install-nightly-agent.sh - Install/update the nightly LaunchAgent on mini
# Usage:
#   bash ~/SaneApps/infra/scripts/mini-install-nightly-agent.sh

set -euo pipefail

AGENT_LABEL="com.saneapps.nightly"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/mini-nightly.sh"
SANE_ROOT="${SANE_ROOT:-$HOME/SaneApps}"
OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"
NIGHTLY_HOUR="${NIGHTLY_HOUR:-2}"
NIGHTLY_MINUTE="${NIGHTLY_MINUTE:-0}"

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
    <integer>${NIGHTLY_HOUR}</integer>
    <key>Minute</key>
    <integer>${NIGHTLY_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/nightly.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/nightly.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SANE_ROOT</key>
    <string>${SANE_ROOT}</string>
    <key>SANE_OUTPUT_DIR</key>
    <string>${OUTPUT_DIR}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true

echo "Installed ${AGENT_LABEL}"
plutil -p "$PLIST"
