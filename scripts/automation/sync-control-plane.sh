#!/bin/bash
# Sync primary operator control plane (Cursor + Grok) to the Mini.
# Legacy Codex sync remains available as sync_mini for compatibility only.

set -euo pipefail

# Shared by the three installed client wrappers. Missing files may be added;
# existing files and peer-only files are never overwritten or removed.
sync_copy_missing() {
  local source="$1" destination="$2" receipt verify_destination="$2"
  receipt=$(mktemp "${TMPDIR:-/tmp}/sane-control-sync.XXXXXX") || return 1
  if ! rsync -rl --ignore-existing "$source" "$destination"; then
    rm -f "$receipt"
    echo "ERROR: transfer failed: $destination" >&2
    return 1
  fi
  # Native openrsync falsely itemizes equal files with a file destination.
  if [[ -f "$source" ]]; then
    [[ "${source##*/}" == "${destination##*/}" ]] || { rm -f "$receipt"; return 1; }
    verify_destination="${destination%/*}/"
  fi
  if ! rsync -rlc --dry-run --out-format=%n "$source" "$verify_destination" > "$receipt"; then
    rm -f "$receipt"
    echo "ERROR: verification failed: $destination" >&2
    return 1
  fi
  if [[ -s "$receipt" ]]; then
    echo "ERROR: existing destination differs; preserved for review: $destination" >&2
    cat "$receipt" >&2
    rm -f "$receipt"
    return 1
  fi
  rm -f "$receipt"
}

sync_peer_home() {
  REMOTE_HOME=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'printf %s "$HOME"') || return 1
  local local_host remote_host
  local_host=$(hostname -s) || return 1
  remote_host=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" 'hostname -s') || return 1
  [[ -n "$REMOTE_HOME" && -n "$remote_host" && "$local_host" != "$remote_host" ]] || {
    echo "ERROR: missing peer identity or loopback sync" >&2
    return 1
  }
}

sync_preserve_profile() {
  local path="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$MINI_HOST" "test -f $(printf '%q' "$path")" || {
    echo "ERROR: configure the client on Mini first; host-owned profile missing or inaccessible: $path" >&2
    return 1
  }
  echo "Preserved host-owned Mini profile: $path"
}

sync_link_missing() {
  local target="$1" link="$2"
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] && return 0
  elif [[ ! -e "$link" ]]; then
    ln -s "$target" "$link"
    return $?
  fi
  echo "ERROR: existing guard path differs; preserved: $link" >&2
  return 1
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

MINI_HOST="mini"
QUIET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [mini-host] [--quiet]
Syncs Cursor hooks/skills and Grok helpers to the Mini.
USAGE
      exit 0
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done

ROOT="$HOME/SaneApps/infra/SaneProcess"
ARGS=()
[[ "$QUIET" -eq 1 ]] && ARGS+=(--quiet)

bash "$ROOT/scripts/automation/sync-cursor-mini.sh" "$MINI_HOST" "${ARGS[@]}"
bash "$ROOT/scripts/automation/sync-grok-mini.sh" "$MINI_HOST" "${ARGS[@]}"
