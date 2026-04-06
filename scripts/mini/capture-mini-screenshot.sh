#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SKILL_DIR="${HOME}/.codex/skills/screenshot/scripts"
REMOTE_HELPER_DIR="/tmp/codex-screenshot-scripts"
MINI_HOST="${MINI_HOST:-mini}"
REMOTE_MINI_GUI_RUN="${REMOTE_MINI_GUI_RUN:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh}"

usage() {
  cat <<'EOF' >&2
Usage:
  capture-mini-screenshot.sh [take_screenshot.py args...]

Examples:
  capture-mini-screenshot.sh --list-windows --app "SaneClip"
  capture-mini-screenshot.sh --app "SaneClip" --window-name "Settings" --mode temp
  capture-mini-screenshot.sh --active-window --mode temp

Notes:
  - Runs inside the Mini's logged-in GUI Terminal session.
  - First use may require Screen Recording permission for Terminal on the Mini.
  - Arguments are forwarded directly to the screenshot helper.
EOF
  exit 2
}

[ $# -gt 0 ] || usage
[ -d "$LOCAL_SKILL_DIR" ] || {
  echo "Missing local screenshot helper scripts at: $LOCAL_SKILL_DIR" >&2
  echo "Run this wrapper from the controlling machine where Codex is installed, not from a plain ssh shell on the Mini." >&2
  exit 1
}
remote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+="${out:+ }$arg"
  done
  printf '%s' "$out"
}

rsync -az "$LOCAL_SKILL_DIR/" "${MINI_HOST}:${REMOTE_HELPER_DIR}/"

forwarded_args="$(remote_cmd "$@")"
cmd="bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh && python3 ${REMOTE_HELPER_DIR}/take_screenshot.py ${forwarded_args}"
remote_runner="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screenshot" --close-window -- "$cmd")"

ssh "$MINI_HOST" "$remote_runner"
