#!/bin/bash
# Safe Git sync + optional peer drift check.
# - Auto-pushes clean main/master commits.
# - Auto-pulls fast-forward when clean.
# - Never auto-commits.
# - Flags dirty repos by default so "clean" cannot be a false positive.
# - Legacy reconcile mode is disabled by default; dirty canonical repos must be
#   resolved explicitly so real work cannot disappear into stashes.
# - Optional: compare local repo state against a peer machine.

set -euo pipefail

PEER_HOST=""
STRICT_DIRTY=1
RECONCILE_DIRTY=0
SNAPSHOT_ONLY=0
ROOT="$HOME/SaneApps"
OUT_DIR="$ROOT/infra/SaneProcess/outputs"
LOG_FILE="$OUT_DIR/git_sync_safe.log"
NOW_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
RUN_TAG=$(date '+%Y%m%d-%H%M%S')
HOST_TAG=$(hostname -s 2>/dev/null || hostname)
HOST_TAG=$(printf '%s' "$HOST_TAG" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')
PEER_HOME=""
SNAPSHOT_ROOT="$OUT_DIR/dirty-work-snapshots"

usage() {
  cat <<'USAGE'
Usage: git-sync-safe.sh [--peer <host>] [--allow-dirty] [--reconcile-dirty] [--snapshot-only]

Options:
  --peer <host>         Compare each repo against a peer machine over SSH.
                        Marks mismatched branch/head/dirty state as an issue.
  --allow-dirty         Do not fail when working trees are dirty.
  --reconcile-dirty     Legacy escape hatch. Refuses to auto-stash unless
                        SANEPROCESS_ALLOW_AUTO_STASH=1 is set explicitly.
  --snapshot-only       Preserve dirty patches/untracked files without fetch,
                        pull, push, stash, commit, or worktree mutation.
USAGE
}

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

refresh_repo_state() {
  local repo="$1"
  local branch="$2"

  dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
  local_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
  behind=$(git -C "$repo" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "0")
  ahead=$(git -C "$repo" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo "0")
}

prune_root_noise() {
  local path
  for path in "$ROOT/apps/.DS_Store" "$ROOT/infra/.DS_Store"; do
    [[ -f "$path" ]] || continue
    rm -f "$path"
    log "Pruned root noise: ${path#$ROOT/}"
  done
}

prune_repo_noise() {
  local repo="$1"
  local path rel count
  count=0

  while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    rel="${path#$repo/}"
    if git -C "$repo" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
      continue
    fi
    rm -f "$path"
    count=$((count + 1))
  done < <(find "$repo" -type f \( -name '.DS_Store' -o -name '*.orig' -o -name '*.rej' \) -print0)

  if [[ "$count" -gt 0 ]]; then
    log "  - Pruned $count untracked noise file(s)"
  fi
}

snapshot_path_allowed() {
  local path="$1"
  case "$path" in
    *.pem|*.p8|.env|*/.env|.env.*|*/.env.*) return 1 ;;
    *) return 0 ;;
  esac
}

