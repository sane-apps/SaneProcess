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

  HOME="$merge_home" "$HOME/mlx-env/bin/python3" "$merge_script"
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
CHALLENGER_SELECTION_MODE="${CHALLENGER_SELECTION_MODE:-all}"
CHALLENGER_ROTATION_ANCHOR_DATE="${CHALLENGER_ROTATION_ANCHOR_DATE:-2026-03-07}"
CHALLENGER_ROTATION_ORDER="${CHALLENGER_ROTATION_ORDER:-smollm3-3b}"
CHALLENGER_ROTATION_DATE="${CHALLENGER_ROTATION_DATE:-$DATE}"
CHALLENGER_SKIP_WEEKDAY="${CHALLENGER_SKIP_WEEKDAY:-}"
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

is_past_hard_stop_time() {
  local hard_stop_hour hard_stop_minute hour_now minute_now

  hard_stop_hour=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f1)
  hard_stop_minute=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f2)
  if ! [[ "$hard_stop_hour" =~ ^[0-9]{1,2}$ ]] || ! [[ "$hard_stop_minute" =~ ^[0-9]{2}$ ]]; then
    hard_stop_hour="08"
    hard_stop_minute="30"
  fi

  hour_now=$(date +%H)
  minute_now=$(date +%M)
  hour_now=$((10#$hour_now))
  minute_now=$((10#$minute_now))
  hard_stop_hour=$((10#$hard_stop_hour))
  hard_stop_minute=$((10#$hard_stop_minute))

  if [ "$hour_now" -gt "$hard_stop_hour" ]; then
    return 0
  fi
  if [ "$hour_now" -eq "$hard_stop_hour" ] && [ "$minute_now" -ge "$hard_stop_minute" ]; then
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
