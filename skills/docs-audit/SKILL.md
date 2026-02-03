# Documentation Audit Skill

> **Triggers** (ANY of these should invoke this skill):
> - `/docs-audit`, "do an audit", "run audit", **"audit"**
> - "update the readme", "update docs", "update documentation"
> - "update the website", "sync website"
> - "update everything", "ship it", "we're done"
> - "push to git", "commit everything", "let's commit"
> - "end session", "session close", "wrap up"
> - "prepare for release", "get ready to ship"

---

## ⛔ CRITICAL: NO SHORTCUTS

**When user says "audit", you MUST:**
1. **Create `DOCS_AUDIT_FINDINGS.md`** in project root with header + timestamp
2. **Run ALL 11 perspectives** by reading each `prompts/*.md` file
3. **Spawn subagents as `general-purpose` type with `model: "sonnet"`** — each writes its own findings file
4. **Consolidate** all per-agent files into the main `DOCS_AUDIT_FINDINGS.md`
5. **Present the full Gap Report** before any updates
6. **Get user approval** before making changes

**SUBAGENT PIPELINE (CRITICAL — READ THIS):**

Each audit perspective runs as a `general-purpose` subagent with `model: "sonnet"` (NOT `Explore` — Explore agents
cannot write files). Sonnet catches issues Haiku misses — worth the cost for reliable audits.
Each agent writes findings to its own file to avoid parallel write conflicts:

```
DOCS_AUDIT_FINDINGS_engineer.md
DOCS_AUDIT_FINDINGS_designer.md
DOCS_AUDIT_FINDINGS_marketer.md
DOCS_AUDIT_FINDINGS_user.md
DOCS_AUDIT_FINDINGS_qa.md
DOCS_AUDIT_FINDINGS_hygiene.md
DOCS_AUDIT_FINDINGS_security.md
DOCS_AUDIT_FINDINGS_freshness.md
DOCS_AUDIT_FINDINGS_completeness.md
DOCS_AUDIT_FINDINGS_ops.md
DOCS_AUDIT_FINDINGS_consistency.md
```

**How to spawn each agent:**
```
Task tool:
  subagent_type: "general-purpose"
  model: "sonnet"
  allowed_tools: ["Read", "Glob", "Grep", "Write", "WebFetch"]
  prompt: |
    You are the [PERSPECTIVE] auditor for a documentation audit.

    PROJECT ROOT: [absolute path to project]

    INSTRUCTIONS: [contents of prompts/[perspective].md]

    FINDINGS FILE: Write your findings to [PROJECT_ROOT]/DOCS_AUDIT_FINDINGS_[perspective].md

    FORMAT your findings file exactly like this:

    # [Perspective] Audit Findings
    **Date:** [today's date]
    **Score:** X/10

    ## Critical Issues
    | Issue | File | Line | Recommendation |
    |-------|------|------|----------------|

    ## Warnings
    | Issue | File | Details |
    |-------|------|---------|

    ## Passed Checks
    - [x] Check description

    ## Summary
    [2-3 sentence summary]

    IMPORTANT: You MUST write your findings file before completing.
    Do NOT just return findings as text — WRITE THE FILE.
```

**After all agents complete — Consolidation Phase:**
1. Read each `DOCS_AUDIT_FINDINGS_*.md` file
2. Combine into the main `DOCS_AUDIT_FINDINGS.md` with:
   - Executive summary (scores table)
   - All critical issues merged and deduplicated
   - All warnings merged
   - Per-perspective sections preserved
