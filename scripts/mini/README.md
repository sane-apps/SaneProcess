# Mac Mini Build Server Scripts

Scripts for the Mac mini training/build pipeline and the local monitoring that watches it. This is the source of truth for Mini runtime scripts only. Canonical Mini control-plane parity now lives in `scripts/automation/sync-codex-mini.sh`.

## Scripts

| Script | Schedule | Purpose |
|--------|----------|---------|
| `mini-prepare-automation-root.sh` | On demand | Creates/updates clean automation clones under `~/SaneApps-automation` |
| `mini-install-nightly-agent.sh` | On demand | Installs/updates the nightly LaunchAgent |
| `mini-install-training-agents.sh` | On demand | Installs/updates weekly + challenger training LaunchAgents |
| `mini-memory-guard.sh` | 5:40 AM daily | Mini hygiene + safe reboot gate (only when idle and needed) |
| `mini-install-memory-guard.sh` | On demand | Installs/updates memory guard LaunchAgent |
| `install-training-daily-check-agent.sh` | On demand (local Mac) | Installs/updates the daily local alert for Mini training results |
| `bootstrap-build-server.sh` | On demand | Proves headless signing, keychain unlock, and ASC auth before App Store work |
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

# If the local machine does not have a `mini` ssh alias or default key, override both explicitly
MINI_HOST=sj@Stephans-Mac-mini.local \
MINI_SSH_OPTS='-i ~/.ssh/id_ed25519_codex_loopback' \
  bash scripts/mini/deploy.sh

# Sync the active Codex automation + skill profile to Mini
bash scripts/automation/sync-codex-mini.sh mini --no-restart

# Legacy compatibility wrapper (prints guidance or routes to the canonical path)
bash scripts/mini/sync-claude-config.sh --dry-run

# Or deploy a single script
scp scripts/mini/mini-train.sh mini:~/SaneApps/infra/scripts/
```

Legacy note:
- `scripts/mini/sync-claude-config.sh` is a deprecation wrapper, not a separate sync system.
- Canonical Air↔Mini control-plane and memory parity is `scripts/automation/sync-codex-mini.sh`.
- `deploy.sh` manages Mini runtime scripts only and should not be used to recreate a second config-sync lane.

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
- tags that window with the shared `SaneApps Automation:` prefix
- reclaims stale automation windows for the same job before launching
- runs the command there
- tees output to the requested log file
- waits for completion
- closes its own Terminal window by default
- hides Terminal again after cleanup so old automation windows do not linger on the desktop

Use this for App Store archive/export/upload recovery on the Mini. Do not leave throwaway Terminal windows open.

If the Mini already looks polluted, run:

```bash
ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-reclaim-automation-windows.sh --all --hide-terminal'
```

## Architecture

```
LaunchAgent (1 AM daily)
  → mini-train-challengers.sh SaneAI
    → mini-prepare-automation-root.sh (fail fast if clean automation root cannot be refreshed)
    → mini-train.sh SaneAI --challenger
      → runs against clean automation root (`~/SaneApps-automation`)
      → nightly SmolLM3-only challenger lane on the 8 GB Mini
      → skips Sundays so weekly SaneAI owns that window
      → no artificial runtime cap; hard stop at 8:30 AM
      → stall guard only fires when both logs and process CPU stop moving
      → evaluates the latest saved checkpoint when the hard stop interrupts a sweep
      → default sweep target comes from the challenger YAML (currently `50` iters for SmolLM3)
      → challenger report + comparison report

