
## Session 106 (2026-04-20)

### Done
- Root-caused the remaining morning control-plane drift after repo sync was fixed: the canonical Air↔Mini wrappers still re-enabled Mini unattended runs by default.
- Confirmed the actual failure chain:
  - `sync-codex-mini.sh` still defaulted Mini AM/PM to `ACTIVE`
  - `reconcile-air-mini.sh` always called that default sync path
  - `start-workday.sh` also called the same default sync path
  - result: even after manually pausing both hosts, the next normal reconcile/start-workday run silently flipped the Mini back to `ACTIVE`
- Changed the shared control-plane policy so safe manual mode is the default:
  - `sync-codex-mini.sh` now keeps Mini AM/PM paused by default
  - explicit Mini runner activation is now opt-in via `--activate-mini-runs`
  - `reconcile-air-mini.sh` defaults to the paused sync path and only re-enables Mini runs when explicitly asked
  - `start-workday.sh` now keeps Mini runs paused by default and only activates them with `--activate-mini-runs`
- Added `--dump-config` to `sync-codex-mini.sh` and `reconcile-air-mini.sh` so mode selection can be proven locally without touching the Mini.
- Added focused regression coverage in `scripts/automation/control_plane_sync_test.rb`.
- Updated shared operator docs in `DEVELOPMENT.md` and `scripts/automation/README.md` so the new safe default is documented.
- Committed and pushed the change as `7ee1924` (`fix: make mini sync default to safe paused state`).

### Live Verification
- Local structural proof:
  - `bash -n scripts/automation/sync-codex-mini.sh`
  - `bash -n scripts/automation/reconcile-air-mini.sh`
  - `bash -n scripts/automation/start-workday.sh`
  - `ruby scripts/automation/control_plane_sync_test.rb` passed `4/4`
- Validation / control-plane proof:
  - `ruby scripts/validation_report.rb` ran cleanly enough to prove the tracked tree, and still flagged one real remaining hosted-file action: SaneBar Lemon hosted ZIP is `2.1.41` while appcast is `2.1.42`
- Live Air↔Mini proof from committed tree:
  - `bash scripts/automation/sync-codex-mini.sh mini --quiet --no-restart` now leaves both Air and Mini AM/PM TOMLs at `PAUSED`, and the Mini scheduler DB rows are also `PAUSED`
  - `bash scripts/automation/reconcile-air-mini.sh mini --quiet` now preserves the paused state instead of reactivating Mini runs
  - `bash scripts/automation/start-workday.sh mini --no-open` completed end to end:
    - Mini control-plane sync passed
    - Air↔Mini repo reconcile finished clean
    - Mini automation status showed both AM/PM `PAUSED`
    - local inbox summary rendered successfully
  - `ruby scripts/SaneMaster.rb status` completed end to end
- Current live status after the fixed morning pass:
  - Sales last 30 days: `74` orders / `$576.26` gross / `$525.25` kept
  - Inbox needs reply: `#608`, `#606`, `#604`
  - Replied and ready to resolve: `#603`, `#600`
  - Listings action-needed: only StartupSubmit follow-up on `#600`
  - Open GitHub issue: `SaneBar #129`
  - Open PRs: `SaneClip #8`, `SaneVideo #13-17`

### Current State
- The shared morning control-plane path is now self-consistent:
  - local manual-work default = paused
  - Mini paused state stays paused across sync, reconcile, and start-workday unless explicit activation is requested
- `SaneProcess` is clean and aligned on Air and Mini after the committed reconcile pass.
- Morning startup is ready to use again from the canonical scripts.
- One real non-tooling follow-up remains from validation: replace the stale SaneBar Lemon hosted file (`2.1.41`) so it matches the live appcast (`2.1.42`).

### Next
- If unattended Mini runs are intentionally needed again, use the explicit activation path instead of relying on hidden defaults:
  - `ruby scripts/SaneMaster.rb sync_mini mini --activate-mini-runs`
  - or `bash scripts/automation/start-workday.sh mini --activate-mini-runs`
- Clear the remaining real queue in order:
  - inbox `#608`, `#606`, `#604`
  - resolve delivered threads `#603` and `#600`
  - SaneBar `#129`
  - SaneBar hosted-file dashboard mismatch

### SOP: 10/10
- (+) Fixed the shared system behavior instead of manually re-pausing the Mini every morning.
- (+) Added a local dry-run proof path and a focused regression test so the mode logic can be verified without touching the Mini.
- (+) Re-ran the actual canonical wrappers (`sync-codex-mini`, `reconcile-air-mini`, `start-workday`, `SaneMaster status`) from the committed tree before calling the workflow ready.

## Session 105 (2026-04-20)

### Done
- Root-caused a shared inbox/status regression after the canonical `status` runner failed in `[2/5] Inbox status` with `ModuleNotFoundError: No module named 'email_delivery'`.
- Confirmed the real failure chain:
  - `infra/scripts/check-inbox.sh` imports `email_delivery`
  - `scripts/automation/email_delivery.py` and `scripts/automation/email_delivery_test.py` existed only in the untracked auto-reconcile stash commit `e3f0836`
  - those files never landed on tracked `main` / `origin/main`
  - durable memory/handoff language had claimed the delivery-aware inbox fix was complete even though the helper file was missing from the real tree
- Restored the missing tracked helper + regression test into `infra/SaneProcess`, committed `57fd824` (`fix: restore tracked email delivery helper`), and pushed it to `origin/main`.
- Reconciled Air and Mini with the canonical path `scripts/automation/reconcile-air-mini.sh mini`.

### Live Verification
- `python3 scripts/automation/email_delivery_test.py` passed `3/3`.
- `bash /Users/sj/SaneApps/infra/scripts/check-inbox.sh check` now runs cleanly again and shows live inbox state instead of crashing on import.
- `bash scripts/automation/sane-status-crossref.sh` now completes end-to-end again:
  - Sales: 74 orders / $576.26 gross / $525.25 kept over the last 30 days
  - Inbox: 3 action-needed threads (`#608`, `#606`, `#604`)
  - Listings: 1 needs-action row (`StartupSubmit`, email `#600`)
  - Open GitHub issues: `SaneBar #129` only
  - Open PRs: `SaneClip #8`, `SaneVideo #13-17`
- Canonical repo reconcile results:
  - Air: `SaneBar`, `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSales`, `SaneSync`, `SaneVideo`, `SaneAI`, and `SaneProcess` all clean and aligned
  - Mini: same repos reconciled clean; dirty `SaneBar` and dirty/behind `SaneProcess` were auto-stashed then synchronized successfully

### Current State
- The immediate split-brain repo problem is fixed. Air and Mini now agree on the tracked `SaneProcess` control-plane state.
- The shared inbox/status workflow is trustworthy again because the missing `email_delivery.py` helper is now tracked and pushed.
- One non-git fragmentation source remains: local Codex automation state differs between Air and Mini for `saneops-am-run` and `saneops-pm-run` (`PAUSED` on Air vs `ACTIVE` on Mini). That drift is outside repo sync and still needs an explicit automation decision if host parity matters.

### Next
- Decide whether to normalize the Mini `saneops-am-run` / `saneops-pm-run` automation status to match the Air (`PAUSED`), since that drift can still create “system looks out of sync” confusion even with repo parity restored.
- Resume the App Store screenshot/public-lane work from a clean synchronized base.

### SOP: 9/10
- (+) Fixed the shared tool instead of working around the broken status output.
- (+) Verified the actual root cause through memory/history plus current git state before changing code.
- (-) Durable notes previously claimed the inbox delivery fix was complete even though the helper files were never tracked on `main`.

## Session 104 (2026-04-14)

### Done
- Fixed the shared duplicate-app cleanup policy so both the Air and Mini end in exactly one canonical `/Applications/App.app` per Sane app.
- Root cause: shared tooling still treated `~/Applications` as a fallback install target, only auto-promoted missing canonicals from already-installed paths, and missed older staging roots like `~/SaneApps/release/**`.
- Updated `scripts/dedupe_sane_apps.rb` to:
  - always treat `/Applications/App.app` as canonical
  - promote missing canonicals from the best available artifact root
  - mark artifact roots as never-index
  - scan and clean `build/`, `outputs/`, `release/`, `release-publish/`, `release-worktrees/`, `~/SaneApps/tmp`, `~/tmp`, and DerivedData
- Updated shared runtime helpers so unsigned/dev fallback staging uses `/tmp/saneapps-staging.noindex` instead of `~/Applications`, and so post-run dedupe happens automatically after the normal verify/launch/test lanes.
- Updated the shared SOP text in `DEVELOPMENT.md` to make `/Applications`-only installs the explicit rule for both Air and Mini.

### Live Verification
- Local focused infra tests passed:
  - `ruby scripts/app_test_mode_test.rb`
  - `ruby scripts/sanemaster/test_mode_test.rb`
  - `ruby scripts/dedupe_sane_apps_test.rb`
- Mini focused infra tests passed with the same results after syncing the updated files.
- Air cleanup:
  - removed stale bundles from DerivedData, repo `build/`, repo `outputs/`, `~/SaneApps/tmp`, and `~/SaneApps/release`
  - promoted `SaneSync` from a stale archive bundle into `/Applications/SaneSync.app`
- Mini cleanup:
  - removed stale bundles from DerivedData, repo `build/`, `release-publish/`, `~/SaneApps/tmp`, and `~/tmp`
- Final filesystem inventory on both Air and Mini now shows exactly one bundle for each of `SaneBar`, `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSales`, `SaneSync`, and `SaneVideo`, all in `/Applications`.
- Final Spotlight (`mdfind`) inventory on both Air and Mini also shows exactly one bundle per app, all in `/Applications`.

### Current State
- The duplicate-app/TCC/LaunchServices drift class is now guarded in shared infra instead of being left to manual cleanup.
- Air and Mini are both clean right now for the core Sane apps.
- Older staging roots like `~/SaneApps/release` are now part of the same dedupe/no-index policy as the newer release worktrees.

### Next
- Commit and push the SaneProcess duplicate-app policy changes after checking around the unrelated untracked `scripts/automation/email_delivery*.py` files.
- If another app bundle family appears outside `/Applications`, treat it as a shared tooling regression first and extend `dedupe_sane_apps.rb` rather than hand-cleaning it again.

### SOP: 10/10
- (+) Fixed the shared install/dedupe policy instead of just deleting the current duplicates.
- (+) Proved the final state with both filesystem and Spotlight inventories on both machines.

## Session 103 (2026-04-14)

### Done
- Fixed a shared email-ops regression in `/Users/sj/SaneApps/infra/scripts/check-inbox.sh`.
- Root cause: the workflow treated Worker acceptance and D1 reply records as proof that an email landed, so a bounced outbound could still look “sent” or even “resolved”.
- Added shared delivery classification in `scripts/automation/email_delivery.py` so reply evidence now requires Resend delivery signals (`delivered`, `opened`, `clicked`, or `complained`).
- `check`, `context`, and `audit` now surface bounced outbound mail as active blockers instead of hiding it behind resolved/replied states.
- `reply` and `compose` no longer report success unless delivery is confirmed; bounced or still-unconfirmed sends now fail closed.
- Fixed the worker-side `reconcileReplies()` blind spot in `sane-email-automation/src/index.js` so D1 no longer promotes threads to `replied_external` from undelivered/bounced `Re:` traffic.
- Changed the reply API default status from `resolved` to `pending` so send acceptance alone no longer looks like the thread is finished.
- Hardened the audit path so null HTML bodies no longer crash the report.
- Updated the shared SOP docs to state that “sent” means delivery-confirmed, not merely accepted by the Worker.

### Live Verification
- Local: `bash -n /Users/sj/SaneApps/infra/scripts/check-inbox.sh`
- Local: `python3 -m py_compile scripts/automation/email_delivery.py scripts/automation/email_delivery_test.py`
- Local: `python3 scripts/automation/email_delivery_test.py` passed `2/2`
- Local: `node --test /Users/sj/SaneApps/infra/sane-email-automation/test/resend-delivery.test.mjs` passed
- Mini proof with temp copies:
  - `bash /tmp/inboxfix/check-inbox.sh context 551` now reports `Delivery: bounced=1 delivered=0 pending=0` and recommends reopen/fix/resend.
  - `bash /tmp/inboxfix/check-inbox.sh check` now surfaces StartupSubmit `#551` under `BOUNCED OUTBOUND — NEEDS FIX`.
  - `bash /tmp/inboxfix/check-inbox.sh audit` now completes instead of crashing and reports StartupSubmit `#551` under `CUSTOMERS WITH BOUNCED OUTBOUND ONLY`.

### Current State
- Shared email status is now delivery-aware instead of Worker-acceptance-aware.
- Worker reconciliation now agrees with the shell workflow instead of reintroducing false `replied_external` states.
- The known confirmed bounced thread is StartupSubmit `#551` on 2026-04-10; it is now surfaced by the normal inbox flows instead of being silently treated as handled.
- Resend/delivery confirmation is now the required truth source for “sent”.

### Next
- Present the exact StartupSubmit resend draft, record user approval, and resend through the corrected flow.
- If other bounced human replies are found in audit, handle them as active blockers rather than historical noise.

### SOP: 10/10
- (+) Fixed the shared workflow instead of patching one thread by hand.
- (+) Added a focused regression test plus Mini proof against real inbox data.

## Session 101 (2026-04-14)

### Done
- Fixed a real Mini/local verification-lane bug in `scripts/sanemaster/test_mode.rb`.
- Root cause: the non-log signed launch path still used LaunchServices `open` even when the launch depended on `SANEAPPS_DISABLE_KEYCHAIN=1` and `--sane-no-keychain`.
- On SaneBar this made the staged signed app come up as Basic even though `mode status` still reported Pro fallback state in defaults.
- Changed the launcher so any launch that depends on env vars or launch args bypasses `open` and spawns the app executable directly.
- Added `scripts/sanemaster/test_mode_test.rb` coverage for the launch-mode preservation decision.

### Live Verification
- `ruby scripts/sanemaster/test_mode_test.rb` passed `4/4`.
- `ruby -c scripts/sanemaster/test_mode.rb` passed.
- Mini `./scripts/SaneMaster.rb test_mode --release --no-logs` for SaneBar launched `/Applications/SaneBar.app` with `--sane-no-keychain` present in the live process list.
- Mini SaneBar `layout snapshot` then reported `licenseIsPro=true`, confirming the runtime lane was no longer silently downgrading to Basic.

### Current State
- Mini/local signed verification is trustworthy again for no-keychain launch modes.
- If a launch depends on env/args, `test_mode` no longer relies on LaunchServices to preserve them.

### Next
- Keep treating any Mini/local “mode says Pro but runtime acts Basic” mismatch as a tooling regression first, not an app regression.

### SOP: 10/10
- (+) Fixed the shared launcher instead of normalizing the false-Basic workaround.
- (+) Added a regression test and verified it on the real Mini lane.

## Session 102 (2026-04-14)

### Done
- Fixed a release-lane harness bug in `apps/SaneBar/Scripts/qa.rb`.
- Root cause: release smoke pass 2 reused the same staged app process from pass 1 but still enforced a fresh `launch` idle budget, so a hot second pass could fail as a fake launch regression.
- Changed the smoke runner to relaunch the staged target before every pass after pass 1.
- Added a matching structural guard in `apps/SaneBar/Tests/RuntimeGuardXCTests.swift`.
- Hardened routed release support-repo handling in `scripts/SaneMaster.rb`:
  - `release_preflight` no longer routes `sane-email-automation` at all because that command only inspects the live deployed worker
  - real routed `release` now falls back to a clean Mini/origin clone of `sane-email-automation` when the local worker repo is dirty or behind, instead of aborting before the app release lane can even start
- Added `scripts/sanemaster/release_route_test.rb` coverage for both routing changes.

### Live Verification
- `ruby scripts/sanemaster/release_route_test.rb` passed `11/11`.
- Local SaneBar `RuntimeGuardXCTests` passed after the QA structural change.
- Mini `./scripts/SaneMaster.rb verify` for SaneBar passed (`1069` tests).
- Mini routed `./scripts/SaneMaster.rb release_preflight` now gets past the old `sane-email-automation` route blocker and reaches the true remaining release blockers:
  - active runtime smoke average CPU `16.1% > 15.0%`
  - open regression policy gate on `#129`
  - live email worker drift serving `2.1.38` / build `2138` while appcast is `2.1.40` / build `2140`

### Current State
- The release lane is no longer blocked by a false pass-2 smoke artifact or by unrelated local email-worker dirt.
- If `release_preflight` fails now, it is failing on actual runtime/perf/governance/channel state.

### Next
- Investigate the active runtime smoke overrun in the staged signed SaneBar app.
- Decide whether `#129` is closeable or whether a manual open-regression release approval is warranted.
- Bring the live email worker back in sync before trusting the direct-download lane.

## Session 100 (2026-04-14)

### Done
- Finished the second cleanup wave for the GitHub local-first rollout instead of leaving it half-landed.
- Root-caused the last broken push path: `apps/SaneVideo/lefthook-local.yml` was still tracked and forcing stale Bundler-based local hooks on the Air.
- Removed the tracked SaneVideo `lefthook-local.yml`, added `lefthook-local.yml` to the canonical ignore sets across the touched repos, and updated the shared templates so future local hook overrides stay local-only.
- Committed and pushed the hook-override cleanup across:
  - `SaneBar` `1fc2189`
  - `SaneClick` `5ae8c46`
  - `SaneClip` `aeb3c70`
  - `SaneHosts` `7eab277`
  - `SaneSync` `d1943d3`
  - `SaneVideo` `dc7036a`
  - `SaneProcess` `bd14b64`
  - `Sane-AppleDocs` `c09d564`
  - `Sane-Mem` `251fa25`
  - `Sane-XcodeBuildMCP` `0144918`
- Fixed the real SaneVideo issue exposed by the repaired pre-push path:
  - `ExportCompositor.swift` was still mixing `Float` `settings.frameRate` with helper APIs that expect `Double`
  - normalized the frame rate once to `Double`
  - recorded the finding in `.claude/research.md`
  - committed and pushed `SaneVideo` `226e11b`

### Live Verification
- Confirmed there are no tracked `lefthook-local.yml` files left anywhere under `apps/`, `infra/`, `mcp/`, or `web/`.
- SaneVideo normal push path is now healthy again without `LEFTHOOK=0`:
  - `git push origin main` ran the real pre-push hook
  - hook routed `./scripts/SaneMaster.rb verify` to the Mini
  - Mini verify passed `1682` tests in `431s`
  - push completed `429cf74..226e11b`
- Additional repo pushes that re-ran their normal Mini verify path also passed:
  - `SaneBar` `1068` tests
  - `SaneClick` `96` tests
  - `SaneClip` `128` tests
  - `SaneHosts` `73` tests
  - `SaneSync` `54` tests
