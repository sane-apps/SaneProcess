#!/bin/bash
# Daily Report Generator - SaneApps business intelligence
# Runs at 7 PM EST daily via LaunchAgent (com.saneapps.daily-report)
#
# Architecture: fetch raw data -> deterministic concise markdown report
# Optional legacy nv summary stays opt-in via SANE_ENABLE_LEGACY_NV_SUMMARY=1.
# Goal: scannable in 30 seconds, actionable, no noise

set -uo pipefail

# Load API keys for LaunchAgent context (keychain not accessible)
if [[ -f "$HOME/.config/nv/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.config/nv/env"
fi

ENV_CACHE_FILE="${SANE_ENV_CACHE_FILE:-$HOME/.config/nv/env}"
KEYCHAIN_FALLBACK_ENABLED="${SANE_KEYCHAIN_FALLBACK:-1}"
[[ "${SANE_NO_KEYCHAIN:-0}" == "1" ]] && KEYCHAIN_FALLBACK_ENABLED="0"

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_QUEUE="$SCRIPT_DIR/github-queue.sh"
OUTPUT_DIR="$HOME/SaneApps/infra/SaneProcess/outputs"
REPORT_FILE="$OUTPUT_DIR/morning_report.md"
ARCHIVE_DIR="$OUTPUT_DIR/reports"
CACHE_DIR="$OUTPUT_DIR/.cache"
APPS_DIR="$HOME/SaneApps/apps"
PRODUCTS_YML="$HOME/SaneApps/infra/SaneProcess/config/products.yml"
DATE_DISPLAY=$(date +"%Y-%m-%d %A")
DATE=$(date +"%Y-%m-%d")
YESTERDAY_DATE=$(date -v-1d +"%Y-%m-%d")
WEEK_AGO=$(date -v-7d +"%Y-%m-%d")
GH_ORG="sane-apps"
PRODUCT_SITES=""
REPOS=""

mkdir -p "$CACHE_DIR" "$ARCHIVE_DIR"

persist_secret_to_env_cache() {
  local value="$1"
  shift

  [[ -n "$value" ]] || return 0
  [[ "${SANE_ENV_CACHE_WRITE:-1}" != "0" ]] || return 0
  [[ $# -gt 0 ]] || return 0

  local env_dir
  env_dir="$(dirname "$ENV_CACHE_FILE")"
  mkdir -p "$env_dir"
  chmod 700 "$env_dir" 2>/dev/null || true

  python3 - "$ENV_CACHE_FILE" "$value" "$@" <<'PY'
import pathlib
import shlex
import sys

env_path = pathlib.Path(sys.argv[1]).expanduser()
value = sys.argv[2]
names = [name for name in sys.argv[3:] if name]
if not names:
    raise SystemExit(0)

lines = []
if env_path.exists():
    lines = env_path.read_text(encoding="utf-8").splitlines()

filtered = []
for line in lines:
    stripped = line.strip()
    if any(stripped.startswith(f"export {name}=") for name in names):
        continue
    filtered.append(line)

for name in names:
    filtered.append(f"export {name}={shlex.quote(value)}")

env_path.write_text("\n".join(filtered) + "\n", encoding="utf-8")
env_path.chmod(0o600)
PY
}

load_secret() {
  local service="$1"
  local account="$2"
  shift 2

  local env_name value=""
  for env_name in "$@"; do
    value="${!env_name:-}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done

  if [[ "$KEYCHAIN_FALLBACK_ENABLED" == "1" ]] && command -v security &>/dev/null; then
    value=$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null || echo "")
    if [[ -n "$value" ]]; then
      persist_secret_to_env_cache "$value" "$@"
      printf '%s' "$value"
      return 0
    fi
  fi

  return 1
}

# Archive previous report before overwriting
if [[ -f "$REPORT_FILE" ]]; then
  # Use the date from the existing report, or yesterday's date as fallback
  local_prev_date=$(head -1 "$REPORT_FILE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "$YESTERDAY_DATE")
  if [[ -n "$local_prev_date" ]] && [[ ! -f "$ARCHIVE_DIR/${local_prev_date}.md" ]]; then
    cp "$REPORT_FILE" "$ARCHIVE_DIR/${local_prev_date}.md"
  fi
fi

# Lock file to prevent concurrent writes
LOCKFILE="$OUTPUT_DIR/.morning_report.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  if [ -d "$LOCKFILE" ]; then
    lock_age=$(( $(date +%s) - $(stat -f %m "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 1800 ]; then
      echo "Stale lock detected (${lock_age}s old) — reclaiming" >&2
      rm -rf "$LOCKFILE"
      mkdir "$LOCKFILE" 2>/dev/null || { echo "Failed to reclaim lock" >&2; exit 1; }
    else
      echo "Another report instance is running (lock: $LOCKFILE, age: ${lock_age}s)" >&2
      exit 1
    fi
  fi
fi
trap 'rm -rf "$LOCKFILE"' EXIT

# Pre-fetch API keys from env (loaded from ~/.config/nv/env above)
LS_KEY="$(load_secret "lemonsqueezy" "api_key" "LEMONSQUEEZY_API_KEY" || true)"
CF_TOKEN="$(load_secret "cloudflare" "api_token" "CLOUDFLARE_API_TOKEN" || true)"
RESEND_KEY="$(load_secret "resend" "api_key" "RESEND_API_KEY" || true)"
DIST_KEY="$(load_secret "dist-analytics" "api_key" "DIST_ANALYTICS_KEY" || true)"
EMAIL_API_KEY="$(load_secret "sane-email-automation" "api_key" "SANE_EMAIL_API_KEY" "EMAIL_API_KEY" || true)"

# Tools check
NV_CMD="${SANE_LEGACY_NV_CMD:-$HOME/.local/bin/nv}"
ENABLE_LEGACY_NV_SUMMARY="${SANE_ENABLE_LEGACY_NV_SUMMARY:-0}"
GH_CMD=$(command -v gh 2>/dev/null || echo "")
LISTING_ACTIONS_SCRIPT="$SCRIPT_DIR/listing-actions.py"

# Cloudflare account ID (cached to file — survives subshells)
CF_ACCOUNT_FILE="$CACHE_DIR/.cf_account_id"
get_cf_account() {
  if [[ -f "$CF_ACCOUNT_FILE" ]] && [[ -s "$CF_ACCOUNT_FILE" ]]; then
    cat "$CF_ACCOUNT_FILE"
    return
  fi
  if [[ -n "$CF_TOKEN" ]]; then
    local acct
    acct=$(safe_curl -s "https://api.cloudflare.com/client/v4/accounts" \
      -H "Authorization: Bearer $CF_TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null || echo "")
    if [[ -n "$acct" ]]; then
      echo "$acct" > "$CF_ACCOUNT_FILE"
      echo "$acct"
    fi
  fi
}

# Helper: Safe section execution
safe_section() {
  local section_name="$1"
  shift
  echo "→ Running: $section_name" >&2
  if "$@"; then
    echo "✓ $section_name complete" >&2
  else
    echo "⚠ $section_name failed (continuing)" >&2
  fi
}

# Helper: curl with timeout (prevents hangs from blocking the whole report)
safe_curl() {
  curl --connect-timeout 10 --max-time 30 "$@"
}

product_config_rows() {
  local mode="$1"
  ruby -ryaml - "$PRODUCTS_YML" "$mode" <<'RUBY'
config = YAML.safe_load(File.read(ARGV[0]), permitted_classes: []) || {}
products = config['products'].is_a?(Hash) ? config['products'] : {}
mode = ARGV[1].to_s

case mode
when 'domains'
  products.values.map { |product| product['domain'].to_s.strip }.reject(&:empty?).uniq.each { |domain| puts domain }
when 'repos'
  products.values.map { |product| product['github_repo'].to_s.split('/').last }.reject(&:empty?).uniq.each { |repo| puts repo }
when 'released'
  products.each do |slug, product|
    next unless product.is_a?(Hash)
    next if product['checkout_uuid'].to_s.strip.empty?

    name = product['name'].to_s.strip
    domain = product['domain'].to_s.strip
    next if name.empty? || domain.empty?

    puts [name, "https://#{domain}/appcast.xml", "https://#{domain}", slug.to_s].join('|')
  end
end
RUBY
}

PRODUCT_SITES="$(
  {
    echo "saneapps.com"
    product_config_rows domains
  } | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
)"
REPOS="$(product_config_rows repos | awk 'NF' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

# Initialize report
cat > "$REPORT_FILE" <<EOF
# Daily Report — $DATE_DISPLAY

Generated at $(date +"%H:%M:%S")

---

EOF

# =============================================================================
# Section 1: Revenue (LemonSqueezy + GitHub Sponsors)
# =============================================================================
section_revenue() {
  echo "## Revenue" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local revenue_data=""

  if [[ -n "$LS_KEY" ]]; then
    local ls_daily
    ls_daily=$(python3 "$SCRIPT_DIR/ls-sales.py" --daily 2>/dev/null || echo "No data")
    echo '```' >> "$REPORT_FILE"
    echo "$ls_daily" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    revenue_data="$ls_daily"
  else
    echo "**LemonSqueezy:** API key not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  # GitHub Sponsors
  if [[ -n "$GH_CMD" ]]; then
    local sponsors
    sponsors=$("$GH_CMD" api graphql -f query='{ viewer { sponsorshipsAsMaintainer(first: 100, activeOnly: true) { totalCount totalRecurringMonthlyPriceInCents nodes { sponsorEntity { ... on User { login } ... on Organization { login } } tier { monthlyPriceInDollars } createdAt } } } }' 2>/dev/null || echo "")

    if [[ -n "$sponsors" ]]; then
      local sponsor_count monthly_cents
      sponsor_count=$(echo "$sponsors" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['viewer']['sponsorshipsAsMaintainer']['totalCount'])" 2>/dev/null || echo "0")
      monthly_cents=$(echo "$sponsors" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['viewer']['sponsorshipsAsMaintainer']['totalRecurringMonthlyPriceInCents'])" 2>/dev/null || echo "0")
      local monthly_dollars
      monthly_dollars=$(python3 -c "print(f'{int(${monthly_cents})/100:.2f}')" 2>/dev/null || echo "0")

      echo "**GitHub Sponsors:** $sponsor_count sponsor(s), \$$monthly_dollars/mo" >> "$REPORT_FILE"

      echo "$sponsors" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for n in d['data']['viewer']['sponsorshipsAsMaintainer']['nodes']:
    login = n['sponsorEntity']['login']
    amount = n['tier']['monthlyPriceInDollars']
    since = n['createdAt'][:10]
    print(f'  - @{login}: \${amount}/mo (since {since})')
" >> "$REPORT_FILE" 2>/dev/null
      echo "" >> "$REPORT_FILE"
    fi
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 2: Download Analytics (sane-dist D1)
# =============================================================================
section_downloads() {
  echo "## Downloads" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$DIST_KEY" ]]; then
    echo "**Status:** dist-analytics API key not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  # Fetch today's stats
  local dl_today
  dl_today=$(python3 "$SCRIPT_DIR/dl-report.py" --daily --days 7 2>/dev/null || echo "No data")
  echo '```' >> "$REPORT_FILE"
  echo "$dl_today" >> "$REPORT_FILE"
  echo '```' >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  # By-app breakdown
  local dl_apps
  dl_apps=$(python3 "$SCRIPT_DIR/dl-report.py" --days 7 2>/dev/null || echo "")
  if [[ -n "$dl_apps" ]]; then
    echo "<details><summary>By App & Version (7d)</summary>" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "$dl_apps" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "</details>" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 3: Website Traffic (Cloudflare Analytics)
# =============================================================================
section_website_traffic() {
  echo "## Website Traffic (7-day)" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$CF_TOKEN" ]]; then
    echo "**Status:** Cloudflare API key not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  local acct
  acct=$(get_cf_account)
  if [[ -z "$acct" ]]; then
    echo "**Status:** Could not get Cloudflare account" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 1
  fi

  # Fetch all zone IDs
  local zones_json
  zones_json=$(safe_curl -s "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    -H "Authorization: Bearer $CF_TOKEN" 2>/dev/null)

  local traffic_raw=""
  echo "| Site | Views (7d) | Uniques (7d) | Top Day |" >> "$REPORT_FILE"
  echo "|------|-----------|-------------|---------|" >> "$REPORT_FILE"

  for site in $PRODUCT_SITES; do
    local zone_id
    zone_id=$(echo "$zones_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for z in d.get('result', []):
    if z['name'] == '$site':
        print(z['id'])
        break
" 2>/dev/null)

    if [[ -z "$zone_id" ]]; then continue; fi

    local analytics
    analytics=$(safe_curl -s "https://api.cloudflare.com/client/v4/graphql" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"query\": \"query { viewer { zones(filter: {zoneTag: \\\"$zone_id\\\"}) { httpRequests1dGroups(limit: 7, filter: {date_geq: \\\"$WEEK_AGO\\\", date_leq: \\\"$DATE\\\"}) { dimensions { date } sum { pageViews } uniq { uniques } } } } }\"
      }" 2>/dev/null)

    local site_summary
    site_summary=$(echo "$analytics" | python3 -c "
import json, sys
d = json.load(sys.stdin)
zones = d.get('data',{}).get('viewer',{}).get('zones',[])
if not zones: sys.exit(0)
days = zones[0].get('httpRequests1dGroups',[])
if not days: sys.exit(0)
total_pv = sum(x['sum']['pageViews'] for x in days)
total_uq = sum(x['uniq']['uniques'] for x in days)
top = max(days, key=lambda x: x['uniq']['uniques'])
top_day = top['dimensions']['date']
top_uq = top['uniq']['uniques']
print(f'{total_pv}|{total_uq}|{top_day} ({top_uq})')
" 2>/dev/null)

    if [[ -n "$site_summary" ]]; then
      IFS='|' read -r pv uq top_info <<< "$site_summary"
      echo "| $site | $pv | $uq | $top_info |" >> "$REPORT_FILE"
      traffic_raw="${traffic_raw}${site}: ${pv} views, ${uq} uniques, top=${top_info}\n"
    fi
  done

  echo "" >> "$REPORT_FILE"

  # Cache for day-over-day comparison
  local prev_traffic="$CACHE_DIR/traffic_prev.txt"
  echo -e "$traffic_raw" > "$prev_traffic"

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 4: GitHub Traction
# =============================================================================
section_github_traction() {
  echo "## GitHub" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$GH_CMD" ]]; then
    echo "**Status:** GitHub CLI not installed" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 1
  fi

  # Stars + forks + clones table
  echo "| Repo | Stars | Forks | Clones (14d) | Views (14d) |" >> "$REPORT_FILE"
  echo "|------|-------|-------|-------------|------------|" >> "$REPORT_FILE"

  for repo in $REPOS; do
    local stars forks clones views
    stars=$("$GH_CMD" api "repos/$GH_ORG/$repo" --jq '.stargazers_count' 2>/dev/null || echo "?")
    forks=$("$GH_CMD" api "repos/$GH_ORG/$repo" --jq '.forks_count' 2>/dev/null || echo "?")
    clones=$("$GH_CMD" api "repos/$GH_ORG/$repo/traffic/clones" --jq '.uniques' 2>/dev/null || echo "?")
    views=$("$GH_CMD" api "repos/$GH_ORG/$repo/traffic/views" --jq '.uniques' 2>/dev/null || echo "?")

    echo "| $repo | $stars | $forks | $clones | $views |" >> "$REPORT_FILE"
  done

  echo "" >> "$REPORT_FILE"

  # Top referrers (SaneBar only)
  local referrers
  referrers=$("$GH_CMD" api "repos/$GH_ORG/SaneBar/traffic/popular/referrers" 2>/dev/null || echo "[]")
  local ref_text
  ref_text=$(echo "$referrers" | python3 -c "
import json, sys
refs = json.load(sys.stdin)
if refs:
    lines = []
    for r in refs[:6]:
        lines.append(f\"  {r['referrer']:<30} {r['count']:>5} views, {r['uniques']:>4} unique\")
    print('\n'.join(lines))
" 2>/dev/null)

  if [[ -n "$ref_text" ]]; then
    echo "**SaneBar Referrers (14d):**" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "$ref_text" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  # Open issues: use the same org-wide queue as status so infra repos do not vanish.
  local issue_text=""
  if [[ -x "$GITHUB_QUEUE" ]]; then
    issue_text=$("$GITHUB_QUEUE" issues --scope org-wide --format markdown --limit "${STATUS_GITHUB_LIMIT:-200}" 2>/dev/null || echo "")
  fi

  if [[ -n "$issue_text" ]]; then
    echo "**Open Issues:**" >> "$REPORT_FILE"
    echo "$issue_text" >> "$REPORT_FILE"
  else
    echo "**Open Issues:** None" >> "$REPORT_FILE"
  fi
  echo "" >> "$REPORT_FILE"

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 5: Customer Intelligence (D1 — new items only)
# =============================================================================
section_customer_intel() {
  echo "## Customer Intel" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$CF_TOKEN" ]]; then
    echo "**Status:** Cloudflare API key not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  local acct
  acct=$(get_cf_account)
  local db_id
  db_id=$(safe_curl -s "https://api.cloudflare.com/client/v4/accounts/$acct/d1/database" \
    -H "Authorization: Bearer $CF_TOKEN" | python3 -c "
import json, sys
dbs = json.load(sys.stdin).get('result', [])
for db in dbs:
    if db['name'] == 'sane-email-db':
        print(db['uuid'])
        break
" 2>/dev/null)

  if [[ -z "$db_id" ]]; then
    echo "**Status:** D1 database not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  # Helper: query D1
  d1_query() {
    safe_curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$acct/d1/database/$db_id/query" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"sql\": \"$1\"}" 2>/dev/null
  }

  # Pending/new emails — only show needs_human items
  local pending_count
  pending_count=$(d1_query "SELECT COUNT(*) as c FROM emails WHERE status IN ('pending','new','needs_human')" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('result',[{}])[0].get('results',[{}])[0].get('c', 0))
" 2>/dev/null || echo "0")

  if [[ "$pending_count" -gt 0 ]]; then
    local pending
    pending=$(d1_query "SELECT from_email, subject, priority, created_at FROM emails WHERE status IN ('pending','new','needs_human') ORDER BY CASE priority WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END, created_at DESC LIMIT 5" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('result',[{}])[0].get('results',[])
for r in rows:
    pri = r.get('priority','?')
    subj = r.get('subject','?')
    subj = (subj[:57] + '...') if len(subj) > 60 else subj
    print(f\"  - [{pri}] {subj}\")
" 2>/dev/null)
    echo "**Pending Emails ($pending_count):**" >> "$REPORT_FILE"
    echo "$pending" >> "$REPORT_FILE"
    if [[ "$pending_count" -gt 5 ]]; then
      echo "  - _...and $((pending_count - 5)) more_" >> "$REPORT_FILE"
    fi
  else
    echo "**Pending Emails:** None" >> "$REPORT_FILE"
  fi
  echo "" >> "$REPORT_FILE"

  # Open high-severity bugs only
  local bugs
  bugs=$(d1_query "SELECT product, title FROM bug_reports WHERE status != 'resolved' AND severity = 'high' ORDER BY created_at DESC LIMIT 5" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('result',[{}])[0].get('results',[])
if rows:
    for r in rows:
        t = r.get('title','?')
        t = (t[:57] + '...') if len(t) > 60 else t
        print(f\"  - {r.get('product','?')}: {t}\")
else:
    print('  None')
" 2>/dev/null)
  echo "**High-Priority Bugs:**" >> "$REPORT_FILE"
  echo "$bugs" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 6: Listing / Directory Actions
# =============================================================================
section_listing_actions() {
  echo "## Listing Actions" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$EMAIL_API_KEY" ]]; then
    echo "**Status:** Email API key not found" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  if [[ ! -f "$LISTING_ACTIONS_SCRIPT" ]]; then
    echo "**Status:** listing-actions.py not found at $LISTING_ACTIONS_SCRIPT" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  local listing_json="$CACHE_DIR/listing_actions.json"
  local listing_xlsx="$OUTPUT_DIR/listing_actions/latest.xlsx"

  if ! SANE_EMAIL_API_KEY="$EMAIL_API_KEY" SANE_KEYCHAIN_FALLBACK=0 \
    python3 "$LISTING_ACTIONS_SCRIPT" --json-out "$listing_json" >/dev/null 2>&1; then
    echo "**Status:** Listing action export failed" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  python3 - "$listing_json" "$listing_xlsx" >> "$REPORT_FILE" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workbook_path = sys.argv[2]
current = payload.get("current_actions", [])
needs = [row for row in current if row.get("action_status") == "Needs action"]
optional = [row for row in current if row.get("action_status") == "Optional"]
monitor = [row for row in current if row.get("action_status") == "Monitor"]

print(f"**Workbook:** `{workbook_path}`")
print(f"**Current actions:** {len(current)}")
print(f"- Needs action: {len(needs)}")
print(f"- Optional: {len(optional)}")
print(f"- Monitor: {len(monitor)}")
print("")

if needs:
    print("| Site | Workflow | Email | Next step |")
    print("|------|----------|-------|-----------|")
    for row in needs[:10]:
        action = (row.get("action") or "").replace("|", "/").strip()
        if len(action) > 90:
            action = action[:87] + "..."
        print(
            f"| {row.get('site', '')} | {row.get('workflow', '')} | "
            f"#{row.get('latest_email_id', '')} | {action} |"
        )
else:
    print("No live listing/setup actions right now.")
PY

  echo "" >> "$REPORT_FILE"
  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 7: API & Infrastructure Health
# =============================================================================
section_health() {
  echo "## Health" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local all_ok=true

  # API checks
  if [[ -n "$RESEND_KEY" ]]; then
    local resend_check
    resend_check=$(safe_curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $RESEND_KEY" "https://api.resend.com/emails" 2>/dev/null || echo "error")
    if [[ "$resend_check" != "200" ]]; then
      echo "- Resend Email API: DOWN ($resend_check)" >> "$REPORT_FILE"
      all_ok=false
    fi
  fi

  if [[ -n "$LS_KEY" ]]; then
    local ls_check
    ls_check=$(safe_curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $LS_KEY" "https://api.lemonsqueezy.com/v1/products" 2>/dev/null || echo "error")
    if [[ "$ls_check" != "200" ]]; then
      echo "- LemonSqueezy API: DOWN ($ls_check)" >> "$REPORT_FILE"
      all_ok=false
    fi
  fi

  if [[ -n "$GH_CMD" ]]; then
    local github_ok=false
    local attempt=1
    local gh_status=""

    while [[ "$attempt" -le 2 ]]; do
      if "$GH_CMD" api rate_limit --jq '.rate.remaining' &>/dev/null; then
        github_ok=true
        break
      fi
      attempt=$((attempt + 1))
      sleep 1
    done

    if [[ "$github_ok" == false ]]; then
      gh_status=$(safe_curl -s -o /dev/null -w "%{http_code}" "https://api.github.com" 2>/dev/null || echo "error")
      if [[ "$gh_status" == "200" ]]; then
        echo "- GitHub CLI auth check failed, but api.github.com is responding" >> "$REPORT_FILE"
      else
        echo "- GitHub API: DOWN ($gh_status)" >> "$REPORT_FILE"
        all_ok=false
      fi
    fi
  fi

  # Checkout links
  local config_file="$HOME/SaneApps/infra/SaneProcess/config/products.yml"
  if [ -f "$config_file" ]; then
    local checkout_base
    checkout_base=$(grep 'checkout_base:' "$config_file" | awk '{print $2}')
    local current_name=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]+name:[[:space:]]+(.*) ]]; then
        current_name="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^[[:space:]]+checkout_uuid:[[:space:]]+(.*) ]]; then
        local url="${checkout_base}/${BASH_REMATCH[1]}"
        local status
        status=$(safe_curl -sI -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
        if [[ "$status" != "200" ]] && [[ "$status" != "301" ]] && [[ "$status" != "302" ]]; then
          echo "- $current_name checkout: BROKEN ($status)" >> "$REPORT_FILE"
          all_ok=false
        fi
      fi
    done < "$config_file"
  fi

  # Appcast feeds
  local appcast_urls=(
    "https://sanebar.com/appcast.xml|SaneBar"
    "https://saneclick.com/appcast.xml|SaneClick"
    "https://saneclip.com/appcast.xml|SaneClip"
    "https://sanehosts.com/appcast.xml|SaneHosts"
  )

  for entry in "${appcast_urls[@]}"; do
    IFS='|' read -r url name <<< "$entry"
    local status
    status=$(safe_curl -sI -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    if [[ "$status" != "200" ]] && [[ "$status" != "301" ]] && [[ "$status" != "302" ]]; then
      echo "- $name appcast: BROKEN ($status)" >> "$REPORT_FILE"
      all_ok=false
    fi
  done

  # Dist workers
  local dist_urls=(
    "https://dist.sanebar.com/health|SaneBar"
    "https://dist.saneclick.com/health|SaneClick"
    "https://dist.saneclip.com/health|SaneClip"
    "https://dist.sanehosts.com/health|SaneHosts"
    "https://dist.sanesales.com/health|SaneSales"
  )

  for entry in "${dist_urls[@]}"; do
    IFS='|' read -r url name <<< "$entry"
    local status
    status=$(safe_curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    if [[ "$status" != "200" ]]; then
      echo "- $name dist worker: DOWN ($status)" >> "$REPORT_FILE"
      all_ok=false
    fi
  done

  if [[ "$all_ok" == "true" ]]; then
    echo "All systems operational (APIs, checkouts, appcasts, dist workers)" >> "$REPORT_FILE"
  else
    # macOS notification for critical issue
    osascript -e "display notification \"Infrastructure issues detected — check daily report\" with title \"SaneApps ALERT\" sound name \"Sosumi\"" 2>/dev/null
  fi

  echo "" >> "$REPORT_FILE"
  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

fetch_live_email_worker_snapshot() {
  [[ -n "$EMAIL_API_KEY" ]] || return 0

  safe_curl -fsSL "https://email-api.saneapps.com/api/debug/download-config" \
    -H "Authorization: Bearer $EMAIL_API_KEY" 2>/dev/null || true
}

extract_live_email_worker_version() {
  local snapshot_json="$1"
  local app_name="$2"

  [[ -n "$snapshot_json" ]] || return 0
  [[ -n "$app_name" ]] || return 0

  SNAPSHOT_JSON="$snapshot_json" python3 - "$app_name" <<'PY'
import json
import os
import sys

app_name = sys.argv[1]
try:
    payload = json.loads(os.environ.get("SNAPSHOT_JSON", ""))
except Exception:
    raise SystemExit(0)

product = (payload.get("products") or {}).get(app_name) or {}
version = product.get("version", "")
if version is None:
    version = ""
sys.stdout.write(str(version))
PY
}

fetch_homebrew_cask_body() {
  local cask_name="$1"
  local github_api_path="repos/sane-apps/homebrew-tap/contents/Casks/${cask_name}.rb?ref=main"

  if [[ -n "$GH_CMD" ]]; then
    local gh_content
    gh_content=$("$GH_CMD" api "$github_api_path" --jq .content 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || echo "")
    if [[ -n "$gh_content" ]]; then
      printf '%s' "$gh_content"
      return 0
    fi
  fi

  safe_curl -fsSL "https://raw.githubusercontent.com/sane-apps/homebrew-tap/main/Casks/${cask_name}.rb" 2>/dev/null || true
}

# =============================================================================
# Section 8: Version Drift (cross-channel consistency)
# =============================================================================
section_version_drift() {
  echo "## Version Consistency" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local webhook_snapshot
  webhook_snapshot=$(fetch_live_email_worker_snapshot)

  local app_configs
  app_configs=$(product_config_rows released)

  echo "| App | Appcast | Website | Webhook | Homebrew | Status |" >> "$REPORT_FILE"
  echo "|-----|---------|---------|---------|----------|--------|" >> "$REPORT_FILE"

  local has_drift=false

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r app_name appcast_url site_url cask_name <<< "$entry"

    # 1. Appcast version (live fetch — source of truth)
    local appcast_ver="—"
    local appcast_xml
    appcast_xml=$(safe_curl -fsSL "$appcast_url" 2>/dev/null || echo "")
    if [[ -n "$appcast_xml" ]]; then
      appcast_ver=$(echo "$appcast_xml" | grep -oE 'shortVersionString[^0-9]*[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "—")
    fi

    # 2. Website download link version (live fetch)
    local site_ver="—"
    local site_html
    site_html=$(safe_curl -fsSL "$site_url" 2>/dev/null || echo "")
    if [[ -n "$site_html" ]]; then
      site_ver=$(echo "$site_html" | grep -oE "${app_name}-[0-9]+\.[0-9]+\.[0-9]+\.(zip|dmg)" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "—")
    fi

    # 3. Webhook PRODUCT_CONFIG version (live worker)
    local webhook_ver="—"
    if [[ -n "$webhook_snapshot" ]]; then
      webhook_ver=$(extract_live_email_worker_version "$webhook_snapshot" "$app_name" || echo "—")
      webhook_ver="${webhook_ver:-—}"
    fi

    # 4. Homebrew cask version (GitHub content API, raw fallback only if needed)
    local cask_ver="—"
    if [[ -n "$cask_name" ]]; then
      local cask_body
      cask_body=$(fetch_homebrew_cask_body "$cask_name")
      if [[ -n "$cask_body" ]]; then
        cask_ver=$(echo "$cask_body" | grep -oE 'version "[0-9]+\.[0-9]+(\.[0-9]+)?"' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "—")
      fi
    fi

    # Compare: all present versions should match appcast
    local status="✅"
    if [[ "$appcast_ver" != "—" ]]; then
      for v in "$site_ver" "$webhook_ver" "$cask_ver"; do
        if [[ "$v" != "—" ]] && [[ "$v" != "$appcast_ver" ]]; then
          status="❌ DRIFT"
          has_drift=true
          break
        fi
      done
    else
      status="⚠️ No appcast"
    fi

    echo "| $app_name | $appcast_ver | $site_ver | $webhook_ver | $cask_ver | $status |" >> "$REPORT_FILE"
  done <<EOF
$app_configs
EOF

  echo "" >> "$REPORT_FILE"

  if [[ "$has_drift" == "true" ]]; then
    echo "**⚠️ Version drift detected!** New customers may be downloading old builds." >> "$REPORT_FILE"
    echo "Run \`ruby scripts/validation_report.rb\` for details." >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    # macOS notification for drift
    osascript -e "display notification \"Version drift detected across channels — check daily report\" with title \"SaneApps VERSION DRIFT\" sound name \"Sosumi\"" 2>/dev/null
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 9: Git Status
# =============================================================================
section_git_status() {
  echo "## Git Status" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo "| App | Last Commit | Days Ago | Status |" >> "$REPORT_FILE"
  echo "|-----|-------------|----------|--------|" >> "$REPORT_FILE"

  local now_epoch
  now_epoch=$(date +%s)

  for app in $REPOS; do
    local app_dir="$APPS_DIR/$app"

    if [[ ! -d "$app_dir/.git" ]]; then
      echo "| $app | N/A | — | Not a git repo |" >> "$REPORT_FILE"
      continue
    fi

    cd "$app_dir" || continue

    local last_commit_date last_commit_epoch days_ago
    last_commit_date=$(git log -1 --format="%cd" --date=short 2>/dev/null || echo "unknown")
    last_commit_epoch=$(git log -1 --format="%ct" 2>/dev/null || echo "0")
    days_ago=$(( (now_epoch - last_commit_epoch) / 86400 ))

    local status="Clean"
    if ! git diff-index --quiet HEAD 2>/dev/null; then
      status="**Uncommitted changes**"
    fi

    if [[ $days_ago -gt 7 ]]; then
      status="$status ⚠️ Stale"
    fi

    echo "| $app | $last_commit_date | $days_ago | $status |" >> "$REPORT_FILE"
  done

  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Executive Summary (optional legacy nv path; disabled by default)
# =============================================================================
section_executive_summary() {
  if [[ "$ENABLE_LEGACY_NV_SUMMARY" != "1" ]]; then return 0; fi
  if [[ ! -x "$NV_CMD" ]]; then return 0; fi

  local report_so_far
  report_so_far=$(cat "$REPORT_FILE")

  local summary
  summary=$(timeout 60 "$NV_CMD" -m kimi-fast --no-stream \
    "You are the CTO reviewing an evening report for a solo indie Mac app developer (SaneApps: SaneBar, SaneClick, SaneClip, SaneHosts, SaneSync, SaneVideo). Write a 5-line EXECUTIVE SUMMARY. Format:

🟢/🟡/🔴 [Overall status one-liner]
- Revenue: [one-liner with numbers]
- Downloads: [one-liner with numbers]
- GitHub: [one-liner with numbers]
- Action needed: [the ONE most important thing to do today]

Be specific with numbers. No fluff." <<< "$report_so_far" 2>/dev/null || echo "")

  if [[ -n "$summary" ]]; then
    local header footer
    header=$(head -6 "$REPORT_FILE")
    footer=$(tail -n +7 "$REPORT_FILE")

    cat > "$REPORT_FILE" <<EOF
$header
$summary

---

$(echo "$footer" | sed '1{/^---$/d;}' | sed '1{/^$/d;}')
EOF
  fi
}

# =============================================================================
# Run all sections with error isolation
# =============================================================================
safe_section "Revenue" section_revenue
safe_section "Downloads" section_downloads
safe_section "Website Traffic" section_website_traffic
safe_section "GitHub" section_github_traction
safe_section "Customer Intel" section_customer_intel
safe_section "Listing Actions" section_listing_actions
safe_section "Health" section_health
safe_section "Version Drift" section_version_drift
safe_section "Git Status" section_git_status

# Executive summary LAST (reads entire report, writes TL;DR at top)
safe_section "Executive Summary" section_executive_summary

# Footer
cat >> "$REPORT_FILE" <<EOF

---

**Report generated:** $(date +"%Y-%m-%d %H:%M:%S")
**Location:** $REPORT_FILE
**Archive:** $ARCHIVE_DIR/

_Review this report before taking action. Drafts are NOT sent automatically._
EOF

echo "✅ Daily report complete: $REPORT_FILE" >&2
