# SaneProcess Development Guide

> [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md)

Concise build, test, and contribution guide. Detailed release playbooks live in
`templates/RELEASE_SOP.md`, implementation details live in `ARCHITECTURE.md`,
and command help lives in `./scripts/SaneMaster.rb help <category>`.

## Quick Start

```bash
ruby scripts/SaneMaster.rb verify                 # canonical full verification
ruby scripts/hooks/test/tier_tests.rb             # hook enforcement suite
ruby scripts/SaneMaster.rb tool_discovery --query "..." # tool/MCP proof receipt
ruby scripts/SaneMaster.rb process_metrics --export-otel outputs/process-traces.json
cd /tmp/repo && /path/to/SaneProcess/scripts/init.sh --client generic
```

## SaneApps Operator Overlay

The following defaults describe the private SaneApps production runner. Public
adopters should treat this as an example and substitute their own canonical
runner, host, and release evidence path.

Mini-first is mandatory for SaneApps repo inspection, build, test, screenshots,
runtime verification, release proof, and customer-facing evidence. Local MacBook
Air fallback is allowed only when `ssh mini` fails, the Mini route is otherwise
unavailable for that task, or the user explicitly approves a local exception for
that exact task. `Inconvenient`, `slower`, or `already open locally` are not
fallback reasons.

Public adopters do not need a Mac Mini. Replace Mini-first with your own
canonical runner or local verification command, then route it through
`SaneMaster.rb` so agents have one safe path to call.

Non-doc edits are not complete just because a hook saw a command that looked like
a test. Completion gates require a fresh counted `SaneMaster.rb verify` metric
with tested evidence and a source fingerprint matching the current repo.

## Documentation Standard

- Keep durable public docs in the core set: `README.md`, `DEVELOPMENT.md`,
  `ARCHITECTURE.md`, `AGENTS.md`, and `SESSION_HANDOFF.md`.
- `SESSION_HANDOFF.md` is active state only, not a history archive.
- Put release mechanics in `templates/RELEASE_SOP.md`.
- Put private/operator setup details in `DEVELOPER_SETUP.md`.
- Do not create orphan docs; improve the nearest existing owner first.

## Client Compatibility

SaneProcess has one SOP with multiple client adapters.

| Client | Install mode | Stable surface |
|--------|--------------|----------------|
| Claude Code | `scripts/init.sh --client claude` | `AGENTS.md`, `.claude/settings.json`, hooks, skills, MCP, shared scripts |
| Codex | `scripts/init.sh --client codex` | `AGENTS.md`, `.agents/skills`, shell/script guards; Codex config/MCP/approval policy stays client-managed |
| Grok | `scripts/init.sh --client grok` | `AGENTS.md`, `.agents/skills`, shell/script guards; operator sync can mirror existing `~/.grok/config.toml` |
| Other agents | `scripts/init.sh --client generic` | `AGENTS.md`, repo scripts, git hooks, optional MCP |
| SaneApps full setup | `scripts/init.sh --client all` | Claude + Codex-compatible surfaces for internal use |

Codex, Grok, and other clients may support hooks and MCP discovery differently.
Grok can load MCP servers from compatibility config while `grok mcp list` only
reports native Grok config, so use the live `/mcps` or Ctrl+L view for session
truth. Rules that matter for public portability must remain enforceable through
repo scripts and shared guards, not only through one client runtime.

### For Grok users (practical steps)

After `scripts/init.sh --client grok` in a repo:

1. Confirm the portable surface is present:
   ```bash
   test -f AGENTS.md && test -d .agents/skills
   ```

2. In the Grok TUI, read the rules (Grok surfaces AGENTS.md from the repo root or via skills):
   - Start every substantial task by reading the nearest AGENTS.md.
   - Use `ruby scripts/SaneMaster.rb tool_discovery --query "..."` before claiming any tool/MCP is missing (this produces a dated receipt in outputs/tool-discovery/).

3. Live MCP truth (important) + 2026-05-29 fix:
   - `/mcps` or Ctrl+L inside the Grok session — this is the source of truth.
   - The helper `scripts/grok-bin/check-mcps` (after a `sync_grok`) prints the same advice plus runs the canonical receipt.
   - On SaneApps operator machines, core Sane servers may be registered natively in `~/.grok/config.toml` with 15-30s startup timeouts. Fresh `init.sh --client grok` does not write user-level Grok config; use your client's MCP setup path, then `sync_grok` can mirror an existing config to the Mini.
   - If any still show connecting after TUI restart: the uvx/git+ ones can be slow on first handshake; the native timeouts give them headroom. Use the /mcps modal to toggle or inspect logs.
   - Native `grok mcp list` shows only the toml entries; the full active set (including compatibility) is in the TUI modal.

