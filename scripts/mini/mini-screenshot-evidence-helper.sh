#!/bin/bash
# Execute a screenshot helper from a private, byte-bound per-run copy.

set -euo pipefail

FILES="ensure_macos_permissions.sh macos_permissions.swift macos_display_info.swift macos_window_info.swift take_screenshot.py cws_sticky_window_info.swift"
source_dir=""
expected_sha=""
stage_dir=""
runtime_dir=""
activate_pid=""
window_title=""

usage() {
  echo "Usage: mini-screenshot-evidence-helper.sh --source DIR --expected-sha SHA --activate-pid PID --window-title TITLE -- [screenshot args]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source)
      [ $# -ge 2 ] || usage
      source_dir="$2"
      shift 2
      ;;
    --expected-sha)
      [ $# -ge 2 ] || usage
      expected_sha="$2"
      shift 2
      ;;
    --activate-pid)
      [ $# -ge 2 ] || usage
      activate_pid="$2"
      shift 2
      ;;
    --window-title)
      [ $# -ge 2 ] || usage
      window_title="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) usage ;;
  esac
done

case "$expected_sha" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    [ "${#expected_sha}" -eq 64 ] || usage
    ;;
  *) usage ;;
esac
case "$activate_pid" in ''|*[!0-9]*) usage ;; esac
[ "$activate_pid" -gt 1 ] && [ -n "$window_title" ] && [ "${#window_title}" -le 300 ] || usage

validate_tree() {
  local directory="$1"
  local current_uid=""
  local entries=""
  local file=""
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  current_uid="$(/usr/bin/id -u)"
  [ "$(/usr/bin/stat -f '%u' "$directory")" = "$current_uid" ] || return 1
  [ "$(/usr/bin/stat -f '%Lp' "$directory")" = "700" ] || return 1
  entries="$(/usr/bin/find "$directory" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [ "$entries" = "6" ] || return 1
  for file in $FILES; do
    [ -f "$directory/$file" ] && [ ! -L "$directory/$file" ] || return 1
    [ "$(/usr/bin/stat -f '%u' "$directory/$file")" = "$current_uid" ] || return 1
    [ "$(/usr/bin/stat -f '%Lp' "$directory/$file")" = "600" ] || return 1
  done
}

tree_sha() {
  local directory="$1"
  (
    cd "$directory"
    for file in $FILES; do
      /usr/bin/shasum -a 256 "$file"
    done
  ) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

cleanup() {
  case "$stage_dir" in
    /private/tmp/sanelot-cws-screenshot.*)
      if [ -d "$stage_dir" ] && [ ! -L "$stage_dir" ]; then
        /bin/rm -R "$stage_dir"
      fi
      ;;
  esac
  case "$runtime_dir" in
    /private/tmp/sanelot-cws-screenshot-runtime.*)
      if [ -d "$runtime_dir" ] && [ ! -L "$runtime_dir" ]; then
        /bin/rm -R "$runtime_dir"
      fi
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

validate_tree "$source_dir" || {
  echo "locked screenshot source tree is unsafe" >&2
  exit 1
}
[ "$(tree_sha "$source_dir")" = "$expected_sha" ] || {
  echo "locked screenshot source hash does not match" >&2
  exit 1
}

stage_dir="$(/usr/bin/mktemp -d /private/tmp/sanelot-cws-screenshot.XXXXXX)"
/bin/chmod 700 "$stage_dir"
for file in $FILES; do
  /bin/cp "$source_dir/$file" "$stage_dir/$file"
  /bin/chmod 600 "$stage_dir/$file"
done
validate_tree "$stage_dir" || {
  echo "locked screenshot execution tree is unsafe" >&2
  exit 1
}
[ "$(tree_sha "$stage_dir")" = "$expected_sha" ] || {
  echo "locked screenshot execution hash does not match" >&2
  exit 1
}
runtime_dir="$(/usr/bin/mktemp -d /private/tmp/sanelot-cws-screenshot-runtime.XXXXXX)"
/bin/chmod 700 "$runtime_dir"

unset BASH_ENV CDPATH ENV GLOBIGNORE PYTHONHOME PYTHONPATH PYTHONSTARTUP
export PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$runtime_dir"
set +e
CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 /bin/bash --noprofile --norc \
  "$stage_dir/ensure_macos_permissions.sh" && \
/usr/bin/swift -module-cache-path "$runtime_dir/swift-cache" \
  "$stage_dir/cws_sticky_window_info.swift" --activate-pid "$activate_pid" \
  --window-title "$window_title" >/dev/null && \
CODEX_SCREENSHOT_NO_PERMISSION_PROMPT=1 /usr/bin/python3 -I \
  "$stage_dir/take_screenshot.py" "$@"
status=$?
set -e

[ "$(tree_sha "$stage_dir")" = "$expected_sha" ] || {
  echo "locked screenshot execution tree changed" >&2
  exit 1
}
exit "$status"
