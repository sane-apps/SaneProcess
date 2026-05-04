# SaneProcess Session Handoff

## Current State (2026-05-04)

- Active policy direction is GPT-first/Mini-first. `nv`/NVIDIA helpers are legacy/explicit-only unless the user asks for that exact run.
- `AGENTS.md` is the cross-agent source of truth. `CLAUDE.md` and repo-local skills are compatibility layers, not independent policy forks.
- Research caches are active indexes, not archives. Promote durable findings to docs, Serena, memory, or issues before removing raw scratch notes from active context.

## Session 128 (2026-05-04)

### Done
- Started remaining cleanup after the best-practices audit.
- Compacted oversized active research caches for SaneBar, SaneClick, SaneSync, SaneClip, and SaneProcess into short active indexes.
- Promoted durable cache findings into Serena memories in each affected repo.
- Hardened SOP scoring after finding the Q4 metric was raw verify-attempt pass rate, not true session-final pass rate.
- Split validation reporting into verify-attempt pass rate, day/project final green rate, and score-inflation warnings; stop-hook SOP scores now cap at 8 after recovered verify failures and 6 after unrecovered verify failures.
- Added structured validation sections for system health, release readiness, app readiness, and advisory findings while preserving legacy `issues`/`warnings` output.
- Added actionable finding guidance, a red-noise budget, a process metrics dashboard command, and an explicit QA snapshot refresh dry-run/run command.
- Documented 13 MCP GitHub workflow auto-trigger exceptions in `config/github_workflow_exceptions.yml`; Q0 no longer reports those as unexplained reds.
- Shrunk active `AGENTS.md` from 473 to 424 lines by moving durable credential detail out of active context.

### Verification
- Mini targeted checks passed: `ruby -c scripts/hooks/sanestop.rb`, `ruby -c scripts/validation_report.rb`, `bash -n scripts/automation/morning-report.sh`, `ruby scripts/hooks/sanestop.rb --self-test-internal` (`37/37`), and `ruby scripts/validation_report_test.rb` (`12/12`).
- Mini full verify passed: `ruby scripts/SaneMaster.rb verify` -> `210 tests, 31s`.
- Mini `git diff --check` passed locally and on the Mini.
- Mini `ruby scripts/validation_report.rb` now clears the prior Q10 research-cache bloat, but still reports NOT WORKING because Q0 MCP GitHub workflow triggers, verify churn, and several app release-readiness gates remain red.
- Follow-up Mini targeted checks passed after the validation split: `ruby scripts/validation_report_test.rb` (`16/16`) and `ruby scripts/sanemaster/process_metrics_test.rb` (`4/4`).
- Mini command smokes passed: `ruby scripts/SaneMaster.rb process_metrics --json`, `ruby scripts/SaneMaster.rb refresh_qa_snapshots --json`.
- Mini validation JSON now reports `APP READINESS BLOCKED`: Q0 workflow-trigger reds are cleared; the remaining critical issue is `Q10 DOCS: [SaneClip] CHANGELOG missing version 2.3.0`.
- Mini full verify passed after all validation/dashboard changes: `ruby scripts/SaneMaster.rb verify` -> `216 tests, 31s`.
- Final Mini validation JSON after verify still reports `APP READINESS BLOCKED` with exactly one critical issue: `Q10 DOCS: [SaneClip] CHANGELOG missing version 2.3.0`; system health is WARN only.
- Upgraded the global Codex `status` skill and `scripts/automation/sane-status-crossref.sh` so valid daily SaneApps status now includes GitHub notifications plus comment/review activity for open org-wide issues and PRs.
- Live Mini status smoke after the upgrade completed all 8 sections and read recent comments for open SaneBar/SaneProcess issues; SaneBar `#139`, `#138`, `#137`, `#136`, and `#129` now show latest comment evidence directly in the status output.
- Reconciled release cleanup across repos after SaneSales 1.3.1: committed SaneProcess validation/status hardening, SaneUI funnel telemetry, email automation DMARC filtering, app research-cache compactions, SaneClip 2.3.0 docs, and SaneSales 1.3.1 README.
- Verified Lemon Squeezy hosted files after manual dashboard completion: SaneBar `2.1.48`, SaneSales `1.3.1`, SaneClick `1.1.5`, SaneClip `2.3.0`, and SaneHosts `1.1.8` all read `In sync`.
- Hardened `hosted_file_actions` to audit `~/Desktop/LemonSqueezy-Uploads`; the staging folder is now latest-only and stale older ZIPs were moved to Trash.

### Next
- Rerun full validation after the hosted-file audit hardening lands on Mini; expected hosted-file action count is `0`.
- Use `SaneMaster.rb process_metrics` to monitor whether new session-end scores improve after the scoring cap change.
- For daily status, classify GitHub comment activity into new evidence, needs response, waiting on reporter, patched pending confirmation, or old backlog.

## Session 127 (2026-05-04)

### Done
- Ran an updated SaneProcess policy/process audit against current Codex, Claude Code, Cursor, GitHub Copilot, and 12-factor agent guidance.
- Removed remaining normal-path `nv` drift from active docs: `scripts/automation/README.md` now marks `nv-*` helpers legacy/explicit-only, `DEVELOPMENT.md` no longer recommends NVIDIA vision for normal visual audits, and `morning-report.sh` makes the legacy `nv` executive summary opt-in.
- Collapsed repo-local `skills/docs-audit/SKILL.md` into a compatibility shim for the global Codex audit skill, and added validation coverage for oversized `AGENTS.md`, `.claude/research.md`, and `SESSION_HANDOFF.md`.

### Verification
- Mini targeted checks passed: `ruby -c scripts/validation_report.rb`, `bash -n scripts/automation/morning-report.sh`, and `ruby scripts/validation_report_test.rb` (`11/11`).
- Mini full verify passed: `ruby scripts/SaneMaster.rb verify` -> `209 tests, 31s`.
- Mini `ruby scripts/validation_report.rb` intentionally reported oversized research caches as Q10 issues before the Session 128 compaction.

### Next
- Resolve or document the 13 automatic GitHub Actions exceptions in MCP repos.
- Review score inflation: validation showed average SOP score `9.75` with only `65.5%` raw verify-attempt pass rate.

## Recent Durable Context

- Session 126: tightened startup, research, audit artifact, tool-discovery, commit/push, Mini-first, and wrapper-vs-raw-command policy wording.
- Session 125: refocused SaneAI Mini training defaults on local Mac operator workflows and extended eval validation.
- Sessions 124/123/122: corrected Mini Llama training diagnosis, restored challenger rotation, and hardened Mini training cleanup/process isolation.
- Session 121: fixed `sane_test.rb` release bundle ID targeting for Basic/Pro mode verification.

## Archived History

Older raw session entries were removed from active handoff context on 2026-05-04.
They remain recoverable in git history. Durable policy/tooling lessons should live in
`AGENTS.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, Serena memories, the knowledge graph,
or GitHub issues instead of this handoff file.
