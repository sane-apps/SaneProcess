#!/bin/bash
# mini-train-challengers.sh - Run challenger model training
# Called by a daily LaunchAgent or by mini-train-all.sh after production training.
#
# Reads challenger configs from $APP_DIR/training_data/challenger_configs/*.yaml
# Runs each through mini-train.sh with --challenger flag.
# Respects time budget — skips remaining challengers if budget exhausted.
# NEVER auto-promotes — generates comparison reports for human review.
#
# Usage: mini-train-challengers.sh [app_name]  (default: SaneAI)

set -uo pipefail

expand_home_path() {
  case "$1" in
    "")
      printf '%s' ""
      ;;
    "~")
      printf '%s' "$HOME"
      ;;
    "~/"*)
      printf '%s' "$HOME/${1#~/}"
      ;;
    '$HOME')
      printf '%s' "$HOME"
      ;;
    '$HOME/'*)
      printf '%s' "$HOME/${1#\$HOME/}"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

run_saneai_merge() {
  local merge_script="$1"
  local merge_home merge_exit

  merge_home=$(mktemp -d -t saneai-merge-home)
  ln -s "$SANE_ROOT" "$merge_home/SaneApps"

  HOME="$merge_home" "${MLX_PYTHON_BIN:-$HOME/mlx-env/bin/python3}" "$merge_script"
  merge_exit=$?

  rm -rf "$merge_home"
  return "$merge_exit"
}

DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="$(expand_home_path "${SANE_ROOT:-$DEFAULT_SANE_ROOT}")"
SANE_OUTPUT_DIR="$(expand_home_path "${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}")"

APP_NAME="${1:-SaneAI}"
APP_DIR="$SANE_ROOT/apps/$APP_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SANE_OUTPUT_DIR"
DATE=$(date +"%Y-%m-%d")
COMPARISON_REPORT="$OUTPUT_DIR/challenger_comparison_${APP_NAME}_${DATE}.md"
mkdir -p "$OUTPUT_DIR"

reap_orphaned_compiler_services() {
  local service_name pids pid ppid rss_kb killed_count failed_count reboot_marker threshold_kb

  if pgrep -f "mlx_lm lora --train" >/dev/null 2>&1 || pgrep -f "mini-train.sh" >/dev/null 2>&1; then
    echo "  Skipping compiler service cleanup because training is still active" >&2
    return 0
  fi

  reboot_marker="$OUTPUT_DIR/.compiler_service_reboot_required"
  threshold_kb="${COMPILER_SERVICE_REBOOT_RSS_KB:-262144}"
  killed_count=0
  failed_count=0
  for service_name in ANECompilerService MTLCompilerService; do
    pids=$(pgrep -x "$service_name" 2>/dev/null || true)
    for pid in $pids; do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$ppid" = "1" ] || continue

      rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{print $1}')
      case "$rss_kb" in
        ''|*[!0-9]*)
          rss_kb=0
          ;;
      esac
      if [ "$rss_kb" -lt "$threshold_kb" ]; then
        echo "  Leaving normal-sized $service_name pid=$pid rss_kb=$rss_kb below threshold_kb=$threshold_kb" >&2
        continue
      fi
      echo "  Reaping orphaned $service_name pid=$pid rss_kb=${rss_kb:-unknown}" >&2
      if kill -TERM "$pid" 2>/dev/null; then
        killed_count=$((killed_count + 1))
      else
        echo "  Unable to reap root-owned $service_name pid=$pid; marking Mini restart required." >&2
        failed_count=$((failed_count + 1))
      fi
    done
  done

  if [ "$failed_count" -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') compiler services require Mini restart" > "$reboot_marker" 2>/dev/null || true
  fi

  [ "$killed_count" -gt 0 ] || return 0
  sleep 1

  for service_name in ANECompilerService MTLCompilerService; do
    pids=$(pgrep -x "$service_name" 2>/dev/null || true)
    for pid in $pids; do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ "$ppid" = "1" ] || continue
      if ! kill -KILL "$pid" 2>/dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') compiler services require Mini restart" > "$reboot_marker" 2>/dev/null || true
      fi
    done
  done
}

prepare_automation_root_if_needed() {
  local prep_script="$SCRIPT_DIR/mini-prepare-automation-root.sh"
  local source_root="${CANONICAL_SOURCE_ROOT:-$HOME/SaneApps}"

  case "$SANE_ROOT" in
    "$HOME/SaneApps-automation"|"${HOME}/SaneApps-automation/"*)
      ;;
    *)
      return 0
      ;;
  esac

  if [ ! -f "$prep_script" ]; then
    echo "Automation prep script missing: $prep_script" >&2
    return 1
  fi

  echo "Refreshing automation root before challenger training: $SANE_ROOT" >&2
  AUTOMATION_ROOT="$SANE_ROOT" \
  SANE_SOURCE_ROOT="$source_root" \
    /bin/bash "$prep_script"
}

