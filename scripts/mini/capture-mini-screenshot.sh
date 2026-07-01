#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SKILL_DIR="${LOCAL_SCREENSHOT_HELPER_DIR:-${HOME}/.codex/skills/screenshot/scripts}"
REMOTE_HELPER_DIR="/tmp/codex-screenshot-scripts"
MINI_HOST="${MINI_HOST:-mini}"
REMOTE_MINI_GUI_RUN="${REMOTE_MINI_GUI_RUN:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh}"
REMOTE_VISUAL_GUARD="${REMOTE_VISUAL_GUARD:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-visual-workspace-guard.sh}"
MINI_HOST_FALLBACKS="${MINI_HOST_FALLBACKS:-stephansmac@Stephans-Mac-mini.local stephansmac@stephans-mac-mini.local}"
MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS="${MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS:-60}"
SKIP_CLEANUP=false

case "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" -le 0 ]; then
  echo "MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

usage() {
  cat <<'EOF' >&2
Usage:
  capture-mini-screenshot.sh desktop [--copy-to LOCAL_DIR] [take_screenshot.py args...]
  capture-mini-screenshot.sh [--skip-cleanup] [take_screenshot.py args...]
  capture-mini-screenshot.sh [take_screenshot.py args...]

Examples:
  capture-mini-screenshot.sh desktop
  capture-mini-screenshot.sh desktop --path /tmp/mini-proof.png
  capture-mini-screenshot.sh desktop --copy-to /tmp/mini-proof
  capture-mini-screenshot.sh --skip-cleanup desktop --copy-to /tmp/mini-diag  # DIAGNOSTIC: raw screen
  capture-mini-screenshot.sh --list-windows --app "SaneClip"
  capture-mini-screenshot.sh --app "SaneClip" --window-name "Settings" --mode temp
  capture-mini-screenshot.sh --active-window --mode temp

Notes:
  - Runs inside the Mini's logged-in GUI Terminal session.
  - First use may require Screen Recording permission for Terminal on the Mini.
  - Arguments are forwarded directly to the screenshot helper.
  - PROOF captures (default): the visual-workspace guard hides Codex/Terminal
    for a clean marketing/receipt shot.
  - DIAGNOSTIC captures (--skip-cleanup): NO guard, so the screen is captured
    AS-IS. Use this to catch permission pop-ups, app sheets, or a stuck modal —
    the default cleanup would hide the very window you need to see. Then Read the
    PNG; a capture you don't open proves nothing.
EOF
  exit 2
}

[ $# -gt 0 ] || usage

local_copy_to=""
forward_args=()
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --copy-to)
      shift
      [ $# -gt 0 ] || {
        echo "Missing value for --copy-to" >&2
        usage
      }
      local_copy_to="$1"
      ;;
    --copy-to=*)
      local_copy_to="${1#--copy-to=}"
      ;;
    --skip-cleanup)
      SKIP_CLEANUP=true
      ;;
    --full-screen|--out-dir)
      echo "Unsupported Mini screenshot flag: $1" >&2
      echo "Use the canonical desktop path instead: capture-mini-screenshot.sh desktop" >&2
      exit 2
      ;;
    *)
      forward_args[${#forward_args[@]}]="$1"
      ;;
  esac
  shift
done
set -- "${forward_args[@]}"

if [ "${1:-}" = "desktop" ]; then
  shift
  has_path_or_mode=false
  for arg in "$@"; do
    case "$arg" in
      --path|--path=*|--mode|--mode=*)
        has_path_or_mode=true
        ;;
    esac
  done
  if ! $has_path_or_mode; then
    set -- --mode temp "$@"
  fi
fi

[ -d "$LOCAL_SKILL_DIR" ] || {
  echo "Missing local screenshot helper scripts at: $LOCAL_SKILL_DIR" >&2
  echo "Install the SaneProcess screenshot helper bundle or set LOCAL_SCREENSHOT_HELPER_DIR." >&2
  echo "Run this wrapper from the controlling machine, not from a plain ssh shell on the Mini." >&2
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

expand_remote_home_path() {
  local path="$1"
  local remote_home="$2"

  case "$path" in
    "~")
      printf '%s' "$remote_home"
      ;;
    "~/"*)
      printf '%s/%s' "$remote_home" "${path#\~/}"
      ;;
    *)
      printf '%s' "$path"
      ;;
  esac
}

