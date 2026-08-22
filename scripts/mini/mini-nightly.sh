#!/bin/bash
# mini-nightly.sh - Bounded nightly verification for the Mac mini server
# Runs at 8:45 AM daily via LaunchAgent.

set -uo pipefail

DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="${SANE_ROOT:-$DEFAULT_SANE_ROOT}"
SANE_OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"

APPS_DIR="$SANE_ROOT/apps"
INFRA_DIR="$SANE_ROOT/infra"
OUTPUT_DIR="$SANE_OUTPUT_DIR"
REPORT="$OUTPUT_DIR/nightly_report.md"
DATE=$(date +"%Y-%m-%d %A")
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANONICAL_SOURCE_ROOT="$HOME/SaneApps"
SANEMASTER_SCRIPT="$CANONICAL_SOURCE_ROOT/infra/SaneProcess/scripts/SaneMaster.rb"
VERIFY_TIMEOUT_SECONDS="${MINI_NIGHTLY_VERIFY_TIMEOUT_SECONDS:-1800}"
CLEANUP_TIMEOUT_SECONDS="${MINI_NIGHTLY_CLEANUP_TIMEOUT_SECONDS:-1200}"
OPERATOR_BRIEF_TIMEOUT_SECONDS="${MINI_NIGHTLY_OPERATOR_BRIEF_TIMEOUT_SECONDS:-120}"
KEEP_CURRENT_TIMEOUT_SECONDS="${MINI_NIGHTLY_KEEP_CURRENT_TIMEOUT_SECONDS:-300}"
LOCK_DIR="$OUTPUT_DIR/.nightly.lock"
LOCK_OWNER_FILE="$LOCK_DIR/owner.pid"
VERIFY_RESULTS="$OUTPUT_DIR/.nightly-verify-results.$$"
VERIFY_LOG_DIR="$OUTPUT_DIR/nightly-verify-logs"
OPERATOR_BRIEF_TEMP="$OUTPUT_DIR/.operator-brief.$$"
LOCK_HELD=0

require_positive_integer() {
  local name="$1"
  local value="$2"
  case "$value" in
    ''|*[!0-9]*)
      echo "$name must be a positive integer" >&2
      exit 64
      ;;
  esac
  if [ "$value" -le 0 ]; then
    echo "$name must be a positive integer" >&2
    exit 64
  fi
}

require_positive_integer MINI_NIGHTLY_VERIFY_TIMEOUT_SECONDS "$VERIFY_TIMEOUT_SECONDS"
require_positive_integer MINI_NIGHTLY_CLEANUP_TIMEOUT_SECONDS "$CLEANUP_TIMEOUT_SECONDS"
require_positive_integer MINI_NIGHTLY_OPERATOR_BRIEF_TIMEOUT_SECONDS "$OPERATOR_BRIEF_TIMEOUT_SECONDS"
require_positive_integer MINI_NIGHTLY_KEEP_CURRENT_TIMEOUT_SECONDS "$KEEP_CURRENT_TIMEOUT_SECONDS"
VERIFY_OUTER_TIMEOUT_SECONDS=$((VERIFY_TIMEOUT_SECONDS + 60))

mkdir -p "$OUTPUT_DIR" "$VERIFY_LOG_DIR"

