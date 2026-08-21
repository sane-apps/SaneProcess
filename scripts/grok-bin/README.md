# Grok Control-Plane Helpers

This directory is the canonical git-owned source for the operator-facing helpers
that get installed into `~/.grok/bin/` (or surfaced via PATH / completions for Grok sessions).

Files:

- `README.md` — this file
- `check-mcps` — live Grok MCP probe
- `cloudflare-mcp-remote.sh` — token-backed Cloudflare admin MCP (`~/.config/nv/env` then Keychain)
- `xcode-mcp.sh` / `xcode-mcp-frame.py` — Mini `mcpbridge`. Air Grok uses the Mini HTTP singleton at `http://127.0.0.1:37915/mcp` through the AgentMemory tunnel. `--framed` is the Content-Length path for that singleton.

Do not edit only `~/.grok/bin/*` and call it done. `sync_grok` overlays these helpers onto `~/.grok/bin` and must never `--delete` that directory (the official Grok CLI binary lives there).

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
