# SaneProcess Hooks

Shared SaneProcess SOP and safety hooks. Regular clients are Grok and Cursor.
Claude and Codex keep their own hook registrations as compatibility adapters.

Safety guards (`sane_catastrophic_guard.rb`, `sane_bash_guards.rb`, release /
ship / email / launch / layout) parse Claude snake_case, Grok camelCase, and
Cursor shell payloads through `core/hook_payload.rb`.

| Client | Registration |
|--------|----------------|
| Grok | `~/.grok/hooks/sane-guards.json` from `scripts/hooks/grok/hooks.json`. Claude/Cursor hook import is off (`compat.*.hooks = false`). |
| Cursor | `~/.cursor/hooks.json` from `scripts/hooks/cursor/hooks.json.example`. |
| Claude | `.claude/settings.json` via `run_hook.sh` for SOP hooks, plus the shared guards. |
| Codex | Existing Codex hook adapters. Shell guards still fire when Codex sends `tool_name=Bash`. |

## Architecture

Native hook entry points, shared helpers, self-test helpers, and one signed state
file:

| Hook | Type | Purpose |
|------|------|---------|
| `session-guardian.sh` | LaunchAgent, 10 min | Reap dead-parent MCP leftovers; page Air on sustained unexpected CPU |
| `session_start.rb` | SessionStart | Bootstraps session, resets stale state, prints briefing |
| `saneprompt.rb` | UserPromptSubmit | Classifies prompts and handles commands (`rb-`, `s+`, etc.) |
| `sanetools.rb` | PreToolUse | Gates edits on research, blocks risky paths/routes, trips circuit breaker |
| `sanetrack.rb` | PostToolUse | Tracks research evidence, edits, failures, proof state, and fresh persistence debt |
| `task_completed_gate.rb` | TaskCompleted | Blocks completion claims without required verification or current handoff/memory checkpoints |
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
ruby scripts/hooks/gui_feedback_test.rb
ruby scripts/hooks/test_hooks.rb
ruby scripts/hooks/session_docs_test.rb
ruby scripts/hooks/grok_and_security_guard_test.rb
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
| `sanetrack_review_tracking.rb` | Review-source binding and completed independent-review tracking |
| `sanetrack_gate.rb` | Post-edit enforcement helpers |
| `sanetrack_proofs.rb` | Proof receipt and runner tracking |
| `sanestop_finalize.rb` | Session-end verification, receipts, and learnings extracted from `sanestop.rb` |
| `sanestop_learnings.rb` | Session learnings capture + cap, extracted from `sanestop_finalize.rb` |
| `sanestop_lemonsqueezy.rb` | Non-blocking post-release staging for Lemon Squeezy uploads |
| `sanetrack_reminders.rb` | Feature reminders and logging |
| `session_briefing.rb` | Session-start briefing output |
| `session_start_cleanup.rb` | Session-start cleanup helpers |
| `release_receipt_signer.rb` | Signs and verifies release-authorizing receipts from canonical producers |
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
| `core/context_compact.rb` | Early context warning that requires persistence debt to be cleared before compaction |
| `core/sop_score.rb` | Shared SOP score rubric |

## Self-Test Modules