- Final remote alignment check after the push batch:
  - `SaneVideo`, `SaneBar`, `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSync`, `SaneProcess`, `Sane-AppleDocs`, `Sane-Mem`, and `Sane-XcodeBuildMCP` all report `origin/main...main = 0 0`

### Current State
- The GitHub local-first policy is now pushed, not just staged locally.
- The hook-override policy is now durable:
  - shared templates ignore `lefthook-local.yml`
  - touched repos ignore it too
  - the tracked SaneVideo override that caused the bypass is gone
- The repaired SaneVideo pre-push path now exposes real regressions instead of silently forcing `LEFTHOOK=0`, which is exactly what happened with the `Float`/`Double` export bug.
- Remaining unrelated local work still exists in `infra/SaneProcess/scripts/mini/*`; it was intentionally not staged or pushed as part of this policy pass.

### Next
- Keep GitHub-hosted runs manual and exceptional. Default remains Mini/local-first.
- If another repo ever needs a local hook override, it should live only in an untracked `lefthook-local.yml`.
- If a future push needs `LEFTHOOK=0`, treat that as a bug in the hook path and fix the hook path instead of normalizing the bypass.

### SOP: 10/10
- (+) Finished the policy rollout all the way through real pushes and real pre-push verification.
- (+) Fixed the actual broken hook root cause instead of keeping the bypass.
- (+) Left the unrelated `scripts/mini/*` worktree changes untouched.

## Session 99 (2026-04-13)

### Done
- Switched the active SaneApps GitHub workflow set to local/Mini-first policy across the repos in this checkout.
- Converted app CI in `SaneVideo` and `SaneClip` from automatic `push` / `pull_request` GitHub-hosted runs to `workflow_dispatch` manual fallback with optional `ref` input and concurrency cancellation.
- Converted the MCP repo workflows in `Sane-AppleDocs`, `Sane-Mem`, and `Sane-XcodeBuildMCP` to manual-only where practical:
  - CI, PR validation, stale cleanup, and release flows are now explicit `workflow_dispatch`
  - comment/AI helper workflows now require explicit manual inputs instead of auto-running from comments/issues
- Removed repo-level `dependabot.yml` from the SaneApps app repos in this checkout so dependency PR churn is local-first too.
- Added a durable note to `DEVELOPMENT.md` that GitHub-hosted automation is fallback only and should not be reintroduced as automatic spend without a documented reason.
- Hardened the policy in `scripts/validation_report.rb` so repo-owned workflows and repo-level Dependabot configs are flagged if they use hosted automation without a `SANEAPPS_GITHUB_HOSTED_EXCEPTION: <reason>` note.
- Updated the bootstrap and release templates so new repos inherit the same Mini/local-first policy instead of teaching weekly or tag-driven hosted Actions.

### Live Verification
- Local YAML parse passed for all changed workflow files on the Air with `ruby -e 'require "yaml"; ... YAML.load_file(...)'`.
- The same YAML parse passed on the Mini after syncing the changed workflow files there.
- Local `ruby scripts/validation_report_test.rb` passed with the final workflow-policy coverage (`9/9`).
- Mini `ruby scripts/validation_report_test.rb` passed with the same workflow-policy coverage (`9/9` after the Dependabot guard was added).
- Direct local and Mini `check_github_workflow_policy` probes both returned `OK` against the current tree.
- Mini sync completed for:
  - `apps/SaneVideo`
  - `apps/SaneClip`
  - `mcp/Sane-AppleDocs`
  - `mcp/Sane-Mem`
  - `mcp/Sane-XcodeBuildMCP`
  - `infra/SaneProcess/DEVELOPMENT.md`
  - `infra/SaneProcess/scripts/validation_report.rb`
  - `infra/SaneProcess/scripts/validation_report_test.rb`
  - `infra/SaneProcess/templates/*` workflow-policy docs

### Current State
- Default GitHub cloud spend is now structurally suppressed by workflow triggers instead of relying on billing caps alone.
- Repo-level GitHub dependency PR churn is suppressed too unless a repo carries a documented exception.
- The organization can keep the GitHub Actions budget at `$0` and still use local/Mini verification as the canonical path.
- If GitHub-hosted work is ever needed again, it is now explicit and manual.
- New drift should be caught automatically by validation and by the updated repo/bootstrap templates before it spreads to more repos.

### Next
- Do not push these workflow changes until the user approves any GitHub writes.
- If a repo genuinely needs remote automation later, prefer a documented self-hosted Mini runner or a narrowly-scoped manual dispatch over automatic hosted CI.

### SOP: 10/10
- (+) Changed policy at the trigger level instead of relying on billing alerts.
- (+) Verified syntax locally and on the Mini after sync.
- (+) Recorded the new workflow policy in both memory and durable docs.

## Session 98 (2026-04-13)

### Done
- Confirmed a deeper architecture mismatch instead of doing another blind training pass:
  - inspected the shipped SaneVideo commentary path and verified `AIService.generateCommentaryPlan(...)` does not call the trained model at all
  - the app currently uses the deterministic `CommentaryWorkflowPlanner` in `SaneVideo/Core/Models/DemoStudioModels.swift`
- Added a repeatable Mini-first diagnostic at `scripts/mini/commentary_hybrid_probe.py`
  - the probe parses each `eval_commentary_workflow.jsonl` case
  - retrieves the closest commentary scenario from the SaneVideo workflow corpus
  - grounds `sourceExcerpt` / `startTime` / `endTime` from the transcript excerpt directly
  - reuses the matched scenario's claim/reference pattern to test a planner+retrieval hybrid baseline against the exact same strict commentary gate
- Fixed one portability bug in the new probe:
  - the first draft hard-coded `/Users/sj/...`
  - updated it to use `Path.home()` so the same script runs on both the Air and the Mini

### Live Verification
- Local verification:
  - `python3 -m py_compile /Users/sj/SaneApps/infra/SaneProcess/scripts/mini/commentary_hybrid_probe.py` passed
  - `python3 /Users/sj/SaneApps/infra/SaneProcess/scripts/mini/commentary_hybrid_probe.py` scored `6/6` on `commentary_workflow`
- Mini verification:
  - synced `commentary_hybrid_probe.py` to `/Users/stephansmac/SaneApps/infra/SaneProcess/scripts/mini/commentary_hybrid_probe.py`
  - `python3 /Users/stephansmac/SaneApps/infra/SaneProcess/scripts/mini/commentary_hybrid_probe.py` also scored `6/6`
- Contrast with the real training lane still stands:
  - raw SmolLM3 workflow-only eval on the Mini is still `0/6`
  - the hybrid probe using deterministic grounding + retrieval is `6/6`

### Current State
- The missing piece is now concrete:
  - SaneAI training is being judged on an end-to-end raw-generation task that the shipped product does not even use today
  - the current 3B Mini lane cannot reliably learn the full commentary workflow contract end to end
  - a simple planner/retrieval hybrid already clears the strict commentary gate on the same data
- That means the bottleneck is not "more nightly tuning on the Mini"
- It is the missing hybrid architecture layer between transcript grounding and final workflow JSON

### Next
- Stop treating raw-model commentary generation as the only viable path.
- Next implementation work should be one of these:
  - promote the planner+retrieval baseline into a real app/runtime path and then evaluate that path honestly
  - or split training so the model only fills the parts that actually need generation, instead of forcing it to invent the whole workflow object from scratch
- Keep the new hybrid probe around as the sanity check:
  - if raw-model training changes do not beat `commentary_hybrid_probe.py`, they are solving the wrong problem

### SOP: 10/10
- (+) Verified the real shipped app path before assuming the training lane represented production behavior.
- (+) Turned the architecture hypothesis into a repeatable Mini probe instead of leaving it as opinion.
- (+) Proved the gap on the same eval contract: `0/6` raw model vs `6/6` hybrid baseline.

## Session 97 (2026-04-13)

### Done
- Traced the Mini "Python quit unexpectedly" dialog to the actual MLX crash path:
  - pulled the matching DiagnosticReports entry for the screenshoted dialog
  - confirmed the crash was `Python 3.14.3` aborting inside `mlx::core::gpu::check_error(MTL::CommandBuffer*)` on `com.Metal.CompletionQueueDispatch`
  - verified it was the training/eval Python process, not a separate system service problem
- Tightened the SaneAI workflow training inputs instead of guessing:
  - added a compact workflow prompt variant plus compact assistant payload shaping in `apps/SaneVideo/training_data/generate_workflow_dataset.py`
  - added `generate_workflow_dataset_test.py`
  - compressed `SaneAI/training_data/system_prompt.txt`
  - regenerated `apps/SaneVideo/training_data/train.jsonl` + `valid.jsonl`
  - rebuilt `SaneAI/training_data/train.jsonl` + `valid.jsonl`
- Proved that sequence-length damage was real:
  - before prompt compression, the merged SaneAI corpus had `480` workflow train examples and `6` workflow valid examples over the SmolLM3 Mini `max_seq_length` of `1664`
  - after compression, over-limit counts dropped to `0 / 0` and the longest merged sample dropped to `1066` tokens
- Ran live Mini experiments against the updated source tree:
  - unified SaneAI + SmolLM3, 25-step run on the first compacted corpus
  - unified SaneAI + SmolLM3, 30-step run on the declipped corpus
  - workflow-only SmolLM3 experiment filtered from the merged corpus (`1440` workflow train / `36` workflow valid) at 30 steps
  - longer workflow-only SmolLM3 experiment at 100 steps
  - explicit checkpoint-50 eval for the workflow-only 100-step run

### Live Verification
- Screenshot/crash verification:
  - captured the Mini window and matched it to `/Users/stephansmac/Library/Logs/DiagnosticReports/Python-2026-04-13-152638.ips`
  - crash report showed `EXC_CRASH (SIGABRT)` with `abort()` called from MLX Metal GPU completion handling
- Local/source verification:
  - `python3 /Users/sj/SaneApps/apps/SaneVideo/training_data/generate_workflow_dataset_test.py` passed
  - `python3 -m py_compile` passed for the changed SaneVideo generator/test and SaneAI merge script
  - regenerated SaneVideo workflow corpus now reports `72` unique assistant payloads in train and `36` in valid
- Mini/source verification:
  - `python3 ~/SaneApps/apps/SaneVideo/training_data/generate_workflow_dataset_test.py` passed
  - source-root token audit on the merged SaneAI corpus:
    - before compression: `train over_limit=480`, `valid over_limit=6`
    - after compression: `train over_limit=0`, `valid over_limit=0`
  - unified 30-step declipped run completed in ~5 minutes with no sequence warnings, first val in ~4.2s, and peak memory ~`3.578 GB`
  - workflow-only 30-step run reached val loss `0.264` by step 30
  - workflow-only 100-step run reached val loss `0.206` by step 50 and stayed stable on the Mini

### Current State
- Sequence-length corruption on the Mini was a real blocker and is now fixed for the current merged corpus.
- Fixing that blocker improved stability a lot:
  - no more `!` collapse on the declipped unified run
  - no more over-limit warnings
  - lower memory and faster validation
- But the strict commentary gate still did not move:
  - unified declipped SaneAI run: `0/6`
  - workflow-only run at 30 steps: `0/6`
  - workflow-only run at 100 steps: `0/6`
  - workflow-only checkpoint-50 eval: `0/6`
- The outputs are more on-task than before, but they still miss the exact summary/item constraints and still sometimes truncate or omit required fields. This is no longer an infra problem and no longer a context-window corruption problem.

### Next
- Stop spending time on the unified SmolLM3-on-Mini strategy for this workflow gate.
- Treat the remaining problem as an architecture/supervision issue:
  - either a dedicated workflow model/router with stronger commentary-specific labels and a looser/non-conflicting objective
  - or a larger/stronger hardware/model lane for workflow training
- If another Mini probe is needed, use the declipped source-root corpus as the baseline. Do not go back to the old over-limit prompt shape.

### SOP: 9/10
- (+) Moved from symptom-chasing to measured Mini experiments with exact corpus-length audits.
- (+) Verified the crash dialog against the real MLX/Metal crash log instead of inferring from the screenshot alone.
- (+) Proved that prompt-length corruption was real before drawing the final conclusion.
- (-) Lost time once on the wrong sync path because `reconcile-air-mini.sh` correctly stashed dirty worktrees instead of propagating them.

## Session 96 (2026-04-13)

### Done
- Fixed a real automation-root prep gap for SaneAI:
  - `scripts/mini/mini-prepare-automation-root.sh` now maps a top-level source repo at `~/SaneApps/SaneAI` into the canonical automation-root target `~/SaneApps-automation/apps/SaneAI` when `apps/SaneAI` is absent in the source tree.
  - Before this fix, the prep script only cloned repos found under `apps/` and `infra/`, so a source tree with top-level `SaneAI` could leave the actual SaneAI automation clone stale or missing even though training-data hydration had a top-level fallback.
- Added a regression check in `scripts/mini/mini_train_process_test.rb` for that top-level `SaneAI -> apps/SaneAI` mapping.
- Updated `scripts/mini/README.md` so the canonical Mini training docs now mention the top-level `SaneAI` repo fallback explicitly.

### Live Verification
- `bash -n /Users/sj/SaneApps/infra/SaneProcess/scripts/mini/mini-prepare-automation-root.sh` passed.
- `ruby /Users/sj/SaneApps/infra/SaneProcess/scripts/mini/mini_train_process_test.rb` passed `10/10`.
- Temp integration proof passed:
  - created a disposable top-level source repo at `<tmp>/source/SaneAI`
  - ran `mini-prepare-automation-root.sh` with `SANE_SOURCE_ROOT=<tmp>/source`
  - verified it cloned into `<tmp>/automation/apps/SaneAI`
- Fresh Mini SSH diagnosis is now narrower:
  - direct `ssh` reached DNS resolution, TCP connect, host-key verification, and `Server accepts key`
  - the connection then timed out only after the client sent the signed publickey packet
  - that points at a server-side `sshd` / account-path stall on the Mini, not a local alias or key-selection mistake
- After the Mini was manually rebooted, SSH recovered and the canonical Mini paths were live again:
  - `training-daily-check.py --host mini --no-notify --print` returned the real state instead of timing out: production last failed on `2026-04-05`, challenger is still `14%`, workflow gate still failing
  - `reconcile-air-mini.sh mini --quiet --no-sync-control-plane` finished clean after reconnecting
  - `sync-codex-mini.sh mini --quiet --no-restart` pushed the current SaneProcess control-plane changes to the Mini
- Live bounded Mini smoke passed end to end on the canonical machine:
  - `mini-train-challengers.sh SaneAI` with `TRAIN_SWEEP_ITERS=2`, `EVAL_SUITES=commentary_workflow,core`, `EVAL_MAX_CASES=6`, `EVAL_MAX_TOKENS=128`, and `SANE_ROOT=~/SaneApps-automation` refreshed the automation root cleanly, trained, evaluated, archived, and cleaned up
  - smoke result was still `0%` workflow-first because all 6 commentary cases returned malformed JSON
- Direct Mini probe of the latest real 50-step SmolLM3 challenger adapter showed the current failure is deeper than the default eval cap:
  - first commentary case still failed at `192` max tokens
  - a direct one-case generation at `512` tokens consumed the full budget, looped `supportingReferences` (`Titus 1:5-9` repeated), and still never closed the JSON object
  - conclusion: the workflow failure is not only the Mini's `128/192` eval budget; the model is degenerating into overlong malformed JSON

### Current State
- The training-lane prep no longer depends on the source tree already exposing `apps/SaneAI`; top-level `SaneAI` can now seed the canonical automation-root layout.
- Mini SSH is currently healthy again after reboot, but the earlier auth stall remains unexplained and may still be machine-state-dependent.
- The remaining blocker is model quality, not infra availability: the Mini lane is operational again, but SaneAI still fails workflow generation by emitting overlong malformed JSON that never closes cleanly.

### Next
- Keep Mini evals serial on the 8 GB host. A mistaken parallel two-case probe on 2026-04-13 immediately reproduced the expected Metal OOM.
- Next SaneAI work should target the malformed-long-output failure directly:
  - add stronger examples that penalize repeated `supportingReferences` loops and reward compact closed JSON
  - consider hard length discipline inside the workflow prompt or training set, because even `512` generation tokens did not rescue the current adapter
- If Mini SSH stalls again, inspect Mini-side `sshd` / account login logs rather than tweaking more local SSH flags.

### SOP: 9/10
- (+) Found and fixed a real automation-root layout bug instead of only adjusting alerts around it.
- (+) Added regression coverage and a temp end-to-end proof for the repo-layout edge case.
- (+) Revalidated the actual SaneAI Mini lane after the reboot instead of stopping at local script checks.
- (-) The first temp integration command used zsh's read-only `status` variable name and had to be rerun.

## Session 95 (2026-04-11)

### Done
- Finished the remaining non-SaneVideo shared-config reconciliation after the `.gitignore` preserved-block rollout.
- Landed the previously-missing shared repo-noise rule for root Swift module residue:
  - `templates/gitignore` now ignores `/Swift-*.swiftmodule`, `/Swift-*.swiftdoc`, and `/Swift-*.abi.json`
  - `scripts/automation/git-sync-safe.sh` now prunes those untracked repo-root artifacts during reconcile
  - `scripts/automation/README.md` now documents the new prune behavior
- Taught `scripts/sync_check.rb` and `templates/swiftlint.yml` to treat `.swiftlint.yml` the same way as `.gitignore`:
  - canonical shared template
  - plus an optional preserved project-specific exclusion block
- Migrated SaneBar's real local SwiftLint exclusions into the preserved block instead of leaving them as permanent drift.
- Ran `sync_check.rb --fix` across the remaining non-SaneVideo repos and synced the outstanding shared files:
  - `SaneBar`: `.claude/settings.json`, `.swiftlint.yml`
  - `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSales`: `.claude/settings.json`
  - `SaneSync`: `.claude/settings.json`, `.claude/rules/*`, and canonical `scripts/sanemaster/*` core modules

### Live Verification
- Air:
  - `ruby scripts/sync_check.rb /Users/sj/SaneApps/apps/SaneBar /Users/sj/SaneApps/apps/SaneClick /Users/sj/SaneApps/apps/SaneClip /Users/sj/SaneApps/apps/SaneHosts /Users/sj/SaneApps/apps/SaneSales /Users/sj/SaneApps/apps/SaneSync` passed with `✅ All projects in sync!`
  - `cd /Users/sj/SaneApps/apps/SaneSync && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd /Users/sj/SaneApps/apps/SaneBar && swiftlint lint --config .swiftlint.yml --quiet` stayed on the same four known warnings only, proving the preserved-block merge did not widen lint scope.
