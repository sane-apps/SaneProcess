#!/bin/bash
# install-training-daily-check-agent.sh - Install/update local training daily check LaunchAgent
# Usage:
#   bash scripts/mini/install-training-daily-check-agent.sh

set -euo pipefail

AGENT_LABEL="com.saneapps.training-daily-check"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/training-daily-check.py"
OUTPUT_DIR="$HOME/SaneApps/infra/SaneProcess/outputs"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3)}"
TRAIN_DAILY_CHECK_HOST="${TRAIN_DAILY_CHECK_HOST:-${MINI_HOST:-mini}}"
TRAIN_DAILY_CHECK_SSH_OPTS="${TRAIN_DAILY_CHECK_SSH_OPTS:-${MINI_SSH_OPTS:-}}"
TRAIN_DAILY_CHECK_HOUR="${TRAIN_DAILY_CHECK_HOUR:-9}"
TRAIN_DAILY_CHECK_MINUTE="${TRAIN_DAILY_CHECK_MINUTE:-15}"

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
    <string>${PYTHON_BIN}</string>
    <string>${SCRIPT_PATH}</string>
    <string>--host</string>
    <string>${TRAIN_DAILY_CHECK_HOST}</string>
    <string>--print</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${TRAIN_DAILY_CHECK_HOUR}</integer>
    <key>Minute</key>
    <integer>${TRAIN_DAILY_CHECK_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/training_daily_check.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/training_daily_check.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
    <key>TRAIN_DAILY_CHECK_SSH_OPTS</key>
    <string>${TRAIN_DAILY_CHECK_SSH_OPTS}</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true

echo "Installed ${AGENT_LABEL}"
plutil -p "$PLIST"
