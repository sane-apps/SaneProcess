# Mac Mini Build Server Scripts

Scripts for the Mac mini training/build pipeline and the local monitoring that watches it. This is the **source of truth** for Mini runtime scripts — edit here, deploy via `deploy.sh`.

## Scripts

| Script | Schedule | Purpose |
|--------|----------|---------|
| `mini-prepare-automation-root.sh` | On demand | Creates/updates clean automation clones under `~/SaneApps-automation` |
| `mini-install-nightly-agent.sh` | On demand | Installs/updates the nightly LaunchAgent |
| `mini-install-training-agents.sh` | On demand | Installs/updates weekly + challenger training LaunchAgents |
| `mini-memory-guard.sh` | 5:40 AM daily | Mini hygiene + safe reboot gate (only when idle and needed) |
| `mini-install-memory-guard.sh` | On demand | Installs/updates memory guard LaunchAgent |
| `install-training-daily-check-agent.sh` | On demand (local Mac) | Installs/updates the daily local alert for Mini training results |
| `mini-gui-run.sh` | Manual / wrapper | Runs a shell command inside the Mini's logged-in GUI Terminal session |
| `mini-license-test.sh` | Manual deep probe | Runs the SaneBar end-to-end license lifecycle on the Mini |
| `mini-train.sh` | Manual / wrapper | MLX LoRA fine-tuning pipeline (sweeps, validation, reporting) |
| `mini-train-all.sh` | 1 AM Sunday | Weekly production training for SaneAI |
| `mini-train-challengers.sh` | 1 AM daily | Daily challenger training for SaneAI |
| `mini-nightly.sh` | 8:45 AM daily | Nightly builds + tests for all SaneApps repos |
| `training-daily-check.py` | 9:15 AM daily (local Mac) | Pulls the latest Mini training state, writes a local summary, and raises a macOS notification |

## Deploying

```bash
# Deploy all mini scripts to the build server
bash scripts/mini/deploy.sh
  # Refreshes agents even if automation-root prep warns, but exits nonzero if prep failed

# Sync the active Codex automation + skill profile to Mini
bash scripts/automation/sync-codex-mini.sh mini --no-restart

# Legacy Claude-only fallback (do not use for normal Codex parity)
bash scripts/mini/sync-claude-config.sh --dry-run

# Or deploy a single script
scp scripts/mini/mini-train.sh mini:~/SaneApps/infra/scripts/
```

Legacy note:
- `scripts/mini/sync-claude-config.sh` is kept only for Claude-specific fallback work.
- Canonical Mini control-plane parity is `scripts/automation/sync-codex-mini.sh`.
- `deploy.sh` should not be used to revive the old Claude sync path.

Default root behavior:
- Mini training runners and mini LaunchAgent installers now auto-prefer `~/SaneApps-automation` when that clone exists.
- Explicit `SANE_ROOT=...` still wins if you set it yourself.
- Outputs still write to `~/SaneApps/outputs` unless `SANE_OUTPUT_DIR` is overridden.

## Release Readiness

Before any headless App Store release from the mini, run:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/mini/bootstrap-build-server.sh
```

What it proves:
- the login keychain can be unlocked in a headless shell
- the signing keys have the right partition-list access for `codesign` and Xcode
- App Store Connect JWT auth works
- iOS signing is probe-tested when an Apple Development or Distribution identity is installed

If this script fails, stop and fix the machine first. Do not push through with raw `xcodebuild`.

## GUI Session Runner

If App Store signing works in the Mini GUI session but fails in plain `ssh` shells with `errSecInternalComponent`, use:

```bash
ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh \
  --title "SaneSales archive" \
  --log-file /tmp/sanesales-archive.log \
  --close-window \
  -- "cd ~/SaneApps/apps/SaneSales && xcodebuild archive ..."'
