<p align="center">
  <img src="assets/hero-process.jpeg" alt="SaneProcess - workflow guardrails for coding agents" width="100%">
</p>

# SaneProcess

**Workflow guardrails for coding agents and LLM-assisted development.**

SaneProcess gives coding agents a shared operating system for development work: clear instructions, stop conditions, research gates, verification commands, and release checks that keep them from looping, skipping tests, or mutating the wrong files.
Codex is the primary SaneApps toolset. Claude Code gets the strongest native hook enforcement today, and other repo-aware agents can use the same SOP through `AGENTS.md`, reusable skills, MCP, `SaneMaster.rb`, and project scripts.
The source of truth stays client-neutral so switching tools does not create a second workflow.

MIT licensed. Ruby. macOS + Linux. Used across 7 SaneApps repos.

---

## Quick Start

Install into an existing project:

```bash
git clone https://github.com/sane-apps/SaneProcess.git
cd /path/to/your-project
/path/to/SaneProcess/scripts/init.sh --client generic
```

Choose the adapter you actually use:

| Setup | Command | Installs |
|-------|---------|----------|
| Generic agent | `scripts/init.sh --client generic` | `AGENTS.md` only |
| Codex-style | `scripts/init.sh --client codex` | `AGENTS.md` + `.agents/skills` |
| Grok-style | `scripts/init.sh --client grok` | `AGENTS.md` + `.agents/skills` |
| Claude Code | `scripts/init.sh --client claude` | `AGENTS.md` + `.claude/settings.json` + native hooks |
| Full SaneApps-style setup | `scripts/init.sh --client all` | Claude hooks + `.agents/skills` |

No hosted service, SaneApps account, second machine, or specific model backend is required. The default with no flags is `--client all` so existing SaneApps workflows keep the full surface.

Verify the install path you chose:

```bash
# Every install mode
test -f AGENTS.md

# Codex, Grok, or all
test -d .agents/skills

# Claude or all
ruby scripts/hooks/saneprompt.rb --self-test
```

## What You Get

| Layer | What it does |
|-------|--------------|
| Agent rules | One `AGENTS.md` source of truth for compatible coding agents |
| Native hook adapters | Prompt classification, research gates, path blocking, completion gates, circuit breaker, and session summaries where the client supports lifecycle hooks |
| Codex/Grok path | `AGENTS.md`, `.agents/skills`, MCP when configured in the client, and shared project scripts |
| `SaneMaster.rb` | One CLI for verify, release, status, tool discovery, metrics, and quality checks |
| Shared guards | Shell/script guardrails for risky paths where a client has no native pre-tool hook |
| Optional runner adapters | Use local checks by default, or plug in your own remote runner/build host if your team has one |
| Optional policy checks | Add product-specific checks such as design-system rules behind the same wrapper pattern |

## Supported Clients

SaneProcess is intentionally layered instead of pretending every coding agent has the same API.

| Client | Install mode | What is enforced today |
|--------|--------------|------------------------|
| Claude Code | `--client claude` | Native lifecycle hooks plus `AGENTS.md`, MCP, skills, and shared scripts |
| Codex | `--client codex` | `AGENTS.md`, `.agents/skills`, and shared scripts/wrappers; Codex MCP/config/approval policy stays client-managed |
| Grok | `--client grok` | `AGENTS.md`, `.agents/skills`, client-managed MCP config, approvals/sandboxing, and shared scripts/wrappers |
| Other agents | `--client generic` | `AGENTS.md`, repo scripts, git/pre-commit checks, MCP if supported, and whatever runtime guards the client can honor |

Codex and Grok can expose MCP servers through compatibility config that does not always match the native CLI list. Use the live client MCP view for session truth (`/mcps` or Ctrl+L in Grok) and `SaneMaster.rb tool_discovery` receipts before declaring a tool missing. SaneProcess treats client hooks as adapter layers rather than the universal enforcement base. The portable contract remains `AGENTS.md` plus project-owned scripts.

Codex marketplace plugins and app connectors are optional accelerators; `AGENTS.md`, repo/global skills, and SaneMaster remain the stable SaneProcess contract.

## Core Guardrails

### Orphan cleanup

Coding agents and MCP servers can leave sidecars running after the parent session exits. SaneProcess identifies only dead-session descendants and leaves active sessions alone.

```text
Cleaned up 3 orphaned coding-agent sessions
Cleaned up 7 orphaned MCP daemons
Cleaned up 2 orphaned subagents
```

### Circuit breaker

After repeated failures, SaneProcess stops edit attempts until the root cause is handled.

```text
CIRCUIT BREAKER TRIPPED
2 strikes with the same failure family.
Reset only after fixing the root cause.
```

### Research gate

Mutation is blocked until the required research categories are satisfied. Read-only inspection stays available.

| Category | Typical sources |
|----------|-----------------|
| docs | apple-docs, context7, official references |
| web | web search or fetch when current external facts matter |
| github | GitHub issue/PR/repo context when configured |
| local | file reads, search, existing project docs |

