# Codex Control-Plane Helpers

This directory is the canonical git-owned source for the operator-facing helpers
that get installed into `~/.codex/bin/`.

Files:

- `check-mcps`: live active-session MCP probe
- `github-mcp-bridge.mjs`: GitHub MCP bridge wrapper
- `xcode-mcpbridge-wrapper.sh`: stable Xcode MCP bridge launcher

Do not edit only `~/.codex/bin/*` and call it done.

Canonical workflow:

```bash
ruby scripts/SaneMaster.rb sync_mini
```

That command:

1. installs these repo-owned helpers into local `~/.codex/bin/`
2. mirrors them to the Mini
3. parity-checks the Mini copies

Use `ruby scripts/SaneMaster.rb mcp_watchdog doctor` for background-machine MCP state.
Use `~/.codex/bin/check-mcps` for the live active-session MCP probe.
