#!/usr/bin/env bash
set -euo pipefail

# Installs the named Cloudflare rescue tunnel connector as a restart-durable
# user LaunchAgent on the Mini. Outbound-only: no inbound ports are opened.
# The Air reaches it through the explicit `mini-cf` SSH alias, never through
# the auto ladder (see install-mini-cf-ssh.sh and mini/README.md).

LABEL="com.saneapps.cf-tunnel"
PLIST="${SANE_CF_TUNNEL_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG_DIR="${SANE_CF_TUNNEL_LOG_DIR:-$HOME/Library/Logs/SaneApps}"
CLOUDFLARED="${SANE_CLOUDFLARED_BIN:-/opt/homebrew/bin/cloudflared}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SOURCE="${SANE_CF_TUNNEL_RUNNER_SOURCE:-$SCRIPT_DIR/mini-cf-tunnel-run.sh}"
RUNNER="${SANE_CF_TUNNEL_RUNNER:-$HOME/.local/libexec/sane-cf-tunnel-run}"
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
SUDO="${SANE_SUDO_BIN:-/usr/bin/sudo}"
ENV_FILE="${SANE_ENV_FILE:-$HOME/.config/nv/env}"
DRY_RUN=0

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ -x "$CLOUDFLARED" ]] || { echo "Missing cloudflared: $CLOUDFLARED" >&2; exit 1; }
[[ -f "$RUNNER_SOURCE" ]] || { echo "Missing tunnel runner: $RUNNER_SOURCE" >&2; exit 1; }

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR" "$(dirname "$RUNNER")"
install -m 755 "$RUNNER_SOURCE" "$RUNNER"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$HOME</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
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
  <string>$LOG_DIR/cf-tunnel.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/cf-tunnel.err.log</string>
</dict>
</plist>
PLIST

chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Validated Cloudflare tunnel LaunchAgent: $PLIST"
  exit 0
fi

# Refuse to load without a token: a crash-looping connector is noise.
TOKEN_PRESENT=0
[ -n "${SANE_CF_TUNNEL_TOKEN:-}" ] && TOKEN_PRESENT=1
if [ "$TOKEN_PRESENT" -eq 0 ] && [ -f "$ENV_FILE" ] && \
   grep -Eq '^(export )?SANE_CF_TUNNEL_TOKEN=.+' "$ENV_FILE"; then
  TOKEN_PRESENT=1
fi
if [ "$TOKEN_PRESENT" -eq 0 ]; then
  echo "Set SANE_CF_TUNNEL_TOKEN in the environment or $ENV_FILE first." >&2
  exit 1
fi

uid="$(id -u)"
if ! "$LAUNCHCTL" bootout "gui/$uid/$LABEL" 2>/dev/null; then
  "$SUDO" -n "$LAUNCHCTL" bootout "gui/$uid/$LABEL" 2>/dev/null || true
fi
# Truncate stale logs so the registration check below cannot pass on old output.
: > "$LOG_DIR/cf-tunnel.out.log"
: > "$LOG_DIR/cf-tunnel.err.log"
if ! bootstrap_error="$("$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST" 2>&1)"; then
  if "$SUDO" -n "$LAUNCHCTL" bootstrap "gui/$uid" "$PLIST"; then
    echo "Loaded $LABEL through the noninteractive admin fallback."
  else
    printf '%s\n' "$bootstrap_error" >&2
    echo "Could not load $LABEL from this session. Run this installer once in the logged-in Mini Terminal." >&2
    exit 1
  fi
fi
"$LAUNCHCTL" enable "gui/$uid/$LABEL" 2>/dev/null || \
  "$SUDO" -n "$LAUNCHCTL" enable "gui/$uid/$LABEL" 2>/dev/null || true
echo "Installed $LABEL; waiting for tunnel registration"
attempt=1
while [ "$attempt" -le 30 ]; do
  if grep -q 'Registered tunnel connection' "$LOG_DIR/cf-tunnel.err.log" 2>/dev/null; then
    echo "Tunnel connector registered"
    exit 0
  fi
  sleep 2
  attempt=$((attempt + 1))
done

echo "Tunnel did not register within 60 seconds; see $LOG_DIR/cf-tunnel.err.log" >&2
exit 1