```

What it does:
- opens a real Terminal window in the logged-in Mini GUI session
- runs the command there
- tees output to the requested log file
- waits for completion
- closes its own Terminal window by default

Use this for App Store archive/export/upload recovery on the Mini. Do not leave throwaway Terminal windows open.

## Architecture

```
LaunchAgent (1 AM daily)
  → mini-train-challengers.sh SaneAI
    → mini-train.sh SaneAI --challenger
      → runs against clean automation root (`~/SaneApps-automation`)
      → alternating nightly bakeoff (Llama 3.2 3B ↔ SmolLM3)
      → skips Sundays so weekly SaneAI owns that window
      → no artificial runtime cap; hard stop at 8:30 AM
      → stall guard only fires when both logs and process CPU stop moving
      → challenger report + comparison report

LaunchAgent (1 AM Sunday)
  → mini-train-all.sh
    → merge_training_data.py (if exists, forced to read from clean automation root)
    → mini-train.sh SaneAI
      → runs against clean automation root (`~/SaneApps-automation`)
      → git fetch + honest repo-state report
      → sed (per-sweep LR config)
      → mlx_lm lora --train (1000 + 2000 iters)
      → Python validation with workflow-first scoring (commentary x4, broader workflow packs x2, guardrails x2, core x1)
      → primary gate requires commentary workflow suite to clear its threshold
      → archives a timestamped report + appends metrics history TSV
      → Summary report → ~/SaneApps/outputs/training_report_SaneAI.md

LaunchAgent (8:45 AM daily)
  → mini-nightly.sh
    → runs against clean automation root (`~/SaneApps-automation`)
    → git fetch + truthful dirty/behind report for all repos
    → xcodebuild (build + test each app)
    → System health (disk, memory, uptime)
    → Report → ~/SaneApps/outputs/nightly_report.md

LaunchAgent (9:15 AM daily on local Mac)
  → training-daily-check.py --host mini
    → pulls latest Mini metrics, readiness, and active alert files over SSH
    → writes local summary report
    → raises a macOS notification when training is stale, blocked, or failing

LaunchAgent (5:40 AM)
  → mini-memory-guard.sh
    → health snapshot + stale-process cleanup
    → optional reboot only in safe window and only when mini is idle
