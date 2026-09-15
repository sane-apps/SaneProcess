#!/bin/zsh
# Xcode MCP belongs on the Mini.
# Mini Grok talks NDJSON to mcpbridge.
# Air Grok and the Mini HTTP singleton talk Content-Length, so they use --framed.
set -euo pipefail

framed=0
if [[ "${1:-}" == "--framed" ]]; then
  framed=1
  shift
fi

host="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
host="${host:l}"

frame="$HOME/.grok/bin/xcode-mcp-frame.py"
if [[ ! -x "$frame" ]]; then
  frame="$(cd -- "${0:A:h}" && pwd)/xcode-mcp-frame.py"
fi

wait_for_xcode() {
  local i pid
  for i in {1..20}; do
    pid="$(pgrep -x Xcode | head -n1 || true)"
    if [[ -n "$pid" ]]; then
      export MCP_XCODE_PID="$pid"
      return 0
    fi
    sleep 1
  done
  print -u2 "xcode-mcp: Xcode is not running"
  return 1
}

run_local() {
  wait_for_xcode
  if [[ "$framed" -eq 1 ]]; then
    exec /usr/bin/python3 "$frame" xcrun mcpbridge
  fi
  exec xcrun mcpbridge
}

if [[ "$host" == *mini* ]]; then
  run_local
fi

# Air: prefer the Mini singleton already forwarded by the AgentMemory tunnel.
if /usr/bin/curl --silent --fail --max-time 1 "http://127.0.0.1:37915/healthz" >/dev/null 2>&1; then
  print -u2 "xcode-mcp: Mini singleton is on 127.0.0.1:37915; point Grok at that HTTP URL"
fi

exec /usr/bin/python3 "$frame" /usr/bin/ssh -T -o BatchMode=yes -o ConnectTimeout=10 mini \
  'exec "$HOME/.grok/bin/xcode-mcp.sh" --framed'
