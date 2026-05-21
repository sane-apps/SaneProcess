# Project Agent Instructions

Use plain English. Keep it short and direct.

This file is the durable, client-neutral instruction surface for the repo.
- Codex reads `AGENTS.md` first.
- Claude can use this alongside `CLAUDE.md` and native hooks.
- Other coding agents should follow this file plus the repo scripts and docs.

## Read First

1. `README.md` for repo purpose and setup
2. `DEVELOPMENT.md` for commands, workflow, and definition of done
3. `ARCHITECTURE.md` for system shape and tradeoffs
4. `SESSION_HANDOFF.md` if it exists for current status
5. `CLAUDE.md` only if the current client also supports Claude-style overlays

## Core Rules

1. Verify APIs, tools, and assumptions before coding.
2. After two failed attempts, stop guessing and research.
3. Use the repo’s canonical scripts instead of ad hoc command chains.
4. Do not claim work is done without running the relevant checks or getting explicit approval.
5. Prefer updating existing docs/scripts over creating parallel ones.
6. Default to local or self-hosted verification. GitHub Actions should stay manual fallback, and Dependabot should stay off, unless the repo documents `HOSTED_AUTOMATION_EXCEPTION: <reason>`.

## Definition Of Done

- Code matches existing patterns.
- Relevant tests, lint, or validation ran.
- User-facing docs changed if behavior or workflow changed.
- Open questions and risks are written down plainly.

## Optional Project Policy

Add product-specific rules here only when they apply to this repo.

Examples:
- Design-system source of truth and typography rules
- Release, support, privacy, or billing gates
- Required local, CI, or remote-runner verification commands

Keep these rules concrete and replaceable so the repo is not tied to one AI client, one machine, or one company's private workflow.

## Client Notes

- Claude: native lifecycle hooks live in `.claude/settings.json`.
- Codex: canonical shared skills live in `~/.codex/skills`; `.agents/skills/`
  is a compatibility mirror when a repo needs checked-in shared skills.
- Everyone: shared safety and SOP checks should be enforced through repo scripts, MCP, git hooks, and shell guards.
