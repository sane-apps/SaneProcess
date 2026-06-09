#!/bin/bash
# Optionally keep the Codex app-server running on the Mac mini.

set -euo pipefail

if [ "${SANEPROCESS_ENABLE_MINI_CODEX_KEEPALIVE:-0}" != "1" ]; then
  exit 0
fi

# The headless app-server daemon is the iPhone/remote-control path. Keep it
# healthy even when a SaneApps app is running; this does not open GUI windows or
# contaminate customer-facing screenshots.
if command -v codex >/dev/null 2>&1; then
  codex app-server daemon start >/dev/null 2>&1 || true
  codex app-server daemon enable-remote-control >/dev/null 2>&1 || true
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
