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
  ProxyCommand sh -c 'h=$(dig +short TXT mini-ssh-host.saneapps.com | tr -d "\"\n" | head -n 1); if [ -z "$h" ]; then echo "mini-ssh-host.saneapps.com TXT is empty" >&2; exit 255; fi; cf=$(command -v cloudflared || echo /opt/homebrew/bin/cloudflared); p=$((22000 + ($$ % 20000))); "$cf" access tcp --hostname "$h" --url "127.0.0.1:$p" >/tmp/saneapps-mini-cloudflared.log 2>&1 & pid=$!; for i in 1 2 3 4 5 6 7 8 9 10; do nc -z 127.0.0.1 "$p" >/dev/null 2>&1 && break; sleep 0.2; done; nc 127.0.0.1 "$p"; rc=$?; kill "$pid" >/dev/null 2>&1 || true; exit "$rc"'

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
