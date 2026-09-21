#!/usr/bin/env bash
# ProxyCommand for the explicit `mini-cf` rescue alias (Air side).
# Reads the Access service token from ~/.config/nv/env and passes it to
# cloudflared through environment variables, so the secret never appears in
# ps output. Fails clearly when the token is missing.
set -u

HOSTNAME="${1:-mini-ssh.saneapps.com}"
CLOUDFLARED="${SANE_CLOUDFLARED_BIN:-/opt/homebrew/bin/cloudflared}"
ENV_FILE="${SANE_ENV_FILE:-$HOME/.config/nv/env}"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

if [ -z "${CF_MINI_SSH_CLIENT_ID:-}" ] || [ -z "${CF_MINI_SSH_CLIENT_SECRET:-}" ]; then
  echo "saneapps-mini-cf-proxy: set CF_MINI_SSH_CLIENT_ID and CF_MINI_SSH_CLIENT_SECRET in $ENV_FILE" >&2
  exit 255
fi
if [ ! -x "$CLOUDFLARED" ]; then
  echo "saneapps-mini-cf-proxy: cloudflared not executable: $CLOUDFLARED" >&2
  exit 255
fi

export TUNNEL_SERVICE_TOKEN_ID="$CF_MINI_SSH_CLIENT_ID"
export TUNNEL_SERVICE_TOKEN_SECRET="$CF_MINI_SSH_CLIENT_SECRET"

# Never let cloudflared open a browser on this machine: its interactive login
# fallback would launch a window on the controller. Shadow `open` (the only
# launcher it uses on macOS) with a stub that fails loudly instead.
NO_BROWSER_DIR="${SANE_NO_BROWSER_DIR:-$HOME/.local/share/saneapps/no-browser}"
mkdir -p "$NO_BROWSER_DIR"
if [ ! -x "$NO_BROWSER_DIR/open" ]; then
  printf '#!/bin/sh\necho "saneapps-mini-cf-proxy: browser launch blocked (service-token auth required)" >&2\nexit 1\n' > "$NO_BROWSER_DIR/open"
  chmod +x "$NO_BROWSER_DIR/open"
fi
export PATH="$NO_BROWSER_DIR:$PATH"

exec "$CLOUDFLARED" access ssh --hostname "$HOSTNAME"
