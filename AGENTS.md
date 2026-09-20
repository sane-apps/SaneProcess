# SaneApps AGENTS

SaneProcess is the shared SaneApps operating harness. This file is the active
agent overlay; the full runbook lives in `DEVELOPMENT.md`, `ARCHITECTURE.md`,
`DEVELOPER_SETUP.md`, `templates/RELEASE_SOP.md`, and `scripts/`.

Regular daily work is Grok, Grokbot, and Cursor (native `~/.grok/hooks` and
`~/.cursor/hooks.json`; keep Codex/Claude adapters working). Do not send
regular jobs to OpenAI or Anthropic unless the owner asks.

Speak plainly and briefly, in singular voice (`I`, `me`, `my`).

## What Belongs Here

Keep only instructions an agent must know before hooks or wrappers can help;
point at enforcement instead of duplicating policy. Enforcement:
`scripts/hooks/` (launch, build-route, release, email, GitHub, tracking,
session-end, security, visual-proof, GUI-feedback, completion gates);
`scripts/SaneMaster.rb` + `scripts/sanemaster/` (workflows);
`validation_report.rb`, `process_eval`, `sop_review`, `near_miss_review`,
tests (process evidence); handoff, research cache, file memory, Mini
AgentMemory (context; Serena is code-navigation only).

## Session Start

Tiny read-only answers need only the relevant file/command surface. For code,
audit, release, support, payment, App Store, automation, UI/runtime, or
multi-file work:

1. Read `SESSION_HANDOFF.md`.
2. Read relevant file memory and the active skill registry; query shared
   context with AgentMemory `memory_recall` or `memory_smart_search`.
3. Run `~/.grok/bin/check-mcps` or `ruby scripts/SaneMaster.rb tool_discovery --query "mcp health"` when MCP health affects the task.
4. Run `ruby scripts/validation_report.rb` for release/audit/process work
   (`--release-checklists` only for the deep all-app artifact checklist).
5. Use the Mac Mini for SaneApps inspection, build, test, screenshots, and
   runtime verification unless the Mini is unavailable or the user explicitly
   approves a local exception.

## Session End

When code, tooling, docs, policy, support, release, or UI/runtime behavior
changed:

1. Update file memory and persist cross-project AgentMemory facts/lessons.
2. Update `SESSION_HANDOFF.md` with active state, proof, open issues, next moves.
3. Run `ruby scripts/SaneMaster.rb sop_review --json`.
4. Record an evidence-backed SOP rating only within the objective cap reported
   by the tooling.

Do not wait until the end to record major bugs, root-cause changes, or process
fixes. Treat memory and handoff as live operational state.

## Core Rules

| # | Rule | Active Meaning |
|---|------|----------------|
| 0 | Name it before you tame it | State the task class before acting. |
| 1 | Stay in lane, no pain | Do not edit outside the project/scope without approval. |
| 2 | Verify, then try | Check uncertain APIs/tools/docs before coding. |
| 3 | Two strikes? Stop and check | After two matching failures, stop guessing and research the error. |
| 4 | Green means go | Do not claim done with failing tests or missing required proof. |
| 5 | House rules, use tools | Use canonical wrappers for build/test/release/launch/email/sales/support. |
| 6 | Build, kill, launch, log | Runtime changes need full cycle proof; tooling/docs need matching tests/evals. |
| 7 | No test? No rest | Every fix gets a meaningful runtime test (drive the app, assert the customer-observable end-state) or explicit proof receipt — never a BLIND string-match guard. |
| 8 | Bug found? Write it down | Update file memory + AgentMemory when bugs change status. |
| 9 | New file? Gen the pile | Prefer templates/scaffolds and existing docs/files. |
| 10 | 500 fine, 800 line | File and component-owner size both count; split at 800. |
| 11 | Tool broke? Fix the yoke | Fix repeated tool failure in the tool/hook/skill path. |
| 12 | Talk while I walk | Use authorized subagents for heavy parallel work and close them promptly. |
| 13 | Context or chaos | Keep `AGENTS.md`, handoff, research, and memory current. |
| 14 | Prompt like a pro | Give agents paths, constraints, context, and exact output needed. |
| 15 | Review before you ship | Self-review security, correctness, edge cases, and proof. |
| 16 | Do not fragment, integrate | Improve existing docs/scripts/skills before creating new surfaces. |

Workflow: PLAN -> VERIFY -> BUILD -> TEST -> CONFIRM -> PROPOSE COMMIT.

Do not commit or push unless the user asks, the task explicitly includes
release/PR/publish, or a workflow requires it.

## Standing maintenance authorization (owner, 2026-09-06)

Routine reversible work is already authorized on both the Air and Mini: inspect, edit and test within the requested
scope; update installed trusted tools/packages; use existing approved credentials internally; and restart the affected
idle service when needed to activate an update. Do not ask again for the same scope. Preserve existing macOS grants and
stable signed application identities. Do not reset TCC or rebuild/re-sign helpers merely to refresh a permission. Before
work, identify all missing OS authorizations together; run native installers sequentially and stop on an unexpected
prompt. Unattended checks use the shared no-prompt flags. Ask before destructive or materially broader security access changes. Standing approval does not authorize blanket sudo/Keychain ACL changes, credential disclosure, unrequested sends/publication, or bypassing platform approval controls. If macOS still requires authentication, explain the exact action once and use its native gate.

