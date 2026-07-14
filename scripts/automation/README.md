# Automation Scripts

Scripts for automating development and business tasks across SaneApps projects.

repo-root-safe rule:
- Prefer `ruby scripts/SaneMaster.rb ...`, `bash scripts/automation/...`, or `python3 scripts/automation/...` from the repo root.
- Bare commands in this directory are implementation detail examples, not the primary operator path.

## Prerequisites

- `OPENAI_API_KEY` available in the shell environment for GPT audit fallbacks
- Git repositories with tags (for release notes)
- SaneApps projects at `~/SaneApps/apps/`

## Scripts

### lead-research.py

Lead discovery with Exa plus read-friendly site dossiers from Firecrawl.

**Usage:**
```bash
lead-research.py --query "mac app review sites"
lead-research.py --query "developer newsletters for privacy tools" --site-limit 8
lead-research.py --domain setapp.com --domain macstories.net
```

**What it does:**
1. Uses Exa search to find candidate URLs for a query.
2. Dedupes those hits down to unique domains.
3. Uses Firecrawl `map` to find relevant pages on each site.
4. Uses Firecrawl `scrape` to turn those pages into readable markdown.
5. Saves one `.json` bundle plus one `.md` summary to `outputs/leads/`.

**Secrets:**
- `EXA_API_KEY` env var, or keychain service `exa` / account `api_key`
- `FIRECRAWL_API_KEY` env var, or keychain service `firecrawl` / account `api_key`

**Output location:** `~/SaneApps/infra/SaneProcess/outputs/leads/`

### gpt_audit.py

Standalone GPT audit runner for scripted or non-interactive audit batches. It
defaults to independent ephemeral Codex CLI lanes and does not require
`OPENAI_API_KEY`.

Codex lanes also pass `--ignore-user-config`, so user MCP/plugin/app
configuration is not loaded while Codex authentication remains available. The
current CLI has no supported no-network flag: read-only sandboxing is not
network isolation, and the selected model can still make network requests.
Child processes receive a minimal runtime/auth environment; API keys and
unrelated token/secret variables are not forwarded. Do not include secrets in
audit inputs.

Authoritative runs accept a repo under `SANEAPPS_ROOT` (default `~/SaneApps`),
a regular current-user bundle inside that repo or the mode-0700
`/tmp/saneprocess-gpt-audit-inputs` staging root, and prompts only from the
installed `~/.codex/skills/{audit,critic}/prompts` roots. Empty, oversized,
symlinked, or duplicate-content inputs are rejected. Outputs are limited to
repo `outputs/` or `/tmp/saneprocess-gpt-audit-receipts`; the report must be a
direct child of the selected mode-0700 output directory.

**Usage:**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/python3 /Users/stephansmac/SaneApps/infra/SaneProcess/scripts/automation/gpt_audit.py \
  --title "Docs Audit" \
  --repo /Users/stephansmac/SaneApps/infra/SaneProcess \
  --bundle /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit-inputs/audit_bundle.txt \
  --prompts-dir /Users/stephansmac/.codex/skills/audit/prompts \
  --out-dir /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/docs \
  --report /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/docs/summary.md \
  --max-workers 4

# Diagnostic partial quorum: always non-authoritative, returns nonzero,
# and never emits CODEX_FANOUT_RECEIPT.
/Applications/Xcode.app/Contents/Developer/usr/bin/python3 /Users/stephansmac/SaneApps/infra/SaneProcess/scripts/automation/gpt_audit.py \
  --repo /Users/stephansmac/SaneApps/infra/SaneProcess \
  --bundle /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit-inputs/audit_bundle.txt \
  --prompts-dir /Users/stephansmac/.codex/skills/audit/prompts \
  --out-dir /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/partial \
  --report /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/partial/summary.md \
  --required-success 3 --allow-partial

# Explicit API fallback (requires OPENAI_API_KEY)
/Applications/Xcode.app/Contents/Developer/usr/bin/python3 /Users/stephansmac/SaneApps/infra/SaneProcess/scripts/automation/gpt_audit.py --backend responses-api \
  --repo /Users/stephansmac/SaneApps/infra/SaneProcess \
  --bundle /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit-inputs/audit_bundle.txt \
  --prompts-dir /Users/stephansmac/.codex/skills/audit/prompts \
  --out-dir /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/api \
  --report /Users/stephansmac/SaneApps/infra/SaneProcess/outputs/gpt-audit/api/summary.md
