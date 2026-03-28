# Contributing to SaneProcess

Thanks for your interest in contributing to SaneProcess! This document explains how to get started.

---

## What is SaneProcess?

SaneProcess is an SOP (Standard Operating Procedure) enforcement framework for AI-assisted development with Claude Code, Codex, and compatible coding agents. It helps developers ship reliable code through:

- 17 Golden Rules for AI-assisted development
- Automated compliance hooks
- Circuit breaker pattern for error prevention
- Cross-session memory for bug patterns

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/sane-apps/SaneProcess.git
cd SaneProcess

# Install dependencies
bundle install

# Run QA checks
./scripts/qa.rb
```

---

## Project Structure

```
SaneProcess/
├── AGENTS.md               # Shared agent instructions
├── CLAUDE.md               # AI instructions
├── README.md               # Product overview
├── DEVELOPMENT.md          # Build, test, contribute
├── ARCHITECTURE.md         # System design, decisions, research
├── SESSION_HANDOFF.md      # Recent work (ephemeral)
├── docs/
│   ├── SaneProcess.md      # Complete SOP (1,400+ lines)
│   └── archive/            # Confidential docs (gitignored)
├── scripts/
│   ├── SaneMaster.rb       # Main CLI tool
│   ├── hooks/              # Enforcement hooks (313 tests)
│   └── sanemaster/         # CLI subcommands
├── templates/              # Project templates
├── skills/                 # Domain-specific knowledge modules
├── .claude/                # Claude Code hook configuration
└── .agents/                # Repo skills for Codex-compatible clients
```

---

## Making Changes

### Before You Start

1. Check [GitHub Issues](https://github.com/sane-apps/SaneProcess/issues) for existing discussions
2. For significant changes, open an issue first to discuss the approach

### Pull Request Process

1. **Fork** the repository
2. **Create a branch** from `main`
3. **Make your changes**
4. **Run QA**: `./scripts/qa.rb`
5. **Submit a PR** with clear description

### Commit Messages

```
type: short description

Fixes #123
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`

---

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Please be respectful and constructive.

---

## Questions?

- Open a [GitHub Issue](https://github.com/sane-apps/SaneProcess/issues)

Thank you for contributing!

<!-- SANEAPPS_AI_CONTRIB_START -->
## Become a Contributor (Even if You Don't Code)

Are you tired of waiting on the dev to get around to fixing your problem?  
Do you have a great idea that could help everyone in the community, but think you can't do anything about it because you're not a coder?

Good news: you actually can.

Copy and paste this into Claude or Codex, then describe your bug or idea:

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
