#!/usr/bin/env bash
# Bounded read-only probe of the `mini-cf` rescue path. Writes a timestamped
# JSON receipt under ~/SaneApps/outputs/mini-cf-probe/. On demand only; the
# auto ladder never calls this.
set -u

OUT_DIR="${SANE_CF_PROBE_DIR:-$HOME/SaneApps/outputs/mini-cf-probe}"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

if [ -n "$TIMEOUT_BIN" ]; then
  # shellcheck disable=SC2086
  out="$($TIMEOUT_BIN 60 ssh -o BatchMode=yes -o ConnectTimeout=20 mini-cf 'hostname; whoami' 2>&1)"
  ssh_status=$?
else
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=20 mini-cf 'hostname; whoami' 2>&1)"
  ssh_status=$?
fi

if [ "$ssh_status" -eq 0 ]; then
  status="pass"
else
  status="fail"
fi

receipt="$OUT_DIR/mini-cf-probe-$STAMP.json"
python3 - "$receipt" "$STAMP" "$status" "$ssh_status" "$out" <<'PY'
import json, sys
_, path, stamp, status, code, output = sys.argv
with open(path, 'w') as f:
    json.dump({"timestamp": stamp, "target": "mini-cf",
               "status": status, "exitstatus": int(code),
               "output": output.strip().splitlines()[:10]}, f, indent=2)
PY

echo "$status: $receipt"
[ "$status" = "pass" ]
