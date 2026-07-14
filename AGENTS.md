# SaneApps AGENTS

SaneProcess is the shared SaneApps operating harness. This file is the active
agent overlay, not the full runbook. Detailed implementation, release, Mini,
and operator setup notes live in `DEVELOPMENT.md`, `ARCHITECTURE.md`,
`DEVELOPER_SETUP.md`, `templates/RELEASE_SOP.md`, and `scripts/`.

Speak plainly and briefly. Use singular voice for SaneApps communications:
`I`, `me`, `my`; never `we`, `us`, or `our`.

## What Belongs Here

Keep only instructions an agent must know before hooks or wrappers can help.
If a rule is already enforced by a hook, SaneMaster command, or test receipt,
prefer pointing to that mechanism instead of duplicating the whole policy here.

Hard enforcement lives in:

- `scripts/hooks/` for launch, build-route, release, email, GitHub, tracking,
  session-end, security, visual-proof, and completion gates.
- `scripts/SaneMaster.rb` and `scripts/sanemaster/` for canonical workflows.
- `scripts/validation_report.rb`, `process_eval`, `sop_review`,
  `near_miss_review`, and tests for repeatable process health evidence.
- `SESSION_HANDOFF.md`, `.claude/research.md`, Serena memory, and Mini-owned
  AgentMemory for active context and durable learnings.

## Session Start

Use right-sized startup.

For tiny read-only answers or one local command, read the relevant file/command
surface and answer. For code, audit, release, support, payment, App Store,
automation, UI/runtime, or multi-file work:

1. Read `SESSION_HANDOFF.md`.
2. Read relevant Serena memory and the active client skill registry.
3. Run `~/.codex/bin/check-mcps` when MCP health affects the task.
4. Run `ruby scripts/validation_report.rb` for release/audit/process work.
   Add `--release-checklists` only when you need the deep all-app artifact
   checklist; the default report is the cheaper process/release verdict.
5. Use the Mac Mini for SaneApps inspection, build, test, screenshots, and
   runtime verification unless the Mini is unavailable or the user explicitly
   approves a local exception.

## Session End

When code, tooling, docs, policy, support, release, or UI/runtime behavior
changed:

1. Update Serena memory and AgentMemory for changed facts.
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
| 8 | Bug found? Write it down | Update Serena + AgentMemory when bugs change status. |
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

## Authority And Safety

When two instructions disagree, use this order:

1. Live user instruction and current machine state.
2. `AGENTS.md` for policy and `scripts/mini/README.md` for the Mini contract.
3. `DEVELOPMENT.md` and `ARCHITECTURE.md` for commands and durable decisions.
4. The compact `SESSION_HANDOFF.md` for current, host-qualified state.
5. Dated research and memories only when they are not expired or superseded.

Normal read, edit, build, test, commit, feature-push, SSH, rsync, and browser
work must remain usable. Approved tools may consume local credentials internally,
including when invoked from the Air over SSH, but agents must never dump, print,
copy, or export raw secret material. Real
sends, releases, uploads, reboots, and customer/data mutations use their
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

Reviewer count is perspective-driven, not capped by the active client's native
interactive-thread limit. Use native subagents for stateful/interactive work
and read-only ephemeral `codex exec` fan-out for isolated perspectives; use
waves only as a fallback. See `DEVELOPMENT.md` under "Reviewer fan-out routing"
for the canonical route and required live tool/version discovery.

## Canonical Routes

Use SaneMaster for stateful workflows. Read-only diagnostics are fine, but
stateful build/test/release/launch/support/business workflows must go through
the wrapper.

| Need | Canonical Route |
|------|-----------------|
| Build/test | `ruby scripts/SaneMaster.rb verify` |
| App runtime test | `ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb AppName` or `ruby scripts/SaneMaster.rb test_mode` |
| Release clearance | `ruby scripts/SaneMaster.rb release_preflight` |
| App Store clearance | `ruby scripts/SaneMaster.rb appstore_preflight` only for enabled App Store lanes |
| Setapp status | `ruby scripts/SaneMaster.rb setapp_status`; `Needs Revision` means waiting on us |
| Setapp upload | `ruby scripts/SaneMaster.rb setapp_upload`; portal fallback must be followed by `setapp_status` / `In Review` proof |
| Full release | `bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project $(pwd) --full ...` |
| Website deploy | `release.sh --website-only` |
| Work email | `ruby scripts/SaneMaster.rb check_inbox` or `~/SaneApps/infra/scripts/check-inbox.sh` |
| Sales/download/funnel | `sales`, `downloads`, `events` |
| Tool discovery | `ruby scripts/SaneMaster.rb tool_discovery --query "..."` |
| Cleanup | `ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply --preserve-apps AppName` |
| Verification scope plan | `ruby scripts/SaneMaster.rb proof_plan --task "..."` |
| Process health | `process_eval`, `sop_review`, `near_miss_review`, `verify_failure_review` |
| Route cost review | `ruby scripts/SaneMaster.rb route_cost_review --json` |
| Mini screenshot | `scripts/mini/capture-mini-screenshot.sh desktop` or app mode wrapper |

