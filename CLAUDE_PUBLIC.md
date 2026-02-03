# SaneProcess Public Guide

This is the public, shareable guide for SaneProcess. It is intentionally free of private or project-specific details.

Private/local files (not in this repo):
- CLAUDE.md
- SESSION_HANDOFF.md

If you are using SaneProcess in your own projects, create local equivalents from your own data.

---

## What SaneProcess Is

SaneProcess is a process and tooling layer that keeps AI-assisted work disciplined and testable.
It uses hooks, checklists, and a small CLI to prevent drift and enforce verification.

---

## Session Start (Suggested)

1. Read project docs (README, DEVELOPMENT, ARCHITECTURE)
2. Run validation: `ruby scripts/validation_report.rb`

---

## Session Close (Default)

1. Confirm worktree is clean or intentionally staged
2. Update your local session notes (Done / Docs / SOP / Next)
3. Run the smallest relevant check:
   - Docs-only: `./scripts/SaneMaster.rb check_docs`
   - Code changes: `./scripts/SaneMaster.rb verify`
4. Append one SOP score line to your local `outputs/sop_ratings.csv`

Run full `/docs-audit` only when needed:
- New user-facing feature or behavior change
- README/website docs touched
- Release prep or public announcement
- Larger change sets where drift risk is higher

---

## Golden Rules

See README.md for the current Golden Rules list and definitions.

---

## CLI Quick Start

```bash
./scripts/SaneMaster.rb verify        # Build + tests
./scripts/SaneMaster.rb test_mode     # Kill -> Build -> Launch -> Logs
./scripts/SaneMaster.rb check_docs    # Docs/tooling sync
```

