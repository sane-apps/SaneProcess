# SaneProcess Development Guide

> [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md)

How to build, test, and contribute to SaneProcess.

---

## Quick Start

```bash
ruby scripts/qa.rb                    # Full QA check
ruby scripts/hooks/test/tier_tests.rb # Run hook tests
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project sync
```

## Documentation Normalization SOP

Use the same anti-fragmentation rule across every SaneApps repo:

- In app repos, update `README.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, `PRIVACY.md`, or `SECURITY.md` before creating a new root doc.
- If you must add an extra doc, link it from the README and from the canonical doc that owns that topic.
- Keep public site content in one obvious folder per repo and say where it lives in the README.
- When docs drift, fix the root canonical file first, then sync the website or supporting docs.

## Client Compatibility

SaneProcess has one SOP and multiple client-specific enforcement surfaces.

| Client | First-class path | What is stable today |
|--------|------------------|----------------------|
| **Claude Code** | Native lifecycle hooks | `scripts/hooks/*.rb` + `.claude/settings.json` |
| **Codex** | Repo instructions + repo skills + config | `AGENTS.md`, `.agents/skills`, `~/.codex/config.toml` or `.codex/config.toml`, MCP, shared script/shell guards |
| **Other LLM agents** | Repo instructions + scripts | `AGENTS.md`, `SaneMaster.rb`, git hooks, MCP, and whatever local runtime guards the client can honor |

Codex now documents an experimental `features.codex_hooks` flag, but it is still under development and off by default. Do not make it the primary SaneProcess contract yet.

Codex extras that are stable enough to use in SOPs today:
- `tool_search` for deferred app/MCP capability discovery before claiming a tool is missing
- `computer-use` for live accessibility-tree inspection on the machine hosting the GUI
- `macos-automator` for reusable AppleScript/JXA discovery before writing raw scripts
- `automation_update` for user-approved recurring checks or follow-ups

Stable cross-client guardrails already enforced in shared runtime paths:

- `~/SaneApps/infra/scripts/check-inbox.sh` (`present-draft` / `approve --user-approval` / `require_email_send_approval`)
- `scripts/hooks/sane_curl_guard.sh` via `~/.local/bin/curl` wrapper

Run `ruby scripts/SaneMaster.rb system_check` to verify both Claude hooks and Codex/shared guard wiring.

## The Rules: Scientific Method for AI

These rules enforce the scientific method. Not optional guidelines - **the hooks block you until you comply.**

### Core Principles (Scientific Method)

| # | Rule | Scientific Method | What Hooks Do |
|---|------|-------------------|---------------|
| #2 | **VERIFY, THEN TRY** | Observe before hypothesizing | Blocks edits until 4 research categories done |
| #3 | **TWO STRIKES? STOP AND CHECK** | Reject failed hypothesis | Circuit breaker trips at 3 failures |
| #4 | **TESTS MUST PASS** | Experimental validation | Tracks test results, blocks on red |

**This is the core.** Guessing is not science. Verify → Hypothesize → Test → Learn.

### Supporting Rules (Code Quality)

| # | Rule | Purpose |
|---|------|---------|
| #0 | **NAME IT BEFORE YOU TAME IT** | State which rule applies before acting |
| #1 | **STAY IN LANE, NO PAIN** | No edits outside project scope |
| #5 | **HOUSE RULES, USE TOOLS** | Use project conventions, not preferences |
| #7 | **NO TEST? NO REST** | No tautologies (`#expect(true)`) |
| #8 | **BUG FOUND? WRITE IT DOWN** | Document bugs in memory |
| #9 | **NEW FILE? GEN THE PILE** | Use project scaffolding tools |
| #10 | **FILE SIZE LIMIT** | Max 500 lines (800 hard limit) |

### Research Categories (Required Before Edits)

The hooks require ALL 4 categories before any edit is allowed:

| Category | Tool | What You Learn |
|----------|------|----------------|
| **docs** | `mcp__apple-docs__*`, `mcp__context7__*` | API verification |
| **web** | `WebSearch` | Current best practices |
| **github** | `mcp__github__search_*` | External examples |
| **local** | `Read`, `Grep`, `Glob` | Existing code patterns |

**Why all 4?** Each category catches different blind spots. Skip one → miss something → fail → waste time.

## Project Structure

```
scripts/
├── hooks/                 # Enforcement hooks (synced to all projects)
│   ├── session_start.rb   # SessionStart - bootstrap
│   ├── saneprompt.rb      # UserPromptSubmit - classify task
│   ├── sanetools.rb       # PreToolUse - block until research done
│   ├── sanetrack.rb       # PostToolUse - track failures
│   ├── sanestop.rb        # Stop - capture learnings
│   ├── core/              # Shared infrastructure
│   └── test/              # Hook tests
├── SaneMaster.rb          # CLI entry (different from Swift projects)
└── qa.rb                  # Quality assurance
```

## SaneMaster CLI (Infra)

Use SaneMaster for automation in this repo (preferred over raw commands).

### Core commands

| Command | Purpose |
|---------|---------|
| `verify [--ui]` | Build + run tests (include UI tests with `--ui`) |
| `status` | Live cross-reference across git, inbox, issues, release lanes, and current signals |
| `check_inbox [check|review <id>|read <id>|reply ...]` | Canonical support inbox workflow wrapper |
| `test_mode` | Kill → Build → Launch → Logs |
| `doctor` | Environment health check |
| `tool_discovery --query "..."` | Generate a proof receipt before using a workaround or adding a tool |
| `process_metrics [--json]` | Dashboard for verify churn, session quality, SOP score caps, and hook blocks |
| `refresh_qa_snapshots [--dry-run|--run]` | List stale app QA snapshots, then explicitly refresh selected stale snapshots |
| `gate_review <fixture.json> [--json]` | Deterministically review candidate prevention gates before promoting them into enforcement |

### Validation Hardening

`scripts/validation_report.rb` separates findings into system health, release readiness, app readiness, and advisory buckets. Keep legacy `issues` and `warnings` JSON keys for compatibility, but use `findings` and `verdict.sections` for new tooling.

GitHub-hosted workflow exceptions can be documented inline with `SANEAPPS_GITHUB_HOSTED_EXCEPTION: <reason>` or centrally in `config/github_workflow_exceptions.yml`. Central exceptions are for repos outside the current edit scope; inline comments are preferred when editing that repo directly.

Red-noise budget: a validation finding older than seven days must be fixed, explicitly accepted, or downgraded. Do not leave permanent unexplained red output in the daily report.

QA snapshot refresh is intentionally explicit. Run `ruby scripts/SaneMaster.rb refresh_qa_snapshots --dry-run` first, review the app commands it would run, then rerun with `--run` only for deliberate app-readiness work.
| `sync_mini [mini] [--quiet] [--no-restart] [--activate-mini-runs]` | Sync the active Codex control-plane profile to the Mini; default keeps Mini AM/PM runs paused unless activation is explicit |
| `universal_control_reset [--status|--reboot-mini|--cleanup-mini]` | Recover Air↔Mini Universal Control / pointer handoff |
| `export` | Export code/docs (PDF/MD) |
| `listing_actions` | Export the current listing/setup action tracker from inbox history |
| `hosted_file_actions` | Export the current Lemon Squeezy hosted-file dashboard action tracker |
| `install_provisioning_profiles [--delete-source] [glob ...]` | Deterministically install downloaded provisioning profiles |
| `dedupe_apps [--host local|mini] [--apps App1,App2] [--dry-run] [--json]` | Keep one canonical app bundle per Sane app |
| `debug` | Debugging helpers (logs, crashes, diagnose) |
| `env` | Environment and setup helpers |
| `meta` | Tooling self-audit helpers (`meta`, `audit`, `system_check`) |
| `sales` | LemonSqueezy revenue reporting helpers |

License support rule: real customer license keys come only from LemonSqueezy-backed orders and license-key records. Use `check-inbox.sh review` + `whois` + the LemonSqueezy recovery/backfill flow for missing-key support. Do not generate local fallback keys.

Email delivery rule: do not treat Worker acceptance as success. Normal inbox operations must only count an outbound as sent when Resend shows delivery evidence (`delivered`, `opened`, `clicked`, or `complained`). A `bounced` or still-unconfirmed outbound remains actionable and must be surfaced in `check`, `context`, `audit`, and `check-reply` until it is fixed and resent.

Support-send metrics rule: reply/compose outcomes append local-only `support_send` events to `~/.sanemaster/process_metrics.jsonl` when they reach a terminal delivery, bounce, unconfirmed, or API-failure state. These metrics must not record recipient address or subject; use email ids, delivery ids, lane, and status evidence instead.

Duplicate-purchase refund rule: when you can prove the same customer paid twice for the same product, you may auto-refund the duplicate order without waiting on the normal “documented unresolved bug >24h” threshold, as long as the action still has an audit note and proof file. Standard investigation path:

```bash
# 1. Find likely matching orders even if the support email differs from the purchase email.
ruby scripts/SaneMaster.rb sales --find-customer-orders --email reed@reed-a.ca --name Reed --product SaneBar

# 2. Check the exact keys the customer sent.
ruby scripts/SaneMaster.rb sales --license-status 766800DD-3877-4EAA-938F-D60D42FFA0D7
ruby scripts/SaneMaster.rb sales --license-status D1918A18-BCC3-4DA2-AC6B-C67CC912CA5C

# 3. Refund the duplicate order and disable the refunded key in one audited step.
SANE_REFUND_APPROVED=1 ruby scripts/SaneMaster.rb sales \
  --refund-duplicate-license-key D1918A18-BCC3-4DA2-AC6B-C67CC912CA5C \
  --keep-license-key 766800DD-3877-4EAA-938F-D60D42FFA0D7 \
  --refund-order-number 270691528 \
  --customer-thread "email #542" \
  --approval-source "owner approval note" \
  --proof-file /tmp/reed_duplicate_refund.txt \
  --approval-note /tmp/reed_duplicate_refund_approval.txt
```

Refund audit rule: every refund action now writes a durable audit record under `~/.sanemaster/refunds`, even if the proof file was created in `/tmp`. Approval notes must include explicit owner/user approval. Discretionary refunds must also document the unresolved qualifying issue; duplicate-purchase refunds must document the duplicate/transactional reason. A customer saying “I want a refund” is not enough.

Customer-reply rule for duplicate-license refunds: say explicitly which order was refunded, say the refunded key is disabled and will not work, and say which remaining key is the live working key.

### Manual and Specialized Scripts

These scripts are real, but they are not the default daily path. Keep their role explicit so they do not turn into shadow systems.

| Script | Status | Use it for |
|--------|--------|------------|
| `ruby scripts/contamination_check.rb [path\|--all]` | Manual audit utility | Cross-project contamination scans when you suspect one repo leaked another repo's names, paths, or configs |
| `ruby scripts/link_monitor.rb` | Manual or LaunchAgent utility | Critical checkout/download/site URL monitoring backed by `config/products.yml` |
| `ruby scripts/scaffold.rb <AppName> [--type macos\|ios]` | One-time bootstrap utility | New Sane* repo skeleton generation before project-specific cleanup and Codex/AGENTS refresh |
| `bash scripts/automation/website-consistency-check.sh` | Manual website audit | Static consistency checks across product sites and guide hubs after website/release copy changes |
| `bash scripts/mini/mini-license-test.sh` | Manual deep Mini probe | Full SaneBar license lifecycle testing on the Mini when license activation/deactivation/offline caching changes |
| `bash scripts/mini/sync-claude-config.sh` | Deprecated wrapper only | Prints or routes to the canonical `ruby scripts/SaneMaster.rb sync_mini --no-restart` path |
| `bash scripts/app_test_mode.sh ...` | Manual runtime lane control | Force app mode, owner-license state, or live-launch verification on local host or Mini without ad hoc defaults writes |

Listing/directory follow-up rule: do not maintain separate manual spreadsheets by hand. Regenerate the tracker from inbox history with the canonical command below. New recognized listing/setup emails are folded into the workbook the next time the command runs.

```bash
ruby scripts/SaneMaster.rb listing_actions
```

Outputs:
- dated workbook: `outputs/listing_actions/sanebar_listing_actions_<date>.xlsx`
- latest stable path: `outputs/listing_actions/latest.xlsx`

Hosted-file dashboard sync rule: do not leave Lemon Squeezy hosted-file drift as tribal knowledge or a one-line validation warning. Regenerate the current workbook from live appcast + Lemon Squeezy API data:

```bash
ruby scripts/SaneMaster.rb hosted_file_actions
```

Outputs:
- dated workbook: `outputs/hosted_file_actions/saneapps_hosted_file_actions_<date>.xlsx`
- latest stable path: `outputs/hosted_file_actions/latest.xlsx`

This is a dashboard-action tracker, not an uploader. Lemon Squeezy currently exposes read APIs for files, but not a public file-replacement API. Use the workbook to open the exact product dashboard page and replace the published file with the appcast-matching ZIP.

Upload-folder rule: `~/Desktop/LemonSqueezy-Uploads` is a latest-only staging folder. Before any Lemon Squeezy dashboard upload, move older app ZIPs to Trash so the file picker cannot select the wrong release. The hosted-file tracker audits this folder and reports stale, missing-latest, and unexpected ZIPs alongside the dashboard action list.

Operational SOP:
- `scripts/automation/morning-report.sh` now regenerates the workbook automatically, so new listing/setup emails show up in the nightly report without a manual spreadsheet pass.
- `scripts/automation/sane-status-crossref.sh` now shows the live listing-action counts and current `Needs action` rows.
- `scripts/automation/sane-status-crossref.sh` also shows hosted-file dashboard sync actions, so `ruby scripts/SaneMaster.rb status` surfaces Lemon Squeezy file drift alongside inbox, sales, listing actions, and org-wide GitHub issues/PRs.
- Known recurring vendors should get explicit rules in `scripts/automation/listing_actions_rules.py`.
- New unknown listing/setup senders are still surfaced via the generic heuristic path, with a note saying they should be promoted to a dedicated rule if they recur.
- If the open queue includes `StartupSubmit — Decide whether vendor must redo manual setups`, then downstream setup rows like Gartner, SaaSworthy, and SourceForge are vendor-owned remediation, not direct operator work. Keep them visible as evidence/monitoring, but do not manually complete those setups unless the user explicitly overrides that rule.

Tracker columns are designed for owner action, not inbox triage:
- `action_status`: `Needs action`, `Optional`, or `Monitor`
- `primary_link` / `secondary_link`: the exact vendor links from the emails
- `instructions`: the concrete setup step to do next
- `source_email_ids`: inbox evidence backing that row

### Canonical Tool Paths

Do not hunt around for ad hoc tools.
Use the documented standard path first, then use `tool_discovery` if you still think something is missing.

### Release README Gate

`scripts/release.sh` now runs `scripts/automation/nv-readme-check.sh` as part of the release flow.
Treat that as a real release gate, not optional polish:

- if it says the README is stale, fix the README before release
- do not bypass it by calling shipped user-facing changes “internal”

### Candidate Gate Review

Use `ruby scripts/SaneMaster.rb gate_review <fixture.json>` before adding a new blocking hook or SOP rule. A fixture must include the incident seed, examples that must block, and examples that must remain allowed. The command is local and deterministic: no external package, cloud call, telemetry path, or automatic rule promotion.

Release preflight also loads app-specific fixtures from `test/fixtures/gates/<normalized-app-name>_*.json`. A malformed or failing fixture blocks release until the prevention evidence is fixed or deliberately removed.

```json
{
  "rules": [
    {
      "id": "no-force-push-main",
      "trigger": "force push main",
      "seed": "A release was damaged by force push main",
      "block": ["git push --force origin main"],
      "allow": ["git push origin feature-branch", "git status --short"]
    }
  ]
}
```

### GitHub Actions Policy

SaneApps is Mini/local first.

- Default verification, release prep, and smoke testing should run on the Mini or locally through `SaneMaster.rb`.
- GitHub workflows should be manual fallbacks, not automatic `push`, `pull_request`, or `schedule` spend by default.
- Dependabot should stay off by default too. Do dependency sweeps locally unless a repo documents a real hosted exception.
- If a repo needs GitHub-hosted automation again, document the reason first. Convenience alone is not enough.
- GitHub is only justified when you specifically need a GitHub-hosted lane to produce an externally visible status check or artifact.
- Validation treats any non-manual workflow trigger or repo-level `dependabot.yml` as drift unless the file includes `SANEAPPS_GITHUB_HOSTED_EXCEPTION: <reason>`.

| Need | Standard path | Not this |
|------|---------------|----------|
| Find the right tool first | `ruby scripts/SaneMaster.rb tool_discovery --query "..."` | Random searches, guessing, or inventing a new script first |
| Check live project status | `ruby scripts/SaneMaster.rb status` | Piecing status together manually from git, inbox, sales, and issues |
| Build and test app code | `ruby scripts/SaneMaster.rb verify [--ui]` | Raw `xcodebuild` unless the tool itself is what you are fixing |
| Promote a new prevention gate | `ruby scripts/SaneMaster.rb gate_review <fixture.json>` | Adding hook blocks from one anecdote or untested pattern matching |
| Launch and smoke-test an app | `ruby scripts/SaneMaster.rb test_mode --release --no-logs` | Manual local launches and stale DerivedData builds |
| Mini live window screenshots | `scripts/mini/capture-mini-screenshot.sh --app "<App>" --window-name "<Window>" --mode temp` | Plain `ssh` + `screencapture` guessing from a non-GUI shell |
| Mini Safari tab control | `scripts/mini/mini-safari.sh open-read "<url>"` | One-off raw `ssh mini osascript` snippets for Safari evidence, listing links, or portal checks |
| Sync Codex control-plane to the Mini | `ruby scripts/SaneMaster.rb sync_mini [mini] [--quiet] [--no-restart] [--activate-mini-runs]` | Manual sync script hunting or recreating a second Mini config lane |
| Air↔Mini pointer handoff recovery | `ruby scripts/SaneMaster.rb universal_control_reset` | Random killall / reboot guessing when Universal Control breaks |
| App Store review readiness | `ruby scripts/SaneMaster.rb appstore_preflight` | Clicking around ASC first and guessing what Apple meant |
| Headless Mini signing bootstrap | `bash scripts/mini/bootstrap-build-server.sh` | Trying App Store archive/export first and debugging signing after the failure |
| App Review evidence collection | `ruby scripts/appstore_submit.rb --app-id <id> --platform macos|ios --version X.Y.Z --project-root <repo> --fetch-review-package` | Reading only the rejection text and ignoring Apple’s screenshot/video/PDF evidence |
| Direct release readiness | `ruby scripts/SaneMaster.rb release_preflight` | Manual release spot checks |
| Customer support triage | `ruby scripts/SaneMaster.rb check_inbox review <id>` | Manual API calls, ad hoc email drafts, or skipping review |
| Sales / downloads / funnel | `ruby scripts/SaneMaster.rb sales`, `downloads`, `events` | Manual vendor curls or spreadsheet guesses |
| Listing/setup tracker | `ruby scripts/SaneMaster.rb listing_actions` | Manual inbox sweeps and hand-built spreadsheets |
| Hosted-file dashboard tracker | `ruby scripts/SaneMaster.rb hosted_file_actions` | Grepping validation output and manually hunting Lemon Squeezy product/variant pages |
| MCP and tool health | `ruby scripts/SaneMaster.rb mcp_watchdog doctor` and `~/.codex/bin/check-mcps` | Killing random daemons first and hoping |
  `mcp_watchdog doctor` is the background-machine truth. `check-mcps` is the live active-session tool-call probe and expects the current machine to have active MCP bridges.

### Verification helpers

| Command | Purpose |
|---------|---------|
| `verify_api <API> [Framework]` | Verify SDK API exists |
| `fix_mocks` | Check and fix mock sync status |
| `verify_mocks` | Verify generated mocks are synchronized |

**Examples** and **Aliases** are listed in `./scripts/SaneMaster.rb help` — keep them current with the CLI.

## Central Memory MCP (Postgres + pgvector)

SaneProcess includes a semantic memory MCP server for cross-session retrieval.

- Server code: `scripts/mcp-central-memory/server.mjs`
- Bootstrap: `scripts/mcp-central-memory/bootstrap-local.sh`
- Default DB: `postgresql://<local-user>@localhost:5432/central_memory`
- MCP key: `central-memory` in `/Users/sj/.codex/config.toml` and `.mcp.json`
- Codex control-plane helper source lives in `scripts/codex-bin/`; `ruby scripts/SaneMaster.rb sync_mini` installs that source into local `~/.codex/bin/` and mirrors it to Mini. Safe default keeps Mini AM/PM runs paused so manual Air sessions do not silently reactivate unattended Mini work. Use `--activate-mini-runs` only when you intentionally want the Mini scheduler active again.

Setup:

```bash
cd ~/SaneApps/infra/SaneProcess/scripts/mcp-central-memory
./bootstrap-local.sh
```

Verify:

```bash
~/.codex/bin/check-mcps
codex mcp list | rg central-memory
```

Requirements:

- `OPENAI_API_KEY` available to the Codex app process (for embeddings)
- Homebrew `postgresql@17` and `pgvector` (installed by bootstrap script)

## Knowledge Graph Memory MCP (JSONL)

Codex also uses a separate graph-style memory MCP for entity/relation storage.

- Server code: `scripts/mcp-memory-enhanced/server.mjs`
- Backing store: `/Users/sj/.claude/memory/knowledge-graph.jsonl`
- MCP key: `memory` in `/Users/sj/.codex/config.toml`

Notes:

- This is the graph tool behind `create_entities`, `create_relations`, `open_nodes`, and `search_nodes`.
- Search is tokenized and relation-aware. It is intentionally separate from `central-memory`, which is semantic/vector recall.
- Keep SaneBar issue/email maps in this graph when you want exact cross-reference, not embedding recall.

## Installed Link Check Tools (2026-02-28)

These are installed globally on this machine and available for website verification:

- `lychee` (`brew install lychee`) — version `0.23.0`
- `linkinator` (`npm install -g linkinator`) — version `7.6.1`
- `broken-link-checker` / `blc` (`npm install -g broken-link-checker`) — version `0.7.8`

Quick verify:

```bash
lychee --version
linkinator --version

## Universal Control Recovery

When the Air pointer stops crossing to the Mini, use the shared recovery command instead of ad hoc shell snippets:

```bash
ruby scripts/SaneMaster.rb universal_control_reset
```

What it does:

- forces Handoff advertise/receive on
- clears the saved `com.apple.UniversalControl` state
- restarts `UniversalControl`, `sharingd`, `useractivityd`, `bluetoothd`, and `ControlCenter`
- bounces Wi-Fi on the affected host(s)

Useful flags:

- `--status` prints local + Mini discovery state without changing anything
- `--cleanup-mini` hides Mini Terminal/Codex and closes Preview/Safari
- `--reboot-mini` runs the reset and then restarts the Mini
- `--local-only` or `--mini-only` limits which host gets touched
- `--dry-run` prints the exact commands before executing them

Escalation order:

1. `ruby scripts/SaneMaster.rb universal_control_reset`
2. If the pointer still does not cross, rerun with `--reboot-mini`
3. Reboot the Air only after the Mini reboot path still fails
blc --version
```

## Testing

```bash
ruby scripts/hooks/test/tier_tests.rb           # All tests
ruby scripts/hooks/test/tier_tests.rb --tier easy    # Easy tier
ruby scripts/hooks/test/tier_tests.rb --tier hard    # Hard tier
ruby scripts/hooks/test/tier_tests.rb --tier villain # Villain tier
ruby scripts/SaneMaster.rb verify --timeout 900      # Full registry-backed SaneProcess verify
```

### Script Test Registry

SaneProcess is script-only: full `verify` uses `scripts/test_registry.json`, not Xcode. Every `scripts/**/*_test.rb`, `scripts/**/*_test.py`, plus required scenario tests such as `scripts/hooks/test/tier_tests.rb`, must be registered as one of:

- `required`: runs in full `ruby scripts/SaneMaster.rb verify`
- `manual`: kept for targeted/legacy/operator runs
- `support`: helper loaded by another test, not a standalone executable test

If a new test-like file appears without a registry entry, full verify fails. This is intentional; do not bypass it by adding hardcoded commands back into `verify.rb`.

The Mini currently runs the registry with system Ruby 2.6, so required Ruby tests must avoid Ruby 2.7+ only APIs such as `filter_map` unless they guard them.

## Cross-Project Sync

If you use SaneProcess across multiple projects, keep hooks in sync:

```bash
# Check sync status against another project
ruby scripts/sync_check.rb /path/to/other-project

