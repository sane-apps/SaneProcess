#!/bin/bash
# Notify only when macOS 27 is a stable public release. Replaces Codex
# `revisit-sanebar-after-macos-27`. No SaneBar code changes.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
OUT_DIR="$HOME/SaneApps/outputs/sanebar-macos27-watch"
mkdir -p "$OUT_DIR"
PAGE="$OUT_DIR/releases.html"
RECEIPT="$OUT_DIR/latest.json"

curl -fsS --max-time 25 -A "SaneApps-macos27-watch" \
  "https://developer.apple.com/news/releases/" -o "$PAGE"

python3 - "$PAGE" "$RECEIPT" <<'PY'
import json, pathlib, re, sys
html = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
stable = bool(re.search(r"macOS\s+27(?!\s*(beta|preview|RC|Release Candidate))", html, re.I))
beta = bool(re.search(r"macOS\s+27.{0,40}(beta|preview)", html, re.I))
payload = {
    "ok": True,
    "macos_27_mentioned": "macOS 27" in html or "macOS27" in html,
    "looks_stable_public": stable and not beta,
    "looks_beta": beta,
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print(json.dumps(payload))
if payload["looks_stable_public"]:
    raise SystemExit(10)
PY
STATUS=$?
if [[ "$STATUS" -eq 10 ]]; then
  osascript -e 'display notification "macOS 27 looks like a public stable release. Revisit SaneBar vs Thaw." with title "SaneBar" sound name "Glass"' || true
  echo "NOTIFY macos 27 public"
  exit 0
fi
exit "$STATUS"
