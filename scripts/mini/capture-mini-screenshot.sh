#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_SKILL_DIR="${LOCAL_SCREENSHOT_HELPER_DIR:-${HOME}/.codex/skills/screenshot/scripts}"
REMOTE_HELPER_DIR="/tmp/codex-screenshot-scripts"
MINI_HOST="${MINI_HOST:-mini}"
REMOTE_MINI_GUI_RUN="${REMOTE_MINI_GUI_RUN:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh}"
REMOTE_VISUAL_GUARD="${REMOTE_VISUAL_GUARD:-~/SaneApps/infra/SaneProcess/scripts/mini/mini-visual-workspace-guard.sh}"
LOCKED_HELPER_RUNNER="$SCRIPT_DIR/mini-screenshot-evidence-helper.sh"
MINI_HOST_FALLBACKS="${MINI_HOST_FALLBACKS:-stephansmac@Stephans-Mac-mini.local stephansmac@stephans-mac-mini.local}"
MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS="${MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS:-120}"
SKIP_CLEANUP=false
use_local_runner=false
locked_evidence=false
activate_pid=""
window_title=""
print_usage() {
  cat <<'EOF'
Usage:
  capture-mini-screenshot.sh -h|--help
  capture-mini-screenshot.sh [--skip-cleanup] desktop [--copy-to LOCAL_DIR] [helper args]
  capture-mini-screenshot.sh [--locked-evidence] desktop [helper args]
  capture-mini-screenshot.sh --video [--duration N] [--out PATH] [--copy-to DIR]
Notes:
  Runs in the Mini's logged-in Terminal session. Default captures clean the desktop;
  --skip-cleanup preserves visible prompts. Always open and inspect the resulting image.
EOF
}
usage() { print_usage >&2; exit 2; }
[ $# -gt 0 ] || usage
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      print_usage
      exit 0
      ;;
  esac
done
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
local_copy_to=""
capture_video=false
video_duration=5
video_out=""
forward_args=()
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --video)
      capture_video=true
      ;;
    --duration)
      shift
      [ $# -gt 0 ] || {
        echo "Missing value for --duration" >&2
        usage
      }
      video_duration="$1"
      ;;
    --duration=*)
      video_duration="${1#--duration=}"
      ;;
    --out)
      shift
      [ $# -gt 0 ] || {
        echo "Missing value for --out" >&2
        usage
      }
      video_out="$1"
      ;;
    --out=*)
      video_out="${1#--out=}"
      ;;
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
    --locked-evidence)
      locked_evidence=true
      ;;
    --activate-pid)
      shift; [ $# -gt 0 ] || usage; activate_pid="$1"
      ;;
    --window-title)
      shift; [ $# -gt 0 ] || usage; window_title="$1"
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
if $capture_video; then
  case "$video_duration" in
    ''|*[!0-9]*)
      echo "--duration must be a positive integer number of seconds" >&2
      exit 2
      ;;
  esac
  [ "$video_duration" -gt 0 ] || {
    echo "--duration must be a positive integer number of seconds" >&2
    exit 2
  }
fi
set -- ${forward_args[@]+"${forward_args[@]}"}
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
if ! $capture_video; then
  [ -d "$LOCAL_SKILL_DIR" ] || {
    echo "Missing local screenshot helper scripts at: $LOCAL_SKILL_DIR" >&2
    echo "Install the SaneProcess screenshot helper bundle or set LOCAL_SCREENSHOT_HELPER_DIR." >&2
    echo "Run this wrapper from the controlling machine, not from a plain ssh shell on the Mini." >&2
    exit 1
  }
fi
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

run_local_runner_with_timeout() {
  local timeout_seconds="$1"
  local runner="$2"
  local output_file=""
  local status_file=""
  local pid=""
  local elapsed=0
  local status=1

  output_file="$(mktemp "/tmp/capture-mini-screenshot-output.XXXXXX")"
  status_file="$(mktemp "/tmp/capture-mini-screenshot-status.XXXXXX")"

  (
    if $locked_evidence; then
      /usr/bin/env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/tmp \
        /bin/bash --noprofile --norc -c "$runner" >"$output_file" 2>&1
    else
      bash -lc "$runner" >"$output_file" 2>&1
    fi
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

running_on_mini() {
  [ "${MINI_SCREENSHOT_FORCE_SSH:-0}" = "1" ] && return 1

  case "$(hostname 2>/dev/null || true)" in
    Stephans-Mac-mini.local|stephans-mac-mini.local|Stephans-Mac-mini|stephans-mac-mini)
      return 0
      ;;
  esac

  case "$(scutil --get ComputerName 2>/dev/null || true)" in
    *Mac\ mini*|*Mac\ Mini*)
      return 0
      ;;
  esac

  return 1
}

