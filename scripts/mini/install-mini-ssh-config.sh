#!/usr/bin/env bash
set -euo pipefail

# Installs the controller-machine SSH aliases for the SaneApps Mac Mini.
# Canonical `ssh mini` walks a connection ladder (LAN -> Tailscale) via
# ~/.local/bin/saneapps-mini-proxy so the same alias
# works on-LAN, off-LAN, and after either machine reboots.
# `ssh mini-lan` keeps the direct Bonjour route for same-network diagnostics.
#
# Also installs a no-sudo userspace tailscaled LaunchAgent on this machine if
# no tailscaled is running, then prints the one-time auth step if needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.ssh/config.d"
CONFIG_FILE="$HOME/.ssh/config"
MINI_CONFIG="$CONFIG_DIR/saneapps-mini.conf"
PROXY_SRC="$SCRIPT_DIR/saneapps-mini-proxy.sh"
PROXY_DEST="$HOME/.local/bin/saneapps-mini-proxy"
AGENT_LABEL="com.saneapps.tailscaled-userspace"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
TS_STATE_DIR="$HOME/Library/Application Support/tailscaled-userspace"
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$CONFIG_DIR" "$HOME/.local/bin"
chmod 700 "$HOME/.ssh"

if ! command -v tailscale >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/tailscale ]; then
  if command -v brew >/dev/null 2>&1; then
    brew install tailscale 2>/dev/null || true
  fi
fi

touch "$CONFIG_FILE"
cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$BACKUP_STAMP"
if [ -f "$MINI_CONFIG" ]; then
  cp "$MINI_CONFIG" "$MINI_CONFIG.backup.$BACKUP_STAMP"
fi

if ! grep -q '^Include ~/.ssh/config.d/\*.conf' "$CONFIG_FILE"; then
  tmp_file="$(mktemp)"
  {
    printf 'Include ~/.ssh/config.d/*.conf\n\n'
    cat "$CONFIG_FILE"
  } > "$tmp_file"
  mv "$tmp_file" "$CONFIG_FILE"
fi

install -m 755 "$PROXY_SRC" "$PROXY_DEST"

cat > "$MINI_CONFIG" <<'EOF'
Host mini mini-remote
  HostName mini-remote
  User stephansmac
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  AddKeysToAgent yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ConnectTimeout 15
  # Connection ladder: LAN -> Tailscale.
  # See SaneProcess scripts/mini/saneapps-mini-proxy.sh (canonical source).
  ProxyCommand ~/.local/bin/saneapps-mini-proxy

Host mini-lan
  HostName stephans-mac-mini.local
  User stephansmac
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  AddKeysToAgent yes
  ServerAliveInterval 30
  ServerAliveCountMax 2
EOF

chmod 600 "$CONFIG_FILE" "$MINI_CONFIG"

# --- Tailscale daemon (this machine, client side) ---------------------------
TS="$(command -v tailscale || true)"
[ -z "$TS" ] && [ -x /opt/homebrew/bin/tailscale ] && TS=/opt/homebrew/bin/tailscale

if [ -n "$TS" ]; then
  if "$TS" status >/dev/null 2>&1; then
    echo "tailscaled (system) is running."
  elif [ -S "$TS_STATE_DIR/tailscaled.sock" ] && \
       "$TS" --socket="$TS_STATE_DIR/tailscaled.sock" status >/dev/null 2>&1; then
    echo "tailscaled (userspace LaunchAgent) is running."
  else
    TAILSCALED="$(dirname "$TS")/../opt/tailscale/bin/tailscaled"
    [ -x "$TAILSCALED" ] || TAILSCALED=/opt/homebrew/opt/tailscale/bin/tailscaled
    if [ -x "$TAILSCALED" ]; then
      mkdir -p "$TS_STATE_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/SaneApps"
      cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$TAILSCALED</string>
		<string>--tun=userspace-networking</string>
		<string>--statedir=$TS_STATE_DIR</string>
		<string>--socket=$TS_STATE_DIR/tailscaled.sock</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/SaneApps/tailscaled-userspace.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/SaneApps/tailscaled-userspace.err.log</string>
</dict>
</plist>
PLIST
      launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
      echo "Installed userspace tailscaled LaunchAgent ($AGENT_LABEL)."
      sleep 2
    fi
  fi

  SOCK_ARGS=()
  if ! "$TS" status >/dev/null 2>&1 && [ -S "$TS_STATE_DIR/tailscaled.sock" ]; then
    SOCK_ARGS=(--socket="$TS_STATE_DIR/tailscaled.sock")
  fi
  if "$TS" ${SOCK_ARGS[@]+"${SOCK_ARGS[@]}"} status 2>&1 | grep -q "Logged out"; then
    echo ""
    echo "One-time step: authenticate this machine to the tailnet:"
    echo "  $TS ${SOCK_ARGS[*]:-} up --hostname=\"\$(hostname -s | tr '[:upper:]' '[:lower:]')\""
  fi
else
  echo "tailscale not installed; only the same-LAN route will be available." >&2
fi

echo "Installed $MINI_CONFIG and $PROXY_DEST"
echo "Verify with: ssh mini 'hostname; whoami'"
