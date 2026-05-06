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
6. Default to local or self-hosted verification. GitHub Actions should stay manual fallback, and Dependabot should stay off, unless the repo documents `SANEAPPS_GITHUB_HOSTED_EXCEPTION: <reason>`.

## Definition Of Done

- Code matches existing patterns.
- Relevant tests, lint, or validation ran.
- User-facing docs changed if behavior or workflow changed.
- Open questions and risks are written down plainly.

## Shared UI Source Of Truth

- For settings, About, license, updater, button-style, or typography work, inspect `~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
- Extend shared SaneUI components instead of creating app-local settings chrome.
- Use shared `SaneSettingsContainer`, `SaneAboutView`, `LicenseSettingsView`, and `SaneSparkleRow` where applicable.
- In shared settings surfaces, keep all text bright white and at least 13pt.
- Do not use `.secondary`, gray helper text, `mailto:` bug-report paths, `Manage Access` copy, app-local updater rows, local `SaneSparkleRow`, or `.buttonStyle(.bordered)` in settings/About/license/update UI.

## Client Notes

- Claude: native lifecycle hooks live in `.claude/settings.json`.
- Codex: shared repo skills live in `.agents/skills/`.
- Everyone: shared safety and SOP checks should be enforced through repo scripts, MCP, git hooks, and shell guards.