LaunchAgent (1 AM Sunday)
  → mini-train-all.sh
    → mini-prepare-automation-root.sh (fail fast if clean automation root cannot be refreshed)
    → merge_training_data.py (if exists, forced to read from clean automation root)
    → mini-train.sh SaneAI
      → runs against clean automation root (`~/SaneApps-automation`)
      → git fetch + honest repo-state report
      → sed (per-sweep LR + warmup config)
      → mlx_lm lora --train (default weekly target now comes from YAML, currently `100` iters)
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
- **Lock files** — Mini training now uses one shared `mkdir`-based MLX lock with 8-hour stale detection so production and challenger lanes cannot overlap on the 8 GB GPU.
- **Logs** — LaunchAgent stderr appends (never truncates). `mini-train-all.sh` rotates at 1MB.
- **Isolation enabled** — deploy refreshes `~/SaneApps-automation`, launch agents point `SANE_ROOT` there, and each scheduled training lane now re-runs `mini-prepare-automation-root.sh` before training so stale dirty clones fail fast instead of silently training on drifted state.
- **Managed overlays only** — automation-root prep is allowed to reset hydrated training overlays (`train.jsonl`, eval packs, challenger configs, generated fixtures) before syncing. Any other dirt still fails the prep step.
- **Training data hydration** — `mini-prepare-automation-root.sh` copies local-only `train.jsonl` / `valid.jsonl` datasets for SaneSync, SaneClip, SaneAI, and SaneVideo into the clean clones before training.
- **Dataset regression guard** — `mini-train.sh` now fails before spending GPU time if the current train/valid counts shrink too far versus the latest successful run for that lane.
- **Current bakeoff mode** — the daily challenger agent is pinned to `smollm3-3b` on `SaneAI` because `llama32-3b` reproducibly OOMs on the 8 GB Mini, runs until `08:30`, and skips Sundays so the weekly `SaneAI` run gets the full window.
- **Production Mini baseline** — `lora_config_mini.yaml` now points at `smollm3-3b` as the scheduled production model on the 8 GB Mini; `llama32-3b` remains a manual off-Mini experiment until it is requalified.
- **Unsafe-model preflight** — `mini-train.sh` now blocks `mlx-community/Llama-3.2-3B-Instruct-4bit` before launch on the 8 GB Mini unless `ALLOW_UNSAFE_TRAINING=true` is set, so the weekly lane fails cleanly with a report/alert instead of crashing Python on Metal OOM.
- **Clean-start training** — `mini-train.sh` now drains stale `mlx_lm` / `evaluate_model.py` processes before each run and purges inactive memory so one crashed/manual lane does not poison the next scheduled lane.
- **Progress tracking** — every training run now archives a timestamped report under `outputs/history/<App>/` and appends a TSV metrics row so week-over-week comparisons survive report overwrites.
- **Interrupted run recovery** — `mini-train.sh` now evaluates the latest saved checkpoint when the hard stop interrupts a sweep, so overnight runs still produce scored signal instead of defaulting to `0%`.
- **Realistic sweep sizing** — `mini-train.sh` now takes its default sweep length from the config file instead of hardcoded `1000` / `2000` defaults, and rescales warmup alongside decay steps so shortened overnight sweeps do not spend most of their life in warmup.
- **Workflow focus** — nightly `SaneAI` training keeps the unified SaneSync/SaneClip corpus but now weights SaneVideo workflow data so the shared model learns the broader commentary/repurposing surface.
- **Workflow-first scoring** — training and nightly reports now treat `commentary_workflow` as the primary gate and weight it above legacy action JSON accuracy, while still scoring the broader SaneVideo workflow packs and schema guardrails. Hybrid suites are diagnostic only and should not be used for promotion.
- **8 GB stable baseline** — `SaneAI` production + challenger configs should use `val_batches: 1` on the Mini. `val_batches: 10` is no longer stable with the workflow-expanded corpus and reproducibly trips Metal OOM.
- **8 GB sequence ceiling** — the audited merged corpus peaks at `1665` tokens on the SmolLM3 tokenizer and `1580` on the cached Llama tokenizer, so the Mini configs now use `max_seq_length: 1664` instead of carrying wasted `1792` / `2048` headroom.
- **Checkpoint cadence** — the Mini configs save every `25` steps, with current default sweep targets of `50` iterations for the nightly SmolLM challenger lane and `100` iterations for the weekly SmolLM production lane.
- **8 GB eval baseline** — keep `EVAL_MAX_TOKENS=128` on the Mini and clear the MLX Metal cache between eval cases. The strict workflow JSON eval cases now request `max_tokens: 256` individually, but the Mini still caps them via `EVAL_MAX_TOKENS_CAP` so long JSON is less likely to be truncated without globally widening every suite.
- **SaneVideo fixtures** — `mini-prepare-automation-root.sh` hydrates ignored `Tests/Assets` media in the clean clone when `ffmpeg` is available on the Mini.
- **Bad training is a hard failure** — `mini-train.sh` now fails the sweep if the train log shows `nan` loss or `Trained Tokens 0`, and emits a training alert instead of treating that as success.
- **Cleanup hygiene** — `mini-memory-guard.sh` now prunes training artifacts under both `~/SaneApps` and `~/SaneApps-automation`, rotates challenger/weekly/guard logs, and trims the training alert history log.

