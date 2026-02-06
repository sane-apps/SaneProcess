#!/bin/bash
# frozen_string_literal: false
# Morning Report Generator - Overnight automation for SaneApps
# Runs at 5 AM daily via LaunchAgent
#
# Architecture: fetch raw data -> nv analyzes for free -> markdown report
# nv handles: trend analysis, anomaly detection, summaries, recommendations

set -uo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="/Users/sj/SaneApps/infra/SaneProcess/outputs"
REPORT_FILE="$OUTPUT_DIR/morning_report.md"
CACHE_DIR="$OUTPUT_DIR/.cache"
RAW_DIR="$OUTPUT_DIR/.raw"
APPS_DIR="/Users/sj/SaneApps/apps"
DATE_DISPLAY=$(date +"%Y-%m-%d %A")
DATE=$(date +"%Y-%m-%d")
YESTERDAY=$(date -v-1d +"%Y-%m-%dT%H:%M:%SZ")
YESTERDAY_DATE=$(date -v-1d +"%Y-%m-%d")
WEEK_AGO=$(date -v-7d +"%Y-%m-%d")
GH_ORG="sane-apps"
PRODUCT_SITES="sanebar.com saneclick.com saneclip.com sanehosts.com sanesync.com sanevideo.com saneapps.com"
REPOS="SaneBar SaneClick SaneClip SaneHosts SaneSync SaneVideo"

mkdir -p "$CACHE_DIR" "$RAW_DIR"

# Lock file to prevent concurrent writes (race condition if cron + manual overlap)
LOCKFILE="$OUTPUT_DIR/.morning_report.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  echo "Another morning-report instance is running (lock: $LOCKFILE)" >&2
  exit 1
fi
trap 'rm -rf "$LOCKFILE"' EXIT

# Pre-fetch API keys ONCE (sequential to avoid keychain popup flood)
RESEND_KEY=""
CF_TOKEN=""
LS_KEY=""
if command -v security &>/dev/null; then
  RESEND_KEY=$(security find-generic-password -s resend -a api_key -w 2>/dev/null || echo "")
  CF_TOKEN=$(security find-generic-password -s cloudflare -a api_token -w 2>/dev/null || echo "")
  LS_KEY=$(security find-generic-password -s lemonsqueezy -a api_key -w 2>/dev/null || echo "")
fi

# Tools check
NV_CMD="/Users/sj/.local/bin/nv"
GH_CMD=$(command -v gh 2>/dev/null || echo "")

