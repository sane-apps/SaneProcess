# SaneApps AGENTS

Speak in plain English. Keep it short and direct.

If we are starting a new session run these:
- Read `~/SaneApps/infra/SaneProcess/SESSION_HANDOFF.md` if it exists.
- Check Serena memories (`read_memory`) for relevant history.
- Read `~/.claude/SKILLS_REGISTRY.md` for global skills/tools.
- Run `ruby ~/SaneApps/infra/SaneProcess/scripts/validation_report.rb`.

Core rules:
- Verify APIs before use. Do not guess.
- Stop after 2 failures and investigate.
- Tests must pass before saying “done.”
- Use project tools/scripts (SaneMaster, etc.), not raw commands.
- Stay in the project; don’t edit outside without asking.
- If a hook or prompt fires, read it first and follow it exactly.

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
