#!/bin/bash
# mini-install-training-agents.sh - Install/update training LaunchAgents on mini
# Usage:
#   bash ~/SaneApps/infra/scripts/mini-install-training-agents.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
DEFAULT_SANE_ROOT="$HOME/SaneApps"
if [ -d "$HOME/SaneApps-automation/apps" ]; then
  DEFAULT_SANE_ROOT="$HOME/SaneApps-automation"
fi
SANE_ROOT="${SANE_ROOT:-$DEFAULT_SANE_ROOT}"
OUTPUT_DIR="${SANE_OUTPUT_DIR:-$HOME/SaneApps/outputs}"
MLX_BIN_DIR="${MLX_BIN_DIR:-$HOME/mlx-env/bin}"
MLX_VENV_ROOT="${MLX_VENV_ROOT:-$HOME/mlx-env}"
ENABLE_WEEKLY_TRAINING="${ENABLE_WEEKLY_TRAINING:-true}"
TRAIN_HARD_STOP_TIME="${TRAIN_HARD_STOP_TIME:-08:30}"
READINESS_TARGET_APP="${READINESS_TARGET_APP:-}"
CHALLENGER_SELECTION_MODE="${CHALLENGER_SELECTION_MODE:-alternate}"
CHALLENGER_ROTATION_ANCHOR_DATE="${CHALLENGER_ROTATION_ANCHOR_DATE:-2026-05-01}"
CHALLENGER_ROTATION_ORDER="${CHALLENGER_ROTATION_ORDER:-qwen3-0.6b,qwen25-1.5b,gemma3-1b-it,qwen35-0.8b-optiq,smollm3-3b}"
CHALLENGER_BUDGET_MIN="${CHALLENGER_BUDGET_MIN:-0}"
CHALLENGER_SKIP_WEEKDAY="${CHALLENGER_SKIP_WEEKDAY:-0}"
RUN_CHALLENGERS_AFTER_WEEKLY="${RUN_CHALLENGERS_AFTER_WEEKLY:-false}"
CHALLENGER_APP="${CHALLENGER_APP:-SaneAI}"
TRAIN_ALERT_NOTIFY="${TRAIN_ALERT_NOTIFY:-true}"
TRAIN_ALERT_SUPPRESS_MIN="${TRAIN_ALERT_SUPPRESS_MIN:-360}"
TRAIN_ALERT_COMMAND="${TRAIN_ALERT_COMMAND:-}"
TRAIN_POLL_INTERVAL_SEC="${TRAIN_POLL_INTERVAL_SEC:-30}"
TRAIN_EXAMPLE_DROP_MAX_PCT="${TRAIN_EXAMPLE_DROP_MAX_PCT:-20}"
VALID_EXAMPLE_DROP_MAX_PCT="${VALID_EXAMPLE_DROP_MAX_PCT:-20}"
TRAINING_MODE_ENABLED="${TRAINING_MODE_ENABLED:-true}"
TRAINING_MODE_AGENT_SUSPEND_LIST="${TRAINING_MODE_AGENT_SUSPEND_LIST:-com.saneapps.always-awake,com.saneapps.codex-keepalive,com.saneapps.evening,com.saneapps.git-sync-safe,com.saneapps.mcp-watchdog,com.saneapps.memory-guard,com.saneapps.morning,com.saneapps.nightly,com.saneapps.nv-benchmark,com.saneapps.training-daily-check,com.google.GoogleUpdater.wake,com.google.keystone.agent,com.google.keystone.xpcservice,com.grammarly.ProjectLlama.Shepherd,com.grammarly.ProjectLlama.cleanup,com.logos.LogosIndexer,com.logos.desktop.logosindexer}"
TRAINING_MODE_APP_QUIT_LIST="${TRAINING_MODE_APP_QUIT_LIST:-Codex,Xcode,SaneBar,SaneClip,SaneHosts,Shottr,MenuMeters,gfxCardStatus,Safari}"

