# SaneProcess Session Handoff

As of: 2026-08-21 America/New_York
Owner host: Mac Mini = tree truth; Air = controller.
Repo: `~/SaneApps/infra/SaneProcess`

## 2026-08-21 regular clients: Grok, Grokbot, Cursor

- Owner: daily work is Grok, Grokbot, and Cursor. SaneProcess stays compatible
  with Codex and Claude. Do not route regular jobs or new recurring work through
  OpenAI/Anthropic. Recurring work uses SaneMaster/launchd plus Mini Grok
  headless heartbeats. All Air and Mini Codex heartbeats are PAUSED after the
  replacements were proven.
- Proven 2026-08-21: Mini Grok heartbeat smoke (`PONG`); App+CWS review watch
  GET-only (UTF-8 fix); SaneCite Monday sweep HTTP (Air, 0 failures); SaneBar
  macOS 27 watch (still beta, no notify). X scout is now a Grok heartbeat, not
  the paid X API. Launch-ops / Prophecy resume use the same Grok runner; not
  executed fully this pass because they mutate inbox/batches.
- NVIDIA weekly scout was not moved: `nvidia_eval` is not in SaneMaster and the
  NVIDIA-agent rule forbids it unless the owner asks again. SaneClip 8am
  release and SaneLot 1.2.1 live-auction gate stay retired/paused.
- D-U-N-S reminder was a one-shot Codex nag; paused. Still an owner task if
  SaneLot Google verification needs it.

## 2026-08-21 keep-current: pins apply themselves, Grok wrappers stop drifting

- Weekly Air LaunchAgent `com.saneapps.keep-current` (Sunday 09:15) applies npm
  pins, auto-bumps `firecrawl-cli` within the same major, and notifies only on
  drift. Mini nightly applies Mini pins. Homebrew/Codex/Claude are not
  auto-upgraded; Claude `autoUpdates` is now on; Grok already auto-updates.
- Grok wrappers live in git `scripts/grok-bin/` (`cloudflare-mcp-remote.sh`,
  `xcode-mcp.sh`, `xcode-mcp-frame.py`). `sync_grok` overlays them and no longer
  `--delete`s `~/.grok/bin` (that was wiping the Grok CLI).
- Air Grok apple-docs is HTTP `http://127.0.0.1:37911/mcp` through the existing
  AgentMemory tunnel, which also forwards 37911/37913/37915. Xcode is the Mini
  HTTP singleton at `http://127.0.0.1:37915/mcp`, not a fresh SSH stdio spawn.
  mcpbridge still needs Xcode open on Mini. Proven 2026-08-21: Mini `/healthz`
  ok, Air initialize HTTP 200, live Grok `XcodeListWindows` returned Mini
  SaneHosts. Leftover Mini `com.saneapps.x-opportunity-scout` plist was
  removed; the live 10:00 job is the Grok heartbeat.
- Firecrawl CLI is 1.23.1 with `firecrawl developer` and the
  `firecrawl-developer-index` skill. No Firecrawl MCP.

## 2026-08-21 native Grok/Cursor hooks, Codex/Claude stay adapters

- Grok was importing Claude `settings.json` hooks. Those scripts read
  `tool_name == "Bash"` and no-op on `GROK_HOOK_EVENT`, so Grok shell guards
  never saw `toolName: run_terminal_command`. Native Grok hooks live in
  `~/.grok/hooks/sane-guards.json` (git source `scripts/hooks/grok/hooks.json`).
  Grok `compat.claude` / `compat.cursor` hook import is off so the Claude SOP
  no-ops do not paint every tool. Shared payload adapter:
  `scripts/hooks/core/hook_payload.rb`. Cursor `~/.cursor/hooks.json` still
  runs the Cursor adapters. Claude `.claude/settings.json` and Codex stay on
  their own registrations.

## 2026-08-16 machine_cleanup hunts junk by kind, not free space

- Owner correction: Air `machine_cleanup` was skipping generated junk because
  the disk was marked healthy (451G free). Hygiene now plans unnecessary
  generated dumps on any host regardless of free space. Disk pressure still
  gates only expensive-to-restore caches (Playwright, HuggingFace,
  `codex-runtimes`, npm/npx, simulator runtime images).
- Air apply reclaimed the planned set (19.84G planned, 117/117 actions, Trash
  emptied). SaneLot dropped from 14G to 1.3G after
  `outputs/mini-storage-archive`, loose verify xcresults, and old run
  xcresults were removed. SaneVideo container `tmp`, setapp_review, uv stale
  archives, pnpm cache, and memory-sync backups are gone. Codex sessions,
  SaneVideo Documents, Logos, Photos, and sim runtimes were left alone.
