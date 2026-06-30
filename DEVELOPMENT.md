# SaneProcess Development Guide

> [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md)

Concise build, test, and contribution guide. Detailed release playbooks live in
`templates/RELEASE_SOP.md`, implementation details live in `ARCHITECTURE.md`,
and command help lives in `./scripts/SaneMaster.rb help <category>`.

## Quick Start

```bash
ruby scripts/SaneMaster.rb verify                 # canonical full verification
ruby scripts/hooks/test_hooks.rb                  # hook integration suite
ruby scripts/SaneMaster.rb tool_discovery --query "..." # tool/MCP proof receipt
ruby scripts/SaneMaster.rb process_metrics --export-otel outputs/process-traces.json
ruby scripts/SaneMaster.rb route_cost_review --json # rank expensive proof-route risks
ruby scripts/SaneMaster.rb context_bundle --task "review this workflow"
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

`ssh mini` is the canonical Mini route and must not depend on same-Wi-Fi Bonjour
resolution. On SaneApps controller machines it is installed by:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/mini/install-mini-ssh-config.sh
ssh mini 'hostname; whoami'
```

The installer writes `~/.ssh/config.d/saneapps-mini.conf`, where `mini` and
`mini-remote` use Cloudflare Access via the TXT record
`mini-ssh-host.saneapps.com`; `mini-lan` keeps the direct
`stephans-mac-mini.local` route for LAN diagnostics only. Verify the bridge with:

```bash
dig +short TXT mini-ssh-host.saneapps.com
cloudflared --version
ssh -G mini | grep -E '^(hostname|proxycommand|identityfile) '
ssh mini 'hostname; whoami; pwd'
```

The Mini publishes that TXT record from a launchd-managed quick tunnel. Reinstall
or repair it from a working Mini shell with:

```bash
cd ~/SaneApps/infra/SaneProcess
bash scripts/mini/mini-install-remote-ssh-tunnel.sh
launchctl print gui/$(id -u)/com.saneapps.mini-remote-ssh-tunnel
tail -50 ~/Library/Logs/SaneApps/mini-remote-ssh-tunnel.log
```

If `ssh mini` is down but `ssh mini-lan` works, the problem is the Cloudflare
tunnel/TXT bridge, not Mini availability. Do not fall back to local app testing
until that route has been diagnosed or the user approves the exact exception.

Codex Mini remote-control health:

```bash
ssh mini 'codex app-server daemon version'
ssh mini 'codex app-server daemon restart; codex app-server daemon enable-remote-control'
ssh mini 'launchctl print gui/$(id -u)/com.saneapps.codex-keepalive'
```

The keepalive LaunchAgent must include
`SANEPROCESS_ENABLE_MINI_CODEX_KEEPALIVE=1`. The keepalive refreshes the
headless Codex remote-control daemon without opening GUI windows; it opens the
Codex app only when no SaneApps app is running and no app server is present.

Tailscale setup state:

```bash
ssh mini 'tailscale status'
ssh mini 'launchctl print system/homebrew.mxcl.tailscale'
```

The Mini formula daemon can run as a root LaunchDaemon, but it is not a permanent
route until the Mini is enrolled in a tailnet. The controller formula is
installed but not running as root; local enrollment requires the user's local
sudo/GUI approval or a reusable/preauthorized Tailscale auth key.

Public adopters do not need a Mac Mini. Replace Mini-first with your own
canonical runner or local verification command, then route it through
`SaneMaster.rb` so agents have one safe path to call.

Non-doc edits are not complete just because a hook saw a command that looked like
a test. Completion gates require a fresh counted `SaneMaster.rb verify` metric
with tested evidence and a source fingerprint matching the current repo.

### Cloudflare And Browser Proof

SaneApps Cloudflare mutations use pinned Wrangler by default. `npx wrangler`
can resolve stale local versions; SaneCite queue creation failed under
Wrangler 4.65.0 and succeeded under `wrangler@4.104.0`. Shared release paths
set `SANEPROCESS_WRANGLER_VERSION=4.104.0` unless deliberately overridden.
For SaneApps website/app deploys, use `release.sh --website-only` or
`release.sh --deploy`; the release guards still block ad-hoc Pages/R2 mutations.
Deliberately manual Cloudflare maintenance commands should use
`npx --yes wrangler@4.104.0 ...`.

Website visual verification should use real browser automation. On SaneApps
operator Macs, use Brave with Playwright via `NODE_PATH=/opt/homebrew/lib/node_modules`
and `executablePath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"`.
Save screenshots under `outputs/playwright/` or the workflow's existing
`outputs/<workflow>/visual/` directory.

