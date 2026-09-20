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
| SaneLot email campaign | Daily 08:15 and 16:30 through 2026-10-05 | Grok `sanelot-email-campaign` | Missing Cursor canary timers; Mini heartbeat is the sender. Grokbot is the owner-facing partner via `outputs/sanelot-resend-outreach-2026-08-21/GROKBOT.md`. Plist may exist unloaded; do not reload it as a side effect of Hosts work (40-cap dealer dump). |
| SaneClip email campaign | Weekdays 08:25 ET | LaunchAgent + `run-saneclip-email-campaign.sh` | E2/E3 only (`drip_morning.py`). Cap 50. First E2 **2026-09-08** 10:50 ET. No E1 remount. |
| SaneClick email campaign | Weekdays 08:30 ET | LaunchAgent + `run-saneclick-email-campaign.sh` | E2/E3 only (`drip_morning.py`). Cap 50. First E2 **2026-09-09** 11:15 ET. No E1 remount. |
| SaneHosts email campaign | Weekdays 08:20 ET, 2026-09-01 through 2026-11-24 | LaunchAgent + `run-sanehosts-email-campaign.sh` | Direct Python. **50** new Email 1 / weekday plus automatic Email 2/3. Tops up a short day instead of skipping. Own job — does not ride the Lot Grok heartbeat. |
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
| Fathers free-neuron burn | Daily 21:10 ET (≈01:10 UTC after CF reset) | **Mini** LaunchAgent `com.saneapps.fathers-overnight-quota` → `clients/translations/scripts/run-overnight-quota.sh` | Dual-lane CF + NVIDIA; calendar-only (no KeepAlive); fcntl.flock global + claim locks; exit 3 / wrapper exit 0 if busy; no Logos/site deploy |

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
- **Fathers overnight quota (Mini):** LaunchAgent `com.saneapps.fathers-overnight-quota` runs daily 21:10 local. Install: `bash ~/SaneApps/clients/translations/scripts/install-mini-overnight-quota.sh` on the Mini. Dual-lane CF+NVIDIA; resumes stuck `claimed` rows when idle; calendar-only (no KeepAlive); flock single-instance; wall clocks `claim_wall_s` / `overnight_wall_s`. See `clients/translations/docs/AI_CROSSCHECK.md`.

Do not duplicate the Mini LaunchAgent jobs above in Cursor.
