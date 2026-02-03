#!/bin/bash
#
# SaneProcess Installation Script
# Sets up Claude Code hook enforcement in your project
#
# Usage:
#   git clone https://github.com/sane-apps/SaneProcess.git /tmp/saneprocess
#   /tmp/saneprocess/scripts/init.sh
#
# Or from an existing clone:
#   /path/to/SaneProcess/scripts/init.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Find the SaneProcess source directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANEPROCESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Verify we're running from a valid SaneProcess clone
if [ ! -f "$SANEPROCESS_DIR/scripts/hooks/saneprompt.rb" ]; then
    echo -e "${RED}Error: Cannot find SaneProcess hooks at $SANEPROCESS_DIR${NC}"
    echo "Clone the repo first: git clone https://github.com/sane-apps/SaneProcess.git"
    exit 1
fi

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}                ${GREEN}SaneProcess Installation${NC}                       ${BLUE}║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Checking dependencies..."

if ! command -v ruby &>/dev/null; then
    echo -e "${RED}Error: Ruby not found${NC}"
    echo "   macOS ships with Ruby. If removed, install via: brew install ruby"
    exit 1
fi
echo -e "   ${GREEN}✓${NC} ruby $(ruby -v | head -c 20)"

if ! command -v claude &>/dev/null; then
    echo -e "${YELLOW}Warning: Claude Code CLI not found${NC}"
    echo "   Install: npm install -g @anthropic-ai/claude-code"
    echo "   (Hooks will be installed but won't activate until claude is available)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE DIRECTORIES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Creating directories..."

mkdir -p .claude/rules
mkdir -p scripts/hooks/core

echo -e "   ${GREEN}✓${NC} .claude/rules/"
echo -e "   ${GREEN}✓${NC} scripts/hooks/core/"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# COPY HOOKS
# ═══════════════════════════════════════════════════════════════════════════════

echo "Installing hooks..."

SRC="$SANEPROCESS_DIR/scripts/hooks"

# Main hooks (5)
MAIN_HOOKS=(
    "session_start.rb"
    "saneprompt.rb"
    "sanetools.rb"
    "sanetrack.rb"
    "sanestop.rb"
)

# Support modules (required by main hooks)
SUPPORT_MODULES=(
    "saneprompt_intelligence.rb"
    "saneprompt_commands.rb"
    "sanetools_checks.rb"
    "sanetools_startup.rb"
    "sanetools_gaming.rb"
    "sanetools_deploy.rb"
    "sanetrack_research.rb"
    "sanetrack_gate.rb"
    "sanetrack_reminders.rb"
    "session_briefing.rb"
    "state_signer.rb"
    "rule_tracker.rb"
)

# Core modules (shared infrastructure)
CORE_MODULES=(
    "core/config.rb"
    "core/state_manager.rb"
    "core/context_compact.rb"
)

ERRORS=0

for hook in "${MAIN_HOOKS[@]}"; do
    if [ -f "$SRC/$hook" ]; then
        cp "$SRC/$hook" "scripts/hooks/$hook"
        chmod +x "scripts/hooks/$hook"
        echo -e "   ${GREEN}✓${NC} $hook"
    else
        echo -e "   ${RED}✗${NC} $hook (not found in source)"
        ERRORS=$((ERRORS + 1))
    fi
done

for module in "${SUPPORT_MODULES[@]}"; do
    if [ -f "$SRC/$module" ]; then
        cp "$SRC/$module" "scripts/hooks/$module"
    else
        echo -e "   ${YELLOW}!${NC} $module (optional, skipped)"
    fi
done

for core in "${CORE_MODULES[@]}"; do
    if [ -f "$SRC/$core" ]; then
        cp "$SRC/$core" "scripts/hooks/$core"
    else
        echo -e "   ${RED}✗${NC} $core (not found in source)"
        ERRORS=$((ERRORS + 1))
    fi
done

echo -e "   ${GREEN}✓${NC} ${#SUPPORT_MODULES[@]} support modules"
echo -e "   ${GREEN}✓${NC} ${#CORE_MODULES[@]} core modules"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# COPY PATTERN RULES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Installing pattern rules..."

RULES_SRC="$SANEPROCESS_DIR/.claude/rules"