Native hook adapters enforce this at tool time where the client exposes lifecycle hooks. Codex and compatible clients use `AGENTS.md`, skills, MCP, `SaneMaster.rb`, and shell/script guards; for those clients, the repo wrapper is the hard boundary.

## Measured Results (two blind A/B case studies)

We ran two A/B tests on real tasks: identical prompts, one arm with SaneProcess
fully enabled, one vanilla agent in a bare worktree, both scored blind by a
separate adversarial judge agent against the actual code and runtime evidence.

- **Round 1 — menu-bar app bug triage.** Quality (judge): **34 vs 27 /40**.
  Tokens: 246k vs 327k (~25% cheaper, ~3x faster). Why: the harness found the
  bug was already fixed upstream and proved it on the canonical host; the
  vanilla agent re-diagnosed it and wrote an unproven root cause into durable
  docs.
- **Round 2 — video app automation feature.** Quality (judge): **32 vs 29 /40**.
  Tokens: 424k vs 209k (~2x cost, 3 sessions). Why: the harness's work survived
  the canonical launcher's env filtering; the vanilla agent's flag silently
  no-op'd and its tests violated repo rules.

The mechanisms that did the work: session-start context loading (handoff and
release receipts), canonical-host verification, and written restraint policies
for fragile subsystems. Round 2's higher cost came from routing a scoped task
into broad release-grade verification — since fixed: `proof_plan` /
`proof_scope` now route focused work to focused proof.

Honest caveats: n=2, one operator, one codebase family, and the judge — while
blind and adversarial — was itself an LLM. Treat these as case studies, not
benchmarks. Expect the gates to cost tokens up front and pay for themselves
when a task touches state your agent would otherwise guess about.

## SaneMaster

`./scripts/SaneMaster.rb` is the canonical workflow wrapper. It prevents each repo from inventing a separate build, release, status, support, or verification path.

Useful public commands:

```bash
ruby scripts/SaneMaster.rb verify
ruby scripts/SaneMaster.rb status
ruby scripts/SaneMaster.rb release_preflight
ruby scripts/SaneMaster.rb appstore_preflight  # only when .saneprocess appstore.enabled: true
ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"
ruby scripts/SaneMaster.rb secret_scan --path /Users/sj
ruby scripts/SaneMaster.rb runtime_evidence --dry-run --break Sources/App.swift:42
ruby scripts/SaneMaster.rb visual_smoke --app ExampleApp --dry-run
ruby scripts/SaneMaster.rb process_metrics --json
ruby scripts/SaneMaster.rb process_metrics --export-otel outputs/process-traces.json
ruby scripts/SaneMaster.rb gate_review test/fixtures/gates/example.json
ruby scripts/SaneMaster.rb saneui_guard /path/to/app
```

`secret_scan` uses Automic Vault when available, writes redacted receipts under
`outputs/secret-scan/`, and fails on actionable plaintext secrets while
classifying active auth stores and common third-party package test vectors
separately. Install Automic Vault or set `SANEMASTER_AUTOMIC_VAULT_CLI` to the
`av` binary.

Project-specific installs can add their own release, support, analytics, or remote-runner commands behind the same wrapper pattern. See [DEVELOPMENT.md](DEVELOPMENT.md) for the full command map.

## Optional Remote Runners

SaneProcess does not require a second machine. The default path is local verification:

```bash
ruby scripts/SaneMaster.rb verify
```

Teams that already use a remote builder, CI runner, or dedicated test host can wire that through `SaneMaster.rb` so agents still call one safe project command instead of inventing raw build/test steps.

## Optional Policy Packs

SaneProcess can carry product-specific policy packs alongside generic process rules. SaneApps uses this for SaneUI design-system checks, but outside teams can remove or replace that policy.

For projects using SaneUI settings, About, license, updater, button-style, or typography surfaces:

- Inspect the shared SaneUI catalog/source of truth first.
- Compose shared `SaneSettingsContainer`, `SaneAboutView`, `LicenseSettingsView`, and `SaneSparkleRow`.
- Keep shared settings text bright white and at least `13pt`.
- Do not use `.secondary`, gray helper text, `mailto:` bug-report paths, `Manage Access` copy, app-local updater rows, local `SaneSparkleRow`, or `.buttonStyle(.bordered)` in those surfaces.

Run:

```bash
ruby scripts/SaneMaster.rb saneui_guard /path/to/app
```

The SaneUI guard currently catches shared-shell drift, local `SaneSparkleRow`, `mailto:` support links, `Manage Access` copy, and `.buttonStyle(.bordered)`. Typography and color compliance still require human review until the automated scanner covers those patterns directly.

## How It Works

SaneProcess has one SOP and multiple enforcement shapes:

```text
User prompt
  -> AGENTS.md / client instructions
  -> hooks or shared guards
  -> MCP / local research / tool discovery
  -> SaneMaster wrapper
  -> verified action
```

Native hook adapter mapping:

These hooks are strongest in clients with native lifecycle hooks. In other
clients, treat the same behavior as a wrapper/script contract and verify it
through `SaneMaster.rb`.

