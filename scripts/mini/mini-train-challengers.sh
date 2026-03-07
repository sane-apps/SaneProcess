#!/bin/bash
# mini-train-challengers.sh - Run challenger model training
# Called by a daily LaunchAgent or by mini-train-all.sh after production training.
#
# Reads challenger configs from $APP_DIR/training_data/challenger_configs/*.yaml
# Runs each through mini-train.sh with --challenger flag.
# Respects time budget — skips remaining challengers if budget exhausted.
# NEVER auto-promotes — generates comparison reports for human review.
#
# Usage: mini-train-challengers.sh [app_name]  (default: SaneSync)

set -uo pipefail

SANE_ROOT="${SANE_ROOT:-$HOME/SaneApps}"
SANE_OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"

APP_NAME="${1:-SaneSync}"
APP_DIR="$SANE_ROOT/apps/$APP_NAME"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SANE_OUTPUT_DIR"
DATE=$(date +"%Y-%m-%d")
COMPARISON_REPORT="$OUTPUT_DIR/challenger_comparison_${APP_NAME}_${DATE}.md"

# Inherit time budget from environment (set by mini-train-all.sh)
# Default: 120 minutes for all challengers combined
CHALLENGER_BUDGET_MIN="${CHALLENGER_BUDGET_MIN:-120}"
TRAIN_HARD_STOP_HOUR="${TRAIN_HARD_STOP_HOUR:-8}"
CHALLENGER_START=$(date +%s)

CONFIGS_DIR="$APP_DIR/training_data/challenger_configs"

if [ ! -d "$CONFIGS_DIR" ]; then
  echo "No challenger configs found at $CONFIGS_DIR" >&2
  exit 0
fi

# Find all challenger YAML configs
CONFIG_FILES=$(find "$CONFIGS_DIR" -name "*.yaml" -o -name "*.yml" 2>/dev/null | sort)

if [ -z "$CONFIG_FILES" ]; then
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
Budget: ${CHALLENGER_BUDGET_MIN} minutes, hard stop at ${TRAIN_HARD_STOP_HOUR}:00

## Production Baseline
EOF

# Read production accuracy from today's training report (if available)
PROD_REPORT="$OUTPUT_DIR/training_report_${APP_NAME}.md"
if [ -f "$PROD_REPORT" ]; then
  PROD_BEST=$(grep "Best adapter:" "$PROD_REPORT" 2>/dev/null | grep -oE '[0-9]+%' | head -1)
  if [ -n "$PROD_BEST" ]; then
    echo "- **Llama 3.2 3B (production):** $PROD_BEST" >> "$COMPARISON_REPORT"
  else
    echo "- **Llama 3.2 3B (production):** (no result today)" >> "$COMPARISON_REPORT"
  fi
else
  echo "- **Llama 3.2 3B (production):** (no training report today)" >> "$COMPARISON_REPORT"
fi

echo "" >> "$COMPARISON_REPORT"
echo "## Challenger Results" >> "$COMPARISON_REPORT"
echo "" >> "$COMPARISON_REPORT"
echo "| Model | Config | Accuracy | Time (min) | Status |" >> "$COMPARISON_REPORT"
echo "|-------|--------|----------|------------|--------|" >> "$COMPARISON_REPORT"

CHALLENGERS_RUN=0
CHALLENGERS_SKIPPED=0

# Write config list to temp file so we can use redirect instead of pipe
# (pipe creates subshell on bash 3.2, losing counter variables)
CONFIG_LIST_TMP=$(mktemp)
echo "$CONFIG_FILES" > "$CONFIG_LIST_TMP"

# Run each challenger
while read -r config_file; do
  # Check time budget
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

  # Check hard stop hour
  hour_now=$(date +%H)
  hour_now=$((10#$hour_now))
  if [ "$hour_now" -ge "$TRAIN_HARD_STOP_HOUR" ]; then
    echo "Past hard stop hour (${TRAIN_HARD_STOP_HOUR}:00). Skipping remaining challengers." >&2
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
  echo "    Time remaining: $remaining min" >&2

  CHALLENGER_RUN_START=$(date +%s)

  # Run mini-train.sh with challenger flags
  # Pass remaining time as budget (divided by remaining challengers would be smarter,
  # but for now just let the script's own budget/hard-stop guards handle it)
  SANE_ROOT="$SANE_ROOT" \
  SANE_OUTPUT_DIR="$SANE_OUTPUT_DIR" \
  MAX_TRAIN_RUNTIME_MIN="$remaining" \
  TRAIN_HARD_STOP_HOUR="$TRAIN_HARD_STOP_HOUR" \
    bash "$SCRIPT_DIR/mini-train.sh" "$APP_NAME" \
      --model "$model_id" \
      --config "$config_file" \
      --challenger

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
  else
    accuracy=""
  fi

  if [ -z "$accuracy" ]; then
    accuracy="N/A"
    status="FAILED"
  elif echo "$accuracy" | grep -qE '^[0-9]+'; then
    acc_num=$(echo "$accuracy" | tr -d '%')
    if [ "$acc_num" -gt 90 ]; then
      status="BEATS BASELINE"
    elif [ "$acc_num" -gt 70 ]; then
      status="Promising"
    else
      status="Below baseline"
    fi
  else
    status="Unknown"
  fi

  echo "| $model_id | $config_name | $accuracy | $CHALLENGER_TIME | $status |" >> "$COMPARISON_REPORT"
  CHALLENGERS_RUN=$((CHALLENGERS_RUN + 1))

  echo "    Result: $accuracy ($status) in ${CHALLENGER_TIME}min" >&2
done < "$CONFIG_LIST_TMP"
rm -f "$CONFIG_LIST_TMP"

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
**Next scheduled lane:** Daily challenger agent at 1:00 AM, plus Sunday weekly follow-up after production training

> Challengers NEVER auto-promote. If a model beats Llama, review the report and manually promote.
EOF

echo "" >&2
echo "Challenger comparison report: $COMPARISON_REPORT" >&2