- Mini:
  - `ruby scripts/sync_check.rb ~/SaneApps/apps/SaneBar ~/SaneApps/apps/SaneClick ~/SaneApps/apps/SaneClip ~/SaneApps/apps/SaneHosts ~/SaneApps/apps/SaneSales ~/SaneApps/apps/SaneSync` passed with `✅ All projects in sync!`
  - `cd ~/SaneApps/apps/SaneSync && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd ~/SaneApps/apps/SaneBar && swiftlint lint --config .swiftlint.yml --quiet` matched the same four known warnings only.
  - End-to-end repo-noise prune proof passed after creating fake root `Swift-CODEXTEST.swiftmodule`, `Swift-CODEXTEST.swiftdoc`, and `Swift-CODEXTEST.abi.json` files in `SaneClick`, `SaneSales`, and `SaneProcess`:
    - `./scripts/automation/git-sync-safe.sh --allow-dirty` removed all three files
    - reconcile log showed prune activity for each touched repo

### Current State
- The non-SaneVideo repos are now green under the canonical shared-config check on both Air and Mini.
- Shared repo-noise cleanup and shared ignore templates now agree again for root Swift build residue.
- Shared-template drift is now reduced to real differences instead of byte-for-byte false positives for `.gitignore` or `.swiftlint.yml`.
- SaneBar keeps its intentional local SwiftLint exclusions without losing shared-template alignment.
- SaneVideo was intentionally left out of this finishing pass because the user is working that lane in another chat.

### Next
- If another shared config needs safe repo-local additions, reuse the same preserved-block model instead of adding another byte-for-byte exception.
- Keep SaneVideo lane work isolated to the other session unless the user explicitly pulls it back into this one.

### SOP: 10/10
- (+) Closed the remaining shared-config debt at the tool level instead of accepting permanent drift.
- (+) Verified both local and Mini canonical paths after the final sync.
- (+) Kept the user’s active SaneVideo lane isolated.

## Session 94 (2026-04-10)

### Done
- Taught `scripts/sync_check.rb` to treat `.gitignore` as:
  - a canonical shared template
  - plus an optional preserved project-specific extension block
- Added the canonical project-specific block markers to `templates/gitignore`.
- Migrated known repo-specific ignore rules into that block for:
  - `SaneBar` (`scripts/runtime_smoke.rb`, `.sanemaster/`, `infra`)
  - `SaneClip` (`fastlane/`, `training_data/`)
  - `SaneSales` (`.swiftlint-cache/`)
  - `SaneSync` (`*.pyo`, `*.pyd`, `!Tests/Assets/*.mp4`, `models/`, `training_data/*.jsonl*`)
- Aligned the straightforward repos to the new canonical `.gitignore` shape:
  - `SaneClick`, `SaneHosts`, `SaneVideo`

### Live Verification
- Air:
  - `ruby -c scripts/sync_check.rb` passed.
  - `ruby scripts/sync_check.rb` against `SaneBar`, `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSales`, `SaneSync`, and `SaneVideo` no longer reported `.gitignore` drift.
- Mini:
  - `ruby -c ~/SaneApps/infra/SaneProcess/scripts/sync_check.rb` passed.
  - synced the canonical `SaneProcess/.claude/settings.json` to `~/.claude/settings.json` on the Mini.
  - `ruby scripts/sync_check.rb` against the same app set no longer reported `.gitignore` drift; only the expected remaining settings/rules/sanemaster diffs remained.
  - Disposable fixture proof for `--fix` passed under a disposable `HOME`:
    - seeded a stale `.gitignore` missing `.claude/mcp_doctor_last.json`
    - added `custom-cache/` inside the project-specific block
    - ran `ruby scripts/sync_check.rb --fix <fixture>`
    - shared template content was restored
    - `custom-cache/` remained preserved inside the block

### Current State
- `.gitignore` drift is no longer a false-positive source in `sync_check.rb` for repos that need a few real local additions.
- Mini global `~/.claude/settings.json` is now present and `sync_check` reports it in sync.
- The remaining `sync_check` noise is now the real stuff:
  - missing project `.claude/settings.json`
  - missing rules
  - intentional/custom `sanemaster/*` divergence
  - `SaneBar` local `.swiftlint.yml` / settings hooks differences

### Next
- Decide whether syncing the Mini `~/.claude/settings.json` should be part of normal control-plane bootstrap rather than a one-off repair.
- If more shared config files need safe per-project extensions later, reuse the same “canonical base + preserved local block” model instead of byte-for-byte comparisons.

### SOP: 10/10
- (+) Reduced false-positive drift without weakening the shared-template check.
- (+) Verified both the compare path and the `--fix` merge path.
- (+) Kept the project-specific rules explicit instead of hiding them in ad hoc ordering drift.

## Session 93 (2026-04-10)

### Done
- Hardened shared repo-noise hygiene for generated Swift module residue:
  - added repo-root ignore rules for `Swift-*.swiftmodule`, `Swift-*.swiftdoc`, and `Swift-*.abi.json` to the canonical `templates/gitignore`
  - updated `scripts/automation/git-sync-safe.sh` so it now prunes those repo-root Swift artifacts in addition to existing `.DS_Store` / `*.orig` / `*.rej` cleanup
  - documented the new prune behavior in `scripts/automation/README.md`
- Synced the canonical `.gitignore` update into the straightforward app repos:
  - `SaneClick`, `SaneClip`, `SaneHosts`, `SaneSales`, `SaneSync`, `SaneVideo`
  - preserved repo-specific extra ignore rules in `SaneClip`, `SaneSales`, and `SaneSync` after the template sync

### Live Verification
- Air:
  - `bash -n /Users/sj/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh` passed.
- Mini:
  - `bash -n ~/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh` passed.
  - `SaneClick` no longer showed the stray root `Swift-3ANHSQNT5DBVB.swiftmodule` in `git status`.
  - `SaneVideo` no longer showed the stray root `Swift-3ANHSQNT5DBVB.swiftmodule` in `git status`; only the existing real in-flight code edits remained.
  - End-to-end prune check passed:
    - created fake root files in `SaneClick`, `SaneVideo`, and `SaneProcess`
    - ran `~/SaneApps/infra/SaneProcess/scripts/automation/git-sync-safe.sh --allow-dirty`
    - all fake files were removed
    - log confirmed prune activity for `SaneClick`, `SaneVideo`, and `SaneProcess`

### Current State
- Root-level Swift module cache residue is now treated as first-class repo noise instead of a recurring manual cleanup item.
- The shared ignore template and shared reconcile script now agree on this artifact family.
- Remaining intentional `.gitignore` drift still exists in some repos because `sync_check.rb` currently expects exact template matches and does not model safe project-specific additions.
- `SaneVideo` still has real unrelated tracked edits in progress and still lacks a root `SESSION_HANDOFF.md`; this cleanup did not change that.

### Next
- If `.gitignore` drift keeps recurring, teach `sync_check.rb` to allow a project-specific extension block instead of forcing byte-for-byte equality.
- Consider expanding repo-noise pruning to other repeated generated root artifacts only after proving they are always safe to delete.

### SOP: 10/10
- (+) Fixed the repeat cleanup at the shared-tool level instead of only deleting files once.
- (+) Verified the actual Mini reconcile path with real fake artifacts, not just a static diff.
- (+) Preserved known repo-specific ignore rules instead of flattening them blindly.

## Session 92 (2026-04-10)

### Done
- Repaired the canonical status runner at `scripts/automation/sane-status-crossref.sh`:
  - fixed the broken listing-actions stage that was piping `listing_actions --json` into a heredoc Python reader and crashing with `JSONDecodeError`
  - switched that stage to `listing_actions --json-out <tempfile>` so later sections can run reliably
  - added a new App Store lanes section to the normal `ruby scripts/SaneMaster.rb status` report
  - the App Store section now reads every appstore-enabled `.saneprocess` manifest and surfaces current ASC lane state, including explicit `ACTION: release manually` wording for `PENDING_DEVELOPER_RELEASE`
  - cleaned up GitHub issue/PR section formatting so repo headers print cleanly
- Added regression coverage:
  - `scripts/automation/status_crossref_test.py` now proves the status script reports both listing actions and a `PENDING_DEVELOPER_RELEASE` App Store lane
- Synced the updated status script to the Mini and verified the live canonical status path there.

### Live Verification
- Air:
  - `bash -n scripts/automation/sane-status-crossref.sh` passed.
  - `python3 scripts/automation/status_crossref_test.py` passed `1/1`.
- Mini:
  - `cd ~/SaneApps/infra/SaneProcess && ruby scripts/SaneMaster.rb status` completed successfully.
  - The repaired App Store lane section reported:
    - `SaneClip 2.2.13: macos=2.2.13 (READY_FOR_SALE) | ios=2.2.13 (READY_FOR_SALE)`

### Current State
- The miss on SaneClip iOS `2.2.13` is now addressed at the process/tooling layer:
  - before this fix, the canonical status runner did not surface App Store lane state at all
  - after this fix, a pending manual-release lane would show up directly in `ruby scripts/SaneMaster.rb status`
- By the time the repaired status check was run, the user had already manually released the iOS lane, so live ASC state was `READY_FOR_SALE`, not `PENDING_DEVELOPER_RELEASE`.
- One remaining status-report gap is visible:
  - `SaneVideo` still prints `appstore enabled, but current MARKETING_VERSION could not be determined`
  - that is a version-discovery gap in the status script, not an ASC outage

### Next
- Improve current-version discovery for `SaneVideo` so the App Store lane report covers every enabled app cleanly.
- Decide whether the stale open SaneClip GitHub issue `#7` (`[Feature] Endless history`) should now be closed, since local code/tests indicate the feature is already present.

### SOP: 10/10
- (+) Fixed the broken canonical tool instead of relying on memory or manual checks.
- (+) Added a focused regression test for the exact failure mode and the new App Store lane signal.
- (+) Verified the real `SaneMaster.rb status` path on the Mini after syncing the fix.

## Session 91 (2026-04-10)

### Done
- Upgraded the listing/vendor tracker workbook generator:
  - added a first-sheet `Assistant Handoff` summary with priority order, status counts, close guidance, and direct action rows
  - reformatted `Current Actions` and `Email History` into human-readable column order with widths, frozen headers, and status styling
  - converted visible vendor links into clickable spreadsheet hyperlinks with short labels like `Open link` and `Backup link` instead of exposing full raw tracking URLs in cells
  - collapsed the raw `URLs` history column into a short captured-link count so giant redirect URLs do not dominate the sheet
  - split the XLSX/layout writer into `scripts/automation/listing_actions_workbook.py` so `listing-actions.py` stays under the 500-line file cap
  - added regression coverage for the new workbook layout and for superseding obsolete SaaSworthy invite rows once the portal-active email exists
- Tightened current-action dedupe:
  - `Verify vendor portal invite` for SaaSworthy no longer survives as a separate current row after `Your SaaSworthy Vendor Portal Access Is Now Active`
- Regenerated the live workbook at:
  - `outputs/listing_actions/latest.xlsx`
- Reviewed and then force-resolved the full open listing/vendor email batch after the workbook was updated:
  - resolved IDs: `575, 561, 560, 558, 552, 551, 550, 531, 528, 527, 520, 514, 512, 511, 510, 509, 508`
- Added a dedicated vendor/listing fallback inbox path for StartupSubmit:
  - deployed `sane-email-automation` Worker version `ce06a18e-a9e5-40b2-a471-3b8c6687fc82`
  - created Cloudflare Email Routing rule `29b10654e5854bf584021703698ee882` for `listings@saneapps.com` -> `sane-email-automation`
  - worker now forwards `listings@saneapps.com` mail to `mrsaneapps@gmail.com` while leaving `hi@saneapps.com` out of the listing/setup flow
- Refreshed the workbook copies so the assistant-facing handoff now documents the new fallback address:
  - `outputs/listing_actions/latest.xlsx`
  - `outputs/listing_actions/sanebar_listing_actions_2026-04-10.xlsx`
  - `/Users/sj/Desktop/Vendor List.xlsx`

### Live Verification
- `python3 -m py_compile scripts/automation/listing-actions.py scripts/automation/listing_actions_workbook.py scripts/automation/listing_actions_rules.py scripts/automation/listing_actions_test.py` passed.
- `python3 scripts/automation/listing_actions_test.py` passed `12/12`.
- `ruby scripts/SaneMaster.rb listing_actions --json-out /tmp/listing_actions_final.json` regenerated the workbook cleanly with:
  - `Current actions: 12`
  - `History rows: 22`
  - `post_close_open 0` listing/vendor emails remaining in the JSON payload

### Current State
- The handoff workbook is now ready to email directly to an assistant:
  - first sheet: action queue and closure rules
  - second sheet: full current tracker with resolved inbox status preserved for audit context
  - third sheet: full email history
- Assistant-facing handoff copy is now the desktop Excel file:
  - `/Users/sj/Desktop/Vendor List.xlsx`
- Source export for regeneration remains:
  - `outputs/listing_actions/latest.xlsx`
- All currently open listing/vendor inbox threads that fed this tracker are now resolved.
- The action queue still exists in the workbook even though the inbox is clean; `action_status` still shows what work remains operationally, separate from the email thread status.
- The StartupSubmit fallback path is now:
  - public/business-facing listing address: `listings@saneapps.com`
  - forwarded inbox behind it: `mrsaneapps@gmail.com`
  - password note in the workbook points to the same submissions credentials already on file for `mrsaneapps@gmail.com`

### Next
- Send `/Users/sj/Desktop/Vendor List.xlsx` as the vendor/listing handoff sheet.
- Use the `Assistant Handoff` sheet first; use `Current Actions` only when more detail is needed.
- If the tracker is regenerated again, refresh the desktop Excel copy from `outputs/listing_actions/latest.xlsx` so the assistant-facing file stays current.
- If a new recurring vendor sender appears, add a dedicated rule in `scripts/automation/listing_actions_rules.py` instead of letting the generic heuristic accumulate.

### SOP: 10/10
- (+) Changed the canonical tracker instead of hand-editing a one-off spreadsheet.
- (+) Kept the automation under the file-size rule by splitting workbook helpers cleanly.
- (+) Honored the inbox review gate before resolving the vendor mail batch.

## Session 90 (2026-04-09)

### Done
- Cleared the remaining repo-side validation backlog that was blocking a clean start:
  - `SaneClip/README.md` now names the live macOS direct-download release `2.2.12` instead of a stale `v2.1` "What's New" block.
  - `SaneSales/README.md` now includes an explicit current-release section for `1.2.6`.
- Fixed a real shared-tool bug in `scripts/sanemaster/generation.rb`:
  - `check_docs` was reading `README.md`, `scripts/mini/README.md`, and `scripts/automation/README.md` relative to the caller repo instead of the SaneProcess repo root.
  - App-repo wrapper calls like `./scripts/SaneMaster.rb check_docs` in `SaneClip` and `SaneSales` now work correctly.
- Added regression coverage in `scripts/sanemaster/generation_test.rb` and wired it into the standard SaneProcess verify suite.
- Pushed:
  - `SaneClip` `db8a569` — `Update README for current release`
  - `SaneSales` `60a508d` — `Update README for current release`
  - `SaneProcess` `65936a9` — `Fix shared docs sync from app wrappers`

### Live Verification
- Air:
  - `ruby scripts/sanemaster/generation_test.rb` passed `1/1`.
  - `cd ~/SaneApps/apps/SaneClip && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd ~/SaneApps/apps/SaneSales && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd ~/SaneApps/infra/SaneProcess && ruby scripts/SaneMaster.rb verify` passed on the full Mini-routed suite, including the new generation test.
- Mini:
  - `cd ~/SaneApps/apps/SaneClip && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd ~/SaneApps/apps/SaneSales && ./scripts/SaneMaster.rb check_docs` passed.
  - `cd ~/SaneApps/infra/SaneProcess && ruby scripts/sanemaster/generation_test.rb` passed `1/1`.
  - `ruby scripts/validation_report.rb` now reports no Q10 README drift; the only remaining actionable lines are the five `Q11 HOSTED FILE ACTION` items.
- Cross-machine hygiene:
  - `bash scripts/automation/reconcile-air-mini.sh mini --quiet` finished clean.
  - `bash scripts/automation/git-sync-safe.sh --peer mini` finished clean.
  - Air and Mini canonical repos are `dirty=0`, `behind=0`, `ahead=0`.

### Current State
- Repo-side release/docs debt is cleared.
- The only remaining validation verdict is `NEEDS DASHBOARD SYNC` for Lemon Squeezy hosted files:
  - `SaneBar` hosted file `2.1.36` vs appcast `2.1.39`
  - `SaneClick` hosted file `1.1.1` vs appcast `1.1.4`
  - `SaneClip` hosted file `2.2.10` vs appcast `2.2.12`
  - `SaneHosts` hosted file `1.1.5` vs appcast `1.1.6`
  - `SaneSales` hosted file `1.2.3` vs appcast `1.2.6`
- This is a real customer-facing alternate-download drift, but the current canonical tooling only supports detection and workbook generation. The official Lemon Squeezy Files API is read-only for SaneApps’ use case, so actual file replacement remains a dashboard action, not a Ruby/API automation path.
- Mini now has one remaining stash that should be preserved:
  - `~/SaneApps/infra/SaneProcess` stash `auto-reconcile-20260409-161316-stephans-mac-mini` contains unrelated `scripts/mini/*` work and test changes and was intentionally not dropped.

### Next
- If the hosted-file lane still matters for customer delivery, replace the five stale Lemon Squeezy hosted ZIPs in the dashboard using `outputs/hosted_file_actions/latest.xlsx` as the exact action sheet.
- If the hosted-file lane is no longer meant to be customer-facing, explicitly retire or downgrade that requirement in the validator instead of leaving it as perpetual drift.
- Leave the preserved Mini SaneProcess stash alone until its owner decides whether to keep, reapply, or discard it.

### SOP: 10/10
- (+) Fixed the broken shared tool instead of working around it.
- (+) Added a regression test and proved the exact wrapper path that had been failing.
- (+) Ended with clean Air/Mini sync and a narrowed remaining debt list instead of vague "maybe stale" warnings.

## Session 89 (2026-04-09)

### Done
- Added a canonical Universal Control recovery command to shared tooling:
  - `ruby scripts/SaneMaster.rb universal_control_reset`
  - aliases: `uc_reset`, `ucr`
- Implemented the recovery flow in new module `scripts/sanemaster/universal_control.rb`.
- Documented the standard recovery and escalation path in `DEVELOPMENT.md`.