## Documentation Standard

- Keep durable public docs in the core set: `README.md`, `DEVELOPMENT.md`,
  `ARCHITECTURE.md`, `AGENTS.md`, and `SESSION_HANDOFF.md`.
- `SESSION_HANDOFF.md` is active state only, not a history archive.
- Put release mechanics in `templates/RELEASE_SOP.md`.
- Put private/operator setup details in `DEVELOPER_SETUP.md`.
- Do not create orphan docs; improve the nearest existing owner first.

## Client Compatibility

SaneProcess has one SOP with multiple client adapters.

## Ruby Toolchain

- SaneProcess automation targets Homebrew Ruby `4.0.0+`; operator machines
  should run the latest installed Homebrew Ruby for SaneApps workflows.
- macOS `/usr/bin/ruby` `2.6` is fallback/bootstrap compatibility only. Do not
  make it the normal toolchain.
- `scripts/SaneMaster.rb` re-runs itself through
  `/opt/homebrew/opt/ruby/bin/ruby` on macOS when started under an older Ruby.
- `scripts/init.sh` checks Homebrew Ruby, required standalone Ruby gems such as
  `jwt`, Bundler, and project bundle state. In an interactive shell it prompts
  to run the needed update/install command; in non-interactive shells it prints
  the exact command and fails the install.
- `SaneMaster.rb bootstrap` updates stale `.ruby-version` pins in fix mode and
  only warns in `--check-only` mode. It also installs missing required Ruby gems
  in fix mode, even when a repo intentionally has no `Gemfile`.
- Keep low-level bootstrap/package validators Ruby 2.6-parseable until the
  Homebrew Ruby check has had a chance to run.

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

6. Use global client skills such as `critic` and `audit`; SaneProcess no longer carries local reviewer prompt packs.

The portable enforcement contract for Grok (and Codex, generic agents) is **AGENTS.md + explicit calls to SaneMaster + shell guards**. High-risk native hook entries may still block dangerous commands when Grok invokes them; passive tracking annotations are safe to ignore or disable per-session for pure Grok workflows.

### For Codex users (practical steps)

SANEPROCESS_PROSE_ONLY_POLICY: Codex plugin routing documents how to choose optional client capabilities over existing SaneMaster, tool_discovery, agent_eval, and skill_lint enforcement; no new mandatory gate is intended.

Codex can expose marketplace plugins, app connectors, MCP tools, and local skills
that are not installed by `scripts/init.sh --client codex`. Treat those as
session-local accelerators. The stable SaneApps contract is still `AGENTS.md`,
the active skill registry, and SaneMaster wrappers.

Before using or declaring a Codex plugin missing:

1. Check the live tool surface in the current session.
2. Read the matching skill instructions when a plugin skill applies.
3. Run `ruby scripts/SaneMaster.rb tool_discovery --query "..."` before adding a new wrapper, claiming a gap, or choosing a repeated workaround.
4. Finish stateful SaneApps work with the canonical proof command: `verify`,
   `release_preflight`, `appstore_preflight`, `sane_test.rb`, `check-inbox.sh`,
   `sales`, `downloads`, `events`, or the app-specific visual proof path.

Use this routing table for Codex plugin skills:

| Work | Useful Codex plugin family | SaneApps close-out |
|------|----------------------------|--------------------|
| macOS app UI, AppKit interop, signing, packaging, telemetry, test triage | Build macOS Apps | Mini-first `SaneMaster.rb verify`; use `sane_test.rb` for runtime proof |
| iOS companion apps, simulator proof, App Intents, leaks, performance | Build iOS Apps | Project verify plus fresh simulator/runtime evidence |
| Websites and local frontend debugging | Build Web Apps, Browser | `release_preflight` for shipped web surfaces and Cloudflare Pages release path |
| New product UI direction, redesign, prototype, image-to-code, visual QA | Product Design, Figma | Start with a brief/visual target; get approval before code; verify plus clean screenshots after implementation |
| Marketing positioning, ad concepts, mood boards, editable decks, social resizes | Creative Production, Canva | Check live product facts and brand/copy rules; run `launch_readiness` before public launch use |
| Repo/path security scan, diff security review, threat model, fix validation | Codex Security | Use for security-specific work; fixes still require `verify` and relevant release checks |
| OpenAI API, Agents SDK, ChatGPT App, OpenAI key or MCP work | OpenAI Developers | Use official-doc-backed skill flow; keep secrets in the approved Keychain/env path |
| Cloudflare Pages/R2/Workers/Durable Objects/Tunnels | Cloudflare | Prefer SaneProcess release wrappers for deploy/release proof; use plugin docs for platform details |
| GitHub PRs/issues/CI metadata | GitHub | Cross-check support email before closing customer-reported issues |
| Personal email, docs, sheets, slides, or calendar deliverables | Explicit one-off connector only | Not a default SaneApps route; generic "email" still means `hi@saneapps.com` through `check-inbox.sh` |
| KPI reports, metric diagnostics, dashboards | Data Analytics | Use `SaneMaster.rb sales`, `downloads`, `events`, or `/outreach` first for canonical SaneApps signals |
| Presenter videos, generated media, stock assets, programmatic videos | HeyGen, HyperFrames, Picsart, Fal, Shutterstock, Remotion | Treat as marketing assets, not runtime verification evidence |

