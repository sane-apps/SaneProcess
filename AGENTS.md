# SaneApps AGENTS

SaneProcess is the shared SaneApps operating harness. This file is the active
agent overlay, not the full runbook. Detailed implementation, release, Mini,
and operator setup notes live in `DEVELOPMENT.md`, `ARCHITECTURE.md`,
`DEVELOPER_SETUP.md`, `templates/RELEASE_SOP.md`, and `scripts/`.

Regular daily work is Grok, Grokbot, and Cursor. Grok uses native
`~/.grok/hooks` (git source `scripts/hooks/grok/hooks.json`). Cursor uses
`~/.cursor/hooks.json`. Keep Codex/Claude hook adapters working. Do not send
regular jobs to OpenAI or Anthropic unless the owner asks.

Speak plainly and briefly. Use singular voice for SaneApps communications:
`I`, `me`, `my`; never `we`, `us`, or `our`.

## What Belongs Here

Keep only instructions an agent must know before hooks or wrappers can help.
If a rule is already enforced by a hook, SaneMaster command, or test receipt,
prefer pointing to that mechanism instead of duplicating the whole policy here.

Hard enforcement lives in:

- `scripts/hooks/` for launch, build-route, release, email, GitHub, tracking,
  session-end, security, visual-proof, GUI-feedback-loop, and completion gates.
- `scripts/SaneMaster.rb` and `scripts/sanemaster/` for canonical workflows.
- `scripts/validation_report.rb`, `process_eval`, `sop_review`,
  `near_miss_review`, and tests for repeatable process health evidence.
- `SESSION_HANDOFF.md`, `.claude/research.md`, agent file memory, and
  Mini-owned AgentMemory for active context and durable learnings. Serena is
  code-navigation only; its memories were absorbed into AgentMemory.

## Session Start

For tiny read-only answers or one local command, read the relevant file/command
surface and answer. For code, audit, release, support, payment, App Store,
automation, UI/runtime, or multi-file work:

1. Read `SESSION_HANDOFF.md`.
2. Read relevant file memory and the active skill registry; query shared
   context with AgentMemory `memory_recall` or `memory_smart_search`.
3. Run `~/.grok/bin/check-mcps` or `ruby scripts/SaneMaster.rb tool_discovery --query "mcp health"` when MCP health affects the task.
4. Run `ruby scripts/validation_report.rb` for release/audit/process work.
   Add `--release-checklists` only when you need the deep all-app artifact
   checklist; the default report is the cheaper process/release verdict.
5. Use the Mac Mini for SaneApps inspection, build, test, screenshots, and
   runtime verification unless the Mini is unavailable or the user explicitly
   approves a local exception.

## Session End

When code, tooling, docs, policy, support, release, or UI/runtime behavior
changed:

1. Update project-scoped file memory and persist cross-project AgentMemory
   facts/lessons with `memory_save` or `memory_lesson_save`.
2. Update `SESSION_HANDOFF.md` with active state, proof, open issues, and next
   useful moves.
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
| 7 | No test? No rest | Every fix gets a meaningful test or explicit proof receipt — and no BLIND test: a test must fail for the real bug at RUNTIME (drive the app, assert the customer-observable end-state); structure/string-match guards (`source.contains`) are not behavioral coverage. |
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
Approved tools may consume local credentials internally, including when invoked from the Air over
SSH, but agents must never dump, print, copy, or export raw secret material. Real sends, releases, uploads, reboots, and customer/data mutations use their
canonical approval gates. Irreversible deletion of a home, repository,
history, production resource, credential, ownership, license, or money is a
manual user-only action and must be mechanically blocked even in bypass mode.

Working locally on the Mini means working directly in the local checkout. Do
not SSH to `mini` from the Mini; use `ssh mini` only from the Air/controller.
Run `hostname` before cross-machine diagnosis, sync claims, or acceptance work.

## Subagents

Subagents are authorized for SaneApps work when they materially improve
coverage. Before spawning, decide what the parent will do locally and what can
run in parallel.

Every subagent prompt must include:

```text
Read relevant repo hooks in scripts/hooks/ and active client config when present (`~/.codex/config.toml`, `~/.claude/settings.json`) BEFORE doing work.
If a hook blocks you, STOP immediately and report the block back to the parent agent. Do not retry or work around it.
NEVER build or launch apps locally on the MacBook Air. Use `ssh mini` for SaneApps builds, tests, screenshots, and runtime verification.
Abide by every hook exactly as a human session would.
```

Use GPT subagents for broad review, research, audits, planning, and bounded
implementation. Do not use NVIDIA agents, `nv` sweeps, or `nvidia_vision`
unless the user explicitly asks for that specific run.
Do not use Gemini/Google provider paths as standard SaneApps tooling; use
Apple Docs, macOS Automator, Grok, Codex, Claude, and SaneMaster routes instead.

## Cloudflare Workers AI / NVIDIA NIM

Before any Workers AI or NIM **inference** call, follow `docs/LLM_VENDOR_API_SOP.md`. Use `scripts/llm_api_research_gate.rb` then smoke. Hook: `scripts/hooks/sane_llm_api_guard.rb` (via `sane_bash_guards.rb`). This is separate from the NVIDIA-agent ban (`nv` sweeps / `nvidia_vision`) — NIM draft APIs are allowed only with the SOP/receipt path.

