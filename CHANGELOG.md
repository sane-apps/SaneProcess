# Changelog

All notable changes to SaneProcess are documented here.

---

## [2.4] - January 2026

### Added
- 16 Golden Rules for AI-assisted development
- Consolidated enforcement hooks (saneprompt, sanetools, sanetrack, sanestop)
- Circuit breaker pattern (trips at 3 consecutive failures)
- Cross-session memory for bug patterns
- SaneMaster CLI tool with 19 subcommands
- 259 hook tests
- Skills system for domain-specific knowledge
- Cross-project sync capability

### Technical
- Ruby 3.0+ required
- Integration with Claude Code MCP servers
- File-based state management with signatures

---

## Version Numbering

SaneProcess follows [Semantic Versioning](https://semver.org/):
- MAJOR: Breaking changes to rules or hooks
- MINOR: New rules, hooks, or features
- PATCH: Bug fixes and documentation
