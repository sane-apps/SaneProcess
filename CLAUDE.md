# SaneProcess - Claude Code Instructions

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

> **PRIME DIRECTIVE: READ THE PROMPTS**
> Hook fires → Read the message → Find the answer → Succeed first try.
> Don't skim. Don't guess. The answer is in front of you.

---

## Project Location

| Path | Description |
|------|-------------|
| **This project** | `~/SaneApps/infra/SaneProcess/` |
| **Save outputs** | `~/SaneApps/infra/SaneProcess/outputs/` |
| **Screenshots** | `~/Desktop/Screenshots/` (label with project prefix) |
| **Templates** | `~/SaneApps/infra/SaneProcess-templates/` |
| **Shared UI** | `~/SaneApps/infra/SaneUI/` |

**This is INFRA** - shared hooks and tooling for all SaneApps.

**Apps using this:** SaneBar, SaneClip, SaneVideo, SaneSync, SaneHosts, SaneAI, SaneScript

---

## Session Procedures

**At session START:**
```bash
ruby scripts/validation_report.rb  # Is SaneProcess working? Check before diving in
```

**At session CLOSE:**
```bash
/docs-audit  # Did we document what we built? Check before leaving
```

Both are quick. Both catch problems before they compound.

---

## Quick Start

```bash
ruby scripts/qa.rb                    # Full QA check
ruby scripts/validation_report.rb     # Is SaneProcess working?
ruby scripts/hooks/test/tier_tests.rb # Run hook tests
ruby scripts/sync_check.rb ~/SaneBar  # Cross-project sync
```

## The Rules: Scientific Method for AI

These rules enforce the scientific method. Hooks block you until you comply.

### Core Principles (Scientific Method)

**#2 VERIFY BEFORE YOU TRY** - Observe before hypothesizing
- **DO:** Check `.swiftinterface`, use `apple-docs` MCP, read type definitions
- **DON'T:** "I remember this API has a .zoom property"
- **Enforcement:** Edits blocked until all 5 research categories complete

**#3 TWO STRIKES? INVESTIGATE** - Reject failed hypothesis
- **DO:** "Failed twice. Checking SDK to verify this exists."
- **DON'T:** "Let me try a slightly different approach..." (attempt #3)
- **Enforcement:** Circuit breaker trips at 3 consecutive failures

**#4 TESTS MUST PASS** - Experimental validation
- **DO:** Tests red → fix → run again → green → done
- **DON'T:** "Tests failed but it's probably fine"
- **Enforcement:** Test results tracked, failures logged

### Supporting Rules (Code Quality)

| Rule | What | Enforcement |
|------|------|-------------|
| #0 NAME RULE FIRST | State which rule applies | Prompt classification |
| #1 STAY IN LANE | No edits outside project | Path blocking |
| #5 THEIR HOUSE THEIR RULES | Use project conventions | Tool restrictions |
| #7 NO TEST NO REST | No tautologies | Tautology detection |
| #8 BUG FOUND? WRITE DOWN | Document bugs | Memory staging |
| #9 USE GENERATORS | Use scaffolding tools | Tool preferences |
| #10 FILE SIZE LIMIT | Max 500 lines | Size check on edit |

### Research Categories (All 5 Required)

| Category | Tool | Why |
|----------|------|-----|
| sane-mem | `curl localhost:37777/search?q=topic` | Past bugs, patterns (auto-captured) |
| docs | `mcp__apple-docs__*`, `mcp__context7__*` | API verification |
| web | `WebSearch` | Current best practices |
| github | `mcp__github__search_*` | External examples |
| local | `Read`, `Grep`, `Glob` | Existing code |

**Guessing is not science.** Verify → Hypothesize → Test → Learn.

## macOS UI Testing

Two different tools for two different targets:

| Tool | Target | Use For |
|------|--------|---------|
| **XcodeBuildMCP** | iOS Simulator | Build, test, simulator UI automation |
| **macos-automator** | Real macOS Desktop | Click menu bars, test actual running apps |

**For menu bar apps (SaneBar):** Use `macos-automator` to interact with real UI - XcodeBuildMCP's UI tools only work in simulator.

## Keychain Usage (CRITICAL)

All secrets are stored in macOS Keychain. **NEVER flood the user with popup requests.**

**The Rule: ONE AT A TIME**
```bash
# CORRECT - fetch once, store in variable
TOKEN=$(security find-generic-password -s cloudflare -a api_token -w)
curl -H "Authorization: Bearer $TOKEN" ...

# WRONG - multiple parallel calls = popup flood
curl ... $(security find-generic-password ...) &
curl ... $(security find-generic-password ...) &
```

