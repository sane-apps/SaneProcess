# SaneProcess Development Guide

This project uses **SaneProcess** for Claude Code SOP enforcement. Yes, we eat our own dogfood.

## The 16 Golden Rules

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

## Quick Start

```bash
# Run all QA checks (hooks, docs, tests)
ruby scripts/qa.rb

# Run hook tests only (259 tests)
ruby scripts/hooks/test/tier_tests.rb

# Check memory health
./Scripts/SaneMaster.rb memory

# Cross-project sync check
ruby scripts/sync_check.rb ~/SaneBar
```

## Project Structure

```
SaneProcess/
├── docs/                    # User-facing documentation
│   ├── SaneProcess.md       # Complete methodology (1,400+ lines)
│   └── PROJECT_TEMPLATE.md  # Template for users to customize
├── scripts/                 # Core tooling and automation
│   ├── SaneMaster.rb        # Main CLI tool
│   ├── sanemaster/          # 19 SaneMaster modules
│   ├── hooks/               # 4 consolidated enforcement hooks
│   │   ├── saneprompt.rb    # UserPromptSubmit hook
│   │   ├── sanetools.rb     # PreToolUse hook
│   │   ├── sanetrack.rb     # PostToolUse hook
│   │   └── sanestop.rb      # Stop hook
│   ├── init.sh              # Installation script
│   └── qa.rb                # Quality assurance
├── skills/                  # Modular domain-specific knowledge
└── .claude/
    ├── rules/               # Path-specific guidance
    └── settings.json        # Hook registration
```

## Installed Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| `saneprompt.rb` | UserPromptSubmit | Classify task, inject workflow structure |
| `sanetools.rb` | PreToolUse | Block edits until research complete |
| `sanetrack.rb` | PostToolUse | Track failures, update circuit breaker |
| `sanestop.rb` | Stop | Capture session learnings |

## Testing

All hooks have self-tests. Test tiers:

| Tier | Count | Purpose |
|------|-------|---------|
| Easy | 75 | Basic functionality |
| Hard | 72 | Edge cases |
| Villain | 70 | Adversarial inputs |
| Real Failures | 42 | Actual past failures |

```bash
# Run all tests
ruby scripts/hooks/test/tier_tests.rb

# Run specific tier
ruby scripts/hooks/test/tier_tests.rb --tier easy
```

## Before Pushing

1. Run QA: `ruby scripts/qa.rb`
2. Verify tests pass: `ruby scripts/hooks/test/tier_tests.rb`
3. Check cross-project consistency: `ruby scripts/sync_check.rb ~/SaneBar`

## Self-Rating

After every task, rate 1-10:

| 9-10 | All rules followed |
| 7-8 | Minor miss |
| 5-6 | Notable gaps |
| 1-4 | Multiple violations |

## AI Usage Self-Rating

| Criteria | Status |
|----------|--------|
| Used progressive prompting (plan first) | |
| Verified APIs before using | |
| Self-reviewed code before done | |
| Updated context file with learnings | |
| Used specific prompts with constraints | |
| Stopped at 2 failures and researched | |

**Target: 5/6 or better**

## Cross-Project Consistency

This repo syncs with:
- **SaneBar** - macOS menu bar app
- **SaneVideo** - Video processing app

When making changes, check if they should propagate:

```bash
ruby scripts/sync_check.rb ~/SaneBar
ruby scripts/sync_check.rb ~/SaneVideo
```

## Key Files

| File | Purpose |
|------|---------|
| `docs/SaneProcess.md` | Complete methodology |
| `scripts/qa.rb` | Quality assurance runner |
| `scripts/hooks/core/state_manager.rb` | State management (never modify state.json directly) |
| `.claude/settings.json` | Hook registration |

## More Info

- Full documentation: `docs/SaneProcess.md`
- Hook architecture: `scripts/hooks/README.md`
- Project context: `.claude/SOP_CONTEXT.md`
