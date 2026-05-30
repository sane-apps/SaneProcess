# SaneApps AGENTS

> SaneApps operator overlay. This file shows the full internal production
> workflow used by SaneApps. Public adopters can use it as a reference, but
> should start with `README.md`, `DEVELOPMENT.md`, and their own project
> `AGENTS.md` rather than copying SaneApps-specific hosts, accounts, or release
> assumptions verbatim.

Speak in plain English. Keep it short and direct. Use `I`/`me`/`my` — never `we`/`us`/`our`.

---

## Session Start

Skip full startup only when the task does not edit files, does not run
build/test/release/support/account workflows, and can be answered from one local
file or one local command. Otherwise run Session Start steps 1-5.

1. Read `SESSION_HANDOFF.md` if it exists — recent work, pending tasks, gotchas
2. Check Serena memories (`read_memory`) for project-specific learnings
3. Read the active client skill registry (Codex: `~/.codex/SKILLS_REGISTRY.md`, Claude: `~/.claude/SKILLS_REGISTRY.md`; Grok and others: their client skill/config surface plus `.agents/skills/` when installed)
4. Run `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`
5. Launch Xcode only for explicit local IDE work. For SaneApps app inspection,
   build, test, screenshots, and runtime verification, use the Mac Mini first.

## Session End

1. Save learnings via Serena `write_memory` and update the knowledge graph for any bug, process, policy, tooling, or release-status fact that changed this session
2. Update `SESSION_HANDOFF.md` — include: open GitHub issues (`gh issue list`), research.md topics, feature requests
3. Run `ruby scripts/SaneMaster.rb sop_review --json` when the session changed code, tools, policy, docs, support, release, or UI/runtime behavior
4. Append SOP rating to `outputs/sop_ratings.csv` with evidence and any cap reason; do not rate above the objective cap from `sop_review`

## Live Memory Rule

Do not wait until session end.

- When you find a new bug, issue cluster, regression, or root-cause change, update Serena memory and the knowledge graph immediately.
- When you fix, close, merge, or downgrade an issue, update the same memory/graph entries immediately.
- When you change hooks, tools, automation, skills, templates, or durable docs like `AGENTS.md`, `CLAUDE.md`, `README.md`, `DEVELOPMENT.md`, or `ARCHITECTURE.md`, update Serena memory and `SESSION_HANDOFF.md` immediately. Do not treat this as optional cleanup.
- When you add a new durable document, either fold it into the core docs + `AGENTS.md` standard or record why it exists and where future sessions should look for it.
- Keep bug memory live enough that it can be used directly for support replies, App Store submissions, website release notes, and future debugging without re-discovery.
- Before any release, audit release notes against recent support promises, recent GitHub replies, and `research.md`. If a customer-visible fix shipped, the notes should mention it.
- Every product website must have a public privacy policy URL before release. Missing privacy pages are release blockers for App Store products and should be treated as SOP violations for every product.

```
## Session Summary
### Done: [1-3 bullets]
### Docs: [Updated/Current/Needs attention]
### SOP: X/10
### Next: [Follow-up items]
```

---

## The 17 Golden Rules

| # | Rule | What It Means |
|---|------|---------------|
| 0 | NAME IT BEFORE YOU TAME IT | State which rule applies before acting |
| 1 | STAY IN LANE, NO PAIN | No edits outside project without asking. Explicit cleanup/admin approval applies only to the named path, host, and task |
| 2 | VERIFY, THEN TRY | Check uncertain APIs/tools before using. Write durable findings to the project research cache with TTL |
| 3 | TWO STRIKES? STOP AND CHECK | Failed twice → STOP, read the error, research |
| 4 | GREEN MEANS GO | Tests must pass before "done" |
| 5 | HOUSE RULES, USE TOOLS | Use canonical wrappers for stateful build/test/release/launch/email workflows |
| 6 | BUILD, KILL, LAUNCH, LOG | Full build/kill/launch/log cycle after runtime code changes; docs/tooling changes get matching tests/evals |
| 7 | NO TEST? NO REST | Every fix gets a test. No tautologies (`#expect(true)` is useless) |
| 8 | BUG FOUND? WRITE IT DOWN | Update Serena memory + knowledge graph when bugs are found, reclassified, fixed, or closed |
| 9 | NEW FILE? GEN THE PILE | Use scaffolding tools and templates |
| 10 | FIVE HUNDRED'S FINE, EIGHT'S THE LINE | Max 500 lines per file and per component owner, must split at 800. Extensions count toward the same owner; do not hide a god class by growing it sideways |
| 11 | TOOL BROKE? FIX THE YOKE | Fix broken tools, don't work around them |
| 12 | TALK WHILE I WALK | Subagents for heavy work, stay responsive, and close completed/stale agents promptly |
| 13 | CONTEXT OR CHAOS | Maintain AGENTS.md, plus CLAUDE.md only when Claude-specific overlay guidance is needed |
| 14 | PROMPT LIKE A PRO | Specific prompts with file paths, constraints, context |
| 15 | REVIEW BEFORE YOU SHIP | Self-review for security, edge cases, correctness |
| 16 | DON'T FRAGMENT, INTEGRATE | Upgrade existing files. Core standard is README, DEVELOPMENT, ARCHITECTURE, SESSION_HANDOFF, and AGENTS; add CLAUDE only when needed. No orphan files. New tooling/docs must be recorded in memory + handoff |