# Inherit time budget from environment (set by mini-train-all.sh)
# Default daily lane stays on the last stable 8 GB candidate unless explicitly widened.
CHALLENGER_BUDGET_MIN="${CHALLENGER_BUDGET_MIN:-0}"
TRAIN_HARD_STOP_TIME="${TRAIN_HARD_STOP_TIME:-08:30}"
CHALLENGER_SELECTION_MODE="${CHALLENGER_SELECTION_MODE:-alternate}"
CHALLENGER_ROTATION_ANCHOR_DATE="${CHALLENGER_ROTATION_ANCHOR_DATE:-2026-03-07}"
CHALLENGER_ROTATION_ORDER="${CHALLENGER_ROTATION_ORDER:-smollm3-3b}"
CHALLENGER_ROTATION_DATE="${CHALLENGER_ROTATION_DATE:-$DATE}"
CHALLENGER_SKIP_WEEKDAY="${CHALLENGER_SKIP_WEEKDAY:-}"
ALLOW_MULTI_CHALLENGER_RUNS="${ALLOW_MULTI_CHALLENGER_RUNS:-false}"
CHALLENGER_START=$(date +%s)
SELECTED_CONFIG_NAME=""

CONFIGS_DIR="$APP_DIR/training_data/challenger_configs"
MERGE_STATUS="not-needed"

if ! prepare_automation_root_if_needed; then
  echo "Automation root refresh failed. Aborting challenger lane." >&2
  exit 1
fi

if [ "$APP_NAME" = "SaneAI" ] && [ -f "$APP_DIR/training_data/merge_training_data.py" ]; then
  if run_saneai_merge "$APP_DIR/training_data/merge_training_data.py" >/dev/null 2>&1; then
    MERGE_STATUS="refreshed"
  else
    MERGE_STATUS="failed"
    echo "WARNING: SaneAI merge refresh failed. Continuing with existing unified dataset." >&2
  fi
fi

if [ ! -d "$CONFIGS_DIR" ]; then
  echo "No challenger configs found at $CONFIGS_DIR" >&2
  exit 0
fi

if [ -n "$CHALLENGER_SKIP_WEEKDAY" ] && [ "$(date +%w)" = "$CHALLENGER_SKIP_WEEKDAY" ]; then
  cat > "$COMPARISON_REPORT" <<EOF
# Challenger Model Comparison — $APP_NAME — $DATE

Generated at $(date +"%Y-%m-%d %H:%M:%S")

## Status

- Skipped: weekday $(date +%w)
- Reason: Sunday window reserved for weekly SaneAI training
- Next scheduled lane: Daily challenger agent at 1:00 AM on non-Sundays
EOF
  echo "Skipping challenger lane on weekday $(date +%w); weekly SaneAI owns this window." >&2
  exit 0
fi

