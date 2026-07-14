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

find_xcode_pid() {
  # pgrep/ps are intentionally unavailable in some Codex sandboxes. launchd's
  # GUI-domain inventory is still readable there and identifies the real Xcode
  # application process without weakening the sandbox.
  local pid=""
  pid="$(pgrep -x Xcode 2>/dev/null | head -n 1 || true)"
  if [ -z "${pid}" ]; then
    pid="$(launchctl print "gui/$(id -u)" 2>/dev/null | awk '
      $1 ~ /^[0-9]+$/ && $3 ~ /^application\.com\.apple\.dt\.Xcode\./ { print $1; exit }
    ')"
  fi
  printf '%s' "${pid}"
}

# Ensure Xcode is running so mcpbridge can attach.
if [ -z "$(find_xcode_pid)" ]; then
  if [ -d "/Applications/Xcode.app" ]; then
    open -ga "/Applications/Xcode.app" >/dev/null 2>&1 || true
  else
    open -ga "Xcode" >/dev/null 2>&1 || true
  fi
fi

# Wait for the process and pass an explicit PID to mcpbridge.
for _ in $(seq 1 60); do
  xcode_pid="$(find_xcode_pid)"
  if [ -n "${xcode_pid}" ]; then
    export MCP_XCODE_PID="${xcode_pid}"
    exec xcrun mcpbridge
  fi
  # LaunchServices can transiently lose the application registration after an
  # Xcode update. The signed app executable remains the canonical fallback.
  if [ "${_}" -eq 3 ] && [ -x "/Applications/Xcode.app/Contents/MacOS/Xcode" ]; then
    /Applications/Xcode.app/Contents/MacOS/Xcode >/dev/null 2>&1 &
  fi
  sleep 1
done

echo "xcode-mcpbridge-wrapper: Xcode did not start within 60s" >&2
exit 1