# Sync hooks to another project
rsync -av scripts/hooks/ /path/to/other-project/scripts/hooks/
```

## Release Pipeline

SaneProcess provides a **unified release script** for all SaneApps macOS products. Every app uses the same pipeline — no local release scripts.

### How It Works

```
.saneprocess (per-app YAML config)
       ↓
saneprocess_env.rb (YAML → env vars)
       ↓
release.sh (build → sign → notarize → DMG → Sparkle signature)
       ↓
set_dmg_icon.swift (applies Finder file icon)
```

### Running a Release

From any app directory with a `.saneprocess` config:

```bash
# Standard release (build + sign + notarize + DMG)
./scripts/SaneMaster.rb release

# Full release (also bumps version, runs tests, creates GitHub release)
./scripts/SaneMaster.rb release --full --version X.Y.Z --notes "Release notes"
```

### Release truth path

For Mini-first apps, the release signal now has one canonical path:

1. `./scripts/SaneMaster.rb release_preflight` runs on Mini when the command is Mini-routed.
2. Project QA writes `outputs/qa_status.json` when available.
3. Shared preflight also writes `outputs/release_preflight_status.json`.
4. `SaneMaster.rb` syncs `outputs/` back from Mini to the local workspace.

## Mini Visual Verification SOP

For SaneApps desktop UI, use this verification ladder on the Mini:

1. **Launch the signed/release-like app on the Mini**

```bash
./scripts/SaneMaster.rb test_mode --release --no-logs
```

2. **Live screenshot path (preferred when Screen Recording is granted)**

Run this from the controlling machine with Codex installed. The capture itself still happens on the Mini GUI session.

```bash
/Users/sj/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh \
  --list-windows --app "SaneClip"

