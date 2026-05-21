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
| Codex | `scripts/init.sh --client codex` | `AGENTS.md`, `.agents/skills`, Codex config, MCP, shell/script guards |
| Other agents | `scripts/init.sh --client generic` | `AGENTS.md`, repo scripts, git hooks, optional MCP |
| SaneApps full setup | `scripts/init.sh --client all` | Claude + Codex-compatible surfaces for internal use |

Codex and other clients may support hooks differently. Rules that matter for
public portability must remain enforceable through repo scripts and shared
guards, not only through one client runtime.

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