4. PreToolUse / PostToolUse warnings or annotations (if you see them):
   - Grok merges hooks from ~/.claude/settings.json (and project .claude/ if trusted) for Claude Code compatibility.
   - SaneProcess populates that surface with saneprompt, sanetools + sane_* guards (PreToolUse), sanetrack + task_completed_gate + sanestop (PostToolUse), etc.
   - Even guarded entries can produce visible annotations/notifications in the Grok scrollback on every tool call (search_replace, read_file, run_terminal_cmd, todo_write, etc.) because Grok records hook execution.
   - This is expected when the same machine runs both Claude Code and Grok heavily on Sane repos. Passive tracking/session hooks no-op under Grok; high-risk launch, release, ship, and email guards still block if Grok invokes them.
   - Inspect/disable at runtime: /hooks or Ctrl+L \u2192 Hooks tab.
   - The portable SaneProcess contract for Grok is unchanged: AGENTS.md + explicit SaneMaster.rb + shell guards. Native Pre/Post hooks are an adapter layer, not the only enforcement surface.

5. Common SaneProcess commands from Grok:
   - `ruby scripts/SaneMaster.rb verify`
   - `ruby scripts/SaneMaster.rb status`
   - `ruby scripts/SaneMaster.rb release_preflight`
   - `ruby scripts/SaneMaster.rb sync_grok` (operator only — keeps your Grok profile in sync with the Mini)

6. Shared skills (critic, docs-audit) land in `.agents/skills/`. Load them via your client's skill mechanism or invoke the SKILL.md prompts directly when needed.

The portable enforcement contract for Grok (and Codex, generic agents) is **AGENTS.md + explicit calls to SaneMaster + shell guards**. High-risk native hook entries may still block dangerous commands when Grok invokes them; passive tracking annotations are safe to ignore or disable per-session for pure Grok workflows.

## Core Rules

SaneProcess enforces the scientific method for coding agents:

| Rule | Meaning |
|------|---------|
| Verify before trying | Read local code and check uncertain APIs/tools before editing |
| Two failures means stop | Read the error and research the real API before continuing |
| Green means done | Do not claim completion with failing tests |
| No test, no rest | Fixes need meaningful tests; tautologies do not count |
| Use house tools | Use SaneMaster and shared wrappers for stateful workflows |
| Write it down | Bugs, process misses, and durable tool changes go to memory + handoff |

Full behavioral policy lives in `AGENTS.md`; hooks and shared scripts enforce
the parts that can be automated.

## Project Structure

```text
scripts/
  SaneMaster.rb              # primary CLI
  hooks/                     # Claude/native hook runtime + shared guards
  sanemaster/                # SaneMaster command modules
  mini/                      # Mac Mini build/test/training helpers
  automation/                # vendor/API automation helpers
templates/                   # release, bootstrap, and project templates
```

## SaneMaster Commands

Prefer SaneMaster over raw commands for workflows with state, safety, or
receipts. Run `ruby scripts/SaneMaster.rb` or `help <category>` for full help.

| Need | Command |
|------|---------|
| Full build/test | `ruby scripts/SaneMaster.rb verify` |
| UI-inclusive verify | `ruby scripts/SaneMaster.rb verify --ui` |
| Tool/MCP discovery | `ruby scripts/SaneMaster.rb tool_discovery --query "..."` |
| Test quality scan | `ruby scripts/SaneMaster.rb test_scan -v` |
| Process eval | `ruby scripts/SaneMaster.rb process_eval --json` |
| Prompt routing eval | `ruby scripts/SaneMaster.rb agent_eval --json` |
| Skill routing lint | `ruby scripts/SaneMaster.rb skill_lint --json` |
| App release preflight | `ruby scripts/SaneMaster.rb release_preflight` |
| Active App Store lane | `ruby scripts/SaneMaster.rb appstore_preflight` |
| Runtime launch/proof | `ruby scripts/SaneMaster.rb test_mode` plus app-specific `customer_ui_sweep`, or `visual_smoke` only when no app sweep exists |
| Support inbox | `ruby scripts/SaneMaster.rb check_inbox` |
| Sales/download/funnel | `sales`, `downloads`, `events` |
| Machine cleanup | `ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply` |

## Testing

Use the registry-backed verify path before calling work done:

```bash
ruby scripts/SaneMaster.rb verify --timeout 900
```

Useful focused tests:

```bash
ruby scripts/validation_report_test.rb
ruby scripts/sanemaster/agent_workflow_test.rb
ruby scripts/sanemaster/meta_test.rb
ruby scripts/sanemaster/release_guardrail_test.rb
ruby scripts/appstore_submit_guardrail_test.rb
ruby scripts/mini/bootstrap_build_server_test.rb
```

