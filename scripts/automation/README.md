# Automation Scripts

Scripts for automating development tasks across SaneApps projects using the `nv` CLI.

## Prerequisites

- `nv` CLI installed at `/Users/sj/.local/bin/nv`
- Git repositories with tags (for release notes)
- SaneApps projects at `~/SaneApps/apps/`

## Scripts

### nv-audit.sh

Multi-app codebase audit using LLM review.

**Usage:**
```bash
# Audit all apps
nv-audit.sh

# Audit specific app
nv-audit.sh SaneBar

# Audit with different model
nv-audit.sh -m claude-3-5-sonnet-20250514

# Auto-detect current project
cd ~/SaneApps/apps/SaneBar && nv-audit.sh
```

**What it does:**
1. Scans all .swift files in the app's source directory
2. Uses `nv --sweep` to review for bugs, security issues, deprecated APIs, memory leaks, and concurrency issues
3. Generates severity-tagged findings (HIGH/MED/LOW)
4. Saves results to `outputs/audit/{app}-{timestamp}.md`
5. Prints summary with counts per severity

**Output location:** `~/SaneApps/infra/SaneProcess/outputs/audit/`

### nv-relnotes.sh

Generate user-facing release notes from git history using LLM council.

**Usage:**
```bash
# Generate for current directory
cd ~/SaneApps/apps/SaneBar && nv-relnotes.sh

# Generate for specific repo
nv-relnotes.sh ~/SaneApps/apps/SaneClip
```

**What it does:**
1. Finds the two most recent git tags (or last tag + HEAD)
2. Extracts commit log and diff stats between tags
3. Queries 3 LLMs via `nv --council` for user-facing release notes
4. Shows all 3 responses for comparison
5. Saves full output to `outputs/relnotes/{repo}-{tag}.md`

**Output location:** `~/SaneApps/infra/SaneProcess/outputs/relnotes/`

### nv-buildlog.sh

Analyze Xcode build errors using LLM.

**Usage:**
```bash
# Analyze most recent build log
nv-buildlog.sh

# Analyze specific log file
nv-buildlog.sh /path/to/build.log
```

### nv-tests.sh

Analyze test failures using LLM.

**Usage:**
```bash
# Analyze most recent test results
nv-tests.sh

# Analyze specific test log
nv-tests.sh /path/to/test-results.xcresult
```

### morning-report.sh

Daily development status report across all projects.

**Usage:**
```bash
morning-report.sh
```

### sync-codex-mini.sh

Sync SaneOps Codex automation config from MacBook to Mini and enforce runner roles.

**Usage:**
```bash
# Sync to default host "mini" and restart Codex on Mini
sync-codex-mini.sh

# Sync quietly without restarting Codex
sync-codex-mini.sh mini --quiet --no-restart
```

**What it does:**
1. Forces local Codex automations to paused (prevents duplicate runs).
2. Rewrites home paths for Mini and syncs automation TOML files.
3. Syncs critical control-plane scripts (`check-inbox.sh`, `git-sync-safe.sh`, hooks, validation/reporting scripts).
4. Updates Mini automation SQLite rows from TOML so prompt/status changes apply immediately.
5. Verifies Air↔Mini SHA-256 parity for all synced control-plane files.
6. Sets Mini AM run active and PM run paused.
7. Optionally restarts Codex on Mini so scheduler reloads immediately.

### start-workday.sh

One-command MacBook workflow start while Mini runs unattended.

**Usage:**
```bash
start-workday.sh
start-workday.sh mini --no-open
```

**What it does:**
1. Syncs automation config to Mini.
2. Runs Air↔Mini git drift check (`git-sync-safe.sh --peer mini`) as advisory.
3. Pulls latest Mini morning/nightly reports locally.
4. Shows Mini automation scheduler status.
5. Runs inbox summary locally.
6. Opens reports and Codex app (unless `--no-open`).

### git-sync-safe.sh

Nightly safe Git sync to avoid duplicate work between machines.

**Usage:**
```bash
git-sync-safe.sh

# Compare local repos against Mini for branch/head/dirty drift
git-sync-safe.sh --peer mini

# Allow dirty working trees (warning-only mode)
git-sync-safe.sh --allow-dirty
```

**What it does:**
1. Scans SaneApps repos (`apps/*`, `SaneAI`, `infra/SaneProcess`).
2. Fetches from origin.
3. Fast-forward pulls only when clean.
4. Auto-pushes only clean `main/master` ahead commits.
5. Flags dirty trees as issues by default (prevents false “clean” states).
6. Optional peer mode (`--peer <host>`) checks branch/head/dirty parity over SSH.

## Models

Default models used:
- **nv-audit.sh**: `kimi-fast` (fast, free, decent quality)
- **nv-relnotes.sh**: council mode (queries 3 models automatically)

Override with `-m MODEL` flag where supported.

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

- Run `nv-audit.sh` before releases to catch issues
- Run `nv-relnotes.sh` after tagging to generate changelog
- Use `-m claude-3-5-sonnet-20250514` for higher quality audits (costs tokens)
- Review all council responses in `nv-relnotes.sh` — pick the best one manually
