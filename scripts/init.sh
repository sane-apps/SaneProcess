#!/bin/bash
#
# SaneProcess Installation Script
# Sets up SaneProcess for Claude Code, Codex, Grok, or generic coding agents.
# Usage: /path/to/SaneProcess/scripts/init.sh [--client all|claude|codex|grok|generic] [--force]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANEPROCESS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REQUIRED_RUBY_VERSION="${SANEPROCESS_REQUIRED_RUBY_VERSION:-4.0.0}"
HOMEBREW_RUBY="${SANEPROCESS_HOMEBREW_RUBY:-/opt/homebrew/opt/ruby/bin/ruby}"
HOMEBREW_RUBY_BIN_DIR="$(dirname "$HOMEBREW_RUBY")"
HOMEBREW_RUBY_GEM_BIN="${SANEPROCESS_HOMEBREW_RUBY_GEM_BIN:-/opt/homebrew/lib/ruby/gems/4.0.0/bin}"
REQUIRED_RUBY_GEMS="${SANEPROCESS_REQUIRED_RUBY_GEMS:-jwt}"
RUBY_CMD="ruby"
BUNDLE_CMD="bundle"

CLIENT="all"
FORCE=0
INTERACTIVE=0

usage() {
    cat <<EOF
SaneProcess installer
Usage:
  scripts/init.sh [options]
Options:
  --client all       Install AGENTS.md, Claude hooks, and shared .agents skills (default)
  --client claude    Install AGENTS.md plus Claude Code native hooks
  --client codex     Install AGENTS.md plus shared .agents skills for Codex-style clients
  --client grok      Install AGENTS.md plus shared .agents skills for Grok-style clients
  --client generic   Install only the portable AGENTS.md baseline
  --all | --claude | --codex | --grok | --generic
  --interactive      Ask which client adapter to install
  --force            Overwrite files previously installed by SaneProcess
  -h, --help         Show this help
The default remains "all" so existing SaneApps setup flows keep the full
Claude + Codex-compatible surface. Public adopters can choose a narrower
adapter without getting client-specific files they do not use.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client)
            shift
            if [ "$#" -eq 0 ]; then
                echo -e "${RED}Error: --client requires all, claude, codex, grok, or generic${NC}" >&2
                exit 1
            fi
            CLIENT="$1"
            ;;
        --all) CLIENT="all" ;;
        --claude) CLIENT="claude" ;;
        --codex) CLIENT="codex" ;;
        --grok) CLIENT="grok" ;;
        --generic) CLIENT="generic" ;;
        --interactive) INTERACTIVE=1 ;;
        --force) FORCE=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: unknown option $1${NC}" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ ! -f "$SANEPROCESS_DIR/scripts/hooks/saneprompt.rb" ]; then
    echo -e "${RED}Error: Cannot find SaneProcess hooks at $SANEPROCESS_DIR${NC}" >&2
    echo "Clone the repo first: git clone https://github.com/sane-apps/SaneProcess.git" >&2
    exit 1
fi

if [ "$INTERACTIVE" -eq 1 ]; then
    echo "Choose the SaneProcess setup:"
    echo "  1) all     - AGENTS.md, Claude hooks, and .agents skills"
    echo "  2) claude  - AGENTS.md and Claude Code native hooks"
    echo "  3) codex   - AGENTS.md and .agents skills"
    echo "  4) grok    - AGENTS.md and .agents skills"
    echo "  5) generic - AGENTS.md only"
    printf "Selection [1]: "
    read answer
    case "${answer:-1}" in
        1|all) CLIENT="all" ;;
        2|claude) CLIENT="claude" ;;
        3|codex) CLIENT="codex" ;;
        4|grok) CLIENT="grok" ;;
        5|generic) CLIENT="generic" ;;
        *)
            echo -e "${RED}Error: invalid selection${NC}" >&2
            exit 1
            ;;
    esac
fi

case "$CLIENT" in
    all|claude|codex|grok|generic) ;;
    *)
        echo -e "${RED}Error: unsupported client '$CLIENT'${NC}" >&2
        usage >&2
        exit 1
        ;;
esac

INSTALL_CLAUDE=0
INSTALL_AGENTS_SKILLS=0
CLAUDE_SETTINGS_ACTIVE=0

case "$CLIENT" in
    all) INSTALL_CLAUDE=1; INSTALL_AGENTS_SKILLS=1 ;;
    claude) INSTALL_CLAUDE=1 ;;
    codex|grok) INSTALL_AGENTS_SKILLS=1 ;;
    generic) ;;
