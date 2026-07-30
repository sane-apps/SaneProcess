# SaneProcess Session Handoff

As of: 2026-07-29 America/New_York
Owner host: Mac Mini = tree truth; Air = controller.
Repo: `~/SaneApps/infra/SaneProcess`

This file is current state only. Historical detail belongs in git history,
dated research, AgentMemory, and durable architecture decisions.

## 2026-07-29 Mini Terminal focus repair

- Repeated `mini-gui-run.sh --reclaim-all` calls exposed and foregrounded stale
  automation Terminal windows, covering SaneClick during native UI control.
- `mini-reclaim-automation-windows.sh` no longer unminimizes, raises, activates,
  or sends focus-dependent shortcuts to Terminal. Hidden terminate-process
  sheets are handled through their accessibility controls. Reclaim hides
  Terminal before any close work, and the runner allows 15 bounded seconds for
  process-termination sheets.
- The runner hides stale Terminal hosts before and after each command.
  Its window-existence check now preserves AppleScript's true/false result, and
  the runner waits until its host is no longer accessibility-visible before
  returning. Inert Terminal scripting ghosts with no tab, TTY, process, or AX
  window are not treated as visible blockers.
  `AGENTS.md` and `scripts/mini/README.md` require title-scoped reclaim during
  click sequences, `--reclaim-all` only at workflow boundaries, and
  `--restore-bundle-id` for app control.
- Mini proof: focused suite 31/31. End-to-end runner acceptance returned status
  `0`, preserved Finder as the frontmost app, kept Terminal hidden, and left
  zero accessibility-visible automation windows.

## 2026-07-29 GUI action feedback loop

- Owner complaint: agents treat ASC/Brave/osascript click return as success and
  skip reading dialogs/page/AX/API (false "Update Review" success with
  "Newer Build Available" unread).
- Permanent rule added to `~/AGENTS.md` (GUI action feedback loop).
- Shared detector: `scripts/hooks/core/gui_feedback.rb`
  - Claude: sanetrack PostToolUse reminder + pending state; sanestop blocks;
    saneprompt injects on portal/ASC prompts.
  - Cursor: `~/.cursor/hooks/gui_feedback_after_shell.rb` +
    `gui_feedback_stop.rb` (follow-up up to 2 loops).
- Proof: `ruby scripts/hooks/gui_feedback_test.rb` ALL PASS.

## 2026-07-27 SaneHosts Release Worker Repair

- SaneHosts 1.1.24 exposed a release-tool bug: the email Worker checkout was on
  a local snapshot branch, so the release committed and pushed download
  metadata there while strict verification correctly checked GitHub `main`.
- `release.sh` now derives the Worker's canonical branch from `origin/HEAD`,
  falls back to `main`, pushes `HEAD` explicitly to that branch, and updates
  bundle download entries along with direct-product entries.
- Focused release guardrails pass 244/244. The Worker main repair is commit
  `d727220`; its full Node suite passes 50/50 and Cloudflare deployed version
  `02527f71-6164-4fd7-86a7-b2a95e5983f9`.
- SaneHosts 1.1.24 strict post-release verification passed across appcast,
  dist, website, checkout routing, Lemon Squeezy hosted files, Worker, source,
  JSON-LD, download redirect, GitHub, and Homebrew. Receipt:
  `apps/SaneHosts/outputs/post-release-checks-1.1.24-final-20260727.log`.

## Unified Cloudflare AI Meter Rollout

- The Mini-first, read-only `SaneMaster.rb ai_meter` command supports `--days`,
  `--json`, and `--markdown` and reports weighted calls, errors, retries,
  fallbacks, latency, token coverage, token totals, and dated cost estimates for
  SaneLot and SaneCite from the shared Cloudflare Analytics Engine
  `sane_ai_meter` v1 dataset. The existing morning report consumes the command;
  no new Worker, dashboard, or producer-side mutation was added. The existing
  Mini-local `saneapps-launch-ops` automation now performs a Friday seven-day
  portfolio review with cost, reliability, coverage, and separate quality
  evidence gates, so the owner does not need to remember to run it.
- The final eight-file rollout patch is
  `outputs/ai-meter/saneprocess-ai-meter.patch`, SHA-256
  `51b3b0af5566f32f908f85989f8a5b7b0964688bb44228e2f8667b4dd132cf1d`.
  Primary-checkout focused proof is
  `outputs/ai-meter/primary-focused-tests-20260720.log`, SHA-256
  `d51b32799b9130c481eced5c4eb3fad929dfff69b30472517c722b66d5709d8d`:
  AI meter 9/9, process metrics 19/19, command registry 5/5, Ruby/Bash syntax,
  registry JSON, and diff checks all passed.
