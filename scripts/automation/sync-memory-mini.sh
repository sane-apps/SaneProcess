#!/bin/bash
# Conflict-preserving Air<->Mini synchronization for the file-backed memories
# used by Claude, Serena, and Codex. The shared AgentMemory service is separate.
#
# Production runs on the Air and connects to the Mini over `ssh mini`. It is
# intentionally no-delete. Each changed pair is backed up once per day, then
# synchronized pull -> push -> pull using checksum comparison and newest-mtime
# selection. Losing same-file versions and legacy `.sane-conflict-*` artifacts
# move to private, hashed archives outside active client memory.
#
# Session/LaunchAgent safety: an unreachable Mini or an already-held lock is a
# clean skip. Use --strict for an interactive verification run that must fail on
# an unreachable peer or post-sync checksum drift.
set -uo pipefail
umask 077

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
DISCOVERY_TMP=""

skip_or_fail() {
  echo "sync-memory-mini: $*" >&2
  [[ "$STRICT" -eq 0 ]] && exit 0
  exit 1
}

if [[ -n "$LOCAL_PEER_HOME" ]]; then
  REMOTE_HOME="${LOCAL_PEER_HOME%/}"
  REMOTE_HOST="${SANE_MEMORY_SYNC_PEER_HOST_LABEL:-local-peer}"
else
  REMOTE_HOME="$("${SSH[@]}" "$MINI_HOST" 'printf %s "$HOME"' 2>/dev/null || true)"
  [[ -n "$REMOTE_HOME" ]] || skip_or_fail "$MINI_HOST unreachable; skipped"
  REMOTE_HOST="$("${SSH[@]}" "$MINI_HOST" 'hostname -s 2>/dev/null || hostname' 2>/dev/null || true)"
  [[ -n "$REMOTE_HOST" ]] || REMOTE_HOST="mini"
  if [[ -n "$REMOTE_HOST" && "$LOCAL_HOST" == "$REMOTE_HOST" ]]; then
    skip_or_fail "refusing loopback sync on $LOCAL_HOST"
  fi
fi

LOCAL_ARCHIVE_ROOT="${SANE_MEMORY_CONFLICT_ARCHIVE_ROOT:-$HOME/SaneApps/infra/SaneProcess/outputs/memory-conflicts}"
REMOTE_ARCHIVE_ROOT="${SANE_MEMORY_CONFLICT_PEER_ARCHIVE_ROOT:-$REMOTE_HOME/SaneApps/infra/SaneProcess/outputs/memory-conflicts}"
LOCAL_ARCHIVE_RUN="$LOCAL_ARCHIVE_ROOT/$STAMP"
REMOTE_ARCHIVE_RUN="$REMOTE_ARCHIVE_ROOT/$STAMP"

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

cleanup() {
  release_lock
  if [[ -n "$DISCOVERY_TMP" && -d "$DISCOVERY_TMP" ]]; then
    rm -f "$DISCOVERY_TMP/local-serena.txt" \
      "$DISCOVERY_TMP/peer-serena.txt" "$DISCOVERY_TMP/serena-union.txt"
    rmdir "$DISCOVERY_TMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

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

# Emit project-local Serena memory directories relative to ~/SaneApps. `find`
# does not follow symlinked directories by default. Pruning output, preserved-
# archive, and nested-worktree trees prevents stale copies from becoming active
# memory roots; dependency and VCS trees are likewise not SaneApps projects.
discover_project_serena_paths() {
  local root="$1" path relative
  [[ -d "$root" ]] || return 0
  find "$root" \
    \( -type d \( -name outputs -o -name archive -o -name .worktrees -o -name .git -o -name node_modules -o -name vendor \) -prune \) -o \
    \( -type d -path '*/.serena/memories' -print0 -prune \) |
    while IFS= read -r -d '' path; do
      relative="${path#"$root"/}"
      [[ "$relative" == ".serena/memories" ]] && continue
      case "$relative" in
        */.serena/memories) ;;
        *) echo "ERROR: rejected unexpected Serena path: $relative" >&2; return 1 ;;
      esac
      case "$relative" in
        *[!A-Za-z0-9._/-]*)
          echo "ERROR: project Serena path contains unsupported characters: $relative" >&2
          return 1
          ;;
      esac
      printf '%s\n' "$relative"
    done
}

