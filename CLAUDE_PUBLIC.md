# SaneProcess - Claude Code Instructions (Public)

This file provides AI-readable guidance for projects using SaneProcess.
See [README.md](README.md) for full documentation.

Private/local files (not tracked in git):
- `CLAUDE.md` — project-specific AI rules and session procedures
- `SESSION_HANDOFF.md` — recent work context between sessions

---

## Hook Architecture

Five hooks enforce discipline at each Claude Code lifecycle event:

| Hook | Event | Exit Codes |
|------|-------|------------|
| `session_start.rb` | SessionStart | 0 (always) |
| `saneprompt.rb` | UserPromptSubmit | 0 (always) |
| `sanetools.rb` | PreToolUse | 0=allow, 2=block |
| `sanetrack.rb` | PostToolUse | 0 (always) |
| `sanestop.rb` | Stop | 0 (always) |

## When Hooks Block You

| Block Message | What To Do |
|--------------|------------|
| RESEARCH INCOMPLETE | Complete the required research categories (see below) |
| CIRCUIT BREAKER | Say `reset breaker` after fixing the root cause |
| FILE SIZE | Split the file — 500 line warning, 800 line block |
| BLOCKED PATH | You're editing outside project scope |
| SENSITIVE FILE | Confirm the edit (first time per file per session) |

## Research Categories

The gate adapts to your installed MCP servers. Categories whose MCPs have never been used auto-skip.

| Category | How | Tool | Required? |
|----------|-----|------|-----------|
| docs | Check API documentation | apple-docs, context7 | Only if MCP installed |
| web | Search for best practices | WebSearch | Always |
| github | Find examples | GitHub search | Only if MCP installed |
| local | Read existing code | Read, Grep, Glob | Always |

With no MCPs installed, only `web` + `local` are required. Install MCPs for stricter enforcement.

## Commands

| Say This | Effect |
|----------|--------|
| `reset breaker` or `rb-` | Reset circuit breaker |
| `rb?` or `breaker status` | Show breaker status |
| `research` | Show research progress |
| `s+` | Enable safe mode (block all edits) |
| `s-` | Disable safe mode |
