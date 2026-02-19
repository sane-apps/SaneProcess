# SaneApps AGENTS

Speak in plain English. Keep it short and direct.

If we are starting a new session run these:
- Read `~/SaneApps/infra/SaneProcess/SESSION_HANDOFF.md` if it exists.
- Check Serena memories (`read_memory`) for relevant history.
- Read `~/.claude/SKILLS_REGISTRY.md` for global skills/tools.
- Run `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`.

The 16 Golden Rules:

| # | Rule | What It Means |
|---|------|---------------|
| 0 | NAME IT BEFORE YOU TAME IT | State which rule applies before acting |
| 1 | STAY IN LANE, NO PAIN | No edits outside project without asking |
| 2 | VERIFY, THEN TRY | Check APIs/tools exist before using. Read docs, not memory |
| 3 | TWO STRIKES? STOP AND CHECK | Failed twice → STOP, read the error, research |
| 4 | GREEN MEANS GO | Tests must pass before "done" |
| 5 | HOUSE RULES, USE TOOLS | Use project tools (SaneMaster, etc.), not raw commands |
| 6 | BUILD, KILL, LAUNCH, LOG | Full cycle after every code change |
| 7 | NO TEST? NO REST | Every fix gets a test. No tautologies |
| 8 | BUG FOUND? WRITE IT DOWN | Document bugs in memory/issues |
| 9 | NEW FILE? GEN THE PILE | Use scaffolding tools and templates |
| 10 | FIVE HUNDRED'S FINE, EIGHT'S THE LINE | Max 500 lines, must split at 800 |
| 11 | TOOL BROKE? FIX THE YOKE | Fix broken tools, don't work around them |
| 12 | TALK WHILE I WALK | Subagents for heavy work, stay responsive |
| 13 | CONTEXT OR CHAOS | Maintain CLAUDE.md, load at start, save at end |
| 14 | PROMPT LIKE A PRO | Specific prompts with file paths, constraints, context |
| 15 | REVIEW BEFORE YOU SHIP | Self-review for security, edge cases, correctness |

If a hook or prompt fires, read it first and follow it exactly.

Research gate (when verifying or blocked):
- Use all 4: docs (apple-docs/context7), web search, GitHub MCP, and local codebase.

Codex enforcement (manual):
- No automatic hooks here; treat these as hard gates.
- If errors repeat, check breaker status (when available) and research before retrying.
- Don’t invent new docs; use the 5-doc standard (README, DEVELOPMENT, ARCHITECTURE, SESSION_HANDOFF, CLAUDE).

Safety:
- Keychain: one secret at a time (no parallel keychain calls).
- Use `trash`, not `rm -rf`.

Docs:
- On session end,update memory and `SESSION_HANDOFF.md`.
- Add a short SOP self-rating to `SESSION_HANDOFF.md`, then append one line to `/Users/sj/SaneApps/infra/SaneProcess/outputs/sop_ratings.csv`.

References:
- Global rules and gotchas: `/Users/sj/.claude/CLAUDE.md`
- Infra rules: `/Users/sj/SaneApps/infra/SaneProcess/CLAUDE.md`
