#!/bin/bash
# install-repo-reconcile-agent.sh - Install/update local Air↔Mini repo reconcile LaunchAgent
# Usage:
#   bash scripts/automation/install-repo-reconcile-agent.sh

set -euo pipefail

AGENT_LABEL="com.saneapps.repo-reconcile"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/reconcile-air-mini.sh"
OUTPUT_DIR="$HOME/SaneApps/infra/SaneProcess/outputs"
REPO_RECONCILE_HOST="${REPO_RECONCILE_HOST:-mini}"
REPO_RECONCILE_AM_HOUR="${REPO_RECONCILE_AM_HOUR:-5}"
REPO_RECONCILE_AM_MINUTE="${REPO_RECONCILE_AM_MINUTE:-55}"
REPO_RECONCILE_PM_HOUR="${REPO_RECONCILE_PM_HOUR:-21}"
REPO_RECONCILE_PM_MINUTE="${REPO_RECONCILE_PM_MINUTE:-55}"

[[ -f "$SCRIPT_PATH" ]] || { echo "ERROR: Missing reconcile script: $SCRIPT_PATH" >&2; exit 1; }
chmod +x "$SCRIPT_PATH"

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
    <string>${REPO_RECONCILE_HOST}</string>
  </array>

  <key>StartCalendarInterval</key>
  <array>
    <dict>
      <key>Hour</key>
      <integer>${REPO_RECONCILE_AM_HOUR}</integer>
      <key>Minute</key>
      <integer>${REPO_RECONCILE_AM_MINUTE}</integer>
    </dict>
    <dict>
      <key>Hour</key>
      <integer>${REPO_RECONCILE_PM_HOUR}</integer>
      <key>Minute</key>
      <integer>${REPO_RECONCILE_PM_MINUTE}</integer>
    </dict>
  </array>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/repo_reconcile.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/repo_reconcile.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true

echo "Installed ${AGENT_LABEL}"
plutil -p "$PLIST"
