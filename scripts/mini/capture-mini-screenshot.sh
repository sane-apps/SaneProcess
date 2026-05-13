#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SKILL_DIR="${HOME}/.codex/skills/screenshot/scripts"
REMOTE_HELPER_DIR="/tmp/codex-screenshot-scripts"
MINI_HOST="${MINI_HOST:-mini}"
REMOTE_MINI_GUI_RUN="${REMOTE_MINI_GUI_RUN:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh}"
REMOTE_VISUAL_GUARD="${REMOTE_VISUAL_GUARD:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-visual-workspace-guard.sh}"

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

has_active_window=false
has_explicit_target=false
target_app=""
expect_app_value=false
for arg in "$@"; do
  if $expect_app_value; then
    target_app="$arg"
    expect_app_value=false
    continue
  fi

  case "$arg" in
    --active-window)
      has_active_window=true
      ;;
    --app|--window-name|--window-id|--region|--interactive)
      has_explicit_target=true
      [ "$arg" = "--app" ] && expect_app_value=true
      ;;
    --app=*)
      has_explicit_target=true
      target_app="${arg#--app=}"
      ;;
  esac
done

if $has_active_window && ! $has_explicit_target; then
  echo "Refusing Mini screenshot capture with bare --active-window." >&2
  echo "That path often captures the automation Terminal instead of the intended app window." >&2
  echo "Use --app/--window-name or --window-id, then close Safari/Preview after the capture." >&2
  exit 2
fi

remote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+="${out:+ }$arg"
  done
  printf '%s' "$out"
}

resolve_mini_host() {
  local host="$1"
  local resolved_host=""

  if ssh -o BatchMode=yes -o ConnectTimeout=2 "$host" true >/dev/null 2>&1; then
    printf '%s' "$host"
    return 0
  fi

  resolved_host="$(ssh -G "$host" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  if [ -n "$resolved_host" ]; then
    printf '%s' "$resolved_host"
    return 0
  fi

  printf '%s' "$host"
}

resolved_mini_host="$(resolve_mini_host "$MINI_HOST")"

rsync -az "$LOCAL_SKILL_DIR/" "${resolved_mini_host}:${REMOTE_HELPER_DIR}/"

forwarded_args="$(remote_cmd "$@")"
guard_cmd=""
if [ -n "$target_app" ]; then
  guard_cmd="bash ${REMOTE_VISUAL_GUARD} --cleanup --app $(printf '%q' "$target_app") && "
fi
cmd="${guard_cmd}bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh && python3 ${REMOTE_HELPER_DIR}/take_screenshot.py ${forwarded_args}"
remote_runner="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screenshot" --reclaim-all --close-window -- "$cmd")"

ssh "$resolved_mini_host" "$remote_runner"
