# SaneProcess Project Overview

## Purpose
SaneProcess is an SOP (Standard Operating Procedure) enforcement system for SaneApps agents. Codex is the primary operator surface; Claude Code has the strongest native lifecycle hooks; Grok, Gemini, and generic agents use the same portable `AGENTS.md`, `.agents/skills`, `SaneMaster.rb`, MCP config, and shared shell/script guard contract.

## Tech Stack
- **Language**: Ruby (hooks, CLI, tests), shell for low-level guards
- **Target**: macOS (Darwin), with Mini-first SaneApps verification
- **Integration**: Claude Code lifecycle hooks, Codex/Grok/Gemini client-managed MCP/config surfaces, shared SaneMaster wrappers

## Project Structure
```
scripts/
├── hooks/                    # lifecycle hooks + shared shell/script guards
│   ├── saneprompt.rb        # UserPromptSubmit - classify intent
│   ├── sanetools.rb         # PreToolUse - block until research done
│   ├── sanetrack.rb         # PostToolUse - track failures
│   ├── sanestop.rb          # Stop - capture learnings
│   └── core/                # Shared modules
│       ├── state_manager.rb # Thread-safe JSON state
│       └── config.rb        # Configuration
├── sanemaster/              # 19 CLI modules
└── qa.rb                    # Quality checks
.claude/
├── rules/                   # Pattern-based rules
│   ├── views.md, tests.md, services.md, models.md, scripts.md, hooks.md
└── settings.json            # Hook configuration
```

## Key Concepts
- **17 Golden Rules**: scientific-method enforcement for AI work
- **Circuit Breaker**: Auto-stops after 3 consecutive failures
- **State Signing**: HMAC signatures prevent tampering
- **Cross-Client Guardrails**: Passive tracking hooks may no-op under Grok, but high-risk launch/release/ship/email guards still enforce dangerous commands when invoked.
- **Active Client MCP Union**: MCP verification and doctor paths should read `.mcp.json`, Claude settings/permissions, Codex/Grok TOML, Gemini `mcpServers`, and neutral `.agents/skills`.
- **Cross-Project Sync**: Hooks and SaneMaster wrappers are shared with SaneApps repos.
