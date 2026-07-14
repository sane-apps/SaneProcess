#!/usr/bin/env bash
set -euo pipefail

# Gives the Mini a dedicated, restart-durable SSH identity for recovery and
# server-to-controller operations on the Air. The key is not an agent-forwarded
# GitHub/signing credential and grants an ordinary interactive Air shell.

AIR_HOST="${SANE_AIR_HOST:-100.64.240.115}"
AIR_USER="${SANE_AIR_USER:-sj}"
AIR_TARGET="${SANE_AIR_BOOTSTRAP_TARGET:-$AIR_USER@$AIR_HOST}"
KEY_FILE="${SANE_AIR_KEY_FILE:-$HOME/.ssh/saneapps-mini-to-air}"
CONFIG_DIR="${SANE_AIR_CONFIG_DIR:-$HOME/.ssh/config.d}"
CONFIG_FILE="${SANE_AIR_CONFIG_FILE:-$HOME/.ssh/config}"
AIR_CONFIG="${SANE_AIR_CONFIG:-$CONFIG_DIR/saneapps-air.conf}"
SSH="${SANE_SSH_BIN:-/usr/bin/ssh}"
SSH_KEYGEN="${SANE_SSH_KEYGEN_BIN:-/usr/bin/ssh-keygen}"
INSTALL_REMOTE=1

case "${1:-}" in
  '') ;;
  --config-only) INSTALL_REMOTE=0 ;;
  *) echo "Usage: $0 [--config-only]" >&2; exit 2 ;;
esac

mkdir -p "$HOME/.ssh" "$CONFIG_DIR"
chmod 700 "$HOME/.ssh"
touch "$CONFIG_FILE"

if [[ ! -f "$KEY_FILE" || ! -f "$KEY_FILE.pub" ]]; then
  [[ ! -e "$KEY_FILE" && ! -e "$KEY_FILE.pub" ]] || {
    echo "Incomplete Mini-to-Air keypair at $KEY_FILE; repair it deliberately." >&2
    exit 1
  }
  "$SSH_KEYGEN" -q -t ed25519 -N '' -C saneapps-mini-to-air -f "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"
chmod 644 "$KEY_FILE.pub"

if [[ "$INSTALL_REMOTE" -eq 1 ]]; then
  # Ignore the not-yet-installed Host stanza for this one bootstrap connection.
  # Existing local authentication may be an ssh-agent or a one-time password.
  public_key="$(<"$KEY_FILE.pub")"
  printf '%s\n' "$public_key" | "$SSH" -F /dev/null \
    -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$AIR_TARGET" '
      set -eu
      umask 077
      mkdir -p "$HOME/.ssh"
      touch "$HOME/.ssh/authorized_keys"
      key="$(/bin/cat)"
      /usr/bin/grep -qxF "$key" "$HOME/.ssh/authorized_keys" || printf "%s\n" "$key" >> "$HOME/.ssh/authorized_keys"
      chmod 700 "$HOME/.ssh"
      chmod 600 "$HOME/.ssh/authorized_keys"
    '
fi

if ! /usr/bin/grep -q '^Include ~/.ssh/config.d/\*.conf' "$CONFIG_FILE"; then
  tmp_file="$(/usr/bin/mktemp)"
  {
    printf 'Include ~/.ssh/config.d/*.conf\n\n'
    /bin/cat "$CONFIG_FILE"
  } > "$tmp_file"
  /bin/mv "$tmp_file" "$CONFIG_FILE"
fi

cat > "$AIR_CONFIG" <<EOF
Host air air-remote $AIR_HOST
  HostName $AIR_HOST
  User $AIR_USER
  IdentityFile $KEY_FILE
  IdentitiesOnly yes
  ForwardAgent no
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 3
  ConnectTimeout 15
EOF

chmod 600 "$CONFIG_FILE" "$AIR_CONFIG"

if [[ "$INSTALL_REMOTE" -eq 1 ]]; then
  "$SSH" -o BatchMode=yes air 'hostname; /usr/bin/whoami'
fi

echo "Installed durable Mini-to-Air SSH route: ssh air"
