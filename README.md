# SaneProcess

> **Project Docs:** [CLAUDE_PUBLIC.md](CLAUDE_PUBLIC.md) · [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md)
>
> You are reading **README.md** — what SaneProcess is and how to use it.
> For contributing, see [DEVELOPMENT](DEVELOPMENT.md). For system internals, see [ARCHITECTURE](ARCHITECTURE.md).
>
> Note: Local/private docs (not in this repo) include `CLAUDE.md` and `SESSION_HANDOFF.md`.

**Battle-tested SOP enforcement for Claude Code.**

Stop AI doom loops. Ship reliable code.


---

## The Problem

Claude Code is powerful but undisciplined:
- Guesses the same broken fix 10 times
- Assumes APIs exist without checking
- Skips verification, forgets context
- Wastes 20+ minutes on preventable mistakes

## The Solution

SaneProcess enforces discipline through hooks that block bad behavior before it happens.

| Feature | What It Does |
|---------|--------------|
| **4 Enforcement Hooks** | Block unsafe actions until research is complete |
| **Circuit Breaker** | Auto-stops after repeated failures |
| **Golden Rules (16 total)** | Core + supporting + operational discipline |
| **Sensitive File Protection** | CI/CD, entitlements, build configs require confirmation |
| **Test Suite** | Tier tests + self-tests (run `ruby scripts/hooks/test/tier_tests.rb`) |

---

## Quick Start

**After purchase:**

```bash
# Install everything with one command
curl -sL https://raw.githubusercontent.com/sane-apps/SaneProcess/main/scripts/init.sh | bash
```

**Verify it's working:**

```bash
./scripts/SaneMaster.rb doctor    # Check environment
./scripts/SaneMaster.rb health    # Quick health check
```

**Your first workflow:**

```bash
./scripts/SaneMaster.rb verify    # Build + test
./scripts/SaneMaster.rb test_mode # Kill → Build → Launch → Logs
```

---

## Session Close (Default)

1. Confirm worktree is clean or intentionally staged
2. Update `SESSION_HANDOFF.md` (Done / Docs / SOP / Next)
3. Run the smallest relevant check:
   - Docs-only: `./scripts/SaneMaster.rb check_docs`
   - Code changes: `./scripts/SaneMaster.rb verify`
4. Append one SOP score line to `outputs/sop_ratings.csv`

**Run full `/docs-audit` only when needed:**
- New user-facing feature or behavior change
- README/website docs touched
- Release prep or public announcement
- Larger change sets where drift risk is higher

---

## What's Included

```
SaneProcess/
├── scripts/
│   ├── SaneMaster.rb          # CLI with 50+ commands (see below)
│   ├── hooks/                 # 4 enforcement hooks
│   │   ├── saneprompt.rb      # Analyzes intent, sets requirements
│   │   ├── sanetools.rb       # Blocks until research complete
│   │   ├── sanetrack.rb       # Tracks failures, trips breaker
│   │   └── sanestop.rb        # Ensures session summary
│   ├── qa.rb                  # Full QA suite
│   ├── sync_check.rb          # Cross-project drift detection
│   └── skill_loader.rb        # Load domain knowledge on demand
├── templates/                 # Project templates and checklists
├── skills/                    # Loadable domain knowledge
├── .claude/rules/             # Path-specific guidance
└── docs/                      # Full methodology (1,400+ lines)
```

---

## SaneMaster CLI (Quick)

Your command center. Full list: `./scripts/SaneMaster.rb help`.

```bash
./scripts/SaneMaster.rb verify        # Build + tests (use --ui for UI tests)
./scripts/SaneMaster.rb test_mode     # Kill → Build → Launch → Logs
./scripts/SaneMaster.rb doctor        # Environment health check
./scripts/SaneMaster.rb qa            # Full QA suite
./scripts/SaneMaster.rb check_docs    # Docs/tooling sync
```

---

## Hook Architecture

Four hooks handle all enforcement:

| Hook | When | What It Does |
|------|------|--------------|
| **saneprompt** | User sends message | Analyzes intent, sets research requirements |
| **sanetools** | Before tool runs | Blocks destructive ops until research complete |
| **sanetrack** | After tool runs | Tracks failures, updates circuit breaker |
| **sanestop** | Session ends | Ensures summary, extracts learnings |

### How Blocking Works

Tools are categorized by blast radius:

| Category | Examples | Blocked Until |
|----------|----------|---------------|
| Read-only | Read, Grep, search | Never blocked |
| Local mutation | Edit, Write | Research complete |
| Sensitive files | CI/CD, entitlements, build config | Confirmed once per file |
| External mutation | GitHub push | Research complete |

**Security:** State is HMAC-signed to prevent tampering (key in macOS Keychain, not file-readable). Inline script execution (`python -c`, `ruby -e`, `node -e`) blocked as bash mutations. Sensitive files (`.github/workflows/`, `.entitlements`, `Dockerfile`, `Fastfile`, `.xcconfig`, `.mcp.json`) require explicit confirmation before the first edit each session.

---

## The Golden Rules (16 total, numbered #0–#15)

**Source of truth:** `scripts/hooks/rule_tracker.rb` (used in enforcement logs).
**No conflicts:** Rules are complementary — if multiple apply, follow all. When in doubt, follow the stricter rule.

**Core (enforced by hooks):**
- #2 VERIFY, THEN TRY
- #3 TWO STRIKES? STOP AND CHECK
- #4 GREEN MEANS GO