Runtime app tests must attach a live app log stream from before launch/relaunch
through the tested workflow and save the log receipt path. A GUI/runtime result
without live logs is invalid because the agent cannot see what is happening.

If a canonical route fails, fix the route or explain why it is insufficient.
Do not silently work around it.
Raw `ssh mini ... screencapture ...` is not a fallback; it is blocked by
`scripts/hooks/sane_ssh_guard.sh` and the Bash guard dispatcher. Use the
canonical Mini screenshot wrapper or fix that wrapper.

## Browser And App Control

Before driving a portal, dashboard, or visible desktop app, check the live tool
surface. If Browser or Chrome control is active, use it through `node_repl` for
Brave/Chrome DOM work before raw AppleScript, screenshots, SSH capture, or
manual browsing.

Mini browser work is Brave-only (owner rule, 2026-07-14): Claude drives Brave on
the Mini through the Claude-in-Chrome extension; Codex drives Brave through its
Chrome-control lane. Do not script Safari (AppleScript `do JavaScript`, cookie
extraction, front-tab reads) for portal or web-proof work — Safari is routinely
not running and its automation breaks. Tools whose fallback is a Safari cookie
(e.g. `setapp_status` portal token) should be run through the Brave portal path
or a refreshed stored token instead. The App Store Connect Safari lane is the
single standing exception until the owner retires it.

For visible native app/window state, use Computer Use `get_app_state` before
falling back to screenshot-only inspection. Use `macos-automator` for
deterministic AppleScript/JXA and app-specific automation tips. Use Playwright
with the SaneApps Brave defaults for repeatable website QA.

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

Green tests are not enough for customer-facing UI claims.

- Capture clean saved Mini screenshots for every customer-facing view/state
  touched or claimed verified.
- Inspect screenshots for clipping, overlap, contrast, confusing copy,
  obstructed prompts, and dark-mode quality.
- Record screenshot paths and verdicts in `SESSION_HANDOFF.md` or an
  `outputs/visual-audit*/` receipt.
- For release/UI/runtime gates, use the runner that writes durable receipts.
  `process_eval --require-ui-proof` treats missing or local-only UI proof as a
  blocker.

## Customer Email

Default mailbox: SaneApps work email `hi@saneapps.com`.

- Use `check-inbox.sh` / `SaneMaster.rb check_inbox`; never manual email API
  curl.
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
- Compare release notes against support promises, GitHub replies, and research.
- Direct-download and App Store private setup details live in
  `DEVELOPER_SETUP.md` and `templates/RELEASE_SOP.md`.

## SaneUI Gate

For settings, About, license, update, button-style, or typography work, inspect
`~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
Shared settings chrome belongs in SaneUI, not app-local clones.

Automated guard: `ruby scripts/SaneMaster.rb saneui_guard`.

## Secrets

No Keychain prompt floods.

- Fetch each secret once and reuse it.
- No `security` calls in loops, retries, background jobs, or parallel runs.
- Hot-path keys live in `~/.config/nv/env`; Keychain is fallback.
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

Use active MCPs when useful, but keep proof portable through local scripts and
Mini receipts. Apple Docs covers Apple APIs, Context7 covers third-party docs,
macOS Automator covers repeatable GUI automation, Xcode covers IDE/device work,
Serena stores project notes, and AgentMemory provides shared recall. Check with
`~/.codex/bin/check-mcps` and `ruby scripts/SaneMaster.rb mcp_watchdog doctor`.

## Environment

- Apps: `~/SaneApps/apps/`
- Infra: `~/SaneApps/infra/`
- SaneProcess: `~/SaneApps/infra/SaneProcess/`
- SaneUI: `~/SaneApps/infra/SaneUI/`
- Outputs: `~/SaneApps/infra/SaneProcess/outputs/`
- Screenshots: `~/Desktop/Screenshots/`
- Templates: `~/SaneApps/infra/SaneProcess/templates/`