```

Create the bundle as a regular UTF-8 file at the shown repo-owned input path
before running an example. The absolute Python launcher and script paths are
part of the authoritative hook command binding; do not replace them with
`python3`, a repo-local launcher, `~`, or shell-variable aliases.

**What it does:**
1. Loads all perspective prompts from a prompt directory.
2. Runs every prompt as a separate
   `codex exec --ephemeral --ignore-user-config -s read-only` lane, with
   configurable concurrency and no total perspective cap. The Responses API
   remains available through `--backend responses-api`.
3. Writes one raw markdown file per perspective.
4. Runs a synthesis pass to merge duplicates and contradictions.
5. Atomically writes a consolidated markdown report plus a JSON manifest with
   per-lane SHA-256, unique perspective/artifact identity, runner path, full
   count, isolation, freshness, and synthesis evidence. By default every prompt
   must succeed. It prints `CODEX_FANOUT_RECEIPT=<absolute manifest path>` only
   for a full-quorum successful synthesis using the repo-owned runner and a
   fixed absolute, root-owned Python launcher and a canonical signed Codex
   installation. Authoritative runs ignore inherited
   `PATH`: Codex must satisfy OpenAI Team ID `2DC432GLL2` and its designated
   code requirement, and is selected only from the standalone install under
   `~/.codex/packages/standalone/current/` or the ChatGPT app resource.
   `--codex-bin` is rejected for authoritative runs. Partial, failed, or
   overridden runs return nonzero without a receipt.

The receipt is concrete local provenance, not cryptographic attestation or a
security boundary against malicious code already running as the same user. An
agent with workspace write access can forge local files. The hook therefore
validates the canonical runner realpath, internal counts, isolation flags,
input hashes, the trusted Python and Codex realpaths and binary hashes, invocation
nonce/command binding, unique names
and artifact realpaths, report/artifact hashes, freshness, and successful
authoritative synthesis before counting coverage.

**Status:** `/audit` now uses GPT subagents as the standard path. Use `gpt_audit.py` only when
you explicitly need a scripted fallback.

### tool_discovery_receipt.rb

Standard proof command for “do I already have this?” before using a workaround or adding tooling.

**Usage:**
```bash
ruby tool_discovery_receipt.rb --query "missing screenshot diff tool"
ruby tool_discovery_receipt.rb --query "workaround for docs audit" --json
```

**What it does:**
1. Checks the global skills registry.
2. Searches installed global skills for matching workflows.
3. Searches local scripts, hooks, templates, and core docs.
4. Runs `SaneMaster.rb doctor`.
5. Runs `validation_report.rb --json`.
6. Writes JSON and markdown receipts to `outputs/tool-discovery/`.

### listing-actions.py

Build the current SaneBar listing/setup tracker from inbox history and write it to Excel.

**Usage:**
```bash
python3 scripts/automation/listing-actions.py
python3 scripts/automation/listing-actions.py --json
python3 scripts/automation/listing-actions.py --xlsx /tmp/sanebar_listings.xlsx
```

**What it does:**
1. Fetches inbox history from the email API with the cached/keychain-backed API key.
2. Classifies known listing/setup vendors like SaaSworthy, SourceForge, Gartner Digital Markets, StartupSubmit, and related directory flows.
3. Falls back to a generic listing/setup heuristic for new unknown senders so new action emails still surface before a dedicated rule exists.
4. Writes a `Current Actions` sheet with `Needs action / Optional / Monitor` rows.
5. Writes an `Email History` sheet so the inbox evidence stays attached to each action.
6. Saves a dated workbook plus `outputs/listing_actions/latest.xlsx`.
7. Feeds the same workbook/JSON data into the nightly `morning-report.sh` summary and the `sane-status-crossref.sh` status runner.

**Canonical path:** prefer `ruby scripts/SaneMaster.rb listing_actions` from the repo root.

### hosted-file-actions.py

Build the current Lemon Squeezy hosted-file dashboard tracker from live appcast + store API data.

**Usage:**
```bash
python3 scripts/automation/hosted-file-actions.py
python3 scripts/automation/hosted-file-actions.py --json
python3 scripts/automation/hosted-file-actions.py --xlsx /tmp/hosted_file_actions.xlsx
```

**What it does:**
1. Fetches the current SaneApps product/variant/file snapshot from the Lemon Squeezy API.
2. Fetches the live appcast version + dist ZIP URL for each direct-download app.
3. Flags version drift where the published hosted file is older than the live appcast.
4. Flags cleanup drift where the latest hosted file exists but old ZIPs are still published beside it.
5. Writes a `Current Actions` sheet with the exact product ID, variant ID, dashboard URL, dist ZIP to upload, and old hosted ZIPs to remove.
6. Writes a `Live Snapshot` sheet so the full current state is visible even when only some apps drift.
7. Audits `~/Desktop/LemonSqueezy-Uploads` and flags stale or missing latest ZIPs so dashboard uploads start from a clean file picker.
8. Saves a dated workbook plus `outputs/hosted_file_actions/latest.xlsx`.

**Upload staging rule:** `~/Desktop/LemonSqueezy-Uploads` should contain only the latest ZIP for each direct-download app. Move older app ZIPs to Trash before opening Lemon Squeezy; do not leave old release files in the picker.

**Dashboard cleanup rule:** after replacing a product file in Lemon Squeezy, delete or unpublish old hosted ZIPs for that variant so customers see only the current release. Rerun the tracker and keep the evidence with the release notes.

**Canonical path:** prefer `ruby ../SaneMaster.rb hosted_file_actions` from the repo root.

### morning-report.sh

Daily development status report across all projects.

**Usage:**
```bash
morning-report.sh
```

### Production Codex heartbeats

Recurring Codex automation is Mini-owned and intentionally limited to two
lanes: SaneApps Operations at 08:30 Mini local time and SaneCite Growth at
10:00. Both append to live pinned Mini-local tasks. ACTIVE records must pass
`sane_automation_guard.rb --validate ~/.codex/automations`, which verifies the
task database row, session rollout identity/cwd containment, and GPT-5.5+
reasoning profile. Use `automation_update` on the Mini for every production
automation change; sync/reconcile scripts never mutate automation records.

### sync-codex-mini.sh

Sync the active Codex config, skill registry, skills, repo-owned helpers, and control-plane files from MacBook to Mini.

**Usage:**
```bash
# Sync to default host "mini" without interrupting Codex on Mini
ruby scripts/SaneMaster.rb sync_mini

