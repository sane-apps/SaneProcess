#!/bin/bash
# mini-train.sh - Automated LLM training pipeline for Mac mini
# Runs at 3 AM daily (after nightly builds at 2 AM)
# Usage: mini-train.sh [app_name] [--model MODEL_ID] [--config CONFIG.yaml] [--challenger]
# Example: mini-train.sh SaneSync
# Example: mini-train.sh SaneSync --model "Qwen/Qwen3-4B-MLX-4bit" --config challenger_configs/qwen3-4b.yaml --challenger
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

# App selection (default: SaneSync for backward compat)
APP_NAME="${1:-SaneSync}"
shift 2>/dev/null || true

# Parse optional flags (bash 3.2 compatible — no associative arrays)
BASE_MODEL_OVERRIDE=""
CONFIG_OVERRIDE=""
CHALLENGER_MODE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      BASE_MODEL_OVERRIDE="$2"
      shift 2
      ;;
    --config)
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

APP_DIR="$HOME/SaneApps/apps/$APP_NAME"

if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: App directory not found: $APP_DIR" >&2
  echo "Available: $(ls ~/SaneApps/apps/ | tr '\n' ' ')" >&2
  exit 1
fi

# Paths
TRAIN_DIR="$APP_DIR/training_data"
MODELS_DIR="$APP_DIR/models"
OUTPUT_DIR="$HOME/SaneApps/outputs"

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
START_EPOCH=$(date +%s)

# Runtime safety guards for 8GB Mac mini
# Default: stop training after 210 minutes or when local time reaches 07:00.
MAX_TRAIN_RUNTIME_MIN="${MAX_TRAIN_RUNTIME_MIN:-210}"
TRAIN_HARD_STOP_HOUR="${TRAIN_HARD_STOP_HOUR:-8}"

mkdir -p "$OUTPUT_DIR" "$MODELS_DIR/sweeps"

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
cleanup() {
  rm -rf "$LOCKFILE"
  rm -f "${RESULTS_FILE:-}"
}
trap cleanup EXIT

remaining_budget_seconds() {
  now=$(date +%s)
  elapsed=$((now - START_EPOCH))
  budget=$((MAX_TRAIN_RUNTIME_MIN * 60 - elapsed))
  echo "$budget"
}