resolve_mini_host() {
  local host="$1"
  local resolved_host=""
  local candidate=""
  local candidates=""

  if ssh -o BatchMode=yes -o ConnectTimeout=2 "$host" true >/dev/null 2>&1; then
    printf '%s' "$host"
    return 0
  fi

  candidates="${candidates}${host}
"
  resolved_host="$(ssh -G "$host" 2>/dev/null | awk '/^hostname /{print $2; exit}')"
  if [ -n "$resolved_host" ]; then
    candidates="${candidates}${resolved_host}
"
    if [[ "$resolved_host" != *@* ]]; then
      candidates="${candidates}stephansmac@${resolved_host}
"
    fi
  fi

  for candidate in $MINI_HOST_FALLBACKS; do
    candidates="${candidates}${candidate}
"
  done

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "$candidate" true >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done <<EOF
$candidates
EOF

  echo "Could not reach the canonical Mini host." >&2
  echo "Tried: ${candidates[*]}" >&2
  echo "Fix ~/.ssh/config or set MINI_HOST=user@host; do not use ad hoc screenshot paths." >&2
  return 1
}

run_remote_runner_with_timeout() {
  local timeout_seconds="$1"
  local host="$2"
  local runner="$3"
  local output_file=""
  local status_file=""
  local pid=""
  local elapsed=0
  local status=1

  output_file="$(mktemp "/tmp/capture-mini-screenshot-output.XXXXXX")"
  status_file="$(mktemp "/tmp/capture-mini-screenshot-status.XXXXXX")"

  (
    ssh "$host" "$runner" >"$output_file" 2>&1
    printf '%s' "$?" >"$status_file"
  ) &
  pid="$!"

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output_file" 2>/dev/null || true
      rm -f "$output_file" "$status_file"
      echo "Mini screenshot capture timed out after ${timeout_seconds}s; inspect the Mini for a stuck GUI runner or permission prompt." >&2
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid" 2>/dev/null || true
  cat "$output_file" 2>/dev/null || true
  if [ -s "$status_file" ]; then
    status="$(cat "$status_file")"
  else
    status=1
  fi
  rm -f "$output_file" "$status_file"
  return "$status"
}

resolved_mini_host="$(resolve_mini_host "$MINI_HOST")"
remote_home="$(ssh "$resolved_mini_host" 'printf %s "$HOME"')"
REMOTE_MINI_GUI_RUN="$(expand_remote_home_path "$REMOTE_MINI_GUI_RUN" "$remote_home")"
REMOTE_VISUAL_GUARD="$(expand_remote_home_path "$REMOTE_VISUAL_GUARD" "$remote_home")"

rsync -az "$LOCAL_SKILL_DIR/" "${resolved_mini_host}:${REMOTE_HELPER_DIR}/"

forwarded_args="$(remote_cmd "$@")"
guard_cmd=""
if [ -n "$target_app" ]; then
  if ! $SKIP_CLEANUP; then
    guard_cmd="bash ${REMOTE_VISUAL_GUARD} --cleanup --app $(printf '%q' "$target_app") && "
  fi
elif [ "$has_explicit_target" = false ]; then
  if ! $SKIP_CLEANUP; then
    guard_cmd="bash ${REMOTE_VISUAL_GUARD} --desktop --cleanup && "
  fi
fi
cmd="${guard_cmd}CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh && CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 python3 ${REMOTE_HELPER_DIR}/take_screenshot.py ${forwarded_args}"
remote_runner="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screenshot" --reclaim-all --close-window -- "$cmd")"

capture_status=0
capture_output="$(run_remote_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$resolved_mini_host" "$remote_runner")" || capture_status=$?
printf '%s\n' "$capture_output"
if [ "$capture_status" -ne 0 ]; then
  exit "$capture_status"
fi

if [ -n "$local_copy_to" ]; then
  mkdir -p "$local_copy_to"
  copied=false
  while IFS= read -r remote_path; do
    case "$remote_path" in
      /*.png|/*.jpg|/*.jpeg|/*.heic)
        rsync -az "${resolved_mini_host}:${remote_path}" "$local_copy_to/"
        copied=true
        ;;
    esac
  done <<EOF
$capture_output
EOF

  if ! $copied; then
    echo "No screenshot path was printed by the Mini capture helper; nothing copied to $local_copy_to" >&2
    exit 1
  fi
fi