/Users/sj/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh \
  --app "SaneClip" --window-name "Settings" --mode temp
```

- This runs inside the Mini's logged-in GUI Terminal session through `mini-gui-run.sh`.
- First use may trigger a one-time Screen Recording permission request for Terminal on the Mini.
- Do **not** trust plain `ssh ... screencapture` as the primary path for live app windows.

3. **Deterministic render fallback for SwiftUI settings/surfaces**

Use this when live capture is blocked by permissions or when you need a stable artifact for review.

```bash
echo /tmp/app-renders > /tmp/saneclip_screenshot_dir.txt
./scripts/SaneMaster.rb verify
ls -1 /tmp/app-renders
```

- SaneClip already writes `settings-*.png` renders from tests when the hint file is present.
- Use these renders to verify layout, copy, spacing, and destructive-action affordances.

4. **iOS simulator screenshots**

When the issue is iPhone/iPad-only, use the app's simulator screenshot script or the iOS screenshot lane instead of desktop capture.

4.5 **Codex second-pass visual audit**

- After saving a Mini screenshot or deterministic render, inspect it with Codex visual tools and, when the GUI is available to Codex, `computer-use` accessibility inspection.
- Use it to check for clipped controls, overlap, wrong selected state, unreadable copy, and obvious contrast drift.
- Do not use NVIDIA vision helpers for normal SaneApps verification. They are legacy/exception-only and require an explicit user request for that specific run.
- These are supplements. The canonical proof is still the clean Mini screenshot or deterministic render artifact.

Hard rule:
- For any release-critical UI claim, keep at least one saved visual artifact: live Mini screenshot when available, otherwise a deterministic render PNG.
5. `ruby scripts/validation_report.rb` reads the newest available status snapshot and blocks false `READY TO SHIP` results.

Validation-report nuance:
- Broken website/appcast/webhook/Homebrew drift still counts as a real broken release pipeline.
- Lemon Squeezy hosted-file drift is reported separately as `NEEDS DASHBOARD SYNC` with product/variant references, because it still affects customer downloads but requires dashboard follow-up rather than code or deploy repair.

Canonical runtime cleanup is now a first-class step:

- `./scripts/SaneMaster.rb dedupe_apps --host mini --apps SaneBar`
- `./scripts/SaneMaster.rb dedupe_apps --apps SaneBar,SaneHosts`

`dedupe_apps` keeps one canonical installed bundle per app at `/Applications/App.app` and trashes stale build/runtime copies that can confuse Launch Services, Spotlight, TCC, and Launch Services.

Hard rule:
- SaneApps runtime installs on both the Air and Mini must resolve to exactly one canonical `/Applications/App.app` per app.
- Do not leave fallback runtime bundles in `~/Applications`.
- Do not leave Spotlight-visible duplicate bundles in `build/`, `outputs/`, `release/`, `release-publish/`, `release-worktrees/`, `~/SaneApps/tmp`, or `DerivedData`.
- Unsigned or Apple Development fallback launches must stage to a transient non-indexed path under `/tmp/saneapps-staging.noindex`, never to another installed Applications location.
- Standard verify/launch/test flows should auto-run `dedupe_apps` afterward. If you bypass the standard flow, run dedupe manually before claiming the machine is clean.

### Work Session Guard

SaneMaster now has a shared work-session guard for unattended local and Mini-routed work.

What it does:
- starts `caffeinate -dimsu`
- disables idle screensaver start with `defaults -currentHost write com.apple.screensaver idleTime -int 0`
- disables screensaver password prompt with `defaults write com.apple.screensaver askForPassword -int 0`
- saves the previous values to `~/.sanemaster/work_session_state.json` so they can be restored later

It auto-runs for active work commands such as:
- `verify`
- `launch`
- `test_mode`
- release/debug flows

Manual commands:

```bash
./scripts/SaneMaster.rb work_session_on
./scripts/SaneMaster.rb work_session_status
./scripts/SaneMaster.rb work_session_off
```

Important:
- `caffeinate` prevents sleep, not macOS screen lock.
- If `sysadminctl -screenLock status` still reports `immediate`, true unattended no-lock still requires a one-time manual host change:

```bash
sysadminctl -screenLock off -password -
```

Unsigned fallback rules:

- headless `test_mode --release` may build `Debug` when the Mini cannot unlock signing
- that fallback stages to `/tmp/saneapps-staging.noindex/App.app`
- the shared launcher preserves any signed `/Applications/App.app` install during that fallback
- release-style smoke should target the signed `/Applications` install when it exists, not the transient unsigned fallback copy

Non-interactive auth/tooling gaps should render as structured skips, not raw stderr noise:

- missing `gh` auth/keychain access → `skipped (gh auth unavailable)`
- missing `CLOUDFLARE_API_TOKEN` for Wrangler → `skipped (Cloudflare token unavailable)`

### DMG Icon Configuration

Each app's `.saneprocess` must define both icon types:

```yaml
release:
  dmg:
    volume_icon: Resources/DMGIcon.icns   # Mounted volume icon (Finder sidebar)
    file_icon: Resources/DMGIcon.icns     # File icon (Desktop/Finder)
