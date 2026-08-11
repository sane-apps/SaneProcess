# SaneProcess Development Guide

> [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md)

Concise build, test, and contribution guide. Detailed release playbooks live in
`templates/RELEASE_SOP.md`, implementation details live in `ARCHITECTURE.md`,
and command help lives in `./scripts/SaneMaster.rb help <category>`.

## Quick Start

```bash
ruby scripts/SaneMaster.rb verify                 # canonical full verification
ruby scripts/SaneMaster.rb verify --ui            # unit/integration plus signed UI tests
ruby scripts/SaneMaster.rb verify --ui-only       # focused UI-runner diagnostic lane
ruby scripts/SaneMaster.rb verify_api API Framework # confirm an Apple SDK symbol exists
ruby scripts/SaneMaster.rb verify_mocks            # check generated mocks match protocols
ruby scripts/hooks/test_hooks.rb                  # hook integration suite
ruby scripts/SaneMaster.rb tool_discovery --query "..." # tool/MCP proof receipt
ruby scripts/SaneMaster.rb process_metrics --export-otel outputs/process-traces.json
ruby scripts/SaneMaster.rb route_cost_review --json # rank expensive proof-route risks
ruby scripts/SaneMaster.rb ai_meter --days 7 --json # read Cloudflare AI usage and estimated cost
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

The installer writes `~/.ssh/config.d/saneapps-mini.conf`. `mini` and
`mini-remote` use the first available private route: Bonjour LAN, then
Tailscale. `mini-lan` keeps the direct `stephans-mac-mini.local` route for LAN
diagnostics only. Verify both the normal alias and Tailscale state with:

```bash
ssh -G mini | grep -E '^(hostname|proxycommand|identityfile) '
ssh mini 'hostname; whoami; pwd'
tailscale status
```

There is no public quick-tunnel fallback. If `ssh mini-lan` works but `ssh mini`
does not work off-LAN, diagnose the authenticated Tailscale client/daemon. Do
not fall back to local app testing until the private route is repaired or the
user approves the exact exception.

### Host Identity: Direct On Mini, SSH From Air

Run `hostname` before cross-machine reasoning. On the Mini, work directly in
the local checkout; do not add a self-SSH hop. From the Air, `ssh mini` is the
canonical controller route. A local-vs-`ssh mini` comparison performed on the
Mini sees the same filesystem and proves nothing about Air parity.

GitHub `main` is canonical for committed code. Dirty work is snapshot-only and
never auto-applied. The Air's conflict-preserving 15-minute file-memory sync is
a separate lane and must not be mistaken for working-tree mirroring.

After either client or machine restarts, run this from the Air:

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb server_acceptance
```

The receipt is Air-owned under `outputs/restart-acceptance/`; record its full
Air path when citing it from a shared handoff.

Codex Mini remote-control health:

```bash
ssh mini 'codex app-server daemon version'
ssh mini 'codex app-server daemon restart; codex app-server daemon enable-remote-control'
```

The retired `com.saneapps.codex-keepalive` job must remain absent. It installed
software and opened GUI apps from a background timer. Normal Air control uses
SSH; restart the Codex app-server explicitly only when that optional remote-
control lane is needed.

Tailscale health:

```bash
ssh mini 'tailscale status'
ssh mini 'launchctl print system/homebrew.mxcl.tailscale'
```

Both Macs are enrolled in the MrSaneApps tailnet and report no key expiry. The
Mini daemon is a root `RunAtLoad`/`KeepAlive` LaunchDaemon; the Air uses an
authenticated userspace `RunAtLoad`/`KeepAlive` LaunchAgent and returns after
normal Air login.

The return route is explicit and independently keyed:

```bash
ssh mini 'bash ~/SaneApps/infra/SaneProcess/scripts/mini/install-air-return-ssh.sh'
ssh mini "ssh air 'hostname; whoami'"
```

Do not enable agent forwarding for this path. The dedicated key permits normal
recovery/operations on the Air without exposing Air GitHub or signing keys to
the Mini.

