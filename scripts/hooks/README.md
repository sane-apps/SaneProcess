# SaneProcess Hooks

Production-ready Claude-native hooks for SaneProcess SOP enforcement.

For Codex and other clients, treat these as one layer of the system, not the whole system. The stable cross-client path is `AGENTS.md`, repo skills, MCP, `SaneMaster.rb`, and shared shell/script guards.

## Architecture

Native hook entry points, shared helpers, self-test helpers, and one signed state
file:

| Hook | Type | Purpose |
|------|------|---------|
| `session_start.rb` | SessionStart | Bootstraps session, resets stale state, prints briefing |
| `saneprompt.rb` | UserPromptSubmit | Classifies prompts and handles commands (`rb-`, `s+`, etc.) |
| `sanetools.rb` | PreToolUse | Gates edits on research, blocks risky paths/routes, trips circuit breaker |
| `sanetrack.rb` | PostToolUse | Tracks research evidence, edits, failures, and proof state |
| `task_completed_gate.rb` | TaskCompleted | Blocks completion claims without required verification evidence |
| `sanestop.rb` | Stop | Session summary, verification gate, handoff/memory reminders |

Hook-layer counts move as guardrails are extracted. Use the commands below for
focused hook proof; full repo verification remains
`ruby scripts/SaneMaster.rb verify`.

## Quick Start

```bash
# Run all tests
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
ruby scripts/hooks/test_hooks.rb
ruby scripts/hooks/session_docs_test.rb
ruby scripts/hooks/grok_and_security_guard_test.rb
ruby scripts/hooks/test_hooks.rb
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
| `sanetools_refusal.rb` | Repeat-block/refusal tracking |
| `sanetools_research.rb` | MCP-aware research and MCP verification helpers |
| `saneprompt_intelligence.rb` | Prompt classification |
| `saneprompt_commands.rb` | Safemode, breaker, planning user commands |
| `saneprompt_output.rb` | Prompt hook output formatting |
| `sanetrack_research.rb` | Research write/size validation |
| `sanetrack_state_updates.rb` | State mutation helpers for PostToolUse |
| `sanetrack_tracking.rb` | Per-tool result tracking extracted from `sanetrack.rb` |
| `sanetrack_gate.rb` | Post-edit enforcement helpers |
| `sanetrack_proofs.rb` | Proof receipt and runner tracking |
| `sanestop_finalize.rb` | Session-end verification, receipts, and learnings extracted from `sanestop.rb` |
| `sanetrack_reminders.rb` | Feature reminders and logging |
| `session_briefing.rb` | Session-start briefing output |
| `session_start_cleanup.rb` | Session-start cleanup helpers |
| `self_test_environment.rb` | Isolated temp project for `--self-test` |
| `state_signer.rb` | State file signing/verification |

## Core Modules

| File | Purpose |
|------|---------|
| `core/state_manager.rb` | Locked, signed state store |
| `core/project_root.rb` | Canonical project-root resolver for hook state |
| `core/process_metrics.rb` | Process metrics writer |
| `core/mandatory_workflows.rb` | Required workflow routing map |
| `core/local_ui_guard.rb` | Mini-first local UI guard helpers |
| `core/visual_receipt.rb` | Visual evidence receipt helpers |
| `core/session_docs.rb` | Session document gate helpers |
| `core/context_compact.rb` | Context compaction helpers |
| `core/sop_score.rb` | Shared SOP score rubric |

## Self-Test Modules

| File | Purpose |
|------|---------|
| `saneprompt_test.rb` | saneprompt self-tests |
| `sanetools_test.rb` | sanetools self-tests |
| `sanetools_gate_test.rb` | sanetools startup, GitHub, and MCP gate self-tests |
| `sanetools_test_scenarios.rb` | shared sanetools self-test fixtures |
| `sanetrack_test.rb` | sanetrack self-tests |
| `sanestop_test.rb` | sanestop self-tests |
| `sanestop_persistence_test.rb` | sanestop handoff, visual, validation, and JSON self-tests |

## State File

All hook runtime state lives in `.claude/state.json`, with defaults defined in
`StateManager::SCHEMA` inside `core/state_manager.rb`. Do not duplicate the
schema here; update the code first and document only durable design rationale in
`ARCHITECTURE.md`.

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
ruby scripts/hooks/test_hooks.rb
ruby scripts/SaneMaster.rb verify
```