esac

copy_file() {
    src="$1"
    dst="$2"
    label="$3"
    mode="$4"

    if [ ! -f "$src" ]; then
        echo -e "   ${RED}x${NC} $label (source missing: $src)"
        ERRORS=$((ERRORS + 1))
        return
    fi

    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ] && [ "$FORCE" -ne 1 ]; then
        echo -e "   ${YELLOW}!${NC} $label exists - skipping (use --force to overwrite)"
        return
    fi

    cp "$src" "$dst"
    if [ -n "$mode" ]; then
        chmod "$mode" "$dst"
    fi
    echo -e "   ${GREEN}+${NC} $label"
}

version_at_least() {
    current="$1"
    required="$2"

    old_ifs="$IFS"
    IFS=.
    set -- $current
    current_major="${1:-0}"
    current_minor="${2:-0}"
    current_patch="${3:-0}"
    set -- $required
    required_major="${1:-0}"
    required_minor="${2:-0}"
    required_patch="${3:-0}"
    IFS="$old_ifs"

    [ "$current_major" -gt "$required_major" ] && return 0
    [ "$current_major" -lt "$required_major" ] && return 1
    [ "$current_minor" -gt "$required_minor" ] && return 0
    [ "$current_minor" -lt "$required_minor" ] && return 1
    [ "$current_patch" -ge "$required_patch" ]
}

prompt_dependency_update() {
    label="$1"
    command="$2"

    echo -e "   ${YELLOW}!${NC} $label"
    if [ -t 0 ]; then
        printf "   Run now? [y/N] "
        read answer
        case "$answer" in
            y|Y|yes|YES)
                if eval "$command"; then
                    echo -e "   ${GREEN}+${NC} dependency updated"
                    return 0
                fi
                echo -e "   ${RED}x${NC} dependency update failed"
                ERRORS=$((ERRORS + 1))
                return 1
                ;;
            *)
                echo "   Run later: $command"
                ERRORS=$((ERRORS + 1))
                return 1
                ;;
        esac
    fi

    echo "   Run: $command"
    ERRORS=$((ERRORS + 1))
    return 1
}

check_ruby_dependency() {
    if [ "$PLATFORM" = "macOS" ]; then
        if [ ! -x "$HOMEBREW_RUBY" ]; then
            if command -v brew >/dev/null 2>&1; then
                prompt_dependency_update "Homebrew Ruby ${REQUIRED_RUBY_VERSION}+ is required for SaneProcess automation." "brew install ruby"
            else
                echo -e "${RED}Error: Homebrew not found${NC}" >&2
                echo "   Install Homebrew first: https://brew.sh" >&2
                ERRORS=$((ERRORS + 1))
            fi
            return
        fi

        ruby_version="$("$HOMEBREW_RUBY" -e 'print RUBY_VERSION' 2>/dev/null || true)"
        if ! version_at_least "$ruby_version" "$REQUIRED_RUBY_VERSION"; then
            prompt_dependency_update "Homebrew Ruby $ruby_version is older than required ${REQUIRED_RUBY_VERSION}+." "brew update && brew upgrade ruby"
        fi

        export PATH="$HOMEBREW_RUBY_BIN_DIR:$HOMEBREW_RUBY_GEM_BIN:$PATH"
        RUBY_CMD="$HOMEBREW_RUBY"
        BUNDLE_CMD="$HOMEBREW_RUBY_BIN_DIR/bundle"
        echo -e "   ${GREEN}+${NC} Homebrew Ruby $("$RUBY_CMD" -v | cut -d' ' -f2)"
        return
    fi

    if ! command -v ruby >/dev/null 2>&1; then
        echo -e "${RED}Error: Ruby not found${NC}" >&2
        echo "   Install via: sudo apt install ruby or sudo dnf install ruby" >&2
        exit 1
    fi

    ruby_version="$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)"
    if ! version_at_least "$ruby_version" "$REQUIRED_RUBY_VERSION"; then
        echo -e "   ${YELLOW}!${NC} Ruby $ruby_version is older than preferred ${REQUIRED_RUBY_VERSION}+"
    fi
    echo -e "   ${GREEN}+${NC} ruby $(ruby -v | head -c 20)"
}

