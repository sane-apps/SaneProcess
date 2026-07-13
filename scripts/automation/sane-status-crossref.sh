#!/bin/bash
set -uo pipefail

STATUS_SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
export PATH="$STATUS_SAFE_PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_INBOX="${HOME}/SaneApps/infra/scripts/check-inbox.sh"
SANE_MASTER="${REPO_ROOT}/SaneMaster.rb"
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
STATUS_MODE="full"
STATUS_INCOMPLETE_EXIT=3
STATUS_UNAVAILABLE_COUNT=0
STATUS_UNAVAILABLE_LANES=""

for arg in "$@"; do
  case "$arg" in
    --full|full)
      STATUS_MODE="full"
      ;;
    --fast|fast)
      STATUS_MODE="fast"
      ;;
    -h|--help)
      echo "Usage: sane-status-crossref.sh [--fast|--full]"
      echo "Default: --full (includes release and distribution blockers)"
      echo "Exit 0: every selected lane ran; exit 3: one or more selected lanes were unavailable."
      echo "Fast mode is always partial and prints that disclaimer even when a selected lane fails."
      exit 0
      ;;
    *)
      echo "Unknown status argument: $arg" >&2
      echo "Usage: sane-status-crossref.sh [--fast|--full]" >&2
      exit 2
      ;;
  esac
done

run_status_lane() {
  local label="$1"
  shift
  local exit_status detail

  if "$@"; then
    return 0
  else
    exit_status=$?
  fi

  printf '⚠️  Lane unavailable: %s (exit %s)\n' "$label" "$exit_status"
  detail="${label} (exit ${exit_status})"
  STATUS_UNAVAILABLE_COUNT=$((STATUS_UNAVAILABLE_COUNT + 1))
  if [[ -z "$STATUS_UNAVAILABLE_LANES" ]]; then
    STATUS_UNAVAILABLE_LANES="$detail"
  else
    STATUS_UNAVAILABLE_LANES="${STATUS_UNAVAILABLE_LANES}
${detail}"
  fi
  return 0
}

print_unavailable_lanes() {
  printf '%s\n' "$STATUS_UNAVAILABLE_LANES" | while IFS= read -r lane; do
    [[ -n "$lane" ]] && printf -- '- %s\n' "$lane"
  done
}

run_setapp_status() {
  local output_path command_status
  output_path="$(mktemp "${TMPDIR:-/tmp}/sane-status-setapp.XXXXXX")"

  if ruby "$SANE_MASTER" setapp_status --soft > "$output_path"; then
    command_status=0
  else
    command_status=$?
  fi
  cat "$output_path"
  if grep -Eq 'Status unavailable:|Treat Setapp status as incomplete' "$output_path"; then
    command_status=1
  fi
  rm -f "$output_path"
  return "$command_status"
}

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
  if declare -f status_github_cleanup >/dev/null 2>&1; then
    status_github_cleanup
  fi
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

print_key_worktrees() {
  local repo label branch_line dirty_output dirty_count shown_count
  local unavailable=0

  for repo in \
    "$HOME/SaneApps/websites/sanecite-saas" \
    "$HOME/SaneApps/apps/SaneClip" \
    "$HOME/SaneApps/infra/SaneProcess"; do
    label="${repo#$HOME/SaneApps/}"
    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      printf -- '- %s: unavailable (not a Git worktree)\n' "$label"
      unavailable=1
      continue
    fi

    if ! branch_line="$(git -C "$repo" status --short --branch | sed -n '1p')"; then
      printf -- '- %s: unavailable (git status failed)\n' "$label"
      unavailable=1
      continue
    fi
    if ! dirty_output="$(git -C "$repo" status --porcelain --untracked-files=normal)"; then
      printf -- '- %s: unavailable (git worktree scan failed)\n' "$label"
      unavailable=1
      continue
    fi
    dirty_count="$(printf '%s\n' "$dirty_output" | sed '/^$/d' | wc -l | tr -d ' ')"
    printf -- '- %s: %s | dirty files: %s\n' "$label" "$branch_line" "$dirty_count"
    if [[ "$dirty_count" -gt 0 ]]; then
      printf '%s\n' "$dirty_output" | sed -n '1,8p' | sed 's/^/    /'
      shown_count=8
      if [[ "$dirty_count" -gt "$shown_count" ]]; then
        printf '    ... %s more\n' "$((dirty_count - shown_count))"
      fi
    fi
  done

  return "$unavailable"
}

