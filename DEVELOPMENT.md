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

## Codex Compatibility

Codex does not expose native Claude-style hook events. For consistent behavior across Claude and Codex:

- Claude path: Ruby hooks in `scripts/hooks/*.rb`.
- Codex path: critical email safety is enforced in shared runtime paths:
  - `~/SaneApps/infra/scripts/check-inbox.sh` (`require_email_send_approval`)
  - `scripts/hooks/sane_curl_guard.sh` via `~/.local/bin/curl` wrapper

Run `ruby scripts/SaneMaster.rb system_check` to verify both Claude hooks and Codex guard wiring.

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
| `test_mode` | Kill → Build → Launch → Logs |
| `doctor` | Environment health check |
| `export` | Export code/docs (PDF/MD) |
| `debug` | Debugging helpers (logs, crashes, diagnose) |
| `env` | Environment and setup helpers |

### Verification helpers

| Command | Purpose |
|---------|---------|
| `verify_api <API> [Framework]` | Verify SDK API exists |
| `fix_mocks` | Check and fix mock sync status |

**Examples** and **Aliases** are listed in `./scripts/SaneMaster.rb help` — keep them current with the CLI.

## Testing

```bash
ruby scripts/hooks/test/tier_tests.rb           # All tests
ruby scripts/hooks/test/tier_tests.rb --tier easy    # Easy tier
ruby scripts/hooks/test/tier_tests.rb --tier hard    # Hard tier
ruby scripts/hooks/test/tier_tests.rb --tier villain # Villain tier
```

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
ruby scripts/hooks/test/tier_tests.rb  # Authoritative test suite (175 tests)
```

### Full QA

```bash
./scripts/qa.rb   # All checks passed
```

---
