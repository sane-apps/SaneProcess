#!/bin/bash
# mini-train.sh - Automated LLM training pipeline for Mac mini
# Called by launchd wrappers or run manually against a specific app repo
# Usage: mini-train.sh [app_name] [--model MODEL_ID] [--config CONFIG.yaml] [--challenger]
# Example: mini-train.sh SaneAI
# Example: mini-train.sh SaneAI --model "mlx-community/SmolLM3-3B-4bit" --config challenger_configs/smollm3-3b.yaml --challenger
#
# What it does:
# 1. Pulls latest training data from git
# 2. Runs training sweeps at multiple iteration counts
# 3. Validates each checkpoint
# 4. Generates a report comparing results
# 5. Identifies the best adapter (auto-promote only in production mode)
#
# Flags:
#   --model MODEL_ID   Override base model (default: Llama-3.2-3B-Instruct-4bit)
#   --config FILE      Override LoRA config (relative to training_data/ or absolute path)
#   --challenger       Challenger mode: single 1000-iter sweep, no auto-promote, separate report

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

DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="$(expand_home_path "${SANE_ROOT:-$DEFAULT_SANE_ROOT}")"
SANE_OUTPUT_DIR="$(expand_home_path "${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}")"

# App selection (default: SaneAI)
APP_NAME="SaneAI"
case "${1:-}" in
  ""|-*)
    ;;
  *)
    APP_NAME="$1"
    shift
    ;;
esac

# Parse optional flags (bash 3.2 compatible — no associative arrays)
BASE_MODEL_OVERRIDE=""
CONFIG_OVERRIDE=""
CHALLENGER_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || { echo "ERROR: --model requires a value" >&2; exit 2; }
      BASE_MODEL_OVERRIDE="$2"
      shift 2
      ;;
    --config)
      [ $# -ge 2 ] || { echo "ERROR: --config requires a value" >&2; exit 2; }
      CONFIG_OVERRIDE="$2"
      shift 2
      ;;
    --challenger)
      CHALLENGER_MODE=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

APP_DIR="$SANE_ROOT/apps/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: App directory not found: $APP_DIR" >&2
  echo "Available: $(ls "$SANE_ROOT/apps" 2>/dev/null | tr '\n' ' ')" >&2
  exit 1
fi

# Paths
TRAIN_DIR="$APP_DIR/training_data"
MODELS_DIR="$APP_DIR/models"
OUTPUT_DIR="$SANE_OUTPUT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_SCRIPT="$SCRIPT_DIR/evaluate_model.py"

# Report file: separate for challengers to avoid clobbering production report
if [ "$CHALLENGER_MODE" = true ] && [ -n "$BASE_MODEL_OVERRIDE" ]; then
  # Extract short model name for report filename (e.g., "Qwen3-4B" from "Qwen/Qwen3-4B-MLX-4bit")
  MODEL_SHORT=$(echo "$BASE_MODEL_OVERRIDE" | sed 's|.*/||' | sed 's/-MLX-4bit//' | sed 's/-4bit//' | tr '[:upper:]' '[:lower:]')
  REPORT="$OUTPUT_DIR/challenger_report_${APP_NAME}_${MODEL_SHORT}.md"
else
  REPORT="$OUTPUT_DIR/training_report_${APP_NAME}.md"
fi
VENV="$HOME/mlx-env/bin"
PYTHON="$VENV/python3"
MLX_LM="$PYTHON -m mlx_lm"

DATE=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
TIMESTAMP_FILE=$(date +"%Y-%m-%d_%H-%M-%S")
START_EPOCH=$(date +%s)
MODE_LABEL="production"
READINESS_TARGET_APP="${READINESS_TARGET_APP:-}"
EVAL_SUITE_WEIGHTS="${EVAL_SUITE_WEIGHTS:-commentary_workflow=4,workflow_packs=2,workflow_guardrails=2,core=1}"
EVAL_MAX_CASES="${EVAL_MAX_CASES:-0}"
EVAL_MAX_TOKENS="${EVAL_MAX_TOKENS:-128}"
EVAL_MAX_TOKENS_CAP="${EVAL_MAX_TOKENS_CAP:-0}"
EVAL_SUITES="${EVAL_SUITES:-}"
PRIMARY_WORKFLOW_SUITE="${PRIMARY_WORKFLOW_SUITE:-commentary_workflow}"
PRIMARY_WORKFLOW_MIN_PCT="${PRIMARY_WORKFLOW_MIN_PCT:-50}"
WORKFLOW_PASS_SCORE="${WORKFLOW_PASS_SCORE:-75}"
PRODUCTION_PROMOTE_SCORE="${PRODUCTION_PROMOTE_SCORE:-90}"
if [ "$CHALLENGER_MODE" = true ]; then
  MODE_LABEL="challenger"
fi

detect_eval_token_cap() {
  local raw_memsize mem_gb

  if [ "$EVAL_MAX_TOKENS_CAP" -gt 0 ]; then
    return
  fi

  raw_memsize=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
  if ! [[ "$raw_memsize" =~ ^[0-9]+$ ]] || [ "$raw_memsize" -le 0 ]; then
    EVAL_MAX_TOKENS_CAP=192
    return
  fi

  mem_gb=$((raw_memsize / 1024 / 1024 / 1024))
  if [ "$mem_gb" -le 8 ]; then
    EVAL_MAX_TOKENS_CAP=192
  else
    EVAL_MAX_TOKENS_CAP=256
  fi
}

detect_eval_token_cap

if [ "$EVAL_MAX_TOKENS" -gt "$EVAL_MAX_TOKENS_CAP" ]; then
  EVAL_MAX_TOKENS="$EVAL_MAX_TOKENS_CAP"
fi

# Runtime safety guards for 8GB Mac mini
# Default challenger behavior is "run until hard stop time unless the process stalls."
MAX_TRAIN_RUNTIME_MIN="${MAX_TRAIN_RUNTIME_MIN:-0}"
TRAIN_STALL_TIMEOUT_MIN="${TRAIN_STALL_TIMEOUT_MIN:-45}"
TRAIN_POLL_INTERVAL_SEC="${TRAIN_POLL_INTERVAL_SEC:-30}"
TRAIN_FAILURE_LOG_LINES="${TRAIN_FAILURE_LOG_LINES:-20}"
TRAIN_ALERT_NOTIFY="${TRAIN_ALERT_NOTIFY:-true}"
TRAIN_ALERT_SUPPRESS_MIN="${TRAIN_ALERT_SUPPRESS_MIN:-360}"
TRAIN_ALERT_COMMAND="${TRAIN_ALERT_COMMAND:-}"
TRAIN_SWEEP_ITERS="${TRAIN_SWEEP_ITERS:-}"
TRAIN_EXAMPLE_DROP_MAX_PCT="${TRAIN_EXAMPLE_DROP_MAX_PCT:-20}"
VALID_EXAMPLE_DROP_MAX_PCT="${VALID_EXAMPLE_DROP_MAX_PCT:-20}"
PARTIAL_CHECKPOINT_EVAL="${PARTIAL_CHECKPOINT_EVAL:-true}"
CHECKPOINT_FILES_TO_KEEP="${CHECKPOINT_FILES_TO_KEEP:-1}"

resolve_base_config() {
  local candidate=""

  if [ -n "$CONFIG_OVERRIDE" ]; then
    candidate="$CONFIG_OVERRIDE"
    if [ ! -f "$candidate" ]; then
      candidate="$TRAIN_DIR/$CONFIG_OVERRIDE"
    fi
  else
    candidate="$TRAIN_DIR/lora_config_mini.yaml"
  fi

  printf '%s\n' "$candidate"
}

config_iters_from_file() {
  local config_file="$1"
  awk '/^iters:/ {print $2; exit}' "$config_file" 2>/dev/null
}

config_warmup_from_file() {
  local config_file="$1"
  awk '/^[[:space:]]*warmup:/ {print $2; exit}' "$config_file" 2>/dev/null
}

warmup_steps_for_sweep() {
  local config_file="$1"
  local sweep_iters="$2"
  local base_iters base_warmup scaled

  base_iters=$(config_iters_from_file "$config_file")
  base_warmup=$(config_warmup_from_file "$config_file")

  if ! [[ "$sweep_iters" =~ ^[0-9]+$ ]] || [ "$sweep_iters" -le 1 ]; then
    printf '%s\n' "0"
    return
  fi

  if ! [[ "$base_iters" =~ ^[0-9]+$ ]] || [ "$base_iters" -le 0 ] || \
     ! [[ "$base_warmup" =~ ^[0-9]+$ ]] || [ "$base_warmup" -lt 0 ]; then
    scaled=$((sweep_iters / 20))
    if [ "$scaled" -lt 1 ]; then
      scaled=1
    fi
    printf '%s\n' "$scaled"
    return
  fi

  scaled=$(( (base_warmup * sweep_iters + base_iters - 1) / base_iters ))
  if [ "$base_warmup" -gt 0 ] && [ "$scaled" -lt 1 ]; then
    scaled=1
  fi
  if [ "$scaled" -ge "$sweep_iters" ]; then
    scaled=$((sweep_iters - 1))
  fi

  printf '%s\n' "$scaled"
}

