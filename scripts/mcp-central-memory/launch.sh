#!/usr/bin/env bash
# Wrapper that resolves secrets from keychain, then exec's the MCP server.
# Claude Code doesn't expand ${VAR} in .mcp.json env values, so this
# script bridges the gap.
set -euo pipefail

export CENTRAL_MEMORY_DATABASE_URL="${CENTRAL_MEMORY_DATABASE_URL:-postgresql://localhost:5432/central_memory}"
export CENTRAL_MEMORY_EMBED_MODEL="${CENTRAL_MEMORY_EMBED_MODEL:-text-embedding-3-small}"
export CENTRAL_MEMORY_EMBED_DIMENSIONS="${CENTRAL_MEMORY_EMBED_DIMENSIONS:-1536}"

# Read OpenAI key from keychain if not already set
if [ -z "${OPENAI_API_KEY:-}" ]; then
    OPENAI_API_KEY=$(security find-generic-password -s openai -a api_key -w 2>/dev/null || true)
    export OPENAI_API_KEY
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "OPENAI_API_KEY not available (keychain lookup failed)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "${SCRIPT_DIR}/server.mjs"