```

If `file_icon` is missing, the DMG gets a generic Finder icon. The `DMGIcon.icns` file should be a full-square opaque icon (no squircle, no shadow — macOS applies its own mask).

### Release Flags

| Flag | Purpose |
|------|---------|
| `--full` | Version bump + tests + GitHub release + deploy |
| `--website-only` | Deploy website to Cloudflare Pages only (no app build) |
| `--skip-build` | Skip Xcode build (use existing binary) |
| `--skip-appstore` | Skip App Store submission in full release |
| `--allow-republish` | Allow re-release of same version |
| `--allow-unsynced-peer` | Allow release even if peer projects are out of sync |

### Full SOP

See [templates/RELEASE_SOP.md](templates/RELEASE_SOP.md) for the complete release checklist including R2 upload, appcast update, and Cloudflare Pages deployment.

### Multi-Channel Distribution Rules

Setapp is a third macOS channel. It is **not** a replacement for direct distribution, and it is **not** an App Store variant.

| Channel | Licensing / Commerce | Updates | UI rules | Ops rules |
|---------|----------------------|---------|----------|-----------|
| Direct | Lemon Squeezy | Sparkle + appcast | Direct checkout/key entry allowed. Donate/support links allowed. | Website, dist ZIP, appcast, GitHub release, Homebrew, email helper stay aligned. |
| App Store | StoreKit | App Store | No external purchase path. No donation/support links that can trigger review issues. | ASC metadata, screenshots, IAP, and review notes must stay aligned. |
| Setapp | Setapp Framework + Setapp commerce | Setapp agent / framework path | No Sparkle. No Lemon Squeezy activation UI. No donate/buy prompts. | Separate bundle ID, Setapp public key, Setapp update policy, Setapp verification lane. |

Non-negotiable rule:
- Do **not** switch the direct website/business lane from Lemon Squeezy to Stripe just because Setapp uses Stripe.
- Direct-release worker sync must stay isolated too: if `sane-email-automation` is dirty or behind `origin/main`, `release.sh` should use a fresh temporary clone for the worker deploy step instead of mixing unrelated worker changes into the app release.

### Setapp Implementation Checklist

Do these in order:

1. Add an explicit distribution-channel abstraction in shared code.
   - Do not keep inferring everything from `AppStoreProductID` and `SUFeedURL`.
   - Expected end state: channel-aware code paths for `direct`, `appStore`, and `setapp`.
2. Add Setapp-specific build configs.
   - Expected names: `Debug-Setapp`, `Release-Setapp` or the nearest equivalent that keeps the lane obvious.
3. Register separate Setapp bundle IDs.
   - Setapp docs treat bundle ID choice as effectively permanent.
   - Use the `-setapp` suffix convention.
4. Add Setapp resources and entitlements.
   - `setappPublicKey.pem`
   - current convention: keep it at `Setapp/setappPublicKey.pem` inside the app repo and let the Setapp build script copy it into the bundle resources
   - `NSUpdateSecurityPolicy` for `com.setapp.DesktopClient.SetappAgent` on macOS 13+
   - `com.setapp.ProvisioningService` mach-lookup exception if the build is sandboxed
   - `MPSupportedArchitectures` if the Setapp lane needs explicit architecture declaration
5. Remove direct/App Store monetization surfaces from the Setapp build.
   - no Sparkle row
   - no Lemon Squeezy key entry
   - no direct checkout button
   - no Donate / GitHub Sponsors section
6. Implement Setapp-specific runtime hooks.
   - release notes / What's New path
   - menu bar usage reporting for menu bar apps
7. Add channel-aware verification.
   - direct, App Store, and Setapp all need their own smoke checks
   - Setapp must not be "verified" by direct/App Store tests

### Interim Setapp Bundle Sanitizer

Current Xcode target build order is not enough to make a same-target Setapp config truthful on its own.

- Sparkle can still be re-embedded and `SU*` keys can still reappear after an app target shell phase runs.
- For now, the authoritative final-bundle cleanup step is:

```bash
./scripts/sanitize_distribution_bundle.rb \
  --channel setapp \
  /path/to/App.app
