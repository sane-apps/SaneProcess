#!/usr/bin/env bash
# frozen_string_literal: true
# Legacy helper: syncs global ~/.claude/ config (skills, commands, templates,
# CLAUDE.md) to Mac mini for Claude-specific setups only.
# Active Codex parity should use scripts/automation/sync-codex-mini.sh instead.
#
# Usage: bash scripts/mini/sync-claude-config.sh [--dry-run]

set -euo pipefail

MINI="mini"
DRY_RUN=""

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="--dry-run"
  echo "DRY RUN — no files will be transferred"
fi

# Verify mini is reachable
if ! ssh -o ConnectTimeout=5 "$MINI" true 2>/dev/null; then
  echo "ERROR: Cannot reach mini via SSH. Is it on?" >&2
  exit 1
fi

echo "=== Syncing global Claude config to mini ==="

# 1. Global CLAUDE.md
echo "→ CLAUDE.md"
rsync -av $DRY_RUN ~/.claude/CLAUDE.md "$MINI":~/.claude/CLAUDE.md

# 2. SKILLS_REGISTRY.md
echo "→ SKILLS_REGISTRY.md"
rsync -av $DRY_RUN ~/.claude/SKILLS_REGISTRY.md "$MINI":~/.claude/SKILLS_REGISTRY.md

# 3. Skills directory (all skills, recursive)
echo "→ skills/"
ssh "$MINI" 'mkdir -p ~/.claude/skills'
rsync -av --delete $DRY_RUN ~/.claude/skills/ "$MINI":~/.claude/skills/

# 4. Commands directory
echo "→ commands/"
ssh "$MINI" 'mkdir -p ~/.claude/commands'
rsync -av --delete $DRY_RUN ~/.claude/commands/ "$MINI":~/.claude/commands/

# 5. Templates directory
echo "→ templates/"
ssh "$MINI" 'mkdir -p ~/.claude/templates'
rsync -av --delete $DRY_RUN ~/.claude/templates/ "$MINI":~/.claude/templates/

# 6. Settings files (but NOT settings.local.json — mini has its own permissions)
echo "→ settings.json"
rsync -av $DRY_RUN ~/.claude/settings.json "$MINI":~/.claude/settings.json

echo ""
echo "=== Done ==="
echo "Skipped: settings.local.json (mini has its own permissions)"
echo "Skipped: plugins/ (mini installs its own)"
echo "Skipped: hooks/ (synced via SaneProcess git repo)"
echo ""
echo "Mini now has the same skills, commands, and global config as MacBook."
