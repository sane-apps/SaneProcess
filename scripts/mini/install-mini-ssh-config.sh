#!/usr/bin/env bash
set -euo pipefail

# Installs the controller-machine SSH aliases for the SaneApps Mac Mini.
# Canonical `ssh mini` uses the Cloudflare Access bridge so it works off-LAN.
# `ssh mini-lan` keeps the direct Bonjour route for same-network diagnostics.

CONFIG_DIR="$HOME/.ssh/config.d"
CONFIG_FILE="$HOME/.ssh/config"
MINI_CONFIG="$CONFIG_DIR/saneapps-mini.conf"
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$CONFIG_DIR"
chmod 700 "$HOME/.ssh"

if ! command -v cloudflared >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/cloudflared ]; then
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared 2>/dev/null || brew upgrade cloudflared
  else
    echo "cloudflared is required. Install it with Homebrew or put it on PATH." >&2
    exit 1
  fi
fi

touch "$CONFIG_FILE"
if [ -f "$CONFIG_FILE" ]; then
  cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$BACKUP_STAMP"
fi
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
  # LAN-first: when the Mini is reachable directly (same network), bypass the
  # Cloudflare bridge entirely. The quick-tunnel path drops long transfers
  # (rsync broken-pipe) and depends on an ephemeral TXT hostname; only fall
  # back to it off-LAN.
  ProxyCommand sh -c 'if nc -z -G 2 stephans-mac-mini.local 22 >/dev/null 2>&1; then exec nc stephans-mac-mini.local 22; fi; h=$(dig +short TXT mini-ssh-host.saneapps.com | tr -d "\"\n" | head -n 1); if [ -z "$h" ]; then echo "mini-ssh-host.saneapps.com TXT is empty" >&2; exit 255; fi; cf=$(command -v cloudflared || echo /opt/homebrew/bin/cloudflared); exec "$cf" access ssh --hostname "$h"'

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

echo "Installed $MINI_CONFIG"
echo "Verify with: ssh mini 'hostname; whoami'"