Reviewer routing is perspective-driven. Canonical route, thread sizing, and live
tool/version discovery: `DEVELOPMENT.md` under "Reviewer fan-out routing".

## Canonical Routes

Use SaneMaster for stateful workflows. Read-only diagnostics are fine, but
stateful build/test/release/launch/support/business workflows must go through
the wrapper.

| Need | Canonical Route |
|------|-----------------|
| Build/test | `ruby scripts/SaneMaster.rb verify` |
| Release clearance | `ruby scripts/SaneMaster.rb release_preflight` |
| Work email | `ruby scripts/SaneMaster.rb check_inbox` |
| Tool discovery | `ruby scripts/SaneMaster.rb tool_discovery --query "..."` |
| Mini screenshot | `scripts/mini/capture-mini-screenshot.sh desktop` |

Full command map: `DEVELOPMENT.md` under "SaneMaster Commands".

Runtime app tests must attach a live app log stream from before launch/relaunch through
the tested workflow and save the receipt path. GUI/runtime results without live logs are invalid.

If a canonical route fails, fix it or explain why it is insufficient; do not silently work around it.
Raw `ssh mini ... screencapture ...` is not a fallback; it is blocked by
`scripts/hooks/sane_ssh_guard.sh` and the Bash guard dispatcher. Use the
canonical Mini screenshot wrapper or fix that wrapper.

## Browser And App Control

Mini browser work is Brave-only (owner rule, 2026-07-14): never script Safari
for portal or web-proof work. Full control ladder: `DEVELOPMENT.md` under
"Reviewer fan-out routing" (browser and app-control ladder).

Mini Terminal-host rule: cleanup must never unminimize, raise, maximize, or
activate an automation Terminal window. Use title-scoped reclaim during an app
interaction sequence; reserve `--reclaim-all` for workflow boundaries. Pass
`--restore-bundle-id <bundle-id>` when the hidden Terminal command controls an
open app. If Terminal becomes visible or frontmost, stop the GUI sequence and
fix the runner before clicking again.

Screenshots remain final evidence, not the first control mechanism. Use
`scripts/mini/capture-mini-screenshot.sh` only when a receipt needs an image.
The same ladder applies in Claude when its browser/app-control plugin is
active; compare live tools (`claude mcp list` and the current tool surface)
with config before declaring a tool missing.

Brave on the Mac Mini is the canonical authenticated control plane for
Setapp, App Store Connect, Apollo, Lemon Squeezy, Cloudflare, Resend, and
similar admin portals. This applies to both Codex and Claude. API wrappers
remain preferred when healthy, but agents must inspect the live Brave session
before declaring an admin surface unavailable. Safari is not a Setapp
dependency. A missing portal token blocks only the unattended API lane, not
browser access. Managed shell `osascript` may report that Brave cannot be
found even while the direct browser/Mac automation surface is working; treat
that as a shell Automation/TCC boundary and inspect Brave through the active
agent control surface.

## Tool Discovery

Before declaring a tool missing or inventing a repeated workaround:

1. Check the active client skill registry.
2. Run `ruby scripts/SaneMaster.rb tool_discovery --query "..."`.
3. Search existing scripts, hooks, skills, and core docs.
4. If still missing and repeatable, add the capability to SaneProcess and make
   it the standard path.

## Mini-First Rule

The Mac Mini is the canonical SaneApps build/test/runtime host.

- Use `ssh mini` and SaneMaster/sane_test wrappers for app work.
- Local fallback is allowed only when the Mini is unavailable or explicitly
  approved for that exact task.
- Do not leave test apps, stale shells, or helper windows running on the Mini.
- Mini admin/tunnel/build-server details live in `DEVELOPMENT.md` and
  `scripts/mini/`.

## Visual/UI Proof

Green tests are not enough for customer-facing UI claims. Capture clean saved
Mini screenshots for every customer-facing view/state touched, inspect them,
and record paths plus verdicts. Full freshness, claim-mapping, and validity
rules: `DEVELOPMENT.md` under "Runtime And Visual Evidence".

## GUI / Portal Feedback Loop

Click return is not success. After Brave/ASC/osascript/System Events mutations,
re-read dialog/page/AX/API state before claiming done. Shared detector:
`scripts/hooks/core/gui_feedback.rb` (Claude sanetrack/sanestop; Cursor
`~/.cursor/hooks` afterShellExecution + stop follow-up).

## Customer Email

Default mailbox: SaneApps work email `hi@saneapps.com`.

- Use `check-inbox.sh` / `SaneMaster.rb check_inbox`. Full inbox, media-review,
  and approval flow: `DEVELOPMENT.md` under "Support And Business Signals".
- Run `review <id>` before reply or resolve.
- Show the exact draft and wait for explicit approval before sending.
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
- Everything else (note comparison, lane setup, wrapper commands) lives in
  `templates/RELEASE_SOP.md` and `DEVELOPMENT.md`.

## SaneUI Gate

For settings, About, license, update, button-style, or typography work, inspect
`~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
Shared settings chrome belongs in SaneUI, not app-local clones.

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
