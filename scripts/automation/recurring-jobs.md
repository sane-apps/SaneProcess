# Recurring jobs registry

As of 2026-08-21. Regular clients: **Grok**, **Grokbot**, and **Cursor**. Codex and Claude heartbeats stay PAUSED for compatibility reference only. Do not reactivate them.

## Runner types

| Runner | Use when |
|--------|----------|
| **LaunchAgent + script** | Deterministic GET-only or report-only work; no LLM needed |
| **LaunchAgent + Grok headless** | Mini-local agent judgment; reads `scripts/automation/heartbeats/*.md` |
| **LaunchAgent (existing)** | Nightly verify, daily business report, memory sync, batch watchdog |
| **Cursor Automation** | Air-orchestrated scheduled work; create in Cursor Automations UI |
| **Codex heartbeat (PAUSED)** | Legacy; do not reactivate without owner approval |

Install or refresh Mini LaunchAgents:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/automation/install-recurring-agents.sh
```

Pause all legacy Codex heartbeats:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/automation/pause-codex-heartbeats.sh
```

Sync control plane after client changes:

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/SaneMaster.rb sync_control_plane
```

## Active schedule (no duplicates)

| Job | Schedule | Runner | Replaces |
|-----|----------|--------|----------|
| App + CWS review watch | Every 15 min | `run-app-review-watch.sh` | Codex `saneapps-app-review-watch` |
| SaneLot X scout | Daily 10:00 | Grok `sanelot-x-opportunity-scout` | Codex same id; paid X API scout stays disabled |
| SaneApps launch ops | Daily 08:30 | Grok `saneapps-launch-ops` | Codex `saneapps-launch-ops` |
| Prophecy batch resume | Daily 20:20 | Grok `prophecy-ledger-transcript-batch-resume` | Codex same id |
| GA LLC registration | Yearly Jan 6 09:07 | Grok `saneapps-ga-llc-annual-registration-reminder` | Codex same id |
| Nightly verify | Daily 08:45 | `mini-nightly.sh` | (unchanged; not duplicate of launch ops) |
| Daily business report | Daily 19:00 | `morning-report.sh` | (unchanged) |
| Prophecy batch watchdog | Every 6 h | prophecy-ledger `run-batch-watchdog.sh` | Complements batch resume; not duplicate |
| Memory sync | Every 15 min (Air) | `sync-memory-mini.sh` | (unchanged) |
| Keep-current | Weekly Sun 09:15 (Air) | `dependency_baseline.rb` | pins/Firecrawl |
| SaneCite Monday sweep | Weekly Mon 07:00 (Air) | `run-sanecite-monday-sweep.sh` | Claude `sanecite-monday-sweep` |
| SaneBar macOS 27 watch | Daily 09:00 (Air) | `run-sanebar-macos27-watch.sh` | Codex `revisit-sanebar-after-macos-27` |

## Paused / retired

| Job | Reason |
|-----|--------|
| `sanelot-1-2-1-live-auction-release-gate` | 1.2.1 submitted 2026-08-19; CWS watch handles review state. Re-enable only for a new gated release. |

## Not duplicate (intentional overlap)

- **Launch ops (08:30)** vs **nightly (08:45)**: launch ops checks inbox, launch calendar, AgentMemory, and listing state; nightly runs bounded verify/cleanup and operator brief. Different outputs.
- **Prophecy watchdog (6 h)** vs **batch resume (daily)**: watchdog auto-heals fuse stalls; resume advances paused batches and research/conveyor work.
- **App review watch (15 min)** vs **launch ops storefront checks (M/W/F)**: watch emails on ASC/CWS state transitions; launch ops does broader read-only launch surface inspection.

## Cursor Automations (Air)

Use Cursor Automations for scheduled work that starts on the Air and orchestrates via SSH/Mini-first rules. Mini-local browser, build, and runtime proof still belong on the Mini. Do not recreate Codex heartbeats on the Air.

Suggested Air-side automations (create manually in Cursor):

- Weekly control-plane sync reminder if `sync_control_plane` receipt is stale
- PR review triage on merge-ready repos (optional; overlaps autopilot skill)

Do not duplicate the Mini LaunchAgent jobs above in Cursor.
