#!/bin/bash
# mini-install-memory-guard.sh - Install nightly machine cleanup on this host
# Usage:
#   bash ~/SaneApps/infra/SaneProcess/scripts/mini/mini-install-memory-guard.sh
#
# Mini: com.saneapps.memory-guard -> mini-memory-guard.sh (server reset)
# Air:  com.saneapps.machine-cleanup -> SaneMaster hygiene apply (no --server)

set -euo pipefail

OUTPUT_DIR="$HOME/SaneApps/outputs"
HOST="$(hostname -s 2>/dev/null || hostname)"
mkdir -p "$HOME/Library/LaunchAgents" "$OUTPUT_DIR"

if [[ "$HOST" == *[Mm]ini* ]]; then
  AGENT_LABEL="com.saneapps.memory-guard"
  SCRIPT_PATH="$HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-memory-guard.sh"
  STDOUT_PATH="${OUTPUT_DIR}/memory-guard.stdout.log"
  STDERR_PATH="${OUTPUT_DIR}/memory-guard.stderr.log"
  PROGRAM_ARGUMENTS="$(printf '    <string>/bin/bash</string>\n    <string>%s</string>\n' "$SCRIPT_PATH")"
else
  AGENT_LABEL="com.saneapps.machine-cleanup"
  SANEMASTER="$HOME/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb"
  STDOUT_PATH="${OUTPUT_DIR}/machine-cleanup.stdout.log"
  STDERR_PATH="${OUTPUT_DIR}/machine-cleanup.stderr.log"
  PROGRAM_ARGUMENTS="$(printf '    <string>/usr/bin/env</string>\n    <string>ruby</string>\n    <string>%s</string>\n    <string>machine_cleanup</string>\n    <string>--host</string>\n    <string>local</string>\n    <string>--apply</string>\n    <string>--quiet</string>\n' "$SANEMASTER")"
fi

PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${AGENT_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
${PROGRAM_ARGUMENTS}  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>5</integer>
    <key>Minute</key>
    <integer>40</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${STDOUT_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${STDERR_PATH}</string>

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

echo "Installed ${AGENT_LABEL} on ${HOST}"
defaults read "$PLIST" StartCalendarInterval