parse_hard_stop_time() {
  local raw_time="${TRAIN_HARD_STOP_TIME:-}"
  local parsed_hour parsed_minute

  if [ -z "$raw_time" ]; then
    raw_time="$(printf '%02d:%02d' "${TRAIN_HARD_STOP_HOUR:-8}" "${TRAIN_HARD_STOP_MINUTE:-30}")"
  fi

  parsed_hour=$(printf '%s' "$raw_time" | cut -d: -f1)
  parsed_minute=$(printf '%s' "$raw_time" | cut -d: -f2)

  if ! [[ "$parsed_hour" =~ ^[0-9]{1,2}$ ]] || ! [[ "$parsed_minute" =~ ^[0-9]{2}$ ]]; then
    parsed_hour="08"
    parsed_minute="30"
  fi

  TRAIN_HARD_STOP_HOUR=$((10#$parsed_hour))
  TRAIN_HARD_STOP_MINUTE=$((10#$parsed_minute))
  TRAIN_HARD_STOP_TIME=$(printf '%02d:%02d' "$TRAIN_HARD_STOP_HOUR" "$TRAIN_HARD_STOP_MINUTE")
}

parse_hard_stop_time

if [ "$CHALLENGER_MODE" = true ]; then
  NEXT_RUN_HINT="Daily challenger agent at 1:00 AM, except Sunday when SaneAI owns the window."
else
  NEXT_RUN_HINT="Weekly SaneAI agent on Sunday at 1:00 AM."
fi

mkdir -p "$OUTPUT_DIR" "$MODELS_DIR/sweeps"

ALERTS_DIR="$OUTPUT_DIR/alerts/training"
CURRENT_ALERTS_DIR="$ALERTS_DIR/current"
CURRENT_ALERT_FILE="$CURRENT_ALERTS_DIR/${APP_NAME}_${MODE_LABEL}.md"
ALERT_STATE_FILE="$ALERTS_DIR/${APP_NAME}_${MODE_LABEL}.state"
ALERT_HISTORY_LOG="$ALERTS_DIR/history.log"
mkdir -p "$CURRENT_ALERTS_DIR"

# Lock file (with stale lock detection)
# Challengers share a single lock to run sequentially (not parallel — GPU contention)
if [ "$CHALLENGER_MODE" = true ]; then
  LOCKFILE="$OUTPUT_DIR/.training_${APP_NAME}_challenger.lock"
else
  LOCKFILE="$OUTPUT_DIR/.training_${APP_NAME}.lock"
fi
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  # Check if lock is stale (older than 8 hours — sweeps can take 5+ hours)
  if [ -d "$LOCKFILE" ] && [ "$(find "$LOCKFILE" -maxdepth 0 -mmin +480 2>/dev/null)" ]; then
    echo "Removing stale lock (>8 hours old)" >&2
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE" 2>/dev/null || { echo "Cannot acquire lock" >&2; exit 1; }
  else
    echo "Another training instance is running" >&2
    exit 1
  fi
fi
prune_old_sweeps() {
  local report_file="${1:-}"
  local keep_days="${SWEEP_KEEP_DAYS:-3}"
  local min_keep="${MIN_SWEEPS_TO_KEEP:-4}"

  if ! [[ "$keep_days" =~ ^[0-9]+$ ]]; then
    keep_days=3
  fi
  if ! [[ "$min_keep" =~ ^[0-9]+$ ]]; then
    min_keep=4
  fi

  local prune_cutoff
  prune_cutoff=$(date -v-"${keep_days}"d +"%Y-%m-%d")
  local pruned_count=0
  local pruned_size=0

  local sweep_idx=0
  for sweep_dir in $(ls -1dt "$MODELS_DIR/sweeps"/sweep_* "$MODELS_DIR/sweeps"/challenger_* 2>/dev/null); do
    [ -d "$sweep_dir" ] || continue
    sweep_idx=$((sweep_idx + 1))
    if [ "$sweep_idx" -le "$min_keep" ]; then
      continue
    fi

    local sweep_date
    sweep_date=$(basename "$sweep_dir" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
    [ -z "$sweep_date" ] && continue

    if [[ "$sweep_date" < "$prune_cutoff" ]]; then
      local dir_size
      dir_size=$(du -sm "$sweep_dir" 2>/dev/null | awk '{print $1}')
      rm -rf "$sweep_dir"
      pruned_count=$((pruned_count + 1))
      pruned_size=$((pruned_size + dir_size))
    fi
  done

  if [ "$pruned_count" -gt 0 ]; then
    local summary
    summary="Pruned $pruned_count old sweep(s), freed ${pruned_size}MB (keep_days=$keep_days, min_keep=$min_keep)."
    echo "$summary" >&2
    if [ -n "$report_file" ] && [ -f "$report_file" ]; then
      echo "" >> "$report_file"
      echo "**Pruned:** $pruned_count old sweep(s) removed (${pruned_size}MB freed). Keeping last ${keep_days} day(s), minimum ${min_keep} sweep dir(s)." >> "$report_file"
    fi
  fi
}

cleanup() {
  prune_old_sweeps "" || true
  rm -rf "$LOCKFILE"
  rm -f "${RESULTS_FILE:-}"
}
trap cleanup EXIT

# Backstop: prune stale sweeps before training starts so old checkpoints
# cannot accumulate after prior interrupted runs.
prune_old_sweeps "" || true

remaining_budget_seconds() {
  if [ "$MAX_TRAIN_RUNTIME_MIN" -le 0 ]; then
    echo "-1"
    return
  fi
  now=$(date +%s)
  elapsed=$((now - START_EPOCH))
  budget=$((MAX_TRAIN_RUNTIME_MIN * 60 - elapsed))
  echo "$budget"
}

is_past_hard_stop_time() {
  local hour_now minute_now
  hour_now=$(date +%H)
  minute_now=$(date +%M)
  hour_now=$((10#$hour_now))
  minute_now=$((10#$minute_now))

  if [ "$hour_now" -gt "$TRAIN_HARD_STOP_HOUR" ]; then
    return 0
  fi
  if [ "$hour_now" -eq "$TRAIN_HARD_STOP_HOUR" ] && [ "$minute_now" -ge "$TRAIN_HARD_STOP_MINUTE" ]; then
    return 0
  fi
  return 1
}

is_training_stalled() {
  local log_path="$1"
  local train_pid="$2"
  local now current_log_mtime current_cpu_seconds

  if [ "$TRAIN_STALL_TIMEOUT_MIN" -le 0 ]; then
    return 1
  fi

  current_log_mtime=$(log_mtime_epoch "$log_path")
  current_cpu_seconds=$(pid_cpu_seconds "$train_pid")
  now=$(date +%s)

  if [ "$current_log_mtime" -gt "$TRAIN_LAST_LOG_MTIME" ] || [ "$current_cpu_seconds" -gt "$TRAIN_LAST_CPU_SECONDS" ]; then
    TRAIN_LAST_PROGRESS_AT="$now"
  fi

  TRAIN_LAST_LOG_MTIME="$current_log_mtime"
  TRAIN_LAST_CPU_SECONDS="$current_cpu_seconds"

  [ $((now - TRAIN_LAST_PROGRESS_AT)) -ge $((TRAIN_STALL_TIMEOUT_MIN * 60)) ]
}

log_mtime_epoch() {
  local log_path="$1"
  local last_activity

  if [ ! -f "$log_path" ]; then
    echo "0"
    return
  fi

  last_activity=$(stat -f %m "$log_path" 2>/dev/null || echo "")
  if [ -z "$last_activity" ]; then
    echo "0"
    return
  fi

  echo "$last_activity"
}

parse_ps_time_to_seconds() {
  local raw_time="$1"
  local days=0 hours=0 minutes=0 seconds=0 time_part

  raw_time=$(printf '%s' "$raw_time" | tr -d '[:space:]')
  raw_time="${raw_time%%.*}"
  if [ -z "$raw_time" ]; then
    echo "0"
    return
  fi

  if [[ "$raw_time" == *-* ]]; then
    days="${raw_time%%-*}"
    time_part="${raw_time#*-}"
  else
    time_part="$raw_time"
  fi

  case "$time_part" in
    *:*:*)
      hours="${time_part%%:*}"
      time_part="${time_part#*:}"
      minutes="${time_part%%:*}"
      seconds="${time_part##*:}"
      ;;
    *:*)
      minutes="${time_part%%:*}"
      seconds="${time_part##*:}"
      ;;
    *)
      seconds="$time_part"
      ;;
  esac

  echo $((10#$days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
}

pid_cpu_seconds() {
  local pid="$1"
  local raw_time

  raw_time=$(ps -o time= -p "$pid" 2>/dev/null | awk '{$1=$1; print $1}')
  parse_ps_time_to_seconds "$raw_time"
}

init_training_progress_watch() {
  local log_path="$1"
  local train_pid="$2"

  TRAIN_LAST_PROGRESS_AT=$(date +%s)
  TRAIN_LAST_LOG_MTIME=$(log_mtime_epoch "$log_path")
  TRAIN_LAST_CPU_SECONDS=$(pid_cpu_seconds "$train_pid")
}

training_log_has_invalid_metrics() {
  local log_path="$1"

  [ -f "$log_path" ] || return 1

  if grep -Eq 'Val loss nan|Train loss nan|Trained Tokens 0([^0-9]|$)' "$log_path"; then
    return 0
  fi

  return 1
}

latest_saved_checkpoint_step() {
  local adapter_dir="$1"
  local checkpoint_path checkpoint_step latest_step

  latest_step=0
  for checkpoint_path in "$adapter_dir"/*_adapters.safetensors; do
    [ -f "$checkpoint_path" ] || continue
    checkpoint_step=$(basename "$checkpoint_path" | sed 's/_adapters\.safetensors$//' | sed 's/^0*//')
    if [ -z "$checkpoint_step" ]; then
      checkpoint_step=0
    fi
    if [[ "$checkpoint_step" =~ ^[0-9]+$ ]] && [ "$checkpoint_step" -gt "$latest_step" ]; then
      latest_step=$checkpoint_step
    fi
  done

  printf '%s\n' "$latest_step"
}

prune_checkpoint_files() {
  local adapter_dir="$1"
  local keep_latest="${2:-1}"
  local report_file="${3:-}"
  local checkpoint_list keep_list checkpoint_path
  local total_checkpoints removed_checkpoints removed_mb checkpoint_mb

  [ -d "$adapter_dir" ] || return 0

  if ! [[ "$keep_latest" =~ ^[0-9]+$ ]] || [ "$keep_latest" -lt 1 ]; then
    keep_latest=1
  fi

  checkpoint_list=$(mktemp)
  keep_list=$(mktemp)
  removed_checkpoints=0
  removed_mb=0

  for checkpoint_path in "$adapter_dir"/*_adapters.safetensors; do
    [ -f "$checkpoint_path" ] || continue
    printf '%s\n' "$checkpoint_path" >> "$checkpoint_list"
  done

  if [ ! -s "$checkpoint_list" ]; then
    rm -f "$checkpoint_list" "$keep_list"
    return 0
  fi

  sort "$checkpoint_list" -o "$checkpoint_list"
  total_checkpoints=$(wc -l < "$checkpoint_list" | tr -d ' ')
  if [ "$total_checkpoints" -le "$keep_latest" ]; then
    rm -f "$checkpoint_list" "$keep_list"
    return 0
  fi

  tail -n "$keep_latest" "$checkpoint_list" > "$keep_list"

  while IFS= read -r checkpoint_path; do
    [ -n "$checkpoint_path" ] || continue
    if grep -Fxq "$checkpoint_path" "$keep_list"; then
      continue
    fi
    checkpoint_mb=$(du -sm "$checkpoint_path" 2>/dev/null | awk '{print $1}')
    [ -n "$checkpoint_mb" ] || checkpoint_mb=0
    rm -f "$checkpoint_path"
    removed_checkpoints=$((removed_checkpoints + 1))
    removed_mb=$((removed_mb + checkpoint_mb))
  done < "$checkpoint_list"

  rm -f "$checkpoint_list" "$keep_list"

  if [ "$removed_checkpoints" -gt 0 ] && [ -n "$report_file" ] && [ -f "$report_file" ]; then
    echo "- Pruned intermediate checkpoints: ${removed_checkpoints} file(s), ${removed_mb}MB freed, kept latest ${keep_latest}" >> "$report_file"
  fi
}

build_sweep_iters() {
  local base_config="$1"
  local raw_iters normalized iter configured_iters
  local sweep_count=0

  raw_iters="$TRAIN_SWEEP_ITERS"
  SWEEP_ITERS=()
  if [ -n "$raw_iters" ]; then
    normalized=$(printf '%s' "$raw_iters" | tr ',:' '  ')
    for iter in $normalized; do
      if [[ "$iter" =~ ^[0-9]+$ ]] && [ "$iter" -gt 0 ]; then
        if [ "$sweep_count" -eq 0 ]; then
          SWEEP_ITERS=("$iter")
        else
          SWEEP_ITERS=("${SWEEP_ITERS[@]}" "$iter")
        fi
        sweep_count=$((sweep_count + 1))
      fi
  done
  fi

  if [ "$sweep_count" -eq 0 ]; then
    configured_iters=$(config_iters_from_file "$base_config")
    if [[ "$configured_iters" =~ ^[0-9]+$ ]] && [ "$configured_iters" -gt 0 ]; then
      SWEEP_ITERS=("$configured_iters")
    elif [ "$CHALLENGER_MODE" = true ]; then
      SWEEP_ITERS=(1000)
    else
      SWEEP_ITERS=(1000 2000)
    fi
  fi
}

is_active_pid() {
  local pid="$1"
  local proc_state

  proc_state=$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}')
  case "$proc_state" in
    ""|Z*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

load_training_alert_state() {
  LAST_ALERT_STATUS=""
  LAST_ALERT_AT=0
  LAST_ALERT_KEY=""
  LAST_ALERT_REPORT=""

  if [ -f "$ALERT_STATE_FILE" ]; then
    IFS=$'\t' read -r LAST_ALERT_STATUS LAST_ALERT_AT LAST_ALERT_KEY LAST_ALERT_REPORT < "$ALERT_STATE_FILE" || true
  fi
}

save_training_alert_state() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$ALERT_STATE_FILE"
}

append_training_alert_history() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TIMESTAMP" \
    "$APP_NAME" \
    "$MODE_LABEL" \
    "$BASE_MODEL" \
    "$1" \
    "$2" >> "$ALERT_HISTORY_LOG"
}

notify_training_event() {
  local title="$1"
  local message="$2"
  local safe_title safe_message

  safe_title=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
  safe_message=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')

  if [ "$TRAIN_ALERT_NOTIFY" = "true" ]; then
    osascript -e "display notification \"$safe_message\" with title \"$safe_title\" sound name \"Sosumi\"" >/dev/null 2>&1 || true
  fi

  if [ -n "$TRAIN_ALERT_COMMAND" ]; then
    TRAIN_ALERT_TITLE="$title" \
    TRAIN_ALERT_MESSAGE="$message" \
    TRAIN_ALERT_APP="$APP_NAME" \
    TRAIN_ALERT_MODE="$MODE_LABEL" \
    TRAIN_ALERT_MODEL="$BASE_MODEL" \
    TRAIN_ALERT_REPORT="${REPORT_ARCHIVE:-$REPORT}" \
      /bin/bash -lc "$TRAIN_ALERT_COMMAND" >/dev/null 2>&1 || true
  fi
}

write_current_training_alert() {
  local status="$1"
  local summary="$2"
  local log_path="${3:-}"

  cat > "$CURRENT_ALERT_FILE" <<EOF
# Training Alert — $APP_NAME ($MODE_LABEL)

- Status: $status
- Generated: $TIMESTAMP
- Model: $BASE_MODEL
- Summary: $summary
- Report: ${REPORT_ARCHIVE:-$REPORT}
EOF

  if [ -n "$log_path" ]; then
    cat >> "$CURRENT_ALERT_FILE" <<EOF
- Log: $log_path
EOF
  fi
}

emit_training_failure_alert() {
  local summary="$1"
  local log_path="${2:-}"
  local now key suppress_seconds

  load_training_alert_state
  now=$(date +%s)
  key="${APP_NAME}|${MODE_LABEL}|${BASE_MODEL}|failure|${summary}"
  suppress_seconds=$((TRAIN_ALERT_SUPPRESS_MIN * 60))

  write_current_training_alert "failure" "$summary" "$log_path"
  append_training_alert_history "failure" "$summary"

  if [ "$LAST_ALERT_STATUS" != "failure" ] || [ "$LAST_ALERT_KEY" != "$key" ] || [ $((now - LAST_ALERT_AT)) -ge "$suppress_seconds" ]; then
    notify_training_event "Mini training failed" "$APP_NAME $MODE_LABEL: $summary"
  fi

  save_training_alert_state "failure" "$now" "$key" "${REPORT_ARCHIVE:-$REPORT}"
}

emit_training_recovery_alert() {
  local summary="$1"
  local now

  load_training_alert_state
  now=$(date +%s)

  if [ "$LAST_ALERT_STATUS" = "failure" ]; then
    notify_training_event "Mini training recovered" "$APP_NAME $MODE_LABEL: $summary"
    append_training_alert_history "recovered" "$summary"
  fi

  rm -f "$CURRENT_ALERT_FILE"
  save_training_alert_state "success" "$now" "${APP_NAME}|${MODE_LABEL}|${BASE_MODEL}|success" "${REPORT_ARCHIVE:-$REPORT}"
}

append_metrics_header_if_needed() {
  if [ ! -f "$METRICS_FILE" ]; then
    printf 'app\tmode\tmodel\ttimestamp\ttrain_examples\tvalid_examples\tbest_iters\tbest_accuracy\tbest_time_min\tsuccessful_sweeps\tscript_exit\tstatus\treport_archive\n' > "$METRICS_FILE"
  fi
}

find_previous_successful_metric() {
  if [ ! -f "$METRICS_FILE" ]; then
    return 1
  fi

  awk -F '\t' -v app="$APP_NAME" -v mode="$MODE_LABEL" -v model="$BASE_MODEL" '
    NR == 1 { next }
    $1 == app && $2 == mode && $3 == model && $12 == "success" { line = $0 }
    END {
      if (line != "") {
        print line
      } else {
        exit 1
      }
    }
  ' "$METRICS_FILE"
}

find_latest_successful_metric_for_mode() {
  if [ ! -f "$METRICS_FILE" ]; then
    return 1
  fi

  awk -F '\t' -v app="$APP_NAME" -v mode="$MODE_LABEL" '
    NR == 1 { next }
    $1 == app && $2 == mode && $12 == "success" { line = $0 }
    END {
      if (line != "") {
        print line
      } else {
        exit 1
      }
    }
  ' "$METRICS_FILE"
}

TARGET_BASELINE_MODE=""

find_latest_target_baseline_metric() {
  local target_app="$1"
  local target_metrics_file="$SANE_OUTPUT_DIR/history/$target_app/training_metrics_workflow_v1.tsv"
  local baseline_line=""

  if [ ! -f "$target_metrics_file" ]; then
    target_metrics_file="$SANE_OUTPUT_DIR/history/$target_app/training_metrics.tsv"
  fi

  if [ ! -f "$target_metrics_file" ]; then
    return 1
  fi

  baseline_line=$(
    awk -F '\t' -v app="$target_app" '
      NR == 1 { next }
      $1 == app && $2 == "production" && $12 == "success" { line = $0 }
      END {
        if (line != "") {
          print line
        } else {
          exit 1
        }
      }
    ' "$target_metrics_file" 2>/dev/null || true
  )

  if [ -n "$baseline_line" ]; then
    TARGET_BASELINE_MODE="production"
    printf '%s\n' "$baseline_line"
    return 0
  fi

  baseline_line=$(
    awk -F '\t' -v app="$target_app" '
      NR == 1 { next }
      $1 == app && $12 == "success" { line = $0 }
      END {
        if (line != "") {
          print line
        } else {
          exit 1
        }
      }
    ' "$target_metrics_file" 2>/dev/null || true
  )

  if [ -n "$baseline_line" ]; then
    TARGET_BASELINE_MODE=$(printf '%s\n' "$baseline_line" | awk -F '\t' '{print $2}')
    printf '%s\n' "$baseline_line"
    return 0
  fi

  return 1
}

find_latest_target_production_metric() {
  awk -F '\t' -v app="$1" '
    NR == 1 { next }
    $1 == app && $2 == "production" && $12 == "success" { line = $0 }
    END {
      if (line != "") {
        print line
      } else {
        exit 1
      }
    }
  ' "$target_metrics_file"
}

append_readiness_header_if_needed() {
  if [ ! -f "$READINESS_FILE" ]; then
    printf 'source_app\ttarget_app\ttimestamp\tsource_model\tsource_best_accuracy\ttarget_model\ttarget_best_accuracy\tdelta\tstatus\tsource_report\ttarget_report\n' > "$READINESS_FILE"
  fi
}

dataset_guard_failed() {
  local summary="$1"

  echo "**ERROR:** $summary" >> "$REPORT"
  echo "" >> "$REPORT"
  emit_training_failure_alert "$summary"
  exit 1
}

build_eval_command() {
  local model_name="$1"
  local adapter_path="${2:-}"
  local old_ifs suite_name suite_weight

  EVAL_CMD=(
    "$PYTHON"
    "$EVAL_SCRIPT"
    --model "$model_name"
    --train-file "$TRAIN_DIR/train.jsonl"
    --system-prompt-file "$TRAIN_DIR/system_prompt.txt"
    --eval-glob "$TRAIN_DIR/eval_*.jsonl"
  )

  if [ -n "$adapter_path" ]; then
    EVAL_CMD=("${EVAL_CMD[@]}" --adapter-path "$adapter_path")
  fi

  old_ifs="$IFS"
  IFS=','
  for suite_name in $EVAL_SUITES; do
    suite_name=$(printf '%s' "$suite_name" | sed 's/^ *//; s/ *$//')
    if [ -n "$suite_name" ]; then
      EVAL_CMD=("${EVAL_CMD[@]}" --suite "$suite_name")
    fi
  done

  for suite_weight in $EVAL_SUITE_WEIGHTS; do
    suite_weight=$(printf '%s' "$suite_weight" | sed 's/^ *//; s/ *$//')
    if [ -n "$suite_weight" ]; then
      EVAL_CMD=("${EVAL_CMD[@]}" --suite-weight "$suite_weight")
    fi
  done
  IFS="$old_ifs"

  if [ "$EVAL_MAX_CASES" -gt 0 ]; then
    EVAL_CMD=("${EVAL_CMD[@]}" --max-cases "$EVAL_MAX_CASES")
  fi

  if [ "$EVAL_MAX_TOKENS" -gt 0 ]; then
    EVAL_CMD=("${EVAL_CMD[@]}" --max-tokens "$EVAL_MAX_TOKENS")
  fi

  if [ "$EVAL_MAX_TOKENS_CAP" -gt 0 ]; then
    EVAL_CMD=("${EVAL_CMD[@]}" --max-tokens-cap "$EVAL_MAX_TOKENS_CAP")
  fi

  if [ -n "$PRIMARY_WORKFLOW_SUITE" ]; then
    EVAL_CMD=("${EVAL_CMD[@]}"
      --primary-suite "$PRIMARY_WORKFLOW_SUITE"
      --primary-min-pct "$PRIMARY_WORKFLOW_MIN_PCT"
    )
  fi
}

parse_eval_summary() {
  local eval_text="$1"

  RAW_SCORE_LINE=$(printf '%s\n' "$eval_text" | grep "^RAW_SCORE:" | head -1 || true)
  WEIGHTED_SCORE_LINE=$(printf '%s\n' "$eval_text" | grep "^WEIGHTED_SCORE:" | head -1 || true)
  SCORE_LINE=$(printf '%s\n' "$eval_text" | grep "^SCORE:" | head -1 || true)
  PRIMARY_SUITE_LINE=$(printf '%s\n' "$eval_text" | grep "^PRIMARY_SUITE:" | head -1 || true)

  if [ -n "$RAW_SCORE_LINE" ]; then
    RAW_PASS=$(printf '%s' "$RAW_SCORE_LINE" | cut -d: -f2)
    RAW_TOTAL=$(printf '%s' "$RAW_SCORE_LINE" | cut -d: -f3)
    RAW_ACCURACY=$(printf '%s' "$RAW_SCORE_LINE" | cut -d: -f4)
  elif [ -n "$SCORE_LINE" ]; then
    RAW_PASS=$(printf '%s' "$SCORE_LINE" | cut -d: -f2)
    RAW_TOTAL=$(printf '%s' "$SCORE_LINE" | cut -d: -f3)
    RAW_ACCURACY=$(printf '%s' "$SCORE_LINE" | cut -d: -f4)
  else
    RAW_PASS=0
    RAW_TOTAL=0
    RAW_ACCURACY=0
  fi

  if [ -n "$WEIGHTED_SCORE_LINE" ]; then
    WEIGHTED_PASS=$(printf '%s' "$WEIGHTED_SCORE_LINE" | cut -d: -f2)
    WEIGHTED_TOTAL=$(printf '%s' "$WEIGHTED_SCORE_LINE" | cut -d: -f3)
    WEIGHTED_ACCURACY=$(printf '%s' "$WEIGHTED_SCORE_LINE" | cut -d: -f4)
  elif [ -n "$SCORE_LINE" ]; then
    WEIGHTED_PASS=$(printf '%s' "$SCORE_LINE" | cut -d: -f2)
    WEIGHTED_TOTAL=$(printf '%s' "$SCORE_LINE" | cut -d: -f3)
    WEIGHTED_ACCURACY=$(printf '%s' "$SCORE_LINE" | cut -d: -f4)
  else
    WEIGHTED_PASS=0
    WEIGHTED_TOTAL=0
    WEIGHTED_ACCURACY=0
  fi

  PRIMARY_SUITE_NAME="$PRIMARY_WORKFLOW_SUITE"
  PRIMARY_PASS=0
  PRIMARY_TOTAL=0
  PRIMARY_PCT=0
  PRIMARY_THRESHOLD="$PRIMARY_WORKFLOW_MIN_PCT"
  PRIMARY_STATUS="FAIL"

  if [ -n "$PRIMARY_SUITE_LINE" ]; then
    PRIMARY_SUITE_NAME=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f2)
    PRIMARY_PASS=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f3)
    PRIMARY_TOTAL=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f4)
    PRIMARY_PCT=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f5)
    PRIMARY_THRESHOLD=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f6)
    PRIMARY_STATUS=$(printf '%s' "$PRIMARY_SUITE_LINE" | cut -d: -f7)
  fi
}

# Check MLX is available
if [ ! -f "$PYTHON" ]; then
  echo "ERROR: Python venv not found at $VENV" >&2
  echo "Setup: python3 -m venv ~/mlx-env && ~/mlx-env/bin/pip install mlx-lm" >&2
  exit 1
fi

# Wait for nightly builds to finish if running
NIGHTLY_LOCK="$OUTPUT_DIR/.nightly.lock"
if [ -d "$NIGHTLY_LOCK" ]; then
  echo "Waiting for nightly build to complete..." >&2
  WAIT_COUNT=0
  while [ -d "$NIGHTLY_LOCK" ] && [ $WAIT_COUNT -lt 60 ]; do
    sleep 60
    WAIT_COUNT=$((WAIT_COUNT + 1))
  done
  if [ -d "$NIGHTLY_LOCK" ]; then
    echo "Nightly still running after 60 minutes. Proceeding anyway." >&2
  fi
fi

# Check disk space (need at least 10GB free for training)
disk_free_gb=$(df -g / | tail -1 | awk '{print $4}')
if [ "$disk_free_gb" -lt 10 ]; then
  echo "ERROR: Only ${disk_free_gb}GB free. Need at least 10GB for training." >&2
  exit 1
fi

cat > "$REPORT" <<EOF
# Training Report — $APP_NAME — $DATE

Generated at $TIMESTAMP
Machine: $(hostname) ($(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Apple Silicon"), $(sysctl -n hw.memsize | awk '{printf "%.0f GB", $1/1073741824}') RAM)
Runtime guard: $([ "$MAX_TRAIN_RUNTIME_MIN" -gt 0 ] && printf 'max %s minutes, ' "$MAX_TRAIN_RUNTIME_MIN" || printf 'no max runtime, ')hard stop at ${TRAIN_HARD_STOP_TIME} local time, stall timeout ${TRAIN_STALL_TIMEOUT_MIN} minutes
Workflow scoring: weights [$EVAL_SUITE_WEIGHTS], primary suite ${PRIMARY_WORKFLOW_SUITE} >= ${PRIMARY_WORKFLOW_MIN_PCT}%, pass target ${WORKFLOW_PASS_SCORE}%

---

EOF

# =============================================================================
# Step 1: Pull latest training data
# =============================================================================
echo "## Git Sync" >> "$REPORT"
echo "" >> "$REPORT"

cd "$APP_DIR"
FETCH_STATUS="ok"
if ! git fetch origin --prune 2>/dev/null; then
  FETCH_STATUS="fetch_failed"
fi

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
BEHIND="?"
AHEAD="?"
if [ "$BRANCH" != "DETACHED" ]; then
  BEHIND=$(git rev-list --count HEAD..origin/"$BRANCH" 2>/dev/null || echo "?")
  AHEAD=$(git rev-list --count origin/"$BRANCH"..HEAD 2>/dev/null || echo "?")
fi

if [ "$FETCH_STATUS" = "fetch_failed" ]; then
  echo "Git fetch failed. Using existing data." >> "$REPORT"
elif [ "$BRANCH" = "DETACHED" ]; then
  echo "Detached HEAD. Using existing data." >> "$REPORT"
elif [ "$DIRTY_COUNT" -gt 0 ]; then
  echo "Git sync skipped: working tree dirty (${DIRTY_COUNT} change(s)). Using existing data." >> "$REPORT"
elif [ "$BEHIND" != "0" ] && [ "$BEHIND" != "?" ]; then
  if git pull --ff-only origin "$BRANCH" 2>/dev/null; then
    echo "Training data synced to latest." >> "$REPORT"
    BEHIND="0"
  else
    echo "Git pull failed. Using existing data." >> "$REPORT"
  fi
else
  echo "Training data already up to date." >> "$REPORT"
fi
echo "- Repo root: $APP_DIR" >> "$REPORT"
echo "- Branch: $BRANCH" >> "$REPORT"
echo "- Dirty files: $DIRTY_COUNT" >> "$REPORT"
echo "- Behind origin: $BEHIND" >> "$REPORT"
echo "- Ahead of origin: $AHEAD" >> "$REPORT"

# Validate training data exists
if [ ! -f "$TRAIN_DIR/train.jsonl" ]; then
  echo "**ERROR:** train.jsonl not found at $TRAIN_DIR" >> "$REPORT"
  echo "- App dir: $APP_DIR" >> "$REPORT"
  echo "- Working directory: $(pwd)" >> "$REPORT"
  echo "- training_data contents:" >> "$REPORT"
  ls -la "$TRAIN_DIR" >> "$REPORT" 2>&1 || echo "  (training_data directory missing)" >> "$REPORT"
  echo "- Git status:" >> "$REPORT"
  git status --short --branch >> "$REPORT" 2>&1 || echo "  (git status unavailable)" >> "$REPORT"
  echo "Training data missing" >&2
  exit 1
fi
if [ ! -f "$TRAIN_DIR/valid.jsonl" ]; then
  echo "**ERROR:** valid.jsonl not found at $TRAIN_DIR" >> "$REPORT"
  echo "- App dir: $APP_DIR" >> "$REPORT"
  echo "- Working directory: $(pwd)" >> "$REPORT"
  echo "- training_data contents:" >> "$REPORT"
  ls -la "$TRAIN_DIR" >> "$REPORT" 2>&1 || echo "  (training_data directory missing)" >> "$REPORT"
  echo "- Git status:" >> "$REPORT"
  git status --short --branch >> "$REPORT" 2>&1 || echo "  (git status unavailable)" >> "$REPORT"
  echo "Validation data missing" >&2
  exit 1
fi

TRAIN_EXAMPLES=$(wc -l < "$TRAIN_DIR/train.jsonl" | tr -d ' ')
VALID_EXAMPLES=$(wc -l < "$TRAIN_DIR/valid.jsonl" | tr -d ' ')

if [ "$TRAIN_EXAMPLES" -eq 0 ] || [ "$VALID_EXAMPLES" -eq 0 ]; then
  echo "**ERROR:** Training data is empty (train: $TRAIN_EXAMPLES, valid: $VALID_EXAMPLES)" >> "$REPORT"
  exit 1
fi
echo "- Training examples: $TRAIN_EXAMPLES" >> "$REPORT"
echo "- Validation examples: $VALID_EXAMPLES" >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Step 2: Download base model if needed
# =============================================================================
echo "## Model Setup" >> "$REPORT"
echo "" >> "$REPORT"

# Model selection: CLI flag > config file > default
if [ -n "$BASE_MODEL_OVERRIDE" ]; then
  BASE_MODEL="$BASE_MODEL_OVERRIDE"
elif [ -n "$CONFIG_OVERRIDE" ]; then
  # Read model from config YAML (simple grep, no yq dependency)
  CONFIG_PATH="$CONFIG_OVERRIDE"
  if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="$TRAIN_DIR/$CONFIG_OVERRIDE"
  fi
  if [ -f "$CONFIG_PATH" ]; then
    MODEL_FROM_CONFIG=$(grep '^model:' "$CONFIG_PATH" | sed 's/model:[[:space:]]*//' | tr -d '"' | tr -d "'")
    if [ -n "$MODEL_FROM_CONFIG" ]; then
      BASE_MODEL="$MODEL_FROM_CONFIG"
    else
      BASE_MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit"
    fi
  else
    BASE_MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit"
  fi
else
  BASE_MODEL="mlx-community/Llama-3.2-3B-Instruct-4bit"
fi

if [ "$CHALLENGER_MODE" = true ]; then
  echo "Base model: $BASE_MODEL **(CHALLENGER)**" >> "$REPORT"
else
  echo "Base model: $BASE_MODEL" >> "$REPORT"
fi

if [ -z "${MODEL_SHORT:-}" ]; then
  MODEL_SHORT=$(echo "$BASE_MODEL" | sed 's|.*/||' | sed 's/-MLX-4bit//' | sed 's/-4bit//' | tr '[:upper:]' '[:lower:]')
fi

HISTORY_DIR="$OUTPUT_DIR/history/$APP_NAME"
mkdir -p "$HISTORY_DIR"
if [ "$CHALLENGER_MODE" = true ]; then
  REPORT_ARCHIVE="$HISTORY_DIR/${MODE_LABEL}_${MODEL_SHORT}_${TIMESTAMP_FILE}.md"
else
  REPORT_ARCHIVE="$HISTORY_DIR/${MODE_LABEL}_${APP_NAME}_${TIMESTAMP_FILE}.md"
fi
METRICS_FILE="$HISTORY_DIR/training_metrics_workflow_v1.tsv"
append_metrics_header_if_needed
READINESS_FILE=""
if [ -n "$READINESS_TARGET_APP" ]; then
  READINESS_FILE="$HISTORY_DIR/readiness_vs_${READINESS_TARGET_APP}_workflow_v1.tsv"
  append_readiness_header_if_needed
fi

echo "## Dataset Guard" >> "$REPORT"
echo "" >> "$REPORT"
echo "- Allowed train drop vs latest successful $MODE_LABEL run: ${TRAIN_EXAMPLE_DROP_MAX_PCT}%" >> "$REPORT"
echo "- Allowed valid drop vs latest successful $MODE_LABEL run: ${VALID_EXAMPLE_DROP_MAX_PCT}%" >> "$REPORT"

DATASET_BASELINE_LINE=$(find_latest_successful_metric_for_mode 2>/dev/null || true)
if [ -n "$DATASET_BASELINE_LINE" ]; then
  BASELINE_TIMESTAMP=$(printf '%s\n' "$DATASET_BASELINE_LINE" | awk -F '\t' '{print $4}')
  BASELINE_MODEL=$(printf '%s\n' "$DATASET_BASELINE_LINE" | awk -F '\t' '{print $3}')
  BASELINE_TRAIN_EXAMPLES=$(printf '%s\n' "$DATASET_BASELINE_LINE" | awk -F '\t' '{print $5}')
  BASELINE_VALID_EXAMPLES=$(printf '%s\n' "$DATASET_BASELINE_LINE" | awk -F '\t' '{print $6}')
  MIN_ALLOWED_TRAIN=$((BASELINE_TRAIN_EXAMPLES * (100 - TRAIN_EXAMPLE_DROP_MAX_PCT) / 100))
  MIN_ALLOWED_VALID=$((BASELINE_VALID_EXAMPLES * (100 - VALID_EXAMPLE_DROP_MAX_PCT) / 100))

  echo "- Baseline success: $BASELINE_TIMESTAMP ($BASELINE_MODEL)" >> "$REPORT"
  echo "- Baseline train/valid: ${BASELINE_TRAIN_EXAMPLES} / ${BASELINE_VALID_EXAMPLES}" >> "$REPORT"
  echo "- Minimum allowed train/valid: ${MIN_ALLOWED_TRAIN} / ${MIN_ALLOWED_VALID}" >> "$REPORT"

  if [ "$TRAIN_EXAMPLES" -lt "$MIN_ALLOWED_TRAIN" ]; then
    dataset_guard_failed "Dataset guard failed: train examples dropped to ${TRAIN_EXAMPLES} from ${BASELINE_TRAIN_EXAMPLES} (allowed minimum ${MIN_ALLOWED_TRAIN})."
  fi

  if [ "$VALID_EXAMPLES" -lt "$MIN_ALLOWED_VALID" ]; then
    dataset_guard_failed "Dataset guard failed: validation examples dropped to ${VALID_EXAMPLES} from ${BASELINE_VALID_EXAMPLES} (allowed minimum ${MIN_ALLOWED_VALID})."
  fi
else
  echo "- No prior successful $MODE_LABEL metrics found. Skipping drop guard." >> "$REPORT"
fi

echo "- Current train/valid: ${TRAIN_EXAMPLES} / ${VALID_EXAMPLES}" >> "$REPORT"
echo "- Result: PASS" >> "$REPORT"
echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# Check if model is cached
if "$PYTHON" -c "from huggingface_hub import scan_cache_dir; cache = scan_cache_dir(); models = [r.repo_id for r in cache.repos]; print('CACHED' if '$BASE_MODEL' in models else 'NEED_DOWNLOAD')" 2>/dev/null | grep -q "CACHED"; then
  echo "Status: Cached locally" >> "$REPORT"
else
  echo "Status: Downloading (first run only)..." >> "$REPORT"
  "$PYTHON" -c "from huggingface_hub import snapshot_download; snapshot_download('$BASE_MODEL')" 2>&1 | tail -3 >> "$REPORT"
fi

echo "" >> "$REPORT"
echo "---" >> "$REPORT"
echo "" >> "$REPORT"

# =============================================================================
# Step 3: Training sweeps
# =============================================================================
echo "## Training Sweeps" >> "$REPORT"
echo "" >> "$REPORT"

BASE_CONFIG="$(resolve_base_config)"

# Sweep defaults predate the workflow-expanded corpus. The Mini now relies on
# earlier checkpoints plus interrupted-checkpoint eval so nightly runs still
# produce usable signal even when the hard stop hits before a full sweep.
SWEEP_ITERS=()
RESULTS_FILE=$(mktemp)
SUCCESSFUL_SWEEPS=0
LAST_SWEEP_LOG=""
LAST_FAILURE_SUMMARY=""
SKIPPED_EXISTING_SWEEPS=0
REQUESTED_SWEEPS=0

if [ ! -f "$BASE_CONFIG" ]; then
  echo "**FAILED** — config not found: $BASE_CONFIG" >> "$REPORT"
  echo "" >> "$REPORT"
  LAST_FAILURE_SUMMARY="config not found: $BASE_CONFIG"
else
  build_sweep_iters "$BASE_CONFIG"
fi

for ITERS in "${SWEEP_ITERS[@]}"; do
  REQUESTED_SWEEPS=$((REQUESTED_SWEEPS + 1))
  if is_past_hard_stop_time; then
    echo "" >> "$REPORT"
    echo "**Stopped before ${ITERS} iterations** — reached hard stop time (${TRAIN_HARD_STOP_TIME})." >> "$REPORT"
    break
  fi

  BUDGET_SECONDS=$(remaining_budget_seconds)
  if [ "$BUDGET_SECONDS" -ne -1 ] && [ "$BUDGET_SECONDS" -le 0 ]; then
    echo "" >> "$REPORT"
    echo "**Stopped before ${ITERS} iterations** — runtime budget exhausted (${MAX_TRAIN_RUNTIME_MIN} min)." >> "$REPORT"
    break
  fi

  # Challenger sweeps get a model-prefixed directory to avoid collisions
  if [ "$CHALLENGER_MODE" = true ] && [ -n "$BASE_MODEL_OVERRIDE" ]; then
    SWEEP_NAME="challenger_${MODEL_SHORT}_${ITERS}_${DATE}"
  else
    SWEEP_NAME="sweep_${ITERS}_${DATE}"
  fi
  ADAPTER_DIR="$MODELS_DIR/sweeps/$SWEEP_NAME"
  LAST_SWEEP_LOG="$ADAPTER_DIR/train.log"

  echo "### ${ITERS} iterations" >> "$REPORT"
  echo "" >> "$REPORT"

  # Skip if already trained today
  if [ -f "$ADAPTER_DIR/adapter_config.json" ]; then
    echo "Already trained today. Skipping." >> "$REPORT"
    echo "" >> "$REPORT"
    SKIPPED_EXISTING_SWEEPS=$((SKIPPED_EXISTING_SWEEPS + 1))
    continue
  fi

  mkdir -p "$ADAPTER_DIR"

  TRAIN_START=$(date +%s)

  # Generate per-sweep config with decay_steps matching this sweep's iteration count.
  # The base YAML also carries warmup tuned for its default length, so rescale it
  # whenever we shorten the sweep for the overnight Mini budget.
  SWEEP_CONFIG="$ADAPTER_DIR/lora_config_sweep.yaml"
  WARMUP_STEPS=$(warmup_steps_for_sweep "$BASE_CONFIG" "$ITERS")

  sed -E \
    -e "s/^(iters: )[0-9]+/\\1$ITERS/" \
    -e "s/^([[:space:]]*arguments: \\[[^,]+, )[0-9]+(\\])$/\\1$ITERS\\2/" \
    -e "s/^([[:space:]]*warmup: )[0-9]+/\\1$WARMUP_STEPS/" \
    "$BASE_CONFIG" > "$SWEEP_CONFIG"

  # Verify the config was generated and has the correct schedule for this sweep.
  if [ ! -s "$SWEEP_CONFIG" ] || \
     ! grep -Eq "^iters: $ITERS([[:space:]]+#.*)?\$" "$SWEEP_CONFIG" || \
     ! grep -Eq "^[[:space:]]*arguments: \\[[^,]+, $ITERS\\]([[:space:]]+#.*)?\$" "$SWEEP_CONFIG" || \
     ! grep -Eq "^[[:space:]]*warmup: $WARMUP_STEPS([[:space:]]+#.*)?\$" "$SWEEP_CONFIG"; then
    echo "**FAILED** — could not generate sweep config (sed failed)" >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  echo "- Sweep schedule: warmup=${WARMUP_STEPS}, decay_steps=${ITERS}" >> "$REPORT"
  echo "" >> "$REPORT"

  STEPS_PER_EVAL=$(grep '^steps_per_eval:' "$SWEEP_CONFIG" | awk '{print $2}' | tail -1)
  if ! [[ "$STEPS_PER_EVAL" =~ ^[0-9]+$ ]]; then
    STEPS_PER_EVAL=100
  fi

  VAL_BATCHES=$(grep '^val_batches:' "$SWEEP_CONFIG" | awk '{print $2}' | tail -1)
  if ! [[ "$VAL_BATCHES" =~ ^[0-9]+$ ]]; then
    VAL_BATCHES=10
  fi

  # Run training (mlx-lm 0.30+ syntax)
  # YAML config provides: LoRA params (rank=16, dropout=0.05, scale=32),
  # LR schedule (warmup → 5e-5 → cosine decay over full sweep), batch_size=1
  # CLI overrides: iters (per sweep), adapter-path. Eval settings come from config.
  nice -n 15 "$PYTHON" -m mlx_lm lora \
    --train \
    --model "$BASE_MODEL" \
    --data "$TRAIN_DIR" \
    -c "$SWEEP_CONFIG" \
    --iters "$ITERS" \
    --steps-per-eval "$STEPS_PER_EVAL" \
    --val-batches "$VAL_BATCHES" \
    --adapter-path "$ADAPTER_DIR" \
    > "$ADAPTER_DIR/train.log" 2>&1 &
  TRAIN_PID=$!
  init_training_progress_watch "$ADAPTER_DIR/train.log" "$TRAIN_PID"

  TRAIN_EXIT=""
  while is_active_pid "$TRAIN_PID"; do
    if is_past_hard_stop_time; then
      echo "Stopping training at hard stop time (${TRAIN_HARD_STOP_TIME})." >> "$ADAPTER_DIR/train.log"
      kill -TERM "$TRAIN_PID" 2>/dev/null || true
      sleep 3
      kill -KILL "$TRAIN_PID" 2>/dev/null || true
      TRAIN_EXIT=124
      break
    fi

    BUDGET_SECONDS=$(remaining_budget_seconds)
    if [ "$BUDGET_SECONDS" -ne -1 ] && [ "$BUDGET_SECONDS" -le 0 ]; then
      echo "Stopping training: runtime budget exceeded (${MAX_TRAIN_RUNTIME_MIN} min)." >> "$ADAPTER_DIR/train.log"
      kill -TERM "$TRAIN_PID" 2>/dev/null || true
      sleep 3
      kill -KILL "$TRAIN_PID" 2>/dev/null || true
      TRAIN_EXIT=124
      break
    fi

    if is_training_stalled "$ADAPTER_DIR/train.log" "$TRAIN_PID"; then
      echo "Stopping training: no log progress for ${TRAIN_STALL_TIMEOUT_MIN} minutes." >> "$ADAPTER_DIR/train.log"
      kill -TERM "$TRAIN_PID" 2>/dev/null || true
      sleep 3
      kill -KILL "$TRAIN_PID" 2>/dev/null || true
      TRAIN_EXIT=125
      break
    fi

    sleep "$TRAIN_POLL_INTERVAL_SEC"
  done

  if [ -z "$TRAIN_EXIT" ]; then
    wait "$TRAIN_PID"
    TRAIN_EXIT=$?
  fi

  if [ "$TRAIN_EXIT" -eq 0 ] && training_log_has_invalid_metrics "$ADAPTER_DIR/train.log"; then
    TRAIN_EXIT=126
  fi

  # Extract key training metrics for report
  grep -E "^Iter|^Saved" "$ADAPTER_DIR/train.log" | tail -10 >> "$REPORT"
  TRAIN_END=$(date +%s)
  TRAIN_TIME=$(( (TRAIN_END - TRAIN_START) / 60 ))

  echo "" >> "$REPORT"

  if [ $TRAIN_EXIT -ne 0 ]; then
    echo "**FAILED** (exit $TRAIN_EXIT, ${TRAIN_TIME}min)" >> "$REPORT"
    if [ "$TRAIN_EXIT" -eq 124 ]; then
      echo "Stopped by runtime guard (hard stop time or runtime budget)." >> "$REPORT"
      LAST_FAILURE_SUMMARY="runtime guard stopped ${ITERS}-iteration sweep (exit 124)"
    elif [ "$TRAIN_EXIT" -eq 125 ]; then
      echo "Stopped by stall guard after no log progress for ${TRAIN_STALL_TIMEOUT_MIN} minutes." >> "$REPORT"
      LAST_FAILURE_SUMMARY="stalled after ${TRAIN_STALL_TIMEOUT_MIN} minutes with no log progress during ${ITERS}-iteration sweep"
    elif [ "$TRAIN_EXIT" -eq 126 ]; then
      echo "Stopped because training produced invalid metrics (nan loss or zero trained tokens)." >> "$REPORT"
      LAST_FAILURE_SUMMARY="invalid training metrics detected during ${ITERS}-iteration sweep"
    else
      LAST_FAILURE_SUMMARY="training process exited $TRAIN_EXIT during ${ITERS}-iteration sweep"
    fi
    if [ -f "$ADAPTER_DIR/train.log" ]; then
      echo "" >> "$REPORT"
      echo "Last training log lines:" >> "$REPORT"
      echo '```' >> "$REPORT"
      tail -n "$TRAIN_FAILURE_LOG_LINES" "$ADAPTER_DIR/train.log" >> "$REPORT"
      echo '```' >> "$REPORT"
    fi

    if [ "$PARTIAL_CHECKPOINT_EVAL" = "true" ] && [ -f "$ADAPTER_DIR/adapters.safetensors" ]; then
      CHECKPOINT_STEP=$(latest_saved_checkpoint_step "$ADAPTER_DIR")
      if [ "$CHECKPOINT_STEP" -gt 0 ]; then
        RESULT_DISPLAY_LABEL="checkpoint ${CHECKPOINT_STEP}/${ITERS}"
      else
        RESULT_DISPLAY_LABEL="checkpoint latest/${ITERS}"
      fi

      echo "" >> "$REPORT"
      echo "**Interrupted checkpoint evaluation:** $RESULT_DISPLAY_LABEL" >> "$REPORT"
      PARTIAL_EVAL_LOG="$ADAPTER_DIR/eval_partial.log"
      rm -f "$PARTIAL_EVAL_LOG"

      if [ -f "$EVAL_SCRIPT" ]; then
        build_eval_command "$BASE_MODEL" "$ADAPTER_DIR"
        VALIDATION_OUTPUT=$("${EVAL_CMD[@]}" 2>&1)
      else
        VALIDATION_OUTPUT=""
      fi
      VALIDATE_EXIT=$?
      printf '%s\n' "$VALIDATION_OUTPUT" > "$PARTIAL_EVAL_LOG"

      if [ $VALIDATE_EXIT -ne 0 ] || [ -z "$VALIDATION_OUTPUT" ]; then
        echo "  - Interrupted checkpoint eval failed (exit $VALIDATE_EXIT)" >> "$REPORT"
        if [ -f "$PARTIAL_EVAL_LOG" ]; then
          echo "  - Eval log: $PARTIAL_EVAL_LOG" >> "$REPORT"
          echo '```' >> "$REPORT"
          tail -n "$TRAIN_FAILURE_LOG_LINES" "$PARTIAL_EVAL_LOG" >> "$REPORT"
          echo '```' >> "$REPORT"
        fi
      else
        echo "$VALIDATION_OUTPUT" | grep -vE "^(SCORE:|RAW_SCORE:|WEIGHTED_SCORE:|PRIMARY_SUITE:|SUITE:)" >> "$REPORT"

        SUITE_LINES=$(echo "$VALIDATION_OUTPUT" | grep "^SUITE:" || true)
        if [ -n "$SUITE_LINES" ]; then
          echo "" >> "$REPORT"
          echo "  Suite scores:" >> "$REPORT"
          while IFS=: read -r _ SUITE_NAME SUITE_PASS SUITE_TOTAL SUITE_PCT; do
            DISPLAY_SUITE=$(echo "$SUITE_NAME" | tr '_' ' ')
            echo "  - $DISPLAY_SUITE: $SUITE_PASS/$SUITE_TOTAL ($SUITE_PCT%)" >> "$REPORT"
          done <<EOF
$SUITE_LINES
EOF
        fi

        parse_eval_summary "$VALIDATION_OUTPUT"
        PASS="$WEIGHTED_PASS"
        TOTAL="$WEIGHTED_TOTAL"
        ACCURACY="$WEIGHTED_ACCURACY"
        RAW_SCORE_VALUE="$RAW_ACCURACY"
        PRIMARY_SCORE_VALUE="$PRIMARY_PCT"
        if [ "$PRIMARY_STATUS" = "PASS" ] && [ "$ACCURACY" -ge "$WORKFLOW_PASS_SCORE" ]; then
          PARTIAL_VALIDATION_STATUS="PARTIAL PASS"
        else
          PARTIAL_VALIDATION_STATUS="PARTIAL NEEDS WORK"
        fi

        echo "" >> "$REPORT"
        echo "**Workflow gate:** $PRIMARY_STATUS ($PRIMARY_SUITE_NAME $PRIMARY_PASS/$PRIMARY_TOTAL, $PRIMARY_PCT%, threshold $PRIMARY_THRESHOLD%)" >> "$REPORT"
        echo "**Workflow-first score:** $PASS/$TOTAL ($ACCURACY%)" >> "$REPORT"
        echo "**Raw score:** $RAW_PASS/$RAW_TOTAL ($RAW_SCORE_VALUE%)" >> "$REPORT"
        echo "**Result:** $PARTIAL_VALIDATION_STATUS" >> "$REPORT"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$RESULT_DISPLAY_LABEL" \
          "$ACCURACY" \
          "$RAW_SCORE_VALUE" \
          "$PRIMARY_SCORE_VALUE" \
          "$PRIMARY_STATUS" \
          "$TRAIN_TIME" \
          "ok" \
          "$ADAPTER_DIR" \
          "partial" >> "$RESULTS_FILE"

        LAST_FAILURE_SUMMARY="${LAST_FAILURE_SUMMARY}; ${RESULT_DISPLAY_LABEL} reached ${ACCURACY}% workflow-first"
      fi
    fi
    prune_checkpoint_files "$ADAPTER_DIR" "$CHECKPOINT_FILES_TO_KEEP" "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  echo "**Completed** in ${TRAIN_TIME} minutes" >> "$REPORT"
  echo "" >> "$REPORT"
  SUCCESSFUL_SWEEPS=$((SUCCESSFUL_SWEEPS + 1))

  # =============================================================================
  # Step 4: Validate this checkpoint
  # =============================================================================
  echo "**Validation:**" >> "$REPORT"
  EVAL_LOG="$ADAPTER_DIR/eval.log"
  rm -f "$EVAL_LOG"

  if [ -f "$EVAL_SCRIPT" ]; then
    build_eval_command "$BASE_MODEL" "$ADAPTER_DIR"
    VALIDATION_OUTPUT=$("${EVAL_CMD[@]}" 2>&1)
    printf '%s\n' "$VALIDATION_OUTPUT" > "$EVAL_LOG"
  else
    VALIDATION_OUTPUT=""
  fi

  VALIDATE_EXIT=$?

  if [ $VALIDATE_EXIT -ne 0 ] || [ -z "$VALIDATION_OUTPUT" ]; then
    echo "  - Validation script failed (exit $VALIDATE_EXIT)" >> "$REPORT"
    if [ -f "$EVAL_LOG" ]; then
      echo "  - Eval log: $EVAL_LOG" >> "$REPORT"
      echo '```' >> "$REPORT"
      tail -n "$TRAIN_FAILURE_LOG_LINES" "$EVAL_LOG" >> "$REPORT"
      echo '```' >> "$REPORT"
    fi
    ACCURACY=0
    PASS=0
    TOTAL=0
    RAW_PASS=0
    RAW_TOTAL=0
    RAW_ACCURACY=0
    PRIMARY_PASS=0
    PRIMARY_TOTAL=0
    PRIMARY_PCT=0
    PRIMARY_STATUS="FAIL"
    PRIMARY_THRESHOLD="$PRIMARY_WORKFLOW_MIN_PCT"
    PRIMARY_SUITE_NAME="$PRIMARY_WORKFLOW_SUITE"
    VALIDATION_ROW_STATUS="error"
    LAST_FAILURE_SUMMARY="validation failed with exit $VALIDATE_EXIT during ${ITERS}-iteration sweep"
  else
    # Write individual results to report
    echo "$VALIDATION_OUTPUT" | grep -vE "^(SCORE:|RAW_SCORE:|WEIGHTED_SCORE:|PRIMARY_SUITE:|SUITE:)" >> "$REPORT"

    SUITE_LINES=$(echo "$VALIDATION_OUTPUT" | grep "^SUITE:" || true)
    if [ -n "$SUITE_LINES" ]; then
      echo "" >> "$REPORT"
      echo "  Suite scores:" >> "$REPORT"
      while IFS=: read -r _ SUITE_NAME SUITE_PASS SUITE_TOTAL SUITE_PCT; do
        DISPLAY_SUITE=$(echo "$SUITE_NAME" | tr '_' ' ')
        echo "  - $DISPLAY_SUITE: $SUITE_PASS/$SUITE_TOTAL ($SUITE_PCT%)" >> "$REPORT"
      done <<EOF
$SUITE_LINES
EOF
    fi

    parse_eval_summary "$VALIDATION_OUTPUT"
    PASS="$WEIGHTED_PASS"
    TOTAL="$WEIGHTED_TOTAL"
    ACCURACY="$WEIGHTED_ACCURACY"
    VALIDATION_ROW_STATUS="ok"
  fi

  echo "" >> "$REPORT"
  echo "**Workflow gate:** $PRIMARY_STATUS ($PRIMARY_SUITE_NAME $PRIMARY_PASS/$PRIMARY_TOTAL, $PRIMARY_PCT%, threshold $PRIMARY_THRESHOLD%)" >> "$REPORT"
  echo "**Workflow-first score:** $PASS/$TOTAL ($ACCURACY%)" >> "$REPORT"
  echo "**Raw score:** $RAW_PASS/$RAW_TOTAL ($RAW_ACCURACY%)" >> "$REPORT"
  if [ "$PRIMARY_STATUS" = "PASS" ] && [ "$ACCURACY" -ge "$WORKFLOW_PASS_SCORE" ]; then
    VALIDATION_STATUS="PASS"
  else
    VALIDATION_STATUS="NEEDS WORK"
  fi
  echo "**Result:** $VALIDATION_STATUS" >> "$REPORT"
  echo "" >> "$REPORT"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ITERS" \
    "$ACCURACY" \
    "$RAW_ACCURACY" \
    "$PRIMARY_PCT" \
    "$PRIMARY_STATUS" \
    "$TRAIN_TIME" \
    "$VALIDATION_ROW_STATUS" \
    "$ADAPTER_DIR" \
    "complete" >> "$RESULTS_FILE"
  prune_checkpoint_files "$ADAPTER_DIR" "$CHECKPOINT_FILES_TO_KEEP" "$REPORT"
done

# =============================================================================
# Step 5: Summary — find the best adapter
# =============================================================================
echo "---" >> "$REPORT"
echo "" >> "$REPORT"
echo "## Summary" >> "$REPORT"
echo "" >> "$REPORT"
echo "| Iterations | Workflow score | Raw score | Primary suite | Time (min) | Status |" >> "$REPORT"
echo "|-----------|----------------|-----------|---------------|------------|--------|" >> "$REPORT"

BEST_ITERS=""
BEST_ADAPTER_DIR=""
BEST_COMPLETION_STATE=""
BEST_ACCURACY=0
BEST_RAW_ACCURACY=0
BEST_PRIMARY_PCT=0
BEST_PRIMARY_STATUS="FAIL"
BEST_TIME_MIN=""
SCRIPT_EXIT=0

while IFS=$'\t' read -r iters acc raw_acc primary_pct primary_status time validation_row_status adapter_dir completion_state; do
  if [ "$validation_row_status" != "ok" ]; then
    status="VALIDATION FAIL"
  elif [ "$completion_state" = "partial" ] && [ "$primary_status" = "PASS" ] && [ "$acc" -ge "$WORKFLOW_PASS_SCORE" ]; then
    status="PARTIAL PASS"
  elif [ "$completion_state" = "partial" ] && [ "$primary_status" = "PASS" ]; then
    status="PARTIAL LOW SCORE"
  elif [ "$completion_state" = "partial" ]; then
    status="PARTIAL WORKFLOW GATE FAIL"
  elif [ "$primary_status" = "PASS" ] && [ "$acc" -ge "$WORKFLOW_PASS_SCORE" ]; then
    status="PASS"
  elif [ "$primary_status" = "PASS" ]; then
    status="LOW SCORE"
  else
    status="WORKFLOW GATE FAIL"
  fi
  echo "| $iters | $acc% | $raw_acc% | $primary_pct% | $time | $status |" >> "$REPORT"

  if [ "$validation_row_status" = "ok" ] && \
     { [ -z "$BEST_ITERS" ] || [ "$acc" -gt "$BEST_ACCURACY" ] || \
       { [ "$acc" -eq "$BEST_ACCURACY" ] && [ "$primary_pct" -gt "$BEST_PRIMARY_PCT" ]; } || \
       { [ "$acc" -eq "$BEST_ACCURACY" ] && [ "$primary_pct" -eq "$BEST_PRIMARY_PCT" ] && [ "$raw_acc" -gt "$BEST_RAW_ACCURACY" ]; }; }; then
    BEST_ACCURACY=$acc
    BEST_RAW_ACCURACY=$raw_acc
    BEST_PRIMARY_PCT=$primary_pct
    BEST_PRIMARY_STATUS=$primary_status
    BEST_ITERS=$iters
    BEST_ADAPTER_DIR="$adapter_dir"
    BEST_COMPLETION_STATE="$completion_state"
    BEST_TIME_MIN=$time
  fi
done < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"

echo "" >> "$REPORT"

if [ -n "$BEST_ITERS" ]; then
  if [ "$BEST_COMPLETION_STATE" = "partial" ]; then
    echo "**Best evaluated checkpoint: $(basename "$BEST_ADAPTER_DIR") ($BEST_ITERS, $BEST_ACCURACY% workflow-first, $BEST_RAW_ACCURACY% raw)**" >> "$REPORT"
    echo "**Checkpoint state:** Interrupted run. Use as directional signal only until a full sweep completes." >> "$REPORT"
  else
    echo "**Best adapter: $(basename "$BEST_ADAPTER_DIR") ($BEST_ACCURACY% workflow-first, $BEST_RAW_ACCURACY% raw)**" >> "$REPORT"
  fi
  echo "**Workflow gate:** $BEST_PRIMARY_STATUS (${PRIMARY_WORKFLOW_SUITE} ${BEST_PRIMARY_PCT}%, threshold ${PRIMARY_WORKFLOW_MIN_PCT}%)" >> "$REPORT"

  # Auto-promote if it clears the workflow gate and beats the promotion target.
  # NEVER auto-promote challengers — report only, human decides
  if [ "$CHALLENGER_MODE" = true ]; then
    echo "" >> "$REPORT"
    if [ "$BEST_PRIMARY_STATUS" != "PASS" ]; then
      echo "**CHALLENGER RESULT: $BEST_ACCURACY% — workflow gate failed.**" >> "$REPORT"
      echo "Model: $BASE_MODEL" >> "$REPORT"
      echo "Primary suite: ${PRIMARY_WORKFLOW_SUITE} ${BEST_PRIMARY_PCT}% (threshold ${PRIMARY_WORKFLOW_MIN_PCT}%)" >> "$REPORT"
      if [ "$BEST_COMPLETION_STATE" != "complete" ]; then
        echo "Checkpoint source: interrupted run ($BEST_ITERS)." >> "$REPORT"
      fi
    elif [ "$BEST_ACCURACY" -ge "$PRODUCTION_PROMOTE_SCORE" ]; then
      echo "**CHALLENGER RESULT: $BEST_ACCURACY% — BEATS WORKFLOW BASELINE!**" >> "$REPORT"
      echo "Model: $BASE_MODEL" >> "$REPORT"
      echo "Adapter: $(basename "$BEST_ADAPTER_DIR")" >> "$REPORT"
      if [ "$BEST_COMPLETION_STATE" != "complete" ]; then
        echo "Checkpoint source: interrupted run ($BEST_ITERS). Treat this as directional until a full sweep finishes." >> "$REPORT"
      fi
      echo "Action required: Human review needed to promote to production." >> "$REPORT"
    else
      echo "**CHALLENGER RESULT: $BEST_ACCURACY% — below workflow baseline.**" >> "$REPORT"
      echo "Model: $BASE_MODEL" >> "$REPORT"
      echo "Primary suite: ${PRIMARY_WORKFLOW_SUITE} ${BEST_PRIMARY_PCT}% (threshold ${PRIMARY_WORKFLOW_MIN_PCT}%)" >> "$REPORT"
      if [ "$BEST_COMPLETION_STATE" != "complete" ]; then
        echo "Checkpoint source: interrupted run ($BEST_ITERS)." >> "$REPORT"
      fi
    fi
  elif [ "$BEST_COMPLETION_STATE" != "complete" ]; then
    echo "" >> "$REPORT"
    echo "**Auto-promotion skipped:** interrupted checkpoint only. Require a fully completed sweep before production promotion." >> "$REPORT"
  elif [ "$BEST_PRIMARY_STATUS" = "PASS" ] && [ "$BEST_ACCURACY" -ge "$PRODUCTION_PROMOTE_SCORE" ]; then
    PROD_DIR="$MODELS_DIR/production_adapter"
    mkdir -p "$PROD_DIR"
    cp -r "$BEST_ADAPTER_DIR/"* "$PROD_DIR/"
    echo "" >> "$REPORT"
    echo "**Auto-promoted to production!** Workflow-first score $BEST_ACCURACY% cleared the ${PRODUCTION_PROMOTE_SCORE}% promotion target." >> "$REPORT"
    echo "Adapter: $(basename "$BEST_ADAPTER_DIR") -> production_adapter/" >> "$REPORT"
  fi
else
  if [ "$REQUESTED_SWEEPS" -gt 0 ] && [ "$SKIPPED_EXISTING_SWEEPS" -eq "$REQUESTED_SWEEPS" ]; then
    echo "**No new sweeps ran.** All requested adapters already existed for today." >> "$REPORT"
    SCRIPT_EXIT=0
  else
    echo "**No successful training runs.**" >> "$REPORT"
    SCRIPT_EXIT=1
  fi
fi

echo "" >> "$REPORT"

PREVIOUS_SUCCESS_LINE=""
if [ -n "$BEST_ITERS" ]; then
  PREVIOUS_SUCCESS_LINE=$(find_previous_successful_metric 2>/dev/null || true)
fi
READINESS_STATUS=""
READINESS_TARGET_MODEL=""
READINESS_TARGET_ACCURACY=""
READINESS_TARGET_REPORT=""
READINESS_DELTA=""

echo "## Metrics" >> "$REPORT"
echo "" >> "$REPORT"
echo "- Successful sweeps this run: $SUCCESSFUL_SWEEPS" >> "$REPORT"
echo "- Archived report: $REPORT_ARCHIVE" >> "$REPORT"
echo "- Metrics history: $METRICS_FILE" >> "$REPORT"
echo "" >> "$REPORT"

if [ -n "$PREVIOUS_SUCCESS_LINE" ]; then
  PREV_TIMESTAMP=$(printf '%s\n' "$PREVIOUS_SUCCESS_LINE" | awk -F '\t' '{print $4}')
  PREV_BEST_ITERS=$(printf '%s\n' "$PREVIOUS_SUCCESS_LINE" | awk -F '\t' '{print $7}')
  PREV_BEST_ACCURACY=$(printf '%s\n' "$PREVIOUS_SUCCESS_LINE" | awk -F '\t' '{print $8}')
  PREV_BEST_TIME_MIN=$(printf '%s\n' "$PREVIOUS_SUCCESS_LINE" | awk -F '\t' '{print $9}')
  PREV_SUCCESSFUL_SWEEPS=$(printf '%s\n' "$PREVIOUS_SUCCESS_LINE" | awk -F '\t' '{print $10}')
  ACC_DELTA=$((BEST_ACCURACY - PREV_BEST_ACCURACY))

  echo "## Progress vs Previous Successful Run" >> "$REPORT"
  echo "" >> "$REPORT"
  echo "- Previous success: $PREV_TIMESTAMP" >> "$REPORT"
  echo "- Previous workflow-first best: ${PREV_BEST_ACCURACY}% at ${PREV_BEST_ITERS} iterations (${PREV_BEST_TIME_MIN} min)" >> "$REPORT"
  echo "- Workflow-first delta: ${ACC_DELTA}% points" >> "$REPORT"
  echo "- Successful sweeps delta: $((SUCCESSFUL_SWEEPS - PREV_SUCCESSFUL_SWEEPS))" >> "$REPORT"
  echo "" >> "$REPORT"
else
  echo "## Progress vs Previous Successful Run" >> "$REPORT"
  echo "" >> "$REPORT"
  echo "- No previous successful run recorded for $APP_NAME / $MODE_LABEL / $BASE_MODEL." >> "$REPORT"
  echo "" >> "$REPORT"
fi

if [ -n "$READINESS_TARGET_APP" ]; then
  echo "## Readiness for $READINESS_TARGET_APP" >> "$REPORT"
  echo "" >> "$REPORT"

  if [ -z "$BEST_ITERS" ]; then
    READINESS_STATUS="source_failed"
    echo "- No readiness assessment because this run produced no successful adapter." >> "$REPORT"
  elif [ "$BEST_COMPLETION_STATE" != "complete" ] || [ "$SCRIPT_EXIT" -ne 0 ]; then
    READINESS_STATUS="source_incomplete"
    echo "- No readiness assessment because the best evaluated result came from an interrupted run." >> "$REPORT"
  else
    TARGET_BASELINE_MODE=""
    TARGET_PRODUCTION_LINE=$(find_latest_target_baseline_metric "$READINESS_TARGET_APP" 2>/dev/null || true)
    if [ -z "$TARGET_PRODUCTION_LINE" ]; then
      READINESS_STATUS="missing_target_baseline"
      echo "- No production baseline found for $READINESS_TARGET_APP in $OUTPUT_DIR/history/$READINESS_TARGET_APP/training_metrics.tsv." >> "$REPORT"
    else
      READINESS_TARGET_MODEL=$(printf '%s\n' "$TARGET_PRODUCTION_LINE" | awk -F '\t' '{print $3}')
      READINESS_TARGET_ACCURACY=$(printf '%s\n' "$TARGET_PRODUCTION_LINE" | awk -F '\t' '{print $8}')
      READINESS_TARGET_REPORT=$(printf '%s\n' "$TARGET_PRODUCTION_LINE" | awk -F '\t' '{print $13}')
      READINESS_DELTA=$((BEST_ACCURACY - READINESS_TARGET_ACCURACY))

      if [ "$BEST_PRIMARY_STATUS" != "PASS" ]; then
        READINESS_STATUS="workflow_gate_failed"
        READINESS_NOTE="Workflow gate failed, so this run is not a valid replacement candidate."
      elif [ "$TARGET_BASELINE_MODE" != "production" ]; then
        READINESS_STATUS="missing_target_production_baseline"
        READINESS_NOTE="Compared against the latest successful $READINESS_TARGET_APP ${TARGET_BASELINE_MODE} run for reference only. Record a production baseline before using this as a replacement gate."
      elif [ "$BEST_ACCURACY" -ge "$READINESS_TARGET_ACCURACY" ]; then
        READINESS_STATUS="ready"
        READINESS_NOTE="Meets or beats the latest $READINESS_TARGET_APP production score on the same validation harness."
      elif [ "$BEST_ACCURACY" -ge $((READINESS_TARGET_ACCURACY - 3)) ]; then
        READINESS_STATUS="shadow_eval"
        READINESS_NOTE="Within 3 points of the latest $READINESS_TARGET_APP production score. Good candidate for shadow evaluation, not replacement yet."
      else
        READINESS_STATUS="not_ready"
        READINESS_NOTE="Still too far behind the latest $READINESS_TARGET_APP production score to replace it."
      fi

      echo "- Target baseline model: $READINESS_TARGET_MODEL" >> "$REPORT"
      echo "- Target baseline mode: ${TARGET_BASELINE_MODE:-unknown}" >> "$REPORT"
      echo "- Target baseline workflow-first score: ${READINESS_TARGET_ACCURACY}% ($READINESS_TARGET_APP ${TARGET_BASELINE_MODE:-unknown})" >> "$REPORT"
      echo "- Source workflow-first score: ${BEST_ACCURACY}% ($APP_NAME $MODE_LABEL)" >> "$REPORT"
      echo "- Source primary suite: ${PRIMARY_WORKFLOW_SUITE} ${BEST_PRIMARY_PCT}% (status $BEST_PRIMARY_STATUS)" >> "$REPORT"
      echo "- Delta vs target: ${READINESS_DELTA}% points" >> "$REPORT"
      echo "- Status: $READINESS_STATUS" >> "$REPORT"
      echo "- Decision hint: $READINESS_NOTE" >> "$REPORT"
      if [ -n "$READINESS_TARGET_REPORT" ]; then
        echo "- Target report: $READINESS_TARGET_REPORT" >> "$REPORT"
      fi
    fi
  fi

  echo "" >> "$REPORT"
fi

# =============================================================================
# Step 6: Prune old sweeps (default keep last 3 days)
# =============================================================================
prune_old_sweeps "$REPORT"

# Footer
cat >> "$REPORT" <<EOF

---

**Report generated:** $(date +"%Y-%m-%d %H:%M:%S")
**Training data:** $TRAIN_EXAMPLES examples (train), $VALID_EXAMPLES (validation)
**Base model:** $BASE_MODEL
**Next scheduled lane:** $NEXT_RUN_HINT
EOF

cp "$REPORT" "$REPORT_ARCHIVE"

RUN_STATUS="failure"
if [ "$SCRIPT_EXIT" -eq 0 ]; then
  RUN_STATUS="success"
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$APP_NAME" \
  "$MODE_LABEL" \
  "$BASE_MODEL" \
  "$TIMESTAMP" \
  "$TRAIN_EXAMPLES" \
  "$VALID_EXAMPLES" \
  "${BEST_ITERS:-}" \
  "${BEST_ACCURACY:-0}" \
  "${BEST_TIME_MIN:-}" \
  "$SUCCESSFUL_SWEEPS" \
  "$SCRIPT_EXIT" \
  "$RUN_STATUS" \
  "$REPORT_ARCHIVE" >> "$METRICS_FILE"

if [ -n "$READINESS_TARGET_APP" ]; then
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$APP_NAME" \
    "$READINESS_TARGET_APP" \
    "$TIMESTAMP" \
    "$BASE_MODEL" \
    "${BEST_ACCURACY:-0}" \
    "$READINESS_TARGET_MODEL" \
    "$READINESS_TARGET_ACCURACY" \
    "$READINESS_DELTA" \
    "$READINESS_STATUS" \
    "$REPORT_ARCHIVE" \
    "$READINESS_TARGET_REPORT" >> "$READINESS_FILE"
fi

if [ "$SCRIPT_EXIT" -eq 0 ]; then
  if [ -n "$BEST_ITERS" ]; then
    emit_training_recovery_alert "best adapter sweep_${BEST_ITERS}_${DATE} reached ${BEST_ACCURACY}% workflow-first"
  else
    emit_training_recovery_alert "training completed successfully"
  fi
else
  if [ -z "$LAST_FAILURE_SUMMARY" ]; then
    LAST_FAILURE_SUMMARY="no successful training runs"
  fi
  emit_training_failure_alert "$LAST_FAILURE_SUMMARY" "$LAST_SWEEP_LOG"
fi

echo "Training report complete: $REPORT" >&2
exit "$SCRIPT_EXIT"
