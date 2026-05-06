# SaneProcess - GitHub Copilot Instructions

## Project Overview

SaneProcess is workflow enforcement for AI-assisted development across Claude Code, Codex, and compatible coding agents.

It provides:

- Client-neutral `AGENTS.md` operating rules
- Claude-native lifecycle hooks
- Codex-compatible skills, MCP guidance, and shared runtime guards
- `SaneMaster.rb` wrappers for verify, release, status, tool discovery, support, Mini sync, metrics, and quality checks
- SaneUI guardrails for shared settings/About/license/update surfaces

## Source Of Truth

Read these before making non-trivial changes:

1. `AGENTS.md` for active rules and mandatory workflows
2. `DEVELOPMENT.md` for commands and definition of done
3. `ARCHITECTURE.md` for system design and durable decisions
4. `SESSION_HANDOFF.md` for current status when it exists

Use `CLAUDE.md` only for Claude-specific overlay behavior. Do not put general policy only in Claude files.

## Code Structure

```text
scripts/
  SaneMaster.rb        Main workflow CLI
  sanemaster/          SaneMaster command modules
  hooks/               Claude-native hooks and tests
  mini/                Mac Mini runtime/build-server scripts
  automation/          Automation helpers behind SaneMaster paths
  codex-bin/           Codex helper source mirrored to ~/.codex/bin/
skills/                Reusable agent skills
templates/             Project/docs/release/UI templates
.github/               GitHub metadata and assistant instructions
```

## Rules For Changes

- Use plain English in docs.
- Prefer updating existing docs/scripts over creating new parallel files.
- Use `SaneMaster.rb` wrappers for stateful workflows instead of raw command chains.
- Do not claim done without running the relevant verification or explicitly saying what was not run.
- Keep SaneProcess agent-neutral unless a section is explicitly about one client.
- Preserve public safety: no secrets, private contact details, local-only state, or generated runtime caches in tracked files.

## SaneUI Rules

For settings, About, license, updater, button-style, or typography work:

- Inspect `~/SaneApps/infra/SaneUI/Sources/SaneUICatalog/SaneUICatalogApp.swift` first.
- Use shared `SaneSettingsContainer`, `SaneAboutView`, `LicenseSettingsView`, and `SaneSparkleRow` where applicable.
- Keep shared settings text bright white and at least `13pt`.
- Do not use `.secondary`, gray helper text, `mailto:` bug-report paths, `Manage Access` copy, app-local updater rows, local `SaneSparkleRow`, or `.buttonStyle(.bordered)` in settings/About/license/update UI.
- Run `ruby scripts/SaneMaster.rb saneui_guard /path/to/app` for relevant changes.

## Verification

For SaneProcess itself:

```bash
ruby scripts/SaneMaster.rb verify
ruby scripts/validation_report.rb
```

For hook-focused work:

```bash
ruby scripts/hooks/test/tier_tests.rb
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
```

For SaneApps app runtime work, use the Mac Mini first. Do not replace Mini-first verification with local launches.
