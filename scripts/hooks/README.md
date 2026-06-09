# SaneProcess Hooks

Production-ready Claude-native hooks for SaneProcess SOP enforcement.

For Codex and other clients, treat these as one layer of the system, not the whole system. The stable cross-client path is `AGENTS.md`, repo skills, MCP, `SaneMaster.rb`, and shared shell/script guards.

## Architecture

6 hooks, shared helpers, self-test helpers, and 1 state file:

| Hook | Type | Purpose | Current self-test count |
|------|------|---------|-------|
| `saneprompt.rb` | UserPromptSubmit | Classifies prompts, handles commands (rb-, s+, etc.) | 62 |
| `sanetools.rb` | PreToolUse | Gates edits on research, blocks paths, circuit breaker | 66 |
| `sanetrack.rb` | PostToolUse | Tracks edits, failures, per-signature errors | 38 |
| `task_completed_gate.rb` | TaskCompleted | Blocks completion claims unless non-doc edits have a fresh counted verify metric with matching source fingerprint | registry-backed |
| `sanestop.rb` | Stop | Session stats, summary reminder, structured verification gate | 45 |
| `session_start.rb` | SessionStart | Bootstraps session, resets state | covered by session docs/integration tests |

**Tier suite:** 185 hook-layer tests (including integration). Additional focused hook tests cover `sanetools`, session docs/startup, Grok guard behavior, and shell-level security guards.

These are hook-layer counts only. Full repo verification is registry-backed and also runs Ruby/Python/SaneMaster/Mini-support tests through `ruby scripts/SaneMaster.rb verify`.

## Quick Start

```bash
# Run all tests
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools_test.rb
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
ruby scripts/hooks/session_docs_test.rb
ruby scripts/hooks/grok_and_security_guard_test.rb
ruby scripts/hooks/test/tier_tests.rb
```

Full verification remains `ruby scripts/SaneMaster.rb verify`; the focused commands above are the hook-layer slices.

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
| `sanetrack_tracking.rb` | Per-tool result tracking extracted from `sanetrack.rb` |
| `sanetrack_gate.rb` | Post-edit enforcement helpers |
| `sanestop_finalize.rb` | Session-end verification, receipts, and learnings extracted from `sanestop.rb` |
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
- 2 consecutive failures, OR
- 2x same error signature (even with successes between)

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
