#!/bin/bash
# Air-side MCP shim for the shared AgentMemory server on the always-on Mini.
# Reuse an existing local tunnel or create one with a bounded SSH attempt, then
# run the stdio MCP shim against loopback. A temporarily unreachable Mini must
# never hang an Air agent session.
set -uo pipefail

if ! nc -z 127.0.0.1 3111 >/dev/null 2>&1; then
  ssh -f -N -o ConnectTimeout=3 -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -L 3111:127.0.0.1:3111 mini >/dev/null 2>&1 || true
fi

export AGENTMEMORY_URL="http://localhost:3111"
exec npx -y @agentmemory/mcp
