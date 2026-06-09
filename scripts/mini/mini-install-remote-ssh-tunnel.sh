#!/usr/bin/env bash
set -euo pipefail

# Run on the Mini. Installs the current Cloudflare quick-tunnel bridge as a
# LaunchAgent so controller machines can reach the Mini with `ssh mini`.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/mini-remote-ssh-tunnel.sh"
TARGET_DIR="$HOME/SaneApps/infra/scripts"
TARGET_SCRIPT="$TARGET_DIR/mini-remote-ssh-tunnel.sh"
PLIST="$HOME/Library/LaunchAgents/com.saneapps.mini-remote-ssh-tunnel.plist"
LOG_DIR="$HOME/Library/Logs/SaneApps"

if [ ! -f "$SOURCE_SCRIPT" ]; then
  echo "Missing source script: $SOURCE_SCRIPT" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"
install -m 755 "$SOURCE_SCRIPT" "$TARGET_SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.saneapps.mini-remote-ssh-tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TARGET_SCRIPT</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$HOME/SaneApps</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/mini-remote-ssh-tunnel.launchd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/mini-remote-ssh-tunnel.launchd.err.log</string>
</dict>
</plist>
EOF

chmod 644 "$PLIST"
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "Installed LaunchAgent: $PLIST"
echo "Logs: $LOG_DIR/mini-remote-ssh-tunnel.log"
