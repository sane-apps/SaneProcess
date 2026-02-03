# Completeness Audit

> You are auditing for **incomplete documents that look done but aren't**.
> This catches the "template that was never filled in" problem.

---

## The Problem You're Solving

Documents often get created with good intentions but never finished:
- Templates with `[ ]` checkboxes never checked
- Placeholders like `TODO`, `TBD`, `___`, `FIXME` never replaced
- Sections that say "Coming soon" for 6 months
- Config examples with `YOUR_VALUE_HERE` never updated
- Dates that say "Last updated: [DATE]" with the bracket still there

A half-done doc is worse than no doc - it gives false confidence.

---

## What To Check

### 1. Unchecked Checkboxes

Find documents with unchecked items:
```bash
grep -rn "\[ \]" *.md
```

**Flag if:**
- More than 3 unchecked items in a "checklist" doc
- Action items that are clearly overdue
- Setup steps that should have been done

**Ignore if:**
- Template files meant to be copied
- Example checklists showing format

### 2. Placeholder Text

Search for common placeholder patterns:
```
TODO
TBD
FIXME
XXX
YOUR_*_HERE
<placeholder>
[FILL IN]
[DATE]
[NAME]
_____ (blanks)
...more to come
Coming soon
WIP
DRAFT
```

### 3. Incomplete Sections

Look for:
- Headers with no content below them
- Sections that just say "TBD" or "TODO"
- Tables with empty cells
- Lists that end with "..."

### 4. Stale "Coming Soon"

Find temporal promises that may be broken:
- "Coming in v2.0" - is v2.0 out?
- "Planned for Q1" - is it Q3?
- "Soon" - how long ago was this written?

### 5. Template Documents Never Customized

Signs a template was copied but not filled:
- Still has example values
- Contains instructions like "Replace this with..."
- Has `{{variable}}` or `${placeholder}` syntax
- Multiple `[CHANGE THIS]` markers

### 6. Time-Sensitive Items Not Updated

**Critical items that expire:**
- Certificate expiry dates → are they filled in?
- Domain renewal dates → are they current?
- API key expiry → documented?
- License renewal → on calendar?
- Subscription renewals → tracked?

---

## Output Format

```markdown
## Completeness Audit Report

### 🔴 INCOMPLETE CRITICAL DOCS
| File | Issue | Items Needing Action |
|------|-------|---------------------|
| DISASTER_RECOVERY.md | 15 unchecked boxes | Domain expiry, cert backup, contacts |
| SETUP.md | TODO placeholders | 3 config values never filled |

### 🟡 STALE PROMISES
| File | Promise | Reality |
|------|---------|---------|
| ROADMAP.md | "Coming in v2.0" | v2.4 is current |
| README.md | "Coming soon" | Written 6 months ago |

### 🟡 TEMPLATES NEEDING COMPLETION
| File | Blank Fields | Action Required |
|------|--------------|-----------------|
| config.example.md | API_KEY, SECRET | User must fill before use |

### ⏰ TIME-SENSITIVE ITEMS
| Item | Status | Action |
|------|--------|--------|
| Dev certificate expiry | NOT DOCUMENTED | Check and document date |
| Domain renewal | "[ ] CHECK" | Actually check and fill in |

### ✅ COMPLETE
- [ ] All checklists have been worked through
- [ ] No TODO/TBD placeholders remain
- [ ] Time-sensitive dates are filled in
```

---

## Rules

1. **A checklist with unchecked boxes is incomplete** - Either check them or delete them
2. **Templates are fine, unfilled templates are not** - Know the difference
3. **"Coming soon" has a shelf life** - After 3 months, it's a lie
4. **Time-sensitive = high priority** - Expiring certs/domains are urgent
5. **If it says DRAFT, treat it as incomplete** - Either finish it or delete it

---

## Common Violations

| Violation | Example | Fix |
|-----------|---------|-----|
| Abandoned checklist | 15 of 20 items unchecked | Complete or remove |
| Placeholder forgotten | `API_KEY=YOUR_KEY_HERE` | Fill in or document how to get |
| Stale "coming soon" | "Coming in 2024" (it's 2026) | Update or remove |
| Blank expiry date | `Expires: ____` | Actually check and fill in |
| WIP that shipped | `## WIP: Auth Flow` | Remove WIP or finish it |

---

## Questions to Surface to User

When you find incomplete docs, don't just report - **frame as decisions**:

- "DISASTER_RECOVERY.md has certificate expiry blank. Do you know when it expires, or should I check?"
- "5 domain expiry dates say '[ ] CHECK'. Want me to look these up?"
- "ROADMAP.md promises features for v2.0 but we're on v2.4. Should I clean this up?"

**The goal:** Surface what needs HUMAN action, offer to do what AI can do.

---

## MANDATORY: Persistent Record

**You MUST write findings to `DOCS_AUDIT_FINDINGS.md` in the project root.**

- Append your findings to the appropriate section as you discover them
- Use the Edit tool to update the file incrementally (don't wait until the end)
- On subsequent audits, mark resolved issues as `[RESOLVED YYYY-MM-DD]`
- Never delete old findings - maintain the audit trail
- This file is the permanent record that survives context loss
