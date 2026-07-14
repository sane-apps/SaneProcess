#!/bin/bash
set -euo pipefail

# Install on the MacBook Air. The Air is the controller for file-memory parity:
# it runs after login and every 15 minutes, pulling Mini-only writes and pushing
# Air-only writes through the conflict-preserving sync lane.

LABEL="com.saneapps.memory-sync"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-memory-mini.sh"
PLIST="${SANE_MEMORY_SYNC_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="${SANE_MEMORY_SYNC_LOG_DIR:-$HOME/SaneApps/infra/SaneProcess/outputs}"
INTERVAL="${SANE_MEMORY_SYNC_INTERVAL:-900}"
DRY_RUN=0

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  *)
    echo "Usage: $(basename "$0") [--dry-run]" >&2
    exit 2
    ;;
esac
[[ "$#" -le 1 ]] || { echo "Usage: $(basename "$0") [--dry-run]" >&2; exit 2; }
[[ -x "$SYNC_SCRIPT" ]] || { echo "Missing executable sync lane: $SYNC_SCRIPT" >&2; exit 1; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "Invalid sync interval: $INTERVAL" >&2; exit 2; }

host="$(hostname -s 2>/dev/null || hostname)"
if [[ "$DRY_RUN" -eq 0 && "$host" == *[Mm]ini* ]]; then
  echo "Refusing to install the Air memory-sync agent on Mini host $host" >&2
  exit 2
fi

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
    <string>/bin/bash</string>
    <string>$SYNC_SCRIPT</string>
    <string>mini</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>ThrottleInterval</key>
  <integer>60</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/memory_sync.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/memory_sync.stderr.log</string>
</dict>
</plist>
PLIST

chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Validated Air memory-sync LaunchAgent: $PLIST"
  exit 0
fi

uid="$(id -u)"
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$PLIST"
launchctl enable "gui/$uid/$LABEL" 2>/dev/null || true
echo "Installed $LABEL (RunAtLoad + every ${INTERVAL}s)"
