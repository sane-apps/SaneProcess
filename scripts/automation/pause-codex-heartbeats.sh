#!/bin/bash
# Pause every ACTIVE Codex heartbeat on the Mini. Idempotent.
# Legacy specs remain in ~/.codex/automations for reference.

set -euo pipefail

STORE="$HOME/.codex/automations"
NOW_MS="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"

changed=0
for toml in "$STORE"/*/automation.toml; do
  [[ -f "$toml" ]] || continue
  id="$(basename "$(dirname "$toml")")"
  if ! grep -q '^status = "ACTIVE"' "$toml"; then
    continue
  fi
  if ! grep -q '^kind = "heartbeat"' "$toml"; then
    continue
  fi
  python3 - "$toml" "$NOW_MS" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
now_ms = sys.argv[2]
text = path.read_text(encoding='utf-8')
if 'status = "ACTIVE"' not in text:
    sys.exit(0)
text = text.replace('status = "ACTIVE"', 'status = "PAUSED"', 1)
if re.search(r'^updated_at = ', text, flags=re.M):
    text = re.sub(r'^updated_at = .*$', f'updated_at = {now_ms}', text, count=1, flags=re.M)
else:
    text = text.rstrip() + f"\nupdated_at = {now_ms}\n"
path.write_text(text, encoding='utf-8')
PY
  echo "PAUSED $id"
  changed=$((changed + 1))
done

if [[ "$changed" -eq 0 ]]; then
  echo "No ACTIVE Codex heartbeats to pause."
else
  echo "Paused $changed Codex heartbeat(s)."
fi