## Core Rules

SaneProcess enforces the scientific method for coding agents:

| Rule | Meaning |
|------|---------|
| Verify before trying | Read local code and check uncertain APIs/tools before editing |
| Two failures means stop | Read the error and research the real API before continuing |
| Green means done | Do not claim completion with failing tests |
| No test, no rest | Fixes need meaningful tests; tautologies and blind `source.contains` guards do not count — the test must fail for the real bug at runtime |
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
| Secret scan hygiene | `ruby scripts/SaneMaster.rb secret_scan --path /Users/sj` |
| Test quality scan | `ruby scripts/SaneMaster.rb test_scan -v` |
| Process eval | `ruby scripts/SaneMaster.rb process_eval --json` |
| Prompt routing eval | `ruby scripts/SaneMaster.rb agent_eval --json` |
| Agent/review context bundle | `ruby scripts/SaneMaster.rb context_bundle --task "..."` |
| Skill routing lint | `ruby scripts/SaneMaster.rb skill_lint --json` |
| App release preflight | `ruby scripts/SaneMaster.rb release_preflight` |
| Active App Store lane | `ruby scripts/SaneMaster.rb appstore_preflight` |
| Runtime launch/proof | `ruby scripts/SaneMaster.rb test_mode` plus app-specific `customer_ui_sweep`, or `visual_smoke` only when no app sweep exists |
| Verification scope plan | `ruby scripts/SaneMaster.rb proof_plan --task "..."` |
| Support inbox | `ruby scripts/SaneMaster.rb check_inbox` |
| Sales/download/funnel | `sales`, `downloads`, `events` |
| Machine cleanup | `ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply` |

`process_eval` is the gate for real workflow improvement, not synthetic
busywork. Trace fixtures define required event shapes, but slimming/expanding
SaneProcess should be justified by live telemetry and structured A/B receipts
under `outputs/process-abtest/`. A valid A/B receipt must name a real task,
both arms, endpoint verification, blind judge outcome, costs, validation
counter deltas, decisive mechanisms, and pending production follow-ups.

Process refinement uses a scientific bar, not vibes:

- **Keep** a rule/tool when it has positive causal evidence, or a high-severity
  incident lineage plus measured accuracy.
- **Slim or merge** when the mechanism is useful but broader than the evidence,
  duplicative, or costly for low-risk task classes.
- **Retire** only after root-cause review shows no unique protection, no
  positive evidence, and enough samples or replay coverage to catch regressions.
- Broad guardrail removals need multiple task families or 100+ samples; narrow
  hook/routing changes need at least 30 relevant samples where available.
- Rare high-severity protections such as release, customer email, local-runtime
  proof, and sensitive data gates may stay on incident lineage plus targeted
  replay tests even when sample counts are low.
- Never optimize raw block count, workflow receipt count, or SOP score alone.
  Score outcome truth: correct world state, fewer repeated failures, less
  rework, and verified customer-facing behavior.

Current evidence split:

- Direct outcome proof: startup context loading, Mini-first canonical
  verification, and SaneBar geometry restraint from the 2026-06-11 A/B receipt.
- Strong incident-lineage protections: structured visual proof, two-strike
  escalation, canonical release path, verify repo-drift guard, and email hash
  approval.
- Contract lint, not outcome proof by itself: `agent_eval`, trace fixtures,
  route fixtures, and SOP score history.
- First slimming targets are measurement and scope, not safety removal:
  demote legacy/noisy score surfaces, exclude daemon bookkeeping from task
  telemetry, unify UI-proof metrics, and test whether startup cleanup steps can
  be warning-only while keeping startup context hard.
- Scoped app behavior work should use `proof_plan` before verification when a
  known-unrelated red gate could swamp the task. Focused scope means focused
  tests plus exact Mini runtime proof for the narrow claim; release,
  shared-infra, broad refactor, and high-risk final claims still require full
  canonical verify.