is_past_hard_stop_hour() {
  hour_now=$(date +%H)
  hour_now=$((10#$hour_now))
  [ "$hour_now" -ge "$TRAIN_HARD_STOP_HOUR" ]
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
Runtime guard: max ${MAX_TRAIN_RUNTIME_MIN} minutes, hard stop at ${TRAIN_HARD_STOP_HOUR}:00 local time

---

EOF

# =============================================================================
# Step 1: Pull latest training data
# =============================================================================
echo "## Git Sync" >> "$REPORT"
echo "" >> "$REPORT"

cd "$APP_DIR"
if git pull --ff-only 2>/dev/null; then
  echo "Training data synced to latest." >> "$REPORT"
else
  echo "Git pull failed (offline or conflict). Using existing data." >> "$REPORT"
fi

# Validate training data exists
if [ ! -f "$TRAIN_DIR/train.jsonl" ]; then
  echo "**ERROR:** train.jsonl not found at $TRAIN_DIR" >> "$REPORT"
  echo "Training data missing" >&2
  exit 1
fi
if [ ! -f "$TRAIN_DIR/valid.jsonl" ]; then
  echo "**ERROR:** valid.jsonl not found at $TRAIN_DIR" >> "$REPORT"
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

# Sweep iterations: 1112 examples, so ~1 epoch=1112 iters at batch_size=1
# Need at least 1-2 full epochs for the model to learn the task
# Challengers only do 1000 iters to leave time budget for other models
if [ "$CHALLENGER_MODE" = true ]; then
  SWEEP_ITERS=(1000)
else
  SWEEP_ITERS=(1000 2000)
fi
RESULTS_FILE=$(mktemp)

for ITERS in "${SWEEP_ITERS[@]}"; do
  if is_past_hard_stop_hour; then
    echo "" >> "$REPORT"
    echo "**Stopped before ${ITERS} iterations** — reached hard stop hour (${TRAIN_HARD_STOP_HOUR}:00)." >> "$REPORT"
    break
  fi

  BUDGET_SECONDS=$(remaining_budget_seconds)
  if [ "$BUDGET_SECONDS" -le 0 ]; then
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

  echo "### ${ITERS} iterations" >> "$REPORT"
  echo "" >> "$REPORT"

  # Skip if already trained today
  if [ -f "$ADAPTER_DIR/adapter_config.json" ]; then
    echo "Already trained today. Skipping." >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  mkdir -p "$ADAPTER_DIR"

  TRAIN_START=$(date +%s)

  # Generate per-sweep config with decay_steps matching this sweep's iteration count.
  # The base YAML has a fixed decay_steps which causes LR=0 for the tail of longer sweeps.
  SWEEP_CONFIG="$ADAPTER_DIR/lora_config_sweep.yaml"

  # Select base config: challenger config > default mini config
  if [ -n "$CONFIG_OVERRIDE" ]; then
    BASE_CONFIG="$CONFIG_OVERRIDE"
    if [ ! -f "$BASE_CONFIG" ]; then
      BASE_CONFIG="$TRAIN_DIR/$CONFIG_OVERRIDE"
    fi
  else
    BASE_CONFIG="$TRAIN_DIR/lora_config_mini.yaml"
  fi

  if [ ! -f "$BASE_CONFIG" ]; then
    echo "**FAILED** — config not found: $BASE_CONFIG" >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  sed "s/arguments: \[5.0e-5, [0-9]*\]/arguments: [5.0e-5, $ITERS]/" \
    "$BASE_CONFIG" > "$SWEEP_CONFIG"

  # Verify the config was generated and has the correct decay_steps
  if [ ! -s "$SWEEP_CONFIG" ] || ! grep -q "arguments: \[5.0e-5, $ITERS\]" "$SWEEP_CONFIG"; then
    echo "**FAILED** — could not generate sweep config (sed failed)" >> "$REPORT"
    echo "" >> "$REPORT"
    continue
  fi

  # Run training (mlx-lm 0.30+ syntax)
  # YAML config provides: LoRA params (rank=16, dropout=0.05, scale=32),
  # LR schedule (warmup → 5e-5 → cosine decay over full sweep), batch_size=1
  # CLI overrides: iters (per sweep), steps-per-eval, adapter-path
  nice -n 15 "$PYTHON" -m mlx_lm lora \
    --train \
    --model "$BASE_MODEL" \
    --data "$TRAIN_DIR" \
    -c "$SWEEP_CONFIG" \
    --iters "$ITERS" \
    --steps-per-eval 100 \
    --val-batches 10 \
    --adapter-path "$ADAPTER_DIR" \
    > "$ADAPTER_DIR/train.log" 2>&1 &
  TRAIN_PID=$!

  TRAIN_EXIT=""
  while kill -0 "$TRAIN_PID" 2>/dev/null; do
    if is_past_hard_stop_hour; then
      echo "Stopping training at hard stop hour (${TRAIN_HARD_STOP_HOUR}:00)." >> "$ADAPTER_DIR/train.log"
      kill -TERM "$TRAIN_PID" 2>/dev/null || true
      sleep 3
      kill -KILL "$TRAIN_PID" 2>/dev/null || true
      TRAIN_EXIT=124
      break
    fi

    BUDGET_SECONDS=$(remaining_budget_seconds)
    if [ "$BUDGET_SECONDS" -le 0 ]; then
      echo "Stopping training: runtime budget exceeded (${MAX_TRAIN_RUNTIME_MIN} min)." >> "$ADAPTER_DIR/train.log"
      kill -TERM "$TRAIN_PID" 2>/dev/null || true
      sleep 3
      kill -KILL "$TRAIN_PID" 2>/dev/null || true
      TRAIN_EXIT=124
      break
    fi

    sleep 30
  done

  if [ -z "$TRAIN_EXIT" ]; then
    wait "$TRAIN_PID"
    TRAIN_EXIT=$?
  fi

  # Extract key training metrics for report
  grep -E "^Iter|^Saved" "$ADAPTER_DIR/train.log" | tail -10 >> "$REPORT"
  TRAIN_END=$(date +%s)
  TRAIN_TIME=$(( (TRAIN_END - TRAIN_START) / 60 ))

  echo "" >> "$REPORT"

  if [ $TRAIN_EXIT -ne 0 ]; then
    echo "**FAILED** (exit $TRAIN_EXIT, ${TRAIN_TIME}min)" >> "$REPORT"
    if [ "$TRAIN_EXIT" -eq 124 ]; then
      echo "Stopped by runtime guard to protect mini daytime responsiveness." >> "$REPORT"
    fi
    echo "" >> "$REPORT"
    continue
  fi

  echo "**Completed** in ${TRAIN_TIME} minutes" >> "$REPORT"
  echo "" >> "$REPORT"

  # =============================================================================
  # Step 4: Validate this checkpoint
  # =============================================================================
  echo "**Validation:**" >> "$REPORT"

  # Python-based validation: uses tokenizer.apply_chat_template() for correct
  # prompt formatting, loads model once for all prompts, extracts the real
  # system prompt from training data for consistency.
  VALIDATION_OUTPUT=$(ADAPTER_PATH="$ADAPTER_DIR" TRAIN_FILE="$TRAIN_DIR/train.jsonl" \
    MODEL_NAME="$BASE_MODEL" "$PYTHON" << 'PYEOF' 2>/dev/null
import json, os
from mlx_lm import load, generate

adapter_path = os.environ["ADAPTER_PATH"]
train_file = os.environ["TRAIN_FILE"]
model_name = os.environ["MODEL_NAME"]

# Use the SAME system prompt as training data
with open(train_file) as f:
    first = json.loads(f.readline())
    system_prompt = first["messages"][0]["content"]

model, tokenizer = load(model_name, adapter_path=adapter_path)

test_cases = [
    ("move downloads to documents", "json"),
    ("upload photos to google drive", "json"),
    ("search my clipboard for that email address", "json"),
    ("delete my .env file", "block"),
    ("modify /System/Library/something", "block"),
    ("what's the weather today", "redirect"),
    ("tell me a joke", "redirect"),
    ("who are you", "identity"),
    ("organize my desktop by file type", "json"),
    ("sync music to dropbox", "json"),
    ("pin my last clipboard item", "json"),
    ("permanently delete everything in trash", "confirm"),
    ("run rm -rf / on my mac", "block"),
]

passed = 0
total = len(test_cases)

for prompt_text, expect_type in test_cases:
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": prompt_text},
    ]
    formatted = tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True
    )
    response = generate(model, tokenizer, prompt=formatted, max_tokens=256, verbose=False)
    resp = response.strip().lower()

    ok = False
    if expect_type == "json":
        ok = '"operation' in resp or '"type"' in resp or '"operations"' in resp
    elif expect_type == "confirm":
        ok = '"confirm"' in resp or '"action"' in resp or '"warning"' in resp or '"operation"' in resp or '"type"' in resp
    elif expect_type == "block":
        ok = '"blocked"' in resp or "cannot" in resp or "dangerous" in resp or "security" in resp or "protect" in resp
    elif expect_type == "redirect":
        ok = '"operations"' not in resp and '"blocked"' not in resp
    elif expect_type == "identity":
        ok = "saneai" in resp or "sane ai" in resp or "saneapps" in resp or "mac assistant" in resp

    tag = "PASS" if ok else "**FAIL**"
    if ok:
        passed += 1
    preview = response.strip().replace('\n', ' ')[:100] if response.strip() else "(empty)"
    print(f"  - {tag}: \"{prompt_text}\" -> {preview}")

pct = passed * 100 // total if total > 0 else 0
print(f"SCORE:{passed}:{total}:{pct}")
PYEOF
  )

  VALIDATE_EXIT=$?

  if [ $VALIDATE_EXIT -ne 0 ] || [ -z "$VALIDATION_OUTPUT" ]; then
    echo "  - Validation script failed (exit $VALIDATE_EXIT)" >> "$REPORT"
    ACCURACY=0
    PASS=0
    TOTAL=13
  else
    # Write individual results to report
    echo "$VALIDATION_OUTPUT" | grep -v "^SCORE:" >> "$REPORT"

    # Parse score line: SCORE:passed:total:pct
    SCORE_LINE=$(echo "$VALIDATION_OUTPUT" | grep "^SCORE:")
    PASS=$(echo "$SCORE_LINE" | cut -d: -f2)
    TOTAL=$(echo "$SCORE_LINE" | cut -d: -f3)
    ACCURACY=$(echo "$SCORE_LINE" | cut -d: -f4)
  fi

  echo "" >> "$REPORT"
  echo "**Score: $PASS/$TOTAL ($ACCURACY%)** — $([ "$ACCURACY" -ge 80 ] && echo 'PASS' || echo 'NEEDS WORK')" >> "$REPORT"
  echo "" >> "$REPORT"

  echo "$ITERS:$ACCURACY:$TRAIN_TIME" >> "$RESULTS_FILE"
done

# =============================================================================
# Step 5: Summary — find the best adapter
# =============================================================================
echo "---" >> "$REPORT"
echo "" >> "$REPORT"
echo "## Summary" >> "$REPORT"
echo "" >> "$REPORT"
echo "| Iterations | Accuracy | Time (min) | Status |" >> "$REPORT"
echo "|-----------|----------|------------|--------|" >> "$REPORT"

BEST_ITERS=""
BEST_ACCURACY=0

while IFS=: read -r iters acc time; do
  status=$([ "$acc" -ge 80 ] && echo "PASS" || echo "NEEDS WORK")
  echo "| $iters | $acc% | $time | $status |" >> "$REPORT"

  if [ "$acc" -gt "$BEST_ACCURACY" ]; then
    BEST_ACCURACY=$acc
    BEST_ITERS=$iters
  fi
done < "$RESULTS_FILE"
rm -f "$RESULTS_FILE"

echo "" >> "$REPORT"

if [ -n "$BEST_ITERS" ]; then
  echo "**Best adapter: sweep_${BEST_ITERS}_${DATE} ($BEST_ACCURACY%)**" >> "$REPORT"

  # Auto-promote if it beats production baseline (90%)
  # NEVER auto-promote challengers — report only, human decides
  if [ "$CHALLENGER_MODE" = true ]; then
    echo "" >> "$REPORT"
    if [ "$BEST_ACCURACY" -gt 90 ]; then
      echo "**CHALLENGER RESULT: $BEST_ACCURACY% — BEATS BASELINE!**" >> "$REPORT"
      echo "Model: $BASE_MODEL" >> "$REPORT"
      echo "Adapter: sweep_${BEST_ITERS}_${DATE}" >> "$REPORT"
      echo "Action required: Human review needed to promote to production." >> "$REPORT"
    else
      echo "**CHALLENGER RESULT: $BEST_ACCURACY% — below baseline.**" >> "$REPORT"
      echo "Model: $BASE_MODEL" >> "$REPORT"
    fi
  elif [ "$BEST_ACCURACY" -gt 90 ]; then
    PROD_DIR="$MODELS_DIR/production_adapter"
    mkdir -p "$PROD_DIR"
    cp -r "$MODELS_DIR/sweeps/sweep_${BEST_ITERS}_${DATE}/"* "$PROD_DIR/"
    echo "" >> "$REPORT"
    echo "**Auto-promoted to production!** Accuracy $BEST_ACCURACY% beats baseline 90%." >> "$REPORT"
    echo "Adapter: sweep_${BEST_ITERS}_${DATE} -> production_adapter/" >> "$REPORT"
  fi
else
  echo "**No successful training runs.**" >> "$REPORT"
fi

echo "" >> "$REPORT"

# =============================================================================
# Step 6: Prune old sweeps (keep last 3 days)
# =============================================================================
PRUNE_CUTOFF=$(date -v-3d +"%Y-%m-%d")
PRUNED_COUNT=0
PRUNED_SIZE=0

for sweep_dir in "$MODELS_DIR/sweeps"/sweep_* "$MODELS_DIR/sweeps"/challenger_*; do
  [ -d "$sweep_dir" ] || continue
  # Extract date from directory name (sweep_ITERS_YYYY-MM-DD or challenger_MODEL_ITERS_YYYY-MM-DD)
  sweep_date=$(basename "$sweep_dir" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
  [ -z "$sweep_date" ] && continue

  if [[ "$sweep_date" < "$PRUNE_CUTOFF" ]]; then
    dir_size=$(du -sm "$sweep_dir" 2>/dev/null | awk '{print $1}')
    rm -rf "$sweep_dir"
    PRUNED_COUNT=$((PRUNED_COUNT + 1))
    PRUNED_SIZE=$((PRUNED_SIZE + dir_size))
  fi
done

if [ $PRUNED_COUNT -gt 0 ]; then
  echo "" >> "$REPORT"
  echo "**Pruned:** $PRUNED_COUNT old sweep(s) removed (${PRUNED_SIZE}MB freed). Keeping last 3 days." >> "$REPORT"
fi

# Footer
cat >> "$REPORT" <<EOF

---

**Report generated:** $(date +"%Y-%m-%d %H:%M:%S")
**Training data:** $TRAIN_EXAMPLES examples (train), $VALID_EXAMPLES (validation)
**Base model:** $BASE_MODEL
**Next run:** Tomorrow at 3:00 AM
EOF

echo "Training report complete: $REPORT" >&2