### Live Verification
- `ruby scripts/sanemaster/universal_control_test.rb` passed `4/4`.
- `ruby scripts/SaneMaster.rb universal_control_reset --status` printed healthy Air + Mini discovery state.
- `ruby scripts/SaneMaster.rb universal_control_reset --dry-run --cleanup-mini` printed the expected reset plan for both Macs, including Mini cleanup steps.

### Current State
- The canonical Air↔Mini Universal Control repair path is now one command instead of ad hoc shell snippets.
- The command resets Handoff/Continuity state on the local Mac and Mini, clears `com.apple.UniversalControl`, restarts the relevant agents, bounces Wi-Fi, and can optionally:
  - hide/clean Mini windows with `--cleanup-mini`
  - restart the Mini with `--reboot-mini`
- The documented escalation order is now:
  1. `ruby scripts/SaneMaster.rb universal_control_reset`
  2. rerun with `--reboot-mini` if still broken
  3. reboot the Air only after the Mini reboot path fails

### Next
- If Universal Control breaks again, use the new `universal_control_reset` command first and record any new blocker if the standard path fails.
- If the recovery path proves stable over multiple incidents, consider surfacing it in a more prominent ops shortcut or shell alias list.

### SOP: 10/10
- (+) Turned a repeat manual recovery into a shared standard command.
- (+) Added a test for the recovery plan instead of leaving it as undocumented shell lore.
- (+) Recorded the operational fix path in both docs and handoff.

## Session 88 (2026-04-09)

### Done
- Repaired the broken SaneVideo verify lane end to end:
  - fixed test-mode source-switch timeout retention in `RecordingEngine+Lifecycle.swift`
  - fixed `RecordingState` task retention so teardown does not keep countdown/start tasks alive
  - made `WhisperKitService.generateCaptions` fail fast on invalid/nonexistent file URLs before model initialization
  - scoped `MagicFixRegressionTests` so single-feature tests stop invoking the full default Magic Fix pipeline
- Repaired false-success parsing in shared tooling:
  - `scripts/sanemaster/verify.rb`
  - `scripts/sanemaster/release.rb`
  - matching guard tests in `verify_guard_test.rb` and `release_guardrail_test.rb`
- Finished the pending validator/doc cleanup:
  - `validation_report.rb` now skips private local `CLAUDE.md` files when checking sister-app completeness
  - added `SaneSales` to the remaining sister-app lists
  - added `SaneHosts` `1.1.6` changelog entry
- Reconciled Air and Mini back to a clean state and dropped the redundant Mini auto-reconcile stashes created during sync.

### Live Verification
- Mini focused verification:
  - SaneVideo AI suite passed after the WhisperKit early-validation fix
  - SaneVideo `MagicFixRegressionTests` passed after scoped options fix
  - `ruby scripts/validation_report_test.rb` passed `4/4`
- Mini full-lane verification:
  - `./scripts/SaneMaster.rb verify --quiet` in `SaneVideo` passed clean on the full suite
  - raw `test_output.txt` had no `** TEST FAILED **`, `** BUILD FAILED **`, or `Source switch timeout after 120s`
  - real `git push origin main` for `SaneVideo` passed through the full pre-push hook and pushed commit `784a881`
- Repo verification via push hooks:
  - `SaneClick` verify passed `96` tests while pushing `4ff2f93`
  - `SaneSync` verify passed `54` tests while pushing `fa24894`
  - `SaneHosts` verify passed `73` tests while pushing `6c00b56`
  - `SaneProcess` targeted validator tests passed before pushing `9e5b4d0`
- Cross-machine hygiene:
  - `reconcile-air-mini.sh mini --quiet` finished clean
  - `git-sync-safe.sh --peer mini` finished clean

### Current State
- Air canonical repos are clean: `dirty=0`, `behind=0`, `ahead=0`.
- Mini canonical repos are clean after reconcile.
- The major false green in shared verify tooling is fixed; explicit failure markers now win over mixed Swift Testing success summaries.
- The biggest remaining process debt is still operational, not code-path breakage:
  - Lemon Squeezy hosted-file dashboard drift for `SaneBar`, `SaneClick`, `SaneClip`, `SaneHosts`, and `SaneSales`
  - legacy `scripts/mini/sync-claude-config.sh` still overlaps with the real Codex-era Mini sync path
  - validation report still surfaces genuine release-readiness gaps in `SaneSync`, `SaneVideo`, and `SaneSales`

### Next
- Decide whether to sync or retire the Lemon Squeezy hosted-file lane, then fix the five current dashboard drift cases or downgrade the rule.
- Collapse the legacy Mini `sync-claude-config.sh` path into the canonical Codex sync flow.
- Address the live validation-report readiness gaps that are still real product work, starting with `SaneSync` and `SaneVideo`.

### SOP: 10/10
- (+) Fixed the broken tool path instead of working around it.
- (+) Proved the SaneVideo repair three ways: focused tests, full Mini verify, and the real pre-push hook path.
- (+) Recorded the new state in Serena memory, the knowledge graph, and this handoff.

## Session 87 (2026-04-09)

### Done
- Ran a morning process/tooling audit before new work.
- Re-verified the canonical tool-health path:
  - `ruby scripts/SaneMaster.rb mcp_watchdog doctor`
  - `/Users/sj/.codex/bin/check-mcps`
  - `ruby scripts/SaneMaster.rb tool_discovery --query "..."`
- Re-ran the Mini validation sweep with `ruby scripts/validation_report.rb` and separated real process debt from validator noise.
- Wrote the audit findings to Serena memory `SaneProcess/morning_process_audit_2026_04_09` and added matching knowledge-graph observations.

### Current State
- Core tool wiring is healthy:
  - Air `check-mcps` passed for `github`, `apple-docs`, `macos-automator`, `memory`, `central-memory`, `nvidia-build`, `serena`, `xcode`, and `openaiDeveloperDocs`.
  - `mcp_watchdog doctor` found no duplicate MCPs, stale sidecars, or watchdog failures.
  - The stale empty `~/.codex/skills/sales` residue from the earlier Codex skill-health warning is gone.
- The biggest real process risk is cross-channel release drift in Lemon Squeezy hosted files:
  - `SaneBar` hosted file `2.1.36` vs appcast `2.1.39`
  - `SaneClick` hosted file `1.1.1` vs appcast `1.1.4`
  - `SaneClip` hosted file `2.2.10` vs appcast `2.2.12`
  - `SaneHosts` hosted file `1.1.5` vs appcast `1.1.6`
  - `SaneSales` hosted file `1.2.3` vs appcast `1.2.6`
- The biggest duplicate-system smell is legacy Mini config sync:
  - the live unattended Codex control-plane path is `scripts/automation/sync-codex-mini.sh`
  - `scripts/mini/sync-claude-config.sh` is now a deprecation wrapper only, not a second live sync lane
- Validation-report noise exists too:
  - Mini/Codex path assumptions for `apple-docs` local path
  - missing `~/.claude/settings.json` in a Codex-only environment
  - missing Mini knowledge-graph file seed
- Config/doc drift is real:
  - multiple `CLAUDE.md` files are missing `SaneSales` in sister-app lists
  - `SaneHosts` changelog is missing `1.1.6`
  - several app `SESSION_HANDOFF.md` and README/version docs are stale
- Fresh-start cleanliness is not perfect yet:
  - local `SaneProcess` has untracked `.claude/mcp_doctor_last.json` after `mcp_watchdog doctor`
  - Mini `SaneBar` has modified `.claude/research-locks.json`
  - Mini `SaneSync` has modified `SaneSync.xcodeproj/.../Package.resolved` adding a remote `SaneUI` pin not present on Air

### Underdocumented Tools To Review
- `scripts/contamination_check.rb`
- `scripts/link_monitor.rb`
- `scripts/scaffold.rb`
- `scripts/automation/website-consistency-check.sh`
- `scripts/mini/mini-license-test.sh`
- `scripts/mini/sync-claude-config.sh`

### Likely Internal-Only
- `scripts/weaken_sparkle.rb`
- `scripts/automation/public-source-build-guard.sh`
- `scripts/qa_drift_checks.rb`

### Next
- Decide whether Lemon Squeezy hosted files remain a supported live customer download lane. If yes, fix the five drift cases immediately. If no, downgrade that validator rule and stop treating archival hosted files as ship blockers.
- Remove or consolidate the legacy `sync-claude-config.sh` path so Mini sync has one canonical config/deploy flow in Codex.
- Clean the doc/config drift: add `SaneSales` to sister-app lists, fix `SaneHosts` changelog/docs, and refresh the stalest handoffs.

### SOP: 10/10
- (+) Audited the actual canonical tooling instead of guessing from docs.
- (+) Recorded the findings in both durable memory and local handoff.
- (+) Distinguished real release/process risk from validator-assumption noise.

## Session 86 (2026-04-09)

### Done
- Added a durable listing/setup tracker flow for SaneBar directory work:
  - canonical command: `ruby scripts/SaneMaster.rb listing_actions`
  - workbook output: `outputs/listing_actions/sanebar_listing_actions_<date>.xlsx`
  - stable path: `outputs/listing_actions/latest.xlsx`
- Extended `listing-actions.py` with `--json-out PATH` so the same run can generate the workbook and feed other automation.
- Tightened `listing_actions_rules.py`:
  - explicit rules still cover known senders like SaaSworthy, SourceForge, Gartner, StartupSubmit, Startup Buffer, SellDigitals, and ConfettiSaaS
  - unknown listing/setup senders now surface through a generic heuristic path instead of being silently missed
  - heuristic false positives were trimmed after live validation (Discord DMCA, GitHub support DMCA, and Rankup customer mail no longer pollute the workbook)
- Wired the tracker into the normal ops surfaces:
  - `scripts/automation/morning-report.sh` now regenerates the workbook nightly and includes a `Listing Actions` section with the workbook path plus the live `Needs action / Optional / Monitor` counts
  - `scripts/automation/sane-status-crossref.sh` now includes a `Listing actions` lane before GitHub issues/PRs
- Updated `DEVELOPMENT.md` and `scripts/automation/README.md` so the listing tracker is documented as SOP instead of a one-off spreadsheet workflow.

### Live Verification
- Air:
  - `python3 -m py_compile scripts/automation/listing-actions.py scripts/automation/listing_actions_rules.py scripts/automation/listing_actions_test.py` passed.
  - `python3 scripts/automation/listing_actions_test.py` passed `9/9`.
  - `ruby scripts/SaneMaster.rb listing_actions --json-out /tmp/listing_actions_local.json` generated the workbook and JSON successfully.
  - `outputs/morning_report.md` now contains the live `## Listing Actions` section with workbook path `outputs/listing_actions/latest.xlsx`, `Current actions: 13`, and `Needs action: 7`.
- Mini:
  - `python3 scripts/automation/listing_actions_test.py` passed `9/9`.
  - `ruby scripts/SaneMaster.rb listing_actions --json-out /tmp/listing_actions_mini.json` generated the same final workbook counts as Air: `Current actions: 13`, `History rows: 20`.
  - Final current-action split on both machines:
    - `Needs action`: 7
    - `Optional`: 5
    - `Monitor`: 1
  - Current `Needs action` rows are Gartner Digital Markets, SaaSworthy (2), SourceForge (2), and StartupSubmit (2).

### Current State
- The listing workbook is now the source of truth for owner-side setup work instead of ad hoc spreadsheets.
- New listing/setup emails should now appear in one of two ways:
  - explicit dedicated rule for known recurring senders
  - generic heuristic row with a note saying to promote the sender to a dedicated rule if it recurs
- Final current actions in `outputs/listing_actions/latest.xlsx`:
  - Needs action:
    - Gartner Digital Markets — activate account and complete profile
    - SaaSworthy — verify invite
    - SaaSworthy — complete vendor portal profile
    - SourceForge — create vendor account
    - SourceForge — claim the page
    - StartupSubmit — review master sheet deliverables
    - StartupSubmit — decide whether they must redo manual setups
  - Optional:
    - PromoteBusinessDirectory featured review upsell
    - SaaSworthy premium upsell
    - SellDigitals account/assets
    - Startup Buffer expedite
    - Startup Stash paid tier
  - Monitor:
    - ConfettiSaaS queue

### Open GitHub Issues
- `SaneBar #129`
- `SaneBar #133`
- `SaneClip #7`

### Feature Requests
- `SaneClip #7` remains implemented on `main` and waiting on release.

### Next
- If a new listing/setup sender shows up in inbox and lands via the generic heuristic, promote it into an explicit rule in `scripts/automation/listing_actions_rules.py` once it proves recurring.
- Use `outputs/listing_actions/latest.xlsx` as the handoff file for any user-side listing setup work instead of creating a new manual tracker.
- If the user wants the workbook for other apps later, expand the same tracker rather than creating a second spreadsheet flow.

### SOP: 10/10
- (+) Replaced a manual spreadsheet habit with a canonical shared tool and workbook.
- (+) Wired the tracker into the normal nightly report path so new listing emails are collected automatically.
- (+) Caught and removed live heuristic false positives before calling the SOP finished.

## Session 85 (2026-04-08)

### Done
- Added and verified audited duplicate-purchase refund tooling in `scripts/automation/ls-sales.py` and `scripts/SaneMaster.rb`:
  - `sales --find-customer-orders --email ... --name ... --product ...`
  - `sales --license-status KEY`
  - `sales --disable-license-key KEY`
  - `sales --refund-duplicate-license-key DUP_KEY --keep-license-key KEEP_KEY --refund-order-number N --proof-file PATH --approval-note PATH`
- Documented the duplicate-purchase refund rule and the canonical command path in `DEVELOPMENT.md`.
- Fixed the Mini Ruby compatibility break in `scripts/automation/tool_discovery_receipt.rb` by replacing `filter_map` with `each_with_object`.
- Tightened customer-order lookup ranking so repeated same-product purchases for the same customer outrank one-off fuzzy name matches.

### Live Verification
- Local:
  - `python3 -m py_compile scripts/automation/ls-sales.py` passed.
  - `python3 scripts/automation/ls_sales_test.py` passed `7/7`.
- Mini:
  - `python3 scripts/automation/ls_sales_test.py` passed `7/7`.
  - `ruby scripts/SaneMaster.rb help sales` showed the new duplicate-refund command surface.
  - `ruby scripts/SaneMaster.rb sales --find-customer-orders --email reed@reed-a.ca --name Reed --product SaneBar` ranked the real Reed duplicate pair (`270691527`, `270691528`) above the unrelated fuzzy `Rene` hit.
  - `ruby scripts/SaneMaster.rb sales --license-status 766800DD-3877-4EAA-938F-D60D42FFA0D7` showed the kept Reed key is live/valid.
  - `ruby scripts/SaneMaster.rb sales --license-status D1918A18-BCC3-4DA2-AC6B-C67CC912CA5C` showed the refunded Reed key is disabled.
  - `SANE_REFUND_APPROVED=1 ruby scripts/SaneMaster.rb sales --refund-duplicate-license-key ...` reran cleanly against the already-refunded Reed case and regenerated an audit proof file, proving the flow is idempotent.

### Current State
- Reed duplicate-purchase facts:
  - support email: `reed@reed-a.ca`
  - purchase email in Lemon Squeezy: `raed-a@outlook.com`
  - kept SaneBar order/key: `270691527` / `766800DD-3877-4EAA-938F-D60D42FFA0D7`
  - refunded SaneBar order/key: `270691528` / `D1918A18-BCC3-4DA2-AC6B-C67CC912CA5C`
- Refund policy exception is now explicit for proven duplicate purchases: refund the duplicate, disable that key, keep the surviving key active, and tell the customer exactly which key is live.
- Customer reply still needs the normal explicit draft approval before send.

### Open GitHub Issues
- `SaneBar #129`
- `SaneBar #133`
- `SaneClip #7`

### Feature Requests
- No new feature requests in this pass.

### Next
- If another refund/duplicate-purchase thread comes in, run the new `sales --find-customer-orders` lookup first with the support email plus any visible customer name.
- For cross-email cases, verify both keys with `sales --license-status`, then use the audited duplicate-refund path instead of manual API calls.
- Before sending the customer reply, say explicitly which order was refunded, that the refunded key is disabled and will not work, and which remaining key is the live working key.

### SOP: 10/10
- (+) Fixed and verified the shared tool instead of handling Reed as a one-off manual exception.
- (+) Proved the new flow locally and on Mini, including the real already-refunded idempotence case.
- (+) Recorded the new workflow in docs, Serena memory, and the knowledge graph immediately.

## Session 84 (2026-04-07)

### Done
- Fixed the SaneClip website manual recovery path end to end:
  - homepage/free-download CTAs in `docs/index.html` now route to `/download` instead of directly to the ZIP
  - added `docs/download.html` with explicit manual install guidance: do not unzip inside `/Applications`, open from `Downloads`, drag `SaneClip.app` to `Applications`, choose `Replace`, and delete `SaneClip 2.app` if a duplicate already exists
  - `download.html` dynamically fetches `/appcast.xml` so the manual download button stays on the latest direct-build ZIP
- Added guard tests in `apps/SaneClip/Tests/SaneClipTests.swift` for:
  - homepage CTAs routing through `/download`
  - duplicate-app warning and `Replace` copy on `download.html`
- Updated `scripts/release.sh` so website version rewrites now touch both `index.html` and `download.html`.
- Fixed routed Mini verify cleanup in `scripts/SaneMaster.rb`:
  - successful non-release routed commands now normalize the Mini repo, SaneProcess repo, and SaneUI repo back to `origin/<branch>` when the corresponding local repo is clean and already matches origin
  - regression coverage added in `scripts/sanemaster/release_route_test.rb`
- Pushed:
  - `SaneClip` `0189a7b` (`Add manual download guide for website recovery`)
  - `SaneProcess` `7a14727` (`Update website version rewrites for download pages`)
  - `SaneProcess` `dd3f70c` (`Clean mini repos after routed verifies`)
- Live verification:
  - `./scripts/SaneMaster.rb verify --quiet` in `SaneClip` passed `120` tests on Mini during push
  - `bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project ~/SaneApps/apps/SaneClip --website-only` succeeded on Mini and deployed `https://saneclip.com/download`
  - `ruby -c scripts/SaneMaster.rb` passed
  - `ruby scripts/sanemaster/release_route_test.rb` passed `9/9`
  - a second real routed `./scripts/SaneMaster.rb verify --quiet` from Air passed `120` tests and left Mini `SaneClip` / `SaneProcess` clean at `0189a7b` / `dd3f70c`
  - `git-sync-safe.sh --peer mini` finished clean

### Open GitHub Issues
- `SaneBar #129`
- `SaneBar #133`
- `SaneClip #3`
- `SaneClip #7`

### Research / Notes
- New Serena memories written:
  - `SaneClip/manual_download_guide_live_2026_04_07`
  - `SaneProcess/mini_route_cleanup_after_verify_2026_04_07`
