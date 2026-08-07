#!/bin/bash
set -euo pipefail

# Install/update the Air-owned orphan-process guardian. The Mini has its own
# memory-guard service and must never own this controller LaunchAgent.

LABEL="com.saneapps.session-guardian"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARDIAN="${SANE_SESSION_GUARDIAN_SCRIPT:-$(cd "$SCRIPT_DIR/.." && pwd)/hooks/session-guardian.sh}"
PLIST="${SANE_SESSION_GUARDIAN_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="${SANE_SESSION_GUARDIAN_LOG_DIR:-$HOME/Library/Logs/SaneApps}"
INTERVAL="${SANE_SESSION_GUARDIAN_INTERVAL:-600}"
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
DRY_RUN=0

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "Usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { echo "Usage: $(basename "$0") [--dry-run]" >&2; exit 2; }
[[ -x "$GUARDIAN" ]] || { echo "Missing executable session guardian: $GUARDIAN" >&2; exit 1; }
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 60 ]] || { echo "Invalid guardian interval: $INTERVAL" >&2; exit 2; }

host="${SANE_SESSION_GUARDIAN_HOST_OVERRIDE:-$(hostname -s 2>/dev/null || hostname)}"
case "$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')" in
  *macbook*air*|*air*) ;;
  *) echo "Refusing to install the Air session guardian on host $host" >&2; exit 2 ;;
esac

render_plist() {
cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$GUARDIAN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>ThrottleInterval</key>
  <integer>30</integer>
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
  <string>$LOG_DIR/session-guardian.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/session-guardian.err.log</string>
</dict>
</plist>
PLIST
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  render_plist | plutil -lint - >/dev/null
  echo "Validated Air session guardian LaunchAgent: $PLIST"
  exit 0
fi

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
render_plist > "$PLIST"
chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

uid="$(id -u)"
"$LAUNCHCTL" bootout "gui/$uid/$LABEL" 2>/dev/null || true
"$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST"
"$LAUNCHCTL" enable "gui/$uid/$LABEL" 2>/dev/null || true
job="$($LAUNCHCTL print "gui/$uid/$LABEL" 2>&1)" || {
  printf '%s\n' "$job" >&2
  echo "Session guardian LaunchAgent did not load" >&2
  exit 1
}
printf '%s\n' "$job" | grep -Fq "$GUARDIAN" || {
  echo "Session guardian LaunchAgent points to the wrong program" >&2
  exit 1
}
"$GUARDIAN" --health >/dev/null
echo "Installed $LABEL (RunAtLoad + every ${INTERVAL}s; health verified)"
