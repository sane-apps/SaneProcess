#!/bin/bash
# Optionally keep the Codex app-server running on the Mac mini.

set -euo pipefail

if [ "${SANEPROCESS_ENABLE_MINI_CODEX_KEEPALIVE:-0}" != "1" ]; then
  exit 0
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
