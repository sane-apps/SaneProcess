# Grok Control-Plane Helpers

This directory is the canonical git-owned source for the operator-facing helpers
that get installed into `~/.grok/bin/` (or surfaced via PATH / completions for Grok sessions).

Files (initial):

- `README.md` — this file
- Future thin shims will live here (MCP probes, SaneMaster convenience wrappers, Grok-specific status helpers, etc.)

Do not edit only `~/.grok/bin/*` and call it done.

Canonical workflow:

```bash
ruby scripts/SaneMaster.rb sync_grok
```

That command:
1. installs these repo-owned helpers into local `~/.grok/bin/` (or the active Grok-visible bin surface)
2. mirrors helpers, `.agents/skills`, and `~/.grok/config.toml` when present to the Mini (via the paired sync-grok-mini.sh)
3. prints any remote-copy warning so the operator can restart Grok only after the target machine has the expected files

Use `ruby scripts/SaneMaster.rb tool_discovery --query "grok"` or the new sync for background-machine Grok state.
Use the live Grok TUI (`/mcps` or Ctrl+L) for session MCP truth — native `grok mcp list` may be incomplete when using compatibility configs.

Start small: only add a helper here when it is actually used from Grok sessions and needs to be kept in sync across machines.
