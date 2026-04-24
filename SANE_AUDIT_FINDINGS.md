# SaneProcess Audit Findings

Date: 2026-04-24

## Remediation Status

Patched on 2026-04-24 after this audit:

- Added `scripts/test_registry.json` and made full SaneProcess `verify` fail on unregistered script tests.
- Full Mini verify now runs the registry-backed required scripted entries and passed with real assertions.
- Added shared `scripts/automation/github-queue.sh` and routed status/morning-report/default inbox GitHub views through explicit scopes.
- Added local process metrics JSONL recording for verify, gate-review, hook blocks, release preflight, App Store preflight, and support-send outcomes.
- Added `hosted-file-actions.py --evidence-out` for Markdown release evidence.
- Added hosted-file dashboard actions to `SaneMaster status`, so Lemon Squeezy drift is part of the live status picture.
- Added SaneBar repeated-regression gate fixtures for icon visibility/drag recovery and installer signing/update.
- Extended the test quality scan to include Ruby/Python test files for basic tautology checks.

Remaining after patch:

- Lemon Squeezy hosted-file dashboard drifts still need owner action in the dashboard.
- Process metrics are instrumented but still need more real samples before statistical process-health conclusions are meaningful.
- Large release/status/validation files are not cosmetically split yet; future splits should follow the boundaries proven by the registry/queue/metrics/evidence work.

## Executive Summary

SaneProcess is working, but its weak points are now clear. The recurring failures are not mostly missing individual checks; they are fragmented source-of-truth paths and oversized orchestration scripts where release, verify, status, support, and Mini routing rules keep being patched after incidents.

The highest-value improvement is to make SaneProcess more registry-driven:

1. one explicit test registry for every scripted test
2. one status/issue source that every status surface uses
3. one release evidence ledger for appcast, website, webhook, Homebrew, Lemon Squeezy, QA snapshot, and App Store readiness
4. smaller lane-specific modules for release, verify, validation, and Mini routing

Do not start with broad cleanup. Start with the gaps that have already caused false confidence.

## Evidence Used

- Fresh Mini `ruby scripts/SaneMaster.rb status`
- Fresh Mini `ruby scripts/validation_report.rb`
- Fresh Mini `ruby scripts/SaneMaster.rb verify`
- Fresh Mini `ruby scripts/SaneMaster.rb meta`
- Fresh Mini `ruby scripts/SaneMaster.rb test_scan`
- Fresh Mini `check-inbox.sh healthcheck`, inbox report, issue patterns, and SaneBar issue reviews
- GitHub issue/PR history for `sane-apps/SaneProcess`
- Serena memories for status omissions, hosted-file drift, email delivery confirmation, Mini routing, verify false-success fixes, StartupSubmit, SaneUI guardrails, and ThumbGate gate review

## Critical Findings

### 1. Full verify does not run all repo tests

Mini check:

- `included=15`
- `all=35`
- `missing=20`

Missing from scripted full verify includes:

- `scripts/automation/status_crossref_test.py`
- `scripts/automation/email_delivery_test.py`
- `scripts/automation/control_plane_sync_test.rb`
- `scripts/dedupe_sane_apps_test.rb`
- `scripts/mini/mini_gui_run_test.rb`
- `scripts/mini/mini_memory_guard_test.rb`
- `scripts/mini/mini_train_cleanup_test.rb`
- `scripts/mini/mini_train_process_test.rb`
- `scripts/sanemaster/universal_control_test.rb`
- several standalone hook tests

This is the most important audit finding. The status omission regression was fixed with `status_crossref_test.py`, but full `verify` still does not run that test. That means a future status regression can pass full verify.

Status: patched with `scripts/test_registry.json`. Full verify now fails on unregistered test-like files and reports script test counts.

### 2. Status and inbox still use different GitHub issue scopes

Fresh `SaneMaster.rb status` correctly shows org-wide GitHub issues:

- SaneBar `#136`
- SaneBar `#129`
- SaneProcess `#8`

But `check-inbox.sh` issue output only listed SaneBar app issues. That may be fine for customer support, but it is dangerous if operators treat inbox/status reports interchangeably.

This is the same class of bug as the recent app allowlist omission: one surface sees an issue and another hides it.

Status: patched with `scripts/automation/github-queue.sh`, org-wide status/morning-report mode, and support-apps labeling for inbox.

### 3. Validation metrics are not mature enough to trust as process truth

Fresh validation report:

- `Q1`: 0 block samples; needs 30+
- `Q3`: only 22 self-rating samples, with 95.5% at 8+
- `Q4`: only 2 session outcomes, pass rate 0/2
- verdict is `NEEDS DASHBOARD SYNC`, not broken pipeline

Validation is useful for release/channel checks, but the process-health metrics are currently too sparse to prove that SaneProcess is preventing mistakes.

Status: patched. Verify, gate-review, hook block, release preflight, App Store preflight, and support-send outcomes now record local JSONL process metrics. Validation still needs more samples before the trend is meaningful.

### 4. Release and verification logic is too concentrated in large files

