# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x     | :white_check_mark: |
| < 2.0   | :x:                |

---

## Reporting a Vulnerability

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to: **hi@saneapps.com**

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

You should receive a response within 48 hours.

---

## Security Model

SaneProcess is a **development tooling framework** that:

1. **Runs locally** on your development machine
2. **Integrates with Claude Code** for AI-assisted development
3. **Uses file-based state** stored in `.claude/` directory
4. **Makes no network requests** — all processing is local

### Data Handling

- Session state is stored locally in `.claude/state.json`
- No data is transmitted externally
- Hook logs are stored locally and not shared

### Hook Security

The enforcement hooks (saneprompt, sanetools, sanetrack, sanestop) run as local Ruby scripts with the same permissions as your development environment. They:

- Do not execute arbitrary code
- Only read/write to designated state files
- Exit with codes 0 (allow) or 2 (block)

---

## Privacy

SaneProcess collects **zero** user data:

- No analytics
- No telemetry
- No crash reporting to external services