## Authority And Safety

When two instructions disagree, use this order:

1. Live user instruction and current machine state.
2. `AGENTS.md` for policy and `scripts/mini/README.md` for the Mini contract.
3. `DEVELOPMENT.md` and `ARCHITECTURE.md` for commands and durable decisions.
4. The compact `SESSION_HANDOFF.md` for current, host-qualified state.
5. Dated research and memories only when they are not expired or superseded.

Normal read, edit, build, test, commit, feature-push, SSH, rsync, and browser work must remain usable.
Approved tools may consume local credentials internally, but agents must never dump, print, copy, or export raw secret material. Sends, releases, uploads, reboots, and customer/data mutations use their canonical approval gates. Irreversible deletion of a home, repository, history, production resource, credential, ownership, license, or money is manual user-only and must be mechanically blocked even in bypass mode.

Working locally on the Mini means working directly in the local checkout. Do
not SSH to `mini` from the Mini; use `ssh mini` only from the Air/controller.
Run `hostname` before cross-machine diagnosis, sync claims, or acceptance work.

## Subagents

Subagents are authorized when they materially improve coverage. Before
spawning, split parent-local vs parallel work.

Every subagent prompt must include:

```text
Read relevant repo hooks in scripts/hooks/ and active client config when present (`~/.codex/config.toml`, `~/.claude/settings.json`) BEFORE doing work.
If a hook blocks you, STOP immediately and report the block back to the parent agent. Do not retry or work around it.
NEVER build or launch apps locally on the MacBook Air. Use `ssh mini` for SaneApps builds, tests, screenshots, and runtime verification.
Abide by every hook exactly as a human session would.
```

Use GPT subagents for broad review, research, audits, planning, and bounded
implementation. NVIDIA agents and Gemini/Google paths are exception-only
(explicit owner request per run); default to Apple Docs, macOS Automator,
Grok, Codex, Claude, and SaneMaster.

## Cloudflare Workers AI / NVIDIA NIM

Before any Workers AI or NIM **inference** call, follow `docs/LLM_VENDOR_API_SOP.md`. Use `scripts/llm_api_research_gate.rb` then smoke. Hook: `scripts/hooks/sane_llm_api_guard.rb` (via `sane_bash_guards.rb`). This is separate from the NVIDIA-agent ban (`nv` sweeps / `nvidia_vision`) — NIM draft APIs are allowed only with the SOP/receipt path.

Reviewer routing is perspective-driven; canonical route and discovery:
`DEVELOPMENT.md`, "Reviewer fan-out routing".

## Canonical Routes

Stateful build/test/release/launch/support/business workflows must go through
the SaneMaster wrapper; read-only diagnostics may run direct.

| Need | Canonical Route |
|------|-----------------|
| Build/test | `ruby scripts/SaneMaster.rb verify` |
| Release clearance | `ruby scripts/SaneMaster.rb release_preflight` |
| Work email | `ruby scripts/SaneMaster.rb check_inbox` |
| Tool discovery | `ruby scripts/SaneMaster.rb tool_discovery --query "..."` |
| Mini screenshot | `scripts/mini/capture-mini-screenshot.sh desktop` |

Full command map: `DEVELOPMENT.md` under "SaneMaster Commands".

Runtime app tests must attach a live app log stream from before launch through
the workflow and save the receipt path; results without live logs are invalid.

If a canonical route fails, fix it or explain why; do not silently work around
it. Raw `ssh mini ... screencapture ...` is blocked by hook — use the Mini
screenshot wrapper or fix it.

## Browser And App Control

Mini browser work is Brave-only (owner rule, 2026-07-14): never script Safari
for portal or web-proof work. Full control ladder: `DEVELOPMENT.md` under
"Reviewer fan-out routing" (browser and app-control ladder).

Mini Terminal-host rule: cleanup must never raise or activate an automation
Terminal window. Use title-scoped reclaim inside app sequences,
`--reclaim-all` only at workflow boundaries, and `--restore-bundle-id` when
the hidden command controls an open app. If Terminal surfaces, stop the GUI
sequence and fix the runner before clicking again.

Screenshots are final evidence, not the first control mechanism — capture only
when a receipt needs an image. Same ladder in Claude with its browser plugin;
compare live tools with config before declaring one missing.

Brave on the Mini is the canonical authenticated control plane for Setapp,
ASC, Apollo, Lemon Squeezy, Cloudflare, Resend, and similar portals (Codex
and Claude alike). Prefer healthy API wrappers, but inspect the live Brave
session before declaring a surface unavailable: a missing token blocks only
the unattended API lane, and a managed-shell "Brave not found" is a TCC
boundary, not proof Brave is down.

## Tool Discovery

Before declaring a tool missing or inventing a repeated workaround:

