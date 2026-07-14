#!/bin/bash
# Provision the hardened GitHub token file that the status GitHub lanes and
# github-queue.sh read (default ~/.codex/secrets/github_token). The token is
# resolved from the canonical keychain store (service sane-env, account
# GITHUB_TOKEN) and never printed. Both operator machines need this file;
# until 2026-07-14 it existed only where it had been provisioned by hand.
set -euo pipefail
umask 077

PROVISION_SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$PROVISION_SAFE_PATH"
SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"

TOKEN_PATH="${STATUS_GITHUB_TOKEN_FILE:-${HOME}/.codex/secrets/github_token}"
KEYCHAIN_SERVICE="${STATUS_GITHUB_KEYCHAIN_SERVICE:-sane-env}"
KEYCHAIN_ACCOUNT="${STATUS_GITHUB_KEYCHAIN_ACCOUNT:-GITHUB_TOKEN}"

verify_executable() {
  local candidate="${1:-}"
  [[ "$candidate" == /* ]] || return 1
  /usr/bin/ruby -e '
    path = File.realpath(ARGV.fetch(0))
    stat = File.stat(path)
    abort unless stat.file? && stat.executable?
    abort unless [Process.uid, 0].include?(stat.uid)
    abort unless (stat.mode & 0o022).zero?
    puts path
  ' "$candidate" 2>/dev/null
}

SECURITY_BIN="/usr/bin/security"
if [[ "${STATUS_TEST_MODE:-0}" == "1" && -n "${STATUS_SECURITY_BIN:-}" ]]; then
  SECURITY_BIN="$(verify_executable "$STATUS_SECURITY_BIN")" || {
    echo "STATUS_SECURITY_BIN is not a verified executable." >&2
    exit 1
  }
fi

token="$("$SECURITY_BIN" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w 2>/dev/null || true)"
if [[ -z "$token" ]]; then
  echo "No ${KEYCHAIN_ACCOUNT} in keychain service ${KEYCHAIN_SERVICE}." >&2
  echo "Add it to the canonical secret store first; this script never accepts a token via argument or stdin." >&2
  exit 1
fi

token_dir="$(/usr/bin/dirname "$TOKEN_PATH")"
/bin/mkdir -p "$token_dir"
/bin/chmod 700 "$token_dir"
printf '%s' "$token" > "$TOKEN_PATH"
unset token
/bin/chmod 600 "$TOKEN_PATH"

# Validate with the exact reader the status lanes use; discard the token bytes.
export STATUS_GITHUB_TOKEN_SOURCE_PATH="$TOKEN_PATH"
# shellcheck source=sane-status-github.sh
source "${SCRIPT_DIR}/sane-status-github.sh"
if ! status_read_github_token > /dev/null; then
  echo "Provisioned file failed the status reader validation; removing it." >&2
  /bin/rm -f "$TOKEN_PATH"
  exit 1
fi

echo "Provisioned ${TOKEN_PATH} (mode 600, $(/usr/bin/stat -f %z "$TOKEN_PATH") bytes)."