- Primary-checkout live proof is
  `outputs/ai-meter/primary-live-query-20260720.json`, SHA-256
  `f1fdeeb97661cce735731ce99f3df9006e83e498520b26560942ca793f6aae02`.
  It returned `ready`, data through `2026-07-20T04:26:21Z`, 113 successful
  calls, zero errors/retries/fallbacks, 100% measured token coverage, and a
  `$0.017312` estimated recurring gross post-credit cost. Workflow receipt:
  `fdcfe42d8c2ae755382bcd150889a028`.
- Canonical `ruby scripts/SaneMaster.rb verify --timeout 900` was attempted in
  the clean isolated worktree and stopped at an unrelated existing Setapp test
  fixture: `Setapp manifest not found: /private/apps/SaneClip/.saneprocess`.
  Exact failing log:
  `/tmp/sane-ai-meter-process.ULWAgc/outputs/verify/20260720T041023.019968Z-30323-fc1aa122/12-test.log`.
  This remains a full-suite blocker, not an AI-meter failure; do not represent
  the canonical verify suite as green until that fixture is repaired.

## X Opportunity Scout Qualification Repair

- Owner directive on 2026-07-18 sets four public X actions per calendar day as
  a ceiling, not a quota: one required original SaneCite baseline, up to two
  high-confidence SaneCite quote posts, and at most one approved queue item or
  opt-in reply. Keyword-found automated cold replies are prohibited; automated
  replies require a mention, reply, or other clear engagement with
  `@MrSaneApps`. Quote posts must add useful context, embed and dedupe the source
  X URL, reject vendor/competitor promotion and noise, and disclose `I built
  SaneCite` if the product is mentioned. The canonical posting tool now has a
  separate `source_quote` policy bucket and `--source-quote-cap 2`, so embedded
  X sources do not consume the ordinary product-link allowance. Shared
  social/outreach skills and `.outreach.yml` record the same policy.
- The two remaining July 18 slots were used for value-first SaneCite quote
  posts after canonical dry-runs. The X API directly verified both as
  `referenced_tweets.type = quoted`: `https://x.com/MrSaneApps/status/2078508836554469624`
  quotes the scattered-proof conversation, and
  `https://x.com/MrSaneApps/status/2078508874756166075` quotes the live-posture
  conversation. Both disclose `I built SaneCite`, add substantive commentary,
  use no separate product link/signature/hashtags, and are logged as
  `source_quote`. July 18 has now reached the four-action ceiling: one SaneLot
  original, one SaneCite original, and two SaneCite quote posts.
- The scout's prior seen-log behavior was a real engagement bug: it treated a
  candidate observed once as though the account had acted on it, so earlier
  SaneCite conversations disappeared uncontacted. The runtime scout now
  separates `seen` from source IDs in `post-log.jsonl`; actionable unacted
  conversations resurface until used, while acted sources and non-actionable
  signals remain deduped. The repaired July 18 rerun surfaced 19 unacted
  SaneCite conversations and 7 SaneLot candidates. Focused coverage is green at
  16/16, including the new seen-versus-acted regression.
- Owner directive on 2026-07-18 now makes one original SaneCite X post per
  calendar day the non-negotiable baseline. The active Mini automation may use
  a valid ready queue item or generate a fresh value-first baseline under this
  standing authorization; an absent/malformed/pending queue is no longer a skip
  reason. Manual posts and optional extras remain exact-approval/ready-queue
  gated. The generated baseline must lead with a customer problem/outcome, use
  current verified SaneCite claims, say `I built SaneCite`, put the CTA/link
  last, contain no signature or hashtags, and pass dry-run, duplicate, and cap
  checks. Persisted automation read-back is current and the automation guard
  remains green at 35/35. The project `.outreach.yml` and shared `social` and
  `outreach` skills now record the same narrow standing exception so future
  runs do not regress to the old queue-absence skip behavior.
- The missed 2026-07-18 SaneCite slot was corrected immediately. The post is
  live and directly verified through the X API at
  `https://x.com/MrSaneApps/status/2078505217331429471` (created
  `2026-07-18T15:40:35Z`). It opens with the unsupported-answer/evidence-hunting
  problem, contrasts a cited answer or honest unknown with guessing, discloses
  `I built SaneCite`, and ends with the free-questionnaire CTA. The canonical
  `x-post.py` dry run passed at 277 characters before the real post.
