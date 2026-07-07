#!/bin/bash
# capture-web-screenshot.sh — reliable Mini website screenshot for visual receipts.
#
# Uses Playwright (headless chromium) on the Mini: renders OFF-SCREEN, so there is no
# GUI-session focus problem and no Codex/Terminal window contamination — unlike
# capture-mini-screenshot.sh, which is for the macOS app UI and refuses a dirty workspace.
#
# THIS EXISTS SO NOBODY EVER CLAIMS "a Mini screenshot isn't possible" AGAIN.
# The tools are here. Use them.
#
# Usage:
#   capture-web-screenshot.sh <url> <output_dir> [--label NAME] [--app APP] [--version VER]
#
# Example:
#   capture-web-screenshot.sh https://sanebar.com apps/SaneBar/outputs/visual-audit-2188 \
#     --label donate --app SaneBar --version 2.1.88
#
# After running: OPEN the PNG, confirm the change renders, then set "inspected": true
# in the receipt (top-level AND in the screenshot entry) and fill in "result".
# Do NOT fabricate inspection — the gate validator requires inspected:true on purpose.
set -uo pipefail

MINI_HOST="${MINI_HOST:-stephans-mac-mini.local}"
URL="${1:-}"
OUT_DIR="${2:-}"
if [ -z "$URL" ] || [ -z "$OUT_DIR" ]; then
  echo "usage: capture-web-screenshot.sh <url> <output_dir> [--label NAME] [--app APP] [--version VER]" >&2
  exit 2
fi
shift 2
LABEL="web"; APP="unknown"; VER="unknown"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2;;
    --app) APP="$2"; shift 2;;
    --version) VER="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

STAMP="$(date -u +%Y%m%d-%H%M%S)"
PNG_NAME="${APP}-${LABEL}-mini-${STAMP}.png"
REMOTE_PNG="/tmp/${PNG_NAME}"
mkdir -p "$OUT_DIR"

echo "→ Ensuring Playwright chromium on ${MINI_HOST}..."
if ! ssh "$MINI_HOST" 'command -v playwright >/dev/null 2>&1'; then
  echo "ERROR: playwright CLI not on ${MINI_HOST} PATH. Install: npm i -g playwright && playwright install chromium" >&2
  exit 3
fi
ssh "$MINI_HOST" 'playwright install chromium >/dev/null 2>&1 || true'

echo "→ Capturing ${URL} (full page, headless)..."
if ! ssh "$MINI_HOST" "playwright screenshot --full-page --wait-for-timeout 4000 '${URL}' '${REMOTE_PNG}'"; then
  echo "ERROR: Playwright capture failed on the Mini." >&2
  exit 4
fi

echo "→ Copying screenshot back to ${OUT_DIR}/${PNG_NAME}..."
scp "${MINI_HOST}:${REMOTE_PNG}" "${OUT_DIR}/${PNG_NAME}"
ssh "$MINI_HOST" "rm -f '${REMOTE_PNG}'" >/dev/null 2>&1 || true

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
RECEIPT="${OUT_DIR}/customer_ui_action_receipt.json"
cat > "$RECEIPT" <<JSON
{
  "type": "visual_audit",
  "status": "passed",
  "host": "${MINI_HOST}",
  "inspected": false,
  "app": "${APP}",
  "app_version": "${VER}",
  "commit": "${COMMIT}",
  "generated_at": "${NOW_ISO}",
  "captured_with": "Playwright headless chromium on the Mini (capture-web-screenshot.sh)",
  "url": "${URL}",
  "screenshots": [
    { "path": "${PNG_NAME}", "view": "${URL} full page", "result": "TODO: describe what you SEE rendering correctly", "inspected": false }
  ],
  "notes": "Scaffold from capture-web-screenshot.sh. OPEN the PNG, confirm the change renders, then set inspected:true (top-level + screenshot) and fill in result. Do NOT fabricate."
}
JSON

echo ""
echo "✅ Screenshot: ${OUT_DIR}/${PNG_NAME}"
echo "✅ Receipt scaffold: ${RECEIPT}  (inspected=false — gate stays red until you inspect)"
echo ""
echo "NEXT (required, honest step):"
echo "  1. Open ${OUT_DIR}/${PNG_NAME}; confirm the change actually renders."
echo "  2. In ${RECEIPT}: set inspected=true (top-level + screenshot entry) and fill in result."