- The public `download` path is now the safe manual recovery lane for old direct-download builds that cannot self-update cleanly.
- The routed-verify cleanup fix only normalizes Mini repos when the local repo is clean and already matched to origin, so dirty local work-in-progress still stays intact on Mini during active development.

### Feature Requests
- `SaneClip #7` asks for endless history.

### Next
- If a future session revisits the manual recovery UX, the remaining improvement beyond the new `/download` page would be shipping a DMG/manual installer path instead of a ZIP.
- If Mini repos ever come back dirty after a routed verify, re-run `./scripts/SaneMaster.rb verify --quiet` from the clean local repo first; that now doubles as the proof path for the normalization fix.

### SOP: 10/10
- (+) Fixed the live customer-facing path, not just the repo copy.
- (+) Added tests and a shared tool fix so the same failure does not keep coming back.
- (+) Finished with clean Air/Mini sync state and live public verification.

## Session 83 (2026-04-07)

### Done
- Cleaned duplicate SaneClip installs on both machines:
  - Air now has one canonical `/Applications/SaneClip.app` at `2.2.12 (2212)`; removed `/Applications/SaneClip 2.app` and `~/Applications/SaneClip.app`.
  - Mini now has one canonical `/Applications/SaneClip.app` at `2.2.12 (2212)`; removed `~/Applications/SaneClip.app`.
- Normalized `SaneClip.xcodeproj/.../Package.resolved` to include the tracked `SaneUI` package pin and added missing ignore coverage for `.claude/research-locks.json` plus `.claude/sop-verify-state.json` in `SaneClip/.gitignore`.
- Added a shared verify guard in `scripts/sanemaster/verify.rb` so `verify` now fails if it introduces new git dirt relative to its starting snapshot. Added regression coverage in `scripts/sanemaster/verify_guard_test.rb` and updated `templates/gitignore` to ignore `.claude/research-locks.json`.
- Pushed:
  - `SaneClip` `0a66ab2` (`Normalize SaneClip package resolution`)
  - `SaneProcess` `3e11718` (`Guard verify against repo drift`)
  - `SaneProcess` `683d431` (`Harden verify repo snapshot checks`)
- Verified on Mini:
  - `ruby scripts/sanemaster/verify_guard_test.rb` passed `4/4`
  - `ruby scripts/sanemaster/release_guardrail_test.rb` passed `27/27`
  - `ruby scripts/SaneMaster.rb check_docs` passed
  - `./scripts/SaneMaster.rb verify --quiet` in `SaneClip` passed `118` tests after the cleanup/sync
  - `git-sync-safe.sh --peer mini` finished clean

### Current State
- Air and Mini now each have exactly one installed SaneClip app bundle in `/Applications` at `2.2.12 (2212)`.
- Air and Mini canonical repos are clean and aligned (`dirty=0`, `behind=0`, `ahead=0`).
- The legacy updater recovery path is fixed at the appcast level for pre-2208 builds, and current direct-download builds are on the newer updater path.
- The website `download` page still serves ZIP links for manual recovery, so extracting directly inside `/Applications` can still create `SaneClip 2.app` if an older app is already there. No website/download-surface change was made in this pass.

### Next
- If you want to eliminate the remaining duplicate-app risk for manual recovery installs, change the website/manual recovery delivery away from ZIP-in-place behavior (for example a DMG-based path or explicit replace instructions).
- If this comes up again, cleanup target is always one `/Applications/SaneClip.app` and no extra `~/Applications/SaneClip.app` copy unless a deliberate dev build is wanted.

### SOP: 10/10
- (+) Cleaned the actual user machines, not just the repo.
- (+) Added a shared verify guard so generated repo dirt fails fast on future runs.
- (+) Finished with Mini verification and clean Air/Mini sync state.

# Session Handoff (PRIVATE / LOCAL ONLY)

This file is private to your local environment and is intentionally not tracked in git.
Public guidance lives in `CLAUDE_PUBLIC.md`.

> **Project Docs:** [CLAUDE.md](CLAUDE.md) · [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SESSION_HANDOFF](SESSION_HANDOFF.md)

## Session 81 (2026-04-06)

## Session 82 (2026-04-06)

### Done
- Fixed and verified the recurring settings-navigation drift across the active macOS app set:
  - `SaneHosts`: unified dock/menu bar settings routing behind `SettingsActionStorage` in `SaneHostsApp.swift`.
  - `SaneSales`: kept the earlier `SettingsTabNavigationStorage` dock/menu fix and removed the remaining in-app timer-based settings hops from dashboard/orders/products/settings routes.
- Added source guards:
  - `SaneHostsPackage/Tests/SaneHostsFeatureTests/NavigationSourceTests.swift`
  - expanded `SaneSales/Tests/SettingsSourceTests.swift` to ban timer-based follow-up route drift in the in-app settings path too.
- Mini verification completed:
  - `SaneHosts`: `./scripts/SaneMaster.rb verify --quiet` passed, `./scripts/SaneMaster.rb test_mode` launched, and the live Mini status-menu `Settings...` path reopened `SaneHosts Settings` from a zero-window state.
  - `SaneSales`: `xcodebuild test -scheme SaneSales -destination "platform=macOS,arch=arm64" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""` passed 52 tests after the final route cleanup.
  - `SaneClick`: `./scripts/SaneMaster.rb verify --quiet` passed 96 tests.
  - `SaneClip`: `./scripts/SaneMaster.rb verify --quiet` passed 116 tests.
  - `SaneBar`: `./scripts/SaneMaster.rb verify --quiet` passed 1057 tests.
- Shipped the app fixes to GitHub:
  - `SaneHosts` commit `d6c2268` pushed to `main`
  - `SaneSales` commit `12d921a` pushed to `main`
- Repaired and completed the SaneClick App Store resubmission on the Mini:
  - `./scripts/SaneMaster.rb appstore_preflight` passed.
  - `appstore_submit.rb --withdraw-version 1.1.4` cleared the stale unresolved review submission.
  - `appstore_submit.rb --sync-metadata-only` refreshed the live metadata.
  - `appstore_submit.rb --skip-upload --skip-screenshots --build-number 1104` reattached the already valid build and successfully resubmitted.
  - Final ASC state: macOS `1.1.4` is `WAITING_FOR_REVIEW` with submission `7ac956a6-7659-4128-9cb4-b051cc34ad64`.
- Workspace cleanup:
  - cleared stray `.claude/sop-verify-state.json`, `.claude/research-locks.json`, Mini lockfile churn, and tracked `.serena/project.yml` drift that was only local Serena metadata.
  - `bash scripts/automation/git-sync-safe.sh --peer mini` finished clean.

### Open GitHub Issues
- `SaneBar #129`
- `SaneBar #133`
- `SaneClip #3`

### Research / Notes
- New durable Serena memories written:
  - `sanehosts/settings_action_unified_and_miniverify_2026_04_06`
  - `sanesales/settings_navigation_timer_cleanup_2026_04_06`
  - `saneclick/appstore_1_1_4_resubmitted_2026_04_06_night`
- One runtime caveat from this pass: Mini Dock-context-menu automation is still less reliable than native status-menu or app-menu automation because the Dock does not expose a normal `menu 1` tree after `AXShowMenu`. For `SaneHosts`, the live zero-window proof came from the status-menu `Settings...` path; Dock screenshots taken through `mini-gui-run.sh` only showed the generic Dock context menu under the unsigned fallback build.

### Feature Requests
- No new product feature requests were introduced in this pass.

### Next
- If the next session needs more Dock-specific proof on Mini, prefer a signed GUI-launched build and visual confirmation instead of headless AX-only Dock scripting.
- Re-check SaneClick ASC after Apple picks up the resubmission to confirm it stays in `WAITING_FOR_REVIEW` or moves forward normally.

### SOP: 9/10
- (+) Fixed the actual recurring route pattern instead of only patching the first broken click.
- (+) Verified across source guards, test suites, live Mini launches, and the real ASC resubmission flow.
- (+) Left Air and Mini clean again instead of ending with dirty repos and temp artifacts.
- (-) Mini Dock-menu automation is still weaker than status-menu/app-menu automation, so that one proof path remains more fragile than I want.

### Done
- Hardened skill enforcement so matched workflows stop being advisory:
  - `saneprompt.rb` now detects runner-backed `status`, `verify`, `ship`, and `check_inbox` in addition to the existing `docs_audit`, `evolve`, and `outreach` paths.
  - `sanetools.rb` / `sanetools_checks.rb` now block freehand `Edit`, `Bash`, and `Task` attempts when a required skill workflow is not yet satisfied.
  - runner-backed skills now accept only the canonical commands:
    - `status` → `bash scripts/automation/sane-status-crossref.sh`
    - `evolve` → `ruby scripts/SaneMaster.rb tool_discovery --query "..."`
    - `verify` → `ruby scripts/SaneMaster.rb verify`
    - `ship` → `ruby scripts/SaneMaster.rb release_preflight`
    - `check_inbox` → `~/SaneApps/infra/scripts/check-inbox.sh check`
- Added live skill-state tracking improvements in `sanetrack.rb` so the shared state now records real satisfaction instead of just “runner used once”.
- Reworked `sanestop.rb` SOP notes so `outputs/sop_ratings.csv` now writes structured notes like `blocks=...;skill=...;verify=...;handoff=...;edits=...` instead of fake `clean session`/`N violations` placeholders.
- Extended `validation_report.rb` so Q0 now checks the skill-workflow contract in `AGENTS.md` and `templates/AGENTS_TEMPLATE.md`, and Q3 now warns when SOP notes are still generic or not structured enough.
- Updated `AGENTS.md`, `templates/AGENTS_TEMPLATE.md`, and `README.md` to say matched skills are mandatory workflows, not freehand guidance.
- Updated the local Codex `status` skill to point at the SaneProcess canonical runner.
- Tightened `check-inbox.sh` email-send enforcement so showing a draft is now a real tracked step instead of a soft reminder:
  - new `present-draft` / `present-batch` commands record that the exact draft or manifest was shown to the user
  - `approve` / `approve-batch` now require `--user-approval "<quote>"` and record the approval quote, not just a body hash
  - single and batch approvals now block until the exact draft was first marked as shown to the user
  - added `spam` / `spam-batch` commands so generic security-bounty fishing mail can be marked as spam instead of wasting reply time

### Current State
- Air and Mini both have the same hook/doc changes copied into `~/SaneApps/infra/SaneProcess`.
- The old hash-only email approval flow is obsolete. Current required path is: show draft -> `present-draft` -> wait for explicit user approval -> `approve ... --user-approval "<quote>"` -> send in a separate command.
- Mini hook self-tests are green:
  - `ruby scripts/hooks/sanetools.rb --self-test` → `47/47`
  - `ruby scripts/hooks/sanestop.rb --self-test` → `30/30`
- Full `validation_report.rb` was started on both Air and Mini after the patch; if a future session wants the final report text, rerun it fresh and wait for completion because it is a long sweep.
- Repo is still dirty overall from unrelated older SaneProcess work; this session changed only the skill-enforcement, scoring, and doc surfaces listed above.

### Next
- Commit only the skill-enforcement / structured-SOP / doc-contract files once you are ready to bundle this SaneProcess pass cleanly.
- Re-run `ruby scripts/validation_report.rb` from the Mini and capture the final output after the long sweep completes.
- If the user wants strict parity beyond SaneProcess, mirror the same “mandatory workflow” pattern into any remaining user-scope Codex skills that still read like prose only.

### SOP: 9/10
- (+) Enforcement now lives in the shared hook path instead of relying on memory or prompt discipline.
- (+) The self-rating notes now carry real workflow signals that can trend over time.
- (-) The status skill doc update lives in `~/.codex/skills/` and is local state, not repo-tracked.

## Session 80 (2026-03-30)

### Done
- Investigated a fresh-session Codex skill-load miss where `status` was present on disk and in `~/.codex/SKILLS_REGISTRY.md` but absent from the session skill list.
- Found the key filesystem anomaly: `~/.codex/skills/status/SKILL.md` was the only symlinked Codex skill entrypoint, pointing back to `~/.claude/skills/status/SKILL.md`.
- Replaced the symlink with a real local `~/.codex/skills/status/SKILL.md` and expanded the trigger line to include plain `status` and `check status`.
- Recorded the regression in Serena memory as `SaneProcess/codex_status_skill_symlink_loader_regression_2026-03-30`.
- Hardened `scripts/validation_report.rb` so Q0 now checks Codex local skill health: symlinked `SKILL.md` entrypoints, unreadable/non-regular files, missing frontmatter, and Codex registry drift.
- Updated `scripts/hooks/session_start.rb` and `scripts/hooks/sanetools_startup.rb` to point startup guidance at the active client registry (`~/.codex/SKILLS_REGISTRY.md` in Codex) instead of hardcoded Claude-only paths.

### Current State
- `~/.codex/skills/status/SKILL.md` is now a normal file, not a symlink.
- Root-cause is still labeled as a strong-evidence loader hypothesis because Codex does not expose a public local skill-loader trace here.
- A brand-new Codex session is still required to verify the skill appears in the injected `Available skills` list.
- Local guardrail check now passes for real Codex skill entrypoints; the only remaining Codex-skill warning is a stale empty `~/.codex/skills/sales/` directory with no `SKILL.md`.

### Next
- Start one fresh Codex session and send `status` or `check status`.
- If `status` still does not appear in the next session's skill list, inspect Codex app logs or open a minimal repro against the desktop app because the bug would then be above the filesystem layer.
- Optionally remove or repurpose the stale empty `~/.codex/skills/sales/` directory so validation stays clean.

### SOP: 9/10
- (+) Fixed the likely loader blocker instead of just changing prompt wording.
- (+) Recorded the regression in both memory and handoff for future sessions.
- (-) No app-side loader trace was available, so final verification still depends on one fresh session.

## Session 79 (2026-03-28)

### Done
- Added a shared SaneUI drift guard in `scripts/sanemaster/saneui_guard.rb`.
  - blocks known bad settings/About/license/update patterns during `./scripts/SaneMaster.rb verify`
  - exposes a direct sweep command: `./scripts/SaneMaster.rb saneui_guard [path]`
  - feeds the same findings into `structural` / `compliance`
- Added regression coverage for the guard in `scripts/sanemaster/saneui_guard_test.rb`.
- Hardened prompt-time guidance in `scripts/hooks/saneprompt.rb` so settings/UI tasks now inject the SaneUI source-of-truth reminder automatically.
- Updated durable instructions and templates so new work points back to shared SaneUI:
  - `/Users/sj/AGENTS.md`
  - `AGENTS.md`
  - `templates/AGENTS_TEMPLATE.md`
  - `templates/docs/SANEAPPS_DESIGN_LANGUAGE.md`
  - `README.md`
- Swept current app repos with the new guard. Current blockers found:
  - `SaneHosts`: local `SaneSparkleRow` clone
  - `SaneBar`: `mailto:` in About settings, plus warning-level custom About/license panes
  - `SaneClick`: local `SaneSparkleRow` clone and bordered updater button
  - `SaneClip`: local `SaneSparkleRow`, bordered updater button, `mailto:` in macOS + iOS settings
  - `SaneSales`: `mailto:` in iOS settings, local `SaneSparkleRow`, bordered updater button
  - `SaneSync`: warning-level custom license/settings shape still outside shared SaneUI

### Current State
- `ruby scripts/sanemaster/saneui_guard_test.rb` passes.
- `ruby scripts/hooks/saneprompt.rb --self-test` passes (`179/179`).
- `ruby scripts/SaneMaster.rb saneui_guard <app>` now gives a fast, deterministic SaneUI drift report.
- `ruby scripts/qa.rb` still fails for pre-existing file-size limits in hook files; after this pass it no longer fails on stale self-test counts.

### Next
- Replace the remaining app-local `SaneSparkleRow` copies in app repos with the shared SaneUI version.
- Migrate SaneBar, SaneClip, SaneSales, and SaneSync settings/About/license panes onto shared SaneUI surfaces so the new guard passes cleanly.
- If you want even stricter enforcement later, promote the current warning-only checks (custom About/license/settings shell) into blocking checks after the sweep is done.

### SOP: 9/10
- (+) Added real enforcement instead of another passive doc note.
- (+) Recorded the current drift list so the next cleanup pass starts from facts, not rediscovery.
- (-) `scripts/qa.rb` still has unrelated hard-limit failures in old hook files that I did not clean up in this pass.

## Session 78 (2026-03-27)

### Done
- Reconciled the full SaneProcess repo state across Air and Mini instead of leaving a half-pushed / half-dirty split:
  - commit `c913a89` pushed to `main`: `Unify SaneProcess for Claude and Codex`
  - commit `5c64306` pushed to `main`: `Tighten mini training and release guardrails`
- Pulled the primary Mini-only infra changes back through Air so the canonical repo history now includes them:
  - routed release workspace pruning in `scripts/SaneMaster.rb`
  - expanded cleanup coverage in `scripts/mini/mini-memory-guard.sh`
  - canonical installer path fix in `scripts/mini/mini-install-memory-guard.sh`
  - release-route regression coverage in `scripts/sanemaster/release_route_test.rb`
- Verified the second reconciliation commit with targeted checks:
  - `ruby scripts/mini/mini_memory_guard_test.rb`
  - `ruby scripts/sanemaster/release_route_test.rb`
  - `ruby scripts/appstore_submit_guardrail_test.rb`
  - `bash -n` for release + Mini shell scripts
  - `ruby -c scripts/SaneMaster.rb`
  - `ruby -c scripts/appstore_submit.rb`
  - `ruby -c scripts/sanemaster/release.rb`
  - `ruby scripts/SaneMaster.rb check_docs`
- Cleaned repo noise for tomorrow:
  - removed the local `scripts/mini/__pycache__` artifact on Air and Mini
  - added local-only excludes for `scripts/mini/__pycache__/` and `.claude/settings.local.json`
- Reconciled the Mini primary checkout safely:
  - created backup branch `backup/reconcile-2026-03-27`
  - advanced `~/SaneApps/infra/SaneProcess` to `origin/main` with a non-hard reset after confirming tracked contents already matched
  - refreshed the clean Mini mirror at `~/SaneApps/infra/SaneProcess-main-sync`

### Current State
- Air primary repo: `main` at `5c64306`, clean.
- Mini primary repo: `main` at `5c64306`, clean.
- Mini clean mirror: `~/SaneApps/infra/SaneProcess-main-sync` at `5c64306`, clean.
- The cross-agent docs/setup pass and the Mini/release guardrail pass are both fully in remote history now.
- Local-only Mini config remains intentionally local-only via `.git/info/exclude`.

### Next
- Tomorrow can start from either Air or Mini without repo-state cleanup first.
- If you want the same Air/Mini reconciliation pattern for app repos, use this SaneProcess pass as the template: verify overlap, land one canonical commit on Air, then reconcile Mini non-destructively.