# Cloudflare account ID (cached after first fetch)
CF_ACCOUNT=""
get_cf_account() {
  if [[ -z "$CF_ACCOUNT" ]] && [[ -n "$CF_TOKEN" ]]; then
    CF_ACCOUNT=$(curl -s "https://api.cloudflare.com/client/v4/accounts" \
      -H "Authorization: Bearer $CF_TOKEN" | python3 -c "import json,sys; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null || echo "")
  fi
  echo "$CF_ACCOUNT"
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

# Helper: nv analyze (pipe data, get insights)
nv_analyze() {
  local prompt="$1"
  local data="$2"
  if [[ -x "$NV_CMD" ]] && [[ -n "$data" ]]; then
    echo "$data" | "$NV_CMD" -m kimi-fast --no-stream "$prompt" 2>/dev/null || echo "_Analysis unavailable_"
  else
    echo "_nv unavailable for analysis_"
  fi
}

# Initialize report
cat > "$REPORT_FILE" <<EOF
# Morning Report — $DATE_DISPLAY

Generated at $(date +"%H:%M:%S")

---

EOF

# =============================================================================
# Section 1: Revenue Dashboard (LemonSqueezy + GitHub Sponsors)
# =============================================================================
section_revenue() {
  echo "## 💰 Revenue" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local revenue_data=""

  # LemonSqueezy sales
  if [[ -n "$LS_KEY" ]]; then
    local ls_output
    ls_output=$(python3 "$SCRIPT_DIR/ls-sales.py" --json 2>/dev/null || echo "[]")
    local ls_summary
    ls_summary=$(python3 "$SCRIPT_DIR/ls-sales.py" --month 2>/dev/null || echo "No data")
    echo '```' >> "$REPORT_FILE"
    echo "$ls_summary" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    revenue_data="LEMONSQUEEZY:\n$ls_summary\n\n"
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

      # List individual sponsors
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
      revenue_data="${revenue_data}SPONSORS: $sponsor_count sponsors, \$$monthly_dollars/mo\n"
    fi
  fi

  # nv: analyze revenue trends (compare to yesterday's cache)
  local prev_cache="$CACHE_DIR/revenue_prev.txt"
  if [[ -x "$NV_CMD" ]] && [[ -n "$revenue_data" ]]; then
    local prev_data=""
    [[ -f "$prev_cache" ]] && prev_data=$(cat "$prev_cache")

    local analysis
    analysis=$(nv_analyze \
      "You are a revenue analyst for a solo indie Mac app developer. Given today's sales data (and optionally yesterday's cached data), write 2-3 bullet points: key takeaway, any anomaly, one actionable suggestion. Be concise, no fluff. If previous data provided, note trends." \
      "TODAY:\n${revenue_data}\nPREVIOUS:\n${prev_data:-No previous data}")

    echo "**Analysis:**" >> "$REPORT_FILE"
    echo "$analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  # Cache today's data for tomorrow's comparison
  echo -e "$revenue_data" > "$prev_cache"

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 2: Website Traffic (Cloudflare Analytics for all product sites)
# =============================================================================
section_website_traffic() {
  echo "## 🌐 Website Traffic (7-day)" >> "$REPORT_FILE"
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
  zones_json=$(curl -s "https://api.cloudflare.com/client/v4/zones?per_page=50" \
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
    analytics=$(curl -s "https://api.cloudflare.com/client/v4/graphql" \
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

  # Workers analytics (download counts)
  local workers_analytics
  workers_analytics=$(curl -s "https://api.cloudflare.com/client/v4/graphql" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"query\": \"query { viewer { accounts(filter: {accountTag: \\\"$acct\\\"}) { workersInvocationsAdaptive(limit: 10, filter: {date_geq: \\\"$WEEK_AGO\\\", date_leq: \\\"$DATE\\\", scriptName: \\\"sane-dist\\\"}) { dimensions { date } sum { requests errors } } } } }\"
    }" 2>/dev/null)

  local download_summary
  download_summary=$(echo "$workers_analytics" | python3 -c "
import json, sys
d = json.load(sys.stdin)
accounts = d.get('data',{}).get('viewer',{}).get('accounts',[])
if not accounts: sys.exit(0)
days = accounts[0].get('workersInvocationsAdaptive',[])
if not days: sys.exit(0)
total = sum(x['sum']['requests'] for x in days)
errors = sum(x['sum']['errors'] for x in days)
print(f'{total}|{errors}')
" 2>/dev/null)

  if [[ -n "$download_summary" ]]; then
    IFS='|' read -r dl_total dl_errors <<< "$download_summary"
    echo "**Downloads (sane-dist worker):** $dl_total requests (7d), $dl_errors errors" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    traffic_raw="${traffic_raw}Downloads: ${dl_total} requests, ${dl_errors} errors\n"
  fi

  # nv: analyze traffic patterns
  if [[ -x "$NV_CMD" ]] && [[ -n "$traffic_raw" ]]; then
    local prev_traffic="$CACHE_DIR/traffic_prev.txt"
    local prev_data=""
    [[ -f "$prev_traffic" ]] && prev_data=$(cat "$prev_traffic")

    local analysis
    analysis=$(nv_analyze \
      "You are a web analytics expert for a solo Mac app developer with 7 products. Given this week's traffic data (and optionally previous week), write 3 bullets: which site is performing best relative to its niche, any traffic anomalies or drops, and download-to-visitor conversion insight. Be terse." \
      "THIS WEEK:\n${traffic_raw}\nPREVIOUS WEEK:\n${prev_data:-No previous data}")

    echo "**Analysis:**" >> "$REPORT_FILE"
    echo "$analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Cache for next run
    echo -e "$traffic_raw" > "$prev_traffic"
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 3: GitHub Traction (Stars, Clones, Referrers, Issues)
# =============================================================================
section_github_traction() {
  echo "## ⭐ GitHub Traction" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ -z "$GH_CMD" ]]; then
    echo "**Status:** GitHub CLI not installed" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 1
  fi

  local github_raw=""

  # Stars + forks table
  echo "| Repo | Stars | Forks | Clones (14d) | Views (14d) |" >> "$REPORT_FILE"
  echo "|------|-------|-------|-------------|------------|" >> "$REPORT_FILE"

  for repo in $REPOS; do
    local stars forks clones views
    stars=$("$GH_CMD" api "repos/$GH_ORG/$repo" --jq '.stargazers_count' 2>/dev/null || echo "?")
    forks=$("$GH_CMD" api "repos/$GH_ORG/$repo" --jq '.forks_count' 2>/dev/null || echo "?")
    clones=$("$GH_CMD" api "repos/$GH_ORG/$repo/traffic/clones" --jq '.uniques' 2>/dev/null || echo "?")
    views=$("$GH_CMD" api "repos/$GH_ORG/$repo/traffic/views" --jq '.uniques' 2>/dev/null || echo "?")

    echo "| $repo | $stars | $forks | $clones | $views |" >> "$REPORT_FILE"
    github_raw="${github_raw}${repo}: ${stars} stars, ${forks} forks, ${clones} clones, ${views} views\n"
  done

  echo "" >> "$REPORT_FILE"

  # Top referrers (SaneBar only - the main product)
  local referrers
  referrers=$("$GH_CMD" api "repos/$GH_ORG/SaneBar/traffic/popular/referrers" 2>/dev/null || echo "[]")
  local ref_text
  ref_text=$(echo "$referrers" | python3 -c "
import json, sys
refs = json.load(sys.stdin)
if refs:
    lines = []
    for r in refs[:8]:
        lines.append(f\"  {r['referrer']:<30} {r['count']:>5} views, {r['uniques']:>4} unique\")
    print('\n'.join(lines))
" 2>/dev/null)

  if [[ -n "$ref_text" ]]; then
    echo "**SaneBar Referrers (14d):**" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "$ref_text" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    github_raw="${github_raw}REFERRERS:\n${ref_text}\n"
  fi

  # Open issues across all repos
  echo "**Open Issues:**" >> "$REPORT_FILE"
  local found_issues=false
  for repo in $REPOS; do
    local issues
    issues=$("$GH_CMD" issue list -R "$GH_ORG/$repo" --state open --json title,number --jq '.[] | "  - #\(.number) \(.title)"' 2>/dev/null || echo "")
    if [[ -n "$issues" ]]; then
      echo "- **$repo:**" >> "$REPORT_FILE"
      echo "$issues" >> "$REPORT_FILE"
      found_issues=true
      github_raw="${github_raw}ISSUES $repo:\n${issues}\n"
    fi
  done
  if [[ "$found_issues" == "false" ]]; then
    echo "  None across all repos" >> "$REPORT_FILE"
  fi
  echo "" >> "$REPORT_FILE"

  # nv: analyze GitHub health
  if [[ -x "$NV_CMD" ]] && [[ -n "$github_raw" ]]; then
    local prev_gh="$CACHE_DIR/github_prev.txt"
    local prev_data=""
    [[ -f "$prev_gh" ]] && prev_data=$(cat "$prev_gh")

    local analysis
    analysis=$(nv_analyze \
      "You are a GitHub growth analyst for a solo indie dev with multiple Mac utility apps. Given stars/clones/views/referrers/issues data (and optionally previous snapshot), write 3 bullets: star growth trend, best referral source to double down on, and any issues that need urgent response. If you see a new referrer, flag it." \
      "TODAY:\n${github_raw}\nPREVIOUS:\n${prev_data:-No previous data}")

    echo "**Analysis:**" >> "$REPORT_FILE"
    echo "$analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo -e "$github_raw" > "$prev_gh"
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 4: Customer Intelligence (D1 Database)
# =============================================================================
section_customer_intel() {
  echo "## 👥 Customer Intelligence" >> "$REPORT_FILE"
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
  db_id=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$acct/d1/database" \
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
    curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$acct/d1/database/$db_id/query" \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"sql\": \"$1\"}" 2>/dev/null
  }

  local customer_raw=""

  # Pending/new emails
  local pending
  pending=$(d1_query "SELECT from_email, subject, category, priority, created_at FROM emails WHERE status='pending' OR status='new' ORDER BY created_at DESC LIMIT 10" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('result',[{}])[0].get('results',[])
if rows:
    for r in rows:
        print(f\"  - [{r.get('priority','?')}] {r.get('from_email','?')}: {r.get('subject','?')} ({r.get('category','?')})\")
else:
    print('  None pending')
" 2>/dev/null)
  echo "**Pending Emails:**" >> "$REPORT_FILE"
  echo "$pending" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  customer_raw="${customer_raw}PENDING EMAILS:\n${pending}\n\n"

  # Open bug reports
  local bugs
  bugs=$(d1_query "SELECT product, title, severity, status FROM bug_reports WHERE status != 'resolved' ORDER BY severity DESC" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('result',[{}])[0].get('results',[])
if rows:
    for r in rows:
        print(f\"  - [{r.get('severity','?')}] {r.get('product','?')}: {r.get('title','?')} ({r.get('status','?')})\")
else:
    print('  None open')
" 2>/dev/null)
  echo "**Open Bug Reports:**" >> "$REPORT_FILE"
  echo "$bugs" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  customer_raw="${customer_raw}BUGS:\n${bugs}\n\n"

  # Feature requests
  local features
  features=$(d1_query "SELECT product, title, votes, status FROM feature_requests WHERE status != 'closed' ORDER BY votes DESC" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d.get('result',[{}])[0].get('results',[])
if rows:
    for r in rows:
        print(f\"  - {r.get('product','?')}: {r.get('title','?')} ({r.get('votes',0)} votes, {r.get('status','?')})\")
else:
    print('  None open')
" 2>/dev/null)
  echo "**Feature Requests:**" >> "$REPORT_FILE"
  echo "$features" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  customer_raw="${customer_raw}FEATURES:\n${features}\n\n"

  # Customer stats
  local stats
  stats=$(d1_query "SELECT COUNT(*) as total, SUM(total_spent) as revenue, MAX(last_contact) as last_contact FROM customers" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('result',[{}])[0].get('results',[{}])[0]
print(f\"  Total customers: {r.get('total',0)}, Revenue tracked: {r.get('revenue',0)}, Last contact: {r.get('last_contact','?')}\")
" 2>/dev/null)
  echo "**Customer DB:**" >> "$REPORT_FILE"
  echo "$stats" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  # nv: prioritize customer actions
  if [[ -x "$NV_CMD" ]] && [[ -n "$customer_raw" ]]; then
    local analysis
    analysis=$(nv_analyze \
      "You are a customer success manager for a solo indie Mac app developer. Given pending emails, bug reports, and feature requests, prioritize: what needs a response TODAY, what can wait, and any pattern you notice (e.g. same bug from multiple people = urgent). 3 bullets max." \
      "$customer_raw")

    echo "**Priorities:**" >> "$REPORT_FILE"
    echo "$analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 5: Conversion Funnel
# =============================================================================
section_funnel() {
  echo "## 🔄 Conversion Funnel (7-day estimates)" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  # Collect data we already fetched (from cache files this run wrote)
  # This section runs LAST so it can read other sections' cached data
  local funnel_data=""

  # Read traffic cache
  [[ -f "$CACHE_DIR/traffic_prev.txt" ]] && funnel_data=$(cat "$CACHE_DIR/traffic_prev.txt")
  # Read github cache
  [[ -f "$CACHE_DIR/github_prev.txt" ]] && funnel_data="${funnel_data}\n$(cat "$CACHE_DIR/github_prev.txt")"
  # Read revenue cache
  [[ -f "$CACHE_DIR/revenue_prev.txt" ]] && funnel_data="${funnel_data}\n$(cat "$CACHE_DIR/revenue_prev.txt")"

  if [[ -x "$NV_CMD" ]] && [[ -n "$funnel_data" ]]; then
    local analysis
    analysis=$(nv_analyze \
      "You are a conversion analyst. Given website traffic, GitHub clones/views, download worker requests, and sales data for a Mac app portfolio, calculate and present a conversion funnel:

1. Website visitors -> GitHub visitors -> Cloners -> Purchasers
2. Show conversion rates between each step
3. Identify the biggest drop-off point
4. One specific suggestion to improve the weakest conversion step

Format as a clean funnel with percentages. Be precise with numbers, estimate where needed." \
      "$funnel_data")

    echo "$analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  else
    echo "**Status:** Insufficient data for funnel analysis" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 5a: API Health Check
# =============================================================================
section_api_health() {
  echo "## 🔌 API Health" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local api_status=""

  # Resend API health (email)
  if [[ -n "$RESEND_KEY" ]]; then
    local resend_check
    resend_check=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $RESEND_KEY" "https://api.resend.com/emails" 2>/dev/null || echo "error")
    if [[ "$resend_check" == "200" ]]; then
      echo "**Resend Email API:** ✅ Responding (200)" >> "$REPORT_FILE"
      api_status="${api_status}Resend: OK\n"
    else
      echo "**Resend Email API:** 🔴 DOWN (HTTP $resend_check)" >> "$REPORT_FILE"
      api_status="${api_status}Resend: DOWN ($resend_check)\n"
    fi
  else
    echo "**Resend Email API:** ⚠️ API key not found" >> "$REPORT_FILE"
  fi

  # LemonSqueezy API health (revenue)
  if [[ -n "$LS_KEY" ]]; then
    local ls_check
    ls_check=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $LS_KEY" "https://api.lemonsqueezy.com/v1/products" 2>/dev/null || echo "error")
    if [[ "$ls_check" == "200" ]]; then
      echo "**LemonSqueezy API:** ✅ Responding (200)" >> "$REPORT_FILE"
      api_status="${api_status}LemonSqueezy: OK\n"
    else
      echo "**LemonSqueezy API:** 🔴 DOWN (HTTP $ls_check)" >> "$REPORT_FILE"
      api_status="${api_status}LemonSqueezy: DOWN ($ls_check)\n"
    fi
  else
    echo "**LemonSqueezy API:** ⚠️ API key not found" >> "$REPORT_FILE"
  fi

  # GitHub accessibility (check exit code directly, not output text)
  if [[ -n "$GH_CMD" ]]; then
    if "$GH_CMD" api user --jq '.login' &>/dev/null; then
      echo "**GitHub API:** ✅ Accessible" >> "$REPORT_FILE"
      api_status="${api_status}GitHub: OK\n"
    else
      echo "**GitHub API:** 🔴 Not accessible (auth may be expired)" >> "$REPORT_FILE"
      api_status="${api_status}GitHub: DOWN\n"
    fi
  else
    echo "**GitHub API:** ⚠️ gh CLI not installed" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"

  # Alert on any API failures
  if echo "$api_status" | grep -q "DOWN"; then
    echo "**🚨 ACTION REQUIRED: One or more critical APIs are down!**" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    # macOS notification for critical issue
    osascript -e "display notification \"Critical API(s) down - check morning report\" with title \"SaneApps ALERT\" sound name \"Sosumi\"" 2>/dev/null
  fi

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 5b: Sales Infrastructure Health Check
# =============================================================================
section_sales_infrastructure() {
  echo "## 🔗 Sales Infrastructure" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local infra_raw=""
  local failures=0

  # Run link monitor and capture results
  local link_monitor="$SCRIPT_DIR/../link_monitor.rb"
  if [[ -f "$link_monitor" ]]; then
    local monitor_output
    monitor_output=$(ruby "$link_monitor" 2>&1) || failures=1

    # Read state file for details
    local state_file="$OUTPUT_DIR/link_monitor_state.json"
    if [[ -f "$state_file" ]]; then
      local state_summary
      state_summary=$(python3 -c "
import json
with open('$state_file') as f:
    s = json.load(f)
consec = s.get('consecutive_failures', 0)
last_ok = s.get('last_success', 'never')[:16] if s.get('last_success') else 'never'
last_fail = s.get('last_failure', 'none')[:16] if s.get('last_failure') else 'none'
details = s.get('last_failure_details', [])
print(f'Consecutive failures: {consec}')
print(f'Last success: {last_ok}')
print(f'Last failure: {last_fail}')
if details:
    print(f'Failed: {\", \".join(details)}')
" 2>/dev/null)

      if [[ $failures -eq 0 ]]; then
        echo "**Status: ALL LINKS HEALTHY**" >> "$REPORT_FILE"
        echo '```' >> "$REPORT_FILE"
        echo "$state_summary" >> "$REPORT_FILE"
        echo '```' >> "$REPORT_FILE"
      else
        echo "**🔴 STATUS: BROKEN LINKS DETECTED**" >> "$REPORT_FILE"
        echo '```' >> "$REPORT_FILE"
        echo "$state_summary" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "$monitor_output" >> "$REPORT_FILE"
        echo '```' >> "$REPORT_FILE"
      fi
      infra_raw="$state_summary"
    fi
  else
    echo "**Status:** Link monitor not installed" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"

  # Check LemonSqueezy checkout links (UUIDs from products.yml — single source of truth)
  local config_file="$SANEAPPS_ROOT/infra/config/products.yml"
  local checkout_base
  checkout_base=$(grep 'checkout_base:' "$config_file" | awk '{print $2}')
  local checkout_urls=()
  local current_name=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+name:[[:space:]]+(.*) ]]; then
      current_name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]+checkout_uuid:[[:space:]]+(.*) ]]; then
      checkout_urls+=("${checkout_base}/${BASH_REMATCH[1]}|${current_name}")
    fi
  done < "$config_file"

  echo "**Checkout Links:**" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  for entry in "${checkout_urls[@]}"; do
    IFS='|' read -r url name <<< "$entry"
    local status
    status=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null)
    if [[ "$status" == "200" ]] || [[ "$status" == "301" ]] || [[ "$status" == "302" ]]; then
      echo "- $name: $status" >> "$REPORT_FILE"
    else
      echo "- **🔴 $name: $status (BROKEN)**" >> "$REPORT_FILE"
      failures=$((failures + 1))
    fi
    infra_raw="${infra_raw}\n${name} checkout: HTTP ${status}"
  done

  echo "" >> "$REPORT_FILE"

  # Check appcast feeds (CRITICAL - no updates if broken)
  echo "**Appcast Feeds:**" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local appcast_urls=(
    "https://sanebar.com/appcast.xml|SaneBar"
    "https://saneclick.com/appcast.xml|SaneClick"
    "https://saneclip.com/appcast.xml|SaneClip"
    "https://sanehosts.com/appcast.xml|SaneHosts"
  )

  for entry in "${appcast_urls[@]}"; do
    IFS='|' read -r url name <<< "$entry"
    local status
    status=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null)
    if [[ "$status" == "200" ]] || [[ "$status" == "301" ]] || [[ "$status" == "302" ]]; then
      echo "- $name: $status" >> "$REPORT_FILE"
    else
      echo "- **🔴 $name: $status (BROKEN - NO UPDATES FOR USERS!)**" >> "$REPORT_FILE"
      failures=$((failures + 1))
    fi
    infra_raw="${infra_raw}\n${name} appcast: HTTP ${status}"
  done

  echo "" >> "$REPORT_FILE"

  # Check dist workers
  echo "**Distribution Workers (R2 Download Endpoints):**" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  local dist_urls=(
    "https://dist.sanebar.com/|SaneBar"
    "https://dist.saneclick.com/|SaneClick"
    "https://dist.saneclip.com/|SaneClip"
    "https://dist.sanehosts.com/|SaneHosts"
    # SaneSync and SaneVideo not yet released - uncomment when active:
    # "https://dist.sanesync.com/|SaneSync"
    # "https://dist.sanevideo.com/|SaneVideo"
  )

  for entry in "${dist_urls[@]}"; do
    IFS='|' read -r url name <<< "$entry"
    local status
    status=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 10 "$url" 2>/dev/null)
    # 404 and 403 are OK for root - workers respond to specific file paths
    if [[ "$status" == "200" ]] || [[ "$status" == "301" ]] || [[ "$status" == "302" ]] || [[ "$status" == "403" ]] || [[ "$status" == "404" ]]; then
      echo "- $name: $status" >> "$REPORT_FILE"
    else
      echo "- **🔴 $name: $status (BROKEN - DOWNLOADS FAIL!)**" >> "$REPORT_FILE"
      failures=$((failures + 1))
    fi
    infra_raw="${infra_raw}\n${name} dist: HTTP ${status}"
  done

  echo "" >> "$REPORT_FILE"

  # Scan HTML files for wrong checkout domains
  local bad_domains=0
  for dir in "$APPS_DIR"/*/docs "$APPS_DIR"/SaneHosts/website; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' html_file; do
      local wrong_domains
      wrong_domains=$(grep -oP 'https?://(?!saneapps)[a-z]+\.lemonsqueezy\.com/checkout/' "$html_file" 2>/dev/null | head -5)
      if [[ -n "$wrong_domains" ]]; then
        local rel_path="${html_file#$APPS_DIR/}"
        echo "- **🔴 Wrong checkout domain in $rel_path**" >> "$REPORT_FILE"
        bad_domains=$((bad_domains + 1))
      fi
    done < <(find "$dir" -name "*.html" -print0 2>/dev/null)
  done

  if [[ $bad_domains -gt 0 ]]; then
    echo "" >> "$REPORT_FILE"
    echo "**⚠️ $bad_domains file(s) have wrong checkout domain (should be saneapps.lemonsqueezy.com)**" >> "$REPORT_FILE"
    failures=$((failures + bad_domains))
  fi

  if [[ $failures -gt 0 ]]; then
    echo "" >> "$REPORT_FILE"
    echo "**🚨 ACTION REQUIRED: $failures sales infrastructure issue(s) detected!**" >> "$REPORT_FILE"
    # macOS notification for critical issue
    osascript -e "display notification \"$failures sales infrastructure issues found!\" with title \"SaneApps ALERT\" sound name \"Sosumi\"" 2>/dev/null
  fi

  echo "" >> "$REPORT_FILE"
  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 6: Codebase Health Sweep (nv --sweep)
# =============================================================================
section_codebase_health() {
  if [[ -n "${NV_MORNING_SKIP_HEALTH:-}" ]]; then
    echo "## 🏥 Codebase Health" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "**Status:** Skipped (NV_MORNING_SKIP_HEALTH=1)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 0
  fi

  echo "## 🏥 Codebase Health" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  if [[ ! -x "$NV_CMD" ]]; then
    echo "**Status:** nv CLI not available" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return 1
  fi

  for app in $REPOS; do
    local app_dir="$APPS_DIR/$app"

    if [[ ! -d "$app_dir" ]]; then
      echo "### $app" >> "$REPORT_FILE"
      echo "**Status:** Directory not found at $app_dir" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"
      continue
    fi

    echo "### $app" >> "$REPORT_FILE"

    local sweep_output
    sweep_output=$("$NV_CMD" --sweep "$app_dir/**/*.swift" -m kimi-fast \
      "List TODOs, FIXMEs, deprecated API usage, and potential bugs. One line per issue. Format: 'File:Line - Issue'. Limit to top 10 most important." 2>/dev/null || echo "Sweep failed")

    if [[ "$sweep_output" == *"Sweep failed"* ]] || [[ -z "$sweep_output" ]]; then
      echo "**Status:** Sweep unavailable" >> "$REPORT_FILE"
    else
      echo '```' >> "$REPORT_FILE"
      echo "$sweep_output" | head -20 >> "$REPORT_FILE"
      echo '```' >> "$REPORT_FILE"
    fi

    echo "" >> "$REPORT_FILE"
  done

  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 7: Git Status Summary
# =============================================================================
section_git_status() {
  echo "## 📊 Git Status" >> "$REPORT_FILE"
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
  echo "---" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

# =============================================================================
# Section 8: Executive Summary (nv reads everything, writes the TL;DR)
# =============================================================================
section_executive_summary() {
  if [[ ! -x "$NV_CMD" ]]; then return 0; fi

  # Read the report so far and generate a 5-line executive summary
  local report_so_far
  report_so_far=$(cat "$REPORT_FILE")

  local summary
  summary=$("$NV_CMD" -m kimi-fast --no-stream \
    "You are the CTO reviewing a morning report for a solo indie Mac app developer (SaneApps portfolio: SaneBar, SaneClick, SaneClip, SaneHosts, SaneSync, SaneVideo). Write a 5-line EXECUTIVE SUMMARY for the top of this report. Format:

🟢/🟡/🔴 [Overall status one-liner]
- Revenue: [one-liner]
- Traffic: [one-liner]
- GitHub: [one-liner]
- Action needed: [the ONE most important thing to do today]

Be specific with numbers. No fluff." <<< "$report_so_far" 2>/dev/null || echo "")

  if [[ -n "$summary" ]]; then
    # Insert executive summary after the header
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
# Data-fetching sections first (they populate cache)
safe_section "Revenue" section_revenue
safe_section "Website Traffic" section_website_traffic
safe_section "GitHub Traction" section_github_traction
safe_section "Customer Intel" section_customer_intel

# Analysis section (reads cache from above)
safe_section "Conversion Funnel" section_funnel

# API health (CRITICAL - catches API outages)
safe_section "API Health" section_api_health

# Sales infrastructure health (CRITICAL - catches dead checkout links)
safe_section "Sales Infrastructure" section_sales_infrastructure

# Independent sections
safe_section "Codebase Health" section_codebase_health
safe_section "Git Status" section_git_status

# Roadmap items (council-sourced, reviewed 2026-02-05)
section_roadmap() {
  local roadmap_file="$CACHE_DIR/roadmap.md"
  if [[ -f "$roadmap_file" ]]; then
    echo "## 🗺️ Automation Roadmap" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    cat "$roadmap_file" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi
}
safe_section "Roadmap" section_roadmap

# Executive summary LAST (reads entire report, writes TL;DR at top)
safe_section "Executive Summary" section_executive_summary

# Footer
cat >> "$REPORT_FILE" <<EOF

---

**Report generated:** $(date +"%Y-%m-%d %H:%M:%S")
**Location:** $REPORT_FILE
**nv calls:** Revenue analysis, traffic analysis, GitHub analysis, customer priorities, funnel analysis, executive summary (6 calls, all free)

_Review this report before taking action. Drafts are NOT sent automatically._
EOF

echo "✅ Morning report complete: $REPORT_FILE" >&2