check_bundle_dependency() {
    if [ ! -f "Gemfile" ]; then
        return
    fi

    if ! command -v "$BUNDLE_CMD" >/dev/null 2>&1; then
        prompt_dependency_update "Bundler is required to install project gems." "$RUBY_CMD -S gem install bundler"
        return
    fi

    if "$BUNDLE_CMD" check >/dev/null 2>&1; then
        echo -e "   ${GREEN}+${NC} bundle dependencies satisfied"
    else
        prompt_dependency_update "Ruby gems are missing or stale for this project." "$BUNDLE_CMD install"
    fi
}

check_ruby_gem_dependencies() {
    for gem_name in $REQUIRED_RUBY_GEMS; do
        if "$RUBY_CMD" -e "require '$gem_name'" >/dev/null 2>&1; then
            echo -e "   ${GREEN}+${NC} Ruby gem: $gem_name"
        else
            prompt_dependency_update "Ruby gem '$gem_name' is required for SaneProcess automation." "$RUBY_CMD -S gem install $gem_name --no-document"
        fi
    done
}

echo ""
echo -e "${BLUE}SaneProcess Installation${NC}"
echo ""

OS="$(uname -s)"
case "$OS" in
    Darwin) PLATFORM="macOS" ;;
    Linux) PLATFORM="Linux" ;;
    *)
        PLATFORM="$OS"
        echo -e "${YELLOW}Warning: untested platform ($OS). Proceeding anyway.${NC}"
        ;;
esac

echo -e "   Platform: ${GREEN}${PLATFORM}${NC}"
echo -e "   Client adapter: ${GREEN}${CLIENT}${NC}"
if [ "$FORCE" -eq 1 ]; then
    echo -e "   Overwrite existing files: ${YELLOW}yes${NC}"
fi
echo ""

echo "Checking dependencies..."
check_ruby_dependency
check_ruby_gem_dependencies
check_bundle_dependency

HAS_CLAUDE=0
HAS_CODEX=0
if command -v claude >/dev/null 2>&1; then
    HAS_CLAUDE=1
elif [ "$INSTALL_CLAUDE" -eq 1 ]; then
    echo -e "   ${YELLOW}!${NC} Claude Code CLI not found; hook files will wait until Claude is installed"
fi

if command -v codex >/dev/null 2>&1; then
    HAS_CODEX=1
elif [ "$CLIENT" = "all" ] || [ "$CLIENT" = "codex" ]; then
    echo -e "   ${YELLOW}!${NC} Codex CLI not found; AGENTS.md and .agents skills are still usable"
fi
echo ""

ERRORS=0

# Entry-point hooks get +x; everything else installs by wholesale glob copy
# below. The previous per-file module lists went 8 files stale and shipped
# installs that crashed with LoadError (2026-06-11 audit).
MAIN_HOOKS="session_start.rb saneprompt.rb sanetools.rb sanetrack.rb task_completed_gate.rb sanestop.rb"

echo "Installing portable instructions..."
if [ -f "AGENTS.md" ] && [ "$FORCE" -ne 1 ]; then
    echo -e "   ${YELLOW}!${NC} AGENTS.md exists - skipping (use --force to overwrite)"
else
    copy_file "$SANEPROCESS_DIR/templates/AGENTS_TEMPLATE.md" "AGENTS.md" "AGENTS.md" ""
fi
echo ""