### SOP: 10/10
- (+) Turned a split-brain repo state into one clean, verified branch on both machines.
- (+) Preserved local-only Mini config and made a backup branch before advancing the Mini primary checkout.
- (+) Finished with clean primary checkouts instead of a “pushed but still dirty” claim.

## Session 77 (2026-03-27)

### Done
- Repositioned SaneProcess from Claude-only framing to a shared cross-agent model:
  - `AGENTS.md` is now the shared repo contract
  - Claude hooks stay as the Claude-specific adapter
  - Codex is documented around `AGENTS.md`, `.agents/skills`, MCP, and shared shell/script guardrails
- Updated the main durable docs to match that model:
  - `README.md`
  - `ARCHITECTURE.md`
  - `DEVELOPMENT.md`
  - `CONTRIBUTING.md`
  - `SECURITY.md`
  - `docs/SaneProcess.md`
  - `CLAUDE_PUBLIC.md`
  - `scripts/hooks/README.md`
- Updated project setup paths so new repos no longer install a Claude-only footprint:
  - added `templates/AGENTS_TEMPLATE.md`
  - `scripts/init.sh` now detects both `claude` and `codex`
  - `scripts/init.sh` now seeds `AGENTS.md` when missing
  - repo skills are now mirrored into both `.claude/skills/` and `.agents/skills/`
  - MCP setup guidance now prints both Claude and Codex commands
- Updated the major starter templates so new projects carry the shared model forward:
  - `templates/NEW_PROJECT_TEMPLATE.md`
  - `templates/docs/DEVELOPMENT_ENVIRONMENT.md`
  - `templates/CLAUDE_TEMPLATE.md`
  - `templates/FULL_PROJECT_BOOTSTRAP.md`
- Updated the public GitHub repo description to match the new positioning.

### Current State
- The stable cross-agent contract is now explicit:
  - shared repo instructions in `AGENTS.md`
  - Claude-native enforcement in `.claude/settings.json`
  - Codex-native skill discovery in `.agents/skills`
  - shared runtime guardrails for critical paths like email safety
- `scripts/init.sh` parses cleanly with `bash -n`.
- `ruby scripts/SaneMaster.rb check_docs` passed after the doc/template changes.
- Important product decision captured in memory:
  - do not present experimental Codex `features.codex_hooks` as the main path yet
  - keep the stable path on `AGENTS.md`, repo skills, MCP, and shared guards
- Worktree note:
  - there were already unrelated local changes in app-store/release and Mini-training files before this pass
  - this pass intentionally only touched cross-agent docs/templates/setup plus `SESSION_HANDOFF.md`

### Next
- Decide whether to add a project-scoped `.codex/config.toml` example or keep Codex MCP/config guidance user-scoped only for now.
- If any other template still teaches a Claude-only setup path, update it in the same shared-contract style instead of adding more one-off notes.
- If downstream SaneApps repos are initialized from older templates, plan a cleanup pass so they get `AGENTS.md` plus `.agents/skills/`.

### SOP: 10/10
- (+) Fixed the real packaging problem instead of just adding another Codex note on top of Claude-first docs.
- (+) Kept the stable contract honest: shared instructions and guards first, client adapters second.
- (+) Verified with `bash -n scripts/init.sh` and `ruby scripts/SaneMaster.rb check_docs`.

## Session 76 (2026-03-27)

### Done
- Hardened Mini training so bad nightlies fail earlier instead of wasting the run:
  - `scripts/mini/mini-train.sh` now has a dataset regression guard that compares current train/valid counts to the latest successful run for that lane and fails if the corpus shrank too far.
  - This was aimed directly at the silent SaneAI regression from `2528 / 175` back to `1378 / 146`.
- Added a real daily visibility path on the MacBook Air:
  - `scripts/mini/training-daily-check.py` now pulls Mini metrics/readiness/current alerts over SSH, writes `outputs/training_daily_check.md`, and can raise a local macOS notification.
  - `scripts/mini/install-training-daily-check-agent.sh` installs `~/Library/LaunchAgents/com.saneapps.training-daily-check.plist` for 9:15 AM daily checks.
- Deployed the patched `mini-train.sh` to the Mini and verified the corrected training root with a live smoke challenger run:
  - smoke report used `~/SaneApps-automation`
  - SaneAI corpus was back at `2528 train / 175 valid`
  - smoke archived successfully under `~/SaneApps/outputs/automation-smoke/dataset-guard`

### Current State
- Tonight’s scheduled Mini challenger lane still runs at 1:00 AM via `com.saneapps.training-challengers`.
- Sunday’s weekly SaneAI lane still runs at 1:00 AM via `com.saneapps.training-weekly`, and that LaunchAgent still has `READINESS_TARGET_APP=SaneSync`.
- A real manual SaneSync production baseline run was started on the Mini on 2026-03-27 at about 15:37 EDT:
  - command path: `mini-train.sh SaneSync`
  - root: `~/SaneApps-automation`
  - report path: `~/SaneApps/outputs/training_report_SaneSync.md`
  - as of the last check it had clean git state, `1112 / 122` examples, and was in the first 1000-iteration sweep
- The local daily training checker LaunchAgent is installed and loaded on the Air:
  - `launchctl print gui/$(id -u)/com.saneapps.training-daily-check`
  - schedule: 9:15 AM local time
- Mini training LaunchAgents were reinstalled on 2026-03-27 with explicit dataset-guard thresholds:
  - `TRAIN_EXAMPLE_DROP_MAX_PCT=20`
  - `VALID_EXAMPLE_DROP_MAX_PCT=20`
- Current local daily-check output still reflects the old March 27 / March 22 production history because no full scheduled run has happened yet since the latest fixes:
  - `outputs/training_daily_check.md` still shows the stale `1378 / 146` run and readiness `missing_target_baseline`
  - tonight’s scheduled run is what should produce the first fresh post-fix history row
- Worktree note:
  - this repo already had unrelated local modifications in `DEVELOPMENT.md`, `scripts/appstore_submit.rb`, `scripts/appstore_submit_guardrail_test.rb`, `scripts/release.sh`, `scripts/sanemaster/release.rb`, and `templates/RELEASE_SOP.md`
  - this pass intentionally only touched the Mini training/monitoring files plus `ARCHITECTURE.md` and `scripts/mini/README.md`

### Next
- Check whether the manual SaneSync production run finished successfully and wrote the first `training_metrics_workflow_v1.tsv` row for SaneSync under `~/SaneApps/outputs/history/SaneSync/`.
- Tomorrow morning, read `outputs/training_daily_check.md` first and confirm the new overnight history row shows the restored `2528 / 175` corpus instead of the old regressed counts.
- If readiness still shows `missing_target_baseline`, decide whether to record a fresh SaneSync production baseline or keep the stricter “reference only until production exists” rule.
- If the daily training checker becomes noisy, tune its summary thresholds before changing the schedule.

### SOP: 10/10
- (+) Fixed the reason the nightly lane was becoming useless instead of just describing it.
- (+) Added both a guardrail on the Mini side and a daily human-visible check on the local side.
- (+) Verified with syntax checks, a live local daily-check run, and a real Mini smoke training run.

## Session 75 (2026-03-26)

### Done
- Tightened the shared “don’t hunt for tools” path in SaneProcess instead of leaving it as a soft reminder only:
  - `scripts/automation/tool_discovery_receipt.rb` now starts with canonical tool-path recommendations for common workflows before noisy grep hits.
  - `scripts/hooks/saneprompt.rb` now routes tool-hunting / “best tool” / SOP-enforcement complaints into the `evolve` skill path.
  - `scripts/hooks/saneprompt_test.rb` now has a regression test for the exact tool-hunting/SOP complaint wording.
- Updated the durable docs so the canonical paths are written down in one obvious place:
  - `DEVELOPMENT.md` now has a `Canonical Tool Paths` section
  - `AGENTS.md` now explicitly says to prefer the canonical paths in `DEVELOPMENT.md`
- Verified the new path with:
  - `ruby -c scripts/automation/tool_discovery_receipt.rb`
  - `ruby -c scripts/hooks/saneprompt.rb`
  - `cd scripts/hooks && ruby saneprompt.rb --self-test`
  - `ruby scripts/SaneMaster.rb tool_discovery --query "you should not be hunting around for tools..." --skip-doctor --skip-validation`

### Current State
- Tool discovery is now much more useful for this class of complaint:
  - it emits canonical commands like `tool_discovery`, `verify`, `test_mode`, `appstore_preflight`, `release_preflight`, `check-inbox.sh review`, and MCP health checks before raw grep noise
- Session/handoff noise is reduced in tool discovery:
  - `SESSION_HANDOFF.md` is no longer searched by default for tool discovery unless the query is explicitly about session/recent/handoff state
- The enforcement is still prompt-driven:
  - the hook now catches more tool-hunting wording, but it still depends on the prompt being classified into the `evolve` path first

### Next
- If the same complaint still slips through, strengthen the hook again at the raw prompt-pattern level instead of adding more docs.
- If `tool_discovery` still feels too noisy or slow in live use, split fast canonical-path detection from the slower doctor/validation receipt path.

### SOP: 10/10
- (+) Fixed the process gap in the shared tool path instead of just acknowledging the complaint.
- (+) Added both durable docs and an executable regression test.

## Session 74 (2026-03-20)

### Done
- Fixed the live legacy missing-license recovery tooling so SaneClick is now covered instead of only SaneBar/SaneClip:
  - `~/SaneApps/infra/scripts/license_backfill_campaign.py`
  - `~/SaneApps/infra/scripts/check-inbox.sh`
- Added a live `scan-missing` export path so recovery no longer depends only on the stale February `license_missing_*.csv`.
- Hardened `legacy-license-recover` to refresh the missing-license export automatically before matching a thread.
- Verified the fix end to end on Margot thread `#403`:
  - generated a real Lemon-backed 100% recovery checkout
  - passed `reconcile` + `verify-facts`
  - sent the reply
- Ran a fresh SaneClick scan and found 4 stranded paid orders with no license keys.
- Sent the same canonical recovery email proactively to the other 3 stranded SaneClick buyers; delivery verification came back `delivered` for all 3.

### Current State
- Campaign artifacts:
  - scan export: `~/SaneApps/outputs/license-campaign/license_missing_20260320-082111.csv`
  - proactive send log: `~/SaneApps/outputs/license-campaign/saneclick_campaign_20260320-082415/send_log.csv`
  - proactive sent ledger: `~/SaneApps/outputs/license-campaign/saneclick_recovery_sent_20260320.csv`
- Margot thread `#403` is now pending confirmation, not unresolved.
- One noteworthy leftover: `bycs@chouchoumimi.com` also still has a separate missing SaneBar key. This pass intentionally stayed SaneClick-only.

### Next
- If `bycs@chouchoumimi.com` surfaces again, recover the separate missing SaneBar order too.
- Consider running `scan-missing --app all` periodically before inbox sweeps so stale exports do not drift again.

### SOP: 9/10
- (+) Fixed the real shared tooling gap instead of doing a one-off manual code for Margot only.
- (+) Verified with real recovery generation, real sends, and real delivery status.
- (-) The first campaign send started with the default long throttle interval before I cut it over to a short interval for the 3-recipient cleanup.

## Session 73 (2026-03-19)

### Done
- Audited the App Store release/preflight path after the SaneClick and SaneSales review failures instead of just retrying submission.
- Hardened the shared process so App Store submits cannot skip the compiled-artifact gate anymore:
  - `scripts/release.sh` now hard-runs `./scripts/SaneMaster.rb appstore_preflight` before any App Store submission step and in preflight-only mode.
  - `scripts/appstore_submit.rb` now validates live support/privacy URL health and fails fast when the IAP is still `DEVELOPER_ACTION_NEEDED`.
- Added regression coverage for the new submit-side guardrails in `scripts/appstore_submit_guardrail_test.rb`.
- Verified the new gates with:
  - `ruby -c scripts/appstore_submit.rb`
  - `bash -n scripts/release.sh`
  - `ruby scripts/appstore_submit_guardrail_test.rb`
  - `ruby scripts/sanemaster/release_guardrail_test.rb`
  - live `./scripts/SaneMaster.rb appstore_preflight` on `apps/SaneClick`
  - live `./scripts/SaneMaster.rb appstore_preflight` on `apps/SaneSales`

### Current State
- Proven process hole that existed before this pass:
  - `release.sh` could reach `appstore_submit.rb` without forcing the stronger `appstore_preflight` compiled-artifact audit first.
- Proven remaining blind spot after the new gate:
  - mixed-lane apps still share direct-only package/runtime surfaces, so App Store artifacts can retain Sparkle, app-mover, and direct-license strings even when app-level source tries to hide them.
- Corrected earlier suspicion:
  - `apps/SaneSales/iOS/Views/SettingsView.swift` already wraps the macOS `SaneSparkleRow` block in `#if !APP_STORE`; that specific claim was stale and should not be repeated.
- Current live results:
  - `SaneClick` App Store preflight now correctly fails on real blockers: `DEVELOPER_ACTION_NEEDED` IAP plus direct/donation/outside-update artifact residue.
  - `SaneSales` support URL is fixed live and a fresh routed Mini preflight now cleanly blocks on real artifact residue, not on a Mini-only build problem:
    - direct-purchase marker: `purchase key entry copy`
    - outside-update markers: `Sparkle framework linkage`, `Sparkle settings UI`, `updater service type`

### Next
- Separate App Store-safe shared UI/runtime paths from direct-only shared surfaces for mixed-lane apps (`SaneClick`, `SaneSales`, likely `SaneClip` too).
- After approval for the needed UI/settings changes, strip direct-license prompts, Sparkle update UI, and move-to-Applications/runtime updater residue from the App Store package graph instead of relying on source-level hiding.
- Re-run routed Mini `appstore_preflight` on `SaneClick` and `SaneSales` after that cleanup and do not resubmit until both compiled artifact audits are green.

### SOP: 9/10
- (+) Moved from frustration-driven retries to a proven process audit with tests.
- (+) Recorded the real remaining problem as architecture drift, not just “App Review being difficult.”
- (-) Validation report was started late in the pass and did not produce a useful signal before the audit work was already underway.

## Session 71 (2026-03-16)

### Done
- Finished the broader GPT-first workflow migration after the `/audit` change so the surrounding skills and docs no longer point at stale Claude/NVIDIA-era agent names.
- Updated the remaining workflow skills to use the current Codex subagent model:
  - `feature-reminders`
  - `codebase-explorer`
  - `evolve`
  - `seo-audit`
  - `orchestrate`
- Standardized `critic` on GPT subagents too:
  - global `critic` skill now uses 7 parallel GPT review perspectives instead of the old NVIDIA-only runner flow
  - SaneProcess `critic` skill now uses 7 `spawn_agent` review calls on `gpt-5.4`
  - added local `pipeline-tracer.md` so the project critic prompt set matches the global critic shape
- Updated the main selection docs so the standard agent names are now `explorer`, `default`, and `worker`, and the model guidance matches the current GPT-first workflow.

### Current State
- The durable standard is now:
  - `explorer` + `gpt-5.3-codex-spark` for disposable lookups
  - `default` + `gpt-5.2` for normal research
  - `default` + `gpt-5.4` for audits, critic, and hard architecture
  - `worker` + GPT for bounded implementation
- `critic` and `/audit` now agree on the same broad-context GPT-subagent direction instead of splitting between GPT and NVIDIA workflows.
- Verification run for this pass:
  - targeted `rg` contradiction sweep across the touched skill and doc files
  - `ruby scripts/SaneMaster.rb check_docs`

### Next
- If any other skill is still intentionally NVIDIA-first, decide whether it stays as an optional sidecar or gets migrated to GPT as well.
- If the global and project `critic` prompts drift again, keep the shared perspective list in sync first before changing execution details.

## Session 72 (2026-03-17)

### Done
- Documented the Setapp single-app distribution plan as a real third channel instead of letting it drift into ad hoc direct/App Store conditionals.
- Updated durable docs with the exact channel split:
  - direct = Lemon Squeezy + Sparkle
  - App Store = StoreKit + App Store updates
  - Setapp = Setapp entitlement/update path, no Sparkle, no direct licensing UI
- Wrote down the main Setapp gotchas up front:
  - Stripe is only for Setapp onboarding/payout, not a Lemon Squeezy replacement
  - separate immutable `-setapp` bundle IDs
  - universal binary readiness
  - Setapp macOS 13+ update policy
  - possible sandbox Mach exception
  - explicit menu bar usage reporting for menu bar apps

### Current State
- Durable docs now live in:
  - `ARCHITECTURE.md`
  - `DEVELOPMENT.md`
  - app `ARCHITECTURE.md` files
  - app `.claude/research.md` caches
- No Setapp product code has landed yet.
- Safe blocker remains: do not try to fake final Setapp verification before the real `setappPublicKey.pem` exists.

### Next
- Implement an explicit shared distribution-channel abstraction before touching any Setapp UI or release logic.
- Add Setapp build configs and bundle IDs for SaneBar and SaneClip.
- Then wire Setapp-specific verification on the mini before any business-facing promise about readiness.

### SOP: 10/10
- (+) Used the existing docs structure instead of inventing a new one-off Setapp plan file.
- (+) Captured the update path and drift risks before implementation, not after.

## Session 70 (2026-03-16)

### Done
- Replaced the standard `/audit` path again: it is now a real GPT subagent swarm, not `nv-audit.sh` and not `scripts/automation/gpt_audit.py`.
- Updated the global and SaneProcess audit skills, ship pipeline docs, registry, and automation docs so they all point to the same standard:
  - shared context brief
  - shared bundle
  - multiple `gpt-5.4` perspectives
  - parent synthesis before any edits
- Tightened hook enforcement:
  - `saneprompt.rb` now requires `docs_audit` subagents again
  - `sanetrack.rb` no longer treats `gpt_audit.py` as satisfying `docs_audit`
  - `sanestop.rb` now blocks session end when `docs_audit` was required but the GPT audit swarm never actually ran
- Added missing regression coverage for this exact failure mode in:
  - `saneprompt_test.rb`
  - `sanetrack_test.rb`
  - `sanestop_test.rb`
- Fixed the `saneprompt` self-test footer bug that printed `177/176 tests passed`.

### Current State
- The durable standard is now:
  - `/audit` = GPT subagent swarm
  - `gpt_audit.py` = scripted fallback only
  - `nv-audit.sh` = legacy ad hoc bulk sweep only
