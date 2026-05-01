#!/bin/bash
# mini-prepare-automation-root.sh - Create/update clean automation clones on mini
# Usage:
#   AUTOMATION_ROOT=~/SaneApps-automation SANE_SOURCE_ROOT=~/SaneApps \
#     bash ~/SaneApps/infra/scripts/mini-prepare-automation-root.sh

set -euo pipefail

SOURCE_ROOT="${SANE_SOURCE_ROOT:-$HOME/SaneApps}"
AUTOMATION_ROOT="${AUTOMATION_ROOT:-$HOME/SaneApps-automation}"
AUTOMATION_MARKER="$AUTOMATION_ROOT/.sane_automation_root"
PREPARE_LOCK="$AUTOMATION_ROOT/.prepare.lock"
FAILURES=0
UPDATED=0
CLONED=0
SKIPPED=0
WARNINGS=0

cleanup_prepare_lock() {
  if [ -n "${PREPARE_LOCK_HELD:-}" ] && [ -d "$PREPARE_LOCK" ]; then
    rmdir "$PREPARE_LOCK" 2>/dev/null || true
  fi
}

trap cleanup_prepare_lock EXIT INT TERM

acquire_prepare_lock() {
  local waited=0
  local wait_limit_sec="${PREPARE_LOCK_WAIT_SEC:-600}"
  local stale_after_min="${PREPARE_LOCK_STALE_MIN:-45}"

  mkdir -p "$AUTOMATION_ROOT"

  while ! mkdir "$PREPARE_LOCK" 2>/dev/null; do
    if [ -n "$(find "$PREPARE_LOCK" -maxdepth 0 -mmin +"$stale_after_min" -print -quit 2>/dev/null)" ]; then
      echo "WARN  removing stale automation prep lock: $PREPARE_LOCK"
      rmdir "$PREPARE_LOCK" 2>/dev/null || true
      continue
    fi

    if [ "$waited" -ge "$wait_limit_sec" ]; then
      echo "FAIL  automation prep lock busy after ${wait_limit_sec}s: $PREPARE_LOCK"
      return 1
    fi

    sleep 10
    waited=$((waited + 10))
  done

  PREPARE_LOCK_HELD=1
  return 0
}

cleanup_stale_git_index_locks() {
  local lock_file removed=0
  local stale_after_min="${GIT_INDEX_LOCK_STALE_MIN:-30}"

  if ps axww -o pid= -o comm= -o command= | awk -v root="$AUTOMATION_ROOT" '
    $2 ~ /(^|\/)git$/ && index($0, root) { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    return 0
  fi

  while IFS= read -r lock_file; do
    [ -n "$lock_file" ] || continue
    echo "WARN  removing stale git index lock: $lock_file"
    rm -f "$lock_file"
    removed=$((removed + 1))
  done < <(find "$AUTOMATION_ROOT" -path "*/.git/index.lock" -mmin +"$stale_after_min" -print 2>/dev/null)

  if [ "$removed" -gt 0 ]; then
    echo "CLEAN automation git locks [$removed removed]"
  fi
}

is_syncable_repo_name() {
  local name="$1"
  case "$name" in
    *-reconcile-preview-*|*-release-main|*-release-peer|*_codex_*|*-codex-*|*codex_sync*|*codex_test*|*-preview-*|*-worktree-*)
      return 1
      ;;
  esac
  return 0
}

default_branch_for_repo() {
  local repo="$1"
  local branch=""
  branch=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  if [ -z "$branch" ]; then
    branch=$(git -C "$repo" remote show origin 2>/dev/null | awk '/HEAD branch:/ {print $NF; exit}')
  fi
  if [ -z "$branch" ]; then
    branch="main"
  fi
  printf '%s' "$branch"
}