fast_status() {
  printf '\nSane status fast (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "----------------------------------------"

  printf '\n[1/3] Active inbox actions\n'
  run_status_lane "Active inbox actions" env INBOX_FETCH_LIMIT="${STATUS_INBOX_LIMIT:-200}" "$CHECK_INBOX" active-summary

  printf '\n[2/3] Key worktrees\n'
  run_status_lane "Key worktrees" print_key_worktrees

  printf '\n[3/3] Deep lanes\n'
  echo "Skipped sales, Setapp, hosted-file dashboard, outreach, and GitHub comment expansion in fast mode."
  echo "Run: ruby $SANE_MASTER status"
  printf '\nFast summary complete; this is not a full readiness verdict.\n'

  if [[ "$STATUS_UNAVAILABLE_COUNT" -eq 0 ]]; then
    printf 'FAST STATUS: PARTIAL — selected lanes available (exit 0).\n'
    return 0
  fi

  printf 'FAST STATUS: PARTIAL AND INCOMPLETE — %s selected lane(s) unavailable.\n' "$STATUS_UNAVAILABLE_COUNT"
  print_unavailable_lanes
  printf 'Exit %s means selected status coverage was incomplete.\n' "$STATUS_INCOMPLETE_EXIT"
  return "$STATUS_INCOMPLETE_EXIT"
}

source "$SCRIPT_DIR/sane-status-github.sh" || {
  echo "Unable to load the status GitHub helper." >&2
  exit 1
}

if [[ "$STATUS_MODE" == "fast" ]]; then
  fast_status
  exit $?
fi

if [[ "${STATUS_GITHUB_NOTIFICATIONS_ONLY:-0}" == "1" ]]; then
  github_notifications
  exit $?
fi

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

full_listing_status() {
  ruby "$SANE_MASTER" listing_actions --json-out "$LISTING_JSON_PATH" >/dev/null || return $?
  ruby -rjson -e '
    rows = JSON.parse(File.read(ARGV.fetch(0))).fetch("current_actions", [])
    needs = rows.select { |row| row["action_status"] == "Needs action" }
    puts "Current actions: #{rows.length}"
    puts "Needs action: #{needs.length} | Optional: #{rows.count { |row| row["action_status"] == "Optional" }} | Monitor: #{rows.count { |row| row["action_status"] == "Monitor" }}"
    needs.first(10).each { |row| puts "- #{row["site"]}: #{row["workflow"]} (email ##{row["latest_email_id"]})" }
    puts "No live listing/setup actions." if needs.empty?
  ' "$LISTING_JSON_PATH"
}

full_hosted_file_status() {
  ruby "$SANE_MASTER" hosted_file_actions --json > "$HOSTED_JSON_PATH" || return $?
  ruby -rjson -e '
    rows = JSON.parse(File.read(ARGV.fetch(0))).fetch("current_actions", [])
    puts "Needs dashboard sync: #{rows.length}"
    rows.first(10).each { |row| puts "- #{row["app"]}: hosted #{row.fetch("hosted_version", "?")} -> expected #{row.fetch("expected_version", "?")} (variant #{row["variant_id"]})" }
    puts "No hosted-file dashboard actions." if rows.empty?
  ' "$HOSTED_JSON_PATH"
}

full_github_comment_status() {
  local exit_status=0

  github_comment_activity || exit_status=$?
  github_external_notification_activity || exit_status=$?
  return "$exit_status"
}

printf '\nSane status cross-reference (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' "----------------------------------------"

printf '\n[Core] Key worktrees\n'
run_status_lane "Core key worktrees" print_key_worktrees

printf '\n[1/10] Sales (last 30 days)\n'
run_status_lane "Sales" ruby "$SANE_MASTER" sales --days 30

printf '\n[2/10] Inbox status\n'
run_status_lane "Inbox status" "$CHECK_INBOX"

printf '\n[3/10] Listing actions\n'
run_status_lane "Listing actions" full_listing_status

printf '\n[4/10] Hosted-file dashboard actions\n'
run_status_lane "Hosted-file dashboard actions" full_hosted_file_status

printf '\n[5/10] Setapp distribution channel\n'
run_status_lane "Setapp distribution channel" run_setapp_status

printf '\n[6/10] Outreach / launch operations\n'
run_status_lane "Outreach / launch operations" outreach_launch_status

printf '\n[7/10] GitHub notifications\n'
run_status_lane "GitHub notifications" github_notifications

printf '\n[8/10] Open GitHub issues (sane-apps org)\n'
run_status_lane "Open GitHub issues" status_github_queue issues "${STATUS_GITHUB_LIMIT:-200}"

printf '\n[9/10] Open GitHub PRs (sane-apps org)\n'
run_status_lane "Open GitHub PRs" status_github_queue prs "${STATUS_GITHUB_LIMIT:-200}"

printf '\n[10/10] GitHub comment/review activity on open issues, PRs, and external notifications\n'
run_status_lane "GitHub comment/review activity" full_github_comment_status

if [[ "$STATUS_UNAVAILABLE_COUNT" -eq 0 ]]; then
  printf '\nFULL STATUS: COMPLETE — all selected lanes ran. Review reported blockers above.\n'
  exit 0
fi

printf '\nFULL STATUS: INCOMPLETE — %s selected lane(s) unavailable.\n' "$STATUS_UNAVAILABLE_COUNT"
print_unavailable_lanes
printf 'Exit %s means full status coverage was incomplete.\n' "$STATUS_INCOMPLETE_EXIT"
exit "$STATUS_INCOMPLETE_EXIT"
