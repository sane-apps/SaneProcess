#!/bin/bash
# mini-train-all.sh - Train unified SaneAI model + challenger models
# Called by a weekly LaunchAgent or run manually.
#
# Pipeline:
# 1. Merge training data from all products into SaneAI
# 2. Train the production config selected for the Mini (auto-promotes if >90%)
# 3. Run challenger models on the configured app data (report only, never auto-promote)
#
# Architecture (Option B): One unified SaneAI model trained on all product data.
# Per-product behavior comes from system prompts at inference time, not separate models.

DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="${SANE_ROOT:-$DEFAULT_SANE_ROOT}"
SANE_OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SANE_OUTPUT_DIR"
PYTHON="$HOME/mlx-env/bin/python3"
TRAIN_HARD_STOP_TIME="${TRAIN_HARD_STOP_TIME:-08:30}"
RUN_CHALLENGERS_AFTER_WEEKLY="${RUN_CHALLENGERS_AFTER_WEEKLY:-false}"
CHALLENGER_APP="${CHALLENGER_APP:-SaneAI}"
mkdir -p "$LOG_DIR"

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
    echo "=== ERROR: automation prep script missing: $prep_script ===" >> "$STDOUT_LOG"
    return 1
  fi

  echo "=== Refreshing automation root before weekly training: $SANE_ROOT ===" >> "$STDOUT_LOG"
  AUTOMATION_ROOT="$SANE_ROOT" \
  SANE_SOURCE_ROOT="$source_root" \
    /bin/bash "$prep_script" >> "$STDOUT_LOG" 2>&1
}

run_saneai_merge() {
  local merge_script="$1"
  local merge_home merge_exit

  merge_home=$(mktemp -d -t saneai-merge-home)
  ln -s "$SANE_ROOT" "$merge_home/SaneApps"

  echo "=== Merge root: $SANE_ROOT — $(date) ===" >> "$STDOUT_LOG"
  HOME="$merge_home" SANE_ROOT="$SANE_ROOT" "$PYTHON" "$merge_script" >> "$STDOUT_LOG" 2>&1
  merge_exit=$?

  rm -rf "$merge_home"
  return "$merge_exit"
}

# Rotate stderr log if >1MB (LaunchAgent appends, never truncates)
STDOUT_LOG="${TRAIN_STDOUT_LOG:-$LOG_DIR/training.stdout.log}"
STDERR_LOG="${TRAIN_STDERR_LOG:-$LOG_DIR/training.stderr.log}"
if [ -f "$STDERR_LOG" ] && [ "$(stat -f%z "$STDERR_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$STDERR_LOG" "$STDERR_LOG.old"
fi

echo "=== Training SaneAI (unified model) — $(date) ===" >> "$STDOUT_LOG"

if ! prepare_automation_root_if_needed; then
  exit 1
fi

# Step 1: Merge latest per-product training data into SaneAI
SANEAI_DIR="$SANE_ROOT/apps/SaneAI/training_data"
MERGE_EXIT=0
if [ -f "$SANEAI_DIR/merge_training_data.py" ]; then
  run_saneai_merge "$SANEAI_DIR/merge_training_data.py"
  MERGE_EXIT=$?
  echo "=== SaneAI merge complete (exit $MERGE_EXIT) — $(date) ===" >> "$STDOUT_LOG"
  if [ "$MERGE_EXIT" -ne 0 ]; then
    echo "=== Merge failed. Falling back to any existing SaneAI train/valid files. ===" >> "$STDOUT_LOG"
  fi
fi

if [ ! -f "$SANEAI_DIR/train.jsonl" ] || [ ! -f "$SANEAI_DIR/valid.jsonl" ]; then
  echo "=== ERROR: SaneAI training data missing after merge stage — $(date) ===" >> "$STDOUT_LOG"
  exit 1
fi

# Step 2: Train the production model selected by lora_config_mini.yaml
PROD_START=$(date +%s)
SANE_ROOT="$SANE_ROOT" \
SANE_OUTPUT_DIR="$SANE_OUTPUT_DIR" \
  bash "$SCRIPT_DIR/mini-train.sh" SaneAI --config lora_config_mini.yaml
PROD_EXIT=$?
PROD_END=$(date +%s)
PROD_MINUTES=$(( (PROD_END - PROD_START) / 60 ))
echo "=== SaneAI complete (exit $PROD_EXIT, ${PROD_MINUTES}min) — $(date) ===" >> "$STDOUT_LOG"

# Step 3: Optionally run challenger models after SaneAI training.
# Default is off so Sunday belongs entirely to weekly SaneAI training.
hour_now=$(date +%H)
minute_now=$(date +%M)
hour_now=$((10#$hour_now))
minute_now=$((10#$minute_now))
hard_stop_hour=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f1)
hard_stop_minute=$(printf '%s' "$TRAIN_HARD_STOP_TIME" | cut -d: -f2)
if ! [[ "$hard_stop_hour" =~ ^[0-9]{1,2}$ ]] || ! [[ "$hard_stop_minute" =~ ^[0-9]{2}$ ]]; then
  hard_stop_hour="08"
  hard_stop_minute="30"
fi
hard_stop_hour=$((10#$hard_stop_hour))
hard_stop_minute=$((10#$hard_stop_minute))
current_minutes=$((hour_now * 60 + minute_now))
hard_stop_minutes=$((hard_stop_hour * 60 + hard_stop_minute))

if [ "$RUN_CHALLENGERS_AFTER_WEEKLY" != "true" ]; then
  echo "=== Skipping challengers — weekly SaneAI owns the Sunday window ===" >> "$STDOUT_LOG"
elif [ "$PROD_EXIT" -ne 0 ]; then
  echo "=== Skipping challengers — production training failed (exit $PROD_EXIT) ===" >> "$STDOUT_LOG"
elif [ "$current_minutes" -lt "$hard_stop_minutes" ]; then
  minutes_until_stop=$((hard_stop_minutes - current_minutes))
  # Cap at 120 min (don't hog the machine even if lots of time)
  if [ "$minutes_until_stop" -gt 120 ]; then
    minutes_until_stop=120
  fi

  echo "=== Challenger training (budget: ${minutes_until_stop}min, hard stop ${TRAIN_HARD_STOP_TIME}) — $(date) ===" >> "$STDOUT_LOG"

  SANE_ROOT="$SANE_ROOT" \
  SANE_OUTPUT_DIR="$SANE_OUTPUT_DIR" \
  CHALLENGER_BUDGET_MIN="$minutes_until_stop" \
  TRAIN_HARD_STOP_TIME="$TRAIN_HARD_STOP_TIME" \
  CHALLENGER_APP="$CHALLENGER_APP" \
    bash "$SCRIPT_DIR/mini-train-challengers.sh" "$CHALLENGER_APP" \
    >> "$STDOUT_LOG" 2>&1

  CHALLENGER_EXIT=$?
  echo "=== Challengers complete (exit $CHALLENGER_EXIT) — $(date) ===" >> "$STDOUT_LOG"
else
  echo "=== Skipping challengers — past hard stop ${TRAIN_HARD_STOP_TIME} ===" >> "$STDOUT_LOG"
fi

exit $PROD_EXIT
