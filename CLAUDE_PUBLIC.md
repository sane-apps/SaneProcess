# SaneProcess - Public Agent Instructions

This file provides public AI-readable guidance for projects using SaneProcess.
See [README.md](README.md) for full documentation.

Private/local operator files may include `CLAUDE.md` and
`SESSION_HANDOFF.md`. Their tracking policy is project-specific; they never
override the client-neutral `AGENTS.md` contract.

Codex note: Codex reads repo `AGENTS.md` first. Treat this file as the public reference for the Claude-native hook runtime and the shared SOP concepts behind it.

---

## Hook Architecture

Six lifecycle events enforce discipline in the current Claude adapter:

| Hook | Event | Exit Codes |
|------|-------|------------|
| `session_start.rb` | SessionStart | 0 (always) |
| `saneprompt.rb` | UserPromptSubmit | 0 (always) |
| `sanetools.rb` | PreToolUse | 0=allow, 2=block |
| `sanetrack.rb` | PostToolUse | 0 (always) |
| `task_completed_gate.rb` | TaskCompleted | 0=complete, 2=missing required proof |
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

## Client Model

- **Claude Code:** native lifecycle hooks plus this file and local/private `CLAUDE.md`.
- **Codex:** repo `AGENTS.md`, `.agents/skills`, `.codex/config.toml`, MCP, and shared shell/script guardrails.
- **Other agents:** use the same SOP if they can honor `AGENTS.md`, repo scripts, and MCP.

## Commands

| Say This | Effect |
|----------|--------|
| `reset breaker` or `rb-` | Reset circuit breaker |
| `rb?` or `breaker status` | Show breaker status |
| `research` | Show research progress |
| `s+` | Enable safe mode (block all edits) |
| `s-` | Disable safe mode |