running_in_ssh_session() {
  [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

printed_screenshot_path() {
  awk '/^\/.*\.(png|jpg|jpeg|heic)$/ { path=$0 } END { if (path != "") print path }'
}

if running_on_mini; then
  use_local_runner=true
  resolved_mini_host=""
  remote_home="$HOME"
else
  resolved_mini_host="$(resolve_mini_host "$MINI_HOST")"
  remote_home="$(ssh "$resolved_mini_host" 'printf %s "$HOME"')"
fi
if $locked_evidence && ! $use_local_runner; then
  echo "Locked screenshot evidence must run directly on the Mac Mini." >&2
  exit 1
fi
REMOTE_MINI_GUI_RUN="$(expand_remote_home_path "$REMOTE_MINI_GUI_RUN" "$remote_home")"
REMOTE_VISUAL_GUARD="$(expand_remote_home_path "$REMOTE_VISUAL_GUARD" "$remote_home")"

# --- Screen recording (video) ---------------------------------------------
# ffmpeg runs inside the Mini's logged-in GUI Terminal session (via
# mini-gui-run.sh), the same granted context the screenshot path uses — the
# only reliable way to capture the Mini screen over ssh (a direct ssh
# ffmpeg/screencapture is blocked by TCC responsible-process attribution).
if $capture_video; then
  video_out="${video_out:-/tmp/mini-record.mp4}"
  screen_index="${MINI_SCREEN_AVF_INDEX:-2}" # avfoundation "Capture screen 0"
  ff_out_q="$(printf '%q' "$video_out")"
  ff_cmd="ffmpeg -y -f avfoundation -capture_cursor 1 -framerate 15 -i ${screen_index}:none -t ${video_duration} ${ff_out_q} && printf 'RECORDING %s\\n' ${ff_out_q}"
  video_runner="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screen Recording" --close-window -- "$ff_cmd")"
  vtimeout=$((video_duration + 30))
  video_output="$(run_remote_runner_with_timeout "$vtimeout" "$resolved_mini_host" "$video_runner")" || {
    echo "Mini screen recording failed. If it is a permission error, grant Screen Recording to Terminal on the Mini (this wrapper runs ffmpeg inside Terminal's session)." >&2
    exit 1
  }
  printf '%s\n' "$video_output"
  if [ -n "$local_copy_to" ]; then
    mkdir -p "$local_copy_to"
    rsync -az "${resolved_mini_host}:${video_out}" "$local_copy_to/"
    echo "Copied recording to $local_copy_to/" >&2
  fi
  exit 0
fi

if $locked_evidence; then
  [ -n "${CWS_SCREENSHOT_EXPECTED_HELPER_SHA256:-}" ] || {
    echo "Locked screenshot evidence requires an expected helper hash." >&2
    exit 1
  }
  [ -n "$activate_pid" ] && [ -n "$window_title" ] || {
    echo "Locked screenshot evidence requires an exact Brave PID and window title." >&2
    exit 1
  }
elif $use_local_runner; then
  mkdir -p "$REMOTE_HELPER_DIR"
  rsync -az "$LOCAL_SKILL_DIR/" "${REMOTE_HELPER_DIR}/"
else
  rsync -az "$LOCAL_SKILL_DIR/" "${resolved_mini_host}:${REMOTE_HELPER_DIR}/"
fi

forwarded_args="$(remote_cmd "$@")"
guard_cmd=""
guard_env=""
if $use_local_runner && ! running_in_ssh_session; then
  guard_env="MINI_VISUAL_AVOID_TERMINAL_AUTOMATION=1 "
fi
if [ -n "$target_app" ]; then
  if ! $SKIP_CLEANUP; then
    guard_cmd="${guard_env}/bin/bash ${REMOTE_VISUAL_GUARD} --cleanup --app $(printf '%q' "$target_app") && "
  fi
elif [ "$has_explicit_target" = false ]; then
  if ! $SKIP_CLEANUP; then
    guard_cmd="${guard_env}/bin/bash ${REMOTE_VISUAL_GUARD} --desktop --cleanup && "
  fi
fi
if $locked_evidence; then
  locked_cmd="$(remote_cmd /usr/bin/env -i HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/tmp /bin/bash "$LOCKED_HELPER_RUNNER" --source "$LOCAL_SKILL_DIR" --expected-sha "$CWS_SCREENSHOT_EXPECTED_HELPER_SHA256" --activate-pid "$activate_pid" --window-title "$window_title" -- "$@")"
  cmd="${guard_cmd}${locked_cmd}"
  runner_cmd="$(remote_cmd /bin/bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screenshot" --reclaim-all --close-window --no-login-shell -- "$cmd")"
elif $use_local_runner && ! running_in_ssh_session; then
  cmd="${guard_cmd}CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh && CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 python3 ${REMOTE_HELPER_DIR}/take_screenshot.py ${forwarded_args}"
  runner_cmd="$cmd"
else
  cmd="${guard_cmd}CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 bash ${REMOTE_HELPER_DIR}/ensure_macos_permissions.sh && CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 python3 ${REMOTE_HELPER_DIR}/take_screenshot.py ${forwarded_args}"
  runner_cmd="$(remote_cmd bash "$REMOTE_MINI_GUI_RUN" --title "Mini Screenshot" --reclaim-all --close-window -- "$cmd")"
fi

capture_status=0
if $use_local_runner; then
  capture_output="$(run_local_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$runner_cmd")" || capture_status=$?
else
  capture_output="$(run_remote_runner_with_timeout "$MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS" "$resolved_mini_host" "$runner_cmd")" || capture_status=$?
fi
if [ "$capture_status" -ne 0 ] && ! $locked_evidence; then
  recovered_path="$(printf '%s\n' "$capture_output" | printed_screenshot_path)"
  if [ -n "${recovered_path:-}" ]; then
    if $use_local_runner; then
      [ -s "$recovered_path" ] || recovered_path=""
    else
      ssh "$resolved_mini_host" "[ -s $(printf '%q' "$recovered_path") ]" >/dev/null 2>&1 || recovered_path=""
    fi
  fi
  if [ -n "${recovered_path:-}" ]; then
    echo "Recovered screenshot path printed before runner failure: ${recovered_path}" >&2
    capture_status=0
  else
    recovered_path=""
  fi
fi
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
        if $use_local_runner; then
          cp "$remote_path" "$local_copy_to/"
        else
          rsync -az "${resolved_mini_host}:${remote_path}" "$local_copy_to/"
        fi
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
