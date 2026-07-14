#!/bin/bash
set -euo pipefail

# Make the normal Tailscale CLI follow the controller Mac's active daemon.
# The Air uses a no-sudo userspace daemon; the Mini uses the system daemon.

NATIVE_TAILSCALE="${SANE_TAILSCALE_BIN:-/opt/homebrew/bin/tailscale}"
USERSPACE_SOCKET="${SANE_TAILSCALE_SOCKET:-$HOME/Library/Application Support/tailscaled-userspace/tailscaled.sock}"

if [ ! -x "$NATIVE_TAILSCALE" ]; then
  echo "tailscale: native CLI not found at $NATIVE_TAILSCALE" >&2
  exit 127
fi

for argument in "$@"; do
  case "$argument" in
    --socket|--socket=*) exec "$NATIVE_TAILSCALE" "$@" ;;
  esac
done

if [ -S "$USERSPACE_SOCKET" ]; then
  exec "$NATIVE_TAILSCALE" --socket="$USERSPACE_SOCKET" "$@"
fi

exec "$NATIVE_TAILSCALE" "$@"