- Nightly: Air `com.saneapps.machine-cleanup` at 05:40 runs
  `machine_cleanup --host local --apply --quiet`. Mini
  `com.saneapps.memory-guard` at 05:40 still runs the server reset. Planner
  files were copied to the Mini checkout so tonight's Mini pass uses the new
  rules.

## 2026-08-17 locked Mini screenshot evidence lane

- `capture-mini-screenshot.sh --locked-evidence` now preserves nonzero helper
  failures, runs through a clean non-login GUI shell, and delegates to a fresh
  private byte-bound helper tree rather than the shared `/tmp` copy.
- `mini-screenshot-evidence-helper.sh` validates and copies the exact helper
  inventory, uses absolute system tools, re-raises the exact Brave PID/title
  immediately before capture, suppresses window-title JSON, and removes its
  private stage/runtime trees. The SaneLot checkpoint receipt separately binds
  the wrapper, helper runner, GUI runner/AppleScript/reclaimer, and screenshot
  helper bytes before and after capture.
- Mini proof is green: GUI runner **36/36**, locked evidence **2/2**, shell
  syntax, and diff check. Independent review found no P0/P1; this is tool proof,
  not SaneLot live-host or release proof.

## 2026-08-16 App Review/CWS watcher live recovery

- The shared 15-minute Mini heartbeat is ACTIVE and still runs only the two
  canonical GET-only Apple and Chrome Web Store watchers. Its governing-file
  path was corrected through `automation_update` from the nonexistent
  `/Users/stephansmac/SaneApps/AGENTS.md` to
  `/Users/stephansmac/AGENTS.md`; cadence, target task, mutation prohibitions,
  pending-alert retry behavior, and model inheritance were preserved.
- A fresh paired Mini run returned status `ok` for both watchers with zero
  delivered, zero pending, and no diagnostics. The CWS OAuth refresh path also
  returned `official_get: ok`; the current dashboard revision remains rejected
  1.2.0 until the separately gated 1.2.1 submission.

## 2026-08-10 CWS watcher configuration-loss diagnosis and receipt hardening

- The 15-minute App Review heartbeat is still active. Its publisher ID and
  dedicated OAuth client ID were restored one at a time through the watcher's
  guarded stdin route into the private Mini cache. The CWS lane now fails
  precisely at `oauth_missing` because the read-only refresh grant has not yet
  been completed; no browser grant or store mutation occurred. A Desktop OAuth
  client secret is not required. The Apple lane remains independent and its
  latest GET-only run was green with no pending transition.
- Google Chrome Web Store API v2 still requires the publisher ID in the
  `publishers/{publisherId}/items/{itemId}:fetchStatus` path. Google's current
  official guide says the ID must be read from Developer Dashboard > Publisher
  > Settings; the API has no publisher-list discovery route. `fetchStatus`
  continues to accept the exact `chromewebstore.readonly` scope.
- `cws_review_watch.rb` now treats empty process variables as absent instead of
  letting them mask a valid private-cache value. Every run writes a private,
  atomic, redacted `~/SaneApps/outputs/cws-review-watch-receipt.json` that names
  config sources and distinguishes missing/invalid publisher ID, missing OAuth,
  OAuth failure, official GET failure, and pending alert delivery. It never
  writes IDs, tokens, secrets, provider bodies, or watcher state into that
  receipt. Desktop PKCE now omits an unavailable client secret from code and
  refresh exchanges while retaining compatibility when one exists. Focused
  proof is green: OAuth 9/9, CWS watcher 23/23, App Review watcher 24/24,
  automation guard 32/32, Ruby syntax, and `git diff --check`.
- Resolved 2026-08-16: the exact read-only grant now returns
  `official_get: ok`, and `automation_update` corrected the governing-file path
  while preserving the existing cadence and target task. No substitute
  scheduler or direct TOML mutation was used.

This file is current state only. Historical detail belongs in git history,
dated research, AgentMemory, and durable architecture decisions.

## 2026-08-08 Mini Brave web-capture correction

- The canonical web screenshot wrapper now launches the installed Mini Brave
  executable through Playwright instead of downloading or using cached Chromium.
  It accepts named `desktop` (1440x1000) and `375` (375x900) viewports and binds
  the chosen label and dimensions into each filename and receipt.
