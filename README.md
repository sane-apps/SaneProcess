# SaneProcess

> **Project Docs:** [CLAUDE.md](CLAUDE.md) · [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SESSION_HANDOFF](SESSION_HANDOFF.md)
>
> You are reading **README.md** — what SaneProcess is and how to use it.
> For contributing, see [DEVELOPMENT](DEVELOPMENT.md). For system internals, see [ARCHITECTURE](ARCHITECTURE.md).

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
| **4 Enforcement Hooks** | Block edits until research is done |
| **Circuit Breaker** | Auto-stops after 3 same errors |
| **16 Golden Rules** | Memorable, enforceable discipline |
| **403 Tests** | 167 tier tests + 236 self-tests, including 42 from real Claude failures |

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

## SaneMaster CLI Reference

Your project's command center. Run `./scripts/SaneMaster.rb help` for full list.

### Build & Test

| Command | What It Does |
|---------|--------------|
| `verify [--ui] [--clean]` | Build and run tests |
| `clean [--nuclear]` | Wipe build cache |
| `lint` | Run SwiftLint with auto-fix |
| `audit` | Scan for missing accessibility IDs |
| `qa` | Full QA suite (hooks, docs, URLs, tests) |

### Debug & Launch

| Command | What It Does |
|---------|--------------|
| `test_mode` / `tm` | Kill → Build → Launch → Logs (one command) |
| `launch` | Launch the app |
| `logs [--follow]` | Show application logs |
| `crashes [--recent]` | Analyze crash reports |
| `diagnose [path]` | Analyze .xcresult bundle |

### Code Generation

| Command | What It Does |
|---------|--------------|
| `gen_test` | Generate test file from template |
| `gen_mock` | Generate mocks using Mockolo |
| `gen_assets` | Generate test video assets |
| `template [save\|apply\|list]` | Manage configuration templates |

### Static Analysis

| Command | What It Does |
|---------|--------------|
| `verify_api <API> [Framework]` | Verify API exists in SDK before using |
| `dead_code` | Find unused code (Periphery) |
| `deprecations` | Scan for deprecated API usage |
| `swift6` | Verify Swift 6 concurrency compliance |
| `test_scan [-v]` | Find tautologies and hardcoded values in tests |
| `check_docs` | Check docs are in sync with code |
| `check_binary` | Audit binary for security issues |

### Memory & Circuit Breaker

Cross-session memory via MCP integration:

| Command | What It Does |
|---------|--------------|
| `mc` | Show memory context (bugs, patterns, decisions) |
| `mr <type> <name>` | Record new entity to memory |
| `mp [--dry-run]` | Prune stale entities |
| `mh` | Memory health (entity count, token estimate) |
| `mcompact [--aggressive]` | Compact memory (trim verbose, dedupe) |
| `mcleanup` | Analyze memory, generate cleanup commands |

Circuit breaker control:

| Command | What It Does |
|---------|--------------|
| `reset_breaker` / `rb` | Reset circuit breaker (unblock tools) |
| `breaker_status` / `bs` | Show circuit breaker status |
| `breaker_errors` / `be` | Show recent failure messages |

### Session & SOP

| Command | What It Does |
|---------|--------------|
| `session_end` / `se` | End session with insight extraction |
| `saneloop <cmd>` | Native task loop (start\|status\|check\|complete) |
| `compliance` / `cr` | Generate compliance report |

### Environment

| Command | What It Does |
|---------|--------------|
| `doctor` | Full environment health check |
| `health` / `h` | Quick health check (< 100ms) |
| `meta` | Audit SaneMaster tooling itself |
| `bootstrap [--check-only]` | Full environment setup |
| `setup` | Install gems and dependencies |
| `versions` | Check all tool versions |
| `deps [--dot]` | Show dependency graph |
| `reset` | Reset TCC permissions |
| `restore` | Fix Xcode/Launch Services issues |

### Export

| Command | What It Does |
|---------|--------------|
| `export [--highlight]` | Export code to PDF |
| `md_export <file.md>` | Convert markdown to PDF |

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
| Global mutation | MCP memory delete | Research complete |
| External mutation | GitHub push | Research complete |

**Security:** State is HMAC-signed to prevent tampering.

---

## The 16 Golden Rules

```
#0  NAME THE RULE BEFORE YOU CODE
#1  STAY IN YOUR LANE (files in project only)
#2  VERIFY BEFORE YOU TRY (check docs first)
#3  TWO STRIKES? INVESTIGATE
#4  GREEN MEANS GO (tests must pass)
#5  THEIR HOUSE, THEIR RULES (use project tools)
#6  BUILD, KILL, LAUNCH, LOG
#7  NO TEST? NO REST
#8  BUG FOUND? WRITE IT DOWN
#9  NEW FILE? GEN THAT PILE
#10 FIVE HUNDRED'S FINE, EIGHT'S THE LINE
#11 TOOL BROKE? FIX THE YOKE
#12 TALK WHILE I WALK (stay responsive)
#13 CONTEXT OR CHAOS (maintain CLAUDE.md)
#14 PROMPT LIKE A PRO (specific prompts)
#15 REVIEW BEFORE YOU SHIP (self-review)
```

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

403 tests across tier tests and self-tests:

**Tier Tests (167):**

| Tier | Count | Purpose |
|------|-------|---------|
| Easy | 61 | Basic functionality |
| Hard | 53 | Edge cases |
| Villain | 48 | Adversarial bypass attempts |
| Integration | 5 | End-to-end hook chains |

**Self-Tests (236):**

| Hook | Count | Purpose |
|------|-------|---------|
| saneprompt | 176 | Prompt classification |
| sanetrack | 23 | Failure tracking, doom loops |
| sanetools | 20 | Research gate, blocking |
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