Check the skill registry, run `tool_discovery --query "..."`, search existing
scripts/hooks/skills/docs; if still missing and repeatable, add it to
SaneProcess as the standard path.

## Mini-First Rule

The Mac Mini is the canonical SaneApps build/test/runtime host.

Use `ssh mini` and SaneMaster/sane_test wrappers for app work. Local fallback
only when the Mini is unavailable or explicitly approved for that exact task.
Leave no test apps, stale shells, or helper windows on the Mini. Details:
`DEVELOPMENT.md`, `scripts/mini/`.

## Visual/UI Proof

Green tests are not enough for UI claims. Capture clean saved Mini screenshots
for every customer-facing view/state touched, inspect them, record paths plus
verdicts. Full rules: `DEVELOPMENT.md`, "Runtime And Visual Evidence".

## GUI / Portal Feedback Loop

Click return is not success. After GUI/portal mutations, re-read dialog/page/AX/API state before claiming done. Detector: `scripts/hooks/core/gui_feedback.rb`.

## Customer Email

Default mailbox: SaneApps work email `hi@saneapps.com`.

Use `check-inbox.sh` / `check_inbox` (full flow: `DEVELOPMENT.md`, "Support
And Business Signals"). Run `review <id>` before reply/resolve; show the exact
draft and wait for explicit approval before sending.
- Existing app users should be told to update from inside the app. Do not send
  website/download links for update/fix/test replies unless the user needs a
  reinstall or direct-download recovery path.
- Choose the signature by recipient type. Customers and end-user support use:

```text
Mr. Sane
https://saneapps.com
```

Businesses, vendors, partners, API providers, and compliance/account-
verification teams use the real-name business signature with the relevant
product:

```text
Stephan Joseph
Founder, SaneApps / [Product]
727-758-9785
hi@saneapps.com
https://[relevant product site]
```

Never use the real-name signature for ordinary customer support, and never use
`Mr. Sane` for business/vendor/compliance correspondence.

Escalate refunds, complaints, legal issues, feature requests, attached problem
media, identity ambiguity, and promises about unfixed bugs.

## Release Rules

- Bump version before release. Sparkle ignores same-version updates.
- Run release preflight before release. Run App Store preflight only for enabled
  App Store lanes.
- Use public release-note terminology `Basic` and `Pro`; never public
  "free mode" wording.
- Note comparison, lane setup, wrapper commands: `templates/RELEASE_SOP.md`.

## SaneUI Gate

For settings/About/license/update/button/typography work, inspect
`~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first;
no app-local settings clones.

Automated guard: `ruby scripts/SaneMaster.rb saneui_guard`.

## Secrets

No Keychain prompt floods.

- Fetch each secret once and reuse it.
- No `security` calls in loops, retries, background jobs, or parallel runs.
- `~/.config/nv/env` holds loader functions only, zero plaintext. Every secret
  lives in macOS Keychain service `sane-env` behind `_sane_export_secret NAME`
  lines that must precede the `unset -f` line.
- A locked login keychain (reboot before console unlock) means shells load
  empty secrets; that is an empty-secrets watch-item, not missing config.
- Validation defaults to no prompt mode. Credential-backed checks must say they
  were skipped unless explicit prompt/keychain flags are enabled.

## Support/GitHub Sync

Before closing or summarizing a customer-reported GitHub issue, cross-check the
work-email history for the same app/reporter/keywords. Summaries should
anonymize customer identity unless legal/compliance context requires it.

## Historical Failure Classes

Do not delete these guardrails without root-cause review and replay proof:

- API guessing and repeated failed attempts.
- Raw `xcodebuild`/`swift`/release/email routes.
- Stale/local app testing instead of Mini/canonical paths.
- Missing visual proof for customer-facing UI.
- Same-version releases.
- Public SaneApps mentions without developer disclosure.
- Session handoffs or memory missing completed work.
- Gray/low-opacity SaneApps UI text.
- Direct email sends without exact draft approval.
- Symlink/config deletion without `ls -la`.
- Third-party slug/domain/routing changes without dependency audit.

## MCPs

Keep MCP proof portable. Serena is code-navigation tooling only — its memories
were absorbed into AgentMemory (corrected 2026-07-15). Mini AgentMemory uses
`memory_recall`/`memory_smart_search` for shared recall and
`memory_save`/`memory_lesson_save` for durable writes. Graph extraction is
intentionally off, so `Knowledge graph not enabled` is not an outage; legacy
`mcp__memory__*`/`mcp__central-memory__*` are retired. Check MCPs with
`~/.codex/bin/check-mcps` and `ruby scripts/SaneMaster.rb mcp_watchdog doctor`.

## Environment

- Apps: `~/SaneApps/apps/`
- Infra: `~/SaneApps/infra/`
- SaneProcess: `~/SaneApps/infra/SaneProcess/`
- SaneUI: `~/SaneApps/infra/SaneUI/`
- Outputs: `~/SaneApps/infra/SaneProcess/outputs/`
- Screenshots: `~/Desktop/Screenshots/`
- Templates: `~/SaneApps/infra/SaneProcess/templates/`
