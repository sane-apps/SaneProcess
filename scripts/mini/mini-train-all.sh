#!/bin/bash
# mini-train-all.sh - Train unified SaneAI model + challenger models
# Called by LaunchAgent at 3 AM daily
#
# Pipeline:
# 1. Merge training data from all products into SaneAI
# 2. Train production Llama model (auto-promotes if >90%)
# 3. Run challenger models on SaneSync data (report only, never auto-promote)
#
# Architecture (Option B): One unified SaneAI model trained on all product data.
# Per-product behavior comes from system prompts at inference time, not separate models.

SCRIPT_DIR="$(dirname "$0")"
LOG_DIR="$HOME/SaneApps/outputs"
PYTHON="$HOME/mlx-env/bin/python3"
mkdir -p "$LOG_DIR"

# Rotate stderr log if >1MB (LaunchAgent appends, never truncates)
STDERR_LOG="$LOG_DIR/training.stderr.log"
if [ -f "$STDERR_LOG" ] && [ "$(stat -f%z "$STDERR_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  mv "$STDERR_LOG" "$STDERR_LOG.old"
fi

echo "=== Training SaneAI (unified model) — $(date) ===" >> "$LOG_DIR/training.stdout.log"

# Step 1: Merge latest per-product training data into SaneAI
SANEAI_DIR="$HOME/SaneApps/apps/SaneAI/training_data"
if [ -f "$SANEAI_DIR/merge_training_data.py" ]; then
  "$PYTHON" "$SANEAI_DIR/merge_training_data.py" >> "$LOG_DIR/training.stdout.log" 2>&1
fi

# Step 2: Train the production Llama model
PROD_START=$(date +%s)
bash "$SCRIPT_DIR/mini-train.sh" SaneAI
PROD_EXIT=$?
PROD_END=$(date +%s)
PROD_MINUTES=$(( (PROD_END - PROD_START) / 60 ))
echo "=== SaneAI complete (exit $PROD_EXIT, ${PROD_MINUTES}min) — $(date) ===" >> "$LOG_DIR/training.stdout.log"

# Step 3: Run challenger models (using SaneSync training data)
# Only run if production training succeeded and we have time before 8 AM
hour_now=$(date +%H)
hour_now=$((10#$hour_now))

if [ "$hour_now" -lt 8 ]; then
  # Calculate remaining minutes until hard stop
  minutes_until_8=$(( (8 - hour_now) * 60 - $(date +%M | sed 's/^0//') ))
  # Cap at 120 min (don't hog the machine even if lots of time)
  if [ "$minutes_until_8" -gt 120 ]; then
    minutes_until_8=120
  fi

  echo "=== Challenger training (budget: ${minutes_until_8}min) — $(date) ===" >> "$LOG_DIR/training.stdout.log"

  CHALLENGER_BUDGET_MIN="$minutes_until_8" \
  TRAIN_HARD_STOP_HOUR=8 \
    bash "$SCRIPT_DIR/mini-train-challengers.sh" SaneSync \
    >> "$LOG_DIR/training.stdout.log" 2>&1

  CHALLENGER_EXIT=$?
  echo "=== Challengers complete (exit $CHALLENGER_EXIT) — $(date) ===" >> "$LOG_DIR/training.stdout.log"
else
  echo "=== Skipping challengers — past 8 AM ===" >> "$LOG_DIR/training.stdout.log"
fi

exit $PROD_EXIT
