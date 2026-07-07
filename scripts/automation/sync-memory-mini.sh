#!/bin/bash
# Targeted Air->Mini sync of the two agent memory stores BOTH agents rely on but that were previously Air-only:
#   1) the Claude file-based project memory  (~/.claude/projects/<proj>/memory)
#   2) the Serena store                       (~/SaneApps/.serena/memories)
# Standalone (no Codex-automation prereqs, unlike sync-codex-mini.sh, which aborts if those are absent). Air is
# canonical; backs up the Mini side FIRST and uses NO --delete so a Mini-side write is never lost. Project-dir
# names are path-derived, so Air's $HOME is mapped to the Mini's $REMOTE_HOME. (memory-sync SOP 2026-07-07.)
# Usage: sync-memory-mini.sh [mini-host]   (default host: mini)
set -uo pipefail

MINI_HOST="${1:-mini}"
REMOTE_HOME="$(ssh "$MINI_HOST" 'printf %s "$HOME"' 2>/dev/null || true)"
[[ -n "$REMOTE_HOME" ]] || { echo "ERROR: could not resolve $MINI_HOST home over ssh"; exit 1; }

LOCAL_PROJ_DIR="$(printf '%s' "$HOME/SaneApps" | sed 's#/#-#g')"
REMOTE_PROJ_DIR="$(printf '%s' "$REMOTE_HOME/SaneApps" | sed 's#/#-#g')"
LOCAL_FILE_MEM="$HOME/.claude/projects/$LOCAL_PROJ_DIR/memory"
LOCAL_SERENA_MEM="$HOME/SaneApps/.serena/memories"
REMOTE_FILE_MEM="$REMOTE_HOME/.claude/projects/$REMOTE_PROJ_DIR/memory"
REMOTE_SERENA_MEM="$REMOTE_HOME/SaneApps/.serena/memories"
TS="$(date +%Y%m%d-%H%M%S)"

echo "Backing up Mini memory + Serena (never lose a Mini-side write) then syncing Air->Mini (no --delete)..."
ssh "$MINI_HOST" "mkdir -p \"$REMOTE_HOME/.claude/backups\" \"$REMOTE_FILE_MEM\" \"$REMOTE_SERENA_MEM\"; \
  cp -a \"$REMOTE_FILE_MEM\" \"$REMOTE_HOME/.claude/backups/memory-$TS\" 2>/dev/null; \
  cp -a \"$REMOTE_SERENA_MEM\" \"$REMOTE_HOME/.claude/backups/serena-$TS\" 2>/dev/null; true"

if [[ -d "$LOCAL_FILE_MEM" ]]; then
  rsync -a "$LOCAL_FILE_MEM/" "$MINI_HOST:$REMOTE_FILE_MEM/" && echo "  synced file-based memory -> $MINI_HOST:$REMOTE_FILE_MEM"
fi
if [[ -d "$LOCAL_SERENA_MEM" ]]; then
  rsync -a "$LOCAL_SERENA_MEM/" "$MINI_HOST:$REMOTE_SERENA_MEM/" && echo "  synced Serena memories -> $MINI_HOST:$REMOTE_SERENA_MEM"
fi
echo "Done. Mini backup at: $REMOTE_HOME/.claude/backups/{memory,serena}-$TS"