```

## Key Details

- **Bash 3.2** — mini runs macOS default bash. No `+=()` arrays, no `<<<` herestrings. Use file-based alternatives.
- **8GB RAM** — training uses ~3.7GB peak. One sweep at a time.
- **Lock files** — both scripts use `mkdir`-based locks with 8-hour stale detection.
- **Logs** — LaunchAgent stderr appends (never truncates). `mini-train-all.sh` rotates at 1MB.
- **Isolation enabled** — deploy refreshes `~/SaneApps-automation`, and launch agents point `SANE_ROOT` there so scheduled jobs do not touch the human-used `~/SaneApps` tree.
- **Managed overlays only** — automation-root prep is allowed to reset hydrated training overlays (`train.jsonl`, eval packs, challenger configs, generated fixtures) before syncing. Any other dirt still fails the prep step.
- **Training data hydration** — `mini-prepare-automation-root.sh` copies local-only `train.jsonl` / `valid.jsonl` datasets for SaneSync, SaneClip, SaneAI, and SaneVideo into the clean clones before training.
- **Dataset regression guard** — `mini-train.sh` now fails before spending GPU time if the current train/valid counts shrink too far versus the latest successful run for that lane.
- **Current bakeoff mode** — the daily challenger agent alternates `llama32-3b` and `smollm3-3b` on `SaneAI`, runs until `08:30`, and skips Sundays so the weekly `SaneAI` run gets the full window.
- **Progress tracking** — every training run now archives a timestamped report under `outputs/history/<App>/` and appends a TSV metrics row so week-over-week comparisons survive report overwrites.
- **Workflow focus** — nightly `SaneAI` training keeps the unified SaneSync/SaneClip corpus but now weights SaneVideo workflow data so the shared model learns the broader commentary/repurposing surface.
- **Workflow-first scoring** — training and nightly reports now treat `commentary_workflow` as the primary gate and weight it above legacy action JSON accuracy, while still scoring the broader SaneVideo workflow packs and schema guardrails.
- **8 GB stable baseline** — `SaneAI` production + challenger configs should use `val_batches: 1` on the Mini. `val_batches: 10` is no longer stable with the workflow-expanded corpus and reproducibly trips Metal OOM.
- **8 GB eval baseline** — keep `EVAL_MAX_TOKENS=128` on the Mini and clear the MLX Metal cache between eval cases. Longer generations are not stable enough on this box.
- **SaneVideo fixtures** — `mini-prepare-automation-root.sh` hydrates ignored `Tests/Assets` media in the clean clone when `ffmpeg` is available on the Mini.
- **Bad training is a hard failure** — `mini-train.sh` now fails the sweep if the train log shows `nan` loss or `Trained Tokens 0`, and emits a training alert instead of treating that as success.

## Standard Process

Only use this path on the Mini:
- Deploy from `scripts/mini/` in `SaneProcess`.
- Train against `SANE_ROOT=~/SaneApps-automation`.
- Write reports and alerts under `~/SaneApps/outputs`.
- Do not run scheduled training against the human repo at `~/SaneApps`.

### Smoke Test

Use this to prove the runtime, wrapper, reporting, and alert plumbing after any training change:

```bash
ssh mini '
  TRAIN_SWEEP_ITERS=2 \
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=5 \
  TRAIN_STALL_TIMEOUT_MIN=15 \
  EVAL_SUITES=commentary_workflow,core \
  EVAL_MAX_CASES=6 \
  EVAL_MAX_TOKENS=128 \
  TRAIN_ALERT_NOTIFY=false \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/automation-smoke/manual \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train.sh \
    SaneAI --model mlx-community/SmolLM3-3B-4bit \
    --config $HOME/SaneApps-automation/apps/SaneAI/training_data/challenger_configs/smollm3-3b.yaml \
    --challenger
'
```

Smoke must prove all of this:
- a new sweep directory is created
- the report is archived under `outputs/history/`
- no `nan` loss appears
- no `Trained Tokens 0` appears
- no current failure alert is left behind
- the post-train eval completes quickly because it is capped to a small smoke suite

### Bounded E2E

Use this after smoke passes:

```bash
ssh mini '
  TRAIN_SWEEP_ITERS=1000 \
  MAX_TRAIN_RUNTIME_MIN=30 \
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=15 \
  EVAL_MAX_TOKENS=128 \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/automation-e2e \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train.sh \
    SaneAI --model mlx-community/SmolLM3-3B-4bit \
    --config $HOME/SaneApps-automation/apps/SaneAI/training_data/challenger_configs/smollm3-3b.yaml \
    --challenger
'
```

Bounded e2e is only considered healthy if:
- the process stays alive past the first validation
- the report records the real exit reason
- alerts are written for failures
- the next nightly report surfaces active training alerts

## LaunchAgents (on mini)

```
~/Library/LaunchAgents/com.saneapps.training-challengers.plist → mini-train-challengers.sh (1 AM daily)
~/Library/LaunchAgents/com.saneapps.training-weekly.plist      → mini-train-all.sh (1 AM Sunday)
~/Library/LaunchAgents/com.saneapps.nightly.plist              → mini-nightly.sh (8:45 AM)
~/Library/LaunchAgents/com.saneapps.memory-guard.plist → mini-memory-guard.sh (5:40 AM)
```

## LaunchAgent (local Mac)

```
~/Library/LaunchAgents/com.saneapps.training-daily-check.plist → training-daily-check.py (9:15 AM)
```

## Outputs (on mini)

```
~/SaneApps/outputs/training_report_SaneAI.md   # Training results + validation
~/SaneApps/outputs/nightly_report.md            # Build + test results
~/SaneApps/outputs/training.stderr.log          # Training stderr (rotated at 1MB)
~/SaneApps/outputs/training.stdout.log          # Training stdout (appended)
```
