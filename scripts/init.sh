#!/bin/bash
#
# SaneProcess Initialization Script
# One-click setup for Claude Code SOP enforcement
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/stephanjoseph/SaneProcess/main/scripts/init.sh | bash
#
# Version 2.4 - January 2026
# Copyright (c) 2026 Stephan Joseph. All Rights Reserved.
# License required for use: stephanjoseph2007@gmail.com
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

REPO_RAW="https://raw.githubusercontent.com/stephanjoseph/SaneProcess/main"

# ═══════════════════════════════════════════════════════════════════════════════
# LICENSE VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

LICENSE_DIR="$HOME/.saneprocess"
LICENSE_FILE="$LICENSE_DIR/license.key"

validate_license() {
    local key=""

    if [ -n "$SANEPROCESS_LICENSE" ]; then
        key="$SANEPROCESS_LICENSE"
    elif [ -f "$LICENSE_FILE" ]; then
        key=$(cat "$LICENSE_FILE")
    fi

    if [ -z "$key" ]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    LICENSE REQUIRED                           ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "SaneProcess requires a valid license."
        echo ""
        echo -e "${YELLOW}To purchase:${NC}"
        echo "   Email: stephanjoseph2007@gmail.com"
        echo "   Or open an issue: https://github.com/stephanjoseph/SaneProcess/issues"
        echo ""
        echo -e "${YELLOW}To activate:${NC}"
        echo "   mkdir -p ~/.saneprocess"
        echo "   echo 'SP-XXXX-XXXX-XXXX-XXXX' > ~/.saneprocess/license.key"
        echo ""
        exit 1
    fi

    # Validate format
    if ! echo "$key" | grep -qE '^SP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$'; then
        echo -e "${RED}❌ Invalid license key format${NC}"
        exit 1
    fi

    # Validate checksum
    local data=$(echo "$key" | cut -d'-' -f1-4)
    local checksum=$(echo "$key" | cut -d'-' -f5)
    local expected=$(echo -n "${data}SaneProcess2026" | shasum -a 256 | cut -c1-4 | tr 'a-z' 'A-Z')

    if [ "$checksum" != "$expected" ]; then
        echo -e "${RED}❌ Invalid license key${NC}"
        exit 1
    fi

    echo -e "${GREEN}✅ License validated${NC}"
}

validate_license

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}              ${GREEN}SaneProcess v2.4 Installation${NC}                    ${BLUE}║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# DETECT PROJECT TYPE
# ═══════════════════════════════════════════════════════════════════════════════

detect_project_type() {
    if [ -f "Package.swift" ]; then echo "swift-package"
    elif [ -f "project.yml" ]; then echo "xcodegen"
    elif ls *.xcodeproj 1>/dev/null 2>&1; then echo "xcode"
    elif [ -f "Gemfile" ]; then echo "ruby"
    elif [ -f "package.json" ]; then echo "node"
    elif [ -f "Cargo.toml" ]; then echo "rust"
    elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then echo "python"
    else echo "generic"
    fi
}

PROJECT_TYPE=$(detect_project_type)
PROJECT_NAME=$(basename "$(pwd)")

echo -e "📁 Project: ${GREEN}${PROJECT_NAME}${NC}"
echo -e "🔍 Type: ${GREEN}${PROJECT_TYPE}${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CHECK DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Checking dependencies..."

if ! command -v claude &>/dev/null; then
    echo -e "${RED}❌ Claude Code not found${NC}"
    echo "   Install: npm install -g @anthropic-ai/claude-code"
    exit 1
fi
echo -e "   ✅ claude"

if ! command -v curl &>/dev/null; then
    echo -e "${RED}❌ curl not found${NC}"
    exit 1
fi
echo -e "   ✅ curl"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE DIRECTORIES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Creating directories..."

mkdir -p .claude/rules
mkdir -p Scripts/hooks

echo "   ✅ .claude/"
echo "   ✅ .claude/rules/"
echo "   ✅ Scripts/hooks/"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD HOOKS FROM GITHUB
# ═══════════════════════════════════════════════════════════════════════════════

