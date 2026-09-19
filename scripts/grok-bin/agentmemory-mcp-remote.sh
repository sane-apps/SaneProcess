#!/bin/zsh
# AgentMemory MCP for Cursor, Grok, and Codex on a host that can reach the
# Mini-owned worker. Daily use talks to loopback :3111. Cloud Access is
# --login / AGENTMEMORY_MCP_FORCE_CLOUD=1 only — it must not hang session start.
set -euo pipefail

URL="${AGENTMEMORY_URL:-http://127.0.0.1:3111}"
CONFIG_DIR="${AGENTMEMORY_MCP_CONFIG_DIR:-$HOME/.config/saneapps/agentmemory-mcp-oauth}"
LEGACY_DIR="$HOME/Library/Application Support/SaneApps/AgentMemoryCloudOAuthTest/mcp-remote-production/mcp-remote-0.1.37"
CALLBACK_PORT="${AGENTMEMORY_MCP_CALLBACK_PORT:-5716}"
AUTH_TIMEOUT="${AGENTMEMORY_MCP_AUTH_TIMEOUT:-86400}"
ALLOW_BROWSER="${AGENTMEMORY_ALLOW_BROWSER:-0}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
AGENTMEMORY_BIN="${AGENTMEMORY_BIN:-/opt/homebrew/bin/agentmemory}"
CLOUD_URL="https://memory.saneapps.com/mcp"

usage() {
  print -u2 "usage: ${0:t} [--login|--self-test]"
  print -u2 "Daily MCP clients run this with no flags. Browser Access is --login only."
  exit 2
}

local_ready() {
  "$CURL" --silent --fail --max-time 1 "$URL/agentmemory/health" >/dev/null 2>&1 \
    || "$CURL" --silent --fail --max-time 1 "$URL/agentmemory/livez" >/dev/null 2>&1
}

seed_cache() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  local dest="$CONFIG_DIR/mcp-remote-0.1.37"
  mkdir -p "$dest"
  chmod 700 "$dest"
  local src
  if [[ -f "$LEGACY_DIR/mcp-remote-0.1.37/094da39d19d2887eb004e1f6d6d5710a_tokens.json" ]]; then
    src="$LEGACY_DIR/mcp-remote-0.1.37"
  elif [[ -f "$LEGACY_DIR/094da39d19d2887eb004e1f6d6d5710a_tokens.json" ]]; then
    src="$LEGACY_DIR"
  else
    return 0
  fi
  if [[ ! -f "$dest/094da39d19d2887eb004e1f6d6d5710a_tokens.json" ]]; then
    cp -p "$src"/094da39d19d2887eb004e1f6d6d5710a_* "$dest/" 2>/dev/null || true
    chmod 600 "$dest"/* 2>/dev/null || true
  fi
}

install_open_guard() {
  OPEN_GUARD_BIN="$CONFIG_DIR/bin"
  mkdir -p "$OPEN_GUARD_BIN"
  cat > "$OPEN_GUARD_BIN/open" <<'EOS'
#!/bin/bash
set -euo pipefail
if [[ "${AGENTMEMORY_ALLOW_BROWSER:-0}" == "1" ]]; then
  exec /usr/bin/open "$@"
fi
for arg in "$@"; do
  case "$arg" in
    *memory.saneapps.com*|*cloudflareaccess.com*|*cdn-cgi/access*|*oauth/consent*)
      echo "agentmemory-mcp-remote: not opening Cloudflare Access. Run: agentmemory-mcp-remote.sh --login" >&2
      exit 0
      ;;
  esac
done
exec /usr/bin/open "$@"
EOS
  chmod 755 "$OPEN_GUARD_BIN/open"
}

self_test() {
  local tmp out
  tmp="$(mktemp -d /tmp/agentmemory-mcp-remote-test.XXXXXX)"
  CONFIG_DIR="$tmp"
  install_open_guard
  case "$CONFIG_DIR" in
    *" "*) print -u2 "self-test: config dir must not contain spaces"; rm -rf "$tmp"; exit 1 ;;
  esac
  out="$("$OPEN_GUARD_BIN/open" "https://memory.saneapps.com/cdn-cgi/access/oauth/consent?x=1" 2>&1)" || true
  if [[ "$out" != *"not opening Cloudflare Access"* ]]; then
    print -u2 "self-test: Access URL must be refused"
    print -u2 "$out"
    rm -rf "$tmp"
    exit 1
  fi
  out="$("$OPEN_GUARD_BIN/open" "https://cold-violet-458e.cloudflareaccess.com/cdn-cgi/access/login/memory.saneapps.com" 2>&1)" || true
  if [[ "$out" != *"not opening Cloudflare Access"* ]]; then
    print -u2 "self-test: Access login URL must be refused"
    print -u2 "$out"
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
  print -u2 "agentmemory-mcp-remote self-test: pass"
}

exec_local_mcp() {
  export AGENTMEMORY_URL="$URL"
  # Never silently fall back to a private local store if the shared worker drops.
  export AGENTMEMORY_FORCE_PROXY=1
  if [[ -x "$AGENTMEMORY_BIN" ]]; then
    exec "$AGENTMEMORY_BIN" mcp --no-engine
  fi
  exec npx -y @agentmemory/mcp
}

exec_cloud_mcp() {
  seed_cache
  install_open_guard
  export AGENTMEMORY_ALLOW_BROWSER="$ALLOW_BROWSER"
  export MCP_REMOTE_CONFIG_DIR="$CONFIG_DIR"
  export PATH="$OPEN_GUARD_BIN:$PATH"
  if [[ "$ALLOW_BROWSER" == "1" ]]; then
    print -u2 "AgentMemory login: click Allow once. Leave this running until the tab says authorization successful."
  fi
  exec npx -p mcp-remote@0.1.38 mcp-remote "$CLOUD_URL" \
    "$CALLBACK_PORT" \
    --transport http-only \
    --silent \
    --auth-timeout "$AUTH_TIMEOUT"
}

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$#" -eq 1 ]] || usage
  self_test
  exit 0
fi

if [[ "${1:-}" == "--login" ]]; then
  [[ "$#" -eq 1 ]] || usage
  ALLOW_BROWSER=1
  exec_cloud_mcp
fi

if [[ "$#" -gt 0 ]]; then
  usage
fi

if [[ "${AGENTMEMORY_MCP_FORCE_CLOUD:-0}" == "1" ]]; then
  exec_cloud_mcp
fi

if local_ready; then
  exec_local_mcp
fi

print -u2 "agentmemory-mcp-remote: Mini worker is not healthy at $URL"
print -u2 "Start it with: launchctl kickstart gui/\$(id -u)/com.saneapps.agentmemory"
print -u2 "Cloud Access is --login or AGENTMEMORY_MCP_FORCE_CLOUD=1 only."
exit 1