**Workflow:** PLAN → VERIFY → BUILD → TEST → CONFIRM → PROPOSE COMMIT

Do not commit or push unless the user asks, the task explicitly includes release/PR/publish, or a project workflow requires it. For completed implementation work, propose the verified diff for commit when intent is unclear. Keep unrelated dirty files out of any commit.

**Circuit Breaker:** After 3 consecutive failures: STOP. Read error messages. Research the actual API.

**Research gate:** Local inspection is always required before editing. If the
active client/runtime enforces stricter research gates, obey the stricter gate.
Otherwise use docs, web, and GitHub when APIs are uncertain, external facts may
have changed, third-party behavior matters, or the decision is durable/high-stakes.
Do not run broad research just because the task contains discussion words.

**Subagent hygiene:** Before spawning subagents (or using equivalent delegation features in your client), close stale/completed agents that are no longer needed. After a subagent returns, capture the useful result and close it unless it is actively needed for a follow-up. If spawning fails because the agent limit is reached, cleanup is the required first step.

**Subagent prompt contract:** Every subagent prompt (regardless of client) must include:
1. Read relevant repo hooks in `scripts/hooks/` and active client config when present before doing work.
2. If a hook blocks, stop immediately and report the block to the parent; do not retry or work around it.
3. Never build or launch SaneApps locally on the MacBook Air. Use `ssh mini` for build/test/runtime work unless the parent documents an approved local exception for that exact task.
4. Follow the same wrapper, approval, and evidence rules as the parent session.

## Tool Discovery Before Workarounds

Before I say a tool is missing, choose a new canonical tool path, install/upgrade tooling, or switch to a repeated workaround, I must:
1. Check the active client skill registry (Codex: `~/.codex/SKILLS_REGISTRY.md`, Claude: `~/.claude/SKILLS_REGISTRY.md`, Grok and others: client-specific skill/config paths + `.agents/skills/` when present)
2. Run `ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb tool_discovery --query "..."` so the receipt captures registry, doctor, validation, and local-path checks
3. Search `scripts/`, hooks, skills, and the core docs + `AGENTS.md` standard for an existing path
4. If the capability is still missing and the workflow repeats, add it to SaneProcess, document it, and make it the standard path
5. Prefer the canonical tool paths in `DEVELOPMENT.md` instead of ad hoc tool hunting

Mentioning "workaround", "fragmentation", or "what am I missing" inside a policy
or design audit does not trigger tool discovery by itself.

If I cannot name which of those checks I ran, I have not checked enough.

## Mandatory Skill Workflows

If the user explicitly names a skill or directly matches a trigger phrase in the
active registry, that skill workflow is mandatory. If multiple skills match, use
the most specific match; if specificity is tied, state the chosen priority before
proceeding.

- Do not freehand the job.
- Do not replace it with a nearby manual bash chain.
- Invoke the skill first, then run the canonical runner or proof command for that skill when one exists.
- If the workflow is runner-backed, the session is not complete until that runner is actually used.

Canonical runner-backed paths in this repo:
- `status` → `ruby scripts/SaneMaster.rb status`
- `evolve` → `ruby scripts/SaneMaster.rb tool_discovery --query "..."`
- `verify` → `ruby scripts/SaneMaster.rb verify`
- `ship` → `ruby scripts/SaneMaster.rb release_preflight`
- `check-inbox` → `ruby scripts/SaneMaster.rb check_inbox`

