# SaneProcess SOP Context

You are working on **SaneProcess** - the SOP enforcement framework itself.

## Project Purpose
- Public repo for sale/distribution
- Contains: docs, examples, hooks, skills, init scripts
- Users install via `curl -sL https://raw.githubusercontent.com/stephanjoseph/SaneProcess/main/scripts/init.sh | bash`

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
Run `mcp__memory__read_graph` at session start for cross-project context.
