#!/bin/bash
# Air-side MCP shim for the shared AgentMemory server on the always-on Mini.
# One launchd-owned foreground process owns the shared loopback tunnel. MCP
# clients only verify/kickstart that owner, so simultaneous clients never race
# to bind port 3111 or leave detached ssh processes behind.
set -uo pipefail

LABEL="${SANE_AGENTMEMORY_TUNNEL_LABEL:-com.saneapps.agentmemory-tunnel}"
MINI_HOST="${SANE_AGENTMEMORY_MINI_HOST:-mini}"
LOCAL_PORT="${SANE_AGENTMEMORY_LOCAL_PORT:-3111}"
APPLE_DOCS_PORT="${SANE_APPLE_DOCS_LOCAL_PORT:-37911}"
MACOS_AUTOMATOR_PORT="${SANE_MACOS_AUTOMATOR_LOCAL_PORT:-37913}"
XCODE_PORT="${SANE_XCODE_LOCAL_PORT:-37915}"
URL="${SANE_AGENTMEMORY_URL:-http://127.0.0.1:$LOCAL_PORT}"
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
SSH="${SANE_SSH_BIN:-/usr/bin/ssh}"
NPX="${SANE_NPX_BIN:-npx}"
WAIT_ATTEMPTS="${SANE_AGENTMEMORY_WAIT_ATTEMPTS:-6}"
WAIT_INTERVAL="${SANE_AGENTMEMORY_WAIT_INTERVAL:-0.5}"

usage() {
  echo "Usage: $(basename "$0") [--tunnel]" >&2
  exit 2
}

health_ready() {
  "$CURL" --silent --fail --max-time 1 "$URL/agentmemory/health" >/dev/null 2>&1
}

if [[ "${1:-}" == "--tunnel" ]]; then
  [[ "$#" -eq 1 ]] || usage
  exec "$SSH" -N \
    -o BatchMode=yes \
    -o ConnectTimeout=3 \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -L "$LOCAL_PORT:127.0.0.1:3111" \
    -L "$APPLE_DOCS_PORT:127.0.0.1:37911" \
    -L "$MACOS_AUTOMATOR_PORT:127.0.0.1:37913" \
    -L "$XCODE_PORT:127.0.0.1:37915" \
    "$MINI_HOST"
fi

[[ "$#" -eq 0 ]] || usage

if ! health_ready; then
  if ! "$LAUNCHCTL" kickstart "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "AgentMemory tunnel LaunchAgent is unavailable; run install-memory-sync-agent.sh on the Air" >&2
    exit 1
  fi

  attempt=0
  while [[ "$attempt" -lt "$WAIT_ATTEMPTS" ]]; do
    health_ready && break
    attempt=$((attempt + 1))
    sleep "$WAIT_INTERVAL"
  done
fi

if ! health_ready; then
  echo "AgentMemory tunnel did not become healthy at $URL within the bounded startup window" >&2
  exit 1
fi

export AGENTMEMORY_URL="$URL"
# Never silently fall back to the shim's private local store if the shared
# service drops after startup; the shared memory lane must fail truthfully.
export AGENTMEMORY_FORCE_PROXY=1
exec "$NPX" -y @agentmemory/mcp
