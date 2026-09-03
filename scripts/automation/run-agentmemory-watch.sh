#!/bin/bash
# Air-side AgentMemory watch: thin livez/health/search acceptance + notify on red.
# Recovers a zombie Air tunnel once, then fails loud. Does not reinstall Mini.
set -euo pipefail

host="$(hostname -s 2>/dev/null || hostname)"
if [[ "$host" == *[Mm]ini* ]]; then
  echo "Refusing agentmemory watch on Mini host $host (Air-owned)" >&2
  exit 2
fi

ROOT="${SANEPROCESS_ROOT:-$HOME/SaneApps/infra/SaneProcess}"
RUBY="${SANE_RUBY_BIN:-/opt/homebrew/opt/ruby/bin/ruby}"
OUT_DIR="${SANE_AGENTMEMORY_WATCH_OUT:-$ROOT/outputs/agentmemory-watch}"
LOCK_DIR="${SANE_AGENTMEMORY_WATCH_LOCK:-$OUT_DIR/.lock}"
LABEL="${SANE_AGENTMEMORY_TUNNEL_LABEL:-com.saneapps.agentmemory-tunnel}"
LAUNCHCTL="${SANE_LAUNCHCTL_BIN:-/bin/launchctl}"
CURL="${SANE_CURL_BIN:-/usr/bin/curl}"
NOTIFY="${SANE_AGENTMEMORY_WATCH_NOTIFY:-1}"

mkdir -p "$OUT_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "agentmemory watch already running (lock $LOCK_DIR)" >&2
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

notify() {
  local title="$1"
  local body="$2"
  [[ "$NOTIFY" == "1" ]] || return 0
  /usr/bin/osascript -e "display notification $(printf '%s' "$body" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') with title $(printf '%s' "$title" | /usr/bin/python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') sound name \"Basso\"" 2>/dev/null || true
}

probe_air_livez() {
  "$CURL" --silent --fail --max-time 3 "http://127.0.0.1:3111/agentmemory/livez" >/dev/null 2>&1
}

# One bounded tunnel recovery before the acceptance slice.
if ! probe_air_livez; then
  echo "Air livez failed; kickstarting $LABEL once" >&2
  "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  attempt=1
  while [[ "$attempt" -le 10 ]]; do
    probe_air_livez && break
    sleep 1
    attempt=$((attempt + 1))
  done
fi

set +e
"$RUBY" "$ROOT/scripts/automation/air_mini_acceptance.rb" \
  --memory-only \
  --json \
  --output "$OUT_DIR" >"$OUT_DIR/latest.json" 2>"$OUT_DIR/latest.stderr"
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  fails="$(/usr/bin/python3 - <<'PY' "$OUT_DIR/latest.json" 2>/dev/null || true
import json,sys
path=sys.argv[1]
try:
  data=json.load(open(path))
except Exception:
  print("acceptance failed (no receipt)")
  raise SystemExit
failed=[c.get("id","?") for c in data.get("checks",[]) if not c.get("passed")]
print(", ".join(failed) if failed else "memory-only acceptance failed")
PY
)"
  echo "FAIL agentmemory watch: $fails" >&2
  notify "AgentMemory watch FAIL" "$fails"
  exit 1
fi

echo "PASS agentmemory watch"
exit 0