File-backed Claude, Serena, and Codex memories use
`scripts/automation/sync-memory-mini.sh`, installed on the Air as
`com.saneapps.memory-sync` (`RunAtLoad`, then every 15 minutes). It is backup-
first, no-delete, cross-host locked, checksum-verified, and preserves a losing
same-file version as `.sane-conflict-*` on both machines. It also pulls Mini
dirty-work snapshots without applying them. The shared AgentMemory worker is
Mini-owned by `com.saneapps.agentmemory`. The Air must maintain a private,
persistent SSH tunnel to Mini loopback port 3111; Air MCP clients use that local
endpoint instead of creating an unmonitored one-shot detached tunnel. Tunnel
health is part of Air acceptance and must survive normal client restarts without
changing AgentMemory's loopback-only exposure.
The Mini LaunchAgent must point to `sane-agentmemory-supervisor`, not directly
to the `agentmemory` wrapper. Verify both the service program and HTTP corpus:

```bash
ssh mini 'launchctl print gui/$(id -u)/com.saneapps.agentmemory'
ssh mini '/opt/homebrew/bin/agentmemory status'
```

### Source Custody Receipts

Use the focused custody lane when current source must be preserved without
fetch, pull, push, stash, commit, checkout, or worktree changes:

```bash
ssh mini 'cd ~/SaneApps/infra/SaneProcess && bash scripts/automation/git-sync-safe.sh \
  --custody-path apps/SaneLot \
  --custody-manifest-symlink lefthook.yml'
```

Repeat `--custody-path` for ordinary Git or non-Git sources. A
`--custody-manifest-symlink` declaration requires exactly one custody source
and names a path relative to it. The default rejects every escaping symlink.
The explicit form records a relative link whose regular-file target stays
inside `~/SaneApps`; neither the link nor target enters the source archive.
The private manifest records the dependency and restore requirement. Each run
hashes the safe inventory, writes mode-0600 artifacts, verifies any Git bundle,
restores into a temporary directory, compares hashes and modes, and confirms
the declared dependency again before atomic finalization.

Public adopters do not need a Mac Mini. Replace Mini-first with your own
canonical runner or local verification command, then route it through
`SaneMaster.rb` so agents have one safe path to call.

Non-doc edits are not complete just because a hook saw a command that looked like
a test. Completion gates require a fresh counted `SaneMaster.rb verify` metric
with tested evidence and a source fingerprint matching the current repo.
Receipt fingerprints are the `SaneSourceFingerprint` content hash
(`scripts/sanemaster/source_fingerprint.rb`) — hooks must compare with that
same module, never a git status/diff recipe. Mini-routed verify mirrors its
fresh Mini-recorded `type=verify` metric into the controller's local metrics
file after the run, so completion/stop gates work from the Air as well.

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
The canonical route is `scripts/mini/capture-web-screenshot.sh`; pass
the exact project Git root with `--source-root`, then `--viewport desktop`
(1440x1000) or `--viewport 375` (375x900). The receipt binds target HEAD,
branch, dirty status, and a deterministic source/config manifest across the Air
and Mini; the wrapper rejects path escape, mismatch, or capture-time drift.
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

### Reviewer fan-out routing

Reviewer count follows the number of useful independent perspectives, not a
hard-coded thread total. The active client's interactive-subagent limit is only
a limit on simultaneous stateful threads; it is not a limit on the size of a
review.

Choose the route by capability:

- Use native `spawn_agent` (Codex) or Task/subagent tools (Claude) for work that
  is stateful, interactive, write-capable, or likely to need follow-up.
- Use separate `codex exec --ephemeral -s read-only` processes for isolated,
  read-only review perspectives. Give every process the same context brief and
  target, and save each result to its own output file. This is the normal
  high-fanout route when the useful perspective count exceeds the currently
  available interactive slots.
- Size simultaneous processes from current host/service capacity and active
  client configuration. Queue additional independent perspectives as capacity
  becomes available; do not reduce the total perspective set merely because a
  client currently exposes fewer interactive slots.
- Use interactive waves only when the isolated `codex exec` route is genuinely
  unavailable or the work requires shared state/follow-up. Waves are a
  compatibility fallback, not a reviewer ceiling.

