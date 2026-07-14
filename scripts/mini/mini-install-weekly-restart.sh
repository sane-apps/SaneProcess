#!/bin/bash
# Install the Sunday restart gate as a root-owned LaunchDaemon and helper.

set -euo pipefail

LABEL="com.saneapps.weekly-restart"
SOURCE="$(cd "$(dirname "$0")" && pwd)/mini-weekly-restart.sh"
HELPER="/usr/local/sbin/sane-mini-weekly-restart"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SERVER_USER="${SANE_SERVER_USER:-$(id -un)}"
TMP_PLIST="$(mktemp "${TMPDIR:-/tmp}/${LABEL}.XXXXXX")"
trap 'rm -f "$TMP_PLIST"' EXIT

if [ -t 0 ]; then
  SUDO=(/usr/bin/sudo)
else
  SUDO=(/usr/bin/sudo -n)
fi

if [ "${1:-}" = "--uninstall" ]; then
  "${SUDO[@]}" launchctl bootout "system/${LABEL}" 2>/dev/null || true
  "${SUDO[@]}" rm -f "$PLIST" "$HELPER"
  echo "Uninstalled ${LABEL}"
  exit 0
elif [ "$#" -gt 0 ]; then
  echo "Usage: $0 [--uninstall]" >&2
  exit 2
fi

cat > "$TMP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${HELPER}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SANE_SERVER_USER</key>
    <string>${SERVER_USER}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <array>
    <dict>
      <key>Weekday</key><integer>0</integer>
      <key>Hour</key><integer>10</integer>
      <key>Minute</key><integer>30</integer>
    </dict>
    <dict>
      <key>Weekday</key><integer>0</integer>
      <key>Hour</key><integer>11</integer>
      <key>Minute</key><integer>30</integer>
    </dict>
    <dict>
      <key>Weekday</key><integer>0</integer>
      <key>Hour</key><integer>12</integer>
      <key>Minute</key><integer>30</integer>
    </dict>
  </array>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/sane-mini-weekly-restart.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/sane-mini-weekly-restart.log</string>
</dict>
</plist>
EOF

plutil -lint "$TMP_PLIST"
"${SUDO[@]}" install -d -m 0755 -o root -g wheel /usr/local/sbin
"${SUDO[@]}" install -m 0755 -o root -g wheel "$SOURCE" "$HELPER"
"${SUDO[@]}" install -m 0644 -o root -g wheel "$TMP_PLIST" "$PLIST"
"${SUDO[@]}" launchctl bootout "system/${LABEL}" 2>/dev/null || true
"${SUDO[@]}" launchctl bootstrap system "$PLIST"
"${SUDO[@]}" launchctl enable "system/${LABEL}"

echo "Installed ${LABEL} for Sundays at 10:30, 11:30, and 12:30"
"${SUDO[@]}" launchctl print "system/${LABEL}" | sed -n '1,80p'
ls -l "$HELPER" "$PLIST"
