# Contributing to SaneProcess

Thanks for your interest in contributing to SaneProcess.

## What It Is

SaneProcess is workflow enforcement for AI-assisted development across compatible coding agents. It combines client-neutral instructions, native hook adapters, skills/MCP guidance, `SaneMaster.rb` wrappers, and shared runtime guards.

## Quick Start

```bash
git clone https://github.com/sane-apps/SaneProcess.git
cd SaneProcess

ruby scripts/SaneMaster.rb verify
```

There is no `Gemfile` today. Use the system Ruby or your normal Ruby install.

## Project Structure

```text
SaneProcess/
  AGENTS.md             Client-neutral agent instructions
  README.md             Public overview and install path
  DEVELOPMENT.md        Commands, workflow, and definition of done
  ARCHITECTURE.md       System design and durable decisions
  SECURITY.md           Security and reporting policy
  scripts/
    SaneMaster.rb       Main workflow CLI
    hooks/              Native hook layer
    sanemaster/         CLI command modules
    automation/         Helper scripts behind canonical wrappers
  templates/            Project/docs/release/UI templates
  skills/               Reusable agent skills
```

`SESSION_HANDOFF.md`, `.claude` runtime state, and archive snapshots are local operator artifacts, not public source-of-truth docs.

## Before You Start

1. Check existing [issues](https://github.com/sane-apps/SaneProcess/issues).
2. For significant behavior changes, open an issue first.
3. Read `AGENTS.md` and `DEVELOPMENT.md`.
4. Prefer updating existing docs/scripts over adding parallel files.

## Pull Request Process

1. Fork the repository.
2. Create a branch from `main`.
3. Make the smallest focused change.
4. Run the relevant verification.
5. Open a PR with a clear summary and test evidence.

Useful checks:

```bash
ruby scripts/SaneMaster.rb verify
ruby scripts/hooks/test/tier_tests.rb
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
```

Hook and repo test counts change as registry-backed tests are added. Treat `ruby scripts/SaneMaster.rb verify` as the source of truth.

## Commit Messages

```text
type: short description

Fixes #123
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

## Code Of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Please be respectful and constructive.

## Questions

Open a [GitHub Issue](https://github.com/sane-apps/SaneProcess/issues).

<!-- SANEAPPS_AI_CONTRIB_START -->
## Become a Contributor (Even if You Don't Code)

Are you tired of waiting on the dev to get around to fixing your problem?  
Do you have a great idea that could help everyone in the community, but think you can't do anything about it because you're not a coder?

Good news: you actually can.

Copy and paste this into your preferred coding agent, then describe your bug or idea:

```text
I want to contribute to this repo, but I'm not a coder.

Repository:
https://github.com/sane-apps/SaneProcess

Bug or idea:
[Describe your bug or idea here in plain English]

Please do this for me:
1) Understand and reproduce the issue (or understand the feature request).
2) Make the smallest safe fix.
3) Open a pull request to https://github.com/sane-apps/SaneProcess
4) Give me the pull request link.
5) Open a GitHub issue in https://github.com/sane-apps/SaneProcess/issues that includes:
   - the pull request link
   - a short summary of what changed and why
6) Also give me the exact issue link.

Important:
- Keep it focused on this one issue/idea.
- Do not make unrelated changes.
```

If needed, you can also just email the pull request link to hi@saneapps.com.

I review and test every pull request before merge.

If your PR is merged, I will publicly give you credit, and you'll have the satisfaction of knowing you helped ship a fix for everyone.
<!-- SANEAPPS_AI_CONTRIB_END -->