if [ "$INSTALL_CLAUDE" -eq 1 ]; then
    echo "Installing Claude Code native hook adapter..."
    mkdir -p .claude/rules .claude/skills scripts/hooks/core

    SRC="$SANEPROCESS_DIR/scripts/hooks"
    for hook in $MAIN_HOOKS; do
        copy_file "$SRC/$hook" "scripts/hooks/$hook" "$hook" "+x"
    done
    # Wholesale copy of the rest of the hook tree: support modules, core
    # modules, guards, and self-tests ride along so the install can never
    # drift from the entry hooks' require graph.
    for f in "$SRC"/*.rb; do
        base="$(basename "$f")"
        case " $MAIN_HOOKS " in *" $base "*) continue ;; esac
        copy_file "$f" "scripts/hooks/$base" "$base" ""
    done
    for f in "$SRC"/core/*.rb; do
        base="core/$(basename "$f")"
        copy_file "$f" "scripts/hooks/$base" "$base" ""
    done

    RULES_SRC="$SANEPROCESS_DIR/.claude/rules"
    if [ -d "$RULES_SRC" ]; then
        for rule in hooks.md scripts.md; do
            if [ -f "$RULES_SRC/$rule" ]; then
                copy_file "$RULES_SRC/$rule" ".claude/rules/$rule" ".claude/rules/$rule" ""
            fi
        done
    fi

    if [ -f ".claude/settings.json" ] && [ "$FORCE" -ne 1 ]; then
        echo -e "   ${YELLOW}!${NC} .claude/settings.json exists - skipping (merge manually or use --force)"
        if grep -q 'scripts/hooks/saneprompt.rb' .claude/settings.json 2>/dev/null; then
            CLAUDE_SETTINGS_ACTIVE=1
        fi
    else
        mkdir -p .claude
        cat > .claude/settings.json <<'SETTINGS_EOF'
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
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sane_catastrophic_guard.rb",
            "timeout": 5000
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sanetools.rb",
            "timeout": 5000
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/sane_bash_guards.rb",
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
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "ruby \"$CLAUDE_PROJECT_DIR\"/scripts/hooks/task_completed_gate.rb",
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
        echo -e "   ${GREEN}+${NC} .claude/settings.json"
        CLAUDE_SETTINGS_ACTIVE=1
    fi

    if [ -f ".claude/.gitignore" ] && [ "$FORCE" -ne 1 ]; then
        echo -e "   ${YELLOW}!${NC} .claude/.gitignore exists - skipping"
    else
        cat > .claude/.gitignore <<'GITIGNORE_EOF'
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

# Keep rules, skills, and settings in version control
!rules/
!skills/
!settings.json
GITIGNORE_EOF
        echo -e "   ${GREEN}+${NC} .claude/.gitignore"
    fi
    echo ""
fi

if [ "$INSTALL_CLAUDE" -eq 1 ] || [ "$INSTALL_AGENTS_SKILLS" -eq 1 ]; then
    echo "Installing reusable skills..."
    SKILLS_SRC="$SANEPROCESS_DIR/skills"
    if [ -d "$SKILLS_SRC" ]; then
        for skill_dir in "$SKILLS_SRC"/*/; do
            skill_name=$(basename "$skill_dir")
            [ -f "$skill_dir/SKILL.md" ] || continue

            if [ "$INSTALL_CLAUDE" -eq 1 ]; then
                mkdir -p ".claude/skills/$skill_name"
                copy_file "$skill_dir/SKILL.md" ".claude/skills/$skill_name/SKILL.md" ".claude/skills/$skill_name" ""
                if [ -d "$skill_dir/prompts" ]; then
                    mkdir -p ".claude/skills/$skill_name/prompts"
                    for prompt in "$skill_dir"/prompts/*.md; do
                        [ -f "$prompt" ] && copy_file "$prompt" ".claude/skills/$skill_name/prompts/$(basename "$prompt")" ".claude/skills/$skill_name/prompts/$(basename "$prompt")" ""
                    done
                fi
            fi

            if [ "$INSTALL_AGENTS_SKILLS" -eq 1 ]; then
                mkdir -p ".agents/skills/$skill_name"
                copy_file "$skill_dir/SKILL.md" ".agents/skills/$skill_name/SKILL.md" ".agents/skills/$skill_name" ""
                if [ -d "$skill_dir/prompts" ]; then
                    mkdir -p ".agents/skills/$skill_name/prompts"
                    for prompt in "$skill_dir"/prompts/*.md; do
                        [ -f "$prompt" ] && copy_file "$prompt" ".agents/skills/$skill_name/prompts/$(basename "$prompt")" ".agents/skills/$skill_name/prompts/$(basename "$prompt")" ""
                    done
                fi
            fi
        done
    else
        echo -e "   ${YELLOW}!${NC} No skills found (optional)"
    fi
    echo ""
fi

echo "Verifying installation..."
if [ ! -f "AGENTS.md" ]; then
    echo -e "   ${RED}x${NC} AGENTS.md missing"
    ERRORS=$((ERRORS + 1))
else
    echo -e "   ${GREEN}+${NC} AGENTS.md present"
fi

if [ "$INSTALL_CLAUDE" -eq 1 ]; then
    for hook in $MAIN_HOOKS; do
        if [ ! -f "scripts/hooks/$hook" ]; then
            echo -e "   ${RED}x${NC} scripts/hooks/$hook missing"
            ERRORS=$((ERRORS + 1))
        elif ! "$RUBY_CMD" -c "scripts/hooks/$hook" >/dev/null 2>&1; then
            echo -e "   ${RED}x${NC} scripts/hooks/$hook has syntax errors"
            ERRORS=$((ERRORS + 1))
        fi
    done
    if [ -f ".claude/settings.json" ]; then
        "$RUBY_CMD" -rjson -e 'JSON.parse(File.read(".claude/settings.json"))' >/dev/null 2>&1 || {
            echo -e "   ${RED}x${NC} .claude/settings.json is not valid JSON"
            ERRORS=$((ERRORS + 1))
        }
        if [ "$CLAUDE_SETTINGS_ACTIVE" -eq 1 ]; then
            echo -e "   ${GREEN}+${NC} Claude hook registration present"
        else
            echo -e "   ${YELLOW}!${NC} Claude hook registration was not changed; merge SaneProcess hooks manually"
        fi
    else
        echo -e "   ${YELLOW}!${NC} .claude/settings.json missing because existing config was not overwritten"
    fi
fi

if [ "$INSTALL_AGENTS_SKILLS" -eq 1 ]; then
    if [ -d ".agents/skills" ]; then
        echo -e "   ${GREEN}+${NC} .agents/skills present"
    else
        echo -e "   ${RED}x${NC} .agents/skills missing"
        ERRORS=$((ERRORS + 1))
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    echo ""
    echo -e "${RED}Installation completed with $ERRORS error(s)${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Installation complete${NC}"
echo ""
echo "Installed adapter: $CLIENT"
echo "  AGENTS.md: portable rules for any repo-aware coding agent"
if [ "$INSTALL_CLAUDE" -eq 1 ]; then
    if [ "$CLAUDE_SETTINGS_ACTIVE" -eq 1 ]; then
        echo "  Claude Code: native lifecycle hooks in .claude/settings.json"
    else
        echo "  Claude Code: hook files installed; settings merge still required"
    fi
fi
if [ "$INSTALL_AGENTS_SKILLS" -eq 1 ]; then
    echo "  Shared skills: .agents/skills"
fi
if [ "$CLIENT" = "grok" ]; then
    echo "  Grok: AGENTS.md + .agents/skills; use /mcps or Ctrl+L for live MCP status"
fi
if [ "$CLIENT" = "generic" ]; then
    echo "  Generic agent path: AGENTS.md plus your project's own scripts and checks"
fi
echo ""

echo -e "${BLUE}Optional MCP setup:${NC}"
echo "  SaneProcess works without MCP. MCP servers make research and API checks stricter."

show_install_commands() {
    server_name="$1"
    stdio_cmd="$2"
    extra_note="$3"

    if [ "$INSTALL_CLAUDE" -eq 1 ]; then
        echo "    Claude: claude mcp add ${server_name} -- ${stdio_cmd}"
    fi
    if [ "$CLIENT" = "all" ] || [ "$CLIENT" = "codex" ]; then
        echo "    Codex:  codex mcp add ${server_name} -- ${stdio_cmd}"
    fi
    if [ "$CLIENT" = "grok" ]; then
        echo "    Grok:   add ${server_name} in Grok MCP settings if not provided by compatibility config: ${stdio_cmd}"
    fi
    if [ "$CLIENT" = "generic" ]; then
        echo "    Generic: add ${server_name} to your client's MCP configuration using: ${stdio_cmd}"
    fi
    if [ -n "$extra_note" ]; then
        echo "    ${extra_note}"
    fi
}

show_install_commands "context7" "npx -y @upstash/context7-mcp@2.2.5" ""
show_install_commands "github" "npx -y @modelcontextprotocol/server-github@2025.4.8" "Requires: GITHUB_PERSONAL_ACCESS_TOKEN"
if [ "$PLATFORM" = "macOS" ]; then
    show_install_commands "apple-docs" "npx -y @mweinbach/apple-docs-mcp@1.3.1" ""
fi
echo ""

echo -e "${BLUE}Verify:${NC}"
case "$CLIENT" in
    all|claude)
        echo "  ruby scripts/hooks/saneprompt.rb --self-test"
        echo "  ruby scripts/hooks/sanetrack.rb --self-test"
        echo "  ruby scripts/hooks/sanestop.rb --self-test"
        ;;
    codex)
        echo "  Confirm your client sees AGENTS.md"
        echo "  Confirm reusable skills exist under .agents/skills"
        ;;
    grok)
        echo "  Confirm Grok sees AGENTS.md"
        echo "  Confirm reusable skills exist under .agents/skills"
        echo "  Check live MCP state in Grok with /mcps or Ctrl+L; native grok mcp list may not include compatibility-loaded servers"
        ;;
    generic)
        echo "  Confirm your agent reads AGENTS.md"
        echo "  Run the project's normal test or verify command"
        ;;
esac
echo ""
echo "Docs: https://github.com/sane-apps/SaneProcess"