Before declaring either route unavailable, check the live tool surface, run
`codex --version` and `codex exec --help`, then run
`ruby scripts/SaneMaster.rb tool_discovery --query "reviewer fan-out"`. For
batch review, keep `--ephemeral` and `-s read-only`; never substitute a
dangerous bypass flag. Review outputs remain evidence for the parent synthesis,
not authority to edit, merge, release, or mutate external state.

Browser and app-control ladder:

1. Brave/Chrome dashboard or portal control: Browser/Chrome plugin through
   `node_repl`.
2. Visible native app/window state: Computer Use `get_app_state`.
3. Deterministic macOS action: `macos-automator` AppleScript/JXA.
4. Repeatable website QA: Playwright with Brave defaults.
5. Final proof: Mini screenshot wrapper or app-specific visual receipt.

This applies to Codex and Claude. Check live plugin/tool state before falling
back to raw SSH screenshots, blind `osascript`, or manual browser work.

Use this routing table for Codex plugin skills:

| Work | Useful Codex plugin family | SaneApps close-out |
|------|----------------------------|--------------------|
| macOS app UI, AppKit interop, signing, packaging, telemetry, test triage | Build macOS Apps | Mini-first `SaneMaster.rb verify`; use `sane_test.rb` for runtime proof |
| iOS companion apps, simulator proof, App Intents, leaks, performance | Build iOS Apps | Project verify plus fresh simulator/runtime evidence |
| Websites, browser portals, and local frontend debugging | Build Web Apps, Browser/Chrome Plugin, Computer Use | `release_preflight` for shipped web surfaces and Cloudflare Pages release path; screenshots are final proof, not the primary control path |
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
  mini/                      # Mac Mini build/test and always-on server helpers
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
| Business appointments | `ruby scripts/SaneMaster.rb business_appointment add --title TITLE --start "YYYY-MM-DD HH:MM" --attendee EMAIL` |
| Sales/download/funnel | `sales`, `downloads`, `events` |
| Machine cleanup | `ruby scripts/SaneMaster.rb machine_cleanup --host mini --apply` |

Business appointment live writes require `SANEAPPS_BUSINESS_CALENDAR_ID` and
`GOOGLE_CALENDAR_ACCESS_TOKEN`. Preview mode prints the required
`confirm_send` phrase; live mode requires that exact phrase, checks for an
existing event by dedupe key, creates a no-attendee event first, verifies Google
reports `hi@saneapps.com` as organizer, then adds attendees with notifications.
If organizer proof fails, no attendee invite is sent.

Business appointment follow-up email uses the canonical real-name business
signature from `AGENTS.md` (Customer Email section) with the relevant product
line, e.g. `Founder, SaneApps / SaneCite`, phone `727-758-9785`, and
`hi@saneapps.com` — never the `Mr. Sane` support signoff. (Corrected
2026-07-15: the old `SaneCite Founder` / `7277589785` variant is retired.)
SaneCite prospect emails should use the existing SaneCite visual email frame
from the SaneCite codebase (dark header, warm off-white page, cyan accent,
SaneCite wordmark).

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

When recent production Swift changes touch defaults registration or migration
behavior, configure the real upgrade lane in `.saneprocess` and run it before
preflight:

```yaml
release:
  upgrade_path_test:
    command:
      - ruby
      - scripts/upgrade_path_behavioral_test.rb
    from_version: "1.9.0"
    timeout_seconds: 900
```

```bash
ruby scripts/SaneMaster.rb upgrade_path_proof
ruby scripts/SaneMaster.rb release_preflight
```

The configured process must drive the customer-observable upgrade behavior and
write the JSON result and runtime artifact at the paths supplied by
`SANEMASTER_UPGRADE_RESULT_PATH` and
`SANEMASTER_UPGRADE_RUNTIME_ARTIFACT_PATH`. SaneMaster supplies the one-use
challenge plus app/version/source values, runs this lane on the Mini, and signs
the source-bound receipt. There is no CLI success override.

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

### Chrome Web Store review watcher recovery