**Supporting (enforced by hooks):**
- #0 NAME IT BEFORE YOU TAME IT
- #1 STAY IN LANE, NO PAIN
- #5 HOUSE RULES, USE TOOLS
- #7 NO TEST? NO REST
- #8 BUG FOUND? WRITE IT DOWN
- #9 NEW FILE? GEN THE PILE
- #10 FIVE HUNDRED'S FINE, EIGHT'S THE LINE

**Operational (expected every session):**
- #6 BUILD, KILL, LAUNCH, LOG
- #11 TOOL BROKE? FIX THE YOKE
- #12 TALK WHILE I WALK
- #13 CONTEXT OR CHAOS
- #14 PROMPT LIKE A PRO
- #15 REVIEW BEFORE YOU SHIP

---

## Templates

Pre-built templates in `templates/`:

| Template | Purpose |
|----------|---------|
| `NEW_PROJECT_TEMPLATE.md` | CLAUDE.md for new projects |
| `FULL_PROJECT_BOOTSTRAP.md` | Complete project setup guide |
| `FOUNDER_CHECKLIST.md` | Pre-launch checklist |
| `RESEARCH-TEMPLATE.md` | Structured research format |
| `RESEARCH-INDEX.md` | Track all research |
| `state-machine-audit.md` | 13-section state machine audit |

---

## Skills System

Load domain knowledge only when needed:

```bash
./scripts/skill_loader.rb list              # See available skills
./scripts/skill_loader.rb load swift-concurrency
./scripts/skill_loader.rb status            # See what's loaded
./scripts/skill_loader.rb unload --all      # Clear all
```

**Available skills:**
- `swift-concurrency` - Actor isolation, Sendable, async/await
- `swiftui-performance` - View optimization, lazy loading
- `crash-analysis` - Symbolication, crash report analysis

---

## Automation Scripts

```bash
ruby scripts/qa.rb                    # Full QA (hooks, docs, URLs, tests)
ruby scripts/validation_report.rb     # Is SaneProcess actually working? (run daily)
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project drift detection
ruby scripts/memory_audit.rb          # Find unfixed bugs in memory
ruby scripts/version_bump.rb 2.3      # Bump version everywhere
ruby scripts/license_gen.rb           # Generate license key
ruby scripts/contamination_check.rb   # Check for leaked secrets
```

### Validation Report

Answers the hard question: **Is SaneProcess making us 10x more productive, or is it BS?**

```bash
ruby scripts/validation_report.rb     # Text report
ruby scripts/validation_report.rb --json  # JSON for tracking
```

Checks:
- Q1: Are blocks correct? (users not constantly overriding)
- Q2: Are doom loops caught? (breaker trips on repeat errors)
- Q3: Is self-rating honest? (not rubber-stamping 8/10)
- Q4: Do sessions end with passing tests?
- Q5: Is the trend improving over time?

Requires 30+ data points per metric for statistical significance. Run daily.

---

## Test Coverage

429 tests across tier tests and self-tests:

**Tier Tests (175):**

| Tier | Count | Purpose |
|------|-------|---------|
| Easy | 61 | Basic functionality + integration |
| Hard | 55 | Edge cases |
| Villain | 59 | Adversarial bypass attempts |

**Self-Tests (254):**

| Hook | Count | Purpose |
|------|-------|---------|
| saneprompt | 176 | Prompt classification |
| sanetrack | 23 | Failure tracking, doom loops |
| sanetools | 38 | Research gate, blocking, sensitive files |
| sanestop | 17 | Session metrics, validation |

Run tests:
```bash
ruby scripts/hooks/test/tier_tests.rb
```

---

## Troubleshooting

### "BLOCKED: Research incomplete"

The hook is working correctly. Complete all 4 research categories:
1. **docs** — Verify APIs exist (apple-docs, context7)
2. **web** — Search for current best practices (WebSearch)
3. **github** — Find external examples (GitHub search)
4. **local** — Check existing codebase (Read, Grep, Glob)

Run `./scripts/SaneMaster.rb reset_breaker` if stuck.

### Circuit breaker tripped

After 3 same errors, tools get blocked. This prevents token burn.

```bash
./scripts/SaneMaster.rb breaker_status  # See what's wrong
./scripts/SaneMaster.rb breaker_errors  # See error messages
./scripts/SaneMaster.rb reset_breaker   # Reset (after fixing issue)
```

### Hooks not firing

Check hook registration:
```bash
cat ~/.claude/settings.json | grep hooks
```

Re-run install:
```bash
./scripts/init.sh
```

### Ruby errors

```bash
./scripts/SaneMaster.rb setup  # Install dependencies
```

---

## Uninstall

Remove SaneProcess from a project:

```bash
# Remove hooks from Claude settings
# Edit ~/.claude/settings.json and remove hook entries

# Remove scripts
rm -rf scripts/hooks scripts/SaneMaster.rb scripts/sanemaster

# Remove rules
rm -rf .claude/rules

# Remove CLAUDE.md additions (manual)
```

Data stored:
- `.claude/state.json` - Hook state (HMAC-signed, auto-cleaned per session)
- `.claude/*.log` - Hook logs (rotated at 100KB)

---

## Status

**Internal testing** — Used across 7 SaneApps projects (SaneBar, SaneClick, SaneClip, SaneVideo, SaneSync, SaneHosts, SaneAI).

Public release pending validation.

---

## Domains & Infrastructure

| Asset | Status |
|-------|--------|
| saneprocess.com | Owned (Cloudflare) |
| GitHub repo | Private |
| LemonSqueezy | Account ready |

---

## License

MIT License. See [LICENSE](LICENSE)

---

*SaneProcess v2.4 - February 2026*