- Full-page capture primes lazy-loaded images with a bounded scroll, returns to
  the top, and records the final PNG SHA-256 and byte count in the receipt.
- Focused Mini proof is green: wrapper source/syntax checks and viewport behavior
  pass 35/35. Four SaneLot pricing captures then completed through the corrected
  route. No preview server, headless Brave, or capture process remains.

## 2026-07-30 Launcher path and secret hardening

- End-session security review found that canonical app path overrides were not
  constrained before the staging replacement path, signature checks used
  shell-interpolated paths, and Release test mode imported unrelated secrets
  into the build environment.
- Both shared launchers now allow only the exact system, user Applications, or
  SaneApps transient path for the named app. Existing app replacement moves
  the old bundle to Trash. Signature and bundle-ID reads use argument arrays,
  and the secrets loader imports only signing and keychain variables.
- Regression coverage rejects an arbitrary directory override and proves that
  an unrelated commerce key is not imported into the build environment.

## 2026-07-30 Isolated runtime DerivedData discovery

- The first SaneHosts live retry after provisioning parity built successfully,
  but `CFFIXED_USER_HOME` caused Xcode to place DerivedData under the isolated
  fixture home. `test_mode` searched only the login user's DerivedData, treated
  the official install as stale, rebuilt, then failed to find the new app.
- `test_mode` now searches both the login user's DerivedData and the active
  `CFFIXED_USER_HOME` DerivedData root. The regression test creates a runnable
  app bundle under an isolated fixture home and proves it is selected.
- The retry failed before launch. No SaneHosts customer action ran and no
  production hosts file was changed.

## 2026-07-30 Release test-mode provisioning parity

- SaneHosts `test_mode --release` failed twice because the runtime build path
  asked Xcode for the named Developer ID profile without the provisioning
  update/authentication arguments used by the successful release archive.
  The cached profile is valid and byte-identical to the profile embedded in
  `/Applications/SaneHosts.app`; profile regeneration is not the fix.
- Release test mode now uses `generic/platform=macOS`,
  `-allowProvisioningUpdates`, and the complete ASC authentication argument
  set when all three credential values are available. Debug behavior is
  unchanged: it keeps `platform=macOS` and receives no provisioning flags.
  Authentication values are redacted from captured or timeout output.
- Focused proof passed locally and on the Mini: `test_mode_test.rb` 27/27.
  Canonical Mini `SaneMaster.rb verify --timeout 900` stopped before tests on
  the two existing unregistered test files already recorded below:
  `scripts/automation/app_review_watch_test.rb` and
  `scripts/hooks/gui_feedback_test.rb`. Workflow receipt
  `f1aed7d97091d7b167c371abecb8d796`; cleanup receipt
  `98ab18300869304b5d02f5172b598a45`.
- No app was launched. The next live SaneHosts retry belongs to the parent
  workflow after review and merge. The Mini Terminal visibility fixes below
  remain unchanged.

## 2026-07-30 Mini screenshot help fast path

- `capture-mini-screenshot.sh -h` and `--help` now print local usage and exit
  successfully before timeout validation, helper checks, host resolution,
  SSH, rsync, the visual guard, or the Mini GUI runner.
- The focused behavioral regression stubs SSH and rsync, supplies invalid
  runtime configuration, runs both help flags, and requires zero side effects.
  `mini_gui_run_test.rb` passes 33/33 on the Mini. A direct Mini `--help` run
  with invalid runtime configuration exited 0 in 0.00 seconds.

## 2026-07-30 Mini GUI host visibility repair

- A fresh SaneClick 1.3.3 app-only capture proved the screenshot bytes were
  clean, but the logged-in GUI runner exposed a large Terminal window titled
  `SaneApps Automation: Mini Screenshot` while the command ran. The target app
  stayed non-frontmost until post-command reclaim finished.
- `mini-gui-run.applescript` now binds window mutations to the exact Terminal
  window launched for the command, miniaturizes that window, and forces the
  Terminal host process hidden before the launcher returns. This keeps the
  automation host from covering the target even if Terminal reverses
  miniaturization while a busy tab changes state.
- Focused Mini proof passed 32/32 and the AppleScript compiled. A live
  12-second Mini acceptance command finished successfully while the bound AX
  read reported no Terminal process or window. SaneClick's live proof remains
  separate and resumes only after this shared fix lands.

## 2026-07-30 customer UI execution-evidence routing

