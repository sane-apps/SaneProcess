#!/bin/bash
# Safe Git sync + optional peer drift check.
# - Auto-pushes clean main/master commits.
# - Auto-pulls fast-forward when clean.
# - Never auto-commits. Never pushes dirty trees.
# - Flags dirty repos so "clean" cannot be a false positive.
# - Optional: compare local repo state against a peer machine.

set -euo pipefail

PEER_HOST=""
STRICT_DIRTY=1

usage() {
  cat <<'USAGE'
Usage: git-sync-safe.sh [--peer <host>] [--allow-dirty]

Options:
  --peer <host>   Compare each repo against a peer machine over SSH.
                  Marks mismatched branch/head/dirty state as an issue.
  --allow-dirty   Do not fail when working trees are dirty.
USAGE
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

ROOT="$HOME/SaneApps"
OUT_DIR="$ROOT/infra/SaneProcess/outputs"
LOG_FILE="$OUT_DIR/git_sync_safe.log"
NOW_LOCAL=$(date '+%Y-%m-%d %H:%M:%S')
PEER_HOME=""

mkdir -p "$OUT_DIR"

log() {
  echo "$*" | tee -a "$LOG_FILE"
}

repos=()
for d in "$ROOT/apps"/*; do
  [[ -d "$d/.git" ]] && repos+=("$d")
done
[[ -d "$ROOT/SaneAI/.git" ]] && repos+=("$ROOT/SaneAI")
[[ -d "$ROOT/infra/SaneProcess/.git" ]] && repos+=("$ROOT/infra/SaneProcess")

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "[$NOW_LOCAL] No repos found under $ROOT" >> "$LOG_FILE"
  exit 0
fi

{
  echo
  echo "================================================================"
  echo "[$NOW_LOCAL] Safe Git Sync Start"
  echo "Host: $(hostname)"
  [[ -n "$PEER_HOST" ]] && echo "Peer: $PEER_HOST"
  echo "================================================================"
} >> "$LOG_FILE"

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

  if ! git -C "$repo" fetch origin --prune >/dev/null 2>&1; then
    log "  - ERROR: fetch failed"
    issues=$((issues + 1))
    continue
  fi

  dirty=$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')
  local_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "")
  behind=$(git -C "$repo" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo "0")
  ahead=$(git -C "$repo" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo "0")

  log "  - branch=$branch dirty=$dirty behind=$behind ahead=$ahead"
  if [[ "$dirty" -gt 0 && "$STRICT_DIRTY" -eq 1 ]]; then
    log "  - WARNING: dirty working tree; requires manual reconcile"
    issues=$((issues + 1))
  fi

  if [[ "$dirty" -eq 0 && "$behind" -gt 0 ]]; then
    if git -C "$repo" pull --ff-only >/dev/null 2>&1; then
      log "  - Pulled: fast-forwarded $behind commit(s)"
    else
      log "  - ERROR: ff-only pull failed"
      issues=$((issues + 1))
    fi
  elif [[ "$behind" -gt 0 ]]; then
    log "  - WARNING: behind but dirty; skipped pull"
    issues=$((issues + 1))
  fi

  if [[ "$dirty" -eq 0 && "$ahead" -gt 0 ]]; then
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
      if git -C "$repo" push >/dev/null 2>&1; then
        log "  - Pushed: $ahead commit(s)"
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