# Explicit maintenance-only reload after confirming no active Mini work
ruby scripts/SaneMaster.rb sync_mini mini --restart
```

**What it does:**
1. Rewrites local home and Node paths in a temporary Mini config copy.
2. Syncs the active Codex skill registry (`~/.codex/SKILLS_REGISTRY.md`), `~/.codex/skills/`, and shared `~/.agents/skills/` to Mini.
3. Installs the repo-owned Codex control-plane helpers from `scripts/codex-bin/` into local `~/.codex/bin/` and mirrors them to Mini.
4. Syncs critical control-plane scripts (`check-inbox.sh`, `git-sync-safe.sh`, hooks, validation/reporting scripts).
5. Points Mini AgentMemory at the Mini-owned loopback service; file-backed memories are handled by the separate conflict-preserving sync lane.
6. Verifies Air↔Mini SHA-256 parity for control-plane files and helpers plus dry-run `rsync` parity for skills.
7. Preserves the running Mini Codex process by default; an explicit `--restart` is required to reload it.

It never reads or writes Codex automation TOML or SQLite state. Production automation changes must use `automation_update` on the Mini; the Air remains free of recurring Codex automation records.

### start-workday.sh

One-command MacBook workflow start for control-plane parity, repo reconciliation, and current reports.

**Usage:**
```bash
start-workday.sh
start-workday.sh mini --no-open
```

**What it does:**
1. Syncs the Codex control-plane profile to Mini without inspecting or changing automation state.
2. Runs the canonical Air↔Mini reconcile wrapper (`reconcile-air-mini.sh mini --no-sync-control-plane`).
3. Pulls latest Mini morning/nightly reports locally.
4. Leaves automation inspection and mutation to Codex Scheduled and `automation_update`.
5. Runs inbox summary locally.
6. Opens reports and Codex app (unless `--no-open`).

### reconcile-air-mini.sh

Canonical cross-machine repo reconcile for the local Mac plus Mini.

**Usage:**
```bash
reconcile-air-mini.sh
reconcile-air-mini.sh mini --quiet
reconcile-air-mini.sh mini --sync-control-plane
```

**What it does:**
1. Leaves control-plane sync off by default; `--sync-control-plane` is an explicit operator action.
2. Runs `git-sync-safe.sh` on the Mini first.
3. Runs `git-sync-safe.sh --peer mini` locally.
4. Fails loudly on dirty canonical repos so work is reconciled explicitly.
5. Pulls secret-filtered dirty-work snapshots from the Mini without applying them.

### git-sync-safe.sh

Nightly safe Git sync to avoid duplicate work between machines.

**Usage:**
```bash
git-sync-safe.sh

# Compare local repos against Mini for branch/head/dirty drift
git-sync-safe.sh --peer mini

# Legacy manual recovery only: auto-stash dirty canonical repos before syncing.
# This is disabled unless SANEPROCESS_ALLOW_AUTO_STASH=1 is set.
SANEPROCESS_ALLOW_AUTO_STASH=1 git-sync-safe.sh --reconcile-dirty

