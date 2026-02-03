# SaneProcess Development Guide

> **Project Docs:** [CLAUDE.md](CLAUDE.md) · [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SESSION_HANDOFF](SESSION_HANDOFF.md)
>
> You are reading **DEVELOPMENT.md** — how to build, test, and contribute.
> For system design and decisions, see [ARCHITECTURE](ARCHITECTURE.md). For AI instructions, see [CLAUDE](CLAUDE.md).

Ruby hooks for Claude Code enforcement. Source of truth for all Sane projects.

---

## Sane Philosophy

```
┌─────────────────────────────────────────────────────┐
│           BEFORE YOU SHIP, ASK:                     │
│                                                     │
│  1. Does this REDUCE fear or create it?             │
│  2. Power: Does user have control?                  │
│  3. Love: Does this help people?                    │
│  4. Sound Mind: Is this clear and calm?             │
│                                                     │
│  Grandma test: Would her life be better?            │
│                                                     │
│  "Not fear, but power, love, sound mind"            │
│  — 2 Timothy 1:7                                    │
└─────────────────────────────────────────────────────┘
```

→ Full philosophy: `~/SaneApps/meta/Brand/NORTH_STAR.md`

---

## Quick Start

```bash
ruby scripts/qa.rb                    # Full QA check
ruby scripts/hooks/test/tier_tests.rb # Run hook tests
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project sync
```

## The Rules: Scientific Method for AI

These rules enforce the scientific method. Not optional guidelines - **the hooks block you until you comply.**

### Core Principles (Scientific Method)

| # | Rule | Scientific Method | What Hooks Do |
|---|------|-------------------|---------------|
| #2 | **VERIFY BEFORE YOU TRY** | Observe before hypothesizing | Blocks edits until 4 research categories done |
| #3 | **TWO STRIKES? INVESTIGATE** | Reject failed hypothesis | Circuit breaker trips at 3 failures |
| #4 | **TESTS MUST PASS** | Experimental validation | Tracks test results, blocks on red |

**This is the core.** Guessing is not science. Verify → Hypothesize → Test → Learn.

### Supporting Rules (Code Quality)

| # | Rule | Purpose |
|---|------|---------|
| #0 | **NAME RULE FIRST** | State which rule applies before acting |
| #1 | **STAY IN LANE** | No edits outside project scope |
| #5 | **THEIR HOUSE THEIR RULES** | Use project conventions, not preferences |
| #7 | **NO TEST NO REST** | No tautologies (`#expect(true)`) |
| #8 | **BUG FOUND? WRITE DOWN** | Document bugs in memory |
| #9 | **USE GENERATORS** | Use project scaffolding tools |
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

## macOS UI Testing

Two different tools for two different targets:

| Tool | Target | Use For |
|------|--------|---------|
| **XcodeBuildMCP** | iOS Simulator | Build, test, simulator UI automation |
| **macos-automator** | Real macOS Desktop | Click menu bars, test actual running apps |

**For menu bar apps (SaneBar):** Use `macos-automator` to interact with real UI - XcodeBuildMCP's UI tools only work in simulator.

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
| `verify_mocks` | Check mock sync status |

**Examples** and **Aliases** are listed in `./scripts/SaneMaster.rb help` — keep them current with the CLI.

## Testing

```bash
ruby scripts/hooks/test/tier_tests.rb           # All tests
ruby scripts/hooks/test/tier_tests.rb --tier easy    # Easy tier
ruby scripts/hooks/test/tier_tests.rb --tier hard    # Hard tier
ruby scripts/hooks/test/tier_tests.rb --tier villain # Villain tier
```

## Cross-Project Sync

SaneProcess hooks sync to all SaneApps: SaneBar, SaneClick, SaneClip, SaneVideo, SaneSync, SaneHosts, SaneAI

```bash
# Check sync status
ruby scripts/sync_check.rb ~/SaneApps/apps/SaneBar

# Sync hooks after changes
for app in SaneBar SaneClick SaneClip SaneVideo SaneSync SaneHosts SaneAI; do
  rsync -av scripts/hooks/ ~/SaneApps/apps/$app/scripts/hooks/
done
```

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
- [ ] `Scripts/hooks/` and `Scripts/sanemaster/` exist
- [ ] `.claude/settings.json` is valid JSON
- [ ] `.mcp.json` is valid JSON
- [ ] Syntax validation: `for f in Scripts/hooks/*.rb; do ruby -c "$f"; done`
- [ ] Hook registration: `grep -c "Scripts/hooks" .claude/settings.json` (>= 13)
- [ ] SaneMaster: `./Scripts/SaneMaster.rb --help` shows usage

### Regression Tests

```bash
ruby scripts/hooks/test/hook_test.rb   # 28 tests, 0 failures
```

### Full QA

```bash
./scripts/qa.rb   # All checks passed
```

---

## Lemon Squeezy Product Setup

### Store Settings

- **Store Name:** Sane Labs
- **Store URL:** `sane.lemonsqueezy.com`
- **Brand Color:** `#10B981` (emerald green)

### Products

| Product | Type | Price | Slug |
|---------|------|-------|------|
| SaneProcess | Digital Download | $29 | `saneprocess` |
| SaneBar | macOS App | $12 | `sanebar` |
| SaneVideo | macOS App | $39 | `sanevideo` |
| Sane Suite Bundle | Bundle (all 3) | $59 (save $21) | `suite` |

### Discount Codes

| Code | Discount | Use Case |
|------|----------|----------|
| `LAUNCH` | 20% off | Launch week |
| `TWITTER` | 15% off | Social followers |
| `GITHUB` | 15% off | GitHub contributors |
| `BUNDLE10` | Extra 10% off bundle | Push to bundle |

### Checkout Settings

- **Tax:** LemonSqueezy handles VAT/GST automatically
- **Receipts:** Email receipts enabled
- **License Keys:** Enabled for apps (future update gating)

### Payment Links

```
https://sane.lemonsqueezy.com/buy/saneprocess
https://sane.lemonsqueezy.com/buy/sanebar
https://sane.lemonsqueezy.com/buy/sanevideo
https://sane.lemonsqueezy.com/buy/suite
```

### API Access

```bash
# Fetch orders (keychain-stored API key)
KEY=$(security find-generic-password -s lemonsqueezy -a api_key -w)
curl -s "https://api.lemonsqueezy.com/v1/orders?filter[store_id]=270691" \
  -H "Authorization: Bearer $KEY" -H "Accept: application/vnd.api+json"
```
