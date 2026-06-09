#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_INBOX="${HOME}/SaneApps/infra/scripts/check-inbox.sh"
SANE_MASTER="${REPO_ROOT}/SaneMaster.rb"
GITHUB_QUEUE="${SCRIPT_DIR}/github-queue.sh"
LISTING_JSON_PATH="${STATUS_LISTING_JSON_PATH:-}"
LISTING_JSON_CLEANUP=0
HOSTED_JSON_PATH="${STATUS_HOSTED_JSON_PATH:-}"
HOSTED_JSON_CLEANUP=0
GITHUB_ISSUES_JSON_PATH="${STATUS_GITHUB_ISSUES_JSON_PATH:-}"
GITHUB_ISSUES_JSON_CLEANUP=0
GITHUB_PRS_JSON_PATH="${STATUS_GITHUB_PRS_JSON_PATH:-}"
GITHUB_PRS_JSON_CLEANUP=0
STATUS_GITHUB_ACTIVITY_LIMIT="${STATUS_GITHUB_ACTIVITY_LIMIT:-50}"
STATUS_GITHUB_COMMENT_LIMIT="${STATUS_GITHUB_COMMENT_LIMIT:-3}"
STATUS_GITHUB_NOTIFICATION_ACTIVITY_LIMIT="${STATUS_GITHUB_NOTIFICATION_ACTIVITY_LIMIT:-10}"

load_github_token() {
  if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
    if [[ -z "${GH_TOKEN:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
      export GH_TOKEN="$GITHUB_TOKEN"
    fi
    if [[ -z "${GITHUB_TOKEN:-}" && -n "${GH_TOKEN:-}" ]]; then
      export GITHUB_TOKEN="$GH_TOKEN"
    fi
    return 0
  fi

  local token_path token
  token_path="${STATUS_GITHUB_TOKEN_FILE:-${HOME}/.codex/secrets/github_token}"
  if [[ -r "$token_path" ]]; then
    token="$(tr -d '\r\n' < "$token_path" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      export GITHUB_TOKEN="$token"
      export GH_TOKEN="$token"
    fi
  fi
}

load_github_token

if [[ -z "$LISTING_JSON_PATH" ]]; then
  LISTING_JSON_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-listing.XXXXXX")"
  LISTING_JSON_CLEANUP=1
fi

if [[ -z "$HOSTED_JSON_PATH" ]]; then
  HOSTED_JSON_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-hosted.XXXXXX")"
  HOSTED_JSON_CLEANUP=1
fi

if [[ -z "$GITHUB_ISSUES_JSON_PATH" ]]; then
  GITHUB_ISSUES_JSON_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-issues.XXXXXX")"
  GITHUB_ISSUES_JSON_CLEANUP=1
fi

if [[ -z "$GITHUB_PRS_JSON_PATH" ]]; then
  GITHUB_PRS_JSON_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-prs.XXXXXX")"
  GITHUB_PRS_JSON_CLEANUP=1
fi

cleanup() {
  if [[ "$LISTING_JSON_CLEANUP" -eq 1 ]]; then
    rm -f "$LISTING_JSON_PATH"
  fi
  if [[ "$HOSTED_JSON_CLEANUP" -eq 1 ]]; then
    rm -f "$HOSTED_JSON_PATH"
  fi
  if [[ "$GITHUB_ISSUES_JSON_CLEANUP" -eq 1 ]]; then
    rm -f "$GITHUB_ISSUES_JSON_PATH"
  fi
  if [[ "$GITHUB_PRS_JSON_CLEANUP" -eq 1 ]]; then
    rm -f "$GITHUB_PRS_JSON_PATH"
  fi
}

trap cleanup EXIT

github_notifications() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) not installed"
    return 1
  fi

  local output notifications_path
  output="$(gh api notifications --paginate 2>&1)" || {
    echo "Unable to fetch GitHub notifications."
    echo "$output"
    return 1
  }
  notifications_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notifications.XXXXXX")"
  printf '%s\n' "$output" > "$notifications_path"

  python3 - "$notifications_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        notifications = json.load(handle)
except json.JSONDecodeError as exc:
    print(f"Unable to parse GitHub notifications JSON: {exc}")
    sys.exit(1)

print(f"Notifications: {len(notifications)}")
if not notifications:
    print("No unread GitHub notifications.")
    sys.exit(0)

for item in notifications[:20]:
    repo = (item.get("repository") or {}).get("full_name", "")
    subject = item.get("subject") or {}
    title = subject.get("title", "")
    reason = item.get("reason", "")
    updated = item.get("updated_at", "")
    subject_type = subject.get("type", "")
    url = subject.get("url", "")
    print(f"- {repo}: {subject_type} | {reason} | {updated}")
    print(f"  {title}")
    if url:
        print(f"  api: {url}")
PY
  rm -f "$notifications_path"
}

