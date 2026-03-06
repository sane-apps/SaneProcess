#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/sj/SaneApps"
OUT_DIR="$ROOT/outputs/website-consistency-$(date +%F)"
REPORT="$OUT_DIR/report.tsv"
SUMMARY="$OUT_DIR/summary.md"

mkdir -p "$OUT_DIR"
echo -e "status\tcheck\tfile" > "$REPORT"

PASS_COUNT=0
FAIL_COUNT=0

record_result() {
  local status="$1"
  local check="$2"
  local file="$3"
  echo -e "${status}\t${check}\t${file}" >> "$REPORT"
  if [[ "$status" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q --fixed-strings "$pattern" "$file"; then
    record_result "PASS" "$label" "$file"
  else
    record_result "FAIL" "$label" "$file"
  fi
}

check_absent() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q --fixed-strings "$pattern" "$file"; then
    record_result "FAIL" "$label" "$file"
  else
    record_result "PASS" "$label" "$file"
  fi
}

PRODUCT_INDEX_FILES=(
  "$ROOT/apps/SaneBar/docs/index.html"
  "$ROOT/apps/SaneClip/docs/index.html"
  "$ROOT/apps/SaneClick/docs/index.html"
  "$ROOT/apps/SaneSales/docs/index.html"
  "$ROOT/apps/SaneHosts/website/index.html"
)

GUIDE_HUB_FILES=(
  "$ROOT/apps/SaneBar/docs/guides.html"
  "$ROOT/apps/SaneClip/docs/guides.html"
  "$ROOT/apps/SaneClick/docs/guides.html"
  "$ROOT/apps/SaneSales/docs/guides.html"
  "$ROOT/apps/SaneHosts/website/guides.html"
  "$ROOT/web/saneapps.com/guides.html"
)

for file in "${PRODUCT_INDEX_FILES[@]}"; do
  check_contains "$file" "Donate" "nav-donate-label"
  check_contains "$file" "data-cta=\"download_free\"" "cta-download-free"
  check_contains "$file" "data-cta=\"buy_pro\"" "cta-buy-pro"
  check_contains "$file" "trackCta(" "cta-tracking-function"
  check_contains "$file" "crypto_copy" "cta-crypto-copy-event"
  check_contains "$file" "How it works:" "crypto-how-it-works"
  check_contains "$file" "transaction ID or screenshot" "crypto-proof-copy"
done

check_contains "$ROOT/apps/SaneSales/docs/index.html" "What happens after I pay with crypto?" "faq-crypto-payment"
check_absent "$ROOT/apps/SaneSales/docs/index.html" "sticky-cta" "sanesales-sticky-cta-removed"

check_contains "$ROOT/web/saneapps.com/index.html" "How it works:" "saneapps-crypto-how-it-works"
check_contains "$ROOT/web/saneapps.com/index.html" "What happens after I pay with crypto?" "saneapps-crypto-faq"
check_contains "$ROOT/web/saneapps.com/index.html" "trackCta(" "saneapps-crypto-tracking"

for file in "${GUIDE_HUB_FILES[@]}"; do
  check_contains "$file" "Mobile Guide Guardrails" "guides-mobile-guardrails"
  check_contains "$file" "Donate" "guides-donate-cta"
done

{
  echo "# Website Consistency Check"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- Pass: $PASS_COUNT"
  echo "- Fail: $FAIL_COUNT"
  echo "- Report: $REPORT"
} > "$SUMMARY"

echo "Wrote:"
echo "  $REPORT"
echo "  $SUMMARY"
echo "Pass: $PASS_COUNT | Fail: $FAIL_COUNT"

if [[ $FAIL_COUNT -gt 0 ]]; then
  exit 1
fi
