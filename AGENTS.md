# SaneApps AGENTS

Speak in plain English. Keep it short and direct. Use `I`/`me`/`my` — never `we`/`us`/`our`.

---

## Session Start

Do ALL of these BEFORE any work:

1. Read `SESSION_HANDOFF.md` if it exists — recent work, pending tasks, gotchas
2. Check Serena memories (`read_memory`) for project-specific learnings
3. Read `~/.claude/SKILLS_REGISTRY.md` — know what global skills/tools exist
4. Run `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`
5. Launch Xcode if needed: `pgrep -x Xcode >/dev/null || open -a Xcode`

## Session End

1. Save learnings via Serena `write_memory`
2. Update `SESSION_HANDOFF.md` — include: open GitHub issues (`gh issue list`), research.md topics, feature requests
3. Append SOP rating to `outputs/sop_ratings.csv`

## Live Memory Rule

Do not wait until session end.

- When you find a new bug, issue cluster, regression, or root-cause change, update Serena memory and the knowledge graph immediately.
- When you fix, close, merge, or downgrade an issue, update the same memory/graph entries immediately.
- Keep bug memory live enough that it can be used directly for support replies, App Store submissions, website release notes, and future debugging without re-discovery.
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
| 2 | VERIFY, THEN TRY | Check APIs/tools exist before using. Write findings to `research.md` with TTL |
| 3 | TWO STRIKES? STOP AND CHECK | Failed twice → STOP, read the error, research |
| 4 | GREEN MEANS GO | Tests must pass before "done" |
| 5 | HOUSE RULES, USE TOOLS | Use SaneMaster, release.sh, sane_test.rb — NOT raw commands |
| 6 | BUILD, KILL, LAUNCH, LOG | Full cycle after every code change |
| 7 | NO TEST? NO REST | Every fix gets a test. No tautologies (`#expect(true)` is useless) |
| 8 | BUG FOUND? WRITE IT DOWN | Update Serena memory + knowledge graph when bugs are found, reclassified, fixed, or closed |
| 9 | NEW FILE? GEN THE PILE | Use scaffolding tools and templates |
| 10 | FIVE HUNDRED'S FINE, EIGHT'S THE LINE | Max 500 lines, must split at 800 |
| 11 | TOOL BROKE? FIX THE YOKE | Fix broken tools, don't work around them |
| 12 | TALK WHILE I WALK | Subagents for heavy work, stay responsive |
| 13 | CONTEXT OR CHAOS | Maintain CLAUDE.md, load at start, save at end |
| 14 | PROMPT LIKE A PRO | Specific prompts with file paths, constraints, context |
| 15 | REVIEW BEFORE YOU SHIP | Self-review for security, edge cases, correctness |
| 16 | DON'T FRAGMENT, INTEGRATE | Upgrade existing files. 5-doc standard (README, DEVELOPMENT, ARCHITECTURE, SESSION_HANDOFF, CLAUDE). No orphan files |

**Workflow:** PLAN → VERIFY → BUILD → TEST → CONFIRM (user approves, then commit)

**Circuit Breaker:** After 3 consecutive failures: STOP. Read error messages. Research the actual API.

**Research gate:** Use all 4 categories: docs (apple-docs/context7), web search, GitHub, and local codebase.

---

## SaneMaster Quick Reference

**`./scripts/SaneMaster.rb`** — unified automation CLI for ALL SaneApps projects. Use this instead of raw commands.

Run with no args for full help. Run `help <category>` for category details.

| Category | Key Commands | What It Does |
|----------|-------------|--------------|
| **build** | `verify`, `clean`, `lint`, `release`, `release_preflight`, `appstore_preflight` | Build, test, release pipeline, App Store compliance |
| **sales** | `sales`, `sales --products`, `sales --month`, `sales --daily`, `sales --fees` | LemonSqueezy revenue (today/yesterday/week/all-time) |
| **sales** | `downloads` (dl), `downloads --app NAME`, `downloads --days N`, `downloads --json` | Download analytics from sane-dist Worker (D1-backed) |
| **sales** | `events`, `events --days N`, `events --app NAME`, `events --json` | User-type events: new_free_user, early_adopter_grant, license_activated |
| **sales** | `leads --query "TEXT"`, `leads --domain DOMAIN`, `leads --json` | Prospect discovery with Exa + Firecrawl site dossiers |
| **check** | `verify_api`, `dead_code`, `deprecations`, `swift6`, `test_scan`, `structural`, `compliance`, `check_docs`, `check_binary`, `menu_scan` | Static analysis, API verification, code quality |
| **debug** | `test_mode` (tm), `logs --follow`, `launch`, `crashes`, `diagnose` | Interactive debugging, crash analysis |
| **ci** | `enable_ci_tests`, `restore_ci_tests`, `fix_mocks`, `monitor_tests`, `image_info` | CI/CD test helpers |
| **gen** | `gen_test`, `gen_mock`, `gen_assets`, `template` | Code generation, mocks, assets |
| **memory** | `msync`, `session_end`, `reset_breaker` | Cross-session memory sync, circuit breaker |
| **breaker** | `breaker_status` (bs), `breaker_errors` (be), `reset_breaker` (rb) | Circuit breaker inspection and reset |
| **env** | `doctor`, `health`, `bootstrap`, `setup`, `versions`, `reset`, `restore` | Environment setup, health checks |
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
| "check email", "inbox" | `~/SaneApps/infra/scripts/check-inbox.sh check` |
| "project status", "health check" | `SaneMaster.rb sales` + `events` + `downloads` + git status |
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