if [ -d "$RULES_SRC" ]; then
    for rule in "$RULES_SRC"/*.md; do
        [ -f "$rule" ] || continue
        cp "$rule" ".claude/rules/$(basename "$rule")"
        echo -e "   ${GREEN}✓${NC} $(basename "$rule")"
    done
else
    echo -e "   ${YELLOW}!${NC} No pattern rules found (optional)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE .claude/settings.json (project-level hooks)
# ═══════════════════════════════════════════════════════════════════════════════

echo "Configuring hooks..."

# Only create if not already present (don't overwrite user config)
if [ -f ".claude/settings.json" ]; then
    echo -e "   ${YELLOW}!${NC} .claude/settings.json already exists — skipping"
    echo "   Add hooks manually if needed (see README.md)"
else
    cat > .claude/settings.json << 'SETTINGS_EOF'
{
  "permissions": {
    "allow": []
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/session_start.rb",
            "timeout": 15000
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/saneprompt.rb",
            "timeout": 5000
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sanetools.rb",
            "timeout": 5000
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sanetrack.rb",
            "timeout": 5000
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sanestop.rb",
            "timeout": 10000
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
    echo -e "   ${GREEN}✓${NC} .claude/settings.json (5 hooks registered)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE .claude/.gitignore
# ═══════════════════════════════════════════════════════════════════════════════

cat > .claude/.gitignore << 'GITIGNORE_EOF'
# Hook runtime state (local only, regenerated each session)
state.json
state.json.lock
bypass_active.json
memory_staging.json
memory.json
context_warned_size.txt
session_start_debug.log
*.jsonl
*.log
*.log.old

# Keep rules and settings in version control
!rules/
!settings.json
GITIGNORE_EOF

echo -e "   ${GREEN}✓${NC} .claude/.gitignore"

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFY INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Verifying installation..."

# Check all main hooks exist
for hook in "${MAIN_HOOKS[@]}"; do
    if [ ! -f "scripts/hooks/${hook}" ]; then
        echo -e "   ${RED}✗${NC} scripts/hooks/${hook} missing"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check core modules exist
for core in "${CORE_MODULES[@]}"; do
    if [ ! -f "scripts/hooks/${core}" ]; then
        echo -e "   ${RED}✗${NC} scripts/hooks/${core} missing"
        ERRORS=$((ERRORS + 1))
    fi
done

# Verify Ruby syntax on main hooks
for hook in "${MAIN_HOOKS[@]}"; do
    if [ -f "scripts/hooks/${hook}" ] && ! ruby -c "scripts/hooks/${hook}" &>/dev/null; then
        echo -e "   ${RED}✗${NC} scripts/hooks/${hook} has syntax errors"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${RED}Installation completed with $ERRORS errors${NC}"
    echo "Some hooks may not function correctly. Check the errors above."
    exit 1
fi

echo -e "   ${GREEN}✓${NC} All hooks installed and valid"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUCCESS
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Installation Complete                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Installed:"
echo "   5 main hooks + ${#SUPPORT_MODULES[@]} support modules + ${#CORE_MODULES[@]} core modules"
echo "   $(ls .claude/rules/*.md 2>/dev/null | wc -l | tr -d ' ') pattern rules"
echo "   Hook registration in .claude/settings.json"
echo ""
echo -e "${BLUE}What happens next:${NC}"
echo "   1. Run: claude"
echo "   2. Hooks activate automatically on session start"
echo "   3. Orphaned processes cleaned up"
echo "   4. Circuit breaker armed (trips after 3 consecutive failures)"
echo "   5. Research gate active (4 categories before edits)"
echo ""
echo -e "${BLUE}Verify:${NC}"
echo "   ruby scripts/hooks/saneprompt.rb --self-test"
echo "   ruby scripts/hooks/sanetools.rb --self-test"
echo ""
echo -e "${BLUE}Troubleshooting:${NC}"
echo "   Circuit breaker stuck: say 'reset breaker' in Claude"
echo "   Research gate stuck: complete all 4 research categories"
echo "   Hooks not firing: check .claude/settings.json has hook entries"
echo ""
echo "Docs: https://github.com/sane-apps/SaneProcess"
echo ""
