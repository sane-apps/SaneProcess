#!/bin/bash
# mini-nightly.sh - Nightly automation for Mac mini build server
# Runs at 8:45 AM daily via LaunchAgent
# Results available via: ssh mini cat ~/SaneApps/outputs/nightly_report.md

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
EVAL_SUITE_WEIGHTS="${EVAL_SUITE_WEIGHTS:-mac_operator=4,core=2,workflow_guardrails=1,commentary_workflow=1,workflow_packs=1}"
PRIMARY_WORKFLOW_SUITE="${PRIMARY_WORKFLOW_SUITE:-mac_operator}"
PRIMARY_WORKFLOW_MIN_PCT="${PRIMARY_WORKFLOW_MIN_PCT:-50}"
RUN_SANEAI_WORKFLOW_READINESS="${RUN_SANEAI_WORKFLOW_READINESS:-0}"

mkdir -p "$OUTPUT_DIR"

# Lock file (with stale lock detection)
LOCKFILE="$OUTPUT_DIR/.nightly.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  # Check if lock is stale (older than 2 hours)
  if [ -d "$LOCKFILE" ] && [ "$(find "$LOCKFILE" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    echo "Removing stale lock (>2 hours old)" >&2
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE" 2>/dev/null || { echo "Cannot acquire lock" >&2; exit 1; }
  else
    echo "Another nightly instance is running" >&2
    exit 1
  fi
fi
trap 'rm -rf "$LOCKFILE"' EXIT

cat > "$REPORT" <<EOF
# Mac Mini Nightly Report — $DATE

Generated at $TIMESTAMP

---

EOF

# =============================================================================
# Section 1: Git Pull All Repos
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
# Section 2: Build All Apps
# =============================================================================
echo "## Build Results" >> "$REPORT"
echo "" >> "$REPORT"

BUILD_PASS=0
BUILD_FAIL=0

for app_dir in "$APPS_DIR"/Sane*; do
  [ -d "$app_dir" ] || continue
  app_name=$(basename "$app_dir")

  cd "$app_dir" || continue

  # Find xcodeproj or Package.swift
  SCHEME=""
  BUILD_TYPE=""

  if ls *.xcodeproj 1>/dev/null 2>&1; then
    proj=$(ls -d *.xcodeproj | head -1)
    # Prefer workspace over project (resolves local Swift packages)
    ws=""
    if ls *.xcworkspace 1>/dev/null 2>&1; then
      ws=$(ls -d *.xcworkspace | head -1)
      ALL_SCHEMES=$(xcodebuild -workspace "$ws" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && /^[[:space:]]+/{print; next} found{exit}' | xargs -I{} echo {})
    else
      ALL_SCHEMES=$(xcodebuild -project "$proj" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && /^[[:space:]]+/{print; next} found{exit}' | xargs -I{} echo {})
    fi
    SCHEME=$(echo "$ALL_SCHEMES" | grep -x "$app_name" | head -1)
    [ -z "$SCHEME" ] && SCHEME=$(echo "$ALL_SCHEMES" | head -1)
    if [ -n "$SCHEME" ]; then
      BUILD_TYPE="xcode"
    fi
  elif [ -f "Package.swift" ]; then
    BUILD_TYPE="spm"
  fi

  if [ -z "$BUILD_TYPE" ]; then
    echo "### $app_name" >> "$REPORT"
    echo "**Skipped** — no project or package found" >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  echo "### $app_name" >> "$REPORT"

  # Clean stale Runner.app bundles — macOS 26 protects registered .app bundles,
  # causing EPERM when the linker tries to overwrite them on subsequent builds
  for runner in ~/Library/Developer/Xcode/DerivedData/"${app_name}"-*/Build/Products/Debug/*-Runner.app; do
    [ -e "$runner" ] && rm -rf "$runner"
  done

  build_start=$(date +%s)
  if [ "$BUILD_TYPE" = "xcode" ]; then
    BUILD_TARGET_FLAG="-project $proj"
    [ -n "$ws" ] && BUILD_TARGET_FLAG="-workspace $ws"
    build_output=$(xcodebuild $BUILD_TARGET_FLAG -scheme "$SCHEME" -configuration Debug build -quiet -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1)
  else
    build_output=$(swift build 2>&1)
  fi
  build_exit=$?
  build_end=$(date +%s)
  build_time=$((build_end - build_start))

  if [ $build_exit -eq 0 ]; then
    echo "**PASS** (${build_time}s)" >> "$REPORT"
    BUILD_PASS=$((BUILD_PASS + 1))
  else
    echo "**FAIL** (exit $build_exit, ${build_time}s)" >> "$REPORT"
    echo '```' >> "$REPORT"
    echo "$build_output" | tail -20 >> "$REPORT"
    echo '```' >> "$REPORT"
    BUILD_FAIL=$((BUILD_FAIL + 1))
  fi
  echo "" >> "$REPORT"
done

echo "**Summary:** $BUILD_PASS passed, $BUILD_FAIL failed" >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 3: Run Tests
# =============================================================================
echo "## Test Results" >> "$REPORT"
echo "" >> "$REPORT"

TEST_PASS=0
TEST_FAIL=0

for app_dir in "$APPS_DIR"/Sane*; do
  [ -d "$app_dir" ] || continue
  app_name=$(basename "$app_dir")

  cd "$app_dir" || continue

  # Check if tests exist — prefer SPM package tests (reliable on headless Mini)
  TEST_TYPE=""
  SPM_PKG_DIR=""
  # Check for local SPM packages with tests (e.g. SaneHostsPackage/Tests/)
  for pkg_dir in "${app_name}Package" "Package"; do
    if [ -f "$pkg_dir/Package.swift" ] && [ -d "$pkg_dir/Tests" ]; then
      SPM_PKG_DIR="$pkg_dir"
      TEST_TYPE="spm_local"
      break
    fi
  done
  # Fall back to xcodeproj tests (skip UI tests on headless Mini)
  if [ -z "$TEST_TYPE" ] && ls *.xcodeproj 1>/dev/null 2>&1; then
    proj=$(ls -d *.xcodeproj | head -1)
    ws=""
    if ls *.xcworkspace 1>/dev/null 2>&1; then
      ws=$(ls -d *.xcworkspace | head -1)
      ALL_SCHEMES=$(xcodebuild -workspace "$ws" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && /^[[:space:]]+/{print; next} found{exit}' | xargs -I{} echo {})
    else
      ALL_SCHEMES=$(xcodebuild -project "$proj" -list 2>/dev/null | awk '/Schemes:/{found=1; next} found && /^[[:space:]]+/{print; next} found{exit}' | xargs -I{} echo {})
    fi
    SCHEME=$(echo "$ALL_SCHEMES" | grep -x "$app_name" | head -1)
    [ -z "$SCHEME" ] && SCHEME=$(echo "$ALL_SCHEMES" | head -1)
    if [ -n "$SCHEME" ]; then
      TEST_TYPE="xcode"
    fi
  elif [ -z "$TEST_TYPE" ] && [ -f "Package.swift" ]; then
    TEST_TYPE="spm"
  fi

  if [ -z "$TEST_TYPE" ]; then continue; fi

  echo "### $app_name" >> "$REPORT"

  if [ "$TEST_TYPE" = "spm_local" ]; then
    # Run swift test in local SPM package directory (reliable on headless Mini)
    test_output=$(cd "$SPM_PKG_DIR" && swift test 2>&1)
  elif [ "$TEST_TYPE" = "xcode" ]; then
    TEST_TARGET_FLAG="-project $proj"
    [ -n "$ws" ] && TEST_TARGET_FLAG="-workspace $ws"
    # Skip UI tests on headless Mini — they require a GUI and hang indefinitely
    SKIP_FLAGS=""
    for ui_target in $(echo "$ALL_SCHEMES" | grep -i "UITest"); do
      SKIP_FLAGS="$SKIP_FLAGS -skip-testing:${ui_target}"
    done
    test_output=$(xcodebuild $TEST_TARGET_FLAG -scheme "$SCHEME" test $SKIP_FLAGS -quiet -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1)
  else
    test_output=$(swift test 2>&1)
  fi
  test_exit=$?

  if [ $test_exit -eq 0 ]; then
    # Extract test count if available
    test_count=$(echo "$test_output" | grep -oE '[0-9]+ test[s]? passed' | head -1)
    echo "**PASS** ${test_count:-""}" >> "$REPORT"
    TEST_PASS=$((TEST_PASS + 1))
  else
    echo "**FAIL** (exit $test_exit)" >> "$REPORT"
    echo '```' >> "$REPORT"
    echo "$test_output" | grep -E "(FAIL|error:|fatal)" | tail -10 >> "$REPORT"
    echo '```' >> "$REPORT"
    TEST_FAIL=$((TEST_FAIL + 1))
  fi
  echo "" >> "$REPORT"
done

echo "**Summary:** $TEST_PASS passed, $TEST_FAIL failed" >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 4: SaneAI Workflow Readiness
# =============================================================================
echo "## SaneAI Workflow Readiness" >> "$REPORT"
echo "" >> "$REPORT"

EVAL_SCRIPT="$SCRIPT_DIR/evaluate_model.py"
SANEAI_DIR="$APPS_DIR/SaneAI"
SANEAI_TRAIN_DIR="$SANEAI_DIR/training_data"
SANEAI_ADAPTER="$SANEAI_DIR/models/production_adapter"
PYTHON="$HOME/mlx-env/bin/python3"
SANEAI_MODEL=""

if [ "$RUN_SANEAI_WORKFLOW_READINESS" != "1" ]; then
  echo "**Skipped** - SaneAI training/readiness lane disabled by default; set RUN_SANEAI_WORKFLOW_READINESS=1 to re-enable." >> "$REPORT"
fi

if [ "$RUN_SANEAI_WORKFLOW_READINESS" = "1" ] && [ -f "$SANEAI_ADAPTER/adapter_config.json" ]; then
  SANEAI_MODEL=$("$PYTHON" - <<'PY' "$SANEAI_ADAPTER/adapter_config.json"
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
print(payload.get("model", ""))
PY
)
fi

if [ -z "$SANEAI_MODEL" ]; then
  SANEAI_MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit"
fi

if [ "$RUN_SANEAI_WORKFLOW_READINESS" = "1" ] && [ -f "$EVAL_SCRIPT" ] && [ -d "$SANEAI_ADAPTER" ] && [ -f "$SANEAI_TRAIN_DIR/train.jsonl" ]; then
  EVAL_CMD=(
    "$PYTHON"
    "$EVAL_SCRIPT"
    --model "$SANEAI_MODEL"
    --adapter-path "$SANEAI_ADAPTER"
    --train-file "$SANEAI_TRAIN_DIR/train.jsonl"
    --system-prompt-file "$SANEAI_TRAIN_DIR/system_prompt.txt"
    --eval-glob "$SANEAI_TRAIN_DIR/eval_*.jsonl"
    --primary-suite "$PRIMARY_WORKFLOW_SUITE"
    --primary-min-pct "$PRIMARY_WORKFLOW_MIN_PCT"
  )
  old_ifs="$IFS"
  IFS=','
  for suite_weight in $EVAL_SUITE_WEIGHTS; do
    suite_weight=$(printf '%s' "$suite_weight" | sed 's/^ *//; s/ *$//')
    if [ -n "$suite_weight" ]; then
      EVAL_CMD=("${EVAL_CMD[@]}" --suite-weight "$suite_weight")
    fi
  done
  IFS="$old_ifs"

  eval_output=$("${EVAL_CMD[@]}" 2>&1)
  eval_exit=$?

  if [ "$eval_exit" -eq 0 ] && [ -n "$eval_output" ]; then
    echo "- Scoring weights: $EVAL_SUITE_WEIGHTS" >> "$REPORT"
    echo "- Primary suite gate: ${PRIMARY_WORKFLOW_SUITE} >= ${PRIMARY_WORKFLOW_MIN_PCT}%" >> "$REPORT"
    echo "" >> "$REPORT"
    echo "$eval_output" | grep -vE "^(SCORE:|RAW_SCORE:|WEIGHTED_SCORE:|PRIMARY_SUITE:|SUITE:)" >> "$REPORT"
    echo "" >> "$REPORT"

    suite_lines=$(echo "$eval_output" | grep "^SUITE:" || true)
    if [ -n "$suite_lines" ]; then
      echo "Suite scores:" >> "$REPORT"
      while IFS=: read -r _ suite_name suite_pass suite_total suite_pct; do
        display_suite=$(echo "$suite_name" | tr '_' ' ')
        echo "- $display_suite: $suite_pass/$suite_total ($suite_pct%)" >> "$REPORT"
      done <<EOF
$suite_lines
EOF
      echo "" >> "$REPORT"
    fi

    raw_score_line=$(echo "$eval_output" | grep "^RAW_SCORE:" | head -1 || true)
    weighted_score_line=$(echo "$eval_output" | grep "^WEIGHTED_SCORE:" | head -1 || true)
    primary_suite_line=$(echo "$eval_output" | grep "^PRIMARY_SUITE:" | head -1 || true)

    if [ -n "$primary_suite_line" ]; then
      primary_suite_name=$(echo "$primary_suite_line" | cut -d: -f2)
      primary_pass=$(echo "$primary_suite_line" | cut -d: -f3)
      primary_total=$(echo "$primary_suite_line" | cut -d: -f4)
      primary_pct=$(echo "$primary_suite_line" | cut -d: -f5)
      primary_threshold=$(echo "$primary_suite_line" | cut -d: -f6)
      primary_status=$(echo "$primary_suite_line" | cut -d: -f7)
      echo "**Workflow gate:** $primary_status ($primary_suite_name $primary_pass/$primary_total, $primary_pct%, threshold $primary_threshold%)" >> "$REPORT"
    fi

    if [ -n "$weighted_score_line" ]; then
      eval_pass=$(echo "$weighted_score_line" | cut -d: -f2)
      eval_total=$(echo "$weighted_score_line" | cut -d: -f3)
      eval_pct=$(echo "$weighted_score_line" | cut -d: -f4)
      echo "**Workflow-first score:** $eval_pass/$eval_total ($eval_pct%)" >> "$REPORT"
    fi

    if [ -n "$raw_score_line" ]; then
      raw_pass=$(echo "$raw_score_line" | cut -d: -f2)
      raw_total=$(echo "$raw_score_line" | cut -d: -f3)
      raw_pct=$(echo "$raw_score_line" | cut -d: -f4)
      echo "**Raw score:** $raw_pass/$raw_total ($raw_pct%)" >> "$REPORT"
    fi
  else
    echo "**Skipped** - workflow readiness eval failed (exit $eval_exit)" >> "$REPORT"
    echo '```' >> "$REPORT"
    echo "$eval_output" | tail -20 >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
elif [ "$RUN_SANEAI_WORKFLOW_READINESS" = "1" ]; then
  echo "**Skipped** - missing evaluator, training data, or production adapter" >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 5: Active Training Alerts
# =============================================================================
echo "## Active Training Alerts" >> "$REPORT"
echo "" >> "$REPORT"

TRAIN_ALERT_DIR="$OUTPUT_DIR/alerts/training/current"
if ls "$TRAIN_ALERT_DIR"/*.md 1>/dev/null 2>&1; then
  for alert_file in "$TRAIN_ALERT_DIR"/*.md; do
    echo "### $(basename "$alert_file" .md)" >> "$REPORT"
    sed -n '1,120p' "$alert_file" >> "$REPORT"
    echo "" >> "$REPORT"
  done
else
  echo "None." >> "$REPORT"
  echo "" >> "$REPORT"
fi

echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 6: Automation Root Cleanup
# =============================================================================
echo "## Automation Root Cleanup" >> "$REPORT"
echo "" >> "$REPORT"

AUTOMATION_PREP_SCRIPT="$SCRIPT_DIR/mini-prepare-automation-root.sh"
CANONICAL_SOURCE_ROOT="$HOME/SaneApps"
cleanup_exit=0
cleanup_output=""

if [ "$SANE_ROOT" = "$CANONICAL_SOURCE_ROOT" ]; then
  echo "**Skipped** - nightly is running against the canonical human repo" >> "$REPORT"
elif [ ! -x "$AUTOMATION_PREP_SCRIPT" ]; then
  echo "**Skipped** - missing automation-root prep script" >> "$REPORT"
else
  cleanup_output=$(AUTOMATION_ROOT="$SANE_ROOT" SANE_SOURCE_ROOT="$CANONICAL_SOURCE_ROOT" /bin/bash "$AUTOMATION_PREP_SCRIPT" 2>&1) || cleanup_exit=$?
  if [ "$cleanup_exit" -eq 0 ]; then
    echo "**PASS** - automation root re-synced and cleaned after nightly work" >> "$REPORT"
  else
    echo "**FAIL** (exit $cleanup_exit) - automation root cleanup reported problems" >> "$REPORT"
  fi

  if [ -n "$cleanup_output" ]; then
    echo '```' >> "$REPORT"
    echo "$cleanup_output" | tail -40 >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 7: Machine Cleanup
# =============================================================================
echo "## Machine Cleanup" >> "$REPORT"
echo "" >> "$REPORT"

MACHINE_CLEANUP_SCRIPT="$CANONICAL_SOURCE_ROOT/infra/SaneProcess/scripts/SaneMaster.rb"
machine_cleanup_exit=0
machine_cleanup_output=""

if [ ! -f "$MACHINE_CLEANUP_SCRIPT" ]; then
  echo "**Skipped** - missing SaneMaster machine cleanup command" >> "$REPORT"
else
  machine_cleanup_output=$(ruby "$MACHINE_CLEANUP_SCRIPT" machine_cleanup --host local --server --apply --quiet --min-free-gb 30 --cache-threshold-gb 5 --deriveddata-age-days 2 --preserve-apps SaneVideo,SaneScan 2>&1) || machine_cleanup_exit=$?
  if [ "$machine_cleanup_exit" -eq 0 ]; then
    echo "**PASS** - server-mode cleanup checked disposable caches, full Trash, simulators, DerivedData, routed workspaces, release staging, and generated repo artifacts" >> "$REPORT"
  else
    echo "**FAIL** (exit $machine_cleanup_exit) - machine cleanup reported problems" >> "$REPORT"
  fi

  if [ -n "$machine_cleanup_output" ]; then
    echo '```' >> "$REPORT"
    echo "$machine_cleanup_output" | tail -60 >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 8: Disk & System Health
# =============================================================================
echo "## System Health" >> "$REPORT"
echo "" >> "$REPORT"

disk_free=$(df -h / | tail -1 | awk '{print $4}')
disk_pct=$(df -h / | tail -1 | awk '{print $5}')
echo "**Disk:** $disk_free free ($disk_pct used)" >> "$REPORT"

# Memory pressure
memory_pressure=$(memory_pressure 2>/dev/null | grep "System-wide" | head -1 || echo "Unknown")
echo "**Memory:** $memory_pressure" >> "$REPORT"

# Uptime
echo "**Uptime:** $(uptime | sed 's/.*up /up /' | sed 's/,.*//')" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Section 9: Operator Brief
# =============================================================================
echo "## Operator Brief" >> "$REPORT"
echo "" >> "$REPORT"

OPERATOR_BRIEF_OUTPUT="$OUTPUT_DIR/operator_brief.md"
operator_brief_exit=0
operator_brief_stdout=""

if [ ! -f "$MACHINE_CLEANUP_SCRIPT" ]; then
  echo "**Skipped** - missing SaneMaster operator_brief command" >> "$REPORT"
else
  operator_brief_stdout=$(ruby "$MACHINE_CLEANUP_SCRIPT" operator_brief --nightly-report "$REPORT" --morning-report "$OUTPUT_DIR/morning_report.md" --handoff "$CANONICAL_SOURCE_ROOT/infra/SaneProcess/SESSION_HANDOFF.md" --output "$OPERATOR_BRIEF_OUTPUT" 2>&1) || operator_brief_exit=$?
  if [ "$operator_brief_exit" -eq 0 ]; then
    echo "**PASS** - wrote $OPERATOR_BRIEF_OUTPUT" >> "$REPORT"
  else
    echo "**FAIL** (exit $operator_brief_exit) - operator brief generation failed" >> "$REPORT"
  fi

  if [ -n "$operator_brief_stdout" ]; then
    echo '```' >> "$REPORT"
    echo "$operator_brief_stdout" | tail -80 >> "$REPORT"
    echo '```' >> "$REPORT"
  fi
fi

echo "" >> "$REPORT"

# =============================================================================
# Footer
# =============================================================================
cat >> "$REPORT" <<EOF

---

**Report generated:** $TIMESTAMP
**Machine:** $(hostname) ($(sysctl -n hw.ncpu) cores, $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1/1073741824}') RAM)
**Next run:** Tomorrow at 8:45 AM
EOF

echo "Nightly report complete: $REPORT" >&2
