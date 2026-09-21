#!/usr/bin/env bash
set -euo pipefail

# Installs the explicit `mini-cf` Cloudflare rescue alias on the controller
# machine. Additive only: it never rewrites the existing ladder config, which
# carries hand-maintained blocks. `ssh mini` keeps failing loudly when LAN and
# Tailscale are down; reach for `ssh mini-cf` to recover (see mini/README.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINI_CONFIG="$HOME/.ssh/config.d/saneapps-mini.conf"
PROXY_SRC="$SCRIPT_DIR/saneapps-mini-cf-proxy.sh"
PROXY_DEST="$HOME/.local/bin/saneapps-mini-cf-proxy"

mkdir -p "$HOME/.local/bin" "$(dirname "$MINI_CONFIG")"
touch "$MINI_CONFIG"
install -m 755 "$PROXY_SRC" "$PROXY_DEST"

if grep -q '^Host mini-cf' "$MINI_CONFIG"; then
  echo "Host mini-cf already present in $MINI_CONFIG"
else
  cp "$MINI_CONFIG" "$MINI_CONFIG.backup.$(date +%Y%m%d-%H%M%S)"
  cat >> "$MINI_CONFIG" <<'EOF'

# Explicit Cloudflare rescue alias. Never part of the auto ladder.
Host mini-cf
  HostName mini-ssh.saneapps.com
  User stephansmac
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  AddKeysToAgent yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ConnectTimeout 20
  ProxyCommand ~/.local/bin/saneapps-mini-cf-proxy %h
EOF
  chmod 600 "$MINI_CONFIG"
  echo "Appended Host mini-cf to $MINI_CONFIG"
fi

echo "Verify with: ssh mini-cf 'hostname; whoami'"
