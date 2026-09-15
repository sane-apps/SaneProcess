#!/bin/zsh
# Token-backed Cloudflare MCP via mcp-remote. Env first, Keychain fallback.
# Usage: cloudflare-mcp-remote.sh https://mcp.cloudflare.com/mcp
set -euo pipefail

url="${1:-}"
case "$url" in
  https://mcp.cloudflare.com/mcp|\
  https://bindings.mcp.cloudflare.com/mcp|\
  https://builds.mcp.cloudflare.com/mcp|\
  https://observability.mcp.cloudflare.com/mcp) ;;
  *)
    print -u2 "usage: ${0:t} https://mcp.cloudflare.com/mcp"
    print -u2 "refusing unexpected Cloudflare MCP URL"
    exit 2
    ;;
esac

loader="${SANE_LOAD_SECRETS_SH:-$HOME/SaneApps/infra/SaneProcess/scripts/sane_load_secrets.sh}"
if [[ -f "$loader" ]]; then
  # shellcheck disable=SC1090
  source "$loader"
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -f "$HOME/.config/nv/env" ]]; then
  set +x
  set -a
  # shellcheck disable=SC1091
  source "$HOME/.config/nv/env"
  set +a
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  set +x
  CLOUDFLARE_API_TOKEN="$(/usr/bin/security find-generic-password -s sane-env -a CLOUDFLARE_API_TOKEN -w 2>/dev/null || true)"
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  print -u2 "CLOUDFLARE_API_TOKEN is missing"
  exit 1
fi

set +x
exec npx -p mcp-remote@0.1.38 mcp-remote "$url" \
  --transport http-only \
  --silent \
  --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
