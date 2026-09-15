#!/bin/bash
# Read-only SaneCite Monday health sweep. Replaces the Claude scheduled skill.
# Launchd should pass --email. Manual e2e omits --email.

set -euo pipefail

export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

EMAIL=0
if [[ "${1:-}" == "--email" ]]; then
  EMAIL=1
fi

OUT_DIR="$HOME/SaneApps/outputs/sanecite-monday-sweep"
LOCK_DIR="$OUT_DIR/.lock"
mkdir -p "$OUT_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "skip: prior sweep still holds lock"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

STAMP="$(date +%Y%m%dT%H%M%SZ)"
RECEIPT="$OUT_DIR/$STAMP.json"
BODY="$OUT_DIR/$STAMP.md"
FAILS=0

check() {
  local name="$1"
  local expected="$2"
  shift 2
  local got
  got="$("$@" 2>/dev/null || true)"
  if [[ "$got" == *"$expected"* ]]; then
    echo "PASS $name"
    return 0
  fi
  echo "FAIL $name expected=$expected got=${got:0:180}"
  FAILS=$((FAILS + 1))
  return 1
}

{
  echo "# SaneCite Monday sweep"
  echo
  echo "Generated $(date -Iseconds)"
  echo

  code="$(curl -sS -o /tmp/sc-health.json -w '%{http_code}' --max-time 20 https://app.sanecite.com/health || true)"
  if [[ "$code" == "200" ]] && python3 -c 'import json,sys; d=json.load(open("/tmp/sc-health.json")); sys.exit(0 if d.get("ok") is True else 1)'; then
    echo "PASS app /health"
  else
    echo "FAIL app /health http=$code"
    FAILS=$((FAILS + 1))
  fi

  hdr="$(curl -sSI --max-time 20 https://app.sanecite.com/ || true)"
  for h in content-security-policy strict-transport-security x-frame-options x-content-type-options; do
    echo "$hdr" | grep -qi "^$h:" && echo "PASS header $h" || { echo "FAIL header $h"; FAILS=$((FAILS + 1)); }
  done

  iso="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X POST https://app.sanecite.com/answer -H 'content-type: application/json' -d '{"question":"x"}' || true)"
  if [[ "$iso" == "401" ]]; then
    echo "PASS tenant isolation missing accountId"
  else
    echo "FAIL tenant isolation missing accountId http=$iso"
    FAILS=$((FAILS + 1))
  fi

  mcode="$(curl -sS -o /tmp/sc-home.html -w '%{http_code}' --max-time 20 https://sanecite.com/ || true)"
  if [[ "$mcode" == "200" ]] && grep -q "Accurate, or it's free" /tmp/sc-home.html; then
    echo "PASS marketing home"
  else
    echo "FAIL marketing home http=$mcode"
    FAILS=$((FAILS + 1))
  fi

  echo
  echo "failures=$FAILS"
} | tee "$BODY"

python3 - "$RECEIPT" "$FAILS" "$BODY" <<'PY'
import json, sys
json.dump({"generated_at": __import__("datetime").datetime.utcnow().isoformat()+"Z",
           "failures": int(sys.argv[2]), "body": sys.argv[3], "ok": int(sys.argv[2])==0},
          open(sys.argv[1],"w"), indent=2)
print(sys.argv[1])
PY

if [[ "$EMAIL" -eq 1 ]]; then
  if [[ "$FAILS" -eq 0 ]]; then
    subject="SaneCite Monday sweep: all clear"
  else
    subject="SaneCite Monday sweep: $FAILS FAILURE(S), action needed"
  fi
  "$HOME/SaneApps/infra/scripts/send-internal-report.sh" "$subject" "$BODY"
fi

[[ "$FAILS" -eq 0 ]]
