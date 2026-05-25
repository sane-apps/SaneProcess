#!/bin/bash
# Ensure Codex app-server stays running on Mac mini.

set -euo pipefail

if pgrep -x 'Codex' >/dev/null 2>&1 && pgrep -f 'codex app-server' >/dev/null 2>&1; then
  exit 0
fi

open -ga Codex >/dev/null 2>&1 || true