```

- That sanitizer:
  - removes embedded `Sparkle.framework`
  - strips direct-update keys from the built `Info.plist`
  - weakens Sparkle load commands across every Mach-O under `Contents/MacOS`
- Important:
  - sanitizing a built bundle mutates the code signature
  - local verification therefore needs an ad hoc re-sign after sanitation
  - real release/sign/notarize flow must sanitize before final signing, or re-sign immediately afterward

### Setapp Update Strategy

Think about updates as three separate truths:

- Direct:
  - Sparkle remains the updater
  - appcast remains the source of truth
  - Homebrew/email helper/site links remain part of the direct release checklist
- App Store:
  - App Store Connect remains the updater and billing path
- Setapp:
  - Setapp handles install/update
  - Sparkle must be absent
  - the app should surface Setapp release notes through the Setapp framework path, not through the direct updater UI

Version policy:
- Keep marketing versions aligned across channels whenever feature parity is the same.
- If a Setapp-only or App-Store-only constraint forces different behavior, the version number can still match; the release notes should explain only the channel-specific differences.
- Avoid channel-only hidden fixes that never get documented. This is how support drift starts.

### Setapp Verification Matrix

Minimum sign-off before any Setapp ship:

1. Build and launch the Setapp config on the mini.
2. Verify the built app is on the expected Setapp bundle ID.
3. Verify `setappPublicKey.pem` is embedded.
4. Verify Sparkle is absent from the build product and absent from visible settings/about UI.
5. Verify no Lemon Squeezy purchase/key-entry path is visible.
6. Verify no Donate / GitHub Sponsors UI is visible.
7. Verify Setapp-specific usage reporting is wired where required.
8. Verify macOS 13+ update policy is present in the built Info.plist.
9. If sandboxed, verify the Setapp Mach service entitlement is present.
10. Verify direct and App Store builds still behave correctly after the Setapp code lands.
11. If the Setapp lane still shares a target with the direct lane, run `sanitize_distribution_bundle.rb` and then re-sign the bundle before launch verification.

### Setapp Upload / Replacement Standard

Use the shared upload lane instead of hand-clicking portal forms:

```bash
./scripts/SaneMaster.rb setapp_upload \
  --zip /path/to/App-Setapp-X.Y.Z.zip \
  --release-notes-file /path/to/setapp-notes.txt
