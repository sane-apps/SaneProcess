#!/bin/bash
# mini-install-training-agents.sh - Install/update training LaunchAgents on mini
# Usage:
#   bash ~/SaneApps/infra/scripts/mini-install-training-agents.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="${SANE_ROOT:-$DEFAULT_SANE_ROOT}"
OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"
MLX_BIN_DIR="${MLX_BIN_DIR:-$HOME/mlx-env/bin}"

CHALLENGER_LABEL="com.saneapps.training-challengers"
CHALLENGER_PLIST="$LAUNCH_AGENTS_DIR/${CHALLENGER_LABEL}.plist"
CHALLENGER_SCRIPT="$SCRIPT_DIR/mini-train-challengers.sh"
CHALLENGER_HOUR="${CHALLENGER_HOUR:-1}"
CHALLENGER_MINUTE="${CHALLENGER_MINUTE:-0}"

WEEKLY_LABEL="com.saneapps.training-weekly"
WEEKLY_PLIST="$LAUNCH_AGENTS_DIR/${WEEKLY_LABEL}.plist"
WEEKLY_SCRIPT="$SCRIPT_DIR/mini-train-all.sh"
WEEKLY_TRAIN_WEEKDAY="${WEEKLY_TRAIN_WEEKDAY:-0}"
WEEKLY_TRAIN_HOUR="${WEEKLY_TRAIN_HOUR:-3}"
WEEKLY_TRAIN_MINUTE="${WEEKLY_TRAIN_MINUTE:-0}"

LEGACY_LABEL="com.saneapps.training"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/${LEGACY_LABEL}.plist"

mkdir -p "$LAUNCH_AGENTS_DIR" "$OUTPUT_DIR"

cat > "$CHALLENGER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CHALLENGER_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${CHALLENGER_SCRIPT}</string>
    <string>SaneSync</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${CHALLENGER_HOUR}</integer>
    <key>Minute</key>
    <integer>${CHALLENGER_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/training-challengers.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/training-challengers.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${MLX_BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SANE_ROOT</key>
    <string>${SANE_ROOT}</string>
    <key>SANE_OUTPUT_DIR</key>
    <string>${OUTPUT_DIR}</string>
  </dict>

  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
EOF

cat > "$WEEKLY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${WEEKLY_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WEEKLY_SCRIPT}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>${WEEKLY_TRAIN_WEEKDAY}</integer>
    <key>Hour</key>
    <integer>${WEEKLY_TRAIN_HOUR}</integer>
    <key>Minute</key>
    <integer>${WEEKLY_TRAIN_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/training-weekly.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/training-weekly.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${MLX_BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>SANE_ROOT</key>
    <string>${SANE_ROOT}</string>
    <key>SANE_OUTPUT_DIR</key>
    <string>${OUTPUT_DIR}</string>
    <key>TRAIN_STDOUT_LOG</key>
    <string>${OUTPUT_DIR}/training-weekly.stdout.log</string>
    <key>TRAIN_STDERR_LOG</key>
    <string>${OUTPUT_DIR}/training-weekly.stderr.log</string>
  </dict>

  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LEGACY_LABEL}" 2>/dev/null || true
rm -f "$LEGACY_PLIST"

for label in "$CHALLENGER_LABEL" "$WEEKLY_LABEL"; do
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
done

launchctl bootstrap "gui/$(id -u)" "$CHALLENGER_PLIST"
launchctl bootstrap "gui/$(id -u)" "$WEEKLY_PLIST"
launchctl enable "gui/$(id -u)/${CHALLENGER_LABEL}" 2>/dev/null || true
launchctl enable "gui/$(id -u)/${WEEKLY_LABEL}" 2>/dev/null || true

echo "Installed ${CHALLENGER_LABEL}"
plutil -p "$CHALLENGER_PLIST"
echo ""
echo "Installed ${WEEKLY_LABEL}"
plutil -p "$WEEKLY_PLIST"
