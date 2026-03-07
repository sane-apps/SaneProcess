#!/bin/bash
# mini-prepare-automation-root.sh - Create/update clean automation clones on mini
# Usage:
#   AUTOMATION_ROOT=~/SaneApps-automation SANE_SOURCE_ROOT=~/SaneApps \
#     bash ~/SaneApps/infra/scripts/mini-prepare-automation-root.sh

set -euo pipefail

SOURCE_ROOT="${SANE_SOURCE_ROOT:-$HOME/SaneApps}"
AUTOMATION_ROOT="${AUTOMATION_ROOT:-$HOME/SaneApps-automation}"
AUTOMATION_MARKER="$AUTOMATION_ROOT/.sane_automation_root"
FAILURES=0
UPDATED=0
CLONED=0
SKIPPED=0
WARNINGS=0

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
    echo "FAIL  $rel_path (missing origin)"
    FAILURES=$((FAILURES + 1))
    return 1
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
    echo "FAIL  $rel_path (automation repo dirty: $dirty_count)"
    FAILURES=$((FAILURES + 1))
    return 1
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

hydrate_training_dataset() {
  local app_name="$1"
  shift
  local source_dir="$SOURCE_ROOT/apps/$app_name/training_data"
  local target_dir="$AUTOMATION_ROOT/apps/$app_name/training_data"
  local copied=0
  local unchanged=0
  local missing=0
  local rel_file source_file target_file

  [ -d "$AUTOMATION_ROOT/apps/$app_name" ] || return 0

  if [ ! -d "$source_dir" ]; then
    echo "WARN  apps/$app_name training_data missing in source root"
    WARNINGS=$((WARNINGS + 1))
    return 0
  fi

  for rel_file in "$@"; do
    source_file="$source_dir/$rel_file"
    target_file="$target_dir/$rel_file"

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
printf 'managed_by=mini-prepare-automation-root\nsource_root=%s\nprepared_at=%s\n' \
  "$SOURCE_ROOT" "$(date '+%Y-%m-%d %H:%M:%S')" > "$AUTOMATION_MARKER"

for base in apps infra; do
  for source_repo in "$SOURCE_ROOT/$base"/*; do
    [ -d "$source_repo/.git" ] || continue
    rel_path="${source_repo#$SOURCE_ROOT/}"
    prepare_repo "$source_repo" "$rel_path"
  done
done

hydrate_training_dataset "SaneSync" train.jsonl valid.jsonl test.jsonl
hydrate_training_dataset "SaneClip" train.jsonl valid.jsonl test.jsonl
hydrate_training_dataset "SaneAI" train.jsonl valid.jsonl

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