```

Preferred path:
- Use `SETAPP_AUTOMATION_TOKEN` with Setapp's documented `POST /v1/ci/version` endpoint.
- Include `--allow-overwrite true` when replacing a build that is waiting for review.

Portal fallback path:
- Use only when the web portal is logged in but the visible `Reupload .ZIP` button is inert or read-only.
- Run on the Mini with Safari logged into `developer.setapp.com`.
- Pass the existing Setapp app id and version id:

```bash
./scripts/SaneMaster.rb setapp_upload \
  --portal-fallback \
  --app-id 1848 \
  --version-id 46885 \
  --zip /path/to/SaneBar-Setapp-2.1.47-iconfix.zip \
  --release-notes-file /path/to/setapp-notes.txt
```

What the fallback does:
1. Uploads the archive through the portal-backed `/v1/versions/upload_archive` endpoint.
2. Verifies Setapp extracted the bundle id, build version, display version, and icon.
3. Patches the existing version record with the temporary archive reference and release notes.
4. Recheck the Setapp Apps page and API record; do not trust the stale page label alone.

Do not print, paste, or save Setapp `access_token` / `refresh_token` values. The script reads the Safari token only in-process and uses temp curl config files with `0600` permissions.

### Hidden Gotchas To Plan For Up Front

- Setapp docs still publicly describe a narrower rollout than the email offer. Trust the live business thread for eligibility, but still code to the published technical requirements.
- Universal build support is the largest likely technical blocker for current arm64-only projects.
- SaneBar is a menu bar app, so Setapp usage reporting is not optional polish.
- SaneClip has more bundle surfaces than SaneBar (widgets / extensions), so Setapp bundle-family drift needs an explicit review even if the first Setapp lane ships with fewer surfaces.
- Xcode same-target Setapp configs can look clean in source while still re-embedding Sparkle after target shell phases. Do not trust the raw built bundle without the final sanitizer check.
- A sanitized bundle that launches locally after ad hoc re-sign is good verification signal, but it is not a substitute for the real signed Setapp release path.
- Current mini verification state as of 2026-03-18:
  - SaneBar and SaneClip clean mini worktrees build as Setapp bundles with the right `-setapp` bundle IDs.
  - Their built Info.plists now include `NSUpdateSecurityPolicy` and `MPSupportedArchitectures = [arm64]`.
  - SaneClip's Setapp-specific entitlement file includes `com.setapp.ProvisioningService`.
  - Both sanitized bundles launch on the mini after ad hoc re-sign.
  - `setappPublicKey.pem` is still absent, so runtime entitlement validation is still incomplete.
  - A real signed SaneClip Setapp build is still blocked by provisioning/iCloud profile setup, not by code logic.
- Current local persistence is mixed:
  - app-support data paths are app-name based (`Application Support/SaneBar`, `Application Support/SaneClip`)
  - keychain service defaults are bundle-ID based
  - result: direct and Setapp builds are likely to share settings/data but not share license state unless we deliberately unify or separate that behavior
- SaneBar App Store is intentionally dead. Setapp does not reopen that lane.
- Website copy must stay channel-specific:
  - `sanebar.com` / `saneclip.com` still describe the direct build unless there is an intentional Setapp landing page
  - do not silently mix Setapp onboarding language into the direct site
- Setapp handles first-line billing/licensing support in the published model, so support tooling needs to know the customer channel before troubleshooting licensing or updates.

### App Store IAP Readiness

`scripts/appstore_submit.rb` now includes an IAP readiness pass for any App Store submission when `appstore.product_id` is set in `.saneprocess` (macOS or iOS).

What it auto-checks/fixes:
- Missing IAP localization (`en-US`)
- Missing IAP price schedule (defaults to `6.99` USD unless overridden)
- Missing IAP review screenshot (uses first matching screenshot from `.saneprocess appstore.screenshots`)
- Missing IAP availability
- Missing IAP review note

Useful commands:

```bash
# IAP readiness only (no build upload, no app submission)
ruby scripts/appstore_submit.rb --iap-only --app-id <APP_ID> --project-root .

