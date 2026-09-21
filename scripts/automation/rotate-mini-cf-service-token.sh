#!/usr/bin/env bash
# Rotates the mini-cf Access service token (yearly; current one expires
# 2027-09-21) with zero SSH downtime: create successor, repoint the policy,
# prove the new credentials at the edge, then delete the predecessor.
#
# Requires CLOUDFLARE_SETUP_TOKEN in ~/.config/nv/env: a short-lived dashboard
# token with Account / Access: Apps and Policies / Edit (mint at
# dash.cloudflare.com -> API Tokens -> Custom token, 7-day expiry). The setup
# token cannot delete itself (no token-management scope), so delete it in the
# dashboard afterward and purge it from env/keychain.
#
# Prints IDs and lengths only, never secrets.
set -euo pipefail

ACCOUNT_ID="${SANE_CF_ACCOUNT_ID:-2c267ab06352ba2522114c3081a8c5fa}"
APP_ID="${SANE_CF_MINI_SSH_APP_ID:-3a29736c-8598-48ce-a410-ed8f724d1e14}"
POLICY_ID="${SANE_CF_MINI_SSH_SVC_POLICY_ID:-b94426b0-61c6-4e28-95c6-381c2293d8de}"
TOKEN_NAME="${SANE_CF_MINI_SSH_TOKEN_NAME:-mini-ssh-rescue}"
HOSTNAME="${SANE_CF_MINI_SSH_HOST:-mini-ssh.saneapps.com}"
ENV_FILE="${SANE_ENV_FILE:-$HOME/.config/nv/env}"

[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
[ -n "${CLOUDFLARE_SETUP_TOKEN:-}" ] || { echo "Set CLOUDFLARE_SETUP_TOKEN first (see header)." >&2; exit 1; }

API="https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID"
TMP_NEW="$(mktemp)"; chmod 600 "$TMP_NEW"; trap 'rm -f "$TMP_NEW"' EXIT

echo "Creating successor token..."
curl -s --connect-timeout 10 --max-time 30 -X POST \
  -H "Authorization: Bearer $CLOUDFLARE_SETUP_TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"$TOKEN_NAME-next\"}" "$API/access/service_tokens" > "$TMP_NEW"
NEW_ID="$(python3 -c "import json; d=json.load(open('$TMP_NEW')); print(d['result']['id'] if d.get('success') else '')")"
[ -n "$NEW_ID" ] || { echo "Token create failed." >&2; exit 1; }
echo "Successor: $NEW_ID"

echo "Repointing policy..."
POL_OK="$(curl -s --connect-timeout 10 --max-time 30 -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_SETUP_TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"Rescue service token\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"$NEW_ID\"}}]}" \
  "$API/access/apps/$APP_ID/policies/$POLICY_ID" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success'))")"
[ "$POL_OK" = "True" ] || { echo "Policy update failed; successor $NEW_ID orphaned (delete it)." >&2; exit 1; }

echo "Saving successor to env + keychain..."
NEW_CID="$(python3 -c "import json; print(json.load(open('$TMP_NEW'))['result']['client_id'])")"
NEW_SEC="$(python3 -c "import json; print(json.load(open('$TMP_NEW'))['result']['client_secret'])")"
python3 - "$ENV_FILE" "$NEW_CID" CF_MINI_SSH_CLIENT_ID "$NEW_SEC" CF_MINI_SSH_CLIENT_SECRET <<'PY'
import pathlib, shlex, sys
env_path = pathlib.Path(sys.argv[1]).expanduser()
pairs = [(sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])]
lines = env_path.read_text(encoding='utf-8').splitlines() if env_path.exists() else []
names = [n for _, n in pairs]
filtered = [l for l in lines if not any(l.strip().startswith(f'export {n}=') for n in names)]
for value, name in pairs:
    filtered.append(f'export {name}={shlex.quote(value)}')
env_path.write_text('\n'.join(filtered) + '\n', encoding='utf-8')
env_path.chmod(0o600)
print('env saved')
PY
security add-generic-password -U -a "mini_ssh_client_id" -s "cloudflare" -w "$NEW_CID" >/dev/null \
  && security add-generic-password -U -a "mini_ssh_client_secret" -s "cloudflare" -w "$NEW_SEC" >/dev/null \
  && echo "keychain saved"

echo "Proving successor at the edge (need HTTP 200)..."
sleep 8
PROBE="$(python3 - "$NEW_CID" "$NEW_SEC" "$HOSTNAME" <<'PY'
import ssl, sys, urllib.request, urllib.error
_, cid, sec, host = sys.argv
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
ctx = ssl.create_default_context()
class NoRedir(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None
opener = urllib.request.build_opener(NoRedir, urllib.request.HTTPSHandler(context=ctx))
req = urllib.request.Request(f'https://{host}/', headers={'User-Agent': UA, 'CF-Access-Client-Id': cid, 'CF-Access-Client-Secret': sec})
try:
    print(opener.open(req, timeout=15).status)
except urllib.error.HTTPError as e:
    print(f'HTTP {e.code}')
PY
)"
echo "Edge verdict: $PROBE"
[ "$PROBE" = "200" ] || { echo "Successor rejected; old token still live in policy? Investigate before deleting anything." >&2; exit 1; }

echo "Deleting predecessor(s) by name..."
curl -s --connect-timeout 10 --max-time 30 -H "Authorization: Bearer $CLOUDFLARE_SETUP_TOKEN" \
  "$API/access/service_tokens" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in (d.get('result') or []):
    if t.get('name') == '$TOKEN_NAME':
        print(t['id'])
" | while read -r OLD_ID; do
  [ -n "$OLD_ID" ] || continue
  curl -s --connect-timeout 10 --max-time 30 -X DELETE \
    -H "Authorization: Bearer $CLOUDFLARE_SETUP_TOKEN" "$API/access/service_tokens/$OLD_ID" \
    | python3 -c "import json,sys; print('deleted $OLD_ID:', json.load(sys.stdin).get('success'))"
done
curl -s --connect-timeout 10 --max-time 30 -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_SETUP_TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"$TOKEN_NAME\"}" "$API/access/service_tokens/$NEW_ID" \
  | python3 -c "import json,sys; print('renamed successor:', json.load(sys.stdin).get('success'))"

echo "Rotation complete. Delete CLOUDFLARE_SETUP_TOKEN in the dashboard, then purge it from env/keychain."
