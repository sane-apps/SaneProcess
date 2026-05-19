#!/bin/bash
# sane_rsync_guard.sh
# Blocks basename-flattening sync mistakes into SaneApps app repo roots.

set -euo pipefail

REAL_RSYNC="${SANE_REAL_RSYNC:-/usr/bin/rsync}"

die_blocked() {
  cat >&2 <<EOF
🔴 BLOCKED: risky rsync into a SaneApps app repo root.

This command would copy one or more files by basename into the repo root.
That is how nested files like docs/index.html become ./index.html.

Use one of these instead:
  rsync -av /local/repo/docs/index.html mini:/remote/repo/docs/index.html
  rsync -av --relative /local/repo/./docs/index.html mini:/remote/repo/
  rsync -avR docs/index.html mini:/remote/repo/
  rsync -av /local/repo/ mini:/remote/repo/

Set SANE_RSYNC_ALLOW_FLATTEN=1 only for a deliberate one-off override.
EOF
  exit 2
}

die_bad_relative() {
  cat >&2 <<EOF
🔴 BLOCKED: risky rsync --relative into a SaneApps app repo root.

Absolute sources with --relative preserve too much of the local path unless
you add a /./ anchor. That can create Users/... folders inside the app repo.

Use one of these instead:
  cd /local/repo && rsync -avR docs/index.html mini:/remote/repo/
  rsync -av --relative /local/repo/./docs/index.html mini:/remote/repo/

Set SANE_RSYNC_ALLOW_FLATTEN=1 only for a deliberate one-off override.
EOF
  exit 2
}

is_option_with_value() {
  case "$1" in
    -e|--rsh|--rsync-path|--exclude|--include|--filter|--files-from|--log-file|--out-format|--password-file|--temp-dir|--backup-dir|--compare-dest|--copy-dest|--link-dest)
      return 0
      ;;
  esac
  return 1
}

strip_remote_prefix() {
  local value="$1"
  case "$value" in
    *:/*) value="${value#*:}" ;;
    *:~/*) value="${value#*:}" ;;
  esac
  value="${value/#\~\/SaneApps//Users/stephansmac/SaneApps}"
  printf '%s' "${value%/}"
}

is_saneapps_app_root() {
  local path
  path="$(strip_remote_prefix "$1")"
  [[ "$path" =~ ^/Users/[^/]+/SaneApps/apps/Sane[A-Za-z]+$ ]]
}

source_is_nested_file() {
  local source="$1"
  [[ "$source" == *:* ]] && return 1
  [[ "$source" == */ ]] && return 1
  [[ -d "$source" ]] && return 1

  local rel="$source"
  case "$source" in
    /Users/*/SaneApps/apps/Sane[A-Za-z]*/*)
      rel="${source#*/SaneApps/apps/}"
      rel="${rel#*/}"
      ;;
  esac
  [[ "$rel" == */* ]]
}

source_is_absolute_relative_without_anchor() {
  local source="$1"
  [[ "$source" == *:* ]] && return 1
  [[ "$source" != /* ]] && return 1
  [[ "$source" == *"/./"* ]] && return 1
  return 0
}

operands=()
skip_next=false
after_double_dash=false
preserve_relative=false

for arg in "$@"; do
  if $skip_next; then
    skip_next=false
    continue
  fi

  if ! $after_double_dash && [[ "$arg" == "--" ]]; then
    after_double_dash=true
    continue
  fi

  if ! $after_double_dash && [[ "$arg" == "--relative" ]]; then
    preserve_relative=true
    continue
  fi

  if ! $after_double_dash && [[ "$arg" == "--no-relative" ]]; then
    preserve_relative=false
    continue
  fi

  if ! $after_double_dash && [[ "$arg" == --*=* ]]; then
    continue
  fi

  if ! $after_double_dash && is_option_with_value "$arg"; then
    skip_next=true
    continue
  fi

  if ! $after_double_dash && [[ "$arg" == -* ]]; then
    if [[ "$arg" != --* && "$arg" == *R* ]]; then
      preserve_relative=true
    fi
    continue
  fi

  operands+=("$arg")
done

if [[ "${SANE_RSYNC_ALLOW_FLATTEN:-0}" != "1" && ${#operands[@]} -ge 2 ]]; then
  dest="${operands[$((${#operands[@]} - 1))]}"
  if is_saneapps_app_root "$dest"; then
    source_count=$((${#operands[@]} - 1))
    if $preserve_relative; then
      for ((i = 0; i < source_count; i++)); do
        if source_is_absolute_relative_without_anchor "${operands[$i]}"; then
          die_bad_relative
        fi
      done
    else
      if (( source_count > 1 )); then
        die_blocked
      fi
      if source_is_nested_file "${operands[0]}"; then
        die_blocked
      fi
    fi
  fi
fi

if [[ "${SANE_RSYNC_GUARD_DRY_RUN:-0}" == "1" ]]; then
  exit 0
fi

exec "$REAL_RSYNC" "$@"