fetch_github_items_json() {
  local mode="$1"
  local out_path="$2"
  if [[ "$mode" == "issues" ]]; then
    gh search issues --owner sane-apps --state open --limit "$STATUS_GITHUB_ACTIVITY_LIMIT" \
      --json repository,number,title,updatedAt,url > "$out_path"
  else
    gh search prs --owner sane-apps --state open --limit "$STATUS_GITHUB_ACTIVITY_LIMIT" \
      --json repository,number,title,updatedAt,url,author,isDraft > "$out_path"
  fi
}

github_comment_activity() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) not installed"
    return 1
  fi

  fetch_github_items_json issues "$GITHUB_ISSUES_JSON_PATH" || {
    echo "Unable to fetch GitHub issues for comment review."
    return 1
  }
  fetch_github_items_json prs "$GITHUB_PRS_JSON_PATH" || {
    echo "Unable to fetch GitHub PRs for comment review."
    return 1
  }

  local items_path
  items_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-items.XXXXXX")"
  python3 - "$GITHUB_ISSUES_JSON_PATH" "$GITHUB_PRS_JSON_PATH" > "$items_path" <<'PY'
import json
import sys

for kind, path in (("issue", sys.argv[1]), ("pr", sys.argv[2])):
    with open(path, "r", encoding="utf-8") as handle:
        rows = json.load(handle)
    for row in rows:
        repo = (row.get("repository") or {}).get("nameWithOwner", "")
        number = row.get("number")
        updated = row.get("updatedAt", "")
        title = row.get("title", "")
        if repo and number:
            print(f"{kind}\t{repo}\t{number}\t{updated}\t{title}")
PY
  local detail_path
  while IFS=$'\t' read -r kind repo number updated title; do
    [[ -n "$kind" ]] || continue
    detail_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-detail.XXXXXX")"
    if [[ "$kind" == "issue" ]]; then
      if ! gh issue view "$number" --repo "$repo" --comments \
        --json title,url,updatedAt,comments,labels > "$detail_path" 2>/dev/null; then
        echo "- $repo #$number: unable to read issue comments"
        rm -f "$detail_path"
        continue
      fi
      python3 - "$detail_path" "$kind" "$repo" "$number" "$updated" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, kind, repo, number, updated, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} #{number}: unable to read {kind} comments")
    sys.exit(0)

