#!/usr/bin/env bash
set -euo pipefail

# Reuse a stable MCP session ID so Xcode can recognize the same agent session
# and avoid repeated trust prompts in a single Xcode process lifetime.
SESSION_FILE="${HOME}/.codex/xcode-mcp-session-id"
mkdir -p "$(dirname "${SESSION_FILE}")"
if [ -f "${SESSION_FILE}" ]; then
  session_id="$(tr -d '\n' < "${SESSION_FILE}" || true)"
else
  session_id=""
fi
if ! [[ "${session_id}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  session_id="$(python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
)"
  printf '%s\n' "${session_id}" > "${SESSION_FILE}"
fi
export MCP_XCODE_SESSION_ID="${session_id}"

# Ensure Xcode is running so mcpbridge can attach.
if ! pgrep -x Xcode >/dev/null 2>&1; then
  if [ -d "/Applications/Xcode.app" ]; then
    open -ga "/Applications/Xcode.app" >/dev/null 2>&1 || true
  else
    open -ga "Xcode" >/dev/null 2>&1 || true
  fi
fi

# Wait for the process and pass an explicit PID to mcpbridge.
for _ in $(seq 1 60); do
  xcode_pid="$(pgrep -x Xcode | head -n 1 || true)"
  if [ -n "${xcode_pid}" ]; then
    export MCP_XCODE_PID="${xcode_pid}"
    exec xcrun mcpbridge
  fi
  sleep 1
done

echo "xcode-mcpbridge-wrapper: Xcode did not start within 60s" >&2
exit 1