discover_project_serena_peer_paths() {
  local destination="$1"
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    discover_project_serena_paths "$REMOTE_HOME/SaneApps" > "$destination"
    return
  fi
  "${SSH[@]}" "$MINI_HOST" /bin/bash -s -- "$REMOTE_HOME/SaneApps" > "$destination" <<'REMOTE_SERENA_DISCOVERY'
set -uo pipefail
root="$1"
[[ -d "$root" ]] || exit 0
find "$root" \
  \( -type d \( -name outputs -o -name archive -o -name .worktrees -o -name .git -o -name node_modules -o -name vendor \) -prune \) -o \
  \( -type d -path '*/.serena/memories' -print0 -prune \) |
  while IFS= read -r -d '' path; do
    relative="${path#"$root"/}"
    [[ "$relative" == ".serena/memories" ]] && continue
    case "$relative" in
      */.serena/memories) ;;
      *) echo "ERROR: rejected unexpected Serena path: $relative" >&2; exit 1 ;;
    esac
    case "$relative" in
      *[!A-Za-z0-9._/-]*)
        echo "ERROR: project Serena path contains unsupported characters: $relative" >&2
        exit 1
        ;;
    esac
    printf '%s\n' "$relative"
  done
REMOTE_SERENA_DISCOVERY
}

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

DISCOVERY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sane-memory-discovery.XXXXXX")" || \
  skip_or_fail "could not create private Serena discovery workspace"
discover_project_serena_paths "$HOME/SaneApps" > "$DISCOVERY_TMP/local-serena.txt" || \
  skip_or_fail "local project Serena discovery failed"
discover_project_serena_peer_paths "$DISCOVERY_TMP/peer-serena.txt" || \
  skip_or_fail "peer project Serena discovery failed"
LC_ALL=C sort -u "$DISCOVERY_TMP/local-serena.txt" "$DISCOVERY_TMP/peer-serena.txt" \
  > "$DISCOVERY_TMP/serena-union.txt" || skip_or_fail "project Serena union failed"

while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  digest="$(printf '%s' "$relative" | /usr/bin/shasum -a 256 | awk '{print $1}' | cut -c1-16)" || \
    skip_or_fail "could not label project Serena path: $relative"
  index="${#LOCAL_PATHS[@]}"
  LOCAL_PATHS[$index]="$HOME/SaneApps/$relative"
  REMOTE_PATHS[$index]="$REMOTE_HOME/SaneApps/$relative"
  LABELS[$index]="project-serena-$digest"
done < "$DISCOVERY_TMP/serena-union.txt"

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

archive_legacy_conflicts_local() {
  local active_dir="$1" archive_branch="$2" path relative destination
  [[ -d "$active_dir" ]] || return 0
  while IFS= read -r -d '' path; do
    relative="${path#"$active_dir"/}"
    destination="$archive_branch/legacy/$relative"
    mkdir -p "$(dirname "$destination")" || return 1
    mv "$path" "$destination" || return 1
  done < <(find "$active_dir" -type f -name '*.sane-conflict-*' -print0)
}

archive_legacy_conflicts_remote() {
  local active_dir="$1" archive_branch="$2"
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    archive_legacy_conflicts_local "$active_dir" "$archive_branch"
    return
  fi
  "${SSH[@]}" "$MINI_HOST" /bin/bash -s -- "$active_dir" "$archive_branch" <<'REMOTE_ARCHIVE'
set -uo pipefail
umask 077
active_dir="$1"
archive_branch="$2"
[[ -d "$active_dir" ]] || exit 0
while IFS= read -r -d '' path; do
  relative="${path#"$active_dir"/}"
  destination="$archive_branch/legacy/$relative"
  mkdir -p "$(dirname "$destination")" || exit 1
  mv "$path" "$destination" || exit 1
done < <(find "$active_dir" -type f -name '*.sane-conflict-*' -print0)
REMOTE_ARCHIVE
}