cleanup_nightly() {
  local owner=""
  rm -f "$VERIFY_RESULTS"
  rm -f "$OPERATOR_BRIEF_TEMP"
  if [ "$LOCK_HELD" -eq 1 ] && [ -f "$LOCK_OWNER_FILE" ]; then
    owner=$(cat "$LOCK_OWNER_FILE" 2>/dev/null || true)
    if [ "$owner" = "$$" ]; then
      rm -f "$LOCK_OWNER_FILE"
      rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

trap cleanup_nightly EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_nightly_lock() {
  local owner=""

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_OWNER_FILE"
    LOCK_HELD=1
    return 0
  fi

  if [ -f "$LOCK_OWNER_FILE" ]; then
    owner=$(cat "$LOCK_OWNER_FILE" 2>/dev/null || true)
  fi
  case "$owner" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$owner" 2>/dev/null; then
        echo "Another nightly instance is running (pid=$owner)" >&2
        return 1
      fi
      ;;
  esac

  # A stale lock is removable only when its recorded owner is absent. The lock
  # directory is deliberately constrained to one owner file, so no recursive
  # deletion is needed or allowed.
  rm -f "$LOCK_OWNER_FILE"
  if ! rmdir "$LOCK_DIR" 2>/dev/null; then
    echo "Cannot recover malformed nightly lock: $LOCK_DIR" >&2
    return 1
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another nightly instance acquired the lock" >&2
    return 1
  fi
  printf '%s\n' "$$" > "$LOCK_OWNER_FILE"
  LOCK_HELD=1
}

# Run a command in its own process group. The Ruby wrapper enforces a hard
# outer deadline and always terminates the complete child group before return.
run_bounded_command() {
  local timeout_seconds="$1"
  local working_directory="$2"
  local log_path="$3"
  shift 3

  ruby -ropen3 -e '
    timeout = Integer(ARGV.shift)
    working_directory = ARGV.shift
    log_path = ARGV.shift
    command = ARGV
    child_pid = nil
    reader = nil

    terminate_group = lambda do
      next unless child_pid
      Process.kill("TERM", -child_pid) rescue nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        break unless Process.kill(0, child_pid) rescue false
        sleep 0.1
      end
      Process.kill("KILL", -child_pid) rescue nil
    end

    Signal.trap("TERM") { terminate_group.call; exit 143 }
    Signal.trap("INT") { terminate_group.call; exit 130 }

    status = nil
    File.open(log_path, "w") do |log|
      Open3.popen2e(*command, chdir: working_directory, pgroup: true) do |stdin, output, wait_thr|
        child_pid = wait_thr.pid
        stdin.close
        reader = Thread.new { IO.copy_stream(output, log) }
        unless wait_thr.join(timeout)
          terminate_group.call
          wait_thr.join(5)
          reader.join(2)
          exit 124
        end
        reader.join
        status = wait_thr.value
      end
    end
    exit(status&.exitstatus || 1)
  ' "$timeout_seconds" "$working_directory" "$log_path" "$@"
}

is_active_repo() {
  local repo_dir="$1"
  local name
  name=$(basename "$repo_dir")

  [ -d "$repo_dir/.git" ] || return 1
  [ -x "$repo_dir/scripts/SaneMaster.rb" ] || return 1
  case "$name" in
    SaneAI|SaneSync|*-clean|*-reconcile-preview-*|*-release-main|*-release-peer|*_codex_*|*-codex-*|*codex_sync*|*codex_test*|*-preview-*|*-worktree-*)
      return 1
      ;;
  esac
  return 0
}