snapshot_dirty_repo() {
  local repo="$1" name="$2" fingerprint snapshot_dir latest_file latest_fingerprint
  local tracked_list deleted_list staged_list untracked_list
  fingerprint=$(
    {
      git -C "$repo" status --porcelain=v1 -z
      while IFS= read -r -d '' tracked; do
        snapshot_path_allowed "$tracked" || continue
        printf 'tracked\0%s\0' "$tracked"
        shasum -a 256 "$repo/$tracked"
      done < <(git -C "$repo" diff --name-only --diff-filter=ACMRTUXB -z HEAD)
      while IFS= read -r -d '' deleted; do
        printf 'deleted\0%s\0' "$deleted"
      done < <(git -C "$repo" diff --name-only --diff-filter=D -z HEAD)
      while IFS= read -r -d '' untracked; do
        snapshot_path_allowed "$untracked" || continue
        shasum -a 256 "$repo/$untracked"
      done < <(git -C "$repo" ls-files --others --exclude-standard -z)
    } | shasum -a 256 | cut -d' ' -f1
  )
  latest_file="$SNAPSHOT_ROOT/$name/latest.txt"
  latest_fingerprint=""
  [[ -f "$latest_file" ]] && latest_fingerprint=$(sed -n '1p' "$latest_file")
  if [[ "$fingerprint" == "$latest_fingerprint" ]]; then
    log "  - Dirty snapshot already current: $fingerprint"
    return 0
  fi

  snapshot_dir="$SNAPSHOT_ROOT/$name/$RUN_TAG-$HOST_TAG-$fingerprint"
  mkdir -p "$snapshot_dir"
  chmod 700 "$snapshot_dir"
  git -C "$repo" status --short --branch > "$snapshot_dir/status.txt"
  git -C "$repo" rev-parse HEAD > "$snapshot_dir/base-head.txt"
  git -C "$repo" branch --show-current > "$snapshot_dir/branch.txt"
  git -C "$repo" remote get-url origin > "$snapshot_dir/origin.txt" 2>/dev/null || true
  printf '%s\n' "$fingerprint" > "$snapshot_dir/fingerprint.txt"

  # Preserve only the current dirty state. A traditional patch copies removed
  # lines and whole deleted-file preimages, which can resurrect credentials
  # that the worktree intentionally removed. Git HEAD already preserves the
  # base; this archive plus deletion/index manifests preserves the desired end
  # state without copying historical secret material.
  tracked_list="$snapshot_dir/tracked-current-files.zlist"
  while IFS= read -r -d '' tracked; do
    snapshot_path_allowed "$tracked" || continue
    printf '%s\0' "$tracked" >> "$tracked_list"
  done < <(git -C "$repo" diff --name-only --diff-filter=ACMRTUXB -z HEAD)
  if [[ -s "$tracked_list" ]]; then
    /usr/bin/tar -C "$repo" --null -T "$tracked_list" -czf "$snapshot_dir/tracked-current-files.tar.gz"
  fi

  deleted_list="$snapshot_dir/deleted-files.zlist"
  git -C "$repo" diff --name-only --diff-filter=D -z HEAD > "$deleted_list"
  staged_list="$snapshot_dir/staged-files.zlist"
  git -C "$repo" diff --cached --name-only -z > "$staged_list"

  untracked_list="$snapshot_dir/untracked-files.zlist"
  while IFS= read -r -d '' untracked; do
    snapshot_path_allowed "$untracked" || continue
    printf '%s\0' "$untracked" >> "$untracked_list"
  done < <(git -C "$repo" ls-files --others --exclude-standard -z)
  if [[ -s "$untracked_list" ]]; then
    /usr/bin/tar -C "$repo" --null -T "$untracked_list" -czf "$snapshot_dir/untracked-files.tar.gz"
  fi
  printf '%s\n%s\n' "$fingerprint" "$snapshot_dir" > "$latest_file"
  log "  - Preserved dirty work snapshot: $snapshot_dir"
}

is_syncable_repo_name() {
  local name="$1"
  case "$name" in
    *-reconcile-preview-*|*-release-main|*-release-peer|*-release-run|*_codex_*|*-codex-*|*codex_sync*|*codex_test*|*-preview-*|*-worktree-*)
      return 1
      ;;
  esac
  return 0
}