## Visual Verification Gate

Green tests are not enough for customer-facing UI claims.

- For UI/runtime/customer-facing verification, capture one clean saved Mini screenshot per app-owned view or state touched, changed, or claimed verified.
- Inspect every saved screenshot for balance, clarity, confusing copy, clipping, overlap, contrast, dark-mode quality, and obvious functional state.
- Obstructed, clipped, partial, or helper-window-contaminated screenshots are invalid evidence.
- If a UI/runtime flow is stuck, loading, contradictory, or surprising, assume a hidden macOS prompt/sheet may be blocking it. Capture/check the full desktop and AX tree for permission, SecurityAgent, TCC, file-access, or system dialogs before retrying, changing code, or judging the app.
- App-window-only screenshots are not enough blocker evidence because prompts can appear outside the crop or behind the target window. Click the actual prompt action required by the customer flow, then re-capture the app’s final state.
- Record the screenshot paths and verdict in `SESSION_HANDOFF.md` or an `outputs/visual-audit*/` receipt before saying the surface works.
- Current hook coverage: `saneprompt` marks visual verification requirements,
  `sanetrack` records UI edits and screenshot/audit evidence, and `sanestop`
  plus `task_completed_gate` block completion when required proof is missing.

## SaneUI Source Of Truth

- For any SaneApps settings, About, license, updater, button-style, or typography work, inspect `~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
- Shared settings chrome belongs in `~/SaneApps/infra/SaneUI/`, not in app-local clones.
- App repos should compose shared `SaneSettingsContainer`, `SaneAboutView`, `LicenseSettingsView`, and `SaneSparkleRow` instead of redefining them.
- In shared settings surfaces, all text must be bright white and at least 13pt.
- Do not ship `.secondary`/gray helper text, `mailto:` bug-report paths, `Manage Access` copy, app-local updater rows, local `SaneSparkleRow` definitions, or `.buttonStyle(.bordered)` in settings/About/license/update UI.
- Current automated coverage: `ruby scripts/SaneMaster.rb saneui_guard` catches app-local settings chrome drift, local `SaneSparkleRow`, `mailto:` support links, `Manage Access` copy, and `.buttonStyle(.bordered)`. Typography, opacity-based gray text, and broader visual drift still require human review until the guard checks them directly.

---

## SaneApps Operator Overlay

The following sections describe the private SaneApps operator environment. They
are useful as an example of how SaneProcess is used in production, but public
adopters do not need the Mac Mini, SaneApps accounts, or SaneApps release keys.

## SaneMaster Routing

### Canonical Action Paths

Do not improvise alternate shell paths for repeated SaneApps actions. If a
canonical route exists, use it and fix that route when it fails.

- Status/support overview: `ruby scripts/SaneMaster.rb status`
- Build/test verification: `ruby scripts/SaneMaster.rb verify`
- Release clearance: `ruby scripts/SaneMaster.rb release_preflight`
- Runtime launch/testing: `ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb AppName` or `ruby scripts/SaneMaster.rb test_mode`
- Work email/support: `ruby scripts/SaneMaster.rb check_inbox` or `~/SaneApps/infra/scripts/check-inbox.sh`
- Sales/downloads/funnel: `ruby scripts/SaneMaster.rb sales`, `downloads`, or `events`
- Mini screenshots: `~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh desktop` for full-screen proof, or the same wrapper with `--app AppName --mode temp` for app/window proof
- Mini cleanup: `ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb machine_cleanup --host mini --apply --preserve-apps AppName`
- Missing/repeated tool path: `ruby scripts/SaneMaster.rb tool_discovery --query "..."`

For Mini screenshots, never use raw `ssh mini 'screencapture ...'`. It can run
outside the logged-in GUI session and falsely report that the Mini screen is
unavailable. The screenshot wrapper runs through `mini-gui-run.sh` and applies
the visual workspace guard for app-targeted captures. Full-screen Mini captures
must use `capture-mini-screenshot.sh desktop`, which runs the desktop hygiene
path first: close helper windows, block visible permission/security prompts,
and remove temporary email review media from the Mini Desktop/Screenshots area.
If this path fails, fix the wrapper or Mini host resolution. Do not invent an
alternate screenshot path.

### Mac Mini Admin Automation

- The Mini admin password is stored on the Mini only in `~/.config/nv/env` as `SANE_MINI_ADMIN_PASSWORD` and `MINI_ADMIN_PASSWORD`.
- Do not ask the user for the Mini password during normal SaneApps testing. Source that env file and use the stored variable for required Mini admin actions.
- Do not assume the Mini password applies to the local Mac. If local sudo is needed, the user types it into the terminal prompt; do not ask them to paste it into chat.
- Never print the value. For sudo, use `printf "%s\n" "$SANE_MINI_ADMIN_PASSWORD" | sudo -S ...`.
- Do not pass the password through AppleScript error-prone text that can echo secrets into logs. Prefer shell/sudo paths or UI typing with suppressed stderr when a macOS admin sheet is unavoidable.

Use `./scripts/SaneMaster.rb` for stateful SaneApps workflows: build/test,
release/deploy, app launch, support/email, sales/download/conversion analytics,
lead research, process metrics, cleanup, and release readiness. Read-only shell
diagnostics are fine. If you bypass a wrapper, state why. Run
`./scripts/SaneMaster.rb help <category>` for command details.

Critical routes:
- Build/test → `SaneMaster.rb verify`
- App launch/runtime → `sane_test.rb` or `SaneMaster.rb test_mode`
- Release → `SaneMaster.rb release_preflight`, then `release.sh`
- App Store lane → `SaneMaster.rb appstore_preflight` only when enabled
- Sales/downloads/funnel → `sales`, `downloads`, `events`
- Email/support → `check-inbox.sh` / `SaneMaster.rb check_inbox`
- Tool/process misses → `tool_discovery`, `near_miss_review`, `verify_failure_review`
- Cleanup → `machine_cleanup` before manual process/disk cleanup

### Support Issue Synchronization

- Before closing, resolving, or summarizing a customer-reported GitHub issue, cross-check the work-email history for the same app, reporter identity, and issue keywords with `check-inbox.sh` (`whois`, `context`, `read`, and `check-reply` as needed).
- If email confirms the issue is fixed, report it as "email confirmation received; issue resolved" and close/update GitHub accordingly. If email says it is still broken, keep or reopen the GitHub issue.
- Never describe a GitHub issue as "no follow-up" until the related email trail has also been checked.
- In user-facing summaries, anonymize email senders. Do not include names, personal email addresses, or other identifying details from customer email unless the user explicitly asks or a legal/compliance context requires identity.

## Trigger Map

When the user says something matching these, run the command/skill immediately:

| User Says | Action |
|-----------|--------|
| "how are sales", "revenue" | `SaneMaster.rb sales` + `events` |
| "download stats", "how many downloads" | `SaneMaster.rb downloads` |
| "conversions", "upgrades", "new users", "funnel", "source of sales" | `SaneMaster.rb events` |
| "leads", "prospects", "research sites", "research companies" | `SaneMaster.rb leads --query "..."` |
| "check email", "inbox" | `SaneMaster.rb check_inbox` |
| "missing tool", "install/upgrade tool", "better tool for this workflow" | `/evolve` |
| "project status", "health check", "run status", "check status", "what's the status" | `SaneMaster.rb status` |
| "verify", "does it build" | `SaneMaster.rb verify` |
| "ship it", "prepare for release" | `SaneMaster.rb release_preflight` first, then `release.sh` |
| "tech debt", "find dead code" | `SaneMaster.rb dead_code` |

---

## Release Protocol

```bash
# 1. Bump version FIRST (Sparkle ignores same-version updates)
# Edit MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml

