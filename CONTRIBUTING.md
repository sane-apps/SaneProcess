# Contributing to SaneProcess

Thanks for your interest in contributing to SaneProcess! This document explains how to get started.

---

## What is SaneProcess?

SaneProcess is an SOP (Standard Operating Procedure) enforcement framework for AI-assisted development with Claude Code. It helps developers ship reliable code through:

- 16 Golden Rules for AI-assisted development
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
└── .claude/                # Claude Code configuration
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