The recurring CWS lane is GET-only. Its canonical values live in the private
Mini cache and are restored one at a time through the watcher's stdin route;
never put a refresh token or an optional legacy client secret in command
arguments, automation prompts, logs, or receipts:

```bash
printf '%s' "$VALUE" | ruby scripts/automation/cws_review_watch.rb \
  --store-stdin SANE_CWS_PUBLISHER_ID
printf '%s' "$VALUE" | ruby scripts/automation/cws_review_watch.rb \
  --store-stdin SANE_CWS_CLIENT_ID
ruby scripts/automation/cws_oauth_authorize.rb
ruby scripts/automation/cws_review_watch.rb --health-get
```

Obtain the publisher ID from the authenticated Mini Brave Developer Dashboard
under Publisher > Settings. The OAuth helper stores its private authorization
URL, uses desktop loopback PKCE, accepts only `chromewebstore.readonly`, and
stores the refresh token only after the callback and exact-scope check succeed.
Google documents `client_secret` as optional for both the installed-app code
exchange and refresh; the helper omits it when unavailable and retains
compatibility if a private cache already contains one. Drive that URL in the
existing Mini Brave session; do not launch Chrome or Safari. A clean recovery
requires the final health result and
`outputs/cws-review-watch-receipt.json` to both report `official_get: ok`.
`publisher_id_missing`, `oauth_missing`, `oauth_failed`, or `status_get_failed`
is a visible blocker, not a no-change result.

## Runtime And Visual Evidence

- Use `sane_test.rb` or `SaneMaster.rb test_mode`; do not manually open app
  bundles for SaneApps proof.
- Use the app-specific `customer_ui_sweep` when it exists. Use `visual_smoke`
  only when no app-specific sweep exists.
- For customer-reported UI bugs, the proof must map each customer claim to one
  or more screenshots that reproduce the same state or demonstrate the fixed
  state. Generic "app is open" screenshots, permission dialogs, or unrelated
  desktop captures are not proof.
- `saneprocess.visual_audit` receipts must include `claims` entries with
  screenshot paths for every verified claim. The hook layer rejects visual-audit
  receipts that only list screenshots without claim mapping.
- Customer UI proof freshness is scoped to visual-impact sources. Reuse a valid
  receipt when only tests, release harnesses, screenshot wrappers, docs,
  appcast/site metadata, or version/project metadata changed after the proof.
  Rerun proof when app UI/runtime source, assets, localization, the action
  manifest, or shared SaneUI source changed after the receipt.
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
- `agentmemory`: Mini-owned semantic recall, reached directly on the Mini and
  through the persistent private Air SSH tunnel. Use
  `mcp__agentmemory__memory_recall` or `memory_smart_search` for recall and
  `memory_save` or `memory_lesson_save` for durable global writes. In
  `@agentmemory/mcp` v0.9.27, the standalone proxy drops `memory_save.project`;
  project-scoped facts therefore use Mini loopback REST
  `/agentmemory/remember` until the upstream shim is fixed. Do not describe an
  MCP `memory_save` as project-scoped.
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
- AgentMemory health requires an active-client semantic recall canary, not just
  a running engine or an open port. Air acceptance must prove Air loopback 3111,
  MCP initialization, and a non-mutating `memory_recall` or
  `memory_smart_search` call through the Air route.
- `memory_graph_query` is not a health canary. Graph extraction is optional and
  intentionally off in the SaneApps contract, so `Knowledge graph not enabled`
  must not be reported as shared-memory failure.
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
- For customer media, a successful `open` call is not review evidence. Verify the
  downloaded byte count, require a full decode, generate dense contact sheets,
  inspect the complete action/result sequence, and match that exact path to the
  code fix, regression coverage, same-settings Mini runtime proof, and released
  channel before claiming the issue is fixed. The Mini review command falls
  back to Brave when QuickTime or Preview is unavailable. If GUI launch is
  unavailable, inspect the generated sheets through the active visual tool.
  In either case, `check-inbox.sh confirm-media-review <id> <evidence_file>`
  records semantic inspection separately from file opening. Ask the customer
  to confirm on their Mac even when the local reproduction is green.
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