# 2. Preflight checks
./scripts/SaneMaster.rb release_preflight    # 9 safety checks (direct download)
# Run App Store submission compliance only when `.saneprocess` has `appstore.enabled: true`
./scripts/SaneMaster.rb appstore_preflight   # active App Store lanes only

# 3. Full release
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project $(pwd) --full --version X.Y.Z --notes "..." --deploy
```

**Critical rules:**
- **Bump version BEFORE release** — Sparkle ignores same-version updates
- **Direct-only apps do not run App Store lanes** — SaneBar and SaneClick are direct-download-only unless `.saneprocess appstore.enabled` is deliberately re-enabled after explicit approval and fresh policy review.
- App Store release machines must pass `scripts/mini/bootstrap-build-server.sh`; release proof must include headless keychain, partition-list, and ASC auth.
- Sparkle/R2/App Store private setup details live in `DEVELOPER_SETUP.md`.
- **Morning releases preferred** — full day to monitor
- Full details: `SaneProcess/templates/RELEASE_SOP.md`

---

## Website Deployment

**All SaneApps websites are on Cloudflare Pages.** NEVER use GitHub Pages.

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project $(pwd) --website-only
# Naming: {app}-site (e.g., sanebar-site)
# Deploys from: website/ directory (preferred) or docs/ (fallback)
```