# Override default IAP USD price during readiness pass
ruby scripts/appstore_submit.rb --iap-only --app-id <APP_ID> --project-root . --iap-price-usd 4.99
```

Important Apple constraint:
- If ASC returns `STATE_ERROR.FIRST_IAP_MUST_BE_SUBMITTED_ON_VERSION`, the IAP is ready but must be reviewed together with an app version submission.
- If you rotate away from a rejected IAP, rotate both `appstore.product_id` and `appstore.iap.display_name`. ASC keeps the old rejected IAP record, and duplicate display names will block creation of the replacement product.
- If the replacement IAP stays `READY_TO_SUBMIT`, attach it on the platform version page under `Included Assets > In-App Purchases and Subscriptions` before resubmitting. Do not assume product creation alone is enough.

### App Store Accessibility Declarations (API 4.0+)

`scripts/appstore_submit.rb` can now sync accessibility declarations from `.saneprocess` using App Store Connect API endpoints:
- `GET /v1/apps/{id}/accessibilityDeclarations`
- `POST /v1/accessibilityDeclarations`
- `PATCH /v1/accessibilityDeclarations/{id}`

Config shape:

```yaml
appstore:
  accessibility_declarations:
    publish: true
    iphone:
      supports_dark_interface: true
      supports_voiceover: true
    ipad:
      supports_dark_interface: true
