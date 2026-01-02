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
| **11 Golden Rules** | Memorable rules like "TWO STRIKES? INVESTIGATE" |
| **Circuit Breaker** | Auto-stops after 3 same errors or 5 total failures |
| **Memory System** | Bug patterns persist across sessions |
| **Compliance Loop** | Enforced task completion with verification |
| **Self-Rating** | Accountability after every task |

## What's Included

```
├── docs/SaneProcess.md   # Complete SOP documentation (1,100+ lines)
├── scripts/init.sh       # One-command project setup
└── Hooks & configs       # Circuit breaker, memory compactor, lefthook
```

---

## Pricing

| Tier | Price | Includes |
|------|-------|----------|
| **Personal** | $29 | License for 1 developer |
| **Team** | $99 | License for up to 5 developers |
| **Enterprise** | Contact | Unlimited + custom hooks + support |

**To purchase:** [Open an issue](https://github.com/stephanjoseph/SaneProcess/issues/new) with subject "License Request"

---

## Preview

You can view the full source code here. To use it in your projects, purchase a license.

**Quick look at the Golden Rules:**

```
#0  NAME THE RULE BEFORE YOU CODE
#1  STAY IN YOUR LANE (files in project)
#2  VERIFY BEFORE YOU TRY (check docs)
#3  TWO STRIKES? INVESTIGATE
#4  GREEN MEANS GO (tests must pass)
#5  USE PROJECT TOOLS
#6  BUILD, KILL, LAUNCH, LOG
#7  NO TEST? NO REST
#8  FILE SIZE LIMITS (500/800)
#9  NEW FILE? UPDATE PROJECT
#10 TRACK WITH TodoWrite
```

---

## License

**Source Available** - You may view this code for evaluation. Usage requires a paid license. See [LICENSE](LICENSE) for details.

---

## Questions?

Open an issue or contact [@stephanjoseph](https://github.com/stephanjoseph)

---

*SaneProcess v2.1 - January 2026*