---

## Runtime Testing

**ALWAYS test on the Mac Mini, not the MacBook Air.** Local fallback is allowed
only when `ssh mini` fails, the Mini route is otherwise unavailable for that task,
or the user explicitly approves a local exception for that exact task.
`Inconvenient`, `slower`, or `already open locally` are not fallback reasons.
When using a local exception, say why Mini was unavailable or approved first.

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb SaneBar          # Auto-detects mini
ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb SaneClip --local # ONLY if mini is down
```

Script handles: kill → clean → TCC reset → build → deploy → launch → logs.

---

## Customer Email

**Email:** hi@saneapps.com | **Sign-off:** `Mr. Sane` + `https://saneapps.com` (NEVER mention AI/Claude/Codex)
**Voice:** Singular only (`I`, `me`, `my`). Never `we`/`us`/`our`.
**Banned word:** NEVER say "grab" — use "download", "get", or "update to the latest".

**Style:** Direct, warm, human. No corporate hedge language. Action-oriented ("here's what I'm going to do"). Light humor welcome. Short, no fluff. Humility — use "should" not "will" for fixes.

**Rules:**
- Use `~/SaneApps/infra/scripts/check-inbox.sh` or `SaneMaster.rb check_inbox`; never manual email API curl.
- ALWAYS run `review <id>` before any `reply` or `resolve`
- ALWAYS show the user the exact email draft and get approval before sending
- Email send workflow is mandatory: `present-draft` or `present-batch` after showing the draft, then wait for explicit user approval, then `approve ... --user-approval "<quote>"`, then send in a separate command
- If customer attaches media describing a problem: save to `~/Desktop/Screenshots/`, alert user, wait for approval
- Auto-handle after review only: simple download/install/basic-support questions
  with no refund, complaint, legal issue, feature request, attached problem media,
  customer identity uncertainty, or promise about an unfixed bug. Every outbound
  reply still requires the exact draft approval flow.
- Refund/complaint policy: if the customer is unhappy or asks for a refund, apologize briefly, ask what is broken, and ask for an in-app bug report first. Refunds require explicit user approval plus a documented bug we cannot fix within 24 hours.
- Escalate: refunds, complaints, feature requests, legal, media showing a problem

---

## Keychain Secrets

**NO KEYCHAIN PROMPT FLOODS. Sequential is fine. Parallel is not.**

- Fetch each secret once, reuse it, and never call `security` in loops, retries, background jobs, sweeps, or parallel tool calls.
- Keep hot-path keys in `~/.config/nv/env` (`chmod 600`); use Keychain as fallback.
- Codex shells are guarded by `~/.local/bin/security -> sane_security_guard.sh`.
- Mac Mini keys live in `~/.config/nv/env` because Keychain prompts do not work over SSH.
- Apple release identity: use the private SaneApps operator credential set and
  keychain profile `notarytool`.
- Full private setup and notarization commands live in `DEVELOPER_SETUP.md`.

---

## Mac Mini Build Server

M1 Mac mini (8GB). Access: `ssh mini`.

**Source of truth:** `SaneProcess/scripts/mini/` — edit there, deploy via `bash scripts/mini/deploy.sh`

**Bash 3.2 warning:** Mini runs macOS default bash. No `+=()` array append, no `<<<` herestrings.

```bash
ssh mini 'tail -20 ~/SaneApps/outputs/nightly_report.md'
```

---

## This Has Burned You Before