- User-approved SaneLot outreach sent on 2026-07-18: the value-first X post is
  live at `https://x.com/MrSaneApps/status/2078502446582657137` with no signature.
  Private review invitations using the business signature were delivered to
  Dealership Fixit (`712ac921-fbe2-4bca-a5f0-b419616aaf73`) and ASOTU
  (`3f949e05-1370-4b94-965c-34d3dfe9e4b8`). The campaign audit found two send
  records, delivery evidence for both recipients, and no replies/unsubscribes yet.
- The X API also directly verified the existing SaneCite value-first post at
  `https://x.com/MrSaneApps/status/2074693692451926216` (created
  `2026-07-08T03:14:56Z`). It leads with the 10–40-hour questionnaire problem,
  then the evidence/citation/unknown outcome. No newer SaneCite post was made in
  the repaired July 18 run because the reviewed SaneCite queue is absent.
- The active Mini automation `saneapps-x-opportunity-scout` now has an explicit
  value-first publish gate for both products. It must reject ready items that
  lead with launch/beta/event/price/product language, may not rewrite and approve
  them in the same run, and must report `ready item fails value-first policy; no
  post`. Persisted `automation.toml` read-back and the automation guard are green
  (35/35).
- The Mini-local heartbeat target `/Users/stephansmac/SaneApps/infra/scripts/x-opportunity-scout.py`
  now runs five bounded searches for SaneCite and SaneLot, fetches up to 100
  results per query, deduplicates authors, and locally rejects keyword noise.
- SaneCite results are separated into direct requests, pain, relevant
  conversations, and non-actionable industry/promotional signals.
- SaneLot now treats public inventory posts from real dealer accounts as beta
  review candidates and separately treats dealership podcasters, reviewers,
  media, and automotive creators as beta review partners. The outreach goal is
  founder-led feedback before launch in a few weeks through the verified public
  TestFlight link `https://testflight.apple.com/join/hPv1tGs2`. Candidate reports
  now lead with the product value: SaneLot takes a car from VIN to a verified live
  listing in about five minutes from one iPhone, with guided photos, comp-based
  pricing, and sales copy that will not invent facts. The suggested invitation asks for blunt
  feedback only after that value hook and is explicitly marked as an unapproved
  draft. Dealer/media reviewers get a tailored version that explains the guided
  walkaround, comp-based pricing, fact-checked sales copy, and verified dealer-site
  read-back before asking what is wrong or missing. Use owner-approved email or DM,
  not cold replies on unrelated vehicle listings. Private sellers, classified-ad
  platforms, DMS vendors, name collisions such as `Frazer Town`, and clearly
  non-US dealers do not inflate the actionable dealer count.
- The 2026-07-18 live run scanned 42 SaneCite and 141 SaneLot posts and persisted
  11 actionable candidates: 4 SaneCite conversations and 7 SaneLot opportunities
  (5 dealer accounts plus 2 review/media partners), with 9 market signals kept
  separate. Report: `outputs/x-outreach/opportunities-2026-07-18.md`.
- Regression coverage in `scripts/automation/x_opportunity_scout_test.py` passes
  15/15, including questionnaire noise, real dealer listings, private/classified
  sellers, Frazer name collisions, automotive vendors, non-US dealers, and
  dealership podcasters. The repair made no public post or external contact.

## Branch Convergence And Release Audit Hardening

- Every fetched local/remote branch diff was classified against `main` by
  ancestry, patch equivalence, current-file evidence, and live PR state.
- `codex/no-github-release-policy`, `fix/hook-staleness-gates`,
  `fix/sane-gates-self-improving`, and
  `reconcile/sane-gates-convergence-20260707` were already contained by main.
- Both Copilot feature patches were already integrated; their remaining unique
  commits were empty planning commits. April preservation branches and the June
  Mini handoff were superseded snapshots, not safe merge candidates. They were
  intentionally not replayed because they would restore retired Safari,
  Cloudflare SSH, legacy memory, Bundler, or unsafe App Store behavior.
- Dependabot PR 16 was closed as superseded: it requested Hono 4.12.26 while
  main already contained 4.12.27. Remote branches were retained because branch
  deletion was not requested and remains catastrophically guarded.
- The useful unique content was ported selectively: SaneScan now uses the live
  `com.sanescan.app.pro.yearly6` StoreKit product ID with standalone parity
  coverage, and App Store permission declarations are read from exact root
  plist keys rather than mixed executable strings.