## Testing

Use the registry-backed verify path before calling work done:

```bash
ruby scripts/SaneMaster.rb verify --timeout 900
```

Useful focused tests:

```bash
ruby scripts/validation_report_test.rb
ruby scripts/validation_report.rb                  # cheap verdict/report
ruby scripts/validation_report.rb --release-checklists # deep all-app artifact checklist
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
- No blind tests: a behavioral/regression test must fail for the real bug at runtime;
  `source.contains`/string-match guards are structure checks, not behavioral coverage
  (Golden Rule 7). For SaneBar see `apps/SaneBar/docs/TEST_BLINDNESS_AUDIT.md`.

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
- Codex marketplace plugins and connectors: use the matching skill instructions
  for domain work, then close SaneApps workflows with SaneMaster or the relevant
  shared wrapper.
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
- `ruby scripts/SaneMaster.rb mcp_watchdog doctor` answers whether optional MCP
  helpers are healthy by combining process topology with the live active-client
  probe when available.
- `~/.codex/bin/check-mcps` is the direct Codex MCP endpoint proof. Process
  presence alone is not evidence that Codex can call the tools.
- A green MCP check does not clear repo validation. A red repo validation run
  does not prove a tool is missing.
- Run the tool-discovery receipt before proposing a new tool, wrapper, or
  repeated workaround.

## Golden Rule Hook Coverage

The Golden Rules in `AGENTS.md` must map to concrete enforcement. Current
coverage is:

- Rule 0, name the rule: `saneprompt.rb` injects task/rule reminders.
- Rule 1, stay in lane: `sanetools_checks.rb` blocks sensitive/system paths
  while allowing the active project root, including isolated self-test roots.
- Rule 2, verify first: `sanetools_research.rb`, `sanetrack_research.rb`, and
  `SaneMaster.rb tool_discovery` gate edits and repeated workarounds.
- Rule 3, two strikes: `sanetrack_tracking.rb` trips after 2 failures or 2
  matching signatures; `sanetools_checks.rb` blocks mutation while allowing
  research tools.
- Rule 4, green means go: `task_completed_gate.rb`, `sanestop.rb`, and
  `SaneMaster.rb verify` block or cap completion without fresh proof.
- Rule 5, use tools: `sane_launch_guard.rb`, `sane_release_guard.rb`,
  `sane_email_guard.rb`, and mandatory workflow tracking enforce canonical
  wrappers.
- Rule 6, build/kill/launch/log: `sane_test.rb`, `SaneMaster.rb test_mode`, and
  launch guards own runtime cycles.
- Rule 7, no test no rest: `sanetrack.rb` detects tautology/mock-passthrough
  tests and (via `sanetrack_blind_tests.rb`) red-flags source-fingerprint blind
  tests — `source.contains`/`String(contentsOf:)` substring guards with no
  behavioral assertion — that pass even when a real regression ships; see
  `apps/SaneBar/docs/TEST_BLINDNESS_AUDIT.md`. Stop/completion gates require
  verification.
- Rule 8, write bugs down: `sanetrack_state_updates.rb` and `sanestop.rb` track
  memory and handoff updates after bugs, hooks, tools, and durable docs change.
- Rule 9, gen the pile: `sanetools_checks.rb` blocks orphan markdown creation;
  code scaffolding remains enforced by generator commands and review.
- Rule 10, size limits: `sanetools_checks.rb` enforces file limits and Swift
  component-owner aggregate limits across `Type.swift` plus `Type+*.swift`.
- Rule 11, fix tools: `tool_discovery`, `near_miss_review`,
  `route_cost_review`, `verify_failure_review`, and `gate_review` are the
  canonical promotion path.
- Rule 12, talk while walking: skill prompts and mandatory workflows require
  subagent use for covered heavy workflows; client-native spawn enforcement is
  tool-surface dependent.
- Rule 13, context or chaos: `session_start.rb` and `sanetools_startup.rb` gate
  required startup context.
- Rule 14, prompt like pro: `saneprompt.rb` and skill workflows enforce
  structured prompts for covered tasks; broad prompt-quality remains review-led.
- Rule 15, review before ship: `sane_ship_guard.rb`, release preflight, appstore
  preflight, and release guards enforce release review.
- Rule 16, integrate: `sanetools_checks.rb` blocks orphan docs;
  `sanetrack_state_updates.rb` and `sanestop.rb` require memory/handoff updates
  for tools, hooks, and durable docs.

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