| Mistake | The Rule Now |
|---------|-------------|
| **Guessed an API existed** | VERIFY FIRST. Check docs/types before writing code. |
| **Kept trying after failures** | TWO STRIKES = STOP. Read the error. Research. |
| **Skipped tests** | Tests MUST be green before "done." |
| **Used raw xcodebuild** | Use SaneMaster.rb verify / release.sh / sane_test.rb. |
| **Used `rm -rf`** | ALWAYS use `trash` command. Recoverable beats permanent. |
| **Released with same version** | ALWAYS bump version before release. Sparkle ignores same-version. |
| **Posted about SaneApps without disclosure** | ALWAYS identify as the developer: "I built [App]." |
| **Tested on MacBook Air** | ALWAYS use Mac Mini (`ssh mini`). Only `--local` if mini is down. |
| **Left the mini cluttered after testing** | Close dead Terminal windows / remote shells and kill test-only app instances when the run is done. |
| **Needed GUI-session signing on the mini** | Use `scripts/mini/mini-gui-run.sh` instead of one-off `/tmp` AppleScripts, and let it auto-close its Terminal window. |
| **Used gray text in UI** | ALL text MUST be bright white. `.white` primary, `.white.opacity(0.9)` min for secondary. NEVER `.secondary` or gray. |
| **Sent email without showing draft** | ALWAYS show exact draft to user and get "send" approval first. |
| **Inverted what I just read** | STATE IT BACK: "The doc says X, therefore I will Y." |
| **Trashed a symlink target** | Run `ls -la` before deleting any config file. |
| **Slug change without dep audit** | When user says "I changed X" → "What depends on X?" Full audit. |
| **SESSION_HANDOFF missed work** | Before handoff: run `gh issue list`, check research.md, check feature requests. |

---

## MCP Tools

| Server | Use For | Key Tip |
|--------|---------|---------|
| **apple-docs** | Apple APIs, WWDC | `compact: true` on list/sample tools |
| **context7** | Library docs | `resolve-library-id` FIRST, then `query-docs` |
| **macos-automator** | macOS scripting, real UI testing | `get_scripting_tips search_term: "keyword"` |
| **xcode** | Build, test, preview, diagnostics | `XcodeListWindows` → get `tabIdentifier` first |
| **central-memory** | Shared semantic memory (Postgres + pgvector) | Use `remember` / `recall`; verify with `~/.codex/bin/check-mcps` |
| **Serena** | Past bugs, patterns, project knowledge | `read_memory`/`write_memory` |

Optional MCP accelerators must stay optional. Local scripts, repo docs, and
Mini-first SaneMaster receipts are the portable SaneProcess path; do not make
release correctness depend on an optional MCP unless repo config explicitly
requires it. Use Cloudflare API MCP/plugin for read-only Pages/R2/Worker drift
checks when it is installed, XcodeBuildMCP for iOS simulator proof/debug when it
is available, and central-memory for semantic recall when configured. Do not make
Google Drive/Docs/Sheets/Slides a standard release-evidence dependency.

XcodeBuildMCP decision rule:
- Use Apple `xcrun mcpbridge`/`xcode` first for IDE-native Xcode tools such as
  project context, previews, issue navigator, and documentation search.
- In Codex, the Build iOS Apps plugin provides XcodeBuildMCP via
  `npx -y xcodebuildmcp@latest mcp`; treat stale local forks as reference code
  unless MCP config explicitly points at them.
- Use XcodeBuildMCP when the task needs iOS simulator build-run proof,
  screenshots/video, taps/swipes/typing, accessibility hierarchy inspection,
  LLDB debugging, physical-device install/launch, code coverage, or persistent
  session defaults.
- Do not use XcodeBuildMCP for plain SaneApps release gates or macOS app
  verification unless the requested evidence specifically needs its extra
  automation. Release proof still ends in SaneMaster/Mini receipts.

### Central Memory MCP (Codex)

- Server: optional `central-memory` in local Codex MCP config
- Runtime: PostgreSQL 17 + `pgvector` on `postgresql://<local-user>@localhost:5432/central_memory`
- Bootstrap: `cd ~/SaneApps/infra/SaneProcess/scripts/mcp-central-memory && ./bootstrap-local.sh`
- Health: `~/.codex/bin/check-mcps` (must show `central-memory` PASS)
- Background-machine health: `ruby scripts/SaneMaster.rb mcp_watchdog doctor`
- Control-plane helper source: `scripts/codex-bin/`
- Installed binaries: `~/.codex/bin/check-mcps`, `~/.codex/bin/github-mcp-bridge.mjs`, and `~/.codex/bin/xcode-mcpbridge-wrapper.sh`
- Sync/install path: `ruby scripts/SaneMaster.rb sync_mini` installs the repo-owned helpers locally and mirrors them to Mini
- Tools: `remember`, `recall`, `recent`, `stats`, `delete_by_external_id`, `import_knowledge_graph`

---

## Codex-Specific Notes

