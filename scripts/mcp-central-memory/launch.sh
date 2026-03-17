#!/usr/bin/env bash
# Wrapper that resolves secrets from keychain, then exec's the MCP server.
# Claude Code doesn't expand ${VAR} in .mcp.json env values, so this
# script bridges the gap.
set -euo pipefail

export CENTRAL_MEMORY_DATABASE_URL="${CENTRAL_MEMORY_DATABASE_URL:-postgresql://${USER:-sj}@localhost:5432/central_memory}"
export CENTRAL_MEMORY_EMBED_MODEL="${CENTRAL_MEMORY_EMBED_MODEL:-text-embedding-3-small}"
export CENTRAL_MEMORY_EMBED_DIMENSIONS="${CENTRAL_MEMORY_EMBED_DIMENSIONS:-1536}"
ENV_CACHE_FILE="${SANE_ENV_CACHE_FILE:-$HOME/.config/nv/env}"
KEYCHAIN_FALLBACK_ENABLED="${SANE_KEYCHAIN_FALLBACK:-1}"
[ "${SANE_NO_KEYCHAIN:-0}" = "1" ] && KEYCHAIN_FALLBACK_ENABLED="0"

if [ -f "${ENV_CACHE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENV_CACHE_FILE}"
fi

persist_secret_to_env_cache() {
    local value="$1"
    shift

    [ -n "${value}" ] || return 0
    [ "${SANE_ENV_CACHE_WRITE:-1}" != "0" ] || return 0
    [ $# -gt 0 ] || return 0

    local env_dir
    env_dir="$(dirname "${ENV_CACHE_FILE}")"
    mkdir -p "${env_dir}"
    chmod 700 "${env_dir}" 2>/dev/null || true

    python3 - "${ENV_CACHE_FILE}" "${value}" "$@" <<'PY'
import pathlib
import shlex
import sys

env_path = pathlib.Path(sys.argv[1]).expanduser()
value = sys.argv[2]
names = [name for name in sys.argv[3:] if name]
if not names:
    raise SystemExit(0)

lines = []
if env_path.exists():
    lines = env_path.read_text(encoding="utf-8").splitlines()

filtered = []
for line in lines:
    stripped = line.strip()
    if any(stripped.startswith(f"export {name}=") for name in names):
        continue
    filtered.append(line)

for name in names:
    filtered.append(f"export {name}={shlex.quote(value)}")

env_path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
env_path.chmod(0o600)
PY
}

# Read OpenAI key from env cache first, then keychain only if needed
if [ -z "${OPENAI_API_KEY:-}" ]; then
    if [ "${KEYCHAIN_FALLBACK_ENABLED}" = "1" ]; then
        OPENAI_API_KEY=$(security find-generic-password -s openai -a api_key -w 2>/dev/null || true)
        if [ -n "${OPENAI_API_KEY}" ]; then
            persist_secret_to_env_cache "${OPENAI_API_KEY}" "OPENAI_API_KEY"
        fi
        export OPENAI_API_KEY
    fi
fi

if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "OPENAI_API_KEY not available (keychain lookup failed)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "${SCRIPT_DIR}/server.mjs"
