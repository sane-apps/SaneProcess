#!/usr/bin/env bash
# SSH ProxyCommand for the SaneApps Mac Mini. Installed to
# ~/.local/bin/saneapps-mini-proxy by install-mini-ssh-config.sh.
#
# Connection ladder, first reachable wins:
#   1. Direct LAN (Bonjour) — fastest, same-network only.
#   2. Tailscale — durable anywhere path (WireGuard, survives reboots).
#      Works with either the system tailscaled or the no-sudo userspace
#      LaunchAgent (com.saneapps.tailscaled-userspace).
#
# There is deliberately no public quick-tunnel fallback. Both Macs are enrolled
# in the same tailnet, so an unavailable LAN and unavailable Tailscale route is
# a real connectivity failure that should be surfaced instead of hidden behind
# an ephemeral third-party hostname.
set -u

MINI_LAN_HOST="${SANE_MINI_LAN_HOST:-stephans-mac-mini.local}"
MINI_TS_HOST="${SANE_MINI_TS_HOST:-stephans-mac-mini}"
PORT="${SANE_MINI_PORT:-22}"

if nc -z -G 2 "$MINI_LAN_HOST" "$PORT" >/dev/null 2>&1; then
  exec nc "$MINI_LAN_HOST" "$PORT"
fi

TS="$(command -v tailscale || true)"
if [ -z "${TS}" ] && [ -x /opt/homebrew/bin/tailscale ]; then
  TS=/opt/homebrew/bin/tailscale
fi
if [ -n "${TS}" ]; then
  TS_ARGS=()
  USERSPACE_SOCK="${SANE_TAILSCALE_SOCKET:-$HOME/Library/Application Support/tailscaled-userspace/tailscaled.sock}"
  if [ -S "$USERSPACE_SOCK" ]; then
    TS_ARGS=(--socket="$USERSPACE_SOCK")
  fi
  if "$TS" ${TS_ARGS[@]+"${TS_ARGS[@]}"} ping -c 1 --timeout=3s "$MINI_TS_HOST" >/dev/null 2>&1; then
    exec "$TS" ${TS_ARGS[@]+"${TS_ARGS[@]}"} nc "$MINI_TS_HOST" "$PORT"
  fi
fi

echo "saneapps-mini-proxy: LAN and Tailscale are unavailable" >&2
exit 255
