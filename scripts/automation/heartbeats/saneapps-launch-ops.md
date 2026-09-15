Read /Users/stephansmac/AGENTS.md, /Users/stephansmac/SaneApps/infra/SaneProcess/AGENTS.md, /Users/stephansmac/SaneApps/infra/SaneProcess/SESSION_HANDOFF.md, and outputs/morning_report.md when present. Run on this Mac Mini only. Use canonical SaneMaster and check-inbox routes. Never fall back to the MacBook Air.

Daily inbox hygiene: run exactly `CHECK_INBOX_AUTORESOLVE_APPLY=1 /Users/stephansmac/SaneApps/infra/scripts/check-inbox.sh`. Auto-resolve only threads that pass its evidence guard. Review/read synthetic canary or monitor messages before closing them and fix the source.

Classifier health: use the canonical health route. Synthetic probes must never send owner email or create work-inbox items. Preserve fail-closed manual review; do not deploy without canonical checks.

On Friday, run the SaneLot Workers AI model watch from the backend and official Cloudflare sources using a small visually reviewed fixture set. Report only deprecation/failure, a clearly better candidate, or untrustworthy benchmark data. Do not email the owner.

Daily launch operations: inspect launch_calendar and recent receipts first. If nothing is due/overdue and no blocker changed, do not run broad sweeps. A nonzero canonical launch_readiness result is no-go. On Monday, Wednesday, and Friday, inspect storefront/App Store/public listing/reviewer-notice state without mutation. Training remains disabled unless separately authorized.

AgentMemory: use only the installed Mini LaunchAgent and stable loopback health route. First run `/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:3111/agentmemory/livez`. If unhealthy, do not use nohup, do not start a second direct worker, and do not claim recovery from a PID or `agentmemory status` alone. Run the focused canonical installer once: `bash /Users/stephansmac/SaneApps/infra/SaneProcess/scripts/mini/mini-install-agentmemory.sh`, then require both a successful livez response and a connected `agentmemory status`. If livez still fails, stop, report the blocker verbatim, and fail the task so the native notification fires. On Sunday only, refresh from canonical file memories only after the worker is stably healthy: stop through the canonical CLI, perform the existing documented store reset, restart through the installer, wait for livez, run `python3 /Users/stephansmac/memory_import.py` synchronously in the foreground, and do not finish until its final imported/failed receipt is present. Imported under 1000, failed above 0, missing final counts, a backgrounded import, or an import still running when the task ends is failure. File memories remain source of truth.

Friday portfolio AI usage: run exactly `ruby scripts/SaneMaster.rb ai_meter --days 7 --json`; report product calls/errors/error-rate/retries/fallbacks/latency/token coverage/cost estimate/pricing freshness/data-through time and keep quality evidence separate.

Do not post, submit listings, create accounts, pay, send email, reply publicly, upload, merge, release, or make irreversible portal changes without required approval. Keep one concise outcome report; unchanged sections get one line.

Native visibility guard: if AgentMemory livez remains unhealthy after the single canonical installer attempt, surface the exact blocker in the final report and do not suppress the run as unchanged. The owner must receive the blocker even when no other section changed.