if [ "${MINI_NIGHTLY_LIBRARY_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

acquire_nightly_lock || exit 1
: > "$VERIFY_RESULTS"

cat > "$REPORT" <<EOF
# Mac Mini Nightly Report — $DATE

Generated at $TIMESTAMP

---

EOF

# =============================================================================
# Section 1: Git Sync
# =============================================================================
echo "## Git Sync" >> "$REPORT"
echo "" >> "$REPORT"
echo "| Repo | Status | Dirty | Behind | Ahead |" >> "$REPORT"
echo "|------|--------|-------|--------|-------|" >> "$REPORT"

for repo_dir in "$APPS_DIR"/* "$INFRA_DIR"/*; do
  [ -d "$repo_dir/.git" ] || continue
  repo_name=$(basename "$repo_dir")

  cd "$repo_dir" || continue
  if ! git fetch origin 2>/dev/null; then
    echo "| $repo_name | Fetch failed | - | - | - |" >> "$REPORT"
    continue
  fi

  local_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$local_branch" ]; then
    echo "| $repo_name | Detached HEAD | - | - | - |" >> "$REPORT"
    continue
  fi

  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  behind=$(git rev-list --count HEAD..origin/"$local_branch" 2>/dev/null || echo "?")
  ahead=$(git rev-list --count origin/"$local_branch"..HEAD 2>/dev/null || echo "?")

  if [ "$dirty" != "0" ]; then
    status="Dirty (pull skipped)"
  elif [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
    if git pull --ff-only origin "$local_branch" 2>/dev/null; then
      status="Updated (+$behind commits)"
    else
      status="Pull failed"
    fi
  else
    status="Up to date"
  fi

  echo "| $repo_name | $status | $dirty | $behind | $ahead |" >> "$REPORT"
done

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 2: Canonical bounded verification
# =============================================================================
echo "## Build Results" >> "$REPORT"
echo "" >> "$REPORT"
echo "Build and test are owned by one canonical, bounded SaneMaster verify per active repo." >> "$REPORT"
echo "Per-repo outcomes are listed under Test Results." >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

VERIFY_PASS=0
VERIFY_FAIL=0
VERIFY_SKIP=0

for repo_dir in "$APPS_DIR"/* "$INFRA_DIR"/*; do
  [ -d "$repo_dir/.git" ] || continue
  if ! is_active_repo "$repo_dir"; then
    VERIFY_SKIP=$((VERIFY_SKIP + 1))
    continue
  fi

  rel_path="${repo_dir#$SANE_ROOT/}"
  safe_name=$(printf '%s' "$rel_path" | tr '/ ' '__')
  verify_log="$VERIFY_LOG_DIR/${safe_name}.log"
  verify_start=$(date +%s)
  verify_status=0
  run_bounded_command \
    "$VERIFY_OUTER_TIMEOUT_SECONDS" \
    "$repo_dir" \
    "$verify_log" \
    /usr/bin/env SANEMASTER_VERIFY_TIMEOUT="$VERIFY_TIMEOUT_SECONDS" \
    "$repo_dir/scripts/SaneMaster.rb" verify --timeout "$VERIFY_TIMEOUT_SECONDS" --no-grant-permissions || verify_status=$?
  verify_end=$(date +%s)
  verify_duration=$((verify_end - verify_start))

  if [ "$verify_status" -eq 0 ]; then
    verify_result="PASS"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  elif [ "$verify_status" -eq 124 ]; then
    verify_result="TIMEOUT"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  else
    verify_result="FAIL"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi
  printf '%s\t%s\t%s\t%s\n' "$rel_path" "$verify_result" "$verify_status" "$verify_duration" >> "$VERIFY_RESULTS"
done

echo "## Test Results" >> "$REPORT"
echo "" >> "$REPORT"
if [ ! -s "$VERIFY_RESULTS" ]; then
  echo "**Skipped** — no active repo with an executable scripts/SaneMaster.rb wrapper was found." >> "$REPORT"
else
  while IFS=$'\t' read -r rel_path verify_result verify_status verify_duration; do
    safe_name=$(printf '%s' "$rel_path" | tr '/ ' '__')
    verify_log="$VERIFY_LOG_DIR/${safe_name}.log"
    echo "### $rel_path" >> "$REPORT"
    if [ "$verify_result" = "PASS" ]; then
      echo "**PASS** — canonical verify (${verify_duration}s)" >> "$REPORT"
    elif [ "$verify_result" = "TIMEOUT" ]; then
      echo "**FAIL** — canonical verify exceeded its bounded deadline (${verify_duration}s, exit 124)" >> "$REPORT"
    else
      echo "**FAIL** — canonical verify exited $verify_status (${verify_duration}s)" >> "$REPORT"
    fi
    if [ "$verify_result" != "PASS" ] && [ -s "$verify_log" ]; then
      echo '```' >> "$REPORT"
      tail -30 "$verify_log" >> "$REPORT"
      echo '```' >> "$REPORT"
    fi
    echo "" >> "$REPORT"
  done < "$VERIFY_RESULTS"
fi
echo "**Summary:** $VERIFY_PASS passed, $VERIFY_FAIL failed, $VERIFY_SKIP non-active/unowned checkout(s) skipped" >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 3: Bounded automation-root cleanup
# =============================================================================
echo "## Automation Root Cleanup" >> "$REPORT"
echo "" >> "$REPORT"

AUTOMATION_PREP_SCRIPT="$SCRIPT_DIR/mini-prepare-automation-root.sh"
cleanup_exit=0
cleanup_log="$OUTPUT_DIR/nightly-automation-cleanup.log"

if [ "$SANE_ROOT" = "$CANONICAL_SOURCE_ROOT" ]; then
  echo "**Skipped** - nightly is running against the canonical human repo" >> "$REPORT"
elif [ ! -x "$AUTOMATION_PREP_SCRIPT" ]; then
  echo "**Skipped** - missing automation-root prep script" >> "$REPORT"
else
  run_bounded_command \
    "$CLEANUP_TIMEOUT_SECONDS" \
    "$SCRIPT_DIR" \
    "$cleanup_log" \
    /usr/bin/env AUTOMATION_ROOT="$SANE_ROOT" SANE_SOURCE_ROOT="$CANONICAL_SOURCE_ROOT" \
    /bin/bash "$AUTOMATION_PREP_SCRIPT" || cleanup_exit=$?
  if [ "$cleanup_exit" -eq 0 ]; then
    echo "**PASS** - automation root re-synced and cleaned after nightly work" >> "$REPORT"
  elif [ "$cleanup_exit" -eq 124 ]; then
    echo "**FAIL** - automation root cleanup timed out after ${CLEANUP_TIMEOUT_SECONDS}s" >> "$REPORT"
  else
    echo "**FAIL** (exit $cleanup_exit) - automation root cleanup reported problems" >> "$REPORT"
  fi
  if [ -s "$cleanup_log" ]; then
    echo '```' >> "$REPORT"
    tail -40 "$cleanup_log" >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 4: Disk and system health
# =============================================================================
echo "## System Health" >> "$REPORT"
echo "" >> "$REPORT"

disk_free=$(df -h / | tail -1 | awk '{print $4}')
disk_pct=$(df -h / | tail -1 | awk '{print $5}')
echo "**Disk:** $disk_free free ($disk_pct used)" >> "$REPORT"
memory_state=$(memory_pressure 2>/dev/null | grep "System-wide" | head -1 || echo "Unknown")
echo "**Memory:** $memory_state" >> "$REPORT"
echo "**Uptime:** $(uptime | sed 's/.*up /up /' | sed 's/,.*//')" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 5: Keep pinned MCP/CLI tools current
# =============================================================================
echo "## Keep Current" >> "$REPORT"
echo "" >> "$REPORT"

KEEP_CURRENT_SCRIPT="$CANONICAL_SOURCE_ROOT/infra/SaneProcess/scripts/automation/dependency_baseline.rb"
keep_current_exit=0
keep_current_log="$OUTPUT_DIR/nightly-keep-current.log"

if [ ! -f "$KEEP_CURRENT_SCRIPT" ]; then
  echo "**Skipped** - missing dependency_baseline.rb" >> "$REPORT"
else
  run_bounded_command \
    "$KEEP_CURRENT_TIMEOUT_SECONDS" \
    "$CANONICAL_SOURCE_ROOT/infra/SaneProcess" \
    "$keep_current_log" \
    /opt/homebrew/opt/ruby/bin/ruby "$KEEP_CURRENT_SCRIPT" \
    --apply --npm-only --latest --role mini || keep_current_exit=$?
  if [ "$keep_current_exit" -eq 0 ]; then
    echo "**PASS** - Mini npm pins applied" >> "$REPORT"
  elif [ "$keep_current_exit" -eq 124 ]; then
    echo "**FAIL** - keep-current timed out after ${KEEP_CURRENT_TIMEOUT_SECONDS}s" >> "$REPORT"
  else
    echo "**FAIL** (exit $keep_current_exit) - Mini dependency pins drifted" >> "$REPORT"
  fi
  if [ -s "$keep_current_log" ]; then
    echo '```' >> "$REPORT"
    tail -40 "$keep_current_log" >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 6: Bounded operator brief
# =============================================================================
echo "## Operator Brief" >> "$REPORT"
echo "" >> "$REPORT"

OPERATOR_BRIEF_OUTPUT="$OUTPUT_DIR/operator_brief.md"
operator_brief_exit=0
operator_brief_written=0
operator_brief_log="$OUTPUT_DIR/nightly-operator-brief.log"

if [ ! -f "$SANEMASTER_SCRIPT" ]; then
  echo "**Skipped** - missing SaneMaster operator_brief command at $SANEMASTER_SCRIPT" >> "$REPORT"
else
  run_bounded_command \
    "$OPERATOR_BRIEF_TIMEOUT_SECONDS" \
    "$CANONICAL_SOURCE_ROOT/infra/SaneProcess" \
    "$operator_brief_log" \
    ruby "$SANEMASTER_SCRIPT" operator_brief \
    --nightly-report "$REPORT" \
    --morning-report "$OUTPUT_DIR/morning_report.md" \
    --handoff "$CANONICAL_SOURCE_ROOT/infra/SaneProcess/SESSION_HANDOFF.md" \
    --output "$OPERATOR_BRIEF_TEMP" || operator_brief_exit=$?
  if { [ "$operator_brief_exit" -eq 0 ] || [ "$operator_brief_exit" -eq 1 ]; } && [ -s "$OPERATOR_BRIEF_TEMP" ]; then
    mv "$OPERATOR_BRIEF_TEMP" "$OPERATOR_BRIEF_OUTPUT"
    operator_brief_written=1
  fi
  if [ "$operator_brief_exit" -eq 0 ] && [ "$operator_brief_written" -eq 1 ]; then
    echo "**PASS** - wrote $OPERATOR_BRIEF_OUTPUT" >> "$REPORT"
  elif [ "$operator_brief_exit" -eq 1 ] && [ "$operator_brief_written" -eq 1 ]; then
    echo "**PASS** - wrote $OPERATOR_BRIEF_OUTPUT with priorities requiring attention" >> "$REPORT"
  elif [ "$operator_brief_exit" -eq 124 ]; then
    echo "**FAIL** - operator brief timed out after ${OPERATOR_BRIEF_TIMEOUT_SECONDS}s" >> "$REPORT"
  else
    echo "**FAIL** (exit $operator_brief_exit) - operator brief generation failed" >> "$REPORT"
  fi
  if [ -s "$operator_brief_log" ]; then
    echo '```' >> "$REPORT"
    tail -80 "$operator_brief_log" >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi

cat >> "$REPORT" <<EOF

---

**Report generated:** $TIMESTAMP
**Machine:** $(hostname) ($(sysctl -n hw.ncpu) cores, $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1/1073741824}') RAM)
**Next run:** Tomorrow at 8:45 AM
EOF

echo "Nightly report complete: $REPORT" >&2
