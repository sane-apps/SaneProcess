# SaneApps AGENTS

Speak in plain English. Keep it short and direct. Use `I`/`me`/`my` — never `we`/`us`/`our`.

---

## Session Start

Use a right-sized startup.

Small read-only answers and single local command requests need only the nearest
`AGENTS.md` plus the directly relevant file or command surface. Full startup is
required for mutation, build/test, release, support, UI/runtime, payment, App Store,
automation, policy, or multi-file investigation work.

1. Read `SESSION_HANDOFF.md` if it exists — recent work, pending tasks, gotchas
2. Check Serena memories (`read_memory`) for project-specific learnings
3. Read the active client skill registry — Codex: `~/.codex/SKILLS_REGISTRY.md`, Claude: `~/.claude/SKILLS_REGISTRY.md`
4. Run `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`
5. Launch Xcode only for explicit local IDE work. For SaneApps app inspection,
   build, test, screenshots, and runtime verification, use the Mac Mini first.

## Session End

1. Save learnings via Serena `write_memory`
2. Update `SESSION_HANDOFF.md` — include: open GitHub issues (`gh issue list`), research.md topics, feature requests
3. Append SOP rating to `outputs/sop_ratings.csv`

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
| 1 | STAY IN LANE, NO PAIN | No edits outside project without asking |
| 2 | VERIFY, THEN TRY | Check uncertain APIs/tools before using. Write durable findings to the project research cache with TTL |
| 3 | TWO STRIKES? STOP AND CHECK | Failed twice → STOP, read the error, research |
| 4 | GREEN MEANS GO | Tests must pass before "done" |
| 5 | HOUSE RULES, USE TOOLS | Use canonical wrappers for stateful build/test/release/launch/email workflows |
| 6 | BUILD, KILL, LAUNCH, LOG | Full cycle after every code change |
| 7 | NO TEST? NO REST | Every fix gets a test. No tautologies (`#expect(true)` is useless) |
| 8 | BUG FOUND? WRITE IT DOWN | Update Serena memory + knowledge graph when bugs are found, reclassified, fixed, or closed |
| 9 | NEW FILE? GEN THE PILE | Use scaffolding tools and templates |
| 10 | FIVE HUNDRED'S FINE, EIGHT'S THE LINE | Max 500 lines, must split at 800 |
| 11 | TOOL BROKE? FIX THE YOKE | Fix broken tools, don't work around them |
| 12 | TALK WHILE I WALK | Subagents for heavy work, stay responsive |
| 13 | CONTEXT OR CHAOS | Maintain AGENTS.md, plus CLAUDE.md only when Claude-specific overlay guidance is needed |
| 14 | PROMPT LIKE A PRO | Specific prompts with file paths, constraints, context |
| 15 | REVIEW BEFORE YOU SHIP | Self-review for security, edge cases, correctness |
| 16 | DON'T FRAGMENT, INTEGRATE | Upgrade existing files. Core standard is README, DEVELOPMENT, ARCHITECTURE, SESSION_HANDOFF, and AGENTS; add CLAUDE only when needed. No orphan files. New tooling/docs must be recorded in memory + handoff |

**Workflow:** PLAN → VERIFY → BUILD → TEST → CONFIRM → PROPOSE COMMIT

Do not commit or push unless the user asks, the task explicitly includes release/PR/publish, or a project workflow requires it. For completed implementation work, propose the verified diff for commit when intent is unclear. Keep unrelated dirty files out of any commit.

**Circuit Breaker:** After 3 consecutive failures: STOP. Read error messages. Research the actual API.

**Research gate:** Local inspection is always required before editing. Docs, web, and GitHub are conditional: use them when APIs are uncertain, external facts may have changed, third-party behavior matters, or the decision is durable/high-stakes. Do not run broad research just because the task contains discussion words.

## Tool Discovery Before Workarounds

