#!/bin/bash
# Conflict-preserving Air<->Mini synchronization for the file-backed memories
# used by Claude, Serena, and Codex. The shared AgentMemory service is separate.
#
# Production runs on the Air and connects to the Mini over `ssh mini`. It is
# intentionally no-delete. Each changed pair is backed up once per day, then
# synchronized pull -> push -> pull using checksum comparison, newest-mtime
# selection, and rsync backup suffixes. A losing same-file version therefore
# survives as a `.sane-conflict-*` file on both machines.
#
# Session/LaunchAgent safety: an unreachable Mini or an already-held lock is a
# clean skip. Use --strict for an interactive verification run that must fail on
# an unreachable peer or post-sync checksum drift.
set -uo pipefail

MINI_HOST="mini"
LOCAL_PEER_HOME=""
STRICT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-peer-home)
      [[ $# -ge 2 ]] || { echo "ERROR: --local-peer-home requires a path" >&2; exit 2; }
      LOCAL_PEER_HOME="$2"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      echo "Usage: $(basename "$0") [mini-host] [--strict] [--local-peer-home PATH]"
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
    *)
      MINI_HOST="$1"
      shift
      ;;
  esac
done

SSH=(ssh -o ConnectTimeout=8 -o BatchMode=yes)
LOCK_REL=".cache/saneapps-memory-sync.lock"
BACKUP_REL=".cache/saneapps-memory-sync-backups/$(date +%Y-%m-%d)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOCK_HELD=0
REMOTE_HOST=""
LOCAL_HOST="$(hostname -s 2>/dev/null || hostname)"
LOCK_TOKEN="$LOCAL_HOST:$$:$STAMP"

skip_or_fail() {
  echo "sync-memory-mini: $*" >&2
  [[ "$STRICT" -eq 0 ]] && exit 0
  exit 1
}

if [[ -n "$LOCAL_PEER_HOME" ]]; then
  REMOTE_HOME="${LOCAL_PEER_HOME%/}"
else
  REMOTE_HOME="$("${SSH[@]}" "$MINI_HOST" 'printf %s "$HOME"' 2>/dev/null || true)"
  [[ -n "$REMOTE_HOME" ]] || skip_or_fail "$MINI_HOST unreachable; skipped"
  REMOTE_HOST="$("${SSH[@]}" "$MINI_HOST" 'hostname -s 2>/dev/null || hostname' 2>/dev/null || true)"
  [[ -n "$REMOTE_HOST" ]] || REMOTE_HOST="mini"
  if [[ -n "$REMOTE_HOST" && "$LOCAL_HOST" == "$REMOTE_HOST" ]]; then
    skip_or_fail "refusing loopback sync on $LOCAL_HOST"
  fi
fi

release_lock() {
  [[ "$LOCK_HELD" -eq 1 ]] || return 0
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    if [[ "$(cat "$REMOTE_HOME/$LOCK_REL/owner" 2>/dev/null || true)" == "$LOCK_TOKEN" ]]; then
      rm -f "$REMOTE_HOME/$LOCK_REL/owner"
      rmdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null || true
    fi
  else
    "${SSH[@]}" "$MINI_HOST" "test \"\$(cat '$REMOTE_HOME/$LOCK_REL/owner' 2>/dev/null)\" = '$LOCK_TOKEN' && rm -f '$REMOTE_HOME/$LOCK_REL/owner' && rmdir '$REMOTE_HOME/$LOCK_REL' || true" >/dev/null 2>&1 || true
  fi
}
trap release_lock EXIT INT TERM

acquire_lock() {
  local owner owner_host owner_pid
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    mkdir -p "$REMOTE_HOME/.cache"
    if mkdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null; then
      printf '%s\n' "$LOCK_TOKEN" > "$REMOTE_HOME/$LOCK_REL/owner"
      LOCK_HELD=1
      return 0
    fi
    owner="$(cat "$REMOTE_HOME/$LOCK_REL/owner" 2>/dev/null || true)"
    owner_host="${owner%%:*}"
    owner_pid="${owner#*:}"
    owner_pid="${owner_pid%%:*}"
    if [[ -n "$owner" && "$owner_host" == "$LOCAL_HOST" && "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
      if [[ "$(cat "$REMOTE_HOME/$LOCK_REL/owner" 2>/dev/null || true)" == "$owner" ]]; then
        rm -f "$REMOTE_HOME/$LOCK_REL/owner"
        rmdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null || true
        if mkdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null; then
          printf '%s\n' "$LOCK_TOKEN" > "$REMOTE_HOME/$LOCK_REL/owner"
          LOCK_HELD=1
          return 0
        fi
      fi
    elif [[ -z "$owner" ]] && find "$REMOTE_HOME/$LOCK_REL" -type d -mmin +30 -print -quit 2>/dev/null | grep -q .; then
      rmdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null || true
      if mkdir "$REMOTE_HOME/$LOCK_REL" 2>/dev/null; then
        printf '%s\n' "$LOCK_TOKEN" > "$REMOTE_HOME/$LOCK_REL/owner"
        LOCK_HELD=1
        return 0
      fi
    fi
  else
    if "${SSH[@]}" "$MINI_HOST" "mkdir -p '$REMOTE_HOME/.cache'; mkdir '$REMOTE_HOME/$LOCK_REL' && printf '%s\\n' '$LOCK_TOKEN' > '$REMOTE_HOME/$LOCK_REL/owner'" >/dev/null 2>&1; then
      LOCK_HELD=1
      return 0
    fi
    owner="$("${SSH[@]}" "$MINI_HOST" "cat '$REMOTE_HOME/$LOCK_REL/owner' 2>/dev/null" 2>/dev/null || true)"
    owner_host="${owner%%:*}"
    owner_pid="${owner#*:}"
    owner_pid="${owner_pid%%:*}"
    if [[ -n "$owner" && "$owner_host" == "$LOCAL_HOST" && "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null && \
      "${SSH[@]}" "$MINI_HOST" "test \"\$(cat '$REMOTE_HOME/$LOCK_REL/owner' 2>/dev/null)\" = '$owner' && rm -f '$REMOTE_HOME/$LOCK_REL/owner' && rmdir '$REMOTE_HOME/$LOCK_REL' && mkdir '$REMOTE_HOME/$LOCK_REL' && printf '%s\\n' '$LOCK_TOKEN' > '$REMOTE_HOME/$LOCK_REL/owner'" >/dev/null 2>&1; then
      LOCK_HELD=1
      return 0
    elif [[ -z "$owner" ]] && "${SSH[@]}" "$MINI_HOST" "find '$REMOTE_HOME/$LOCK_REL' -type d -mmin +30 -print -quit 2>/dev/null | grep -q . && rmdir '$REMOTE_HOME/$LOCK_REL' && mkdir '$REMOTE_HOME/$LOCK_REL' && printf '%s\\n' '$LOCK_TOKEN' > '$REMOTE_HOME/$LOCK_REL/owner'" >/dev/null 2>&1; then
      LOCK_HELD=1
      return 0
    fi
  fi
  return 1
}

acquire_lock || skip_or_fail "another sync owns the Mini lock; skipped"

LOCAL_PROJECT="$(printf '%s' "$HOME/SaneApps" | sed 's#/#-#g')"
REMOTE_PROJECT="$(printf '%s' "$REMOTE_HOME/SaneApps" | sed 's#/#-#g')"

LOCAL_PATHS=(
  "$HOME/.claude/projects/$LOCAL_PROJECT/memory"
  "$HOME/SaneApps/.serena/memories"
  "$HOME/.codex/memories"
)
REMOTE_PATHS=(
  "$REMOTE_HOME/.claude/projects/$REMOTE_PROJECT/memory"
  "$REMOTE_HOME/SaneApps/.serena/memories"
  "$REMOTE_HOME/.codex/memories"
)
LABELS=(claude-file-memory serena-memories codex-memories)

mkdir -p "$HOME/$BACKUP_REL"

remote_mkdir() {
  local path="$1"
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    mkdir -p "$path"
  else
    "${SSH[@]}" "$MINI_HOST" "mkdir -p '$path'" >/dev/null 2>&1
  fi
}

remote_backup_once() {
  local source="$1" label="$2"
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    mkdir -p "$REMOTE_HOME/$BACKUP_REL"
    if [[ ! -e "$REMOTE_HOME/$BACKUP_REL/$label" ]]; then
      cp -a "$source" "$REMOTE_HOME/$BACKUP_REL/$label" || return 1
    fi
    [[ -d "$REMOTE_HOME/$BACKUP_REL/$label" ]]
  else
    "${SSH[@]}" "$MINI_HOST" "mkdir -p '$REMOTE_HOME/$BACKUP_REL' && { test -e '$REMOTE_HOME/$BACKUP_REL/$label' || cp -a '$source' '$REMOTE_HOME/$BACKUP_REL/$label'; } && test -d '$REMOTE_HOME/$BACKUP_REL/$label'" >/dev/null
  fi
}

local_backup_once() {
  local source="$1" label="$2"
  if [[ ! -e "$HOME/$BACKUP_REL/$label" ]]; then
    cp -a "$source" "$HOME/$BACKUP_REL/$label" || return 1
  fi
  [[ -d "$HOME/$BACKUP_REL/$label" ]]
}

rsync_remote() {
  local direction="$1" source="$2" destination="$3" suffix="$4"
  local opts=(-a --omit-dir-times --checksum --update --backup "--suffix=$suffix")
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    rsync "${opts[@]}" "$source/" "$destination/"
  elif [[ "$direction" == "pull" ]]; then
    rsync "${opts[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$MINI_HOST:$source/" "$destination/"
  else
    rsync "${opts[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$source/" "$MINI_HOST:$destination/"
  fi
}

pair_has_drift() {
  local local_dir="$1" remote_dir="$2" first second output
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    first="$(rsync -ani --omit-dir-times --checksum "$local_dir/" "$remote_dir/")" || return 2
    second="$(rsync -ani --omit-dir-times --checksum "$remote_dir/" "$local_dir/")" || return 2
  else
    first="$(rsync -ani --omit-dir-times --checksum -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$local_dir/" "$MINI_HOST:$remote_dir/")" || return 2
    second="$(rsync -ani --omit-dir-times --checksum -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$MINI_HOST:$remote_dir/" "$local_dir/")" || return 2
  fi
  output="$first$second"
  [[ -n "${output//[[:space:]]/}" ]]
}

sync_pair() {
  local local_dir="$1" remote_dir="$2" label="$3"
  mkdir -p "$local_dir"
  remote_mkdir "$remote_dir" || return 1

  if pair_has_drift "$local_dir" "$remote_dir"; then
    :
  else
    case "$?" in
      1)
        echo "  $label already in parity"
        return 0
        ;;
      *)
        echo "ERROR: $label parity probe failed" >&2
        return 1
        ;;
    esac
  fi

  local_backup_once "$local_dir" "$label" || {
    echo "ERROR: $label local baseline backup failed" >&2
    return 1
  }
  remote_backup_once "$remote_dir" "$label" || {
    echo "ERROR: $label peer baseline backup failed" >&2
    return 1
  }

  rsync_remote pull "$remote_dir" "$local_dir" ".sane-conflict-local-$STAMP" || return 1
  rsync_remote push "$local_dir" "$remote_dir" ".sane-conflict-peer-$STAMP" || return 1
  rsync_remote pull "$remote_dir" "$local_dir" ".sane-conflict-local-$STAMP" || return 1

  if pair_has_drift "$local_dir" "$remote_dir"; then
    echo "ERROR: $label checksum parity failed" >&2
    return 1
  else
    case "$?" in
      1) ;;
      *)
        echo "ERROR: $label post-sync parity probe failed" >&2
        return 1
        ;;
    esac
  fi
  echo "  synced $label both ways (backup-first, conflict-preserving, no-delete)"
}