**Available Secrets:**
| Service | Account | Usage |
|---------|---------|-------|
| `cloudflare` | `api_token` | Cloudflare API |
| `lemonsqueezy` | `api_key` | Lemon Squeezy API |
| `resend` | `api_key` | Resend email API |
| `notarytool` | (keychain profile) | Apple notarization |

**If you need multiple secrets:**
1. Ask user which ONE you need first
2. Fetch it, complete that task
3. Then ask for the next one if needed

**NEVER run `security find-generic-password` in parallel commands, loops, or background jobs.**

## Customer Email Handling (SaneApps)

**Email:** hi@saneapps.com (via Resend API)
**Sign-off:** Mr. Sane (NEVER mention Claude)

### Automatic Handling
- Simple questions about apps
- Download/installation issues
- Basic support requests

### Escalate to User
- Refund requests
- Complaints
- Feature requests
- Legal matters
- **Any media showing a problem** (see below)

### Media Attachments (CRITICAL)

**IGNORE:** Email signatures, company logos, profile pictures, decorative images

**ESCALATE when customer describes a problem + attaches media:**
1. Save media to `~/Desktop/Screenshots/[customer]-[issue].png`
2. Alert user: "Customer X reports [their description]. Media attached."
3. Open the file: `open ~/Desktop/Screenshots/[filename]`
4. Wait for user approval before responding

**Why:** Claude is bad at interpreting screenshots/videos. Customer describes the issue in text, but visual verification is needed before responding.

### Reading/Sending Emails
```bash
# Check for new emails
RESEND_KEY=$(security find-generic-password -s resend -a api_key -w)
curl -s "https://api.resend.com/emails/receiving" -H "Authorization: Bearer $RESEND_KEY"

# Read specific email
curl -s "https://api.resend.com/emails/receiving/{id}" -H "Authorization: Bearer $RESEND_KEY"

# Send response (as Mr. Sane)
curl -X POST "https://api.resend.com/emails" -H "Authorization: Bearer $RESEND_KEY" \
  -d '{"from":"hi@saneapps.com","to":"customer@email.com","subject":"Re: ...","text":"..."}'
```

```
# XcodeBuildMCP - simulator only
mcp__XcodeBuildMCP__tap, describe_ui, swipe → requires simulatorId

# macos-automator - real desktop
mcp__macos-automator__* → clicks real macOS UI, reads accessibility tree
```

## Workflow

```
1. PLAN    → Understand task, identify files, state approach
2. VERIFY  → Check APIs exist before using
3. BUILD   → Make changes, run tests
4. CONFIRM → Tests pass, user approves
```

## When Hooks Block You

The hooks are helping, not fighting you:

| Block | Rule | Fix |
|-------|------|-----|
| RESEARCH INCOMPLETE | #2 | Complete all 5 research categories |
| BLOCKED PATH | #1 | Stay within project scope |
| CIRCUIT BREAKER | #3 | Stop guessing, investigate root cause |
| FILE SIZE | #10 | Split file by responsibility |
| MCP NOT VERIFIED | #2 | Call each MCP tool once |
| SANELOOP REQUIRED | #2 | Start saneloop for big tasks |

## This Has Burned You Before

| Mistake | What Happened | Rule Violated |
|---------|---------------|---------------|
| Guessed API | Used non-existent method, failed 4x | #2 Verify |
| Kept guessing | Same error 5 times, different "fixes" | #3 Two Strikes |
| Skipped tests | Shipped broken code | #4 Tests Pass |
| Raw xcodebuild | Missed project config | #5 Their House |
| 800 line file | Unmaintainable mess | #10 File Size |

## Session End Format

**BEFORE closing, run `/docs-audit`** (or it triggers automatically on "end session"):
1. Audit finds all features in code
2. Compares to README/website
3. Shows you what's missing
4. You approve, then docs update
5. Then session summary

```
## Session Summary
### Done: [1-3 bullet points]
### Docs: [Updated/Current/Needs attention - list gaps if any]
### SOP: X/10 (rate RULE compliance, not task completion)
### Next: [Follow-up items]
```

**Never end a session with hidden features or stale docs.**

## Project Structure

```
scripts/
├── hooks/              # 5 enforcement hooks
│   ├── session_start.rb   # SessionStart - bootstrap
│   ├── saneprompt.rb      # UserPromptSubmit - classify task
│   ├── sanetools.rb       # PreToolUse - block until research done
│   ├── sanetrack.rb       # PostToolUse - track failures
│   └── sanestop.rb        # Stop - capture learnings
├── SaneMaster.rb       # Main CLI
└── qa.rb               # Quality checks
```

## Cross-Project Sync

This syncs with SaneBar, SaneVideo, SaneSync. After changes:
```bash
ruby scripts/sync_check.rb ~/SaneBar
ruby scripts/sync_check.rb ~/SaneVideo
```
