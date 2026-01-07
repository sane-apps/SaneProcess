# [Project Name] Development Guide (SOP)

**Version 1.0** | Last updated: [DATE]

> **SINGLE SOURCE OF TRUTH** for all Developers and AI Agents.

---

## Quick Start for AI Agents

**New to this project? Start here:**

1. **Read Rule #0 first** - It's about HOW to use all other rules
2. **All files stay in project** - NEVER write files outside this project unless user explicitly requests
3. **Use project tools for everything** - `./Scripts/[tool] verify` for build+test, never raw build commands
4. **Self-rate after every task** - Rate yourself 1-10 on SOP adherence

**Your first action when user says "check our SOP" or "use our SOP":**
```bash
./Scripts/[tool] bootstrap  # Verify environment
./Scripts/[tool] verify     # Build + unit tests
```

**Key Commands:**
```bash
./Scripts/[tool] verify          # Build + tests
./Scripts/[tool] test_mode       # Kill → Build → Launch → Logs
./Scripts/[tool] logs --follow   # Stream live logs
./Scripts/[tool] verify_api X    # Check if API exists in SDK
```

---

## THIS HAS BURNED YOU

Real failures from past sessions. Don't repeat them.

| Mistake | What Happened | Prevention |
|---------|---------------|------------|
| **[Add your first failure here]** | | |

**The #1 differentiator**: Skimming this SOP = 5/10 sessions. Internalizing it = 8+/10.

---

## Project Structure

```
[ProjectName]/
├── Core/               # Foundation types
│   ├── Models/         # Domain models
│   ├── Protocols/      # Service protocols for DI
│   └── Extensions/     # Swift extensions
├── Services/           # Business logic
├── UI/                 # SwiftUI views
├── Tests/              # Unit tests
│   └── Regression/     # Regression tests for bug fixes
├── Scripts/            # Build automation
└── [App].swift         # App entry point
```

---

## Quick Commands

```bash
# Build & Test
./Scripts/[tool] verify          # Build + unit tests
./Scripts/[tool] verify --clean  # Full clean build
./Scripts/[tool] test_mode       # Kill → Build → Launch → Logs

# Diagnostics
./Scripts/[tool] logs --follow   # Stream live logs
./Scripts/[tool] verify_api X    # Check if API exists in SDK
./Scripts/[tool] clean --nuclear # Deep clean (all caches)

# Memory Health (MCP Knowledge Graph)
./Scripts/[tool] mh              # Check entity/token counts

# Circuit Breaker
./Scripts/[tool] breaker_status  # Check if tripped
./Scripts/[tool] breaker_errors  # See what failed
./Scripts/[tool] reset_breaker   # Unblock (after plan approved)
```

---

## Project-Specific Rules

### Key APIs (Verify Before Using)

```bash
# Always verify these exist before coding:
./Scripts/[tool] verify_api [APIName] [Framework]
```

### Project-Specific Patterns

- **[Pattern 1]**: [Description]
- **[Pattern 2]**: [Description]

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Ghost beeps / no launch | `xcodegen generate` (or your project generator) |
| Phantom build errors | `./Scripts/[tool] clean --nuclear` |
| Permissions issues | Check entitlements |
| File not found | Run project generator after creating new files |

---

## Golden Rules Reference

See the full [SaneProcess documentation](./SaneProcess.md) for the complete 16 Golden Rules.

**Quick reminder:**
- #0: NAME THE RULE BEFORE YOU CODE
- #3: TWO STRIKES? INVESTIGATE
- #5: SANEMASTER OR DISASTER (use project tools)
- #7: NO TEST? NO REST
- #9: NEW FILE? GEN THAT PILE

---

## Session Summary Format

Every session ends with this exact format:

```
## Session Summary

### What Was Done
1. [First concrete deliverable]
2. [Second concrete deliverable]
3. [Third concrete deliverable]

### SOP Compliance: X/10

✅ **Followed:**
- Rule #X: [What you did right]
- Rule #X: [What you did right]

❌ **Missed:**
- Rule #X: [What you missed and why]

**Next time:** [Specific improvement for future sessions]

### Followup
- [Actionable item for future]
- [Actionable item for future]
```

**CRITICAL:** Rating is on RULE COMPLIANCE, not task completion.

| Score | Meaning |
|-------|---------|
| 9-10 | All rules followed |
| 7-8 | Minor miss (one rule) |
| 5-6 | Notable gaps (2-3 rules) |
| 1-4 | Multiple violations |

---

*Customize this template for your project. Replace [bracketed items] with project-specific values.*