- Codex has no native PreToolUse hook API — critical gates are enforced in shared scripts
- Email writes are guarded via `~/.local/bin/curl` → `sane_curl_guard.sh` plus `check-inbox.sh` approval checks
- Local MacBook Air GUI opens for SaneApps release/dashboard work are guarded via `~/.local/bin/open` → `sane_open_guard.sh`. Use Mini Safari/Finder instead for Lemon Squeezy, App Store Connect, release upload files, and SaneApps app launches.
- Don't invent new docs — use the core docs + `AGENTS.md` standard
- Use `trash` not `rm -rf`
- Cleanup SOP: use `ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply --preserve-apps App1,App2` for Mini cleanup and `--local` for the MacBook Air. The command is dry-run by default.
- Before any manual cleanup, list active `Sane*`, `xcodebuild`, simulator, training, and MCP processes with parent/PGID context.
- Preserve any app the user says is active, even if it looks noisy. Do safe disk cleanup first: full Trash, disposable caches, inactive DerivedData, and unavailable simulator data.
- Never kill broad process classes; kill only a confirmed unrelated parent process group, and only after tracing respawns back to their launcher.

---

## Cowork / Claude Desktop Notes

Cowork is the Claude desktop app, not Claude Code. It runs the same Golden Rules, but the runtime is different. These notes are additive; nothing here changes Codex, Grok, or Claude Code behavior.

- **Native hooks do not fire.** Every hook in `.claude/settings.json` is gated on `${CLAUDECODE}${CLAUDE_CODE}`, which Cowork does not set, so `session_start.rb`, `saneprompt.rb`, `sanetools.rb`, `sanetrack.rb`, and `sanestop.rb` are all silent. There is no PreToolUse guardrail, no completion gate, and no auto session briefing. Treat every Golden Rule as self-enforced and assume no guardrail ran unless I ran it myself.
- **Run the gates by hand.** Session start: read `SESSION_HANDOFF.md`, then `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`. Before "done": `ruby scripts/SaneMaster.rb verify`. Before release: `release_preflight`. Session end: `sop_review` plus the handoff/memory updates. Nothing prompts me to do these.
- **MCPs are not pre-wired.** Cowork has no native apple-docs/context7/github/Serena servers. Use the connector registry for equivalents, the sandbox shell to run `SaneMaster.rb` and repo scripts, and `WebSearch`/`web_fetch` for API verification. Write durable learnings to `SESSION_HANDOFF.md` (and Serena via shell when available) rather than relying on auto-memory.
- **Mini-first still applies.** `ssh mini` and the `SaneMaster.rb` / `sane_test.rb` wrappers work from the Cowork shell. Use them; do not build or launch on the Air.
- **Canonical routes still apply.** Use the SaneMaster wrappers through the shell instead of improvising raw `xcodebuild`/`security`/email paths. `trash`, not `rm -rf`.
- **Keychain guard interaction.** Cowork shells may inherit the `~/.local/bin/security` shim. The guard only throttles repeated *reads* (`find-generic-password`); sequential distinct lookups pass through. Do not loop `security`. (Note: the guard activates on `$CLAUDE_CODE`; if a client sets that variable, the guard can also intercept the client's own Keychain auth reads — see Login Loop note in `CLAUDE.md`.)

---

## Environment

- **OS**: macOS (Apple Silicon)
- **Apps**: `~/SaneApps/apps/` (SaneBar, SaneClick, SaneClip, SaneHosts, SaneSales, SaneSync, SaneVideo)
- **Infra**: `~/SaneApps/infra/` (SaneProcess, SaneUI)
- **Screenshots**: `~/Desktop/Screenshots/`
- **Outputs**: `~/SaneApps/infra/SaneProcess/outputs/`
- **Templates**: `~/SaneApps/infra/SaneProcess/templates/`
- **Shared UI**: `~/SaneApps/infra/SaneUI/`
- **Global skills**: Codex `~/.codex/skills/`, Claude `~/.claude/skills/`

## References (for deep dives)

- Global rules + full gotchas table: `~/.claude/CLAUDE.md`
- Infra rules + hook details: `~/SaneApps/infra/SaneProcess/CLAUDE.md`
- Per-app architecture: each app's `ARCHITECTURE.md`
- Release SOP: `SaneProcess/templates/RELEASE_SOP.md`
- Shared infra scripts: `SaneProcess/scripts/`
- Mini scripts: `SaneProcess/scripts/mini/`