3. Delete the individual per-agent files (they're now in the consolidated doc)
4. On subsequent audits, UPDATE existing findings (mark resolved, add new issues)
5. Never delete old findings — mark them as `[RESOLVED YYYY-MM-DD]` with date
6. This creates an audit trail showing project health over time

**DO NOT:**
- ❌ Do a "quick manual audit" yourself
- ❌ Skip perspectives because "it's faster"
- ❌ Start fixing things without the full report
- ❌ Assume you know what's wrong without checking

**The whole point is YOU do the thorough thinking so the user doesn't have to.**

---

**Part of standard procedures:**
- **Session close**: Run docs-audit before session summary
- **Before push**: Run docs-audit before git operations

Don't let stale docs slip through.

## Purpose

Comprehensive documentation audit that removes cognitive burden from the user. You are NOT just updating docs - you are **thinking through everything** so the user doesn't have to.

The user is not an engineer, designer, or marketer. They built something cool and need YOU to:
1. Figure out what exists in the code
2. Figure out what's missing from the docs
3. Think through it from multiple expert perspectives
4. Present a clear action plan
5. Execute it properly

---

## The Process

### Phase 1: Discovery (YOU figure out what exists)

Before ANYTHING else, audit the codebase to understand what's actually there:

```
1. Find all entry points (main.swift, App.swift, CLI commands)
2. Find all public features (menu items, commands, UI screens)
3. Find all configuration options (settings, preferences, flags)
4. Find all integrations (APIs, services, other apps)
5. Read the current README.md and any docs/ folder
6. Check if there's a website (docs site, landing page)
```

**Output a Feature Inventory:**
```markdown
## Feature Inventory (from code)

### Commands/Actions
- [ ] /command1 - description (file:line)
- [ ] /command2 - description (file:line)

### UI Elements
- [ ] Settings panel - what it does
- [ ] Menu bar items - what they do

### Integrations
- [ ] API X - what it connects to

### Configuration
- [ ] Setting A - what it controls
```

---

### Phase 2: Multi-Perspective Audit

Run these 11 specialized audits. Each one thinks deeply from their expertise.

**⚠️ SUBAGENT TYPE: `general-purpose` with `model: "sonnet"`** (NOT `Explore` — Explore agents cannot write files!)
**⚠️ Each agent MUST write its findings file before completing.**
**⚠️ Launch agents in parallel batches (5-6 at a time) for efficiency.**

#### 1. Engineer Audit
Read: `prompts/engineer.md`
Focus: Technical accuracy, completeness, API docs

#### 2. Designer Audit
Read: `prompts/designer.md`
Focus: Screenshots, demos, visual storytelling

#### 3. Marketer Audit
Read: `prompts/marketer.md`
Focus: Value proposition, benefits, "why should I care?"

#### 4. User Advocate Audit
Read: `prompts/user.md`
Focus: Onboarding, clarity, "can my grandma understand this?"

#### 5. QA Audit
Read: `prompts/qa.md`
Focus: Edge cases, known issues, gotchas, troubleshooting

#### 6. Hygiene Audit
Read: `prompts/hygiene.md`
Focus: Document duplication, terminology drift, memory MCP gaps

**Catches:** Creating new docs instead of updating existing ones. Multiple docs for "next steps", bugs in files instead of memory.

#### 7. Security Audit (CRITICAL)
Read: `prompts/security.md`
Focus: Leaked secrets, PII in screenshots, internal URLs exposed

**Catches:** API keys in examples, passwords in config, screenshots showing real emails, internal Slack/Jira links, file paths with usernames.

#### 8. Freshness Audit
Read: `prompts/freshness.md`
Focus: Stale examples, outdated screenshots, broken links, wrong version numbers

**Catches:** Code examples that don't compile, screenshots of old UI, "Requires macOS 12" when we're on 15, 404 links.

#### 9. Completeness Audit
Read: `prompts/completeness.md`
Focus: Incomplete docs, unchecked checklists, TODO placeholders, time-sensitive items

**Catches:** Templates never filled in, "Coming soon" from 6 months ago, certificate expiry dates left blank, 15 unchecked action items.

#### 10. Ops Audit (CRITICAL)
Read: `prompts/ops.md`
Focus: Git hygiene, certificates, dependencies, domains, code TODOs, cross-project drift

**Catches:** Stale branches, expiring certs, vulnerable dependencies, lapsing domains, TODO comments rotting in code, version mismatches across projects.

**This is "everything humans forget to check" - trivial for AI, nightmare to track manually.**

#### 11. Consistency Audit (CRITICAL)
Read: `prompts/consistency.md`
Focus: Broken references in CLAUDE.md, rules, settings vs actual code

**Catches:**
- File paths that don't exist
- API references to methods that don't exist
- Rule patterns that match zero files
- MCP tools referenced but not configured
- Scripts mentioned but deleted
- Hook paths in settings.json that are broken

**This is WHY Claude fails when following instructions - the instructions reference things that don't exist.**

---

### Phase 2.5: Consolidation

After ALL subagents complete:

1. **Read** each `DOCS_AUDIT_FINDINGS_*.md` file from the project root
2. **Build the scores table:**
   ```markdown
   | # | Perspective | Score | Critical | Warnings |
   |---|-------------|-------|----------|----------|
   | 1 | Engineer    | 8/10  | 1        | 3        |
   | 2 | Designer    | 7/10  | 0        | 5        |
   ...
   ```
3. **Merge** all critical issues into one deduplicated table
4. **Merge** all warnings into one table
5. **Write** the consolidated `DOCS_AUDIT_FINDINGS.md` with:
   - Header + date + overall score
   - Scores table
   - Critical issues (merged)
   - Warnings (merged)
   - Per-perspective detail sections
6. **Clean up** — delete the individual `DOCS_AUDIT_FINDINGS_*.md` files
7. **Categorize** issues into:
   - **Fix now** (Claude can fix): doc text, wrong references, stale versions
   - **User action** (needs human): screenshots, domain purchases, design decisions, credential checks

---

### Phase 3: Gap Report

Present findings to user in this format:

```markdown
# Documentation Audit Report

## Executive Summary
- X features in code, Y documented (Z% coverage)
- Critical gaps: [list]
- Estimated effort: [quick/medium/significant]

## Critical Gaps (Fix These First)
| Gap | Why It Matters | Recommendation |
|-----|----------------|----------------|
| Feature X undocumented | Users can't discover it | Add section with example |

## Missing Visuals
| What | Current State | Needed |
|------|---------------|--------|
| Main UI | No screenshot | Capture showing X, Y, Z |

## Stale Content
| Section | Problem | Fix |
|---------|---------|-----|
| Installation | Shows old method | Update to new flow |

## Website Status
- [ ] Exists / Doesn't exist
- [ ] Last updated: [date or unknown]
- [ ] Matches README: Yes/No
- [ ] Needs: [list of updates]

## Documentation Hygiene (Duplication/Sprawl)
| Issue | Files Involved | Fix |
|-------|----------------|-----|
| Duplicate "next steps" docs | TODO.md, ROADMAP.md | Delete, use SESSION_HANDOFF.md only |
| Bugs in files not memory | BUGS.md | Move to memory MCP, delete file |
| Terminology drift | "handoff" vs "todos" | Standardize to "handoff" |

## Security Issues (FIX IMMEDIATELY)
| File | Line | Issue | Action |
|------|------|-------|--------|
| README.md | 45 | Looks like real API key | Replace with placeholder |
| screenshot.png | - | Shows /Users/john/ path | Retake screenshot |

## Freshness Issues
| Location | Problem | Current Reality |
|----------|---------|-----------------|
| README.md:15 | Shows v1.2.0 | Actually v2.4.0 |
| install.md | `brew install foo` | Package renamed |
| screenshot.png | Old UI | Redesigned in v2.0 |

## Incomplete Documents (USER ACTION NEEDED)
| File | Issue | What You Need To Do |
|------|-------|---------------------|
| DISASTER_RECOVERY.md | 15 unchecked items | Fill in cert expiry, domain dates, contacts |
| SETUP.md | TODO placeholders | Provide actual config values |

## Time-Sensitive Items
| Item | Status | Urgency |
|------|--------|---------|
| Dev certificate | Expiry not documented | Check Keychain, document date |
| Domains | "[ ] CHECK" not filled | Look up actual expiry dates |

## Ops Issues (Git, Deps, Infrastructure)
| Category | Issue | Action |
|----------|-------|--------|
| Git | 7 stale branches | Review and delete |
| Dependencies | 3 npm vulnerabilities | Run npm audit fix |
| Code | 23 TODO comments | Review and resolve |
| Legal | Copyright says 2024 | Update to 2026 |

## Calendar Reminders Needed
| What | When | Who |
|------|------|-----|
| Dev certificate renewal | [DATE] | You |
| Domain renewal | [DATE] | You |
| Apple Developer $99 | [DATE] | You |

## Recommended Actions (Priority Order)
1. [ ] [Action] - [why] - [effort: 5min/30min/2hr]
2. [ ] [Action] - [why] - [effort]
...
```

---

### Phase 4: User Approval

**STOP and ask the user:**

> "Here's what I found. Before I update anything:
> 1. Does this inventory match your understanding?
> 2. Any features I missed?
> 3. Which gaps should I prioritize?
> 4. Do you want me to proceed with all recommendations?"

**Do NOT update docs until user confirms.**

---

### Phase 5: Execute Updates

Only after approval:
1. Update README.md with all gaps addressed
2. Update website if it exists
3. Create list of screenshots/demos needed (user must capture these)
4. Commit with clear message listing what was updated

---

## Key Principles

1. **You think, they approve** - Don't make them figure out what's missing
2. **Show your work** - Present the inventory so they can catch what you missed
3. **Multiple lenses** - Engineer sees different gaps than Marketer
4. **Visuals matter** - A README without screenshots is incomplete
5. **Website = README** - If they're out of sync, that's a bug
6. **Effort estimates** - Help them prioritize what to tackle
7. **Consolidate, don't multiply** - Update existing docs, don't create new ones
8. **Bugs go in memory MCP** - Not markdown files that go stale
9. **One source of truth** - If info is in 2 places, delete one

---

## Example Invocations

User: "update the readme"
→ Run full audit, present gaps, get approval, then update

User: "quick docs check"
→ Run audit, present gaps, stop (don't update)

User: "/docs-audit --engineering-only"
→ Run only technical completeness check

User: "is the website up to date?"
→ Compare website to README, report differences

User: "end session" / "let's wrap up"
→ Run audit BEFORE session summary. Flag any stale docs. Don't let them slip.

User: "push to git" / "commit and push"
→ Run audit BEFORE git operations. Confirm docs are current.

User: "ship it" / "we're done"
→ Full audit. This is the last chance to catch missing docs.

---

## Session End Integration

When this skill is triggered by session close:

1. Run the full audit (all 11 perspectives)
2. Present gaps to user
3. Ask: "Should I update docs before we close?"
4. If yes → update, then proceed with session summary
5. If no → note in SESSION_HANDOFF.md that docs need attention

**The goal:** Never end a session with hidden features or stale docs.

---

## Quick Mode vs Full Mode

**Full mode** (default): All 11 audits, comprehensive report
- Use for: Major releases, session end, "update everything"

**Quick mode** (add `--quick`): Engineer audit only, fast check
- Use for: Mid-session check, "did I break anything?"

**Single perspective** (add `--engineering-only`, `--design-only`, etc.):
- Use for: Targeted checks when you know what you're looking for