comments = payload.get("comments") or []
labels = ", ".join((label.get("name") or "") for label in (payload.get("labels") or []) if label.get("name"))
print(f"- {repo} #{number}: {payload.get('title') or title}")
print(f"  Updated: {payload.get('updatedAt') or updated} | Comments read: {len(comments)} | Labels: {labels or 'none'}")
for comment in comments[-limit:]:
    author = (comment.get("author") or {}).get("login", "unknown")
    created = comment.get("createdAt") or comment.get("updatedAt") or ""
    body = " ".join((comment.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - {created} @{author}: {body}")
PY
    else
      if ! gh pr view "$number" --repo "$repo" --comments \
        --json title,url,updatedAt,comments,labels,reviews,author,isDraft > "$detail_path" 2>/dev/null; then
        echo "- $repo PR #$number: unable to read PR comments"
        rm -f "$detail_path"
        continue
      fi
      python3 - "$detail_path" "$kind" "$repo" "$number" "$updated" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, kind, repo, number, updated, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} PR #{number}: unable to read PR comments")
    sys.exit(0)

comments = payload.get("comments") or []
reviews = payload.get("reviews") or []
labels = ", ".join((label.get("name") or "") for label in (payload.get("labels") or []) if label.get("name"))
author = ((payload.get("author") or {}).get("login")) or "unknown"
state = "DRAFT" if payload.get("isDraft") else "OPEN"
print(f"- {repo} PR #{number}: {payload.get('title') or title}")
print(f"  State: {state} | Author: @{author} | Updated: {payload.get('updatedAt') or updated} | Comments read: {len(comments)} | Reviews read: {len(reviews)} | Labels: {labels or 'none'}")
for comment in comments[-limit:]:
    comment_author = (comment.get("author") or {}).get("login", "unknown")
    created = comment.get("createdAt") or comment.get("updatedAt") or ""
    body = " ".join((comment.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - comment {created} @{comment_author}: {body}")
for review in reviews[-limit:]:
    review_author = (review.get("author") or {}).get("login", "unknown")
    submitted = review.get("submittedAt") or ""
    state = review.get("state") or ""
    body = " ".join((review.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - review {submitted} @{review_author} [{state}]: {body}")
PY
    fi
    rm -f "$detail_path"
  done < "$items_path"
  rm -f "$items_path"
}

github_external_notification_activity() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) not installed"
    return 1
  fi

  local output notifications_path items_path
  output="$(gh api notifications --paginate 2>&1)" || {
    echo "Unable to fetch GitHub notifications for external activity review."
    echo "$output"
    return 1
  }
  notifications_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notifications.XXXXXX")"
  items_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notification-items.XXXXXX")"
  printf '%s\n' "$output" > "$notifications_path"

  if ! python3 - "$notifications_path" "$STATUS_GITHUB_NOTIFICATION_ACTIVITY_LIMIT" > "$items_path" <<'PY'
import json
import re
import sys

path, limit = sys.argv[1], int(sys.argv[2])
try:
    with open(path, "r", encoding="utf-8") as handle:
        notifications = json.load(handle)
except json.JSONDecodeError as exc:
    print(f"Unable to parse GitHub notifications JSON: {exc}", file=sys.stderr)
    sys.exit(1)

seen = set()
for item in notifications:
    repo = ((item.get("repository") or {}).get("full_name") or "").strip()
    if not repo or repo.startswith("sane-apps/"):
        continue
    if not re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo):
        continue
    subject = item.get("subject") or {}
    subject_type = subject.get("type") or ""
    if subject_type not in ("Issue", "PullRequest"):
        continue
    url = subject.get("url") or ""
    match = re.search(r"/(?:issues|pulls)/(\d+)$", url)
    if not match:
        continue
    number = match.group(1)
    if not number.isdigit():
        continue
    kind = "pr" if subject_type == "PullRequest" else "issue"
    key = (kind, repo, number)
    if key in seen:
        continue
    seen.add(key)
    print("\t".join([
        kind,
        repo,
        number,
        item.get("updated_at") or "",
        item.get("reason") or "",
        subject.get("title") or "",
    ]))
    if len(seen) >= limit:
        break
PY
  then
    rm -f "$notifications_path" "$items_path"
    return 1
  fi

  if [[ ! -s "$items_path" ]]; then
    echo "No external GitHub issue/PR notifications to expand."
    rm -f "$notifications_path" "$items_path"
    return 0
  fi

  echo "External notification-backed GitHub threads:"
  local detail_path
  while IFS=$'\t' read -r kind repo number updated reason title; do
    [[ -n "$kind" ]] || continue
    detail_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notification-detail.XXXXXX")"
    if [[ "$kind" == "issue" ]]; then
      if ! gh issue view "$number" --repo "$repo" --comments \
        --json title,state,url,updatedAt,comments,labels > "$detail_path" 2>/dev/null; then
        echo "- $repo #$number: unable to read notification-backed issue ($reason)"
        rm -f "$detail_path"
        continue
      fi
      python3 - "$detail_path" "$repo" "$number" "$updated" "$reason" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, repo, number, updated, reason, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} #{number}: unable to read notification-backed issue comments")
    sys.exit(0)

comments = payload.get("comments") or []
labels = ", ".join((label.get("name") or "") for label in (payload.get("labels") or []) if label.get("name"))
print(f"- {repo} #{number}: {payload.get('title') or title}")
print(f"  Notification: {reason} | State: {payload.get('state') or 'unknown'} | Updated: {payload.get('updatedAt') or updated} | Comments read: {len(comments)} | Labels: {labels or 'none'}")
for comment in comments[-limit:]:
    author = (comment.get("author") or {}).get("login", "unknown")
    created = comment.get("createdAt") or comment.get("updatedAt") or ""
    body = " ".join((comment.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - comment {created} @{author}: {body}")
PY
    else
      if ! gh pr view "$number" --repo "$repo" --comments \
        --json title,state,url,updatedAt,comments,reviews,author,isDraft > "$detail_path" 2>/dev/null; then
        echo "- $repo PR #$number: unable to read notification-backed PR ($reason)"
        rm -f "$detail_path"
        continue
      fi
      python3 - "$detail_path" "$repo" "$number" "$updated" "$reason" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, repo, number, updated, reason, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} PR #{number}: unable to read notification-backed PR comments")
    sys.exit(0)

comments = payload.get("comments") or []
reviews = payload.get("reviews") or []
author = ((payload.get("author") or {}).get("login")) or "unknown"
state = payload.get("state") or ("DRAFT" if payload.get("isDraft") else "OPEN")
print(f"- {repo} PR #{number}: {payload.get('title') or title}")
print(f"  Notification: {reason} | State: {state} | Author: @{author} | Updated: {payload.get('updatedAt') or updated} | Comments read: {len(comments)} | Reviews read: {len(reviews)}")
for comment in comments[-limit:]:
    comment_author = (comment.get("author") or {}).get("login", "unknown")
    created = comment.get("createdAt") or comment.get("updatedAt") or ""
    body = " ".join((comment.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - comment {created} @{comment_author}: {body}")
for review in reviews[-limit:]:
    review_author = (review.get("author") or {}).get("login", "unknown")
    submitted = review.get("submittedAt") or ""
    review_state = review.get("state") or ""
    body = " ".join((review.get("body") or "").split())
    if len(body) > 220:
        body = body[:217] + "..."
    print(f"  - review {submitted} @{review_author} [{review_state}]: {body}")
PY
    fi
    rm -f "$detail_path"
  done < "$items_path"
  rm -f "$notifications_path" "$items_path"
}

outreach_launch_status() {
  ruby <<'RUBY'
require 'date'
require 'yaml'

paths = Dir[
  File.expand_path('~/SaneApps/apps/*/.outreach.yml'),
  File.expand_path('~/SaneApps/SaneAI/.outreach.yml')
].uniq.sort

if paths.empty?
  puts 'No .outreach.yml files found.'
  exit 0
end

def compact_text(value, max = 180)
  text = value.to_s.gsub(/\s+/, ' ').strip
  text.length > max ? "#{text[0, max - 3]}..." : text
end

def status_counts(hash)
  hash.each_value.each_with_object(Hash.new(0)) do |entry, counts|
    next unless entry.is_a?(Hash)

    counts[entry['status'] || 'unknown'] += 1
  end
end

today = Date.today
puts "Tracked apps: #{paths.length}"

paths.each do |path|
  data = YAML.load_file(path) || {}
  product = data['product'] || data['app'] || File.basename(File.dirname(path))
  calendar = data['launch_calendar'] || {}
  package = data['launch_package'] || {}
  classification = calendar['classification'] || package['status'] || 'unknown'
  package_status = package['status']
  last_readiness = calendar['last_launch_readiness'] || package['last_launch_readiness']

  puts "- #{product}: #{classification}"
  puts "  package: #{package_status}" if package_status && package_status != classification

  launches = Array(data['launches']).select { |entry| entry.is_a?(Hash) }
  unless launches.empty?
    summary = launches.first(3).map do |entry|
      label = entry['name'] || entry['channel'] || 'Launch'
      status = entry['status'] || 'unknown'
      "#{label}=#{status}"
    end.join('; ')
    puts "  launches: #{summary}"
  end

  channel_plan = package['channel_plan']
  if channel_plan.is_a?(Hash) && !channel_plan.empty?
    summary = channel_plan.first(5).map { |channel, status| "#{channel}=#{status}" }.join('; ')
    puts "  channels: #{summary}"
  end

  directory_submissions = data['directory_submissions']
  if directory_submissions.is_a?(Hash) && !directory_submissions.empty?
    counts = status_counts(directory_submissions)
    count_summary = counts.map { |status, count| "#{status}=#{count}" }.join(', ')
    puts "  directories/listings: #{count_summary}" unless count_summary.empty?
  end

  product_hunt = data.dig('directory_submissions', 'product_hunt') ||
                 data.dig('video_distribution', 'product_hunt') ||
                 data['product_hunt']
  if product_hunt.is_a?(Hash)
    ph_bits = []
    ph_bits << "status=#{product_hunt['status']}" if product_hunt['status']
    ph_bits << "votes=#{product_hunt['observed_votes']}" if product_hunt['observed_votes']
    ph_bits << "rank=#{product_hunt['observed_daily_rank']}" if product_hunt['observed_daily_rank']
    ph_bits << "url=#{product_hunt['product_url'] || product_hunt['url']}" if product_hunt['product_url'] || product_hunt['url']
    puts "  Product Hunt: #{ph_bits.join('; ')}" unless ph_bits.empty?
  end

  video = data.dig('video_distribution', 'youtube_upload_candidate') || data.dig('video_distribution', 'youtube')
  if video.is_a?(Hash)
    video_bits = []
    video_bits << "status=#{video['status']}" if video['status']
    video_bits << "url=#{video['youtube_url'] || video['url']}" if video['youtube_url'] || video['url']
    puts "  video: #{video_bits.join('; ')}" unless video_bits.empty?
  end

  x_posts = Array(data['x_tweet_history']).select { |entry| entry.is_a?(Hash) }
  posted = x_posts.select { |entry| entry['status'] == 'posted' }
  deleted = x_posts.select { |entry| entry['status'] == 'deleted' }
  if posted.any? || deleted.any?
    latest = posted.max_by { |entry| entry['date'].to_s }
    x_line = "posted=#{posted.length}"
    x_line += ", deleted=#{deleted.length}" if deleted.any?
    x_line += ", latest=#{latest['url']}" if latest && latest['url']
    puts "  X: #{x_line}"
  end

  scheduled = Array(calendar['scheduled']).select { |entry| entry.is_a?(Hash) }
  actionable = scheduled.select do |entry|
    next true unless entry['date']

    begin
      Date.parse(entry['date'].to_s) >= today
    rescue ArgumentError
      true
    end
  end
  actionable = scheduled if actionable.empty?
  next_item = actionable.first
  if next_item
    pieces = [
      next_item['date'],
      next_item['time'],
      next_item['channel'],
      "[#{next_item['status'] || 'unknown'}]"
    ].compact
    puts "  next: #{pieces.join(' ')}"
    puts "  next action: #{compact_text(next_item['action'])}" if next_item['action']
  end

  if last_readiness.is_a?(Hash)
    readiness = [
      last_readiness['date'],
      last_readiness['status'],
      ("exit=#{last_readiness['launch_readiness_exit']}" if last_readiness.key?('launch_readiness_exit'))
    ].compact.join(' ')
    puts "  launch readiness: #{readiness}" unless readiness.empty?
  end

  blockers = Array(calendar['blockers']) +
             Array(package['channel_blockers']) +
             Array(last_readiness && last_readiness['blocker_summary'])
  blockers = blockers.compact.map { |item| compact_text(item, 140) }.uniq
  puts "  blockers: #{blockers.first(3).join(' | ')}" unless blockers.empty?
end
RUBY
}

printf '\nSane status cross-reference (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

printf '\n[1/9] Sales (last 30 days)\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" sales --days 30
else
  echo "SaneMaster sales not executable"
fi

printf '\n[2/9] Inbox status\n'
if [[ -x "$CHECK_INBOX" ]]; then
  "$CHECK_INBOX"
else
  echo "check-inbox.sh not found at $CHECK_INBOX"
fi

printf '\n[3/9] Listing actions\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" listing_actions --json-out "$LISTING_JSON_PATH" >/dev/null
  python3 - "$LISTING_JSON_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
current = payload.get("current_actions", [])
needs = [row for row in current if row.get("action_status") == "Needs action"]
optional = [row for row in current if row.get("action_status") == "Optional"]
monitor = [row for row in current if row.get("action_status") == "Monitor"]

print(f"Current actions: {len(current)}")
print(f"Needs action: {len(needs)} | Optional: {len(optional)} | Monitor: {len(monitor)}")
if needs:
    print("")
    for row in needs[:10]:
        print(
            f"- {row.get('site', '')}: {row.get('workflow', '')} "
            f"(email #{row.get('latest_email_id', '')})"
        )
else:
    print("No live listing/setup actions.")
PY
else
  echo "SaneMaster listing_actions not executable"
fi

printf '\n[4/9] Hosted-file dashboard actions\n'
if [[ -x "$SANE_MASTER" ]]; then
  if ruby "$SANE_MASTER" hosted_file_actions --json > "$HOSTED_JSON_PATH"; then
    python3 - "$HOSTED_JSON_PATH" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

current = payload.get("current_actions", [])
print(f"Needs dashboard sync: {len(current)}")
if current:
    print("")
    for row in current[:10]:
        app = row.get("app", "")
        hosted = row.get("hosted_version", "?")
        expected = row.get("expected_version", "?")
        variant = row.get("variant_id", "")
        print(f"- {app}: hosted {hosted} -> expected {expected} (variant {variant})")
else:
    print("No hosted-file dashboard actions.")
PY
  else
    echo "Unable to fetch hosted-file dashboard actions."
  fi
else
  echo "SaneMaster hosted_file_actions not executable"
fi

printf '\n[5/9] Outreach / launch operations\n'
outreach_launch_status || true

printf '\n[6/9] GitHub notifications\n'
github_notifications || true

printf '\n[7/9] Open GitHub issues (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" issues --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\n[8/9] Open GitHub PRs (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" prs --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\n[9/9] GitHub comment/review activity on open issues, PRs, and external notifications\n'
github_comment_activity || true
github_external_notification_activity || true

printf '\nDone.\n'