if ! [[ "$CHALLENGER_ROTATION_ORDER" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then
  echo "Invalid CHALLENGER_ROTATION_ORDER: $CHALLENGER_ROTATION_ORDER" >&2
  exit 2
fi

CHALLENGER_LABEL="com.saneapps.training-challengers"
CHALLENGER_PLIST="$LAUNCH_AGENTS_DIR/${CHALLENGER_LABEL}.plist"
CHALLENGER_SCRIPT="$SCRIPT_DIR/mini-train-challengers.sh"
CHALLENGER_HOUR="${CHALLENGER_HOUR:-1}"
CHALLENGER_MINUTE="${CHALLENGER_MINUTE:-0}"

WEEKLY_LABEL="com.saneapps.training-weekly"
WEEKLY_PLIST="$LAUNCH_AGENTS_DIR/${WEEKLY_LABEL}.plist"
WEEKLY_SCRIPT="$SCRIPT_DIR/mini-train-all.sh"
WEEKLY_TRAIN_WEEKDAY="${WEEKLY_TRAIN_WEEKDAY:-0}"
WEEKLY_TRAIN_HOUR="${WEEKLY_TRAIN_HOUR:-1}"
WEEKLY_TRAIN_MINUTE="${WEEKLY_TRAIN_MINUTE:-0}"

LEGACY_LABEL="com.saneapps.training"
LEGACY_PLIST="$LAUNCH_AGENTS_DIR/${LEGACY_LABEL}.plist"

mkdir -p "$LAUNCH_AGENTS_DIR" "$OUTPUT_DIR"

cat > "$CHALLENGER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CHALLENGER_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${CHALLENGER_SCRIPT}</string>
    <string>${CHALLENGER_APP}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${CHALLENGER_HOUR}</integer>
    <key>Minute</key>
    <integer>${CHALLENGER_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/training-challengers.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/training-challengers.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${MLX_BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MLX_VENV_ROOT</key>
    <string>${MLX_VENV_ROOT}</string>
    <key>MLX_PYTHON_BIN</key>
    <string>${MLX_VENV_ROOT}/bin/python3</string>
    <key>SANE_ROOT</key>
    <string>${SANE_ROOT}</string>
    <key>SANE_OUTPUT_DIR</key>
    <string>${OUTPUT_DIR}</string>
    <key>TRAIN_HARD_STOP_TIME</key>
    <string>${TRAIN_HARD_STOP_TIME}</string>
    <key>CHALLENGER_SELECTION_MODE</key>
    <string>${CHALLENGER_SELECTION_MODE}</string>
    <key>CHALLENGER_ROTATION_ANCHOR_DATE</key>
    <string>${CHALLENGER_ROTATION_ANCHOR_DATE}</string>
    <key>CHALLENGER_ROTATION_ORDER</key>
    <string>${CHALLENGER_ROTATION_ORDER}</string>
    <key>CHALLENGER_BUDGET_MIN</key>
    <string>${CHALLENGER_BUDGET_MIN}</string>
    <key>CHALLENGER_SKIP_WEEKDAY</key>
    <string>${CHALLENGER_SKIP_WEEKDAY}</string>
    <key>TRAIN_ALERT_NOTIFY</key>
    <string>${TRAIN_ALERT_NOTIFY}</string>
    <key>TRAIN_ALERT_SUPPRESS_MIN</key>
    <string>${TRAIN_ALERT_SUPPRESS_MIN}</string>
    <key>TRAIN_ALERT_COMMAND</key>
    <string>${TRAIN_ALERT_COMMAND}</string>
    <key>TRAIN_POLL_INTERVAL_SEC</key>
    <string>${TRAIN_POLL_INTERVAL_SEC}</string>
    <key>TRAIN_EXAMPLE_DROP_MAX_PCT</key>
    <string>${TRAIN_EXAMPLE_DROP_MAX_PCT}</string>
    <key>VALID_EXAMPLE_DROP_MAX_PCT</key>
    <string>${VALID_EXAMPLE_DROP_MAX_PCT}</string>
    <key>TRAINING_MODE_ENABLED</key>
    <string>${TRAINING_MODE_ENABLED}</string>
    <key>TRAINING_MODE_AGENT_SUSPEND_LIST</key>
    <string>${TRAINING_MODE_AGENT_SUSPEND_LIST}</string>
    <key>TRAINING_MODE_APP_QUIT_LIST</key>
    <string>${TRAINING_MODE_APP_QUIT_LIST}</string>
  </dict>

  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
EOF

cat > "$WEEKLY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${WEEKLY_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${WEEKLY_SCRIPT}</string>
  </array>

  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key>
    <integer>${WEEKLY_TRAIN_WEEKDAY}</integer>
    <key>Hour</key>
    <integer>${WEEKLY_TRAIN_HOUR}</integer>
    <key>Minute</key>
    <integer>${WEEKLY_TRAIN_MINUTE}</integer>
  </dict>

  <key>StandardOutPath</key>
  <string>${OUTPUT_DIR}/training-weekly.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_DIR}/training-weekly.stderr.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${MLX_BIN_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>MLX_VENV_ROOT</key>
    <string>${MLX_VENV_ROOT}</string>
    <key>MLX_PYTHON_BIN</key>
    <string>${MLX_VENV_ROOT}/bin/python3</string>
    <key>SANE_ROOT</key>
    <string>${SANE_ROOT}</string>
    <key>SANE_OUTPUT_DIR</key>
    <string>${OUTPUT_DIR}</string>
    <key>TRAIN_STDOUT_LOG</key>
    <string>${OUTPUT_DIR}/training-weekly.stdout.log</string>
    <key>TRAIN_STDERR_LOG</key>
    <string>${OUTPUT_DIR}/training-weekly.stderr.log</string>
    <key>TRAIN_HARD_STOP_TIME</key>
    <string>${TRAIN_HARD_STOP_TIME}</string>
    <key>RUN_CHALLENGERS_AFTER_WEEKLY</key>
    <string>${RUN_CHALLENGERS_AFTER_WEEKLY}</string>
    <key>READINESS_TARGET_APP</key>
    <string>${READINESS_TARGET_APP}</string>
    <key>TRAIN_ALERT_NOTIFY</key>
    <string>${TRAIN_ALERT_NOTIFY}</string>
    <key>TRAIN_ALERT_SUPPRESS_MIN</key>
    <string>${TRAIN_ALERT_SUPPRESS_MIN}</string>
    <key>TRAIN_ALERT_COMMAND</key>
    <string>${TRAIN_ALERT_COMMAND}</string>
    <key>TRAIN_POLL_INTERVAL_SEC</key>
    <string>${TRAIN_POLL_INTERVAL_SEC}</string>
    <key>TRAIN_EXAMPLE_DROP_MAX_PCT</key>
    <string>${TRAIN_EXAMPLE_DROP_MAX_PCT}</string>
    <key>VALID_EXAMPLE_DROP_MAX_PCT</key>
    <string>${VALID_EXAMPLE_DROP_MAX_PCT}</string>
    <key>TRAINING_MODE_ENABLED</key>
    <string>${TRAINING_MODE_ENABLED}</string>
    <key>TRAINING_MODE_AGENT_SUSPEND_LIST</key>
    <string>${TRAINING_MODE_AGENT_SUSPEND_LIST}</string>
    <key>TRAINING_MODE_APP_QUIT_LIST</key>
    <string>${TRAINING_MODE_APP_QUIT_LIST}</string>
  </dict>

  <key>Nice</key>
  <integer>10</integer>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LEGACY_LABEL}" 2>/dev/null || true
rm -f "$LEGACY_PLIST"

for label in "$CHALLENGER_LABEL" "$WEEKLY_LABEL"; do
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
done

launchctl bootstrap "gui/$(id -u)" "$CHALLENGER_PLIST"
launchctl enable "gui/$(id -u)/${CHALLENGER_LABEL}" 2>/dev/null || true

if [ "$ENABLE_WEEKLY_TRAINING" = "true" ]; then
  launchctl bootstrap "gui/$(id -u)" "$WEEKLY_PLIST"
  launchctl enable "gui/$(id -u)/${WEEKLY_LABEL}" 2>/dev/null || true
else
  rm -f "$WEEKLY_PLIST"
fi

echo "Installed ${CHALLENGER_LABEL}"
plutil -p "$CHALLENGER_PLIST"
if [ "$ENABLE_WEEKLY_TRAINING" = "true" ]; then
  echo ""
  echo "Installed ${WEEKLY_LABEL}"
  plutil -p "$WEEKLY_PLIST"
else
  echo ""
  echo "Weekly training disabled (${WEEKLY_LABEL})"
fi
