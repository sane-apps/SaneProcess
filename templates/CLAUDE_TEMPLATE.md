# [AppName] Project Configuration

> Project-specific settings that override/extend the global ~/CLAUDE.md

---

## Sane Philosophy

```
┌─────────────────────────────────────────────────────┐
│           BEFORE YOU SHIP, ASK:                     │
│                                                     │
│  1. Does this REDUCE fear or create it?             │
│  2. Power: Does user have control?                  │
│  3. Love: Does this help people?                    │
│  4. Sound Mind: Is this clear and calm?             │
│                                                     │
│  Grandma test: Would her life be better?            │
│                                                     │
│  "Not fear, but power, love, sound mind"            │
│  — 2 Timothy 1:7                                    │
└─────────────────────────────────────────────────────┘
```

→ Full philosophy: `~/SaneApps/meta/Brand/NORTH_STAR.md`

---

## Project Location

| Path | Description |
|------|-------------|
| **This project** | `~/SaneApps/apps/[AppName]/` |
| **Save outputs** | `~/SaneApps/apps/[AppName]/outputs/` |
| **Screenshots** | `~/Desktop/Screenshots/` (label with project prefix) |
| **Shared UI** | `~/SaneApps/infra/SaneUI/` |
| **Hooks/tooling** | `~/SaneApps/infra/SaneProcess/` |

**Sister apps:** SaneBar, SaneClip, SaneVideo, SaneSync, SaneHosts, SaneAI, SaneScript

---

## Where to Look First

| Need | Check |
|------|-------|
| Build/test commands | `./scripts/SaneMaster.rb --help` |
| Project structure | `project.yml` (XcodeGen config) |
| Past bugs/learnings | `.claude/memory.json` or MCP memory |
| Code patterns | `.claude/rules/` directory |
| Swift services | `Core/Services/` directory |
| UI components | `UI/` directory |

---

## PRIME DIRECTIVE (from ~/CLAUDE.md)

> When hooks fire: **READ THE MESSAGE FIRST**. The answer is in the prompt/hook/memory/SOP.
> Stop guessing. Start reading.

---

## Project Overview

<!-- ONE PARAGRAPH describing what this app does and its key purpose -->

[AppName] is a macOS app that [describe core functionality].

---

## Project Structure

| Path | Purpose |
|------|---------|
| `scripts/SaneMaster.rb` | Build tool - use instead of raw xcodebuild |
| `Core/` | Foundation types, Managers, Services |
| `Core/Services/` | Business logic services |
| `Core/Models/` | Data models |
| `UI/` | SwiftUI views |
| `Tests/` | Unit tests (Swift Testing) |
| `project.yml` | XcodeGen configuration |

---

## Quick Commands

```bash
# Build & Test
./scripts/SaneMaster.rb verify     # Build + run tests

# Full dev cycle
./scripts/SaneMaster.rb test_mode  # Kill → Build → Launch → Logs

# Logs
./scripts/SaneMaster.rb logs --follow
```

---

## Key Documentation

| Document | When to Use |
|----------|-------------|
| [DEVELOPMENT.md](DEVELOPMENT.md) | Full SOP, 12 rules, compliance |
| [.claude/rules/](/.claude/rules/) | Code style rules by file type |

---

## MCP Tool Optimization (TOKEN SAVERS)

### Xcode Tools (Apple's Official MCP via `xcrun mcpbridge`)
Apple's first-party MCP server, configured globally as `xcode`. Requires Xcode to be running with the project open.
Get the `tabIdentifier` first, then run build/test/preview tools:
```
mcp__xcode__XcodeListWindows
mcp__xcode__BuildProject
mcp__xcode__RunAllTests
mcp__xcode__RenderPreview
```
Note: This is a **macOS app**. Use `macos-automator` for real UI interaction.

### apple-docs Optimization
- `compact: true` works on `list_technologies`, `get_sample_code`, `wwdc` (NOT on `search_apple_docs`)
- `analyze_api analysis="all"` for comprehensive API analysis
- `apple_docs` as universal entry point (auto-routes queries)

### context7 for Library Docs
- `resolve-library-id` FIRST, then `query-docs`
- SwiftUI ID: `/websites/developer_apple_swiftui` (13,515 snippets!)

### macos-automator (493 Pre-Built Scripts)
- `get_scripting_tips search_term: "keyword"` to find scripts
- `get_scripting_tips list_categories: true` to browse
- 13 categories including `13_developer` (92 Xcode/dev scripts)

---

## Claude Code Features (USE THESE!)

### Key Commands

| Command | When to Use | Shortcut |
|---------|-------------|----------|
| `/rewind` | Rollback code AND conversation after errors | `Esc+Esc` |
| `/context` | Visualize context window token usage | - |
| `/compact [instructions]` | Optimize memory with focus | - |
| `/stats` | See usage patterns (press `r` for date range) | - |

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Esc+Esc` | Rewind to checkpoint |
| `Shift+Tab` | Cycle permission modes |
| `Option+T` | Toggle extended thinking |
| `Ctrl+B` | Background running task |

### Smart /compact Instructions

```
/compact keep [AppName] patterns and bug fixes, archive general Swift tips
```

### Use Explore Subagent for Searches

```
Task tool with subagent_type: Explore
```