Fresh meta output:

- `scripts/release.sh`: 6036 lines
- `scripts/appstore_submit.rb`: 4399 lines
- `scripts/sanemaster/release.rb`: 3674 lines
- `scripts/validation_report.rb`: 2421 lines
- `scripts/SaneMaster.rb`: 2164 lines
- `scripts/sanemaster/verify.rb`: 1366 lines

History shows these exact lanes keep receiving incident fixes: App Store gates, webhook sync, website/appcast/Homebrew drift, Mini routing, false verify success, stale QA snapshots, and hosted-file dashboard drift.

Recommended fix:

- Split by durable responsibility, not cosmetic size:
  - release evidence collection
  - release publish actions
  - App Store preflight
  - verify log parsing
  - Mini route/sync/cleanup
  - validation report question modules
- Keep existing public commands stable while moving implementation behind small modules.

### 5. Dashboard-only release actions remain manual and easy to forget

Fresh validation and hosted-file actions show three current dashboard sync tasks:

- SaneBar Lemon file `2.1.41` vs appcast `2.1.45`
- SaneClip Lemon file `2.2.14` vs appcast `2.2.15`
- SaneSales Lemon file `1.2.7` vs appcast `1.3.0`

The tooling correctly tracks this as `NEEDS DASHBOARD SYNC`, but history shows these drift repeatedly because the action sits outside git and outside the release script.

Status: partially patched with `hosted-file-actions.py --evidence-out`. Dashboard replacement remains a manual owner action.

### 6. Customer-facing regression patterns are concentrated, but SaneProcess does not yet feed them back into release gates

Inbox/GitHub pattern snapshot:

- SaneBar `icon_visibility_drag`: 64 total, 1 open
- SaneBar `installer_signing_update`: 17 total
- SaneBar `cursor_input`: 7 total
- SaneBar `permissions_access`: 3 total

Open issues:

- SaneBar `#129`: persistent missing icon after drag-out/reset/uninstall
- SaneBar `#136`: arrangement regression; logs show fallback estimates and stale geometry recovery

The new `gate_review` command helps, but it is not yet connected to these issue clusters.

Status: patched with checked-in gate fixtures under `test/fixtures/gates/`. Release preflight now loads app-specific fixtures and fails malformed or failing prevention evidence.

## Warnings

### A. Test quality scan is too narrow for this repo

`ruby scripts/SaneMaster.rb test_scan` reported clean, but it says it scans Swift tests. SaneProcess is mostly Ruby, shell, and Python tests. This can create false confidence for the exact kind of weak/tautological tests the user warned about.

Status: partially patched. `test_scan` now includes Ruby/Python test files for basic tautology checks. Deeper assertion-quality analysis remains future work.

### B. Mini environment drift still appears in audit signals

Current meta:

- DerivedData is 19G
- `xcodegen` has a safe update available
- Mini Ruby is still 2.6.10
- context7 is listed missing while newer Codex docs mention different current tool paths

Recommended fix:

- Add a Mini toolchain readiness command that separates app-build blockers from non-blocking update notices.
- Track Ruby/Bundler compatibility as a first-class Mini readiness check, because this has already blocked dependency work.

### C. Open SaneProcess issue `#8` should not stay open forever without a policy state

ThumbGate `#8` is real and now answered. The code already adopted the useful local idea through `gate_review`.

Recommended fix:

- Add a label or comment state such as `watching-external`, `no-default-dependency`, or `needs-proposal`.
- Close only if the maintainer decision is final; otherwise keep it open with an explicit next action.

## What Looks Good

- Full Mini `verify` passes after the new gate-review test was wired in.
- Email healthcheck passes; delivery confirmation is now tied to Resend evidence.
- Status now has org-wide GitHub coverage and no open PRs were missed in the fresh run.
- Hosted-file drift is correctly classified as dashboard action, not broken canonical release pipeline.
- SaneUI guardrails, release preflights, App Store guardrails, and Mini routing guards are much stronger than they were in March.
- The new `gate_review` harness is aligned with the dependency-light philosophy and rejects weak fixtures.

## Recommended Fix Order

1. Build the explicit test registry and make full `verify` fail on unregistered tests.
2. Unify GitHub issue/PR enumeration across status, check-inbox, morning report, and audit.
3. Add a local process metrics ledger so validation has real block/session/verify samples.
4. Turn repeated issue clusters into gate-review fixtures before the next SaneBar persistence release.
5. Add release postflight evidence for Lemon Squeezy dashboard-hosted files.
6. Split the release/verify/status mega-files only along those same boundaries.

## No-Ship / Ship Guidance

For SaneProcess itself:

- Current changes are testable and full Mini verify passed.
- Do not call SaneProcess process-health metrics mature yet.
- Full `verify` is now registry-backed, but new tests still require explicit registry decisions and real assertions.

For SaneBar release readiness:

- Treat `#129` and `#136` as the active repeated-regression cluster.
- Before another persistence fix ships, require targeted runtime evidence plus a gate-review fixture or explicit waiver.
