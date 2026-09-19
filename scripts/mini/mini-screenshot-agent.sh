#!/bin/bash
# mini-screenshot-agent.sh — queue-driven screenshot service for the Mini.
#
# WHY THIS EXISTS: any capture driven from an ssh session inherits sshd TCC
# attribution and is denied Screen Recording, even inside a Terminal window.
# This agent runs in the console GUI session (LaunchAgent), so its captures
# carry console attribution and the existing Terminal grant covers them.
#
# PROTOCOL (all under ~/.sane/capture-queue, owner-only):
#   request-<id>.json  {"id": "<id>", "args": ["desktop", "--skip-cleanup"]}
#   receipt-<id>.json  {"id": "<id>", "exit": 0, "png": "/path/shot.png",
#                       "error": "<last stderr lines>"}
# The requester (e.g. the Air over ssh) writes a request, polls for the
# receipt, fetches/deletes the PNG, and deletes the receipt. Requests are
# processed oldest-first, one at a time. Poison requests get an error
# receipt instead of wedging the queue.
set -u

QUEUE_DIR="${HOME}/.sane/capture-queue"
WRAPPER="${HOME}/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh"
export MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS="${MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS:-120}"

mkdir -p "$QUEUE_DIR"
chmod 700 "$QUEUE_DIR"

log() {
  printf '%s [shot-agent] %s\n' "$(date -u +%FT%TZ)" "$*"
}

extract_args() {
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("args", [])))' "$1" 2>/dev/null
}

process_one() {
  local req="$1" id out exit_code png err
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$req" 2>/dev/null)"
  if [ -z "$id" ]; then
    log "dropping unreadable request $(basename "$req")"
    rm -f "$req"
    return 0
  fi
  log "processing $id"
  if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("prompt") else 1)' "$req" 2>/dev/null; then
    log "prompt mode $id: posting system Screen Recording dialog (no-prompt disabled)"
    out="$(bash /tmp/codex-screenshot-scripts/ensure_macos_permissions.sh 2>&1)"
    exit_code=$?
    png=""
    err="$(printf '%s\n' "$out" | tail -n 5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
    python3 -c 'import json,sys; json.dump({"id": sys.argv[1], "exit": int(sys.argv[2]), "png": sys.argv[3], "error": json.loads(sys.argv[4]), "prompt_posted": True}, open(sys.argv[5], "w"))' \
      "$id" "$exit_code" "$png" "$err" "${QUEUE_DIR}/receipt-${id}.json"
    rm -f "$req"
    log "done $id prompt posted exit=$exit_code"
    return 0
  fi
  wrapper_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && wrapper_args+=("$line")
  done < <(extract_args "$req")
  out="$("$WRAPPER" "${wrapper_args[@]}" 2>&1)"
  exit_code=$?
  png="$(printf '%s\n' "$out" | grep -Eo '/[^ ]+\.(png|jpg|jpeg|heic)' | tail -n 1)"
  err="$(printf '%s\n' "$out" | tail -n 5 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  python3 -c 'import json,sys; json.dump({"id": sys.argv[1], "exit": int(sys.argv[2]), "png": sys.argv[3], "error": json.loads(sys.argv[4])}, open(sys.argv[5], "w"))' \
    "$id" "$exit_code" "$png" "$err" "${QUEUE_DIR}/receipt-${id}.json"
  rm -f "$req"
  log "done $id exit=$exit_code png=${png:-none}"
}

log "agent start queue=$QUEUE_DIR"
while true; do
  for req in "$QUEUE_DIR"/request-*.json; do
    [ -e "$req" ] || break
    process_one "$req"
  done
  sleep 2
done