write_archive_receipt_local() {
  local archive_root="$1" archive_run="$2" archive_branch="$3" host_role="$4" host_name="$5" label="$6" source_root="$7"
  local receipt temp kind path relative digest bytes found
  [[ -d "$archive_branch" ]] || return 0
  found="$(find "$archive_branch" -type f ! -name manifest.tsv -print -quit 2>/dev/null)"
  [[ -n "$found" ]] || return 0
  mkdir -p "$archive_branch" || return 1
  chmod 700 "$archive_root" "$archive_run" "$(dirname "$archive_branch")" "$archive_branch" || return 1
  receipt="$archive_branch/manifest.tsv"
  temp="$archive_branch/.manifest.tsv.tmp.$$"
  {
    printf 'schema\tsane-memory-conflict-archive-v1\n'
    printf 'stamp\t%s\n' "$STAMP"
    printf 'host_role\t%s\n' "$host_role"
    printf 'host\t%s\n' "$host_name"
    printf 'memory_label\t%s\n' "$label"
    printf 'source_root\t%s\n' "$source_root"
    printf 'columns\tkind\toriginal_relative_path\tsha256\tbytes\tarchived_relative_path\n'
    for kind in legacy rsync; do
      [[ -d "$archive_branch/$kind" ]] || continue
      while IFS= read -r -d '' path; do
        relative="${path#"$archive_branch/$kind/"}"
        digest="$(/usr/bin/shasum -a 256 "$path" | awk '{print $1}')" || exit 1
        bytes="$(wc -c < "$path" | tr -d '[:space:]')" || exit 1
        printf 'file\t%s\t%s\t%s\t%s\t%s/%s\n' "$kind" "$relative" "$digest" "$bytes" "$kind" "$relative"
      done < <(find "$archive_branch/$kind" -type f -print0)
    done
  } > "$temp" || { rm -f "$temp"; return 1; }
  chmod 600 "$temp" || return 1
  mv -f "$temp" "$receipt" || return 1
  find "$archive_branch" -type d -exec chmod 700 {} + || return 1
  find "$archive_branch" -type f -exec chmod 600 {} + || return 1
}

write_archive_receipt_remote() {
  local archive_root="$1" archive_run="$2" archive_branch="$3" host_role="$4" host_name="$5" label="$6" source_root="$7"
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    write_archive_receipt_local "$archive_root" "$archive_run" "$archive_branch" "$host_role" "$host_name" "$label" "$source_root"
    return
  fi
  "${SSH[@]}" "$MINI_HOST" /bin/bash -s -- \
    "$archive_root" "$archive_run" "$archive_branch" "$host_role" "$host_name" "$label" "$source_root" "$STAMP" <<'REMOTE_RECEIPT'
set -uo pipefail
umask 077
archive_root="$1"
archive_run="$2"
archive_branch="$3"
host_role="$4"
host_name="$5"
label="$6"
source_root="$7"
stamp="$8"
[[ -d "$archive_branch" ]] || exit 0
found="$(find "$archive_branch" -type f ! -name manifest.tsv -print -quit 2>/dev/null)"
[[ -n "$found" ]] || exit 0
mkdir -p "$archive_branch" || exit 1
chmod 700 "$archive_root" "$archive_run" "$(dirname "$archive_branch")" "$archive_branch" || exit 1
receipt="$archive_branch/manifest.tsv"
temp="$archive_branch/.manifest.tsv.tmp.$$"
{
  printf 'schema\tsane-memory-conflict-archive-v1\n'
  printf 'stamp\t%s\n' "$stamp"
  printf 'host_role\t%s\n' "$host_role"
  printf 'host\t%s\n' "$host_name"
  printf 'memory_label\t%s\n' "$label"
  printf 'source_root\t%s\n' "$source_root"
  printf 'columns\tkind\toriginal_relative_path\tsha256\tbytes\tarchived_relative_path\n'
  for kind in legacy rsync; do
    [[ -d "$archive_branch/$kind" ]] || continue
    while IFS= read -r -d '' path; do
      relative="${path#"$archive_branch/$kind/"}"
      digest="$(/usr/bin/shasum -a 256 "$path" | awk '{print $1}')" || exit 1
      bytes="$(wc -c < "$path" | tr -d '[:space:]')" || exit 1
      printf 'file\t%s\t%s\t%s\t%s\t%s/%s\n' "$kind" "$relative" "$digest" "$bytes" "$kind" "$relative"
    done < <(find "$archive_branch/$kind" -type f -print0)
  done
} > "$temp" || { rm -f "$temp"; exit 1; }
chmod 600 "$temp" || exit 1
mv -f "$temp" "$receipt" || exit 1
find "$archive_branch" -type d -exec chmod 700 {} + || exit 1
find "$archive_branch" -type f -exec chmod 600 {} + || exit 1
REMOTE_RECEIPT
}