echo "Memory sync Air<->Mini ($MINI_HOST); lock acquired; stamp=$STAMP"
failures=0
for i in 0 1 2; do
  sync_pair "${LOCAL_PATHS[$i]}" "${REMOTE_PATHS[$i]}" "${LABELS[$i]}" || failures=$((failures + 1))
done

if [[ "$failures" -gt 0 ]]; then
  echo "sync-memory-mini: $failures memory pair(s) failed" >&2
  exit 1
fi

if [[ -z "$LOCAL_PEER_HOME" ]]; then
  remote_snapshot_script="$REMOTE_HOME/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh"
  remote_snapshot_root="$REMOTE_HOME/SaneApps/infra/SaneProcess/outputs/dirty-work-snapshots"
  if ! "${SSH[@]}" "$MINI_HOST" "bash '$remote_snapshot_script' --snapshot-only && mkdir -p '$remote_snapshot_root'" >/dev/null; then
    echo "ERROR: Mini dirty-work snapshot generation failed" >&2
    exit 1
  fi
  snapshot_dest="$HOME/SaneApps/infra/SaneProcess/outputs/peer-dirty-backups/$REMOTE_HOST"
  mkdir -p "$snapshot_dest"
  if ! rsync -a --omit-dir-times -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" \
    "$MINI_HOST:$REMOTE_HOME/SaneApps/infra/SaneProcess/outputs/dirty-work-snapshots/" \
    "$snapshot_dest/"; then
    echo "ERROR: Mini dirty-work snapshot pull failed" >&2
    exit 1
  fi
fi
echo "Memory sync complete with checksum parity."
exit 0
