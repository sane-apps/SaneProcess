# SaneProcess Development Guide

> Ruby hooks for Claude Code enforcement. Source of truth for all Sane projects.

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

## Quick Start

```bash
ruby scripts/qa.rb                    # Full QA check
ruby scripts/hooks/test/tier_tests.rb # Run hook tests
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project sync
```

## The Rules: Scientific Method for AI

These rules enforce the scientific method. Not optional guidelines - **the hooks block you until you comply.**

### Core Principles (Scientific Method)

| # | Rule | Scientific Method | What Hooks Do |
|---|------|-------------------|---------------|
| #2 | **VERIFY BEFORE YOU TRY** | Observe before hypothesizing | Blocks edits until 5 research categories done |
| #3 | **TWO STRIKES? INVESTIGATE** | Reject failed hypothesis | Circuit breaker trips at 3 failures |
| #4 | **TESTS MUST PASS** | Experimental validation | Tracks test results, blocks on red |

**This is the core.** Guessing is not science. Verify → Hypothesize → Test → Learn.

### Supporting Rules (Code Quality)

| # | Rule | Purpose |
|---|------|---------|
| #0 | **NAME RULE FIRST** | State which rule applies before acting |
| #1 | **STAY IN LANE** | No edits outside project scope |
| #5 | **THEIR HOUSE THEIR RULES** | Use project conventions, not preferences |
| #7 | **NO TEST NO REST** | No tautologies (`#expect(true)`) |
| #8 | **BUG FOUND? WRITE DOWN** | Document bugs in memory |
| #9 | **USE GENERATORS** | Use project scaffolding tools |
| #10 | **FILE SIZE LIMIT** | Max 500 lines (800 hard limit) |

### Research Categories (Required Before Edits)

The hooks require ALL 5 categories before any edit is allowed:

| Category | Tool | What You Learn |
|----------|------|----------------|
| **memory** | `mcp__memory__read_graph` | Past bugs, patterns, decisions |
| **docs** | `mcp__apple-docs__*`, `mcp__context7__*` | API verification |
| **web** | `WebSearch` | Current best practices |
| **github** | `mcp__github__search_*` | External examples |
| **local** | `Read`, `Grep`, `Glob` | Existing code patterns |

**Why all 5?** Each category catches different blind spots. Skip one → miss something → fail → waste time.

## macOS UI Testing

Two different tools for two different targets:

| Tool | Target | Use For |
|------|--------|---------|
| **XcodeBuildMCP** | iOS Simulator | Build, test, simulator UI automation |
| **macos-automator** | Real macOS Desktop | Click menu bars, test actual running apps |

**For menu bar apps (SaneBar):** Use `macos-automator` to interact with real UI - XcodeBuildMCP's UI tools only work in simulator.

## Project Structure

```
scripts/
├── hooks/                 # Enforcement hooks (synced to all projects)
│   ├── session_start.rb   # SessionStart - bootstrap
│   ├── saneprompt.rb      # UserPromptSubmit - classify task
│   ├── sanetools.rb       # PreToolUse - block until research done
│   ├── sanetrack.rb       # PostToolUse - track failures
│   ├── sanestop.rb        # Stop - capture learnings
│   ├── core/              # Shared infrastructure
│   └── test/              # Hook tests
├── SaneMaster.rb          # CLI entry (different from Swift projects)
└── qa.rb                  # Quality assurance
```

## Testing

```bash
ruby scripts/hooks/test/tier_tests.rb           # All tests
ruby scripts/hooks/test/tier_tests.rb --tier easy    # Easy tier
ruby scripts/hooks/test/tier_tests.rb --tier hard    # Hard tier
ruby scripts/hooks/test/tier_tests.rb --tier villain # Villain tier
```

## Cross-Project Sync

SaneProcess hooks sync to: SaneBar, SaneVideo, SaneSync

```bash
# Check sync status
ruby scripts/sync_check.rb ~/SaneBar

# Sync hooks after changes
rsync -av scripts/hooks/ ~/SaneBar/scripts/hooks/
rsync -av scripts/hooks/ ~/SaneVideo/scripts/hooks/
rsync -av scripts/hooks/ ~/SaneSync/scripts/hooks/
```

## Before Pushing

1. `ruby scripts/qa.rb` - QA passes
2. `ruby scripts/hooks/test/tier_tests.rb` - All tests pass
3. Sync to other projects if hooks changed