```

Notes:
- `publish: true` maps to ASC update attribute `publish: true` (not `state: "PUBLISHED"`).
- Family keys accept friendly forms (`iphone`, `ipad`, `mac`, `watch`, `tv`, `vision`) and normalize to ASC enums.
- Attribute keys accept snake_case or camelCase and normalize to ASC names.
- If this block is absent, accessibility declaration sync is skipped.

### App Store Listing Metadata Safety

`appstore_submit.rb` no longer uses `appstore.review_notes` as fallback public listing description.

Why:
- `review_notes` are for App Review only and can contain internal test instructions.
- Public description now only comes from:
  1. `appstore.description` (preferred)
  2. a generic safe fallback string if description is missing.

Recommended:
- Set both `appstore.description` and `appstore.keywords` explicitly in each app’s `.saneprocess`.

`appstore_submit.rb` now hard-fails submission if the target platform is missing:
- a platform-specific metadata block (`appstore.metadata.macos` or `appstore.metadata.ios`)
- description
- subtitle
- keywords
- support URL
- privacy policy URL
- review notes

It also blocks generic fallback descriptions/keywords and flags iOS listing copy that still talks about macOS-only behavior.

### App Store Policy Guardrails

`SaneMaster.rb appstore_preflight` now hard-fails known App Review rejection classes before submission:
- Accessibility or synthetic input used for clipboard/paste automation (`2.4.5`)
- Accessibility or CGEvent-driven third-party UI manipulation in an App Store build (`2.4.5`)
- App Store artifacts that still expose direct-purchase markers like website checkout URLs or key-entry CTAs (`3.1.1`)
- IAP products that merely exist in ASC but are not actually review-ready

This is deliberate. The goal is to stop wasting review cycles on builds Apple is likely to reject.

Additional lessons now enforced in the shared flow:
- When a lane is rejected, the first step is evidence collection, not diagnosis. Read the full reviewer message, record the exact platform/version/build/submission ID, download every App Review attachment, and open all screenshot/video/PDF evidence before changing code or drafting a reply.
- `scripts/appstore_submit.rb --fetch-review-package` is the canonical evidence collector. It saves the reviewer message, page text, and any downloaded App Review attachments into an evidence folder instead of relying on manual browser memory.
- Safari evidence helpers must prove they are on the exact target ASC page before trusting DOM text. If the tab never lands on the requested version/review URL, treat the probe as invalid instead of reusing stale page content from another platform.
- Before hunting for new browser automation tools, use Mini Safari itself as the control surface. AppleScript plus Safari `do JavaScript` is the default path for inspecting reviewer evidence, download links, and Apple Developer profile pages. Always prove the exact front-tab URL first.
- For repeat Mini Safari work, use `scripts/mini/mini-safari.sh` instead of rebuilding AppleScript by hand. Minimum useful subcommands:
  - `list-tabs`
  - `open-read "<url>"`
  - `read <tab_index>`
  - `js <tab_index> "<javascript>"`
- Use `mini-safari.sh` for directory/listing activation links too, not just App Store pages. Capture the final URL, title, and body snippet so status can distinguish `live`, `needs activation`, `queued`, and `upsell only`.
- App Store Connect and `developer.apple.com` can have separate login state. Check both before concluding a profile or review page is inaccessible.
- When a macOS App Store profile needs repair, inspect the certificate shown on the Apple Developer profile edit page and confirm it is tied to `Apple Distribution`, not a stale `3rd Party Mac Developer Application` or `Mac App Distribution` cert.
- `appstore_submit.rb --skip-upload` fails fast if the requested existing build is not actually visible in ASC for that platform. It now prints the visible build candidates instead of polling for 45 minutes on a bad build number.
- `release.sh` now hard-runs `SaneMaster.rb appstore_preflight` before any App Store submission step, so full releases cannot skip the compiled-artifact policy gate by accident.
- For macOS App Store exports, `xcodebuild -exportArchive` must run with ASC API-key auth on the Mini. If export reaches `productbuild` and then fails with `errSecInteractionNotAllowed`, the fix is installer-key keychain access, not another upload attempt.
- `appstore_submit.rb` now validates that support and privacy URLs actually resolve successfully, not just that metadata strings exist.
- Reviewer access is treated as a first-class requirement. If the app needs outside credentials, review notes must explain the exact demo/review path and must state when no account, API key, or payment is required.
- “App Store-safe” means the compiled artifact, not just the source tree. Preflight must verify that the App Store binary no longer exposes website checkout URLs, license-key CTAs, or automation permission declarations that contradict the review notes.
- Apps whose core App Store build still depends on Accessibility/CGEvent control of third-party UI should be treated as high-risk or ineligible for Mac App Store review until that functionality is removed or isolated from the App Store build.

### App Store Website Link Auto-Sync (iOS)

`release.sh` now auto-syncs a live App Store URL into website HTML before deployment when all are true:
- `appstore.enabled: true`
- `appstore.platforms` includes `ios`
- `appstore.app_id` is configured

How it works:
- Looks up live URL via Apple lookup API (`itunes.apple.com/lookup?id=<APPSTORE_APP_ID>`).
- If live, patches any `<a ... data-appstore-ios-link ...>` marker in `docs/index.html` and/or `website/index.html`.
- Removes `style="display: none;"` from that marker so the CTA appears only once the URL is live.

Marker example:

```html
<a href="#" data-appstore-ios-link data-appstore-ios-url="" style="display: none;">Download on App Store</a>
```

If no marker exists, deploy still proceeds and logs a warning.

## Before Pushing

1. `ruby scripts/qa.rb` - QA passes
2. `ruby scripts/hooks/test/tier_tests.rb` - All tests pass
3. Sync to other projects if hooks changed

---

## Fresh Install Testing

Run on a fresh machine or directory without SaneProcess installed.

### Prerequisites

- macOS with Ruby installed
- `claude` CLI installed (`npm install -g @anthropic-ai/claude-code`)

### Test Steps

```bash
# 1. Create test directory
mkdir /tmp/saneprocess-test && cd /tmp/saneprocess-test

# 2. Run init.sh
curl -sL https://raw.githubusercontent.com/sane-apps/SaneProcess/main/scripts/init.sh | bash
```

### Verification Checklist

- [ ] `.claude/` and `.claude/rules/` exist
- [ ] `scripts/hooks/` and `scripts/hooks/core/` exist
- [ ] `.claude/settings.json` is valid JSON with hook entries
- [ ] Syntax validation: `for f in scripts/hooks/*.rb; do ruby -c "$f"; done`
- [ ] Hook registration: `grep -c "scripts/hooks" .claude/settings.json` (>= 5)

### Regression Tests

```bash
ruby scripts/hooks/test/tier_tests.rb  # Authoritative test suite (178 tests)
```

### Full QA

```bash
./scripts/qa.rb   # All checks passed
```

---