**Email:** hi@saneapps.com | **Sign-off:** Mr. Sane (NEVER mention AI/Claude/Codex)
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
- If customer attaches media describing a problem: save to `~/Desktop/Screenshots/`, alert user, wait for approval
- Auto-handle: simple questions, download/install issues, basic support
- Escalate: refunds, complaints, feature requests, legal, media showing a problem
- NEVER craft manual curl commands for email — use check-inbox.sh

---

## Keychain Secrets

**ONE PROMPT, ONE SECRET, ONE TASK. Sequential, never parallel.**

```bash
# CORRECT
TOKEN=$(security find-generic-password -s cloudflare -a api_token -w)
curl -H "Authorization: Bearer $TOKEN" ...

# WRONG — loops, retries, and parallel calls = popup flood
for key in a b c; do security find-generic-password ...; done
security find-generic-password ... && security find-generic-password ...
curl ... $(security find-generic-password ...) &
```

Permanent SOP:
- One intentional Keychain prompt per task. If one lookup succeeds, reuse that value.
- No repeated probing "just to check". If you need another secret, explain why first.
- No `security` calls in loops, background jobs, sweeps, or parallel tool runs.
- Codex shells are guarded by `~/.local/bin/security -> sane_security_guard.sh`, which blocks overlapping and rapid repeat secret reads.

| Service | Account | Usage |
|---------|---------|-------|
| `nvidia` | `api_key` | NVIDIA Build API (nv CLI) |
| `openrouter` | `api_key` | OpenRouter API (nv CLI, paid) |
| `grok` | `api_key` | xAI Grok API |
| `gemini` | `api_key` | Google Gemini API |
| `openai` | `api_key` | OpenAI ChatGPT API |
| `cloudflare` | `api_token` | Cloudflare API |
| `lemonsqueezy` | `api_key` | Lemon Squeezy API |
| `resend` | `api_key` | Resend email API |
| `dist-analytics` | `api_key` | sane-dist Worker analytics API |
| `notarytool` | (keychain profile) | Apple notarization + TestFlight |

Mac Mini keys: `~/.config/nv/env` (keychain doesn't work over SSH).

---

## Apple Developer Credentials

| Key | ID | Access |
|-----|----|--------|
| **SaneApps (primary)** | `S34998ZCRT` | Admin — notarization, TestFlight, altool |
| SaneBar Notarization (legacy) | `7LMFF3A258` | Developer |

- **Issuer ID**: `c98b1e0a-8d10-4fce-a417-536b31c09bfb`
- **Team ID**: `M78L6FXD48`
- **`.p8` file**: `~/.private_keys/AuthKey_S34998ZCRT.p8`
- **Keychain Profile**: `notarytool`

```bash
xcrun notarytool submit /path/to/app.dmg --keychain-profile "notarytool" --wait
xcrun stapler staple /path/to/app.dmg
```

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
- Runtime: PostgreSQL 17 + `pgvector` on `postgresql://localhost:5432/central_memory`
- Bootstrap: `cd ~/SaneApps/infra/SaneProcess/scripts/mcp-central-memory && ./bootstrap-local.sh`
- Health: `~/.codex/bin/check-mcps` (must show `central-memory` PASS)
- Tools: `remember`, `recall`, `recent`, `stats`, `delete_by_external_id`, `import_knowledge_graph`

---

## Codex-Specific Notes

- Codex has no native PreToolUse hook API — critical gates are enforced in shared scripts
- Email writes are guarded via `~/.local/bin/curl` → `sane_curl_guard.sh` plus `check-inbox.sh` approval checks
- Don't invent new docs — use the 5-doc standard
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
- **Global skills**: `~/.claude/skills/`

## References (for deep dives)

- Global rules + full gotchas table: `~/.claude/CLAUDE.md`
- Infra rules + hook details: `~/SaneApps/infra/SaneProcess/CLAUDE.md`
- Per-app architecture: each app's `ARCHITECTURE.md`
- Release SOP: `SaneProcess/templates/RELEASE_SOP.md`
- Shared infra scripts: `SaneProcess/scripts/`
- Mini scripts: `SaneProcess/scripts/mini/`
