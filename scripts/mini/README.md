# Mac Mini Server Scripts

Source of truth for the always-on SaneApps Mac mini. The Mini is a build, test,
automation, browser-proof, and shared-memory server. Local AI training and the
SaneAI/SaneSync runtime are retired.

## Air To Mini Access

Use the same command on or off the local network:

```bash
ssh mini 'hostname; whoami; pwd'
```

The controller configuration at `~/.ssh/config.d/saneapps-mini.conf` invokes
`~/.local/bin/saneapps-mini-proxy` and selects the first private route that is
available:

1. Bonjour LAN: `stephans-mac-mini.local`.
2. Tailscale: `stephans-mac-mini` on the MrSaneApps tailnet.

There is no public Cloudflare quick-tunnel fallback. Both Macs are already
enrolled in Tailscale and report no device-key expiry. The Mini runs the
root-owned Homebrew tailscaled LaunchDaemon. The Air runs the authenticated
userspace `com.saneapps.tailscaled-userspace` LaunchAgent with `RunAtLoad` and
`KeepAlive`, so off-LAN access returns after normal Air login.

The controller installer also owns `~/.local/bin/tailscale`. That thin wrapper
selects the userspace socket automatically when present, so ordinary commands
such as `tailscale status`, `tailscale ping`, and `tailscale nc` work without a
machine-specific `--socket` flag.

Install or repair the Air configuration:

```bash
bash scripts/mini/install-mini-ssh-config.sh
ssh -G mini | grep -E '^(hostname|proxycommand|identityfile) '
ssh mini 'hostname; whoami'
```

After client or machine restarts, run the deterministic read-only acceptance
from the Air before beginning normal work:

```bash
ruby scripts/SaneMaster.rb server_acceptance
```

It writes JSON and Markdown receipts under `outputs/restart-acceptance/` and
fails closed on dependency drift, private-route failure, server-service drift,
repository mismatch, or memory checksum mismatch. Browser/UI and full app
build matrices remain separate because those require their canonical tools.

Use `ssh mini-lan` only to diagnose same-network Bonjour. If LAN is unavailable,
`ssh mini` automatically uses Tailscale. If both private routes fail, the proxy
fails clearly rather than hiding the outage behind an ephemeral hostname.

## Mini To Air Access

The return route is intentionally available for recovery and bidirectional
operations. It uses a dedicated Mini-only key instead of forwarding the Air's
SSH agent or reusing GitHub/signing credentials:

```bash
bash scripts/mini/install-air-return-ssh.sh
ssh air 'hostname; whoami'
```

The installer adds the public half to the Air once, pins `air` to its Tailscale
address, disables agent forwarding, and leaves a normal interactive shell
available. Both machines must still be authenticated to the private tailnet.

## Shared Memory And Cross-Machine Drift

The Mini owns the shared AgentMemory worker on loopback port 3111:

```bash
launchctl print gui/$(id -u)/com.saneapps.agentmemory
agentmemory status
```

`com.saneapps.agentmemory` is a user LaunchAgent with `RunAtLoad`, unsuccessful-
exit keepalive, a 30-second throttle, explicit `HOME`, and working directory
`/Users/stephansmac`. Its supervisor checks the real HTTP health surface, not
just the long-lived Node wrapper; two consecutive health failures terminate the
whole worker with a nonzero exit so launchd restarts it. The working directory
is required because AgentMemory's database is `~/data/state_store.db`. The Air uses
`scripts/automation/agentmemory-mcp-air.sh` to create a bounded SSH tunnel to
the Mini and then starts the stdio MCP shim.

File-backed Claude, Serena, and Codex memories are synchronized from the Air at
login and every 15 minutes by `com.saneapps.memory-sync`. The implementation is
`scripts/automation/sync-memory-mini.sh`:

- cross-host lock with stale-lock recovery;
- backup-first, no-delete operation;
- checksum verification;
- newest-mtime selection with losing same-file versions retained as
  `.sane-conflict-*` files on both Macs;
- clean skip when the Mini is temporarily unreachable;
- non-clobbering Mini dirty-work snapshots pulled into the Air outputs folder.

Run an exact interactive verification from the Air:

```bash
bash scripts/automation/sync-memory-mini.sh mini --strict
```

GitHub `main` is the source of truth for code. `git-sync-safe.sh` fast-forwards
clean repos and pushes clean committed `main`/`master` work; it never auto-
commits or auto-stashes. Dirty work is not raw-mirrored. Instead,
`--snapshot-only` preserves current tracked/untracked file archives plus
deletion, staging, status, and base receipts under
`outputs/dirty-work-snapshots/`; it never stores removed-line or deleted-file
preimages that may contain retired secrets. The Air pulls those snapshots every
15 minutes. Dirty or divergent repos remain loud until a human commits or
reconciles them.

The old Air `com.saneapps.repo-reconcile` job stays disabled while canonical app
repos contain intentional dirty work. Enable it only after both machines are on
the same clean branches.

## Always-On And Restart Policy

The Mini never performs a daily shutdown or restart.

- macOS sleep, display sleep, and disk sleep are disabled.
- Restart after power failure is enabled.
- `mini-memory-guard.sh` performs daily restart-free hygiene. Its deep cleanup
  has a 20-minute process-group deadline and never invokes a power command.
