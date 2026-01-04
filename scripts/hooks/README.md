# SaneProcess Hooks

Production-ready hooks for Claude Code SOP enforcement.

## Architecture

4 hooks, 4 core modules, 1 state file:

| Hook | Type | Purpose | Tests |
|------|------|---------|-------|
| `saneprompt.rb` | UserPromptSubmit | Classifies prompts, handles commands (rb-, s+, etc.) | 26 |
| `sanetools.rb` | PreToolUse | Gates edits on research, blocks paths, circuit breaker | 17 |
| `sanetrack.rb` | PostToolUse | Tracks edits, failures, per-signature errors | 15 |
| `sanestop.rb` | Stop | Session stats, summary reminder | 8 |

**Total: 66 tests**

## Quick Start

```bash
# Run all tests
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
```

## User Commands

| Command | Effect |
|---------|--------|
| `rb-` | Reset circuit breaker |
| `rb?` | Show circuit breaker status |
| `s+` | Enable safemode (blocks edits) |
| `s-` | Disable safemode |
| `s?` | Show safemode status |
| `research` | Show research progress |

## Core Modules

```
scripts/hooks/core/
├── config.rb         # Paths, thresholds, settings
└── state_manager.rb  # Read/write state.json (signed)
```

## State File

All state in `.claude/state.json`:

```json
{
  "circuit_breaker": { "failures": 0, "tripped": false },
  "research": { "memory": null, "docs": null, "web": null, "github": null, "local": null },
  "edits": { "count": 0, "unique_files": [] },
  "enforcement": { "blocks": [], "halted": false }
}
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Allow |
| 2 | **BLOCK** |

## Research Gate

Before edits allowed, must complete 5 categories:

| Category | Satisfied by |
|----------|--------------|
| memory | `mcp__memory__*` |
| docs | `mcp__context7__*`, `mcp__apple-docs__*` |
| web | `WebSearch`, `WebFetch` |
| github | `mcp__github__*` |
| local | `Read`, `Grep`, `Glob` |

## Circuit Breaker

Trips at:
- 3 consecutive failures, OR
- 3x same error signature (even with successes between)

Reset with `rb-` command.

## Files

| File | Purpose |
|------|---------|
| `.claude/state.json` | All hook state (signed) |
| `.claude/state.json.lock` | File lock |
| `.claude/bypass_active.json` | Safemode marker |
| `.claude/*.log` | Per-hook logs |

## Legacy

Old hooks in `scripts/hooks/legacy/` - archived, not active.
