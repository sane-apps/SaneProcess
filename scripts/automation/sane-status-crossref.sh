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

printf '\nSane status cross-reference (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

printf '\n[1/8] Sales (last 30 days)\n'
if [[ -x "$SANE_MASTER" ]]; then
  ruby "$SANE_MASTER" sales --days 30
else
  echo "SaneMaster sales not executable"
fi

printf '\n[2/8] Inbox status\n'
if [[ -x "$CHECK_INBOX" ]]; then
  "$CHECK_INBOX"
else
  echo "check-inbox.sh not found at $CHECK_INBOX"
fi

printf '\n[3/8] Listing actions\n'
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

printf '\n[4/8] Hosted-file dashboard actions\n'
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

printf '\n[5/8] GitHub notifications\n'
github_notifications || true

printf '\n[6/8] Open GitHub issues (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" issues --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\n[7/8] Open GitHub PRs (sane-apps org)\n'
if [[ -x "$GITHUB_QUEUE" ]]; then
  "$GITHUB_QUEUE" prs --scope org-wide --limit "${STATUS_GITHUB_LIMIT:-200}"
else
  echo "github-queue.sh not found at $GITHUB_QUEUE"
fi

printf '\n[8/8] GitHub comment/review activity on open issues, PRs, and external notifications\n'
github_comment_activity || true
github_external_notification_activity || true

printf '\nDone.\n'
