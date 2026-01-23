# SaneProcess SOP Context

You are working on **SaneProcess** - the SOP enforcement framework itself.

## Project Purpose
- Public repo for sale/distribution
- Contains: docs, examples, hooks, skills, init scripts
- Users install via `curl -sL https://raw.githubusercontent.com/sane-apps/SaneProcess/main/scripts/init.sh | bash`

## Key Files
| Path | Purpose |
|------|---------|
| `docs/` | User documentation |
| `examples/` | Example configurations |
| `scripts/hooks/` | Hook templates |
| `scripts/init.sh` | Installation script |
| `skills/` | Skill templates |

## When Editing
- Keep docs clear and beginner-friendly
- Test examples actually work
- Maintain consistency with SaneBar/SaneVideo implementations

## Memory

**Memory MCP** - Curated knowledge graph
- Run `mcp__memory__read_graph` at session start
- Cross-project context, bug patterns
- On "session end": save learnings via `mcp__memory__add_observations`

**claude-mem** - ⚠️ DISABLED (2026-01-11)
- Reason: Orphaned process bug causing session freezes
- Issue: https://github.com/thedotmack/claude-mem/issues/685
- Re-enable when fixed: set `claude-mem@thedotmack: true` in settings.json
