# SaneProcess Hooks

Production-ready hooks for Claude Code SOP enforcement.

## Architecture

5 hooks, shared helpers, self-test helpers, and 1 state file:

| Hook | Type | Purpose | Tests |
|------|------|---------|-------|
| `saneprompt.rb` | UserPromptSubmit | Classifies prompts, handles commands (rb-, s+, etc.) | 62 |
| `sanetools.rb` | PreToolUse | Gates edits on research, blocks paths, circuit breaker | 66 |
| `sanetrack.rb` | PostToolUse | Tracks edits, failures, per-signature errors | 37 |
| `sanestop.rb` | Stop | Session stats, summary reminder | 5 |
| `session_start.rb` | SessionStart | Bootstraps session, resets state | bootstrap only |

**Tier suite:** 178 tests (including integration)

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

## Support Modules

| File | Purpose |
|------|---------|
| `sanetools_checks.rb` | Extracted validation logic |
| `sanetools_startup.rb` | Startup-gate enforcement helpers |
| `sanetools_gaming.rb` | Gaming detection (research cheating) |
| `sanetools_deploy.rb` | Deployment safety checks |
| `sanetools_github_guard.rb` | GitHub posting approval guard |
| `saneprompt_intelligence.rb` | Prompt classification |
| `saneprompt_commands.rb` | Safemode, breaker, planning user commands |
| `sanetrack_research.rb` | Research write/size validation |
| `sanetrack_state_updates.rb` | State mutation helpers for PostToolUse |
| `sanetrack_gate.rb` | Post-edit enforcement helpers |
| `sanetrack_reminders.rb` | Feature reminders and logging |
| `session_briefing.rb` | Session-start briefing output |
| `session_start_cleanup.rb` | Session-start cleanup helpers |
| `self_test_environment.rb` | Isolated temp project for `--self-test` |
| `rule_tracker.rb` | Rule tracking shared module |
| `state_signer.rb` | State file signing/verification |

## Core Modules

| File | Purpose |
|------|---------|
| `core/config.rb` | Shared project/config lookup |
| `core/state_manager.rb` | Locked, signed state store |
| `core/context_compact.rb` | Context compaction helpers |

## Self-Test Modules

| File | Purpose |
|------|---------|
| `saneprompt_test.rb` | saneprompt self-tests |
| `sanetools_test.rb` | sanetools self-tests |
| `sanetools_test_scenarios.rb` | shared sanetools self-test fixtures |
| `sanetrack_test.rb` | sanetrack self-tests |
| `sanestop_test.rb` | sanestop self-tests |

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

Before edits allowed, complete the always-required categories plus any MCP-backed categories you configured:

| Category | Satisfied by | Required? |
|----------|--------------|-----------|
| docs | `mcp__context7__*`, `mcp__apple-docs__*` | If docs MCPs configured |
| web | `WebSearch`, `WebFetch` | Always |
| github | `mcp__github__*` | If GitHub MCP configured |
| local | `Read`, `Grep`, `Glob` | Always |

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

## Testing

Run the full test suite:
```bash
ruby scripts/hooks/test/tier_tests.rb  # 178 tests
```
