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

# --- CPU discipline -------------------------------------------------------
# 2026-07-24: three copies of this script ran concurrently on the Air at ~99%
# CPU each for up to 2h55m and made the machine hot. rsync --checksum hashes
# every file on every pass, so this is genuinely CPU-hungry work and must never
# compete with the owner's interactive session.
renice 10 $$ >/dev/null 2>&1 || true

# A sync of markdown memory files takes seconds. If it is still running after
# MAX_RUNTIME it is wedged, not working.
MAX_RUNTIME="${SANE_SYNC_MAX_RUNTIME:-900}"
STEP_TIMEOUT="${SANE_SYNC_STEP_TIMEOUT:-120}"

# Per-call bound. This is the load-bearing guard: a watchdog child can be killed
# out from under a script that survives orphaning (exactly what happened on
# 2026-07-24 — `timeout 300` killed the timeout process, the sync got reparented
# to launchd and ran another 68 minutes at 98.8% CPU with nothing left to stop
# it). A timeout wrapped around each rsync/ssh cannot be orphaned away, because
# it is in the call path rather than beside it.
TIMEOUT_BIN=""
for candidate in timeout gtimeout; do
  command -v "$candidate" >/dev/null 2>&1 && { TIMEOUT_BIN="$candidate"; break; }
done
RUN_BOUNDED() {
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$STEP_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Self-checked deadline. Unlike a watchdog child this cannot be orphaned away —
# the script asks itself, between steps, whether it has overstayed.
deadline_check() {
  if (( SECONDS > MAX_RUNTIME )); then
    echo "sync-memory-mini: exceeded ${MAX_RUNTIME}s at '$1' — aborting wedged sync" >&2
    exit 1
  fi
}

# Belt and braces: the watchdog still runs, but nothing depends on it surviving.
(
  sleep "$MAX_RUNTIME"
  if kill -0 "$$" 2>/dev/null; then
    echo "sync-memory-mini: exceeded ${MAX_RUNTIME}s — killing wedged sync (pid $$)" >&2
    kill -9 "$$" 2>/dev/null || true
  fi
) &
WATCHDOG_PID=$!

# --- local single-instance lock -------------------------------------------
# The Mini lock below protects the PEER's files. It does not stop this machine
# from running N copies of itself, which is exactly what happened: a stale
# ownerless remote lock got reclaimed by a second and third local process while
# the first was still running. This lock is local, atomic (mkdir), and holds the
# owning PID so a genuinely dead run can be reclaimed without a timer.
LOCAL_LOCK="$HOME/.cache/saneapps-memory-sync.local.lock"
mkdir -p "$HOME/.cache" 2>/dev/null || true
LOCAL_LOCK_HELD=0
if mkdir "$LOCAL_LOCK" 2>/dev/null; then
  LOCAL_LOCK_HELD=1
  printf '%s\n' "$$" > "$LOCAL_LOCK/pid"
else
  existing_pid="$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    skip_or_fail "another sync is already running locally (pid $existing_pid); skipped"
  fi
  # Owner is dead (or the dir was left behind by a kill -9): reclaim it whole.
  rm -rf "$LOCAL_LOCK" 2>/dev/null || true
  if mkdir "$LOCAL_LOCK" 2>/dev/null; then
    LOCAL_LOCK_HELD=1
    printf '%s\n' "$$" > "$LOCAL_LOCK/pid"
  else
    kill "$WATCHDOG_PID" 2>/dev/null || true
    skip_or_fail "could not take the local sync lock; skipped"
  fi
fi

release_local_lock() {
  [[ "$LOCAL_LOCK_HELD" -eq 1 ]] || return 0
  if [[ "$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$LOCAL_LOCK" 2>/dev/null || true
  fi
  kill "$WATCHDOG_PID" 2>/dev/null || true
}
trap release_local_lock EXIT INT TERM

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
    # `rm -rf` the whole lock dir in ONE step. The old two-step (rm owner, then
    # rmdir) left an OWNERLESS lock dir behind whenever the rmdir failed — and
    # acquire_lock treats "no owner file + dir older than 30 min" as stale and
    # reclaims it. That is how a second and third sync took a lock the first was
    # still holding on 2026-07-24. Never leave the dir without its owner file.
    if [[ "$(cat "$REMOTE_HOME/$LOCK_REL/owner" 2>/dev/null || true)" == "$LOCK_TOKEN" ]]; then
      rm -rf "$REMOTE_HOME/$LOCK_REL" 2>/dev/null || true
    fi
  else
    "${SSH[@]}" "$MINI_HOST" "test \"\$(cat '$REMOTE_HOME/$LOCK_REL/owner' 2>/dev/null)\" = '$LOCK_TOKEN' && rm -rf '$REMOTE_HOME/$LOCK_REL' || true" >/dev/null 2>&1 || true
  fi
}
# Both locks release on the same trap. A second `trap ... EXIT` would REPLACE
# the earlier one, silently leaking the local lock, so they are combined here.
trap 'release_lock; release_local_lock' EXIT INT TERM

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

# A `.sane-conflict-*` file is a terminal artifact: the losing side of a past
# conflict, kept as local evidence. It is not live memory, so re-hashing and
# re-shipping it on every pass is pure waste — and it compounds, because each
# run's conflicts add more dead weight for the next run to checksum. On
# 2026-07-24 these were 124 files and 8.6MB of the 21MB codex-memories tree
# (41%), re-checksummed on all five passes of every sync. Excluded from transfer
# and from parity, never deleted.
CONFLICT_EXCLUDE=(--exclude '*.sane-conflict-*')

# `~/.codex/memories` is a GIT REPO. Its `.git/` internals (index, refs, logs)
# change on every commit, so rsyncing them between two machines by mtime made
# EVERY sync conflict — 28 of the 124 conflict files on 2026-07-24 were git
# internals, each spawning another backup file for the next run to checksum.
# That is the compounding loop. Beyond the waste, shipping a live `.git/index`
# or `refs/heads/main` between machines can leave the repo pointing at objects
# the other side does not have. Git state syncs via git, never via rsync.
GIT_EXCLUDE=(--exclude '.git/' --exclude '.git/**')

rsync_remote() {
  local direction="$1" source="$2" destination="$3" suffix="$4"
  local opts=(-a --omit-dir-times --checksum --update --backup "--suffix=$suffix" "${CONFLICT_EXCLUDE[@]}" "${GIT_EXCLUDE[@]}")
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    RUN_BOUNDED rsync "${opts[@]}" "$source/" "$destination/"
  elif [[ "$direction" == "pull" ]]; then
    RUN_BOUNDED rsync "${opts[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$MINI_HOST:$source/" "$destination/"
  else
    RUN_BOUNDED rsync "${opts[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$source/" "$MINI_HOST:$destination/"
  fi
}

pair_has_drift() {
  local local_dir="$1" remote_dir="$2" first second output
  if [[ -n "$LOCAL_PEER_HOME" ]]; then
    first="$(RUN_BOUNDED rsync -ani --omit-dir-times --checksum "${CONFLICT_EXCLUDE[@]}" "${GIT_EXCLUDE[@]}" "$local_dir/" "$remote_dir/")" || return 2
    second="$(RUN_BOUNDED rsync -ani --omit-dir-times --checksum "${CONFLICT_EXCLUDE[@]}" "${GIT_EXCLUDE[@]}" "$remote_dir/" "$local_dir/")" || return 2
  else
    first="$(RUN_BOUNDED rsync -ani --omit-dir-times --checksum "${CONFLICT_EXCLUDE[@]}" "${GIT_EXCLUDE[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$local_dir/" "$MINI_HOST:$remote_dir/")" || return 2
    second="$(RUN_BOUNDED rsync -ani --omit-dir-times --checksum "${CONFLICT_EXCLUDE[@]}" "${GIT_EXCLUDE[@]}" -e "ssh -o ConnectTimeout=8 -o BatchMode=yes" "$MINI_HOST:$remote_dir/" "$local_dir/")" || return 2
  fi
  output="$first$second"
  # THE CPU BUG (fixed 2026-07-24). This was:
  #     [[ -n "${output//[[:space:]]/}" ]]
  # Bash's ${var//pat/} builds an entire new copy of the string to answer a
  # yes/no question. `rsync -ani` over ~1500 files emits thousands of lines, so
  # this burned ~99% CPU IN-PROCESS for hours with no child process running —
  # which is why it looked like rsync was slow when rsync had already exited.
  # grep short-circuits on the first non-space byte and is O(n).
  printf '%s' "$output" | grep -q '[^[:space:]]'

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
  deadline_check "${LABELS[$i]}"
  sync_pair "${LOCAL_PATHS[$i]}" "${REMOTE_PATHS[$i]}" "${LABELS[$i]}" || failures=$((failures + 1))
done
deadline_check "post-sync"

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
