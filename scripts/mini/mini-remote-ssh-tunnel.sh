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

# Mini Directory Services/DNS can fail while /etc/resolv.conf + dig still work.
# Keep the tunnel bridge alive through that state by avoiding macOS resolver APIs.
export GODEBUG="${GODEBUG:+$GODEBUG,}netdns=go,x509usefallbackroots=1"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"

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

  local api_ip
  api_ip="$(dig +short api.cloudflare.com A | head -n 1)"
  if [ -z "$api_ip" ]; then
    echo "$(date -u +%FT%TZ) failed to resolve api.cloudflare.com with dig" >> "$LOG_FILE"
    return 1
  fi

  local existing_id
  existing_id="$(curl -fsS --connect-to "api.cloudflare.com:443:$api_ip:443" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records?type=TXT&name=$TXT_NAME" |
    ruby -rjson -e 'j=JSON.parse(STDIN.read); puts(j["result"].first && j["result"].first["id"])')"

  if [ -n "$existing_id" ]; then
    curl -fsS --connect-to "api.cloudflare.com:443:$api_ip:443" \
      -X PUT -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$payload" \
      "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records/$existing_id" >/dev/null
  else
    curl -fsS --connect-to "api.cloudflare.com:443:$api_ip:443" \
      -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$payload" \
      "https://api.cloudflare.com/client/v4/zones/$ACCOUNT_ZONE_ID/dns_records" >/dev/null
  fi

  echo "$(date -u +%FT%TZ) published $TXT_NAME=$host" >> "$LOG_FILE"
}

allocate_quick_tunnel() {
  local api_ip
  api_ip="$(dig +short api.trycloudflare.com A | head -n 1)"
  if [ -z "$api_ip" ]; then
    echo "$(date -u +%FT%TZ) failed to resolve api.trycloudflare.com with dig" >> "$LOG_FILE"
    return 1
  fi

  curl -fsS --connect-to "api.trycloudflare.com:443:$api_ip:443" \
    -X POST https://api.trycloudflare.com/tunnel
}

quick_tunnel_json="$(allocate_quick_tunnel)"
credentials_file="$LOG_DIR/mini-quick-tunnel-credentials.json"
quick_tunnel_host="$(
  printf '%s' "$quick_tunnel_json" |
    ruby -rjson -e 'j=JSON.parse(STDIN.read); print j.fetch("result").fetch("hostname")'
)"

printf '%s' "$quick_tunnel_json" | ruby -rjson -e '
  j = JSON.parse(STDIN.read).fetch("result")
  print({
    AccountTag: j.fetch("account_tag"),
    TunnelID: j.fetch("id"),
    TunnelName: j.fetch("name"),
    TunnelSecret: j.fetch("secret")
  }.to_json)
' <<<"$quick_tunnel_json" > "$credentials_file"
chmod 600 "$credentials_file"

publish_host "$quick_tunnel_host"

quick_tunnel_id="$(
  printf '%s' "$quick_tunnel_json" |
    ruby -rjson -e 'j=JSON.parse(STDIN.read); print j.fetch("result").fetch("id")'
)"
echo "$(date -u +%FT%TZ) starting tunnel $quick_tunnel_host ($quick_tunnel_id)" >> "$LOG_FILE"

"$CLOUDFLARED" tunnel \
  --no-autoupdate \
  --no-prechecks \
  --edge-ip-version 4 \
  --loglevel info \
  run \
  --credentials-file "$credentials_file" \
  --url ssh://localhost:22 \
  "$quick_tunnel_id" 2>&1 |
while IFS= read -r line; do
  echo "$line" >> "$LOG_FILE"
done