| Hook | Event | Purpose |
|------|-------|---------|
| `session_start.rb` | SessionStart | Cleanup, state bootstrap, session briefing |
| `saneprompt.rb` | UserPromptSubmit | Intent classification and workflow reminders |
| `sanetools.rb` | PreToolUse | Research gate, path blocks, circuit breaker blocks |
| `sanetrack.rb` | PostToolUse | Failure tracking, research evidence, edit/test state |
| `task_completed_gate.rb` | TaskCompleted | Blocks completion claims without required verification evidence in opted-in SaneProcess repos |
| `sanestop.rb` | Stop | Session summary and verification/handoff reminders |

Client adapter state is stored locally in the relevant runtime directory; shared scripts and guards are used by any compatible client.

## Documentation Map

| File | Owns |
|------|------|
| [AGENTS.md](AGENTS.md) | Client-neutral operating rules, trigger map, required workflows |
| [DEVELOPMENT.md](DEVELOPMENT.md) | Canonical commands, verification paths, daily SOP |
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, decisions, research notes, tradeoffs |
| [scripts/hooks/README.md](scripts/hooks/README.md) | Native hook layer |
| [scripts/codex-bin/README.md](scripts/codex-bin/README.md) | Codex helper source mirrored to `~/.codex/bin/` |

The rule is deliberate: update an existing source-of-truth doc before adding another markdown file.

## Operator Docs Map

| Need | Source |
|------|--------|
| Daily agent/operator rules | [AGENTS.md](AGENTS.md) |
| Command map and verification workflow | [DEVELOPMENT.md](DEVELOPMENT.md) |
| Architecture, durable decisions, and tradeoffs | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Hook-layer behavior and tests | [scripts/hooks/README.md](scripts/hooks/README.md) |
| Codex helper install/runtime notes | [scripts/codex-bin/README.md](scripts/codex-bin/README.md) |

## Included Skills

SaneProcess ships reusable skills that can be mirrored into `.agents/skills/` or another client-specific skill directory.

These repo-shipped skills are separate from client-managed marketplace plugins such as Canva, Codex Security, OpenAI Developers, Product Design, and similar connectors.

| Skill | Purpose |
|-------|---------|
| `critic` | Multi-perspective code review: bugs, data flow, integration, edge cases, UX, security |
| `docs-audit` | Compatibility shim for the global audit workflow; keeps audit artifacts temporary and promotes durable conclusions into source-of-truth docs |

## Project Structure

```text
scripts/
  hooks/          Native enforcement hooks and tests
  sanemaster/     SaneMaster command modules
  automation/     Scripted automation helpers
  codex-bin/      Codex control-plane helper source
  grok-bin/       Grok control-plane helper source (parallel, lighter footprint)
skills/           Reusable repo skills
templates/        Project, docs, release, and UI templates
AGENTS.md         Shared agent instructions
DEVELOPMENT.md    Operating procedure and commands
ARCHITECTURE.md   System design and durable decisions
```

## Requirements

- macOS or Linux
- Ruby available on the target machine. Current hooks are written to run on the system Ruby used by macOS automation lanes; Ruby 3.x is recommended for local development.
- A compatible coding agent that can follow repo instructions and scripts. Codex and native lifecycle-hook paths have the best-documented support today.

## Tests

The full verification path is registry-backed so new script tests cannot silently fall out of `verify`.

```bash
ruby scripts/SaneMaster.rb verify
ruby scripts/hooks/test/tier_tests.rb
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
```

Hook-layer docs list hook-specific counts. Full repo counts change as registry-backed Ruby, Python, shell, and hook tests are added; use `SaneMaster.rb verify` as the source of truth. Set `SANE_TEST_DEBUG=1` to see the block messages that hook self-tests normally suppress.

## Security

The enforcement runtime is local-first: adapter state and logs stay on your machine, and hooks do not send telemetry. Some optional automation scripts can call external services such as GitHub, App Store Connect, Cloudflare, email, or sales/download APIs when an operator runs those commands. See [SECURITY.md](SECURITY.md).

## Uninstall

Remove installed hook entries for any client adapter you enabled, delete copied `scripts/hooks/` if you installed them into a project, and remove generated local runtime state for that adapter.

## License

MIT License. See [LICENSE](LICENSE).

---

Built by [SaneApps](https://saneapps.com).

<!-- SANEAPPS_AI_CONTRIB_START -->
### LLM-Assisted Contributions

If you use a coding agent, keep contributions focused and reviewable. This
minimal prompt is enough for a first pass:

```text
I want to contribute to this repo, but I'm not a coder.

Repository:
https://github.com/sane-apps/SaneProcess

Bug or idea:
[Describe your bug or idea here in plain English]

Please do this for me:
1) Understand and reproduce the issue (or understand the feature request).
2) Make the smallest safe fix.
3) Open a pull request to https://github.com/sane-apps/SaneProcess
4) Give me the pull request link.
5) Open a GitHub issue in https://github.com/sane-apps/SaneProcess/issues that includes:
   - the pull request link
   - a short summary of what changed and why
6) Also give me the exact issue link.

Important:
- Keep it focused on this one issue/idea.
- Do not make unrelated changes.
```

Pull requests are reviewed and tested before merge.
<!-- SANEAPPS_AI_CONTRIB_END -->