- Validation passed after the change:
  - `ruby -c` on the touched hook/test files
  - `python3 -m py_compile scripts/automation/gpt_audit.py`
  - `ruby scripts/hooks/saneprompt.rb --self-test-internal`
  - `ruby scripts/hooks/sanetrack.rb --self-test-internal`
  - `ruby scripts/hooks/sanestop.rb --self-test-internal`
  - `ruby scripts/hooks/sanetools.rb --self-test-internal`
  - `ruby scripts/hooks/test/tier_tests.rb`
  - `ruby scripts/SaneMaster.rb check_docs`
- Final observed counts:
  - `saneprompt`: `177/177`
  - `sanetrack`: `32/32`
  - `sanestop`: `27/27`
  - `sanetools`: `44/44`
  - tier tests: `178/178`

### Open GitHub Issues
- None opened in this audit-skill hardening pass.

### Research / Product Topics
- Audit standardization:
  - preserve the same large bundle across all perspectives
  - keep the parent synthesis step authoritative
  - do not let runner shortcuts silently replace the swarm again

### Feature Requests
- None added in this pass.

### Next
- If the broader subagent docs are cleaned up later, migrate the remaining stale `sonnet`/`opus` references in unrelated skills (`orchestrate`, `critic`, `seo-audit`, `evolve`, `codebase-explorer`) to actual Codex GPT model guidance.
- If `/docs-audit` is meant to be globally available, reconcile the registry entry with the actual installed skill path so that part is no longer fragmented.

### SOP: 10/10
- (+) Replaced the standard path instead of layering another audit variant on top.
- (+) Added enforcement and tests together so the downgrade cannot quietly return.
- (+) Updated memory and handoff immediately because this was tooling/SOP work.

## Session 69 (2026-03-16)

### Done
- Strengthened the SaneVideo recorder handoff path for `screen -> camera` recording after a bad real-world desync in `~/Desktop/Coverup.mp4`.
- Changed `RecordingTimeCoordinator` to keep a deferred source-switch time offset and commit it only after the first corrected post-switch video frame actually writes.
- Changed `RecordingEngine.videoWriter` to use `VideoWriterProtocol` so the handoff path is directly mockable in tests.
- Added recorder regressions that prove:
  - the first post-switch camera frame uses the latest written mic-audio time
  - a dropped first post-switch camera frame keeps recalibration armed until a later frame lands
- Rebuilt and relaunched `/Applications/SaneVideo.app` on the Air via `./scripts/SaneMaster.rb work_session_on && ./scripts/SaneMaster.rb test_mode`.

### Current State
- Recorder-focused verification is green on the patched tree:
  - `SaneVideoTests/RecordingEngineTests`
  - `SaneVideoTests/Features/Recording/RecordingTimeCoordinatorTests`
  - `SaneVideoTests/Regression/RecordingRegressionTests`
- The new handoff rule now matches the safer Cap-style pattern:
  - prepare a pending offset during recalibration
  - do not commit it before a corrected post-switch video frame really lands
  - if that first frame is dropped, keep the switch armed and let later audio advance the stable timeline
- Research cache now records the Apple + Cap basis for this:
  - `AVAssetWriter.startSession(atSourceTime:)` requires one coherent source timeline
  - `SCStreamOutput` delivers independent sample buffers
  - Cap defers monotonic-offset commits until append success and treats video-too-far-ahead-of-audio as a bad state
- `/Applications/SaneVideo.app` on the Air is running the patched build, and work-session caffeinate is on.
- Remaining proof gap:
  - still needs one fresh real recording where screen sharing is stopped mid-recording and the exported MP4 is checked around the handoff

### Important Files
- `apps/SaneVideo/SaneVideo/Core/Protocols/VideoWriterProtocol.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingEngine.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingTimeCoordinator.swift`
- `apps/SaneVideo/SaneVideoTests/Mocks/Mocks.swift`
- `apps/SaneVideo/SaneVideoTests/RecordingEngineTests.swift`
- `apps/SaneVideo/SaneVideoTests/Features/Recording/RecordingTimeCoordinatorTests.swift`
- `apps/SaneVideo/.claude/research.md`

### Open GitHub Issues
- None opened in this recorder hardening pass.

### Research / Product Topics
- Packet timing alone was not enough for reliable salvage of `Coverup.mp4`; prevention is the current priority.
- Cap’s deferred-offset pattern is a better model for source-switch safety than committing a new offset before the first new-source frame writes.
- If future recordings still show visible desync, the next hardening step should be a runtime guard that refuses video frames that get too far ahead of the active audio timeline.

### Feature Requests
- Keep the in-app Sync Repair flow plain-English and section-based.
- Add a stronger live validation harness for `share screen -> stop share -> continue -> stop recording`.

### Next
- Have the user make a fresh recording on the Air with a real `screen share -> stop share` handoff.
- Inspect the resulting MP4 around the handoff before trusting the fix as production-safe.
- If that fresh file still breaks, add the next guard: block or defer video frames that outrun audio past a hard threshold during or after source switches.

### SOP: 9/10
- (+) Moved from guesswork to a testable handoff rule aligned with external implementation patterns.
- (+) Recorder-specific suites are green and the Air app was rebuilt immediately after the change.
- (-) Still missing one real end-to-end proof recording after the latest deferred-offset patch.

## Session 68 (2026-03-16)

### Done
- Added a standard proof command for tool-gap checks: `ruby scripts/SaneMaster.rb tool_discovery --query "..."`.
- Added hook enforcement so sessions triggered by missing-tool/workaround/fragmentation prompts now block both before substantive work and again at stop time unless that receipt command actually ran.
- Added `scripts/automation/tool_discovery_receipt.rb`, wired it into `SaneMaster`, and updated SOP docs plus the `evolve` skill to point at the same standard path.
- Ran the full hook self-tests, tier suite, `check_docs`, and live receipt runs. All passed after one live bug fix.
- Fixed repo doc drift found during this pass: stale README/ARCHITECTURE test totals and a live receipt formatting bug where single-file `rg` output dropped filenames.

### Current State
- Tool discovery is now machine-checked enough for the user-facing problem:
  - `saneprompt.rb` flags missing-tool/workaround/fragmentation prompts as `evolve`
  - `sanetools.rb` blocks `Edit`/`Write`/`Bash`/`Task` work until the receipt command runs
  - `sanetrack.rb` records approved receipt commands
  - `sanestop.rb` blocks session end if `evolve` was required but no receipt ran
- Standard command:
  - `ruby scripts/SaneMaster.rb tool_discovery --query "..."`
- Receipt output:
  - `outputs/tool-discovery/*.json`
  - `outputs/tool-discovery/*.md`
- Live proof on `2026-03-16`:
  - `tool_discovery` ran successfully with doctor + validation + search checks
  - first live run exposed a bug: summary paths printed line numbers because `rg` omitted filenames on single-file searches
  - fixed by forcing `rg --with-filename`, then re-ran successfully

### Important Files
- `scripts/SaneMaster.rb`
- `scripts/sanemaster/tool_discovery.rb`
- `scripts/automation/tool_discovery_receipt.rb`
- `scripts/hooks/core/state_manager.rb`
- `scripts/hooks/saneprompt.rb`
- `scripts/hooks/sanetrack.rb`
- `scripts/hooks/sanestop.rb`
- `scripts/hooks/sanetrack_test.rb`
- `scripts/hooks/sanestop_test.rb`
- `AGENTS.md`
- `CLAUDE.md`
- `README.md`
- `DEVELOPMENT.md`
- `ARCHITECTURE.md`
- `~/.claude/CLAUDE.md`
- `~/.codex/skills/evolve/SKILL.md`

### Open GitHub Issues
- None opened in this tooling pass.

### Research / Product Topics
- The exact proof path for tool discovery now exists and is documented in one command rather than split between policy bullets.
- Query quality matters: generic words like `missing` and `tool` created noisy receipts until the search terms were filtered.
- Repo docs had stale test counts even after prior cleanup; this pass corrected the public totals and architecture table.

### Feature Requests
- If Codex eventually exposes better native pre-tool metadata, upgrade the receipt from stop-time enforcement to true pre-work enforcement.
- Consider adding scoring/ranking to receipt search results if future queries still produce too much noise.

### Next
- If the user wants, broaden `tool_discovery` from keyword search into a richer "reuse vs build vs install" advisor with explicit confidence scoring.
- If the user wants, add a dedicated docs/audit consistency check for `~/.claude/SKILLS_REGISTRY.md` versus the actual skill files.

### SOP: 10/10
- (+) There is now one standard command for proving a tool gap instead of loose prose.
- (+) The hooks enforce that standard for the missing-tool/workaround path.
- (+) Live verification caught and fixed a real bug before the workflow was considered done.
- (+) Public/internal docs now agree on the new path and on current test totals.

## Session 67 (2026-03-16)

### Done
- Reworked the shared SOP so "tool missing" and "use a workaround" now require a real tool-discovery pass first instead of guesswork.
- Replaced the legacy `nv`-first `/audit` skill docs with a GPT-based multi-perspective audit path.
- Added `scripts/automation/gpt_audit.py`, a shared OpenAI Responses API runner that executes prompt-directory audits in parallel and synthesizes one markdown report.
- Updated hook state/validation so the docs-audit skill can be satisfied by the approved GPT runner instead of the old "must spawn Task agents" assumption.
- Updated automation docs and ship docs so the documented `/audit` and `/ship` audit path no longer contradict the new runner.

### Current State
- Shared audit standard now points at:
  - `scripts/automation/gpt_audit.py`
  - `~/.codex/skills/audit/SKILL.md`
  - `~/.codex/skills/sane-audit/SKILL.md`
- Hook behavior now matches that standard:
  - `saneprompt.rb` treats audit as GPT audit, not subagent-required nv audit
  - `sanetrack.rb` records approved GPT audit runner usage
  - `sanestop.rb` accepts the GPT runner as satisfying `docs_audit`
- Tool-discovery guidance is now explicit in:
  - `AGENTS.md`
  - `CLAUDE.md`
  - `~/.claude/CLAUDE.md`
- Live runner proof on `2026-03-16`:
  - tiny smoke audit succeeded with `gpt-5-mini`
  - the first attempt failed because the model spent all tokens on hidden reasoning and returned no visible text
  - `gpt_audit.py` now retries that case automatically with lower reasoning effort and a larger output budget
- Remaining limitation:
  - Codex still does not have perfect native pre-tool proof of every discovery step, so "I checked" is now much clearer and more standardized, but not fully machine-proven in every path yet

### Important Files
- `AGENTS.md`
- `CLAUDE.md`
- `scripts/hooks/core/state_manager.rb`
- `scripts/hooks/saneprompt.rb`
- `scripts/hooks/sanetrack.rb`
- `scripts/hooks/sanestop.rb`
- `scripts/automation/gpt_audit.py`
- `scripts/automation/README.md`
- `~/.claude/CLAUDE.md`
- `~/.codex/skills/audit/SKILL.md`
- `~/.codex/skills/sane-audit/SKILL.md`
- `~/.codex/skills/ship/SKILL.md`

### Open GitHub Issues
- None opened in this SOP/audit tooling pass.

### Research / Product Topics
- Official OpenAI docs confirm the current audit-friendly path is the Responses API, not Chat Completions, and GPT-5 reasoning models are the recommended fit for complex multi-step workflows.
- Hidden reasoning can consume the entire `max_output_tokens` budget and yield no visible answer; GPT audit tooling needs a retry path, not just a syntax-valid request.
- The old state was contradictory: hooks expected audit subagents, but the audit skill docs told the model to use `nv` with no subagents.

### Feature Requests
- Add a stronger machine-checkable "tool discovery completed" flag if Codex exposes a stable pre-tool enforcement path later.
- Consider a dedicated `SaneMaster` command for tool-gap checks if repeated "do we already have this?" reviews continue.

### Next
- If the user wants, run a real `/audit` on one target repo through the new GPT runner and tune prompt coverage or report shape from that real result.
- If the user wants stricter proof of tool discovery, the next improvement is a dedicated audited discovery command plus hook/state integration around that command.

### SOP: 9/10
- (+) The contradiction between hook expectations and the documented audit path is gone.
- (+) `/audit` now has a real GPT runner behind it, not just a renamed idea.
- (+) Tool-discovery expectations are clearer and less likely to fragment further.
- (-) Exact proof that every discovery step was executed is still partly policy/prompt driven in Codex, not fully hard-enforced.

## Session 66 (2026-03-16)

### Done
- Re-researched screen/audio source-handoff timing using Apple docs plus Cap’s public implementation notes and added the findings to `apps/SaneVideo/.claude/research.md`.
- Found and fixed three additional recorder issues beyond the original handoff race:
  - `RecordingEngine.startRecording(...)` cleared the writer drift tracker immediately via a late `timeCoordinator.reset()`
  - audio samples could still drive time-base recalibration during a source switch
  - `VideoWriter` was feeding one drift tracker from both mic and system-audio clocks
- Added an in-app Sync Repair flow in `AudioSection` backed by `FFmpegService.repairSync(...)`.
- Added focused regression coverage and re-ran the targeted local lane successfully.
- Synced the patched tree to the mini with sibling `infra/SaneUI` and confirmed `xcodebuild build-for-testing` succeeds there.

### Current State
- The earlier `Coverup_syncsafe_trimmed.mp4` recovery was not accepted by the user and must not be treated as the final fix for the original recording.
- Recorder hardening now includes:
  - no source-switch drift-tracker wipe after recording starts
  - no audio-driven recalibration during an in-flight source switch
  - explicit primary-audio-clock selection for drift tracking
  - a dedicated `beginSourceSwitchRecalibration()` path in `RecordingTimeCoordinator`
- `/Applications/SaneVideo.app` on the Air was restaged as a Release build signed with `Developer ID Application: Stephan Joseph (M78L6FXD48)` after the Debug ad-hoc lane proved to be the wrong target for TCC-sensitive validation.
- Air TCC finding on `2026-03-16`:
  - `kTCCServiceScreenCapture` already matched the current Developer ID code requirement
  - `kTCCServiceCamera` and `kTCCServiceMicrophone` were still pinned to an older 40-byte `csreq` blob
  - backup created before patching: `~/Library/Application Support/com.apple.TCC/TCC.db.sanevideo-pre-csreq-fix-20260316-010510.bak`
- Even after aligning the camera/microphone TCC rows to the current code requirement, a live secure macOS microphone prompt remained on screen on the Air and blocked fully unattended end-to-end validation.
- In-app repair now exists for future failures:
  - shift whole audio
  - shift tail from marker
  - stretch tail from marker
  - trim video to primary audio end
  - pad audio to video end
- Focused local verification on `2026-03-16` passed:
  - `RecordingEngineTests`
  - `BatchExportServiceTests`
  - `RecordingTimeCoordinatorTests`
  - `ProjectRegressionTests`
  - total: `41 tests`, `0 failures`
- Mini verification on `2026-03-16`:
  - synced scratch root with sibling `apps/SaneVideo` and `infra/SaneUI`
  - `xcodebuild build-for-testing -project SaneVideo.xcodeproj -scheme SaneVideo -destination 'platform=macOS'`
  - result: success
- The remaining proof gap is a fresh real recording where screen sharing is stopped mid-recording, then the resulting MP4 is checked around the handoff.
- The practical blocker for fully unattended validation is now the live macOS microphone prompt state on the Air, not a build/install problem.