echo "Downloading hooks from GitHub..."

HOOKS=(
    "rule_tracker.rb"
    "circuit_breaker.rb"
    "edit_validator.rb"
    "failure_tracker.rb"
    "test_quality_checker.rb"
    "path_rules.rb"
    "session_start.rb"
    "audit_logger.rb"
    "sop_mapper.rb"
    "two_fix_reminder.rb"
    "verify_reminder.rb"
    "version_mismatch.rb"
    "deeper_look_trigger.rb"
    "skill_validator.rb"
    "saneloop_enforcer.rb"
    "session_summary_validator.rb"
    "prompt_analyzer.rb"
    "pattern_learner.rb"
    "process_enforcer.rb"
    "research_tracker.rb"
    "state_signer.rb"
)

for hook in "${HOOKS[@]}"; do
    curl -sL "${REPO_RAW}/scripts/hooks/${hook}" -o "Scripts/hooks/${hook}"
    chmod +x "Scripts/hooks/${hook}"
    echo "   ✅ Scripts/hooks/${hook}"
done

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD SANEMASTER CLI
# ═══════════════════════════════════════════════════════════════════════════════

echo "Downloading SaneMaster CLI..."

mkdir -p Scripts/sanemaster

# Download main CLI
curl -sL "${REPO_RAW}/scripts/SaneMaster.rb" -o "Scripts/SaneMaster.rb"
chmod +x "Scripts/SaneMaster.rb"
echo "   ✅ Scripts/SaneMaster.rb"

# Download modules
SANEMASTER_MODULES=(
    "base.rb"
    "bootstrap.rb"
    "circuit_breaker_state.rb"
    "compliance_report.rb"
    "dependencies.rb"
    "diagnostics.rb"
    "export.rb"
    "generation.rb"
    "generation_assets.rb"
    "generation_mocks.rb"
    "generation_templates.rb"
    "md_export.rb"
    "memory.rb"
    "meta.rb"
    "quality.rb"
    "session.rb"
    "sop_loop.rb"
    "test_mode.rb"
    "verify.rb"
)

for module in "${SANEMASTER_MODULES[@]}"; do
    curl -sL "${REPO_RAW}/scripts/sanemaster/${module}" -o "Scripts/sanemaster/${module}"
done
echo "   ✅ Scripts/sanemaster/ (${#SANEMASTER_MODULES[@]} modules)"

# Replace placeholders with project name
echo "   🔧 Configuring for ${PROJECT_NAME}..."
BUNDLE_ID="com.example.${PROJECT_NAME,,}"  # lowercase project name

sed -i '' "s/__PROJECT_NAME__/${PROJECT_NAME}/g" Scripts/SaneMaster.rb
sed -i '' "s/__BUNDLE_ID__/${BUNDLE_ID}/g" Scripts/SaneMaster.rb