## Standard Process

Only use this path on the Mini:
- Deploy from `scripts/mini/` in `SaneProcess`.
- Train against `SANE_ROOT=~/SaneApps-automation`.
- Write reports and alerts under `~/SaneApps/outputs`.
- Do not run scheduled training against the human repo at `~/SaneApps`.

### Split-Lane Recommendation

- `SaneVideo` should train as a standalone workflow-only model.
- `SaneSync` should continue as the generic operations model.
- The merged `SaneAI` lane is no longer the promotion target for strict SaneVideo workflow quality.
- Use the Mini first for `SaneVideo` smoke + bounded workflow-only runs because the corpus is small (`115/29`) and the task is narrow.
- If the standalone `SaneVideo` lane still misses the strict gate after the split, move only that lane to stronger hardware or rented GPU compute.

### Standalone SaneVideo Lane

Canonical standalone files now live in:

```text
apps/SaneVideo/training_data/system_prompt.txt
apps/SaneVideo/training_data/lora_config_mini.yaml
apps/SaneVideo/training_data/challenger_configs/smollm3-3b.yaml
apps/SaneVideo/training_data/eval_commentary_workflow.jsonl
apps/SaneVideo/training_data/eval_workflow_packs.jsonl
apps/SaneVideo/training_data/eval_workflow_guardrails.jsonl
```

Run the production-style standalone lane manually with:

```bash
ssh mini '
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=15 \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/sanevideo-workflow \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train.sh \
    SaneVideo --config lora_config_mini.yaml
'
```

Run the bounded challenger-style lane with:

```bash
ssh mini '
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=15 \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/sanevideo-workflow \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train.sh \
    SaneVideo --config challenger_configs/smollm3-3b.yaml --challenger
'
```

`mini-train.sh` now defaults `SaneVideo` to workflow-only eval suites and removes the irrelevant generic `core` suite from the weighted score unless you override the env manually.

### Smoke Test

Use this to prove the runtime, wrapper, automation-root prep, reporting, and alert plumbing after any training change:

```bash
ssh mini '
  TRAIN_SWEEP_ITERS=2 \
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=5 \
  TRAIN_STALL_TIMEOUT_MIN=15 \
  CHALLENGER_SELECTION_MODE=alternate \
  CHALLENGER_ROTATION_ORDER=smollm3-3b \
  EVAL_SUITES=commentary_workflow,core \
  EVAL_MAX_CASES=6 \
  EVAL_MAX_TOKENS=128 \
  TRAIN_ALERT_NOTIFY=false \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/automation-smoke/manual \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train-challengers.sh SaneAI
'
```

Smoke must prove all of this:
- the automation root refresh runs cleanly before training
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
  TRAIN_SWEEP_ITERS=25 \
  MAX_TRAIN_RUNTIME_MIN=30 \
  TRAIN_HARD_STOP_TIME=23:59 \
  TRAIN_POLL_INTERVAL_SEC=15 \
  CHALLENGER_SELECTION_MODE=alternate \
  CHALLENGER_ROTATION_ORDER=smollm3-3b \
  EVAL_MAX_TOKENS=128 \
  SANE_ROOT=$HOME/SaneApps-automation \
  SANE_OUTPUT_DIR=$HOME/SaneApps/outputs/automation-e2e \
  /bin/bash $HOME/SaneApps/infra/SaneProcess/scripts/mini/mini-train-challengers.sh SaneAI
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
