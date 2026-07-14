#!/bin/bash
# Git Worktree Manager for SaneApps
# Creates and manages parallel worktrees for running multiple Claude sessions
#
# Usage:
#   worktree_setup.sh create <repo-path> <count>  - Create N worktrees
#   worktree_setup.sh list                         - List all active worktrees
#   worktree_setup.sh clean                        - Remove all worktrees
#   worktree_setup.sh status                       - Show status of all worktrees

set -euo pipefail

WORKTREE_BASE="$HOME/.claude-worktrees"

create_worktrees() {
    local repo_path="${1:-}"
    local count="${2:-3}"
    local repo_name
    repo_name=$(basename "$repo_path")

    if [ -z "$repo_path" ] || [ ! -d "$repo_path/.git" ]; then
        echo "Error: $repo_path is not a git repository"
        return 1
    fi

    mkdir -p "$WORKTREE_BASE"

    local branch
    branch=$(git -C "$repo_path" branch --show-current)

    for i in $(seq 1 "$count"); do
        local wt_path="$WORKTREE_BASE/${repo_name}-${i}"
        local wt_branch="wt/${repo_name}-${i}"

        if [ -d "$wt_path" ]; then
            echo "  Worktree $i already exists: $wt_path"
            continue
        fi

        git -C "$repo_path" worktree add "$wt_path" -b "$wt_branch" "$branch" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "  Created worktree $i: $wt_path (branch: $wt_branch)"
        else
            # Branch might exist, try without -b
            git -C "$repo_path" worktree add "$wt_path" "$wt_branch" 2>/dev/null ||
            git -C "$repo_path" worktree add "$wt_path" -b "$wt_branch" HEAD 2>/dev/null
            echo "  Created worktree $i: $wt_path"
        fi

        # Copy only declarative client config. Runtime state and circuit-breaker
        # files are session-owned and must never leak between worktrees.
        mkdir -p "$wt_path/.claude"
        for f in settings.json; do
            [ -f "$repo_path/.claude/$f" ] && cp "$repo_path/.claude/$f" "$wt_path/.claude/$f" 2>/dev/null
        done
        if [ -f "$repo_path/.mcp.json" ]; then
            cp "$repo_path/.mcp.json" "$wt_path/.mcp.json" 2>/dev/null
        fi
    done

    echo ""
    echo "Worktrees ready. Use aliases za/zb/zc to hop between them."
    echo "Run 'claude' in each worktree for parallel sessions."
}

list_worktrees() {
    if [ ! -d "$WORKTREE_BASE" ]; then
        echo "No worktrees found."
        return
    fi

    echo "Active worktrees in $WORKTREE_BASE:"
    echo ""
    for wt in "$WORKTREE_BASE"/*/; do
        if [ -d "$wt" ]; then
            local name
            name=$(basename "$wt")
            local branch
            branch=$(git -C "$wt" branch --show-current 2>/dev/null || echo "detached")
            local status
            status=$(git -C "$wt" status --short 2>/dev/null | wc -l | tr -d ' ')
            echo "  $name  branch=$branch  changes=$status"
        fi
    done
}

clean_worktrees() {
    if [ ! -d "$WORKTREE_BASE" ]; then
        echo "No worktrees to clean."
        return
    fi

    echo "Removing clean worktrees..."
    for wt in "$WORKTREE_BASE"/*/; do
        if [ -d "$wt" ]; then
            local name
            name=$(basename "$wt")
            # Find the parent repo and prune
            local parent
            parent=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)
            if [ -n "$parent" ] && [ -d "$parent" ]; then
                if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
                    echo "  Skipped dirty worktree: $name"
                    continue
                fi
                if ! git -C "$(dirname "$parent")" worktree remove "$wt" 2>/dev/null; then
                    echo "  Skipped worktree Git could not remove safely: $name"
                    continue
                fi
            else
                echo "  Skipped unowned directory (no Git worktree metadata): $name"
                continue
            fi
            echo "  Removed: $name"
        fi
    done

    echo "Done. All worktrees cleaned."
}

status_worktrees() {
    if [ ! -d "$WORKTREE_BASE" ]; then
        echo "No worktrees found."
        return
    fi

    echo "Worktree Status:"
    echo "================"
    for wt in "$WORKTREE_BASE"/*/; do
        if [ -d "$wt" ]; then
            local name
            name=$(basename "$wt")
            echo ""
            echo "[$name]"
            git -C "$wt" status --short 2>/dev/null
            local claude_running
            claude_running=$(pgrep -f "claude.*$(basename "$wt")" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$claude_running" -gt 0 ]; then
                echo "  Claude: ACTIVE ($claude_running processes)"
            else
                echo "  Claude: idle"
            fi
        fi
    done
}

case "${1:-list}" in
    create) create_worktrees "$2" "$3" ;;
    list)   list_worktrees ;;
    clean)  clean_worktrees ;;
    status) status_worktrees ;;
    *)      echo "Usage: $0 {create|list|clean|status}" ;;
esac