select_rotation_config_name() {
  local days_since old_ifs order_count selected_index selected_name

  days_since=$(ruby -e 'require "date"; puts((Date.iso8601(ARGV[1]) - Date.iso8601(ARGV[0])).to_i)' \
    "$CHALLENGER_ROTATION_ANCHOR_DATE" "$CHALLENGER_ROTATION_DATE" 2>/dev/null || echo "")

  if ! [[ "$days_since" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "smollm3-3b"
    return
  fi

  if [ "$days_since" -lt 0 ]; then
    days_since=0
  fi

  old_ifs="$IFS"
  IFS=','
  set -- $CHALLENGER_ROTATION_ORDER
  IFS="$old_ifs"

  order_count=$#
  if [ "$order_count" -eq 0 ]; then
    printf '%s' "smollm3-3b"
    return
  fi

  selected_index=$((days_since % order_count + 1))
  eval "selected_name=\${$selected_index}"
  printf '%s' "$(printf '%s' "$selected_name" | sed 's/^ *//; s/ *$//')"
}

compute_hard_stop_epoch() {
  local hard_stop_hour hard_stop_minute

  hard_stop_hour=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f1)
  hard_stop_minute=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f2)
  if ! [[ "$hard_stop_hour" =~ ^[0-9]{1,2}$ ]] || ! [[ "$hard_stop_minute" =~ ^[0-9]{2}$ ]]; then
    TRAIN_HARD_STOP_TIME="08:30"
  fi

  TRAIN_HARD_STOP_EPOCH=$(ruby -e '
    require "time"

    start_epoch = Integer(ARGV[0])
    raw_time = ARGV[1].to_s
    unless raw_time.match?(/\A\d{1,2}:\d{2}\z/)
      puts 0
      exit
    end

    hour, minute = raw_time.split(":").map(&:to_i)
    unless hour.between?(0, 23) && minute.between?(0, 59)
      puts 0
      exit
    end

    start = Time.at(start_epoch)
    target = Time.local(start.year, start.month, start.day, hour, minute, 0)
    target += 86_400 if target <= start
    puts target.to_i
  ' "$CHALLENGER_START" "$TRAIN_HARD_STOP_TIME" 2>/dev/null || echo "0")
}

compute_hard_stop_epoch

is_past_hard_stop_time() {
  local now

  if ! [[ "${TRAIN_HARD_STOP_EPOCH:-0}" =~ ^[0-9]+$ ]] || [ "${TRAIN_HARD_STOP_EPOCH:-0}" -le 0 ]; then
    echo "Invalid hard stop epoch; treating hard stop as reached." >&2
    return 0
  fi

  now=$(date +%s)
  if [ "$now" -ge "$TRAIN_HARD_STOP_EPOCH" ]; then
    return 0
  fi
  return 1
}

CONFIG_LIST_ALL=$(mktemp)
find "$CONFIGS_DIR" \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort > "$CONFIG_LIST_ALL"
CONFIG_LIST_SELECTED="$CONFIG_LIST_ALL"

if [ "$CHALLENGER_SELECTION_MODE" = "alternate" ]; then
  SELECTED_CONFIG_NAME=$(select_rotation_config_name)
  CONFIG_LIST_SELECTED=$(mktemp)
  while read -r config_file; do
    [ -n "$config_file" ] || continue
    config_name=$(basename "$config_file")
    config_name="${config_name%.yaml}"
    config_name="${config_name%.yml}"
    if [ "$config_name" = "$SELECTED_CONFIG_NAME" ]; then
      echo "$config_file" >> "$CONFIG_LIST_SELECTED"
    fi
  done < "$CONFIG_LIST_ALL"
fi

CONFIG_FILES=$(cat "$CONFIG_LIST_SELECTED")

if [ -z "$CONFIG_FILES" ]; then
  rm -f "$CONFIG_LIST_ALL" "$CONFIG_LIST_SELECTED"
  echo "No challenger config files in $CONFIGS_DIR" >&2
  exit 0
fi

if [ "$CHALLENGER_SELECTION_MODE" = "all" ] && [ "$ALLOW_MULTI_CHALLENGER_RUNS" != "true" ]; then
  CONFIG_COUNT=$(printf '%s\n' "$CONFIG_FILES" | awk 'NF {count++} END {print count+0}')
  if [ "$CONFIG_COUNT" -gt 1 ]; then
    rm -f "$CONFIG_LIST_ALL" "$CONFIG_LIST_SELECTED"
    echo "Refusing to run ${CONFIG_COUNT} challenger configs in one lane. Set ALLOW_MULTI_CHALLENGER_RUNS=true for an explicit bakeoff." >&2
    exit 1
  fi
fi

# Count challengers
TOTAL_CHALLENGERS=$(echo "$CONFIG_FILES" | wc -l | tr -d ' ')
echo "Found $TOTAL_CHALLENGERS challenger config(s) in $CONFIGS_DIR" >&2

# Start comparison report
cat > "$COMPARISON_REPORT" <<EOF
# Challenger Model Comparison — $APP_NAME — $DATE

Generated at $(date +"%Y-%m-%d %H:%M:%S")
Budget: $([ "$CHALLENGER_BUDGET_MIN" -gt 0 ] && printf '%s minutes' "$CHALLENGER_BUDGET_MIN" || printf 'until hard stop'), hard stop at ${TRAIN_HARD_STOP_TIME}

## Production Baseline
EOF

if [ "$MERGE_STATUS" = "refreshed" ]; then
  echo "- Unified SaneAI dataset: refreshed from current app corpora before challenger training" >> "$COMPARISON_REPORT"
elif [ "$MERGE_STATUS" = "failed" ]; then
  echo "- Unified SaneAI dataset: merge refresh failed, using the existing merged files" >> "$COMPARISON_REPORT"
fi

# Read production accuracy from today's training report (if available)
PROD_REPORT="$OUTPUT_DIR/training_report_${APP_NAME}.md"
if [ -f "$PROD_REPORT" ]; then
  PROD_BEST=$(grep "Best adapter:" "$PROD_REPORT" 2>/dev/null | grep -oE '[0-9]+%' | head -1)
  if [ -n "$PROD_BEST" ]; then
    echo "- **Production baseline ($APP_NAME):** $PROD_BEST" >> "$COMPARISON_REPORT"
  else
    echo "- **Production baseline ($APP_NAME):** (no result today)" >> "$COMPARISON_REPORT"
  fi
else
  echo "- **Production baseline ($APP_NAME):** (no training report today)" >> "$COMPARISON_REPORT"
fi

echo "" >> "$COMPARISON_REPORT"
echo "## Challenger Results" >> "$COMPARISON_REPORT"
echo "" >> "$COMPARISON_REPORT"
if [ "$CHALLENGER_SELECTION_MODE" = "alternate" ]; then
  echo "- **Selection mode:** scheduled nightly challenger lane" >> "$COMPARISON_REPORT"
  echo "- **Rotation order:** $CHALLENGER_ROTATION_ORDER" >> "$COMPARISON_REPORT"
  echo "- **Rotation anchor:** $CHALLENGER_ROTATION_ANCHOR_DATE" >> "$COMPARISON_REPORT"
  echo "- **Effective date:** $CHALLENGER_ROTATION_DATE" >> "$COMPARISON_REPORT"
  echo "- **Scheduled model tonight:** $SELECTED_CONFIG_NAME" >> "$COMPARISON_REPORT"
  echo "" >> "$COMPARISON_REPORT"
fi
echo "| Model | Config | Accuracy | Time (min) | Status |" >> "$COMPARISON_REPORT"
echo "|-------|--------|----------|------------|--------|" >> "$COMPARISON_REPORT"

CHALLENGERS_RUN=0
CHALLENGERS_SKIPPED=0

# Write config list to temp file so we can use redirect instead of pipe
# (pipe creates subshell on bash 3.2, losing counter variables)
RUN_CONFIG_LIST_TMP=$(mktemp)
echo "$CONFIG_FILES" > "$RUN_CONFIG_LIST_TMP"

# Run each challenger
while read -r config_file; do
  remaining="until ${TRAIN_HARD_STOP_TIME}"
  if [ "$CHALLENGER_BUDGET_MIN" -gt 0 ]; then
    now=$(date +%s)
    elapsed=$(( (now - CHALLENGER_START) / 60 ))
    remaining=$((CHALLENGER_BUDGET_MIN - elapsed))

    if [ "$remaining" -le 5 ]; then
      echo "Time budget nearly exhausted ($elapsed min used). Skipping remaining challengers." >&2
      config_name=$(basename "$config_file" .yaml)
      echo "| $(basename "$config_file") | $config_name | — | — | SKIPPED (time) |" >> "$COMPARISON_REPORT"
      CHALLENGERS_SKIPPED=$((CHALLENGERS_SKIPPED + 1))
      continue
    fi
  fi

  if is_past_hard_stop_time; then
    echo "Past hard stop time (${TRAIN_HARD_STOP_TIME}). Skipping remaining challengers." >&2
    config_name=$(basename "$config_file" .yaml)
    echo "| $(basename "$config_file") | $config_name | — | — | SKIPPED (hard stop) |" >> "$COMPARISON_REPORT"
    CHALLENGERS_SKIPPED=$((CHALLENGERS_SKIPPED + 1))
    continue
  fi

  # Extract model ID from config
  model_id=$(grep '^model:' "$config_file" | sed 's/model:[[:space:]]*//' | tr -d '"' | tr -d "'")
  config_name=$(basename "$config_file" .yaml)

  if [ -z "$model_id" ]; then
    echo "WARNING: No model: line in $config_file, skipping" >&2
    echo "| $config_name | — | — | — | SKIPPED (no model) |" >> "$COMPARISON_REPORT"
    continue
  fi

  echo "--- Running challenger: $config_name ($model_id) ---" >&2
  echo "    Time remaining: $remaining" >&2

  CHALLENGER_RUN_START=$(date +%s)

  # Run mini-train.sh with challenger flags
  if [ "$CHALLENGER_BUDGET_MIN" -gt 0 ]; then
    SANE_ROOT="$SANE_ROOT" \
    SANE_OUTPUT_DIR="$SANE_OUTPUT_DIR" \
    MAX_TRAIN_RUNTIME_MIN="$remaining" \
    TRAIN_HARD_STOP_TIME="$TRAIN_HARD_STOP_TIME" \
      bash "$SCRIPT_DIR/mini-train.sh" "$APP_NAME" \
        --model "$model_id" \
        --config "$config_file" \
        --challenger
  else
    SANE_ROOT="$SANE_ROOT" \
    SANE_OUTPUT_DIR="$SANE_OUTPUT_DIR" \
    TRAIN_HARD_STOP_TIME="$TRAIN_HARD_STOP_TIME" \
      bash "$SCRIPT_DIR/mini-train.sh" "$APP_NAME" \
        --model "$model_id" \
        --config "$config_file" \
        --challenger
  fi

  CHALLENGER_EXIT=$?
  CHALLENGER_RUN_END=$(date +%s)
  CHALLENGER_TIME=$(( (CHALLENGER_RUN_END - CHALLENGER_RUN_START) / 60 ))

  # Extract accuracy from challenger's individual report
  model_short=$(echo "$model_id" | sed 's|.*/||' | sed 's/-MLX-4bit//' | sed 's/-4bit//' | tr '[:upper:]' '[:lower:]')
  challenger_report="$OUTPUT_DIR/challenger_report_${APP_NAME}_${model_short}.md"

  if [ -f "$challenger_report" ]; then
    accuracy=$(grep -E "CHALLENGER RESULT:" "$challenger_report" | grep -oE '[0-9]+%' | head -1)
    if [ -z "$accuracy" ]; then
      accuracy=$(grep "Best adapter:" "$challenger_report" | grep -oE '[0-9]+%' | head -1)
    fi
    workflow_gate=$(grep "Workflow gate:" "$challenger_report" | grep -oE 'PASS|FAIL' | head -1)
  else
    accuracy=""
    workflow_gate=""
  fi

  if [ -z "$accuracy" ]; then
    accuracy="N/A"
    status="FAILED"
  elif [ "$workflow_gate" = "FAIL" ]; then
    status="Workflow gate failed"
  elif echo "$accuracy" | grep -qE '^[0-9]+'; then
    acc_num=$(echo "$accuracy" | tr -d '%')
    if [ "$acc_num" -ge 85 ]; then
      status="Strong"
    elif [ "$acc_num" -ge 60 ]; then
      status="Promising"
    else
      status="Below target"
    fi
  else
    status="Unknown"
  fi

  echo "| $model_id | $config_name | $accuracy | $CHALLENGER_TIME | $status |" >> "$COMPARISON_REPORT"
  CHALLENGERS_RUN=$((CHALLENGERS_RUN + 1))

  echo "    Result: $accuracy ($status) in ${CHALLENGER_TIME}min" >&2
done < "$RUN_CONFIG_LIST_TMP"
rm -f "$CONFIG_LIST_ALL" "$CONFIG_LIST_SELECTED" "$RUN_CONFIG_LIST_TMP"

# =============================================================================
# Post-training cleanup — free GPU/memory so Mini isn't fried during daytime
# =============================================================================
echo "--- Post-training cleanup ---" >&2

# Kill any lingering mlx/Python training processes (stale from killed sweeps)
for pid in $(pgrep -f "mlx_lm" 2>/dev/null); do
  # Only kill processes older than 2 minutes (avoid killing fresh ones)
  if [ -d "/proc/$pid" ] 2>/dev/null || ps -p "$pid" > /dev/null 2>&1; then
    kill "$pid" 2>/dev/null
    echo "  Killed lingering mlx_lm process $pid" >&2
  fi
done

reap_orphaned_compiler_services

# Purge memory cache (macOS-specific, frees inactive pages)
if command -v purge > /dev/null 2>&1; then
  purge 2>/dev/null
  echo "  Memory cache purged" >&2
fi

# Log system stats for the report
DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
MEM_PRESSURE=$(memory_pressure 2>/dev/null | grep "System-wide" | head -1 || echo "unknown")
echo "  Disk free: $DISK_FREE" >&2
echo "  Memory: $MEM_PRESSURE" >&2

echo "" >&2

# Footer
cat >> "$COMPARISON_REPORT" <<EOF

---

**Challengers run:** $CHALLENGERS_RUN of $TOTAL_CHALLENGERS
**Report:** $COMPARISON_REPORT
**Next scheduled lane:** Daily challenger agent at 1:00 AM, nightly builds at 8:45 AM

> Challengers NEVER auto-promote. If a model beats Llama, review the report and manually promote.
EOF

echo "" >&2
echo "Challenger comparison report: $COMPARISON_REPORT" >&2