Test registry policy:

- Every script test-like file needs an explicit entry in `scripts/test_registry.json`.
- `required` entries run in full `verify`.
- `manual` entries must explain why they are not part of default verify.
- Zero-test green runs are weak evidence and should not be treated as done.

## Release And App Store

Direct release path:

```bash
ruby scripts/SaneMaster.rb release_preflight
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project "$(pwd)" --full --version X.Y.Z --notes "..." --deploy
```

App Store lanes are active only when `.saneprocess` enables them:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/mini/bootstrap-build-server.sh
ruby scripts/SaneMaster.rb appstore_preflight
```

Release rules:

- Bump version before release; Sparkle ignores same-version updates.
- Direct-only apps do not run App Store lanes unless deliberately re-enabled.
- Customer-facing UI or runtime claims need Mini proof and clean saved evidence.
- For App Store submission/resubmission, first run the Mini `customer_ui_sweep`
  on the candidate build in the current session or on the same calendar day, and
  capture per-action screenshots for every reviewer/customer-facing state
  required by the lane.
- Record screenshot paths plus a written verdict in `SESSION_HANDOFF.md` or
  `outputs/visual-audit*/`, then run `ruby scripts/SaneMaster.rb appstore_preflight`.
- Submit only if both fresh visual proof and `appstore_preflight` are green for
  the same candidate build. Do not reuse stale direct-release screenshots as App
  Store proof.
- Private signing, ASC, notary, and R2 setup details live in `DEVELOPER_SETUP.md`.

## Runtime And Visual Evidence

- Use `sane_test.rb` or `SaneMaster.rb test_mode`; do not manually open app
  bundles for SaneApps proof.
- Use the app-specific `customer_ui_sweep` when it exists. Use `visual_smoke`
  only when no app-specific sweep exists.
- Obstructed, clipped, partial, or helper-window-contaminated screenshots are
  invalid.
- Hidden macOS prompts can invalidate app-window-only screenshots; check full
  desktop/AX state when a GUI flow is stuck or contradictory.

## MCP And Tooling

Portable path first: scripts, docs, local receipts, and SaneMaster. Optional
MCPs do not become required proof paths unless repo config or a test explicitly
requires them.

Optional accelerators:

- Apple `xcrun mcpbridge` / `xcode`: IDE-native Xcode context.
- XcodeBuildMCP: iOS simulator build-run proof, UI automation, LLDB/device, and
  coverage workflows.
- `central-memory`: semantic recall when configured.
- Cloudflare API MCP/plugin: read-only Pages/R2/Worker drift checks.

Health checks:

```bash
ruby scripts/SaneMaster.rb mcp_watchdog doctor
~/.codex/bin/check-mcps
```

Tool discovery and MCP health answer different questions:

- `ruby scripts/SaneMaster.rb tool_discovery --query "..."` answers whether a
  canonical tool path already exists.
- `ruby scripts/SaneMaster.rb mcp_watchdog doctor` and
  `~/.codex/bin/check-mcps` answer whether optional MCP helpers are healthy.
- A green MCP check does not clear repo validation. A red repo validation run
  does not prove a tool is missing.
- Run the tool-discovery receipt before proposing a new tool, wrapper, or
  repeated workaround.

## Support And Business Signals

- Work email means `hi@saneapps.com` through `check-inbox.sh`; do not use Gmail
  unless explicitly requested.
- Always run `check-inbox.sh review <id>` before reply or resolve.
- Every outbound support reply requires the exact approval flow: show the exact
  draft, run `present-draft` or `present-batch`, wait for explicit approval, run
  `approve ... --user-approval "<quote>"`, then send in a separate command.
- Do not combine approval and send. Do not replace this flow with manual API calls.
- For sales, downloads, and funnel questions use `SaneMaster.rb sales`,
  `downloads`, and `events`; do not hand-roll vendor API curls.

## Before Pushing

```bash
git diff --check
ruby scripts/SaneMaster.rb test_scan -v
ruby scripts/SaneMaster.rb agent_eval --json
ruby scripts/SaneMaster.rb process_eval --json
ruby scripts/SaneMaster.rb skill_lint --json
ruby scripts/SaneMaster.rb verify --timeout 900
```

Do not commit or push unless the user asks, the task explicitly includes
release/PR/publish, or a project workflow requires it.

## Fresh Install Testing

Use a temporary directory, not an existing app repo:

```bash
tmp="$(mktemp -d)"
mkdir -p "$tmp/generic"
ruby scripts/init.sh --client generic "$tmp/generic"
```

For public portability, generic installs should avoid SaneApps-private hosts,
accounts, keys, and release assumptions.
