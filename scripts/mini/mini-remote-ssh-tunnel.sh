#!/usr/bin/env bash
set -euo pipefail

# Keeps an accountless Cloudflare quick tunnel open for Mini SSH and publishes
# the current trycloudflare hostname to DNS TXT. This is the current bridge
# until a named Cloudflare Zero Trust tunnel or Tailscale replaces it.

ACCOUNT_ZONE_ID="8d49a4868435740853aab3372a393ee5"
TXT_NAME="mini-ssh-host.saneapps.com"
LOG_DIR="$HOME/Library/Logs/SaneApps"
LOG_FILE="$LOG_DIR/mini-remote-ssh-tunnel.log"
CLOUDFLARED="/opt/homebrew/bin/cloudflared"

mkdir -p "$LOG_DIR"

if [ -f "$HOME/.config/nv/env" ]; then
  # shellcheck disable=SC1090
  source "$HOME/.config/nv/env"
fi

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "$(date -u +%FT%TZ) missing CLOUDFLARE_API_TOKEN" >> "$LOG_FILE"
  exit 1
fi

if [ ! -x "$CLOUDFLARED" ]; then
  echo "$(date -u +%FT%TZ) missing cloudflared at $CLOUDFLARED" >> "$LOG_FILE"
  exit 1
fi

publish_host() {
  local host="$1"
  local payload
  payload="$(ruby -rjson -e 'print({type:"TXT", name:ARGV[0], content:ARGV[1], ttl:120, comment:"Current Mini SSH quick tunnel"}.to_json)' "$TXT_NAME" "$host")"

  local existing_id
  existing_id="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records?type=TXT&name=$TXT_NAME" |
    ruby -rjson -e 'j=JSON.parse(STDIN.read); puts(j["result"].first && j["result"].first["id"])')"

  if [ -n "$existing_id" ]; then
    curl -fsS -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$payload" \
      "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records/$existing_id" >/dev/null
  else
    curl -fsS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$payload" \
      "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records" >/dev/null
  fi

  echo "$(date -u +%FT%TZ) published $TXT_NAME=$host" >> "$LOG_FILE"
}

"$CLOUDFLARED" tunnel --url ssh://localhost:22 --loglevel info 2>&1 |
while IFS= read -r line; do
  echo "$line" >> "$LOG_FILE"
  if [[ "$line" =~ https://([a-z0-9-]+\.trycloudflare\.com) ]]; then
    publish_host "${BASH_REMATCH[1]}"
  fi
done
