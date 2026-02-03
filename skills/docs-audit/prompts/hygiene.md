# Documentation Hygiene Audit

> You are auditing for **documentation sprawl, duplication, and inconsistency**.
> This is the most common failure mode - not missing docs, but too many overlapping docs.

---

## The Problem You're Solving

AI assistants (including you) have a bad habit of:
1. Creating new documents instead of updating existing ones
2. Using different terminology for the same concept across projects
3. Forgetting bugs that were already solved
4. Not checking what already exists before writing

This creates:
- 3 documents that all describe "what to do next"
- Terminology drift ("handoff" vs "roadmap" vs "todos" vs "next steps")
- Rediscovering the same bugs session after session
- Cognitive overload for the user trying to find information

---

## What To Check

### 1. Document Overlap Detection

Find ALL markdown files in the project:
```bash
find . -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*"
```

For each document, identify its **primary purpose**:
| Purpose | Should Be In |
|---------|--------------|
| Project overview | README.md (ONE) |
| Development setup | DEVELOPMENT.md or CONTRIBUTING.md (ONE) |
| Session context | SESSION_HANDOFF.md (ONE) |
| Future work | GitHub Issues or single ROADMAP.md |
| Bug tracking | Memory MCP (NOT markdown files) |
| API reference | docs/API.md or inline (ONE location) |

**Red flags:**
- Multiple "overview" documents
- SESSION_HANDOFF.md AND TODO.md AND ROADMAP.md (pick one!)
- BUGS.md file (should be in memory MCP, not a file)
- Multiple READMEs at different levels
- CHANGELOG.md that duplicates git log

### 2. Terminology Consistency

Scan all docs for inconsistent naming of the same concept:

| Check For | Should Standardize To |
|-----------|----------------------|
| "handoff" vs "todos" vs "next steps" | Pick ONE term |
| Project name variations | Exact casing everywhere |
| Feature names | Match code exactly |
| Command names | Match CLI exactly |

### 3. Memory MCP Hygiene

Check memory MCP for this project:
```
search(query: "ProjectName", project: "ProjectName")
```

Flag if:
- Bugs are in markdown files instead of memory
- Same bug appears multiple times in memory
- Patterns documented but not in memory
- Decisions made but not recorded

### 4. Cross-Project Consistency

If this is part of a multi-project ecosystem:
- Are the same concepts named the same way?
- Is SESSION_HANDOFF.md format consistent?
- Are CLAUDE.md structures aligned?

---

## Output Format

```markdown
## Documentation Hygiene Report

### Duplicate Documents
| File A | File B | Overlap | Recommendation |
|--------|--------|---------|----------------|
| TODO.md | SESSION_HANDOFF.md | Both track "next tasks" | Delete TODO.md, use SESSION_HANDOFF.md |

### Terminology Drift
| Concept | Used As | Standardize To |
|---------|---------|----------------|
| Next tasks | "todos", "roadmap", "backlog" | "Next Steps" in SESSION_HANDOFF.md |

### Memory MCP Gaps
| What | Current State | Should Be |
|------|---------------|-----------|
| Bug: X crashes on Y | In BUGS.md | In memory MCP |

### Consolidation Opportunities
1. [ ] Merge X.md into Y.md
2. [ ] Delete Z.md (obsolete)
3. [ ] Move bugs from files to memory MCP

### Documents to Keep (Single Source of Truth)
- README.md - Project overview
- DEVELOPMENT.md - Dev setup
- SESSION_HANDOFF.md - Session continuity
- Memory MCP - Bugs, patterns, decisions
```

---

## Rules

1. **One source of truth per concept** - If it's in two places, delete one
2. **Bugs go in memory MCP** - Not markdown files
3. **SESSION_HANDOFF.md is for session continuity** - Not a permanent roadmap
4. **If you find duplication, consolidate it** - Don't just report, fix
5. **Terminology must match code** - If code says `SaneMaster`, docs say `SaneMaster`

---

## Common Violations

| Violation | Why It's Bad | Fix |
|-----------|--------------|-----|
| TODO.md + ROADMAP.md + SESSION_HANDOFF.md | 3 places to check for "what's next" | Pick SESSION_HANDOFF.md, delete others |
| BUGS.md file | Bugs get stale, not searchable | Move to memory MCP |
| Multiple README files | Confusing which is canonical | One README.md at root |
| NOTES.md, SCRATCH.md | Grows forever, never cleaned | Delete or merge into SESSION_HANDOFF.md |
| Changelog that duplicates git | Maintenance burden | Use git log or auto-generate |

---

## Self-Check Before Creating Documents

Before creating ANY new markdown file, ask:
1. Does a document for this purpose already exist?
2. Can this go in an existing document?
3. Is this a bug/pattern that belongs in memory MCP?
4. Will this create overlap with SESSION_HANDOFF.md?

**Default answer: Update existing, don't create new.**

---

## MANDATORY: Persistent Record

**You MUST write findings to `DOCS_AUDIT_FINDINGS.md` in the project root.**

- Append your findings to the appropriate section as you discover them
- Use the Edit tool to update the file incrementally (don't wait until the end)
- On subsequent audits, mark resolved issues as `[RESOLVED YYYY-MM-DD]`
- Never delete old findings - maintain the audit trail
- This file is the permanent record that survives context loss
