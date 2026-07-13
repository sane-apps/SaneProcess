#!/bin/bash
set -uo pipefail

STATUS_GITHUB_SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export PATH="$STATUS_GITHUB_SAFE_PATH"
STATUS_GITHUB_HELPER_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_GITHUB_HELPER_PATH="${STATUS_GITHUB_HELPER_DIR}/sane-status-github.sh"
STATUS_GITHUB_RUNTIME_TOKEN_OWNED=0

status_verify_executable() {
  local candidate="${1:-}"
  [[ "$candidate" == /* ]] || return 1
  /usr/bin/ruby -e '
    path = File.realpath(ARGV.fetch(0))
    stat = File.stat(path)
    abort unless stat.file? && stat.executable?
    abort unless [Process.uid, 0].include?(stat.uid)
    abort unless (stat.mode & 0o022).zero?
    puts path
  ' "$candidate" 2>/dev/null
}

status_resolve_gh() {
  local candidate resolved
  if [[ "${STATUS_TEST_MODE:-0}" == "1" && -n "${STATUS_GH_BIN:-}" ]]; then
    resolved="$(status_verify_executable "$STATUS_GH_BIN")" || {
      echo "STATUS_GH_BIN is not a verified executable." >&2
      return 1
    }
    printf '%s\n' "$resolved"
    return 0
  fi

  for candidate in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
    [[ -e "$candidate" ]] || continue
    resolved="$(status_verify_executable "$candidate")" || continue
    printf '%s\n' "$resolved"
    return 0
  done
  echo "GitHub CLI (gh) is unavailable at an approved absolute path." >&2
  return 1
}

status_resolve_python() {
  local candidate resolved
  for candidate in /usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    [[ -e "$candidate" ]] || continue
    resolved="$(status_verify_executable "$candidate")" || continue
    printf '%s\n' "$resolved"
    return 0
  done
  echo "Python 3 is unavailable at an approved absolute path." >&2
  return 1
}

status_prepare_github_token_source() {
  local token
  if [[ -n "${STATUS_GITHUB_TOKEN_SOURCE_PATH:-}" ]]; then
    unset GH_TOKEN GITHUB_TOKEN
    return 0
  fi

  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  unset GH_TOKEN GITHUB_TOKEN
  if [[ -n "$token" ]]; then
    umask 077
    STATUS_GITHUB_TOKEN_SOURCE_PATH="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-token.XXXXXX")" || return 1
    chmod 600 "$STATUS_GITHUB_TOKEN_SOURCE_PATH" || {
      rm -f "$STATUS_GITHUB_TOKEN_SOURCE_PATH"
      return 1
    }
    printf '%s' "$token" > "$STATUS_GITHUB_TOKEN_SOURCE_PATH" || {
      rm -f "$STATUS_GITHUB_TOKEN_SOURCE_PATH"
      return 1
    }
    STATUS_GITHUB_RUNTIME_TOKEN_OWNED=1
  else
    STATUS_GITHUB_TOKEN_SOURCE_PATH="${STATUS_GITHUB_TOKEN_FILE:-${HOME}/.codex/secrets/github_token}"
  fi
  export STATUS_GITHUB_TOKEN_SOURCE_PATH
}

status_read_github_token() {
  local token_path="${STATUS_GITHUB_TOKEN_SOURCE_PATH:-}"
  [[ "$token_path" == /* ]] || {
    echo "GitHub token source must be an absolute path." >&2
    return 1
  }
  /usr/bin/ruby -e '
    path = ARGV.fetch(0)
    stat = File.lstat(path)
    abort if stat.symlink?
    abort unless stat.file? && stat.uid == Process.uid
    abort unless (stat.mode & 0o077).zero?
    token = File.binread(path).delete("\r\n")
    abort if token.empty?
    print token
  ' "$token_path" 2>/dev/null || {
    echo "GitHub token source is missing, empty, symlinked, foreign-owned, or too permissive." >&2
    return 1
  }
}

status_github_cleanup() {
  if [[ "${STATUS_GITHUB_RUNTIME_TOKEN_OWNED:-0}" -eq 1 && -n "${STATUS_GITHUB_TOKEN_SOURCE_PATH:-}" ]]; then
    rm -f "$STATUS_GITHUB_TOKEN_SOURCE_PATH"
    STATUS_GITHUB_RUNTIME_TOKEN_OWNED=0
  fi
}

status_gh() {
  local gh_bin token
  gh_bin="$(status_resolve_gh)" || return 1
  token="$(status_read_github_token)" || return 1

  if [[ "${STATUS_TEST_MODE:-0}" == "1" ]]; then
    /usr/bin/env -i \
      HOME="$HOME" \
      PATH="$STATUS_GITHUB_SAFE_PATH" \
      LANG="${LANG:-en_US.UTF-8}" \
      LC_ALL="${LC_ALL:-en_US.UTF-8}" \
      GH_TOKEN="$token" \
      GH_LOG="${GH_LOG:-}" \
      "$gh_bin" "$@"
  else
    /usr/bin/env -i \
      HOME="$HOME" \
      PATH="$STATUS_GITHUB_SAFE_PATH" \
      LANG="${LANG:-en_US.UTF-8}" \
      LC_ALL="${LC_ALL:-en_US.UTF-8}" \
      GH_TOKEN="$token" \
      "$gh_bin" "$@"
  fi
}

status_python() {
  local python_bin
  python_bin="$(status_resolve_python)" || return 1
  "$python_bin" "$@"
}

status_prepare_github_token_source || true

github_notifications() {
  local output notifications_path command_status
  output="$(status_gh api notifications --paginate 2>&1)" || {
    echo "Unable to fetch GitHub notifications."
    echo "$output"
    return 1
  }
  notifications_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notifications.XXXXXX")"
  printf '%s\n' "$output" > "$notifications_path"

  status_python - "$notifications_path" "$STATUS_GITHUB_HELPER_PATH" <<'PY'
import json
import re
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        notifications = json.load(handle)
except json.JSONDecodeError as exc:
    print(f"Unable to parse GitHub notifications JSON: {exc}")
    sys.exit(1)

gh_command = sys.argv[2]

print(f"Unread GitHub notifications: {len(notifications)}")
if not notifications:
    print("No unread GitHub notifications.")
    sys.exit(0)

def gh_json(endpoint):
    result = subprocess.run(
        [gh_command, "exec-gh", "api", endpoint],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh api failed for {endpoint}")
    return json.loads(result.stdout)

repo_run_cache = {}

def timestamp(value):
    raw = str(value or "").replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(raw)
        return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None

def notification_run(item, repo):
    subject = item.get("subject") or {}
    suite_url = subject.get("url")
    if suite_url:
        suite = gh_json(suite_url)
        checks_url = suite.get("check_runs_url") or f"repos/{repo}/check-suites/{suite.get('id')}/check-runs"
        checks = gh_json(checks_url).get("check_runs", [])
        for check in checks:
            match = re.search(r"/actions/runs/(\d+)", str(check.get("details_url") or ""))
            if match:
                return gh_json(f"repos/{repo}/actions/runs/{match.group(1)}")
        raise RuntimeError("check suite has no GitHub Actions run link")

    # GitHub currently returns null subject URLs for CheckSuite inbox rows.
    # Correlate only to a failed run for the same repository/workflow and a
    # close completion timestamp; otherwise fail closed as unknown.
    if repo not in repo_run_cache:
        repo_run_cache[repo] = gh_json(f"repos/{repo}/actions/runs?branch=main&per_page=100").get("workflow_runs", [])
    notified_at = timestamp(item.get("updated_at"))
    workflow_hint = str(subject.get("title") or "").split(" workflow run", 1)[0].strip().lower()
    candidates = []
    for candidate in repo_run_cache[repo]:
        if candidate.get("conclusion") != "failure":
            continue
        name = str(candidate.get("name") or "").strip().lower()
        if workflow_hint and name and name != workflow_hint:
            continue
        run_at = timestamp(candidate.get("updated_at") or candidate.get("created_at"))
        if not notified_at or not run_at:
            continue
        candidates.append((abs((notified_at - run_at).total_seconds()), candidate))
    if not candidates or min(candidates, key=lambda value: value[0])[0] > 900:
        raise RuntimeError("null-URL CheckSuite notification could not be matched to a failed Actions run")
    return min(candidates, key=lambda value: value[0])[1]

def check_suite_state(item):
    repo = (item.get("repository") or {}).get("full_name", "")
    run = notification_run(item, repo)
    workflow_id = run.get("workflow_id")
    branch = run.get("head_branch")
    if not workflow_id or not branch:
        raise RuntimeError("workflow run is missing workflow_id or head_branch")
    query_branch = urllib.parse.quote(str(branch), safe="")
    runs = gh_json(f"repos/{repo}/actions/workflows/{workflow_id}/runs?branch={query_branch}&per_page=20").get("workflow_runs", [])
    created = str(run.get("created_at") or "")
    recovered = [
        candidate for candidate in runs
        if str(candidate.get("created_at") or "") > created
        and candidate.get("status") == "completed"
        and candidate.get("conclusion") == "success"
    ]
    if recovered:
        latest = sorted(recovered, key=lambda value: str(value.get("created_at") or ""))[-1]
        return "superseded", run, latest
    if run.get("status") == "completed" and run.get("conclusion") == "success":
        return "recovered", run, run
    return "active", run, None

state_counts = {"active": 0, "superseded": 0, "recovered": 0, "unknown": 0}
for item in notifications[:20]:
    repo = (item.get("repository") or {}).get("full_name", "")
    subject = item.get("subject") or {}
    title = subject.get("title", "")
    reason = item.get("reason", "")
    updated = item.get("updated_at", "")
    subject_type = subject.get("type", "")
    url = subject.get("url", "")
    state = "unread"
    run = None
    recovery = None
    if subject_type == "CheckSuite":
        try:
            state, run, recovery = check_suite_state(item)
        except Exception as exc:
            state = "unknown"
            print(f"- {repo}: CheckSuite | unknown | {updated}")
            print(f"  {title}")
            print(f"  metadata error: {exc}")
            state_counts[state] += 1
            continue
        state_counts[state] += 1
    print(f"- {repo}: {subject_type} | {reason} | {updated}" + (f" | {state}" if subject_type == "CheckSuite" else ""))
    print(f"  {title}")
    if run:
        print(f"  run: {run.get('id')} | {run.get('conclusion') or run.get('status')} | {run.get('head_sha', '')[:12]}")
    if recovery:
        print(f"  later success: {recovery.get('id')} | {str(recovery.get('head_sha') or '')[:12]}")
    if url:
        print(f"  api: {url}")

check_total = sum(state_counts.values())
if check_total:
    print(
        "CheckSuite summary: "
        f"active={state_counts['active']} "
        f"superseded={state_counts['superseded']} "
        f"recovered={state_counts['recovered']} "
        f"unknown={state_counts['unknown']}"
    )
if state_counts["unknown"]:
    print("GitHub notification state is incomplete because CheckSuite metadata could not be resolved.")
    sys.exit(2)
PY
  command_status=$?
  rm -f "$notifications_path"
  return "$command_status"
}


fetch_github_items_json() {
  local mode="$1"
  local out_path="$2"
  if [[ "$mode" == "issues" ]]; then
    status_gh search issues --owner sane-apps --state open --limit "$STATUS_GITHUB_ACTIVITY_LIMIT" \
      --json repository,number,title,updatedAt,url > "$out_path"
  else
    status_gh search prs --owner sane-apps --state open --limit "$STATUS_GITHUB_ACTIVITY_LIMIT" \
      --json repository,number,title,updatedAt,url,author,isDraft > "$out_path"
  fi
}

github_comment_activity() {
  fetch_github_items_json issues "$GITHUB_ISSUES_JSON_PATH" || {
    echo "Unable to fetch GitHub issues for comment review."
    return 1
  }
  fetch_github_items_json prs "$GITHUB_PRS_JSON_PATH" || {
    echo "Unable to fetch GitHub PRs for comment review."
    return 1
  }

  local items_path activity_status=0
  items_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-items.XXXXXX")"
  status_python - "$GITHUB_ISSUES_JSON_PATH" "$GITHUB_PRS_JSON_PATH" > "$items_path" <<'PY'
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
  if [[ $? -ne 0 ]]; then
    rm -f "$items_path"
    return 1
  fi
  local detail_path
  while IFS=$'\t' read -r kind repo number updated title; do
    [[ -n "$kind" ]] || continue
    detail_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-detail.XXXXXX")"
    if [[ "$kind" == "issue" ]]; then
      if ! status_gh issue view "$number" --repo "$repo" --comments \
        --json title,url,updatedAt,comments,labels > "$detail_path" 2>/dev/null; then
        echo "- $repo #$number: unable to read issue comments"
        activity_status=1
        rm -f "$detail_path"
        continue
      fi
      status_python - "$detail_path" "$kind" "$repo" "$number" "$updated" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, kind, repo, number, updated, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} #{number}: unable to read {kind} comments")
    sys.exit(1)

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
      [[ $? -eq 0 ]] || activity_status=1
    else
      if ! status_gh pr view "$number" --repo "$repo" --comments \
        --json title,url,updatedAt,comments,labels,reviews,author,isDraft > "$detail_path" 2>/dev/null; then
        echo "- $repo PR #$number: unable to read PR comments"
        activity_status=1
        rm -f "$detail_path"
        continue
      fi
      status_python - "$detail_path" "$kind" "$repo" "$number" "$updated" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, kind, repo, number, updated, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} PR #{number}: unable to read PR comments")
    sys.exit(1)

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
      [[ $? -eq 0 ]] || activity_status=1
    fi
    rm -f "$detail_path"
  done < "$items_path"
  rm -f "$items_path"
  return "$activity_status"
}

github_external_notification_activity() {
  local output notifications_path items_path activity_status=0
  output="$(status_gh api notifications --paginate 2>&1)" || {
    echo "Unable to fetch GitHub notifications for external activity review."
    echo "$output"
    return 1
  }
  notifications_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notifications.XXXXXX")"
  items_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-gh-notification-items.XXXXXX")"
  printf '%s\n' "$output" > "$notifications_path"

  if ! status_python - "$notifications_path" "$STATUS_GITHUB_NOTIFICATION_ACTIVITY_LIMIT" > "$items_path" <<'PY'
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
      if ! status_gh issue view "$number" --repo "$repo" --comments \
        --json title,state,url,updatedAt,comments,labels > "$detail_path" 2>/dev/null; then
        echo "- $repo #$number: unable to read notification-backed issue ($reason)"
        activity_status=1
        rm -f "$detail_path"
        continue
      fi
      status_python - "$detail_path" "$repo" "$number" "$updated" "$reason" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, repo, number, updated, reason, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} #{number}: unable to read notification-backed issue comments")
    sys.exit(1)

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
      [[ $? -eq 0 ]] || activity_status=1
    else
      if ! status_gh pr view "$number" --repo "$repo" --comments \
        --json title,state,url,updatedAt,comments,reviews,author,isDraft > "$detail_path" 2>/dev/null; then
        echo "- $repo PR #$number: unable to read notification-backed PR ($reason)"
        activity_status=1
        rm -f "$detail_path"
        continue
      fi
      status_python - "$detail_path" "$repo" "$number" "$updated" "$reason" "$title" "$STATUS_GITHUB_COMMENT_LIMIT" <<'PY'
import json
import sys

path, repo, number, updated, reason, title, limit = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], int(sys.argv[7])
try:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except json.JSONDecodeError:
    print(f"- {repo} PR #{number}: unable to read notification-backed PR comments")
    sys.exit(1)

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
      [[ $? -eq 0 ]] || activity_status=1
    fi
    rm -f "$detail_path"
  done < "$items_path"
  rm -f "$notifications_path" "$items_path"
  return "$activity_status"
}

status_github_queue() {
  local mode="${1:-issues}"
  local limit="${2:-200}"
  local output

  printf 'Scope: org-wide\n'
  if [[ "$mode" == "issues" ]]; then
    output="$(status_gh search issues --owner sane-apps --state open --limit "$limit" \
      --json repository,number,title,labels,updatedAt,url \
      --jq '
        group_by(.repository.nameWithOwner)[]
        | "## " + .[0].repository.nameWithOwner + "\\n"
          + (map(
              "  #" + (.number | tostring)
              + "\\tOPEN\\t" + .title
              + "\\t" + (([.labels[].name] | join(", ")) // "")
              + "\\t" + .updatedAt
            ) | join("\\n"))
      ' 2>&1)" || {
      echo "Unable to fetch org-wide issues (auth missing or GitHub search unavailable)."
      echo "$output"
      return 1
    }
  elif [[ "$mode" == "prs" ]]; then
    output="$(status_gh search prs --owner sane-apps --state open --limit "$limit" \
      --json repository,number,title,labels,updatedAt,author,isDraft,url \
      --jq '
        group_by(.repository.nameWithOwner)[]
        | "## " + .[0].repository.nameWithOwner + "\\n"
          + (map(
              "  #" + (.number | tostring)
              + "\\t" + (if .isDraft then "DRAFT" else "OPEN" end)
              + "\\t" + .title
              + "\\t" + .author.login
              + "\\t" + (([.labels[].name] | join(", ")) // "")
              + "\\t" + .updatedAt
            ) | join("\\n"))
      ' 2>&1)" || {
      echo "Unable to fetch org-wide prs (auth missing or GitHub search unavailable)."
      echo "$output"
      return 1
    }
  else
    echo "Unknown GitHub queue mode: $mode" >&2
    return 2
  fi

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
  else
    echo "No open GitHub $mode found."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    exec-gh)
      shift
      status_gh "$@"
      ;;
    *)
      echo "Usage: sane-status-github.sh exec-gh <gh arguments...>" >&2
      exit 2
      ;;
  esac
fi