- App Store authorization now audits the exact staged `.pkg`/`.ipa` bytes,
  uniquely selects the expected bundle, recursively checks shipped app,
  extension, framework, dylib, Mach-O helper, and runnable helper payloads, and
  fails closed on missing metadata, parser/tool failures, ambiguity, byte
  changes, duplicate uploads, or wrong ASC marketing-version/build/platform.
- Existing ASC-build reuse (`--skip-upload`, `--asc-build-id`,
  `--build-number`) is explicitly retired because App Store Connect cannot
  prove the remote bytes equal a local package. The recovery path is a fresh
  package with an incremented build number; no caller-asserted provenance path
  remains.

## AgentMemory Incident Repaired And Verified

- Mini AgentMemory is healthy on loopback port 3111 with v0.9.27, healthy
  embeddings, and a closed circuit. The active catalog exposes
  `mcp__agentmemory__*` semantic tools and no legacy `mcp__memory__*` tools.
- The false outage report came from stale global instructions that called the
  retired graph namespace and treated optional graph extraction as required.
  `memory_graph_query` returning `Knowledge graph not enabled` is expected in
  the SaneApps contract and is not an AgentMemory outage.
- The separate Air defect was real: the prior MCP wrapper created an
  unmonitored one-shot SSH tunnel, and Air loopback 3111 closed after that
  tunnel died. A launchd-owned persistent private tunnel is now installed and
  running on the Air.
- `@agentmemory/mcp` v0.9.27 drops the advertised `memory_save.project` in its
  standalone proxy, so MCP saves are durable but unscoped. Project-scoped facts
  currently use Mini loopback REST `/agentmemory/remember`; this is a tracked
  shim limitation, not an AgentMemory outage.
- Diagnose reports 1,208 latest memories: two current facts are scoped and
  1,206 imported legacy facts remain unscoped. All 2,152 stored versions are
  structurally consistent. The supported inference migration cannot
  disambiguate the legacy corpus, so bulk project reassignment is unsafe.
- Air acceptance now proves live tunnel health and semantic search. AgentMemory
  architecture and SaneHosts facts were re-saved project-scoped through REST,
  recalled successfully, and their unscoped duplicates governance-deleted.
- Do not run installed `agentmemory help` while the live v0.9.27 service is
  active: it starts a competing instance and caused diagnostic-induced transient
  404/timeouts. The exact processes were terminated, the supervisor recovered,
  and Air health + search passed three consecutive rounds. Use
  `agentmemory --version`, local source/docs, or REST health endpoints; this was
  not a recurrence of the Air tunnel ownership bug.

## Current Machine Contract

- The Mini is the always-on SaneApps build, test, browser-proof, automation,
  and shared-memory server.
- On the Mini, work directly in the local checkout. Do not `ssh mini` back into
  the same machine. From the Air, use `ssh mini`.
- Air-to-Mini routing is private Bonjour LAN first, then authenticated
  Tailscale. The public Cloudflare quick tunnel is retired.
- Mini-to-Air recovery is intentionally enabled as `ssh air` through Tailscale
  with a dedicated Ed25519 identity, `IdentitiesOnly yes`, and no agent
  forwarding.
- GitHub `main` is canonical for committed code. Dirty work is never mirrored,
  auto-committed, auto-stashed, or auto-applied; it is preserved as snapshots.
- Air `com.saneapps.memory-sync` owns conflict-preserving, backup-first,
  no-delete Claude/Serena/Codex file-memory parity every 15 minutes.
- Mini `com.saneapps.agentmemory` owns shared semantic recall on loopback port
  3111. Air access uses the running launchd-owned persistent private SSH tunnel
  and the verified semantic MCP recall path.

## Power And Maintenance

- Daily maintenance never shuts down or restarts the Mini.
- `mini-memory-guard.sh` performs restart-free hygiene and bounds deep cleanup
  to 20 minutes with process-group TERM/KILL cleanup.
- A root-owned Sunday restart gate tries at 10:30, 11:30, and 12:30 only after
  six days uptime and only when FileVault is off, auto-login is configured,
  no user/SSH/build/release/recording/install/Codex work is active, no
  maintenance lease is live, and no HID activity occurred in 30 minutes.
- FileVault is off and automatic login is configured for `stephansmac` by the
  owner's explicit choice for this physically secured server.
- Local SaneAI/SaneSync runtime, training jobs, models, MLX/Ollama state, and
  automation clones are retired and must not be recreated by deploy/setup.

## Dependency Contract

