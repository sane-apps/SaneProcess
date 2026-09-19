#!/bin/bash
# Run one Grok headless heartbeat from a prompt file on the Mac Mini.
# Primary replacement for retired Codex heartbeat prompts that need agent judgment.

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") --id ID --prompt-file PATH [--cwd DIR] [--timeout SECONDS]

Examples:
  $(basename "$0") --id saneapps-launch-ops --prompt-file scripts/automation/heartbeats/saneapps-launch-ops.md
USAGE
}

ID=""
PROMPT_FILE=""
CWD="$HOME/SaneApps/infra/SaneProcess"
TIMEOUT_SECONDS="${AGENT_HEARTBEAT_TIMEOUT_SECONDS:-5400}"
GROK_BIN="${GROK_BIN:-$HOME/.grok/bin/grok}"
OUT_ROOT="$HOME/SaneApps/outputs/agent-heartbeats"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)
      ID="$2"
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE="$2"
      shift 2
      ;;
    --cwd)
      CWD="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

[[ -n "$ID" ]] || { echo "ERROR: --id is required" >&2; exit 64; }
[[ -f "$PROMPT_FILE" ]] || { echo "ERROR: prompt file not found: $PROMPT_FILE" >&2; exit 64; }
[[ -x "$GROK_BIN" || -n "$(command -v grok 2>/dev/null || true)" ]] || {
  echo "ERROR: grok not found (expected $GROK_BIN or PATH)" >&2
  exit 127
}

command -v grok >/dev/null 2>&1 || GROK_BIN="$HOME/.grok/bin/grok"
OUT_DIR="$OUT_ROOT/$ID"
LOCK_DIR="$OUT_DIR/.lock"
mkdir -p "$OUT_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "$(date -Iseconds) skip: prior $ID run still holds lock" >>"$OUT_DIR/run.log"
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

STAMP="$(date +%Y%m%dT%H%M%S)"
LOG="$OUT_DIR/run-$STAMP.log"
RECEIPT="$OUT_DIR/latest.json"

RUBY_BIN="${SANEPROCESS_RUBY:-/opt/homebrew/opt/ruby/bin/ruby}"
{
  echo "== $(date -Iseconds) agent-heartbeat id=$ID cwd=$CWD grok=$GROK_BIN =="
  cd "$CWD"
  # macOS has no GNU timeout(1). Bound the Grok process group in Ruby.
  "$RUBY_BIN" -rtimeout -e '
    timeout_seconds = Integer(ARGV.shift)
    cmd = ARGV
    pid = spawn(*cmd, pgroup: true)
    begin
      Timeout.timeout(timeout_seconds) { Process.wait(pid) }
      exit(Process.last_status&.exitstatus || 1)
    rescue Timeout::Error
      Process.kill("TERM", -pid) rescue nil
      sleep 2
      Process.kill("KILL", -pid) rescue nil
      Process.wait(pid) rescue nil
      exit 124
    end
  ' "$TIMEOUT_SECONDS" "$GROK_BIN" \
    --prompt-file "$PROMPT_FILE" \
    --cwd "$CWD" \
    --output-format json \
    --always-approve
} >"$LOG" 2>&1
STATUS=$?

printf '{"id":"%s","finished_at":"%s","exit_code":%s,"log":"%s"}\n' \
  "$ID" "$(date -Iseconds)" "$STATUS" "$LOG" >"$RECEIPT"

exit "$STATUS"