rsync_remote() {
  local direction="$1" source="$2" destination="$3" backup_dir="$4"
  local opts=(-a --omit-dir-times --checksum --update --backup "--backup-dir=$backup_dir")
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
  local local_archive_branch="$LOCAL_ARCHIVE_RUN/$label/local"
  local remote_archive_branch="$REMOTE_ARCHIVE_RUN/$label/peer"
  mkdir -p "$local_dir"
  remote_mkdir "$remote_dir" || return 1

  archive_legacy_conflicts_local "$local_dir" "$local_archive_branch" || {
    echo "ERROR: $label local legacy conflict archival failed" >&2
    return 1
  }
  archive_legacy_conflicts_remote "$remote_dir" "$remote_archive_branch" || {
    echo "ERROR: $label peer legacy conflict archival failed" >&2
    return 1
  }
  write_archive_receipt_local "$LOCAL_ARCHIVE_ROOT" "$LOCAL_ARCHIVE_RUN" "$local_archive_branch" \
    local "$LOCAL_HOST" "$label" "$local_dir" || return 1
  write_archive_receipt_remote "$REMOTE_ARCHIVE_ROOT" "$REMOTE_ARCHIVE_RUN" "$remote_archive_branch" \
    peer "$REMOTE_HOST" "$label" "$remote_dir" || return 1

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

  rsync_remote pull "$remote_dir" "$local_dir" "$local_archive_branch/rsync" || {
    write_archive_receipt_local "$LOCAL_ARCHIVE_ROOT" "$LOCAL_ARCHIVE_RUN" "$local_archive_branch" local "$LOCAL_HOST" "$label" "$local_dir" || true
    return 1
  }
  rsync_remote push "$local_dir" "$remote_dir" "$remote_archive_branch/rsync" || {
    write_archive_receipt_remote "$REMOTE_ARCHIVE_ROOT" "$REMOTE_ARCHIVE_RUN" "$remote_archive_branch" peer "$REMOTE_HOST" "$label" "$remote_dir" || true
    return 1
  }
  rsync_remote pull "$remote_dir" "$local_dir" "$local_archive_branch/rsync" || {
    write_archive_receipt_local "$LOCAL_ARCHIVE_ROOT" "$LOCAL_ARCHIVE_RUN" "$local_archive_branch" local "$LOCAL_HOST" "$label" "$local_dir" || true
    return 1
  }

  write_archive_receipt_local "$LOCAL_ARCHIVE_ROOT" "$LOCAL_ARCHIVE_RUN" "$local_archive_branch" \
    local "$LOCAL_HOST" "$label" "$local_dir" || return 1
  write_archive_receipt_remote "$REMOTE_ARCHIVE_ROOT" "$REMOTE_ARCHIVE_RUN" "$remote_archive_branch" \
    peer "$REMOTE_HOST" "$label" "$remote_dir" || return 1

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
  echo "  synced $label both ways (backup-first, no-delete, private conflict archive)"
}

echo "Memory sync Air<->Mini ($MINI_HOST); lock acquired; stamp=$STAMP"
failures=0
i=0
while [[ "$i" -lt "${#LOCAL_PATHS[@]}" ]]; do
  sync_pair "${LOCAL_PATHS[$i]}" "${REMOTE_PATHS[$i]}" "${LABELS[$i]}" || failures=$((failures + 1))
  i=$((i + 1))
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