collect_repos() {
  local repo_path repo_name

  repos=()

  for repo_path in "$ROOT/apps"/*; do
    [[ -d "$repo_path/.git" ]] || continue
    repo_name=$(basename "$repo_path")
    if ! is_syncable_repo_name "$repo_name"; then
      log "SKIP transient repo: $repo_path"
      continue
    fi
    repos+=("$repo_path")
  done

  [[ -d "$ROOT/SaneAI/.git" ]] && repos+=("$ROOT/SaneAI")
  [[ -d "$ROOT/infra/SaneProcess/.git" ]] && repos+=("$ROOT/infra/SaneProcess")
  return 0
}

reconcile_dirty_repo() {
  local repo="$1"
  local label="auto-reconcile-$RUN_TAG-$HOST_TAG"
  local output=""

  if output=$(git -C "$repo" stash push -u -m "$label" 2>&1); then
    log "  - Reconciled dirty tree via stash '$label'"
    if [[ -n "$output" ]]; then
      log "  - $output"
    fi
    return 0
  fi

  log "  - ERROR: auto-stash failed"
  if [[ -n "$output" ]]; then
    log "  - $output"
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --peer)
      [[ $# -ge 2 ]] || { echo "ERROR: --peer requires a host" >&2; exit 2; }
      PEER_HOST="$2"
      shift 2
      ;;
    --allow-dirty)
      STRICT_DIRTY=0
      shift
      ;;
    --reconcile-dirty)
      RECONCILE_DIRTY=1
      shift
      ;;
    --snapshot-only)
      SNAPSHOT_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$OUT_DIR"

if [[ "$RECONCILE_DIRTY" -eq 1 && "${SANEPROCESS_ALLOW_AUTO_STASH:-0}" != "1" ]]; then
  log "ERROR: --reconcile-dirty no longer auto-stashes canonical repos by default."
  log "Resolve dirty work explicitly, or set SANEPROCESS_ALLOW_AUTO_STASH=1 for a one-off manual recovery."
  exit 2
fi

if [[ "$SNAPSHOT_ONLY" -eq 0 ]]; then
  prune_root_noise
fi

{
  echo
  echo "================================================================"
  echo "[$NOW_LOCAL] Safe Git Sync Start"
  echo "Host: $(hostname)"
  [[ -n "$PEER_HOST" ]] && echo "Peer: $PEER_HOST"
  echo "Reconcile dirty: $RECONCILE_DIRTY"
  echo "================================================================"
} >> "$LOG_FILE"

collect_repos

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "[$NOW_LOCAL] No repos found under $ROOT" >> "$LOG_FILE"
  exit 0
fi

issues=0
if [[ -n "$PEER_HOST" ]]; then
  if ! PEER_HOME=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$PEER_HOST" 'printf %s "$HOME"' 2>/dev/null); then
    log "WARNING: Could not resolve peer home via SSH ($PEER_HOST); continuing local-only checks"
    PEER_HOST=""
    issues=$((issues + 1))
  fi
fi

for repo in "${repos[@]}"; do
  name=$(basename "$repo")
  log ""
  log "[$name] $repo"

  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "  - Skipped: not a git repo"
    continue
  fi

  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    log "  - Skipped: no origin remote"
    continue
  fi

  branch=$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
  if [[ "$branch" == "DETACHED" ]]; then
    log "  - Skipped: detached HEAD"
    continue
  fi

  if [[ "$SNAPSHOT_ONLY" -eq 1 ]]; then
    dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
    log "  - snapshot-only branch=$branch dirty=$dirty"
    [[ "$dirty" -gt 0 ]] && snapshot_dirty_repo "$repo" "$name"
    continue
  fi

  prune_repo_noise "$repo"

  if ! git -C "$repo" fetch origin --prune >/dev/null 2>&1; then
    log "  - ERROR: fetch failed"
    issues=$((issues + 1))
    continue
  fi

  refresh_repo_state "$repo" "$branch"

  log "  - branch=$branch dirty=$dirty behind=$behind ahead=$ahead"

  if [[ "$dirty" -gt 0 ]]; then
    snapshot_dirty_repo "$repo" "$name"
  fi

  if [[ "$dirty" -gt 0 && "$RECONCILE_DIRTY" -eq 1 ]]; then
    if reconcile_dirty_repo "$repo"; then
      refresh_repo_state "$repo" "$branch"
      log "  - post-reconcile dirty=$dirty behind=$behind ahead=$ahead"
    else
      issues=$((issues + 1))
      continue
    fi
  fi

  if [[ "$dirty" -gt 0 && "$STRICT_DIRTY" -eq 1 ]]; then
    log "  - WARNING: dirty working tree; requires manual reconcile"
    issues=$((issues + 1))
  fi

  if [[ "$dirty" -eq 0 && "$behind" -gt 0 ]]; then
    pulled_count="$behind"
    if git -C "$repo" pull --ff-only >/dev/null 2>&1; then
      refresh_repo_state "$repo" "$branch"
      log "  - Pulled: fast-forwarded $pulled_count commit(s)"
    else
      log "  - ERROR: ff-only pull failed"
      issues=$((issues + 1))
    fi
  elif [[ "$behind" -gt 0 ]]; then
    log "  - WARNING: behind but dirty; skipped pull"
    issues=$((issues + 1))
  fi

  if [[ "$dirty" -eq 0 && "$ahead" -gt 0 ]]; then
    pushed_count="$ahead"
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
      if git -C "$repo" push >/dev/null 2>&1; then
        refresh_repo_state "$repo" "$branch"
        log "  - Pushed: $pushed_count commit(s)"
      else
        log "  - ERROR: push failed"
        issues=$((issues + 1))
      fi
    else
      log "  - WARNING: ahead on non-main branch '$branch'; skipped auto-push"
      issues=$((issues + 1))
    fi
  elif [[ "$ahead" -gt 0 ]]; then
    log "  - WARNING: ahead but dirty; skipped push"
    issues=$((issues + 1))
  fi

  if [[ -n "$PEER_HOST" ]]; then
    rel="${repo#$ROOT/}"
    peer_repo="$PEER_HOME/SaneApps/$rel"

    if ! peer_report=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$PEER_HOST" \
      "repo=\"$peer_repo\"; if [ ! -d \"\$repo/.git\" ] && [ \"$rel\" = \"SaneAI\" ]; then repo=\"$PEER_HOME/SaneApps/apps/SaneAI\"; fi; if [ -d \"\$repo/.git\" ]; then printf 'HEAD=%s\nBRANCH=%s\nDIRTY=%s\nPATH=%s\n' \"\$(git -C \"\$repo\" rev-parse HEAD 2>/dev/null || echo)\" \"\$(git -C \"\$repo\" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)\" \"\$(git -C \"\$repo\" status --porcelain 2>/dev/null | wc -l | tr -d ' ')\" \"\$repo\"; else echo 'MISSING=1'; fi" 2>/dev/null); then
      log "  - ERROR: peer check failed ($PEER_HOST:$peer_repo)"
      issues=$((issues + 1))
      continue
    fi

    peer_missing=""
    peer_head=""
    peer_branch=""
    peer_dirty=""
    peer_path="$peer_repo"
    while IFS='=' read -r key value; do
      case "$key" in
        MISSING) peer_missing="$value" ;;
        HEAD) peer_head="$value" ;;
        BRANCH) peer_branch="$value" ;;
        DIRTY) peer_dirty="$value" ;;
        PATH) peer_path="$value" ;;
      esac
    done <<< "$peer_report"

    if [[ "$peer_missing" == "1" ]]; then
      log "  - WARNING: peer repo missing ($PEER_HOST:$peer_repo)"
      issues=$((issues + 1))
      continue
    fi

    if [[ -z "$peer_head" || -z "$peer_branch" || -z "$peer_dirty" ]]; then
      log "  - ERROR: peer state parse failed ($PEER_HOST:$peer_repo)"
      issues=$((issues + 1))
      continue
    fi

    if [[ "$branch" != "$peer_branch" ]]; then
      log "  - WARNING: branch drift local=$branch peer=$peer_branch"
      issues=$((issues + 1))
    fi
    if [[ -n "$local_head" && "$local_head" != "$peer_head" ]]; then
      log "  - WARNING: HEAD drift local=${local_head:0:12} peer=${peer_head:0:12}"
      issues=$((issues + 1))
    fi
    if [[ "$peer_dirty" != "0" ]]; then
      log "  - WARNING: peer dirty=$peer_dirty ($PEER_HOST:$peer_path)"
      issues=$((issues + 1))
    fi
  fi
done

log ""
if [[ "$issues" -gt 0 ]]; then
  log "Safe Git Sync finished with $issues warning/error item(s)."
  osascript -e "display notification \"$issues repo sync item(s) need attention\" with title \"SaneApps Git Sync\"" >/dev/null 2>&1 || true
  exit 1
else
  log "Safe Git Sync finished clean."
  exit 0
fi
