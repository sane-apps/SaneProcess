# Mac Mini Build Server Scripts

Scripts that run on the Mac mini (M1, 8GB) build server. This is the **source of truth** — edit here, deploy via `deploy.sh`.

## Scripts

| Script | Schedule | Purpose |
|--------|----------|---------|
| `mini-prepare-automation-root.sh` | On demand | Creates/updates clean automation clones under `~/SaneApps-automation` |
| `mini-install-nightly-agent.sh` | On demand | Installs/updates the nightly LaunchAgent |
| `mini-install-training-agents.sh` | On demand | Installs/updates weekly + challenger training LaunchAgents |
| `mini-memory-guard.sh` | 5:40 AM daily | Mini hygiene + safe reboot gate (only when idle and needed) |
| `mini-install-memory-guard.sh` | On demand | Installs/updates memory guard LaunchAgent |
| `mini-train.sh` | Manual / wrapper | MLX LoRA fine-tuning pipeline (sweeps, validation, reporting) |
| `mini-train-all.sh` | 3 AM Sunday | Weekly production training for SaneAI, then challenger follow-up |
| `mini-train-challengers.sh` | 1 AM daily | Daily challenger sweeps for SaneSync |
| `mini-nightly.sh` | 2 AM daily | Nightly builds + tests for all SaneApps repos |

## Deploying

```bash
# Deploy all mini scripts to the build server
bash scripts/mini/deploy.sh
  # Also refreshes ~/SaneApps-automation and repoints launch agents to it

# Or deploy a single script
scp scripts/mini/mini-train.sh mini:~/SaneApps/infra/scripts/
```

## Architecture

```
LaunchAgent (1 AM daily)
  → mini-train-challengers.sh SaneSync
    → mini-train.sh SaneSync --challenger
      → runs against clean automation root (`~/SaneApps-automation`)
      → git fetch + honest repo-state report
      → challenger sweeps + comparison report

LaunchAgent (2 AM daily)
  → mini-nightly.sh
    → runs against clean automation root (`~/SaneApps-automation`)
    → git fetch + truthful dirty/behind report for all repos
    → xcodebuild (build + test each app)
    → System health (disk, memory, uptime)
    → Report → ~/SaneApps/outputs/nightly_report.md

LaunchAgent (3 AM Sunday)
  → mini-train-all.sh
    → merge_training_data.py (if exists, forced to read from clean automation root)
    → mini-train.sh SaneAI
      → runs against clean automation root (`~/SaneApps-automation`)
      → git fetch + honest repo-state report
      → sed (per-sweep LR config)
      → mlx_lm lora --train (1000 + 2000 iters)
      → Python validation (13 test cases)
      → Summary report → ~/SaneApps/outputs/training_report_SaneAI.md
    → mini-train-challengers.sh SaneSync (same-day challenger comparison)

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
- **Training data hydration** — `mini-prepare-automation-root.sh` copies local-only `train.jsonl` / `valid.jsonl` datasets for SaneSync, SaneClip, and SaneAI into the clean clones before training.
- **SaneVideo fixtures** — `mini-prepare-automation-root.sh` hydrates ignored `Tests/Assets` media in the clean clone when `ffmpeg` is available on the Mini.

## LaunchAgents (on mini)

```
~/Library/LaunchAgents/com.saneapps.training-challengers.plist → mini-train-challengers.sh (1 AM daily)
~/Library/LaunchAgents/com.saneapps.training-weekly.plist      → mini-train-all.sh (3 AM Sunday)
~/Library/LaunchAgents/com.saneapps.nightly.plist              → mini-nightly.sh (2 AM)
~/Library/LaunchAgents/com.saneapps.memory-guard.plist → mini-memory-guard.sh (5:40 AM)
```

## Outputs (on mini)

```
~/SaneApps/outputs/training_report_SaneAI.md   # Training results + validation
~/SaneApps/outputs/nightly_report.md            # Build + test results
~/SaneApps/outputs/training.stderr.log          # Training stderr (rotated at 1MB)
~/SaneApps/outputs/training.stdout.log          # Training stdout (appended)
```
