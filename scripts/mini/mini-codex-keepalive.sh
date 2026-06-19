#!/bin/bash
# Optionally keep the Codex app-server running on the Mac mini.

set -euo pipefail

if [ "${SANEPROCESS_ENABLE_MINI_CODEX_KEEPALIVE:-0}" != "1" ]; then
  exit 0
fi

# The headless app-server daemon is the iPhone/remote-control path. Keep it
# healthy even when a SaneApps app is running; this does not open GUI windows or
# contaminate customer-facing screenshots.
CODEX_BIN="$HOME/.codex/packages/standalone/current/codex"
if [ ! -x "$CODEX_BIN" ]; then
  CODEX_BIN="$(command -v codex 2>/dev/null || true)"
fi

current_version=""
if [ -n "$CODEX_BIN" ]; then
  current_version=$("$CODEX_BIN" --version 2>/dev/null || true)
fi

needs_update=$(python3 - "$current_version" <<'PY'
import re
import sys

match = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1] if len(sys.argv) > 1 else "")
current = tuple(int(part) for part in match.groups()) if match else None
print("0" if current and current >= (0, 139, 0) else "1")
PY
)

install_codex_standalone() {
  installer=$(mktemp "${TMPDIR:-/tmp}/codex-install.XXXXXX") || return 1
  if ! CODEX_NON_INTERACTIVE=1 curl --fail --show-error --silent --proto '=https' --tlsv1.2 --location --max-redirs 0 \
    --output "$installer" \
    https://chatgpt.com/codex/install.sh; then
    rm -f "$installer"
    return 1
  fi
  chmod 600 "$installer"
  if CODEX_NON_INTERACTIVE=1 sh "$installer"; then
    rm -f "$installer"
    return 0
  fi
  status=$?
  rm -f "$installer"
  return "$status"
}

if [ "$needs_update" = "1" ]; then
  install_codex_standalone >/dev/null 2>&1 || true
  CODEX_BIN="$HOME/.codex/packages/standalone/current/codex"
fi

if [ -n "$CODEX_BIN" ]; then
  "$CODEX_BIN" app-server daemon start >/dev/null 2>&1 || true
  "$CODEX_BIN" app-server daemon enable-remote-control >/dev/null 2>&1 || true
fi

SANE_APPS='SaneBar SaneClick SaneClip SaneHosts SaneSales SaneSync SaneVideo'

for app in $SANE_APPS; do
  if pgrep -x "$app" >/dev/null 2>&1; then
    exit 0
  fi
done

if pgrep -x 'Codex' >/dev/null 2>&1 && pgrep -f 'codex app-server' >/dev/null 2>&1; then
  exit 0
fi

open -ga Codex >/dev/null 2>&1 || true