- Routine cleanup preserves Downloads and the user's entire Trash, rejects
  symlinked roots/children, and only trashes allowlisted generated artifacts.
- A root-owned weekly restart gate runs Sunday at 10:30, 11:30, and 12:30. The
  later times are same-day retries if active work blocks the first attempt.
- Weekly restart requires FileVault off, automatic login as `stephansmac`, at
  least six days uptime, no active server work/SSH/install/recording process,
  no recent SaneMaster maintenance inhibit or Codex task writes, and no local
  keyboard or mouse activity in the previous 30 minutes.

Inspect the live policy:

```bash
pmset -g custom
launchctl print gui/$(id -u)/com.saneapps.memory-guard
sudo launchctl print system/com.saneapps.weekly-restart
tail -50 ~/SaneApps/outputs/memory-guard.stdout.log
sudo tail -50 /var/log/sane-mini-weekly-restart.log
```

## Active Scripts

| Script | Schedule | Purpose |
|---|---:|---|
| `install-mini-ssh-config.sh` | On demand on Air | Installs LAN to Tailscale `ssh mini` routing |
| `install-air-return-ssh.sh` | On demand on Mini | Installs dedicated Tailscale `ssh air` return routing |
| `saneapps-mini-proxy.sh` | Every `ssh mini` | Chooses LAN, then Tailscale |
| `mini-install-agentmemory.sh` | On demand on Mini | Installs restart-durable shared memory worker |
| `mini-prepare-automation-root.sh` | On demand | Refreshes clean build/test automation clones |
| `mini-install-nightly-agent.sh` | On demand | Installs the nightly build/report agent |
| `mini-nightly.sh` | 8:45 AM daily | Builds/tests active repos and writes the nightly report |
| `mini-memory-guard.sh` | 5:40 AM daily | Restart-free hygiene with bounded deep cleanup |
| `mini-install-memory-guard.sh` | On demand | Installs the daily hygiene LaunchAgent |
| `mini-weekly-restart.sh` | Sunday retry windows | Root guarded weekly restart |
| `mini-install-weekly-restart.sh` | On demand | Installs the root helper and LaunchDaemon |
| `bootstrap-build-server.sh` | On demand | Proves headless signing and App Store credentials |
| `mini-gui-run.sh` | Wrapper/manual | Runs work in the logged-in Mini GUI session |
| `mini-visual-workspace-guard.sh` | Before proof | Clears contaminated screenshot/runtime state |

The nightly job runs one bounded `SaneMaster.rb verify` per active automation
checkout. Its PID-owned lock is recovered only after the recorded owner exits;
verification, automation-root cleanup, and operator-brief generation each have
an explicit process-group deadline.

The former `mini-daytime-cleanup.sh`, `mini-license-test.sh`, and
`mini-codex-keepalive.sh` entry points are retired. They were unowned one-off
tools with unsafe effects (purging login items, deleting live license state, or
installing/opening Codex). `deploy.sh` disables the legacy keepalive label and
moves installed copies to Trash. Supported cleanup, license verification, and
Codex control-plane work must use their canonical SaneMaster or automation
workflows.

## Deployment

```bash
# Refresh active Mini scripts and enforce retirement of legacy training agents
bash scripts/mini/deploy.sh

# Air-only control-plane sync. This refuses Mini loopback and never touches
# automation databases or file-backed memories.
ruby scripts/SaneMaster.rb sync_mini

# Direct helper when debugging the wrapper
bash scripts/automation/sync-codex-mini.sh mini --no-restart
```

`sync-codex-mini.sh` rewrites the Air-specific AgentMemory tunnel configuration
to the Mini's direct `npx -y @agentmemory/mcp` loopback configuration. Production
Codex automation records remain API-owned and Mini-only; use `automation_update`
for those records.

## Release And GUI Work

Before a headless App Store release:

```bash
bash scripts/mini/bootstrap-build-server.sh
```

This proves login-keychain access, signing partition-list access, App Store
Connect JWT authentication, and installed signing identities. If it fails, stop
and repair the environment instead of bypassing the canonical release path.

When signing must run in the auto-logged-in GUI session:

```bash
ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh \
  --title "SaneSales archive" \
  --log-file /tmp/sanesales-archive.log \
  --close-window \
  -- "cd ~/SaneApps/apps/SaneSales && ruby scripts/SaneMaster.rb verify"'
```

Reclaim stale automation windows with:

```bash
ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-reclaim-automation-windows.sh --all --hide-terminal'
```

## Live Launchd Inventory

```text
~/Library/LaunchAgents/com.saneapps.nightly.plist
~/Library/LaunchAgents/com.saneapps.memory-guard.plist
~/Library/LaunchAgents/com.saneapps.agentmemory.plist
/Library/LaunchDaemons/homebrew.mxcl.tailscale.plist
/Library/LaunchDaemons/com.saneapps.weekly-restart.plist
```

Retired training, SaneAI, SaneSync, benchmark, Setapp, Grammarly, Logos, Zoom,
and Cloudflare quick-tunnel agents must remain absent or disabled.