- Branch `fix/customer-ui-execution-evidence-routing` adds
  `customer_ui_sweep --execution-evidence PATH` to the canonical command.
- Evidence must be a regular non-symlink JSON file under
  `outputs/customer-ui`. Air routing validates it before sync, remaps it into
  the exact Mini verify workspace, and verifies the synced SHA-256 before the
  app runner receives the path.
- Focused Mini proof passed: `release_route_test.rb` 28/28,
  `command_registry_test.rb` 6/6, and Ruby syntax checks for the changed
  command and contract files.
- Full `SaneMaster.rb verify --timeout 900` remains blocked before test
  execution by two pre-existing unregistered files:
  `scripts/automation/app_review_watch_test.rb` and
  `scripts/hooks/gui_feedback_test.rb`. A broader guardrail run also retained
  two unrelated baseline failures; the new execution-evidence cases passed.
- No installed-path screenshot acceptance was added. A deterministic positive
  screenshot test needs a real GUI window, so it does not belong in unit tests
  and must remain a separate Mini acceptance run.

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

## 2026-07-29 end-session clean-state ledger

- Every active primary checkout under `~/SaneApps` is clean on both hosts.
  The historical Air snapshot under `archive/SaneProcess-preserved-20260714-133017`
  was left unchanged and is not an active checkout.
- Stale linked worktrees were checkpointed and removed: one Air SaneVideo A/B
  worktree; Mini SaneClick, SaneClip, SaneBar, SaneSales, SaneScan, and
  SaneVideo release/audit worktrees. No uncommitted state was discarded.
- Diverged local tips remain recoverable on
  `checkpoint/air-sanelot-site-20260729` at `53b5e110`,
  `checkpoint/mini-sanevideo-main-20260729` at `3f2ba80d`, and
  `checkpoint/mini-main-20260729` in SaneProcess at `833d39d`.
- Air stash receipts:
  `infra/scripts=4ba036a1`,
  `sanelot=cc6fa11d`,
  `apps/SaneLot=371c381e`,
  `apps/SaneVideo=f8d48890`,
  `websites/sanecite-saas=56971ff7`,
  `websites/sanelot.com=b108067f`,
  `infra/SaneProcess=2b98bcf3`, and
  `SaneVideo A/B=8a46908a`.
- Mini primary-checkout stash receipts:
  `SaneUI=726083f2`,
  `sanelot=6a8afe4d`,
  `SaneLot=eeaddfa5`,
  `SaneBar=cd72f2de`,
  `SaneVideo=b6bbf68d`,
  `SaneSales=d1a96fdf`,
  `SaneScan=f75a55ec`,
  `sanecite-saas=053f7444`,
  `prophecy-ledger=f1cbf68b`,
  `sanelot.com=ae5cf67c`, and
  `SaneProcess=22db9b48`.
- Mini stale-worktree stash receipts:
  `SaneClick Keychain=18ea4473`,
  `SaneClick release=2bcf448e`,
  `SaneClip 2.3.22=cadf96a6`,
  `SaneClip 2.3.23=bf9f9a9d`,
  `SaneBar audit=f4fc7c44`,
  `SaneBar reorder=274b9d70`,
  `SaneBar reorder feature=0e074c1e`,
  `SaneSales gating=d8c99c57`,
  `SaneScan handoff=cb1a1a6a`,
  `SaneVideo E2E=87f0b1fa`,
  `SaneVideo mirror=c1e07b17`, and
  `SaneVideo release=533208b9`.
- Canonical cleanup receipts:
  Mini safe `29375cf850cb7560fe0f7f68cc476276` and server
  `81dd4f7a14a10c2cf8f8b837f403b46d`; Air safe
  `ff820a519830ba495405a957cfa6e257`. The Mini server pass kept the existing
  recoverable Trash and skipped generated-artifact pruning while this Codex GUI
  session was active.
- Exact process cleanup shut down both booted SaneLot simulators, their app
  processes, the three-day-old port-8765 server, SaneApps test processes, and
  Xcode on both hosts. No app was preserved for overnight work.
- SaneClick's canonical handoff now records 1.3.3/1303, the live licensed Mini
  state, and the remaining screenshot-wrapper blocker. Its docs-only update
  passed 189/189 tests and is on both the release branch and `main`.
- GitHub end-of-day review found eight open, mergeable Dependabot PRs with no
  configured checks and two intentional roadmap issues: SaneUI #1 and
  SaneHosts #6. The dependency PRs remain open because mergeability without a
  test result is not release proof.

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