Before I say a tool is missing, choose a new canonical tool path, install/upgrade tooling, or switch to a repeated workaround, I must:
1. Check the active client skill registry — Codex: `~/.codex/SKILLS_REGISTRY.md`, Claude: `~/.claude/SKILLS_REGISTRY.md`
2. Run `ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb tool_discovery --query "..."` so the receipt captures registry, doctor, validation, and local-path checks
3. Search `scripts/`, hooks, skills, and the core docs + `AGENTS.md` standard for an existing path
4. If the capability is still missing and the workflow repeats, add it to SaneProcess, document it, and make it the standard path
5. Prefer the canonical tool paths in `DEVELOPMENT.md` instead of ad hoc tool hunting

Mentioning "workaround", "fragmentation", or "what am I missing" inside a policy
or design audit does not trigger tool discovery by itself.

If I cannot name which of those checks I ran, I have not checked enough.

## Mandatory Skill Workflows

If the prompt matches a registered skill trigger, that skill workflow is mandatory.

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

## SaneUI Source Of Truth

- For any SaneApps settings, About, license, updater, button-style, or typography work, inspect `~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
- Shared settings chrome belongs in `~/SaneApps/infra/SaneUI/`, not in app-local clones.
- App repos should compose shared `SaneSettingsContainer`, `SaneAboutView`, `LicenseSettingsView`, and `SaneSparkleRow` instead of redefining them.
- In shared settings surfaces, all text must be bright white and at least 13pt.
- Do not ship `.secondary`/gray helper text, `mailto:` bug-report paths, `Manage Access` copy, local `SaneSparkleRow` definitions, or `.buttonStyle(.bordered)` in settings/About/license/update UI.

---

## SaneMaster Quick Reference

**`./scripts/SaneMaster.rb`** — unified automation CLI for ALL SaneApps projects. Use this for stateful build/test/release workflows.

Read-only shell commands and focused diagnostics are allowed. Prefer wrappers for
workflows that can bypass safety/tracking: app launch, release/deploy, build/test,
customer email, and sales/support analytics. If you bypass a wrapper, state why.

Run with no args for full help. Run `help <category>` for category details.

| Category | Key Commands | What It Does |
|----------|-------------|--------------|
| **build** | `verify`, `clean`, `lint`, `release`, `release_preflight`, `appstore_preflight` | Build, test, release pipeline, App Store compliance |
| **sales** | `sales`, `sales --products`, `sales --month`, `sales --daily`, `sales --fees` | LemonSqueezy revenue (today/yesterday/week/all-time) |
| **sales** | `downloads` (dl), `downloads --app NAME`, `downloads --days N`, `downloads --json` | Download analytics from sane-dist Worker (D1-backed) |
| **sales** | `events`, `events --days N`, `events --app NAME`, `events --json` | User-type events: new_free_user, early_adopter_grant, license_activated |
| **sales** | `leads --query "TEXT"`, `leads --domain DOMAIN`, `leads --json` | Prospect discovery with Exa + Firecrawl site dossiers |
| **check** | `verify_api`, `dead_code`, `deprecations`, `swift6`, `saneui_guard`, `test_scan`, `structural`, `compliance`, `check_docs`, `check_binary`, `menu_scan` | Static analysis, API verification, code quality |
| **debug** | `test_mode` (tm), `logs --follow`, `launch`, `crashes`, `diagnose` | Interactive debugging, crash analysis |
| **ci** | `enable_ci_tests`, `restore_ci_tests`, `fix_mocks`, `monitor_tests`, `image_info` | CI/CD test helpers |
| **gen** | `gen_test`, `gen_mock`, `gen_assets`, `template` | Code generation, mocks, assets |
| **memory** | `msync`, `session_end`, `reset_breaker` | Cross-session memory sync, circuit breaker |
| **breaker** | `breaker_status` (bs), `breaker_errors` (be), `reset_breaker` (rb) | Circuit breaker inspection and reset |
| **env** | `doctor`, `tool_discovery --query "..."`, `health`, `bootstrap`, `setup`, `versions`, `reset`, `restore` | Environment setup, health checks |
| **saneloop** | `saneloop` (sl), `saneloop start`, `saneloop status`, `saneloop check`, `saneloop complete` | Structured iteration loops for big tasks |
| **meta** | `meta`, `audit`, `system_check` | Tooling self-audit, system verification |
| **export** | `export`, `md_export`, `deps`, `quality` | PDF export, dependency graphs |

**When to use SaneMaster vs other tools:**
- Sales/revenue → `SaneMaster.rb sales` (NOT manual curl to LemonSqueezy)
- Download stats → `SaneMaster.rb downloads` (NOT manual curl to dist Worker)
- Conversion funnel → `SaneMaster.rb events` (new users, upgrades, activations)
- Lead research → `SaneMaster.rb leads --query "..."` (NOT ad-hoc vendor API curl chains)
- Build/test → `SaneMaster.rb verify` (NOT raw `xcodebuild`)
- App launch → `sane_test.rb` (NOT `open SaneBar.app`)
- Release → `release.sh` + `SaneMaster.rb release_preflight` (NOT manual DMG creation)
- CI test setup → `SaneMaster.rb enable_ci_tests` (NOT editing project.yml manually)

### Sales & Conversion Funnel

When user asks about sales, revenue, conversions, upgrades, new users, or funnel — run all three:

```bash
./scripts/SaneMaster.rb sales           # Revenue from LemonSqueezy
./scripts/SaneMaster.rb events          # Freemium funnel: new_free_user, early_adopter_grant, license_activated
./scripts/SaneMaster.rb downloads       # Download counts by source (website, sparkle, homebrew)
```

The `events` command shows:
- `new_free_user` — first launch, no license (brand new free-tier user)
- `early_adopter_grant` — existing user from before freemium, auto-granted Pro
- `license_activated` — someone entered a license key and it validated

Cross-reference events with sales to understand conversion rates.

### Lead Research

When I need new prospect lists or cleaner website reads, use:

```bash
./scripts/SaneMaster.rb leads --query "mac app review sites"
./scripts/SaneMaster.rb leads --query "developer newsletters for privacy tools" --site-limit 8
./scripts/SaneMaster.rb leads --domain setapp.com --domain macstories.net
```

Secrets:
- `EXA_API_KEY` env var or keychain service `exa` / account `api_key`
- `FIRECRAWL_API_KEY` env var or keychain service `firecrawl` / account `api_key`

Outputs:
- `outputs/leads/*.json`
- `outputs/leads/*.md`

---

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
./scripts/SaneMaster.rb appstore_preflight   # App Store submission compliance

# 3. Full release
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project $(pwd) --full --version X.Y.Z --notes "..." --deploy
```

If `.saneprocess` includes iOS App Store release:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/mini/bootstrap-build-server.sh
```

Do not treat the mini as ready unless the bootstrap passes. The release path must prove headless keychain unlock, partition-list access, and ASC auth before a dual-platform App Store release counts as complete.

**Critical rules:**
- **Bump version BEFORE release** — Sparkle ignores same-version updates
- **ONE Sparkle key** for all apps: `7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU=`
- **ONE shared R2 bucket** (`sanebar-downloads`) for ALL apps
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

## Test App Launch

**ALWAYS test on the Mac Mini, not the MacBook Air.** Only use `--local` if Mini is unreachable.

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb SaneBar          # Auto-detects mini
ruby ~/SaneApps/infra/SaneProcess/scripts/sane_test.rb SaneClip --local # ONLY if mini is down
```

Script handles: kill → clean → TCC reset → build → deploy → launch → logs.

| App | Dev Bundle ID | Prod Bundle ID |
|-----|--------------|----------------|
| SaneBar | `com.sanebar.dev` | `com.sanebar.app` |
| SaneClick | `com.saneclick.SaneClick` | `com.saneclick.SaneClick` |
| SaneClip | `com.saneclip.dev` | `com.saneclip.app` |
| SaneHosts | `com.mrsane.SaneHosts` | `com.mrsane.SaneHosts` |
| SaneSales | `com.sanesales.dev` | `com.sanesales.app` |
| SaneSync | `com.sanesync.SaneSync` | `com.sanesync.SaneSync` |
| SaneVideo | `com.sanevideo.app` | `com.sanevideo.app` |

---

## Customer Email

**Email:** hi@saneapps.com | **Sign-off:** `Mr. Sane` + `https://saneapps.com` (NEVER mention AI/Claude/Codex)
**Voice:** Singular only (`I`, `me`, `my`). Never `we`/`us`/`our`.
**Banned word:** NEVER say "grab" — use "download", "get", or "update to the latest".

**Style:** Direct, warm, human. No corporate hedge language. Action-oriented ("here's what I'm going to do"). Light humor welcome. Short, no fluff. Humility — use "should" not "will" for fixes.

**How to check/send email:**
```bash
~/SaneApps/infra/scripts/check-inbox.sh check              # Full inbox
~/SaneApps/infra/scripts/check-inbox.sh review <id>        # MANDATORY before reply/resolve
~/SaneApps/infra/scripts/check-inbox.sh read <id>          # Body + attachments + reply status
~/SaneApps/infra/scripts/check-inbox.sh reply <id> <file>  # Send reply
~/SaneApps/infra/scripts/check-inbox.sh resolve <id>       # Mark resolved
```

**Rules:**
- ALWAYS run `review <id>` before any `reply` or `resolve`
- ALWAYS show the user the exact email draft and get approval before sending
- Email send workflow is mandatory: `present-draft` or `present-batch` after showing the draft, then wait for explicit user approval, then `approve ... --user-approval "<quote>"`, then send in a separate command
- If customer attaches media describing a problem: save to `~/Desktop/Screenshots/`, alert user, wait for approval
- Auto-handle: simple questions, download/install issues, basic support
- Refund/complaint policy: if the customer is unhappy or asks for a refund, apologize briefly, ask what is broken, and ask for an in-app bug report first. Refunds require explicit user approval plus a documented bug we cannot fix within 24 hours.
- Escalate: refunds, complaints, feature requests, legal, media showing a problem
- NEVER craft manual curl commands for email — use check-inbox.sh

---

## Keychain Secrets

**NO KEYCHAIN PROMPT FLOODS. Sequential is fine. Parallel is not.**

- Fetch each secret once, reuse it, and never call `security` in loops, retries, background jobs, sweeps, or parallel tool calls.
- Keep hot-path keys in `~/.config/nv/env` (`chmod 600`); use Keychain as fallback.
- Codex shells are guarded by `~/.local/bin/security -> sane_security_guard.sh`.
- Mac Mini keys live in `~/.config/nv/env` because Keychain prompts do not work over SSH.
- Apple release identity: primary key `S34998ZCRT`, Team `M78L6FXD48`, Issuer `c98b1e0a-8d10-4fce-a417-536b31c09bfb`, profile `notarytool`.
- Full secret/account map and notarization commands live in `DEVELOPMENT.md`.

---

## Mac Mini Build Server

M1 Mac mini (8GB). Access: `ssh mini`.

**Source of truth:** `SaneProcess/scripts/mini/` — edit there, deploy via `bash scripts/mini/deploy.sh`

| Script | Schedule | Purpose |
|--------|----------|---------|
| `mini-prepare-automation-root.sh` | On demand | Creates/updates clean automation clones under `~/SaneApps-automation` |
| `mini-install-nightly-agent.sh` | On demand | Installs/updates nightly LaunchAgent |
| `mini-install-training-agents.sh` | On demand | Installs/updates weekly + challenger training LaunchAgents |
| `mini-nightly.sh` | 8:45 AM daily | Nightly builds for all repos |
| `mini-train.sh` | Manual / wrapper | MLX LoRA fine-tuning |
| `mini-train-challengers.sh` | 1 AM daily | Daily alternating challenger training for SaneSync (skips Sundays, hard stop 8:30 AM) |
| `mini-train-all.sh` | 1 AM Sunday | Weekly production training for SaneAI with archived metrics history and SaneSync readiness tracking |

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

### Central Memory MCP (Codex)

- Server: `central-memory` in `/Users/sj/.codex/config.toml`
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
- Don't invent new docs — use the core docs + `AGENTS.md` standard
- Use `trash` not `rm -rf`

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