for module in Scripts/sanemaster/*.rb; do
    sed -i '' "s/__PROJECT_NAME__/${PROJECT_NAME}/g" "$module"
    sed -i '' "s/__BUNDLE_ID__/${BUNDLE_ID}/g" "$module"
done
echo "   ✅ Configured for ${PROJECT_NAME}"

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD PATTERN RULES
# ═══════════════════════════════════════════════════════════════════════════════

echo "Downloading pattern rules..."

RULES=(
    "views.md"
    "tests.md"
    "services.md"
    "models.md"
    "scripts.md"
    "hooks.md"
)

for rule in "${RULES[@]}"; do
    curl -sL "${REPO_RAW}/.claude/rules/${rule}" -o ".claude/rules/${rule}"
    echo "   ✅ .claude/rules/${rule}"
done

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE .claude/settings.json
# ═══════════════════════════════════════════════════════════════════════════════

echo "Creating Claude Code configuration..."

cat > .claude/settings.json << 'EOF'
{
  "permissions": {
    "allow": [
      "mcp__memory__*",
      "mcp__apple-docs__*",
      "mcp__context7__*"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "./Scripts/hooks/session_start.rb"
      }
    ],
    "PreToolUse": [
      {
        "type": "command",
        "command": "./Scripts/hooks/circuit_breaker.rb",
        "matchTools": ["Edit", "Bash", "Write"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/edit_validator.rb",
        "matchTools": ["Edit", "Write"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/path_rules.rb",
        "matchTools": ["Edit", "Write"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/sop_mapper.rb",
        "matchTools": ["Edit", "Write"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/two_fix_reminder.rb",
        "matchTools": ["Edit"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/version_mismatch.rb",
        "matchTools": ["Bash"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/skill_validator.rb",
        "matchTools": ["Skill"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/saneloop_enforcer.rb",
        "matchTools": ["Edit", "Write", "Bash"]
      }
    ],
    "PostToolUse": [
      {
        "type": "command",
        "command": "./Scripts/hooks/failure_tracker.rb",
        "matchTools": ["Bash"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/test_quality_checker.rb",
        "matchTools": ["Edit", "Write"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/verify_reminder.rb",
        "matchTools": ["Edit"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/audit_logger.rb"
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/deeper_look_trigger.rb",
        "matchTools": ["Grep", "Glob", "Read"]
      },
      {
        "type": "command",
        "command": "./Scripts/hooks/session_summary_validator.rb",
        "matchTools": ["Edit", "Write"]
      }
    ]
  }
}
EOF

echo "   ✅ .claude/settings.json (hooks configured)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE .claude/.gitignore
# ═══════════════════════════════════════════════════════════════════════════════

cat > .claude/.gitignore << 'EOF'
# Session state (local only)
circuit_breaker.json
failure_state.json
audit.jsonl
audit_log.jsonl
memory.json
sop_state.json
edit_state.json
edit_count.json
build_state.json
tool_count.json
compliance_streak.json
rule_tracking.jsonl
research_progress.json
research_findings.jsonl
prompt_requirements.json
process_satisfaction.json
enforcement_log.jsonl

# Keep rules and settings
!rules/
!settings.json
EOF

echo "   ✅ .claude/.gitignore"

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE .mcp.json
# ═══════════════════════════════════════════════════════════════════════════════

echo "Creating MCP configuration..."

cat > .mcp.json << 'EOF'
{
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory", ".claude/memory.json"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    }
  }
}
EOF

# Add apple-docs for Swift projects
case "$PROJECT_TYPE" in
    swift-package|xcodegen|xcode)
        cat > .mcp.json << 'EOF'
{
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory", ".claude/memory.json"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    },
    "apple-docs": {
      "command": "npx",
      "args": ["-y", "@mweinbach/apple-docs-mcp@latest"]
    }
  }
}
EOF
        ;;
esac

echo "   ✅ .mcp.json"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# CREATE DEVELOPMENT.md
# ═══════════════════════════════════════════════════════════════════════════════

if [ ! -f "DEVELOPMENT.md" ]; then
    echo "Creating DEVELOPMENT.md..."

    cat > DEVELOPMENT.md << 'EOF'
# Development Guide

This project uses **SaneProcess** for Claude Code SOP enforcement.

## The 16 Golden Rules

```
#0  NAME THE RULE BEFORE YOU CODE
#1  STAY IN YOUR LANE (files in project)
#2  VERIFY BEFORE YOU TRY (check docs first)
#3  TWO STRIKES? INVESTIGATE
#4  GREEN MEANS GO (tests must pass)
#5  THEIR HOUSE, THEIR RULES (use project tools)
#6  BUILD, KILL, LAUNCH, LOG
#7  NO TEST? NO REST
#8  BUG FOUND? WRITE IT DOWN
#9  NEW FILE? GEN THAT PILE
#10 FIVE HUNDRED'S FINE, EIGHT'S THE LINE
#11 TOOL BROKE? FIX THE YOKE
#12 TALK WHILE I WALK (stay responsive)
#13 CONTEXT OR CHAOS (maintain CLAUDE.md)
#14 PROMPT LIKE A PRO (specific prompts)
#15 REVIEW BEFORE YOU SHIP (self-review)
```

## Installed Hooks

| Hook | Type | Purpose |
|------|------|---------|
| `session_start.rb` | SessionStart | Bootstraps session, resets breaker |
| `circuit_breaker.rb` | PreToolUse | Blocks after 3 failures |
| `edit_validator.rb` | PreToolUse | Blocks dangerous paths, enforces file size |
| `path_rules.rb` | PreToolUse | Shows context-specific rules |
| `failure_tracker.rb` | PostToolUse | Tracks consecutive failures |
| `test_quality_checker.rb` | PostToolUse | Warns on tautology tests |
| `audit_logger.rb` | PostToolUse | Logs all decisions |

## Self-Rating

After every task, Claude should rate 1-10:

| Score | Meaning |
|-------|---------|
| 9-10 | All rules followed |
| 7-8 | Minor miss |
| 5-6 | Notable gaps |
| 1-4 | Multiple violations |

## AI Usage Self-Rating

| Criteria | ✅ or ❌ |
|----------|--------|
| Used progressive prompting (plan first) | |
| Verified APIs before using | |
| Self-reviewed code before done | |
| Updated context file with learnings | |
| Used specific prompts with constraints | |
| Stopped at 2 failures and researched | |

## More Info

Full documentation: https://github.com/stephanjoseph/SaneProcess
EOF

    echo "   ✅ DEVELOPMENT.md"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFY INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

echo "Verifying installation..."

ERRORS=0

# Check all hooks exist and are executable
for hook in "${HOOKS[@]}"; do
    if [ ! -x "Scripts/hooks/${hook}" ]; then
        echo -e "   ${RED}❌ Scripts/hooks/${hook} missing or not executable${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check settings.json exists
if [ ! -f ".claude/settings.json" ]; then
    echo -e "   ${RED}❌ .claude/settings.json missing${NC}"
    ERRORS=$((ERRORS + 1))
fi

# Check .mcp.json exists
if [ ! -f ".mcp.json" ]; then
    echo -e "   ${RED}❌ .mcp.json missing${NC}"
    ERRORS=$((ERRORS + 1))
fi

# Verify hooks have valid Ruby syntax
for hook in "${HOOKS[@]}"; do
    if ! ruby -c "Scripts/hooks/${hook}" &>/dev/null; then
        echo -e "   ${RED}❌ Scripts/hooks/${hook} has syntax errors${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo -e "${RED}❌ Installation failed with $ERRORS errors${NC}"
    exit 1
fi

echo -e "   ${GREEN}✅ All hooks installed and valid${NC}"
echo -e "   ${GREEN}✅ Configuration files created${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUCCESS
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Installation Complete!                     ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Installed:"
echo "   • 16 SOP enforcement hooks"
echo "   • 6 pattern-based rules"
echo "   • SaneMaster CLI (./Scripts/SaneMaster.rb)"
echo "   • Claude Code settings with hook registration"
echo "   • MCP server configuration"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "   1. Run: ${GREEN}claude${NC}"
echo "   2. Hooks activate automatically"
echo "   3. See DEVELOPMENT.md for the 16 Golden Rules"
echo ""
echo -e "${BLUE}SaneMaster commands:${NC}"
echo "   ./Scripts/SaneMaster.rb verify      # Build, test, lint"
echo "   ./Scripts/SaneMaster.rb test-mode   # Build, kill, launch, logs"
echo "   ./Scripts/SaneMaster.rb memory      # View memory graph health"
echo ""
echo -e "${YELLOW}Note:${NC} Add these to .gitignore:"
echo "   .claude/circuit_breaker.json"
echo "   .claude/failure_state.json"
echo "   .claude/audit.jsonl"
echo "   .claude/memory.json"
echo ""
echo "Documentation: https://github.com/stephanjoseph/SaneProcess"
echo ""