# Legacy manual recovery with Mini parity check.
SANEPROCESS_ALLOW_AUTO_STASH=1 git-sync-safe.sh --peer mini --reconcile-dirty

# Allow dirty working trees (warning-only mode)
git-sync-safe.sh --allow-dirty

# Preserve dirty work only; do not fetch, pull, push, stash, or mutate a worktree
git-sync-safe.sh --snapshot-only
```

**What it does:**
1. Scans current SaneApps repos (`apps/*`, `infra/SaneProcess`, and any still-present legacy repo).
2. Skips known transient repo clones such as release/preview/worktree scratch dirs.
3. Prunes untracked Finder and patch residue (`.DS_Store`, `*.orig`, `*.rej`) before status checks.
4. Fetches from origin.
5. Fast-forward pulls only when clean.
6. Auto-pushes only clean `main/master` ahead commits.
7. Creates fingerprinted, secret-filtered snapshots for dirty trees without changing them.
8. Flags dirty trees as issues by default. `--reconcile-dirty` is a legacy manual recovery path and refuses to run unless `SANEPROCESS_ALLOW_AUTO_STASH=1` is set.
9. Optional peer mode (`--peer <host>`) checks branch/head/dirty parity over SSH.

### install-repo-reconcile-agent.sh

Legacy installer for the unattended Air↔Mini repo reconcile agent.

**Usage:**
```bash
install-repo-reconcile-agent.sh
```

**What it does:**
This agent stays disabled while any canonical app worktree is dirty. GitHub
`main` is the committed-code source of truth; the memory-sync agent provides
non-clobbering dirty-work backup snapshots. Use this installer only after an
operator confirms every participating repo is clean and deliberately wants the
twice-daily fast-forward reconcile lane.

### install-memory-sync-agent.sh

Install the Air-owned, restart-durable memory and dirty-snapshot recurrence.

**Usage:**
```bash
install-memory-sync-agent.sh
```

**What it does:**
1. Installs `~/Library/LaunchAgents/com.saneapps.memory-sync.plist`.
2. Runs at login and every 15 minutes.
3. Uses `sync-memory-mini.sh` for locked, backup-first, no-delete, conflict-preserving Claude/Serena/Codex parity.
4. Triggers Mini snapshot-only preservation and pulls the snapshots to the Air without applying them.

### website-consistency-check.sh

Manual static site consistency pass for SaneApps marketing/docs surfaces.

**Usage:**
```bash
website-consistency-check.sh
```

**What it does:**
1. Checks product index pages and guide hubs for required CTA and support copy.
2. Verifies expected crypto-payment copy still exists where required.
3. Writes a TSV report plus summary markdown under `outputs/website-consistency-<date>/`.
4. Exits nonzero on any failed consistency check.

Use this after website copy or release-page changes. It is a manual audit helper, not part of the nightly reconcile path.

### sane-status-crossref.sh

One-command cross-reference run for operational and business status. The default
is the full status surface; fast mode is an explicitly partial intake view.

**Usage:**
```bash
ruby scripts/SaneMaster.rb status          # Default: full
ruby scripts/SaneMaster.rb status --full   # Explicit full status
ruby scripts/SaneMaster.rb status --fast   # Inbox + key worktrees only
```

**Modes:**
1. `--full` checks key worktrees, sales, inbox, listing actions, hosted-file
   dashboard actions, Setapp, outreach, GitHub notifications, open issues and
   PRs, and comment/review activity.
2. `--fast` checks active inbox actions and key worktrees. It always labels the
   result partial and does not claim release or distribution readiness.

Status is read-only: an unavailable portal lane such as Setapp is reported as
incomplete and does not launch browser automation.

**Exit contract:**
- `0`: every lane selected by the chosen mode ran. Reported business or release
  blockers still require review.
- `3`: one or more selected lanes were unavailable, so status coverage is
  incomplete. This applies to both full and fast mode.
- `2`: invalid command-line arguments.

GitHub credentials are loaded by the focused status helper and exposed only to
a verified, absolute GitHub CLI child with a fixed minimal `PATH`.

### sane-support-kickoff.sh

Quick support-workflow starter for support triage.

**Usage:**
```bash
sane-support-kickoff.sh
```

**What it does:**
1. Runs the inbox report.
2. Reprints `NEEDS REPLY` items for fast intake and prioritization.

## Output Structure

```
outputs/
├── audit/
│   ├── SaneBar-20260204-120000.md
│   ├── SaneClip-20260204-120100.md
│   └── ...
└── relnotes/
    ├── SaneBar-1.2.0.md
    ├── SaneClip-2.1.0.md
    └── ...
```

## Tips

- Use `/audit` for the real GPT subagent audit path
