#!/usr/bin/env bash
# Runner for the named Cloudflare rescue tunnel connector on the Mini.
# Invoked by the com.saneapps.cf-tunnel LaunchAgent (mini-install-cf-tunnel.sh).
# Reads SANE_CF_TUNNEL_TOKEN from the environment or ~/.config/nv/env, then
# execs cloudflared. Fails loudly when the token or binary is missing.
set -u

CLOUDFLARED="${SANE_CLOUDFLARED_BIN:-/opt/homebrew/bin/cloudflared}"
ENV_FILE="${SANE_ENV_FILE:-$HOME/.config/nv/env}"

if [ -z "${SANE_CF_TUNNEL_TOKEN:-}" ] && [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi

if [ -z "${SANE_CF_TUNNEL_TOKEN:-}" ]; then
  echo "mini-cf-tunnel-run: SANE_CF_TUNNEL_TOKEN is not set (env or $ENV_FILE)" >&2
  exit 2
fi
if [ ! -x "$CLOUDFLARED" ]; then
  echo "mini-cf-tunnel-run: cloudflared not executable: $CLOUDFLARED" >&2
  exit 1
fi

exec "$CLOUDFLARED" tunnel run --token "$SANE_CF_TUNNEL_TOKEN"