managed_overlay_path_allowed() {
  local rel_path="$1"
  local repo_path="$2"

  case "$rel_path:$repo_path" in
    apps/SaneAI:training_data/train.jsonl|\
    apps/SaneAI:training_data/valid.jsonl|\
    apps/SaneAI:training_data/merge_training_data.py|\
    apps/SaneAI:training_data/system_prompt.txt|\
    apps/SaneAI:training_data/lora_config_mini.yaml|\
    apps/SaneAI:training_data/eval_*.jsonl|\
    apps/SaneAI:training_data/*.yaml|\
    apps/SaneAI:training_data/*.yml|\
    apps/SaneAI:training_data/challenger_configs/*|\
    apps/SaneClip:training_data/train.jsonl|\
    apps/SaneClip:training_data/valid.jsonl|\
    apps/SaneClip:training_data/test.jsonl|\
    apps/SaneSync:training_data/train.jsonl|\
    apps/SaneSync:training_data/valid.jsonl|\
    apps/SaneSync:training_data/test.jsonl|\
    apps/SaneSync:training_data/challenger_configs/*|\
    apps/SaneSync:models/sweeps/*|\
    apps/SaneSync:models/production_adapter/*|\
    apps/SaneVideo:training_data/train.jsonl|\
    apps/SaneVideo:training_data/valid.jsonl|\
    apps/SaneVideo:training_data/system_prompt.txt|\
    apps/SaneVideo:training_data/lora_config_mini.yaml|\
    apps/SaneVideo:training_data/eval_*.jsonl|\
    apps/SaneVideo:training_data/*.yaml|\
    apps/SaneVideo:training_data/*.yml|\
    apps/SaneVideo:training_data/challenger_configs/*|\
    apps/SaneVideo:models/sweeps/*|\
    apps/SaneVideo:models/production_adapter/*|\
    apps/SaneVideo:Tests/Assets/*)
      return 0
      ;;
  esac

  return 1
}

reset_managed_overlay_paths() {
  local target_repo="$1"
  local rel_path="$2"
  local entry status path
  local tracked_reset=0
  local untracked_reset=0
  local tracked_count=0
  local unexpected_count=0
  local untracked_count=0
  local -a tracked_paths unexpected_paths untracked_paths

  tracked_paths=()
  unexpected_paths=()
  untracked_paths=()

  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    status="${entry:0:2}"
    path="${entry:3}"

    if ! managed_overlay_path_allowed "$rel_path" "$path"; then
      if [ "$unexpected_count" -eq 0 ]; then
        unexpected_paths=("$path")
      else
        unexpected_paths=("${unexpected_paths[@]}" "$path")
      fi
      unexpected_count=$((unexpected_count + 1))
      continue
    fi

    case "$status" in
      \?\?)
        if [ "$untracked_count" -eq 0 ]; then
          untracked_paths=("$path")
        else
          untracked_paths=("${untracked_paths[@]}" "$path")
        fi
        untracked_count=$((untracked_count + 1))
        ;;
      *)
        if [ "$tracked_count" -eq 0 ]; then
          tracked_paths=("$path")
        else
          tracked_paths=("${tracked_paths[@]}" "$path")
        fi
        tracked_count=$((tracked_count + 1))
        ;;
    esac
  done < <(git -C "$target_repo" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)

  if [ "$unexpected_count" -gt 0 ]; then
    echo "WARN  $rel_path unexpected dirt remains: ${unexpected_paths[0]}"
    return 1
  fi

  if [ "$tracked_count" -gt 0 ]; then
    git -C "$target_repo" restore --source=HEAD --staged --worktree -- "${tracked_paths[@]}" >/dev/null 2>&1
    tracked_reset="$tracked_count"
  fi

  if [ "$untracked_count" -gt 0 ]; then
    git -C "$target_repo" clean -fd -- "${untracked_paths[@]}" >/dev/null 2>&1
    untracked_reset="$untracked_count"
  fi

  echo "CLEAN $rel_path (reset managed overlay: ${tracked_reset} tracked, ${untracked_reset} untracked)"
  return 0
}

prepare_repo() {
  local source_repo="$1"
  local rel_path="$2"
  local repo_name target_repo origin_url branch dirty_count

  repo_name=$(basename "$source_repo")
  if ! is_syncable_repo_name "$repo_name"; then
    echo "SKIP  $rel_path (preview/temp repo)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  origin_url=$(git -C "$source_repo" remote get-url origin 2>/dev/null || true)
  if [ -z "$origin_url" ]; then
    echo "SKIP  $rel_path (missing origin)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi

  branch=$(default_branch_for_repo "$source_repo")
  target_repo="$AUTOMATION_ROOT/$rel_path"
  mkdir -p "$(dirname "$target_repo")"

  if [ ! -d "$target_repo/.git" ]; then
    echo "CLONE $rel_path [$branch]"
    git clone --quiet --branch "$branch" --single-branch "$origin_url" "$target_repo"
    CLONED=$((CLONED + 1))
    return 0
  fi

  dirty_count=$(git -C "$target_repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty_count" != "0" ]; then
    if ! reset_managed_overlay_paths "$target_repo" "$rel_path"; then
      echo "FAIL  $rel_path (automation repo dirty: $dirty_count)"
      FAILURES=$((FAILURES + 1))
      return 1
    fi

    dirty_count=$(git -C "$target_repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dirty_count" != "0" ]; then
      echo "FAIL  $rel_path (automation repo still dirty: $dirty_count)"
      FAILURES=$((FAILURES + 1))
      return 1
    fi
  fi

  if ! git -C "$target_repo" fetch origin --prune >/dev/null 2>&1; then
    echo "FAIL  $rel_path (fetch failed)"
    FAILURES=$((FAILURES + 1))
    return 1
  fi

  if ! git -C "$target_repo" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$target_repo" checkout --quiet -b "$branch" "origin/$branch"
  else
    git -C "$target_repo" checkout --quiet "$branch"
  fi

  if git -C "$target_repo" pull --ff-only origin "$branch" >/dev/null 2>&1; then
    echo "SYNC  $rel_path [$branch]"
    UPDATED=$((UPDATED + 1))
  else
    echo "FAIL  $rel_path (ff-only pull failed)"
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

generate_media_fixture() {
  local output_path="$1"
  local mode="$2"
  local duration="${3:-5}"
  local size="${4:-640x480}"
  local -a video_args audio_args

  if [ -f "$output_path" ]; then
    return 0
  fi

  mkdir -p "$(dirname "$output_path")"

  if [ "$mode" = "silence" ]; then
    video_args=(-f lavfi -i "color=c=black:size=${size}:rate=30:duration=${duration}")
    audio_args=(-f lavfi -i "anullsrc=r=44100:cl=stereo")
  else
    video_args=(-f lavfi -i "testsrc=duration=${duration}:size=${size}:rate=30")
    audio_args=(-f lavfi -i "sine=frequency=660:sample_rate=44100:duration=${duration}")
  fi

  ffmpeg -loglevel error \
    "${video_args[@]}" \
    "${audio_args[@]}" \
    -shortest \
    -c:v libx264 \
    -preset ultrafast \
    -crf 28 \
    -pix_fmt yuv420p \
    -c:a aac \
    -ar 44100 \
    -movflags +faststart \
    -y "$output_path" >/dev/null 2>&1
}

copy_if_changed() {
  local source_path="$1"
  local target_path="$2"

  mkdir -p "$(dirname "$target_path")"

  if [ -f "$target_path" ] && cmp -s "$source_path" "$target_path"; then
    return 1
  fi

  cp "$source_path" "$target_path"
  return 0
}

source_training_root_candidates() {
  local app_name="$1"
  local -a candidates
  local candidate

  # Order matters: the first existing path wins. Prefer synced repos under
  # apps/ so stale top-level compatibility checkouts cannot overwrite fresh data.
  candidates=(
    "$SOURCE_ROOT/apps/$app_name/training_data"
    "$SOURCE_ROOT/$app_name/training_data"
  )

  for candidate in "${candidates[@]}"; do
    printf '%s\n' "$candidate"
  done
}

resolve_source_training_path() {
  local app_name="$1"
  local rel_path="$2"
  local candidate_root candidate_path fallback_path=""

  while IFS= read -r candidate_root; do
    [ -n "$candidate_root" ] || continue
    if [ -z "$fallback_path" ]; then
      fallback_path="$candidate_root/$rel_path"
    fi
    candidate_path="$candidate_root/$rel_path"
    if [ -e "$candidate_path" ]; then
      printf '%s' "$candidate_path"
      return 0
    fi
  done < <(source_training_root_candidates "$app_name")

  printf '%s' "$fallback_path"
  return 1
}

target_repo_tracks_training_path() {
  local app_name="$1"
  local rel_path="$2"
  local target_repo="$AUTOMATION_ROOT/apps/$app_name"

  [ -d "$target_repo/.git" ] || return 1
  git -C "$target_repo" ls-files --error-unmatch -- "training_data/$rel_path" >/dev/null 2>&1
}

target_repo_tracks_training_prefix() {
  local app_name="$1"
  local rel_prefix="$2"
  local target_repo="$AUTOMATION_ROOT/apps/$app_name"

  [ -d "$target_repo/.git" ] || return 1
  git -C "$target_repo" ls-files | grep -q "^training_data/$rel_prefix/"
}

source_training_dir_for_app() {
  local app_name="$1"
  local candidate_root

  while IFS= read -r candidate_root; do
    [ -n "$candidate_root" ] || continue
    if [ -d "$candidate_root" ]; then
      printf '%s' "$candidate_root"
      return 0
    fi
  done < <(source_training_root_candidates "$app_name")

  printf '%s' "$(source_training_root_candidates "$app_name" | head -1)"
  return 1
}

hydrate_training_dataset() {
  local app_name="$1"
  shift
  local source_dir
  local target_dir="$AUTOMATION_ROOT/apps/$app_name/training_data"
  local copied=0
  local unchanged=0
  local missing=0
  local rel_file source_file target_file

  [ -d "$AUTOMATION_ROOT/apps/$app_name" ] || return 0

  source_dir=$(source_training_dir_for_app "$app_name")

  if [ ! -d "$source_dir" ]; then
    echo "WARN  apps/$app_name training_data missing in source root"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  for rel_file in "$@"; do
    source_file=$(resolve_source_training_path "$app_name" "$rel_file")
    target_file="$target_dir/$rel_file"

    if target_repo_tracks_training_path "$app_name" "$rel_file"; then
      echo "KEEP  apps/$app_name/training_data/$rel_file [git-managed]"
      unchanged=$((unchanged + 1))
      continue
    fi

    if [ ! -f "$source_file" ]; then
      echo "WARN  apps/$app_name/training_data/$rel_file missing in source root"
      WARNINGS=$((WARNINGS + 1))
      missing=$((missing + 1))
      continue
    fi

    if copy_if_changed "$source_file" "$target_file"; then
      echo "DATA  apps/$app_name/training_data/$rel_file"
      copied=$((copied + 1))
    else
      unchanged=$((unchanged + 1))
    fi
  done

  echo "SYNC  apps/$app_name training data [$copied copied, $unchanged unchanged, $missing missing]"
}

hydrate_training_support_files() {
  local app_name="$1"
  shift
  local source_dir
  local target_dir="$AUTOMATION_ROOT/apps/$app_name/training_data"
  local copied=0
  local unchanged=0
  local missing=0
  local pattern source_file rel_file target_file matched

  [ -d "$AUTOMATION_ROOT/apps/$app_name" ] || return 0
  source_dir=$(source_training_dir_for_app "$app_name")
  [ -d "$source_dir" ] || return 0

  for pattern in "$@"; do
    matched=0
    while IFS= read -r source_dir; do
      [ -d "$source_dir" ] || continue
      for source_file in "$source_dir"/$pattern; do
        if [ ! -f "$source_file" ]; then
          continue
        fi
        matched=1
        rel_file="${source_file#$source_dir/}"
        target_file="$target_dir/$rel_file"

        if target_repo_tracks_training_path "$app_name" "$rel_file"; then
          echo "KEEP  apps/$app_name/training_data/$rel_file [git-managed]"
          unchanged=$((unchanged + 1))
          continue
        fi

        if copy_if_changed "$source_file" "$target_file"; then
          echo "DATA  apps/$app_name/training_data/$rel_file"
          copied=$((copied + 1))
        else
          unchanged=$((unchanged + 1))
        fi
      done
    done < <(source_training_root_candidates "$app_name")

    if [ "$matched" -eq 0 ]; then
      echo "WARN  apps/$app_name/training_data/$pattern missing in source root"
      WARNINGS=$((WARNINGS + 1))
      missing=$((missing + 1))
    fi
  done

  echo "SYNC  apps/$app_name training support [$copied copied, $unchanged unchanged, $missing missing]"
}

hydrate_training_subdir() {
  local app_name="$1"
  local rel_dir="$2"
  local source_dir
  local target_dir="$AUTOMATION_ROOT/apps/$app_name/training_data/$rel_dir"

  [ -d "$AUTOMATION_ROOT/apps/$app_name" ] || return 0
  source_dir=$(resolve_source_training_path "$app_name" "$rel_dir")
  if [ ! -d "$source_dir" ]; then
    echo "WARN  apps/$app_name/training_data/$rel_dir missing in source root"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  if target_repo_tracks_training_prefix "$app_name" "$rel_dir"; then
    echo "KEEP  apps/$app_name/training_data/$rel_dir [git-managed]"
    return 0
  fi

  mkdir -p "$target_dir"
  if [ "$rel_dir" = "challenger_configs" ]; then
    # Compatibility path for legacy repos where challenger configs are not tracked.
    # Tracked config dirs are kept above; new candidates must be committed.
    rsync -a "$source_dir"/ "$target_dir"/ >/dev/null 2>&1
    echo "SYNC  apps/$app_name/training_data/$rel_dir [merged]"
  else
    rsync -a --delete "$source_dir"/ "$target_dir"/ >/dev/null 2>&1
    echo "SYNC  apps/$app_name/training_data/$rel_dir [mirrored]"
  fi
}

hydrate_sanevideo_assets() {
  local video_root="$AUTOMATION_ROOT/apps/SaneVideo"
  local assets_dir="$video_root/Tests/Assets"
  local generated=0

  [ -d "$video_root" ] || return 0

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "WARN  apps/SaneVideo test assets not generated (ffmpeg missing)"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  mkdir -p "$assets_dir"

  for name in test_video.mp4 stress_test_clip.mp4 file.mov test.mov German.MOV IMG_0422.MOV IMG_7668.MOV IMG_6091.MOV; do
    if [ ! -f "$assets_dir/$name" ]; then
      echo "ASSET apps/SaneVideo/$name"
      generate_media_fixture "$assets_dir/$name" "tone"
      generated=$((generated + 1))
    fi
  done

  if [ ! -f "$assets_dir/test_silence.mp4" ]; then
    echo "ASSET apps/SaneVideo/test_silence.mp4"
    generate_media_fixture "$assets_dir/test_silence.mp4" "silence"
    generated=$((generated + 1))
  fi

  if [ "$generated" -gt 0 ]; then
    echo "SYNC  apps/SaneVideo test assets [$generated generated]"
  else
    echo "SYNC  apps/SaneVideo test assets [already present]"
  fi
}

mkdir -p "$AUTOMATION_ROOT/apps" "$AUTOMATION_ROOT/infra"
acquire_prepare_lock || exit 1
cleanup_stale_git_index_locks
printf 'managed_by=mini-prepare-automation-root\nsource_root=%s\nprepared_at=%s\n' \
  "$SOURCE_ROOT" "$(date '+%Y-%m-%d %H:%M:%S')" > "$AUTOMATION_MARKER"

for base in apps infra; do
  for source_repo in "$SOURCE_ROOT/$base"/*; do
    [ -d "$source_repo/.git" ] || continue
    rel_path="${source_repo#$SOURCE_ROOT/}"
    prepare_repo "$source_repo" "$rel_path" || true
  done
done

hydrate_training_dataset "SaneSync" train.jsonl valid.jsonl test.jsonl
hydrate_training_dataset "SaneClip" train.jsonl valid.jsonl test.jsonl
hydrate_training_dataset "SaneAI" train.jsonl valid.jsonl
hydrate_training_dataset "SaneVideo" train.jsonl valid.jsonl
hydrate_training_support_files "SaneAI" merge_training_data.py system_prompt.txt lora_config_mini.yaml eval_*.jsonl
hydrate_training_support_files "SaneVideo" system_prompt.txt lora_config_mini.yaml eval_*.jsonl
hydrate_training_subdir "SaneAI" challenger_configs
hydrate_training_subdir "SaneSync" challenger_configs
hydrate_training_subdir "SaneVideo" challenger_configs

hydrate_sanevideo_assets

echo ""
echo "Automation root ready: $AUTOMATION_ROOT"
echo "  cloned:  $CLONED"
echo "  synced:  $UPDATED"
echo "  skipped: $SKIPPED"
echo "  failed:  $FAILURES"
echo "  warned:  $WARNINGS"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
