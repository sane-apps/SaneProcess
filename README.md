# SaneProcess

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

SaneProcess enforces discipline through:

| Feature | What It Does |
|---------|--------------|
| **16 Golden Rules** | Memorable, enforceable rules for AI discipline |
| **Circuit Breaker** | Auto-stops after 3 same errors or 5 total failures |
| **Memory System** | Bug patterns persist across sessions |
| **Compliance Loop** | Enforced task completion with verification |
| **Self-Rating** | Accountability after every task |
| **AI Self-Review** | Mandatory code review before shipping (Rule #15) |

## What's Included

```
├── docs/
│   ├── SaneProcess.md          # Complete methodology (1,400+ lines)
│   └── PROJECT_TEMPLATE.md     # Customize for your project
├── scripts/
│   ├── init.sh                 # One-command project setup
│   ├── SaneMaster.rb           # CLI for build, verify, test-mode, memory
│   ├── sanemaster/             # 19 SaneMaster modules
│   ├── mac_context.rb          # Mac development knowledge injection
│   ├── skill_loader.rb         # Load/unload domain-specific knowledge
│   └── hooks/                  # 4 consolidated enforcement hooks
│       ├── saneprompt.rb       # UserPromptSubmit: Detects intent, sets requirements
│       ├── sanetools.rb        # PreToolUse: Blocks until research complete
│       ├── sanetrack.rb        # PostToolUse: Tracks failures, updates state
│       ├── sanestop.rb         # Stop: Ensures session summary before exit
│       ├── core/               # Shared infrastructure
│       │   ├── state_manager.rb    # Thread-safe state with HMAC signatures
│       │   └── hook_registry.rb    # Hook configuration and routing
│       └── test/               # 259 tests across 3 tiers
│           ├── tier_tests.rb       # 217 tests (Easy/Hard/Villain)
│           ├── real_failures_test.rb # 42 tests from actual Claude failures
│           └── recovery_test.rb    # End-to-end recovery verification
├── skills/                     # Modular expert knowledge
│   ├── swift-concurrency.md
│   ├── swiftui-performance.md
│   └── crash-analysis.md
└── .claude/rules/              # Pattern-based rules (auto-loaded)
    ├── views.md, tests.md, services.md
    ├── models.md, scripts.md, hooks.md
```

### Automation Scripts

Quality assurance and maintenance automation:

```bash
ruby scripts/qa.rb                    # Full product QA (hooks, docs, URLs, tests)
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project drift detection
ruby scripts/memory_audit.rb          # Find unfixed bugs in Memory MCP
ruby scripts/version_bump.rb 2.3      # Bump version across all files
ruby scripts/license_gen.rb           # Generate license key for customer
ruby scripts/license_gen.rb --validate SP-XXXX-...  # Validate a key
```

Pre-push hooks via `lefthook.yml` run QA automatically before each push.

### Skills System

Load only what you need for your current task:

```bash
ruby scripts/skill_loader.rb list                    # See available skills
ruby scripts/skill_loader.rb load swift-concurrency  # Load a skill
ruby scripts/skill_loader.rb status                  # See what's loaded
ruby scripts/skill_loader.rb unload --all            # Clear all skills
```

Skills add domain-specific knowledge to your context. Base context is 757 lines; with all skills loaded: ~1,350 lines.

### SaneMaster CLI

Your project's command center. Installed at `Scripts/SaneMaster.rb`:

```bash
./Scripts/SaneMaster.rb verify          # Build + test + lint
./Scripts/SaneMaster.rb test-mode       # Build, kill, launch, stream logs
./Scripts/SaneMaster.rb memory          # View memory graph health
./Scripts/SaneMaster.rb deps            # Show dependency versions
./Scripts/SaneMaster.rb export          # Export for LLM context
./Scripts/SaneMaster.rb diag            # Analyze crash reports
./Scripts/SaneMaster.rb bootstrap       # Reset session state
```

Key features:
- **verify**: Full build cycle with lint and test
- **test-mode**: Kill old processes, build, launch, tail logs
- **memory**: Check Memory MCP health (entities, token estimate, unfixed bugs)
- **deps**: Version audit of all dependencies (CocoaPods, SPM, Homebrew)
- **diag**: Analyze crash reports and diagnose issues
- **bootstrap**: Reset circuit breaker and session state

Run `./Scripts/SaneMaster.rb help` for all commands.

## Hook Architecture

Four consolidated hooks handle all enforcement:

| Hook | When | What It Does |
|------|------|--------------|
| **saneprompt** | UserPromptSubmit | Analyzes user intent, sets research requirements |
| **sanetools** | PreToolUse | Blocks destructive ops until research complete |
| **sanetrack** | PostToolUse | Tracks failures, updates circuit breaker |
| **sanestop** | Stop | Ensures session summary before exit |

### Damage Potential Categorization

Tools are blocked based on blast radius, not name:

| Category | Blast Radius | Examples | Blocked Until |
|----------|--------------|----------|---------------|
| Read-only | None | Read, Grep, search_nodes | Never |
| Local mutation | This project | Edit, Write | Research complete |
| Global mutation | ALL projects | memory delete/create | Research complete |
| External mutation | Outside systems | GitHub push/merge | Research complete |

This prevents Claude from nuking shared resources (like MCP memory) without understanding the impact.

### Test Coverage

259 tests across 3 tiers:
- **Easy (75)**: Basic functionality
- **Hard (72)**: Edge cases and complex scenarios
- **Villain (70)**: Adversarial bypass attempts
- **Real Failures (42)**: Actual Claude misbehavior patterns

---

## The "Supervisor" Advantage

SaneProcess isn't just rules - it's a **Mac App Factory** layer:

| Feature | What It Does |
|---------|--------------|
| **Mac Context Injection** | 757 lines of Info.plist, entitlements, sandboxing, WWDC 2025 APIs, crash analysis |
| **Circuit Breaker** | Stops Claude after 3 same errors (prevents $20 token burn) |
| **XcodeGen Integration** | Never let Claude touch .xcodeproj directly |
| **Build Loop Handler** | Captures errors, strips noise, feeds back only essentials |

---

## The Sane* Family

All tools share the **Sane** prefix so you know when you're using our battle-tested components:

| Tool | What It Does |
|------|--------------|
| **SaneProcess** | The methodology + product |
| **SaneMaster** | CLI tool for build, verify, launch, logs |
| **SaneLoop** | Iteration loop with enforced exit conditions |
| **SaneSkills** | Load/unload domain knowledge on demand |
| **SaneRules** | Path-specific guidance (Tests/, Views/, Services/) |
| **SaneBreaker** | Circuit breaker - stops after repeated failures |

Each component is designed to work together. When you see "Sane*", you know it's enforcing discipline.

---

## Pricing

**$29 one-time** - Lifetime upgrades included.

No subscriptions. No recurring fees. Pay once, get all future updates.

**To purchase:** [Open an issue](https://github.com/stephanjoseph/SaneProcess/issues/new) with subject "License Request"

## Installation

After purchasing, one command installs everything:

```bash
curl -sL https://raw.githubusercontent.com/stephanjoseph/SaneProcess/main/scripts/init.sh | bash
```

This installs:
- 4 consolidated SOP enforcement hooks (259 tests)
- SaneMaster CLI (`Scripts/SaneMaster.rb` + 19 modules)
- 6 pattern-based rules
- Claude Code settings with hook registration
- MCP server configuration
- DEVELOPMENT.md with the 16 Golden Rules

---

## Preview

You can view the full source code here. To use it in your projects, purchase a license.

**Quick look at the 16 Golden Rules:**

```
#0  NAME THE RULE BEFORE YOU CODE
#1  STAY IN YOUR LANE (files in project)
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

## License

**Source Available** - You may view this code for evaluation. Usage requires a paid license. See [LICENSE](LICENSE) for details.

---

## Questions?

Open an issue or contact [@stephanjoseph](https://github.com/stephanjoseph)

---

*SaneProcess v2.4 - January 2026*