### Important Files
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingEngine.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingEngine+Lifecycle.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingTimeCoordinator.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/VideoWriter.swift`
- `apps/SaneVideo/SaneVideo/Services/Export/FFmpegService.swift`
- `apps/SaneVideo/SaneVideo/Views/Components/AudioSection.swift`
- `apps/SaneVideo/SaneVideo/State/ProjectState+Utilities.swift`
- `apps/SaneVideo/SaneVideoTests/RecordingEngineTests.swift`
- `apps/SaneVideo/SaneVideoTests/Features/Recording/RecordingTimeCoordinatorTests.swift`
- `apps/SaneVideo/SaneVideoTests/BatchExportServiceTests.swift`
- `apps/SaneVideo/.claude/research.md`

### Open GitHub Issues
- None opened in this recorder/sync-repair pass.

### Research / Product Topics
- `AVAssetWriter.startSession(atSourceTime:)` depends on one coherent sample timeline; later-starting inputs get empty edits, so source-handoff code must keep a single stable time base.
- `SCStreamOutput` delivers independent screen/audio/microphone sample buffers, so source-switch handling must prevent one source’s audio clock from re-basing the whole session while another source is still stopping.
- Cap’s public implementation suggests three durable patterns worth keeping in mind:
  - sample-based audio timestamps, not naive wall-clock guesses
  - anomaly tracking / clock clamping during capture
  - editor-level manual source offset repair as a safety net
- TCC permissions are not just `auth_value`; the stored `csreq` blob matters. A stale camera/microphone code requirement can trigger fresh macOS prompts after restaging even when the database still says `granted`.

### Feature Requests
- Keep Sync Repair as a first-class in-app recovery flow, not a one-off ffmpeg hack.
- Add a stronger live validation harness for `screen share -> stop share -> continue recording -> stop recording`.

### Next
- Clear the live macOS microphone prompt on the Air, then rerun the unattended `share screen -> start recording -> stop sharing -> stop recording` validation flow.
- If the prompt reappears after being manually allowed once, treat that as a separate TCC/code-identity regression and inspect the refreshed `access` rows plus the current app designation again.
- If that fresh recording is clean, use the new in-app Sync Repair UI only as the recovery path for older damaged recordings.

### SOP: 9/10
- (+) Root cause moved past guesswork into concrete timing-path failures in the recorder.
- (+) Added both prevention work and a productized repair path instead of relying on shell-only surgery.
- (+) Mini compile proof is green with the patched tree.
- (-) The original long recording is still not truly recovered; the next proof must be a fresh end-to-end recording.

## Session 64 (2026-03-15)

### Done
- Fixed the screen-share stop A/V drift on the Air by patching `RecordingEngine` source handoff timing.
- Added focused regression coverage for the handoff race in `RecordingEngineTests`.
- Rebuilt and relaunched the Air copy from `/Applications/SaneVideo.app`.

### Current State
- Root cause part 1: `RecordingEngine.processSample` could promote `pendingSource == .camera` before `ScreenRecorder.stop()` completed during a screen-to-camera switch, which let the engine recalibrate onto the camera clock while screen capture was still active.
- Root cause part 2: `processAudioSample` and `processSystemAudioSample` dropped audio whenever `timeCoordinator.startTimeNeedsRecalibration` was true, which could leave long audio gaps while waiting for the first frame from the new source.
- The preserved long recording on the Air was found at `/Users/sj/Desktop/Coverup.mp4`; its stream durations were `video 4704.83s`, `mic 4680.34s`, `system audio 3965.40s`, which matches a bad handoff after screen sharing ended.
- `RecordingEngine.swift` now:
  - defers pending camera frames during screen -> camera switches until `performSourceSwitch()` finishes the stop
  - allows the first relevant audio sample to drive recalibration during source switches so audio does not go dark waiting for video
- Focused local verification on `2026-03-15`:
  - `xcodebuild test -project SaneVideo.xcodeproj -scheme SaneVideo -destination 'platform=macOS' -only-testing:SaneVideoTests/RecordingEngineTests`
  - result: `32 tests`, `0 failures`
- Full `./scripts/SaneMaster.rb verify` on the mini still timed out at the global `300s` suite cap after `1159 tests`; that remains a separate harness problem and is not specific to this recording fix.

### Important Files
- `apps/SaneVideo/SaneVideo/Services/Recording/RecordingEngine.swift`
- `apps/SaneVideo/SaneVideoTests/RecordingEngineTests.swift`

### Open GitHub Issues
- None opened in this bug-fix session.

### Research / Product Topics
- Screen-share stop during recording needs two guarantees:
  - no source promotion before SCStream shutdown completes
  - no audio blackout while waiting for the next source's first video frame
- The long-running mini verify lane now times out because the global `300s` cap is too low for the current integration-heavy suite size.

### Feature Requests
- Keep the “stop screen share while recording” flow stable on the Air and continue to prefer live Air checks for screen/camera transitions.

### Next
- Live re-test on the Air: start a screen recording, stop screen sharing mid-recording, then stop recording and inspect the new MP4.
- If the user still sees drift, capture the exact resulting file and check whether the remaining issue is the separate full-suite timeout/harness slowdown or another media timestamp path.

### SOP: 8/10
- (+) Root cause matched both the code race and the real long recording on disk.
- (+) Added regression tests and relaunched the Air build.
- (-) The full mini verify lane is still too slow for its current hard timeout and needs its own follow-up.

## Session 63 (2026-03-15)

### Done
- Fixed the Air screen-share permission/approval loop in SaneVideo by removing the duplicate picker orchestration in `AppState.toggleScreenShare()` and delegating start flow to `ScreenRecorder.start()`.
- Fixed repeated ScreenCaptureKit filter retries by suppressing further dynamic `updateContentFilter()` attempts for the current share session after the known `SCStreamErrorDomain -3801` TCC denial.
- Rebuilt and relaunched the Air copy from `/Applications/SaneVideo.app`.
- Re-verified the focused mini lane after the patch.

### Current State
- macOS TCC rows on the Air already showed `camera`, `microphone`, and `screen capture` granted for `com.sanevideo.app`; the loop was app-side, not a missing base grant.
- `AppState+Actions.swift` no longer manually resets or presents `SCContentSharingPicker`; it now hands screen-share start to `ScreenRecorder.start()`.
- `ScreenRecorder.swift` now:
  - emits `onContentSelected` when reusing an existing filter
  - suppresses more dynamic filter updates for the current session after the ScreenCaptureKit access-denied path
  - resets that suppression on fresh selection and stop
- Focused mini verification on `2026-03-15`:
  - `ScreenRecorderTests`: passed
  - `StateMachineVerificationTests`: passed
  - total targeted lane: `29 tests`, `0 failures`

### Important Files
- `apps/SaneVideo/SaneVideo/State/AppState+Actions.swift`
- `apps/SaneVideo/SaneVideo/Services/Recording/ScreenRecorder.swift`
- `apps/SaneVideo/SaneVideoTests/Core/StateMachineVerificationTests.swift`
- `apps/SaneVideo/SaneVideoTests/Services/Recording/ScreenRecorderTests.swift`

### Open GitHub Issues
- None opened in this bug-fix session.

### Research / Product Topics
- ScreenCaptureKit can succeed on the initial picker path and still reject later stream filter updates with a separate access error; treat that as a degraded session state instead of re-entering a permission loop.
- Keep one owner for picker lifecycle. Duplicating picker orchestration in AppState and ScreenRecorder creates permission and state drift.

### Feature Requests
- Keep the screen-share flow single-path and keyboard-safe on the Air.
- Continue testing end-to-end recording and screen-share behavior on the Air even when the mini lacks a camera.

### Next
- Live-test the patched Air build with the user: screen share once, confirm no repeat approval loop, then check whether floating controls and recording continue normally.
- If ScreenCaptureKit still logs the `-3801` path during a share, capture the exact trigger moment and decide whether to fall back from overlay exclusion for that session entirely.

### SOP: 8/10
- (+) Root cause was confirmed from real Air logs instead of guessing at missing permissions.
- (+) Added tests for both the unified start flow and the ScreenCaptureKit denial classification.
- (-) First mini test run failed because the new test exposed a test-only bypass in the patched code path.

## Session 62 (2026-03-15)

### Done
- Fixed the SaneVideo screen-share quit on the Air by keeping the app alive while screen sharing is active or while the share toggle is in flight.
- Fixed the SaneVideo floating controls timer clipping by replacing the old fixed `600x100` panel size with a preferred recording-state size derived from the shared controls layout.
- Added focused coverage for the floating controls width contract and for the recording-state hosted view fitting inside the floating panel.
- Re-verified the targeted SaneVideo mini lane after the fix.

### Current State
- `AppLifecyclePolicy.shouldTerminateAfterLastWindowClosed` now considers both `isScreenSharing` and `isTogglingScreenShare`.
- `FloatingControlsWindow` now uses an integral `preferredPanelSize` based on `SharedRecordingControls.minimumBarWidth(...)` with extra trailing room for the timer.
- `RecBadgeTimer` reserves minimum width and trailing inset so the trailing timer badge does not collapse.
- Focused mini verification on `2026-03-15`:
  - `AppIntegrationTests`: passed
  - `WindowManagerTests`: passed
  - additional recording-state layout test passed: hosted floating controls content fits inside the panel width
- Practical product note: when no camera is attached, missing PiP during screen-only sharing is expected. Screen-only recording can still work.

### Important Files
- `apps/SaneVideo/SaneVideo/SaneVideoApp.swift`
- `apps/SaneVideo/SaneVideo/Views/Components/SharedRecordingControls.swift`
- `apps/SaneVideo/SaneVideo/Core/ControlsKit.swift`
- `apps/SaneVideo/SaneVideo/Windows/FloatingControlsWindow.swift`
- `apps/SaneVideo/SaneVideoTests/Integration/AppIntegrationTests.swift`
- `apps/SaneVideo/SaneVideoTests/Core/WindowManagerTests.swift`

### Open GitHub Issues
- None opened in this bug-fix session.

### Research / Product Topics
- Floating recording controls need enough reserved width for the widest recording state, not a static pre-recording width.
- Screen-share transitions on macOS can temporarily remove the last visible window before the share state finishes updating, so lifecycle policy must include the in-flight share toggle.

### Feature Requests
- Keep the floating controls layout keyboard-safe and stable during screen-only recording on machines without a camera.
- Continue using transcript-grounded commentary tooling inside SaneVideo.

### Next
- Do a live visual re-check on the Air once the user has the updated build open there, since the mini validation was frame/layout based and not a full visual screenshot.
- If the floating controls gain more trailing actions later, keep extending the width contract through `SharedRecordingControls.minimumBarWidth(...)` instead of changing hard-coded panel sizes.

### SOP: 8/10
- (+) Captured both root causes and verified the fix on the mini with targeted tests.
- (+) Added a recording-state layout test instead of only changing the panel size constant.
- (-) First mini test run failed because `ControlsKit.swift` had not been synced after the dependent width helper was introduced.

## Session 61 (2026-03-11)

### Done
- Shifted the mini training lane to `SaneAI` with `SaneVideo` workflow planning as the primary target instead of legacy action JSON.
- Added workflow-first scoring and gating in `scripts/mini/evaluate_model.py`, `scripts/mini/mini-train.sh`, and `scripts/mini/mini-nightly.sh`.
- Removed stale Phi fallback logic from the challenger lane and kept only `llama32-3b` and `smollm3-3b`.
- Expanded `apps/SaneVideo/training_data` from `7 train / 2 valid` to `115 train / 29 valid` with `generate_workflow_dataset.py`.
- Added broader eval coverage: `eval_workflow_packs.jsonl` and `eval_workflow_guardrails.jsonl`.
- Rebuilt merged `SaneAI/training_data` to `2528 train / 175 valid`.
- Synced updated corpus, eval files, and mini scripts to both `~/SaneApps` and `~/SaneApps-automation` on the mini.
- Updated Serena memory and knowledge graph for workflow-training state.

### Current State
- Mini scoring weights now default to: `commentary_workflow=4, workflow_packs=2, workflow_guardrails=2, core=1`.
- Primary gate is still `commentary_workflow`.
- Current production adapter baseline on the mini under the expanded harness:
  - `core 12/13`
  - `commentary_workflow 0/6`
  - `workflow_packs 0/5`
  - `workflow_guardrails 0/4`
  - `raw 42%`
  - `weighted 21%`
  - primary gate `FAIL`
- Main failure modes:
  - falls back to legacy `{"operations": ...}` schema
  - sometimes emits wrong workflow labels like `commentaryReview`
  - often returns too few items

### Important Files
- `SaneAI/WORKFLOW_TRAINING_STATUS.md`
- `apps/SaneVideo/training_data/generate_workflow_dataset.py`
- `apps/SaneVideo/training_data/train.jsonl`
- `apps/SaneVideo/training_data/valid.jsonl`
- `SaneAI/training_data/system_prompt.txt`
- `SaneAI/training_data/eval_commentary_workflow.jsonl`
- `SaneAI/training_data/eval_workflow_packs.jsonl`
- `SaneAI/training_data/eval_workflow_guardrails.jsonl`
- `scripts/mini/evaluate_model.py`
- `scripts/mini/mini-train.sh`
- `scripts/mini/mini-nightly.sh`
- `scripts/mini/mini-train-challengers.sh`

### Open GitHub Issues
- None opened in this workflow-training session.

### Research / Product Topics
- First-class `Commentary Flow` inside SaneVideo.
- Broader `source-grounded video workflows` surface:
  - commentary
  - meeting review
  - sales coach
  - teaching/study
  - support QA
  - podcast repurpose
- Voice brief input via Prakeet should guide focus, not become the evidence source.

### Feature Requests
- One-click `SaneAI -> SaneVideo` commentary workflow.
- Transcript-grounded concept grouping with editable concept cards.
- Source timestamps shown in every commentary clip overlay.
- Keyboard-safe workflow end to end.

### Next
- Run a fresh SaneAI fine-tune on the expanded merged corpus.
- Re-run the expanded eval harness after training and compare `llama32-3b` vs `smollm3-3b`.
- Keep mini evals serial on the 8 GB machine to avoid Metal OOM during scoring.
- If the model still clings to the old schema after retraining, add more repair-style and wrong-schema rejection examples.

### SOP: 8/10
- (+) Replaced the toy workflow corpus with a real-sized dataset and stricter eval gate.
- (+) Synced the actual nightly path to the mini instead of leaving changes local.
- (-) I initially described Serena memory storage too loosely before verifying the exact storage path.
- (-) I triggered one avoidable mini OOM by running two evals in parallel on the 8 GB machine.

## 2026-03-16 - Coverup piecewise sync repair
- User manually identified the desync becoming obvious around `9:01` in `/Users/sj/Desktop/Coverup.mp4`.
- Packet analysis found the first hard video discontinuity just before that: original video `537.320000 -> 538.031667` with audio continuous.
- Full post-`8:56` scan found 24 notable video-only skips totaling about `2.911667s` cumulative drift by end of file.
- Practical cumulative checkpoints: `~0.811666s` by `541s`, `~1.493329s` by `690s`, `~2.311662s` by `4330s`, `~2.911659s` by end.
- Major break clusters: `8:56.6-8:58.1`, `11:22.5-11:27.7`, `72:04.1-72:05.1`.
- Exported piecewise-retimed review file: `/Users/sj/Desktop/Coverup_piecewise_sync_fixed_mic_only.mp4`.
- Deleted the wrong multi-track exports after the user confirmed they played duplicate audio simultaneously.
- Exported quick review clips: `/Users/sj/Desktop/Coverup_piecewise_sync_fixed_check_9min_mic_only.mp4`, `/Users/sj/Desktop/Coverup_piecewise_sync_fixed_check_11m_mic_only.mp4`, `/Users/sj/Desktop/Coverup_piecewise_sync_fixed_check_72m_mic_only.mp4`.
- ffprobe confirms repaired output keeps full container duration (`4707.782683s`) even though ffmpeg progress visually plateaued around the shorter system-audio track length.
- Next step if user says the repaired copy is still off: validate direction against a human spot check and then build this into SaneVideo as plain-English repair modes (`Whole clip is off`, `It goes wrong at this point`, `Fix it automatically`).

## 2026-03-16 - Recorder failure review after long screen-share recording
- Investigated `/Users/sj/Movies/SaneVideo/Recordings/Recording_1773674270.0644789.mp4`.
- ffprobe showed:
  - video stream duration `7097.606667s`
  - audio stream 1 duration `7097.066667s`
  - audio stream 2 duration `6747.893083s`
- ffmpeg `volumedetect` on multiple sampled ranges showed both audio streams were effectively silent (`mean_volume` and `max_volume` around `-91 dB`), so this was a bad capture path, not a missing-track export bug.
- User also reported PiP and shared-content composition looked correct live but came out smashed together in the recording.
- Root causes identified:
  - `ScreenRecorder.handleContentSelected` created the stream from the raw picker filter, then tried to exclude SaneVideo windows later via dynamic filter updates. That creates a race where the app’s own PiP/control windows can enter the capture before exclusion kicks in.
  - `ScreenRecorder` hard-coded `config.excludesCurrentProcessAudio = true`, which strips SaneVideo’s own playback audio when the user is sharing content inside the app.
  - `RecordingEngine.startRecording` previously allowed the take to proceed immediately after calling `audioService.start()`, even if the mic capture session never actually reached `isRunning`.
- Fixes now in code:
  - `SaneVideo/Services/Recording/ScreenRecorder.swift`
    - build stream from the rebuilt exclusion filter immediately
    - update existing streams with the same effective filter
    - keep `excludesCurrentProcessAudio = false`
  - `SaneVideo/Services/Recording/RecordingEngine.swift`
    - wait for mic readiness before marking the recording as started
    - abort and clean up startup if the mic never becomes live
    - clean up partially started camera/screen/writer state on startup failures
- Tests added:
  - `SaneVideoTests/RecordingEngineTests`
    - mic readiness timeout
    - mic readiness delayed success
- Verification:
  - `./scripts/SaneMaster.rb monitor_tests SaneVideo SaneVideoTests/RecordingEngineTests 240`
  - `./scripts/SaneMaster.rb monitor_tests SaneVideo SaneVideoTests/Regression/RecordingRegressionTests 240`
  - both passed
- External guidance checked:
  - Apple ScreenCaptureKit docs for `excludesCurrentProcessAudio`, `updateContentFilter`, and `SCContentFilter(display:excludingApplications:exceptingWindows:)`
  - Descript / Resolve repair guidance confirms repair should offer plain-English modes and section-based correction, not just one global offset
- Built app directly with `xcodebuild ... build`, copied the Debug app to `/Applications/SaneVideo.app`, relaunched it, and left `caffeinate -dimsu` running.

## 2026-03-23 - test_mode fallback should have auto-redirected on provisioning-profile failure
- Shared tool bug confirmed: `scripts/sanemaster/test_mode.rb` used to auto-retry unsigned Debug only for a narrow codesign failure bucket.
- Real miss: SaneClip mini `test_mode` hit an iCloud/provisioning-profile signing failure that should have fallen back automatically but did not.
- Fix now in `scripts/sanemaster/test_mode.rb`:
  - added provisioning-profile patterns to `should_retry_unsigned_debug?`
  - `No profiles for ... were found`
  - `Automatic signing is disabled and unable to generate a profile`
  - `requires a provisioning profile with the ... feature`
- Regression test added in `scripts/sanemaster/test_mode_test.rb`.
- Verification: `ruby scripts/sanemaster/test_mode_test.rb` passed `2/2`.
- Operational meaning: when signed Mini builds are blocked by provisioning/profile state, `test_mode` should now auto-fall back to unsigned Debug instead of needing manual intervention.

## 2026-04-06 - Air/Mini unattended repo reconcile restored
- Added canonical wrapper `scripts/automation/reconcile-air-mini.sh` and local installer `scripts/automation/install-repo-reconcile-agent.sh`.
- `start-workday.sh` now calls the reconcile wrapper instead of the old advisory-only drift check.
- Installed local LaunchAgent `com.saneapps.repo-reconcile` on the Air at `05:55` and `21:55`; current `launchctl` state shows `last exit code = 0`.
- `sync-codex-mini.sh` now pushes the reconcile path plus `mini-nightly.sh` and `mini-prepare-automation-root.sh` to Mini.
- `scripts/mini/mini-nightly.sh` now re-runs `mini-prepare-automation-root.sh` so the automation root is cleaned after nightly work.
- Fixed a real unattended failure on Air by switching the private repo remotes for `SaneSync`, `SaneVideo`, and `SaneAI` from HTTPS to SSH.
- Fixed repeated Mini auto-stash churn by tracking `scripts/mini/mini-prepare-automation-root.sh` as executable.
- Verified on Mini:
  - `ruby scripts/SaneMaster.rb check_docs`
  - `ruby scripts/appstore_submit_guardrail_test.rb`
  - both passed
- Final state after cleanup:
  - all Air human repos `dirty=0`
  - all Mini human repos `dirty=0`
  - all Mini automation repos `dirty=0`
  - stash lists cleared on Air and Mini human/automation repos

## 2026-04-10 - inbox stale reply-status repair closed
- Root cause found: `infra/scripts/check-inbox.sh repair-replied-status` tried to write `replied_external`, but the live Worker endpoint in `infra/sane-email-automation/src/index.js` only allowed `resolved`, `needs_human`, and `spam`.
- Process fix landed in two places:
  - Worker `updateEmailStatus()` now allows `replied_external`.
  - `check-inbox.sh set_email_status()` now fails loudly on non-200 API responses instead of claiming success after a rejected write.
- Deployed the patched `sane-email-automation` Worker from the Mini on `2026-04-10`; live version id: `b3741daa-afc7-433e-80ae-535e39819c00`.
- Re-ran live repair on the Mini:
  - email `#525` now reads `replied_external`
  - email `#542` now reads `replied_external`
- Verified `./scripts/check-inbox.sh repair-replied-status --all-open` now runs cleanly after removing the brittle bulk-shell path; current run found `0` additional stale open threads with reply evidence.
- Reviewed current refund thread `#574` on the Mini so it is cleared for reply without `--force`.
- Net effect: the stale "already replied but still needs_human" drift for refund / duplicate-key threads is fixed at the API level, not just papered over in the shell wrapper.