- Both machines use Node 24.18.0 LTS with bundled npm 11.16.0, Homebrew Ruby
  4.0.6, and Python 3.14.6.
- Repo release paths pin Wrangler 4.104.0; global Wrangler is intentionally
  absent.
- Role-specific packages are allowed: AgentMemory and Playwright are Mini
  roles; Context7/Firecrawl are Air roles.
- `scripts/automation/dependency_baseline.rb` is the installation/check owner.
  Completion additionally requires every configured MCP executable and
  launchd endpoint to start successfully after an upgrade.

## Safety Contract

- Claude bypass mode and Codex trusted/full-access operation remain allowed.
- Normal SSH, rsync, browser, edit, build, test, commit, feature-push, PR,
  preflight, and reversible work must not be blocked by broad path policy.
- Approved local tools may consume credentials internally, including when the
  Air invokes a Mini workflow over SSH. Raw secret values remain non-exportable:
  never dump, print, copy, or return them in prompts, logs, or receipts.
- Real sends, customer/data mutations, releases/uploads, and reboots keep their
  exact canonical approval gates.
- Home/repository/system-root deletion, protected-history destruction, and
  destructive cloud/data/credential/ownership/license/money operations are
  manual user-only actions with no unattended override.

## Final Verification

- Air `server_acceptance` passed 35/35 at the Air-owned receipt
  `/Users/sj/SaneApps/infra/SaneProcess/outputs/restart-acceptance/20260715T125633Z.json`
  with workflow receipt `790d2656a92ee15cd3bed775df51986f`. It includes
  persistent-tunnel launchd health, Air loopback 3111, and live semantic search;
  it supersedes the older 32/32 receipt that omitted the Air recall path.
- Strict file-memory checksum parity passed at `20260715T124619Z`.
- AgentMemory architecture and SaneHosts facts were re-saved project-scoped
  through REST and recalled successfully; their unscoped duplicates were
  governance-deleted.
- AgentMemory fault injection killed the child engine and launchd recovered it
  within 60 seconds with v0.9.27, embeddings healthy, and all 1,201 memories.
- Full Mini verification passed 1,373 tests in 391 seconds with workflow receipt
  `6b65d5d09daecbadb68f84e2f0c11632` and durable logs under
  `outputs/verify/20260718T020226.435712Z-67333-78ddd533/`.
- Focused final receipts also passed: App Store submit 48/48, release guardrails
  225/225, validation 81/81, receipt signer 15/15, command registry/actual CLI
  5/5, Mini routing 24/24, and Safari/security guards 117/117.
- The live portfolio validation snapshot remains NOT READY FOR RELEASE because
  of pre-existing customer-facing product/release blockers; it reported no
  StoreKit parity drift and is not a failure of this SaneProcess convergence.
- The canonical secret scan passed with zero findings at
  `/Users/stephansmac/SaneApps/infra/SaneProcess/outputs/secret-scan/20260714-203836-secret-scan.json`.
- Supported MCP checks passed for GitHub, Apple Docs, macOS Automator, Serena,
  Xcode, Node REPL, AgentMemory, and OpenAI developer docs.

## Audit Findings Closed

- Old daily-reboot, self-SSH, training, central-memory, and raw-mirror
  instructions are superseded across active docs, hooks, templates, and memory.
- Both machines use the converged dependency baseline; retired Memory MCP and
  training packages/services are absent.
- Ordinary reads, edits, Git, SSH, rsync, build/test, browser, and approved
  credential consumers work while catastrophic operations remain blocked.
- Task-completion and stop hooks no longer demand UI receipts for non-UI work
  or blame the current session for pre-existing dirty files.
- Dirty-work snapshots preserve the current state without storing removed-line
  or deleted-file preimages; the full repo secret scan is clean.
- Xcode MCP health survives sandboxed process enumeration and stale
  LaunchServices registration.

## After The Owner Restarts Both Machines And Clients

1. Restart Codex and Claude on both machines, then run the supplied Air Claude
   acceptance prompt using fixtures, dry-runs, preflights, and disposable
   canaries only.
2. When literal Mini and Air machine reboots are convenient, rerun
   `ruby scripts/SaneMaster.rb server_acceptance` from the Air. The current
   35/35 receipt is pre-reboot evidence; the services are restart-configured,
   but a later post-reboot receipt is the final boot-cycle proof.

No login or portal action is currently required from the owner; Air GitHub was
renewed successfully. If a later
browser/API lane finds a real expired session, name the exact portal once and
stop instead of repeatedly prompting.