| File | Purpose |
|------|---------|
| `saneprompt_test.rb` | saneprompt self-tests |
| `sanetools_test.rb` | sanetools self-tests |
| `sanetools_gate_test.rb` | sanetools startup, GitHub, and MCP gate self-tests |
| `sanetools_test_scenarios.rb` | shared sanetools self-test fixtures |
| `sanetrack_test.rb` | sanetrack self-tests |
| `sanetrack_test_mcp_verification.rb` | bare and plugin-prefixed MCP verification tracking self-tests |
| `sanetrack_test_runner_proofs.rb` | canonical runner receipt, replay-resistance, and clearance self-tests |
| `sanetrack_test_tautology.rb` | sanetrack tautology-detection (Rule #7) self-tests, extracted from `sanetrack_test.rb` |
| `sanetrack_blind_tests.rb` | sanetrack blind/adversarial tracking self-tests |
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
| docs | `mcp__apple-docs__*` (`context7` is toggled off, not callable) | If docs MCPs configured |
| web | `WebSearch`, `WebFetch` | Always |
| github | `gh` skill (`mcp__github__*` no longer gates research) | If GitHub work configured |
| local | `Read`, `Grep`, `Glob` | Always |

## Circuit Breaker

Trips at:
- 2 consecutive failures, OR
- 2x same error signature (even with successes between)

Reset with `rb-` command.

## Bash-Boundary Blocks

`sane_bash_guards.rb` blocks these at the Bash boundary (exit 2, no override).
Agents hit these cold — read the block message and use the canonical path.

| Block | Code | Use instead |
|---|---|---|
| Destructive `security` keychain mutations (`add-*-password -U`, `delete-*`, `set-*-partition-list`; reads stay allowed) | `sane_bash_guards.rb:308-355` | Run it in your own terminal; never from the agent |
| Detached Mini QA via `launchctl submit` (`run_sanebar_qa`, `Scripts/qa.rb`, `SANEBAR_RUN_RUNTIME_SMOKE`, `SaneMaster.rb release_preflight`) | `sane_bash_guards.rb:96-106` | Foreground canonical release/runtime commands |
| Safari automation, including `mini-safari.sh` (`osascript tell … "Safari"`, `open -a Safari`) | `sane_bash_guards.rb:366-403` | Brave on the Mini |
| Raw remote screen capture (`screencapture`, `peekaboo image`/`capture`/`list`, `ffmpeg` + `avfoundation` over ssh) | `sane_bash_guards.rb:68-94` | `mini-gui-run.sh` / `capture-mini-screenshot.sh` |

## Local-UI Guard (Air)

On the Air, `core/local_ui_guard.rb:97-153` blocks three things: editing
`SaneApps/apps/*` source, `pbcopy`/`pbpaste` (Universal Clipboard contaminates
the Mini's Clip history), and driving SaneApps UI / Peekaboo / HID locally.
Use `ssh mini` and `mini-gui-run.sh` on the Mini. The ONLY fallback after
explicit owner approval prefixes the shell command (an `export` inside the
command does not count) or sets hook-process env:

```bash
SANE_APPROVE_LOCAL_UI_ON_AIR='MR. SANE APPROVES LOCAL UI ON AIR' …
SANE_MINI_UNAVAILABLE='MR. SANE CONFIRMS MINI UNAVAILABLE' …
```

The phrases must match exactly (`core/local_ui_guard.rb:20-21,44-67`).

## Files

| File | Purpose |
|------|---------|
| `.claude/state.json` | All hook state (signed) |
| `.claude/state.json.lock` | File lock |
| `.claude/bypass_active.json` | Safemode marker |
| `.claude/*.log` | Per-hook logs |

## Testing

Hook-layer commands live in Quick Start above. Full verification remains
`ruby scripts/SaneMaster.rb verify`.

## Cursor GUI feedback

Permanent owner rule (2026-07-29): after GUI/portal mutations, re-read dialog/page/AX/API before claiming success.

Shared logic: `scripts/hooks/core/gui_feedback.rb`  
Tests: `ruby scripts/hooks/gui_feedback_test.rb`

**Conversation scope (2026-09-02):** pending state is per Cursor `conversation_id`
under `~/.cursor/sane_gui_feedback/<id>.json`. The old global
`~/.cursor/sane_gui_feedback.json` is retired (`legacy_disabled`) so a T&Z Mini
session cannot inject stop follow-ups into unrelated chats. Stop with a missing
`conversation_id` never follows up. Bare System Events AX reads and `simctl`
screenshots count as feedback polls, not mutations.

Install Cursor adapters on the controller (Air):

```bash
mkdir -p ~/.cursor/hooks
cp scripts/hooks/cursor/gui_feedback_after_shell.rb ~/.cursor/hooks/
cp scripts/hooks/cursor/gui_feedback_stop.rb ~/.cursor/hooks/
chmod +x ~/.cursor/hooks/gui_feedback_*.rb
# Merge hooks.json.example into ~/.cursor/hooks.json (afterShellExecution + stop)
# Prefer pointing hooks.json at the repo adapters so conversation_id wiring stays current.
```
