## 2026-09-19 evolve (Mini Grok)

- Flue: skip. Not a hands-down win over the Python translation pipeline or Cloudflare Agents SDK.
- Firecrawl CLI shared Mini+Air, pin 1.23.3. Mini authenticated. Scrape of example.com proved.
- Peekaboo **4.4.0** from the GitHub universal tarball (sha256 `6260d356…`), same Team ID `FWJYW4S8P8`. Brew upgrade still refuses (no bottle, wants Xcode 27). Binary installed into the existing 4.3.3 keg plus `~/.local/libexec/peekaboo-4.4.0`. Screen Recording still Granted. Capture while Grok running: 1920x1080 PNG. 4.3.3 backup at `~/.local/libexec/peekaboo-4.3.3-backup`.
- AgentMemory MCP wrapper now talks to Mini loopback `:3111` (`agentmemory mcp --no-engine`). Cloud Access is `--login` / `AGENTMEMORY_MCP_FORCE_CLOUD=1` only. `check-mcps` agentmemory **PASS**. Tests `scripts/grok-bin/agentmemory_mcp_remote_test.rb` 5/5. This Grok TUI session still needs a restart to reconnect MCP.
- Uncommitted SaneProcess: baseline, wrapper, tests, handoff. No origin push.

## 2026-09-19 Saturday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1146 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-19T12:00:40.916Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox (`source: canary` 0 in 200 scanned).
- Inbox: autoresolve 0. Reviewed already-spam `#1538` MEDIAPRONET $19 listing pitch (unsubscribe delivered 2026-09-18; no send/pay/account). `#1535` Apple Mail unsubscribe already resolved. Standing open: `#1525`/`#1517`/`#1483`/`#1482`/`#1404` departed/OOO auto-replies (evidence guard), `#1508` BidFlip paid-rank pitch, `#1331` Setapp agreement (owner must accept in vendor account), `#1343` Apollo nurture, `#1367` Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Skipped (not Friday): storefront inspect, AI meter, SaneLot Workers AI watch. Skipped (not Sunday): file-memory import.

## 2026-09-18 Friday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1146 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-18T12:00:38.526Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox (`source: canary` 0 in 200 scanned).
- Inbox: autoresolve 0. Reviewed OOO auto-replies `#1525`/`#1517` (evidence guard left open; no send). `#1508` BidFlip paid-rank pitch reviewed; `unsubscribe-spam` blocked as not clearly a cold sales solicitation; left open. `#1519` Codetrendy $19 listing pitch reviewed; `unsubscribe-spam` blocked; marked spam after review (same sender as already-spam `#1486`; no send/pay/account). Standing open: `#1483`/`#1482`/`#1404` departed/OOO auto-replies (evidence guard), `#1331` Setapp agreement (owner must accept in vendor account), `#1343` Apollo nurture, `#1367` Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Friday storefront inspect (no mutation): SaneClip/SaneBar Setapp public live HTTP 200; SaneScan App Store live (id6770391054, version 1.0); product sites Clip/Hosts/Click/Lot/Bar/Sales/Video/Sync HTTP 200; SaneLot CWS public listing HTTP 200 (`ihhnhedfjfjplodfhacompiahlnjbpeb`). ASC watch ok (status=ok, pending 0, last_checked_at 2026-09-18T12:34:18Z, no new reviewer notices). Setapp portal wrapper unavailable (Brave sign-in / SETAPP_PORTAL_TOKEN). CWS official GET blocked: `oauth_missing` (standing). Listing workbook unchanged: Needs action Codetrendy `#1486` (already spam), SitePatent `#1459` (already spam), StartupSubmit `#729`. No portal action.
- Friday AI meter (`ai_meter --days 7 --json`): delayed (`no_events_in_window`); data_through null. Bare command without `CLOUDFLARE_ACCOUNT_ID` in nv/env returns `unavailable`/`cloudflare_credentials_missing`; morning-report account cache unblocks the query. Totals null / products {} / retries n/a / fallbacks n/a / latency n/a / token coverage n/a / cost not_computed / pricing verified 2026-07-08 (stale vs 30-day max). Quality unknown (not run).
- Friday SaneLot Workers AI watch: production remains `@cf/google/gemma-4-26b-a4b-it` (official model page live, vision; recommended replacement, not in May 30 deprecation list). Small reviewed fixture smoke 3/3, slotScore 1.000, receipt `sanelot/outputs/vision-benchmark-friday-smoke-2026-09-18.json`. No deprecation/failure, no clearly better candidate, no untrustworthy data. No owner email.
- Skipped (not Sunday): file-memory import.

## 2026-09-17 Thursday 19:15 — Air gaps: capture attribution + ssh keychain (Muse, Mini)

- Gap 1 (Screen Recording): NO grant was missing — Terminal grant present, gate passes in console context, PNG proven 1920x1080 (Logos Pro frontmost, viewed, trashed). Air-path failure reproduced via loopback: any capture/check driven from an ssh session inherits sshd TCC attribution and is denied, even inside a Terminal window (console-dispatched identical commands PASS). No Settings toggle can fix ssh-driven capture; needs a console-resident capture agent (LaunchAgent/login-persistent runner) — recommended, not built. Side find: wrapper helper swift compiles fail under default CLT SDK (Xcode 6.3.3 vs 6.4-built SDK); SDKROOT-to-Xcode-SDK env workaround used, no files changed.
- Gap 2 (ssh Keychain writes): reproduced (add=36; even show-keychain-info=36 over ssh; console fine). Root cause: ssh sessions get a fresh security session without the login-keychain unlock — no ACL/partition tweak changes that. Built: ~/Library/Keychains/sane-env.keychain-db (empty pw, 600, unlocked, appended to search list after login). Explicit-path add/find/delete round trip over ssh GREEN, zero prompts, self-cleaned. Verbatim path-less probe still targets locked login keychain — needs Air one-word path change or owner-approved login-pw persistence (not implemented).
- Residue: automation Terminal windows (Perm Probe/Probe Shot/Mini Screenshot) resist osascript close (silent no-op); left in place.
- 19:40 DURABLE FIXES BUILT (no restarts): (a) nv/env loader unlocks sane-env keychain every source (bash+zsh 108, silent); ssh shells still read empty LOGIN secrets (standing boundary). (b) com.saneapps.mini-screenshot LaunchAgent RUNNING in gui/501 (repo script mini-screenshot-agent.sh + plist, SDKROOT pinned, queue ~/.sane/capture-queue). Queue protocol proven over ssh (request→receipt). Owner granted bash; ssh-triggered agent capture PROVEN exit 0, PNG 1920x1080 (Logos Pro frontmost, viewed, trashed, receipt cleaned). Lane is fully live.
- 20:15 TRANSLATIONS SYNC WAVE done: 3 valid bundles in /tmp (mini x2, air x1 — both `bundle verify` green). Mini main +1 unpushed commit (PBB fix, SJ authorship preserved, committed 20:09 by worker); 141 uncommitted paths intact. Air on cursor/cyril-matthew-clean-1dff, clean tree, same PBB content as e268dd74. Nothing pushed, nothing deleted. Open: push/merge call, photius untracked wave, Jev cost, Air key check, Logos upload mechanism. (c) sane-env.keychain-db live for ssh writes (explicit path). Wrapper swift/SDK mismatch + unclosable probe windows still open items.

## 2026-09-17 Thursday night — setapp upload 3 failures fixed (Muse, yolo)

- Root causes (all proven, not guessed): (1+2) apps/SaneClip and apps/SaneClip-release-peer-2.3.22 BOTH declared setapp app_id 1847 enabled; portal_targets hash last-wins gave the peer name, breaking 2 upload tests. (3) bare clang defaulted to CLT MacOSX27.0.sdk whose TBD the linker rejects; Xcode SDK compiles fine.
- Fixes: peer .saneprocess setapp.enabled false (one line; nothing uploads from peer — zero script refs); portal_targets aborts on duplicate app ids naming both paths; upload-test clang fixture pins SDKROOT to the Xcode MacOSX.sdk (legible abort if missing). New scripts/setapp_config_test.rb (2/2) registered in test_registry.json.
- Proof: upload 39/39 (was 36/39), config 2/2, verify_guard 59/59, status 8/8, media 11/11. Guard verified against the real collision (temp re-enable → abort names both paths → restored). Peer diff is exactly one line (a blanket sed briefly flipped 2 unrelated flags mid-proof; restored and diff-checked).
- Committed + pushed: SaneProcess 4eee102 (branch codex/appstore-auto-release-after-approval, d031e74..4eee102); peer SaneClip d0ff378 on main (830b000..d0ff378, rebased onto 2.3.25 release commits, one-line diff re-verified). Both confirmed from remote push responses.
- Next: (1) owner runs Air Keychain one-liner, (2) I finish Air loader edit + verify, (3) owner call on appstore_submit, (4) Stripe-name file rotation, (5) commit/push the setapp fix set.

## 2026-09-17 Thursday evening — yolo resume (Muse, unsandboxed; CONTINUE HERE)

- Yolo confirmed: uid/ps/ssh-mini-loopback all work (all blocked last session). `type muse` resolves to the binary; session launched with approval-off/sandbox-off/trusted per launch flags.
- Mini TypeSafe verified: typesafe/env mode 600 name TYPESAFE_API_KEY, nv/env single hit is the Keychain export line (no plaintext), fresh-shell len=108, Keychain entry 108+newline. Mini nv backup trashed (recoverable in ~/.Trash, mode 600).
- Air TypeSafe half-done: typesafe/env copied (mode 600, name ok, 126B matches Mini) and loader HAS the export-secret block, BUT nv/env line 153 is still `export TYPESAFE_API_KEY=...` plaintext and Air Keychain has NO entry — remote `security add-generic-password` fails over ssh ("User interaction is not allowed", exit 36). Left Air untouched (plaintext still loads len=108; swapping the loader line before the Keychain entry exists would break the Jev lane). Owner runs this ON THE AIR in a normal terminal, then tells me: `source ~/.config/typesafe/env; security add-generic-password -s sane-env -a TYPESAFE_API_KEY -w "$TYPESAFE_API_KEY" -U; unset TYPESAFE_API_KEY; security find-generic-password -s sane-env -a TYPESAFE_API_KEY -w | wc -c` (expect 109). I then do the loader edit remotely. Air backup env.bak-20260917-jev left in place (mode 600).
- Suites unsandboxed: access 6/6 (was 4/6; the 2 sandbox-only socket/uid failures now pass), secret_scan 5/5, memory_sync 15/15, setapp_status 8/8, setapp_media_sync 11/11. setapp_upload has 3 PRE-EXISTING failures in clean committed code (no dirty setapp files; impl only requires setapp_config/setapp_status): (a) create-version app-name check rejects the fixture, (b) dry-run same app-name mismatch, (c) clang linker SDK failure (MacOSX27.0.sdk TBD unknown-architecture; env toolchain issue). Not touched — Setapp lane's call.
- appstore_submit.rb untouched: dirty diff (7+/54-) deletes ensure_automatic_app_store_release + 3 call sites and flips IAP default 6.99→14.99 on a branch named for auto-release. Owner call still pending. Dirty tree at 82 paths (55M+27 new); nothing new to commit or push this session.
- Flags standing: Air ~/.config/nv/ holds a mode-644 file whose NAME looks like a live Stripe secret (seen in earlier ls; not quoted here) — rotate + rename, owner action. Keep-current pins still mid-flight (bridge 0.4.7 vs consumers).
- Next: (1) owner runs Air Keychain one-liner, (2) I finish Air loader edit + verify, (3) owner call on appstore_submit, (4) Setapp-lane triage of the 3 upload failures, (5) Stripe-name file rotation.

## 2026-09-17 Thursday — Mini screenshot/codec session (Muse, sandboxed; CONTINUE HERE)

- Pushed 5 commits to origin/codex/appstore-auto-release-after-approval: 18df747 screenshot/Peekaboo-4.3.3, c841ad3 hooks (wrote missing core/hook_payload.rb+test), af436b7 docs, 376c476 mini-ops, d031e74 validation+SOP. Suites green: gui_run 38/38, smoke 25/25, evidence 6/6, deploy 11/11, memory_guard 14/14, validation 86/86, verify_guard 59/59, agentmemory 3/3 (livez file:// fixtures), locale 10/10, baseline 31/31.
- Screenshot root cause (Air take note): raw `ssh mini screencapture` can NEVER work — TCC attributes to sshd. Use capture-mini-screenshot.sh. Mini healthy: console held since Sep 14, sshd on-demand, TCC grants present.
- JEV = TypeSafe reviewer (clients/translations). Was plaintext in ~/.config/nv/env; migrated to Keychain sane-env/TYPESAFE_API_KEY, loader exports it (verified 108ch), residue 0. Backup env.bak-20260917-jev still holds plaintext — delete after confirm. Air copy: user pulled via scp; Air-side verify still open (approval prompts died mid-session, no unsandboxed runs since).
- `muse` now means yolo: ~/.zshrc function appends --yolo. New sessions from a fresh terminal are unsandboxed. THIS session stayed sandboxed (flags fixed at launch).
- Left dirty ~80 paths, do not blanket-commit: appstore_submit.rb needs OWNER call (deletes auto-release enforcement + IAP 6.99→14.99); keep-current pins mid-flight (bridge 0.4.7 vs consumers); sanemaster-core/automation/setapp/python need an unsandboxed run (ps/Swift/pytest/network); customer_ui + runtime_log need real GUI/builds.
- Flags: Air ~/.config/nv/ has a file named like a live Stripe secret — rotate + rename, never quote it. Test-sweep lesson: suites use 4 output formats (RESULTS, minitest, PASS n/n, silent exit 0); verify_guard enforces test_registry.json registration.
- Next: (1) new yolo session, (2) verify Air TypeSafe (4-line check from last session), (3) delete nv backup, (4) unsandboxed re-run of access/secret_scan/memory_sync/setapp suites, (5) owner call on appstore_submit, (6) push any follow-up commits.

## 2026-09-15 Tuesday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1146 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-15T12:00:38Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox (0 hits in 200 scanned).
- Inbox: autoresolve 0. New `#1501` fake Turkish tax “Borç Durum Yazısı” from same sender as already-spam `#1391`; reviewed; ZIP/`yazi.js` attachment; marked spam; attachment trashed. Standing open: `#1495` SaneHosts Reddit-growth question, `#1483`/`#1482` departed/OOO auto-replies (evidence guard), `#1404` departed auto-reply (evidence guard), `#1331` Setapp agreement (owner must accept in vendor account), `#1343` Apollo nurture, `#1367` Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off. No M/W/F storefront inspect.
- Skipped (not Friday): AI meter, SaneLot Workers AI watch. Skipped (not Sunday): file-memory import.

## 2026-09-14 Monday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1146 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-14T12:00:38Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox (0 hits in 200 scanned).
- Inbox: autoresolve 1 (`#1446` SaneClip licence follow-up; delivered reply 2026-09-08, silent 5d, evidence guard passed). New open: `#1495` SaneHosts Reddit-growth question (reviewed; no purchase/GitHub; `unsubscribe-spam` blocked as not clearly a cold sales solicitation; left open). Standing open: `#1483`/`#1482` departed/OOO auto-replies (evidence guard), `#1404` departed auto-reply (evidence guard), `#1331` Setapp agreement (owner must accept in vendor account), `#1343` Apollo nurture, `#1367` Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Monday storefront inspect (no mutation): SaneClip/SaneBar Setapp public live HTTP 200; SaneScan App Store live (id6770391054, version 1.0); product sites Clip/Hosts/Click/Lot/Bar/Sales/Video/Sync HTTP 200; SaneLot CWS public listing HTTP 200. ASC watch ok (status=ok, pending 0, last_checked_at 2026-09-14T12:26:35Z, no new reviewer notices). Setapp portal wrapper unavailable (Brave sign-in / SETAPP_PORTAL_TOKEN). CWS official GET blocked: OAuth refresh HTTP 400 (standing; last observed 1.2.1 PENDING_REVIEW at 2026-08-26). Listing workbook unchanged: Needs action Codetrendy `#1486` (already spam), SitePatent `#1459` (already spam), StartupSubmit `#729`.
- Skipped (not Friday): AI meter, SaneLot Workers AI watch. Skipped (not Sunday): file-memory import.

## 2026-09-13 Sunday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1146 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-13T12:00:38Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox (0 hits in 200 scanned).
- Inbox: autoresolve 0. Standing open: #1483/#1482 departed/OOO auto-replies (evidence guard), #1404 departed auto-reply (evidence guard), #1331 Setapp agreement (owner must accept in vendor account), #1343 Apollo nurture, #1367 Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Sunday file-memory refresh **INCOMPLETE: file-memory refresh unavailable**. `/Users/stephansmac/memory_import.py` is missing (trashed 2026-08-06; not in ~/.Trash). Input contract cannot be reviewed from current source. Dry-run inventory only: claude-file-memory 0 files; serena-memories 687 files/685 md; codex-memories 3221 files/1273 md. Restore path not tested. `agentmemory import-jsonl` is Claude JSONL transcripts, not Markdown file memories. Store left running; no reset/delete/re-import.
- Skipped (not Friday): storefront inspect, AI meter, SaneLot Workers AI watch.

## 2026-09-12 Saturday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1145 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-12T12:01:09Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox.
- Inbox: autoresolve 0. Reviewed departed auto-reply #1483 and OOO auto-reply #1482 (evidence guard left both open; no send). Standing open: #1404 departed auto-reply (evidence guard), #1331 Setapp agreement (owner must accept in vendor account), #1343 Apollo nurture, #1367 Setapp business thread pending confirmation. `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh issues --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Skipped (not Friday): storefront inspect, AI meter, SaneLot Workers AI watch. Skipped (not Sunday): file-memory import.

## 2026-09-11 Friday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1145 memories. LaunchAgent loaded. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-11T12:00:28Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy. No synthetic canary in the work inbox.
- Inbox: autoresolve 0. Open: #1404 Fogdog departed auto-reply (evidence guard), #1331 Setapp agreement (owner must accept in vendor account), #1343 Apollo nurture, #1367 Setapp business thread pending confirmation. Reviewed already-spam #1459 SitePatent $19 listing pitch (no pay/account). `check-inbox.sh issues` JSON parse failed; canonical `github-queue.sh --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates; SaneLot outreach canary dates). No launch_readiness sweep. Training off.
- Friday storefront inspect (no mutation): SaneClip/SaneBar Setapp public live HTTP 200; SaneScan App Store live (id6770391054, version 1.0); product sites Clip/Hosts/Click/Lot/Bar/Sales/Video/Sync HTTP 200; SaneLot CWS public listing HTTP 200. ASC watch ok (status=ok, pending 0, last_checked_at 2026-09-11T12:31:50Z). Setapp portal wrapper unavailable (Brave sign-in / SETAPP_PORTAL_TOKEN). CWS official GET blocked: OAuth refresh HTTP 400 (standing; last observed 1.2.1 PENDING_REVIEW at 2026-08-26). Listing workbook: StartupSubmit Needs action (#729) plus SitePatent Needs action (#1459, already spam, paid pitch; no portal action).
- Friday AI meter (`ai_meter --days 7 --json`): ready; data through 2026-09-06T23:25:45Z. Portfolio 477 calls / 3 errors / 0.63% error-rate / 2 retries / 0 fallbacks / 1346.3 ms / 99.4% token coverage / cost stale_rates / pricing verified 2026-07-08. SaneLot 0 calls. Quality unknown (not run).
- Friday SaneLot Workers AI watch: production remains `@cf/google/gemma-4-26b-a4b-it` (official model page live; recommended replacement, not in May 30 deprecation list). Small reviewed fixture smoke 3/3, slotScore 1.000, receipt `sanelot/outputs/vision-benchmark-friday-smoke-2026-09-11.json`. No deprecation/failure, no clearly better candidate, no untrustworthy data. No owner email.
- Skipped (not Sunday): file-memory import.

## 2026-09-09 Wednesday launch-ops

- Host Mini. livez ok on 127.0.0.1:3111. CLI connected, v0.9.29, 1145 memories. No installer.
- Inbox: skipped (Inbox Triage / weekday inbox owns it).
- Launch calendars: nothing newly due today. Standing historical no-gos unchanged (SaneVideo release_preflight red; SaneScan VisionKit/copy gate; SaneSales/SaneCite launch gates). No launch_readiness sweep. Training off.
- Wednesday storefront inspect (no mutation): SaneClip Setapp public live (https://setapp.com/apps/saneclip HTTP 200); SaneScan App Store live (id6770391054, version 1.0); product sites Clip/Hosts/Click/Lot HTTP 200. ASC watch ok (status=ok, pending 0, no new reviewer notices through 08:55 ET). Setapp portal wrapper unavailable (Brave sign-in / SETAPP_PORTAL_TOKEN). CWS official GET blocked: OAuth refresh HTTP 400 (standing; last observed 1.2.1 PENDING_REVIEW at 2026-08-26). Listing workbook unchanged: StartupSubmit Needs action (#729).
- Skipped (not Friday): AI meter, SaneLot Workers AI watch. Sunday file-memory import not due.

## 2026-09-08 15:57 ET — Clip 2.3.24 Sparkle+LS done; LS SOP is delete-old-keep-newest

- Sparkle/site/Homebrew/webhook already live at 2.3.24 (`5b1c9d7`, dist SHA256 prefix `8fc9df35f96d`).
- Owner deleted leftover `SaneClip-2.3.23.zip` on product 779223. Agent saved; UI showed Product saved. Only `SaneClip-2.3.24.zip` remains, published.
- `release.sh --version 2.3.24 --post-release-checks-only` PASS. Receipt: `outputs/hosted_file_actions/post-release-saneclip-2.3.24-20260908T195702Z-25176.json`.
- SOP correction: after the new hosted ZIP is published, **delete** superseded LS files. Keep only the newest. Unpublishing is not cleanup. Do not claim hosted-file done while an old ZIP is still listed.
- Docs updated on Mini+Air: `templates/RELEASE_SOP.md` step 4, `scripts/automation/hosted-file-actions.py`, `scripts/automation/README.md` dashboard cleanup rule, `scripts/validation_report.rb` stale-file issue text.
- Do not rerun Clip `--full --deploy`. Next: Click 1.3.4, Hosts 1.1.26, Video 1.0.5. Same LS rule on each.
- Mini Brave hidden after Clip LS. Work sessions still on.

## 2026-09-08 Tuesday launch-ops

- Host Mini. livez `ok` on `127.0.0.1:3111`. CLI connected, v0.9.29, 1145 memories. No installer. Grok MCP `agentmemory` timed out at session start; worker health is livez, not the client handshake.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-08T12:01:40Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-08T09:01:12Z` after lastFailure `2026-09-08T08:00:55Z`. No deploy.
- Inbox: autoresolve 0. No canary/monitor work-inbox items. Open: #1404 Fogdog departed auto-reply (evidence guard), #1331 Setapp agreement (owner must accept in vendor account), Apollo nurture (#1438/#1403/#1393/#1343/#1332), #1407 Cloudflare Connect (review incomplete: Google Form link), #1367 Setapp business thread pending; outbound delivered 2026-08-31, no follow-up. `unsubscribe-spam` blocked on #1334 SoftwareSuggest and #1341 On Top Rank; left open. `check-inbox.sh issues` JSON parse failed (`gh --json` returned an ANSI spinner); canonical `github-queue.sh --scope support-apps` succeeded, standing help-wanted/workflow issues unchanged.
- Launch calendars: nothing due today. Standing no-gos unchanged. No `launch_readiness` sweep. Training off. No M/W/F storefront inspect. Listing workbook unchanged: StartupSubmit Needs action (#729).
- Skipped (not Friday): AI meter, SaneLot Workers AI watch. Sunday file-memory import not due.

## 2026-09-07 10:24 ET — SaneClip fixes published to main

- SaneClip main6feb8286796b7fb607f8e787f2cbd4aeaec7f36d is pushed. Pre-push canonical Mini verify passed252 tests/15 suites, workflow9ba533ec9d90bb871c1c86c4557c26d0. Commit includes cached-paid-license and closable-gate regression, shared60176f3, settings readability/layout and published-appcast test.
- Air fast-forwarded from2c69a20 to the same main. Fourteen pending native files matched Mini exactly before sync. The divergent untested Air-only KeychainHelper prototype is retained in named stash portfolio-saneclip-air-before-main-20260907, with all prior dirty work; canonical Mini implementation is now active on Air. Pending pink website edits and upgrade-proof config were reapplied.
- Real Mini Rewrite/Copy and Summarize/Cancel passed with actual Foundation Models generation. Source-bound proof: apps/SaneClip/outputs/customer-ui/portfolio-20260907/ai-runtime-proof.json. Original50 clips/all41 sandbox files restored exactly and original clipboard restored; runtime stopped normally.
- Shared unsigned monitor/proof runner changes and Clip upgrade config remain pending publication. AI diagnostic logs and website/App Store metadata remain separate dirty work. This is a source push, not a public release; full portfolio goal and remaining release/action checks stay open.

## 2026-09-07 10:07 ET — SaneClip suite and upgrade proof green

- Mini canonical verify252 tests/15 suites PASS, workflow564c36a3df0e33d1ef330abd21e89927. New existing-file regression seeds the actual2.3.23 license cache schema in an isolated fake keychain, verifies paid state/no expired gate, then recreates LicenseService with persisted defaults and a hanging keychain; cache check returns under1s and access/email remain. No real Keychain read, customer data, or new grant.
- Fixed two prior website-check failures: Mini comparison table accidentally lost hidden despite unverified competitor claims; restored hidden (Air was already hidden). Public download test now parses published appcast version and checks candidate version is not older, instead of pointing customers at unreleased2.3.24. Site change is source-only, no new browser visual/deploy proof.
- Shared monitor_tests has explicit --unsigned, propagated by release.upgrade_path_test.unsigned_tests; signed default unchanged. Uses same six signing overrides as unit-only verify.23 CI-helper and14 upgrade-proof security tests pass. Four source/test files match Air/Mini with backups. No production signing/grant change.
- .saneprocess now configures exact paidCacheSurvivesUpgradeAndUnavailableKeychain() test from2.3.23 with unsigned_tests true. Final actual upgrade_path_proof PASS workflowf8e06a5e74d10a2efce69088b1a118b0; final preflight04cc313980251c7d59d1560b2d7ebf63 ACCEPTS fresh behavioral upgrade proof. Earlier proof889e400 became stale after editing the shared runner regression test; regenerated only after source stabilized.
- Release still NOT CLEARED: missing/stale full clipboard/settings/AI/iOS customer-workflow artifacts. Existing screenshot/settings proof remains scoped. No release token, app upload, LS deletion or public version change. Native/settings/pin changes and this pass remain uncommitted pending coherent native review/main integration; user permits direct main.
- Evidence apps/SaneClip/outputs/portfolio-release-20260907; shared outputs/portfolio-review-20260906/unsigned-{monitor,upgrade}-tests.log. Air originals in air-before and air-before-unsigned; no broad reset/revert. Memory write timeouts remain parked; facts are in this handoff. Next: real customer-workflow completion and truthful per-action receipts, then release/LS replacement. Full portfolio goal remains active.

## 2026-09-07 09:54 ET — SaneScan startup fix pushed and synced

- Direct-main f060f22daebc5e21cb885af40a0307d11a7a4001 matches Mini/Air/origin. Removed five unused purchase-wiring/startup lines; free scanner no longer starts StoreKit product refresh/transaction listener/product-load telemetry. No timing speedup claim. Current-main canonical verification passed15 tests, workflowee2e02e88814e739fca45b1f5e6ae42c.
- Repaired Mini four-commit drift from4ce76ac to current free MIT release main, preserving its pending work in stash portfolio-scan-before-main-sync-20260907 and Air pink work in portfolio-scan-pink-before-startup-sync-20260907. Five source hashes match both hosts. Pink/UI/site edits remain pending; no App Store release. Evidence apps/SaneScan/outputs/portfolio-startup-20260907/proof.json, failure/recovery/main-test/push logs on both hosts.
- All simulator devices stopped after tests. Existing Air SaneBar process81849 showed0.0% CPU in current snapshot; earlier high-CPU sample is not reproduced or a current defect verdict. SaneBar not running on Mini, no launch/cleanup. SaneSync root lacks AGENTS.md; no edits started there; inspect actual files/nearest global instructions before that lane.
- SaneHosts post-push source/owner-data proof finalized:86 files unchanged, five hashes match, six screenshots plus all three stopped runtime directories copied to Air. Main8e1b4fd on both. Full portfolio remains ACTIVE: prioritize customer-visible/performance fixes, runtime/iPad release proof, versioned release/LS cleanup, shared infra integration and remaining parity. Memory investigation remains parked; no claim timed-out saves succeeded.

## 2026-09-07 — SaneHosts color and test-storage fixes complete on main

- Air/Mini/origin main8e1b4fd14a05c5210b314a3f638673b5a520de92. Color commit37efe30088719ebd331f0cae44512f90223567e9 preserves selected profile color and restores native named palette colors. Import test commit8e1b4fd uses existing isolated ProfileStore initializer, preventing test backups in owner storage.
- Canonical tests127 passed, including all8 colors and import save/delete/temporary-backup checks; both pre-push runs127 passed. Real signed GUI create-pink, quit/relaunch persistence, Delete Cancel then Delete confirmed, temporary profiles removed. Six inspected screenshots and stopped runtime receipts in apps/SaneHosts/outputs/customer-ui/portfolio-20260907/profile-color-proof.json.
- Final post-push verification: all86 original storage files and exact path set unchanged; five source hashes match proof. No public app release. Full customer workflows/release/LS cleanup remain pending.
- Both work guards renewed through2026-09-08T01:43Z; native assertions confirmed. User prioritizes performance and appearance; parked memory plumbing. Cloud memory_status returned healthy/active1297, but earlier write timeouts remain unconfirmed.
- Next active change: SaneScan already-unlocked UI still starts unused StoreKit refresh/listener and purchase telemetry. Removing unused startup/view purchase dependency, canonical Mini verification in outputs/portfolio-startup-20260907. Preserve earlier free-release/UI changes; no release clearance yet.

## 2026-09-07 Monday launch-ops

- Host Mini. livez `ok` on `127.0.0.1:3111`. CLI connected, v0.9.29, 1145 memories. No installer. Sunday import not due.
- Classifier `GET /api/classifier-health` 200, `status=healthy`, lastRunAt `2026-09-07T12:01:09Z`, consecutiveFailures 0, goldenMisses none. Recovered `2026-09-06T17:00:11Z` after lastFailure `2026-09-06T16:00:10Z`. No deploy.
- Inbox: autoresolve 0. Open: #1404 Fogdog departed auto-reply (evidence guard), #1331 Setapp agreement (owner must accept in vendor account), #1343 Apollo nurture. #1367 Setapp business thread pending; outbound delivered 2026-08-31, no follow-up. No canary/monitor work-inbox items.
- Launch calendars: nothing due today. Standing no-gos unchanged. No `launch_readiness` sweep. Training off.
- Monday storefront inspect (no mutation): SaneClip Setapp public live; SaneScan App Store live (`id6770391054`); SaneLot CWS public live. ASC watch ok, no new reviewer notices. Setapp portal wrapper unavailable (Brave sign-in / `SETAPP_PORTAL_TOKEN`). CWS official GET blocked: OAuth refresh HTTP 400; last observed 1.2.1 `PENDING_REVIEW` at 2026-08-26. Listing workbook unchanged: StartupSubmit Needs action (#729).
- Skipped (not Friday): AI meter, SaneLot Workers AI watch.

## 2026-09-07 04:30 ET — SaneHosts executor containment on main

- SaneHosts guard commit3a27bdb merged with existing remote release metadata; main2d034d5dd7b1a057ac1d8a052c4ac76130bd6797 now matches Air/Mini/origin. Initial125-test pre-push passed but remote rejected stale main; merged125-test rerun passed, workflowa1a56f60f58611dd73df97dde814ea8f, push succeeded. No PR or public app release.
- Resolved stash conflict by preserving exact pre-merge website bytes; all four metadata/site SHA256 checks passed. Mini stash portfolio-hosts-metadata-before-main-merge-20260907 and Air superseded handoff stash portfolio-hosts-handoff-before-main-sync-20260907 retained for recovery.
- Shared legacy-receipt revocation and12 regression checks are synced both hosts but remain uncommitted in existing shared infra changes. Evidence hosts-executor-containment.json and hosts-executor-{before,after,push,push-merged}.log under outputs/portfolio-review-20260906. Air preimages air-before-hosts-executor-sync.
- Fresh normal and all GH/GITHUB/enterprise token-env-unset API calls on both hosts returned MrSaneApps. No token printed or replaced. SaneHosts app is stopped; native suite logs are package verification, not full GUI workflow proof.
- Next: repair actual customer-workflow execution/proof for Click and Hosts, retain all required action/entitlement coverage, integrate verified shared infra changes, complete remaining portfolio runtime/iPad/release/LS cleanup and parity work. Goal remains active.

## 2026-09-07 — Legacy customer workflow evidence revoked

- Confirmed executor defect: activation only opens a context menu; entry plan omits edit/delete/invalid input; bulk omits delete; persistence only opens General/License. The writer nevertheless copied all manifest steps, expected outputs and required proof level into passed results. Fixture launch also forces Pro and compiles a fresh AX helper; no isolated HostsService target connection has been proven.
- Execution now fails closed before host checks, fixture writes, helper compilation or GUI setup. Read-only --plan still returns all11 actions. Shared release consumer rejects legacy SaneHosts/SaneClick executor receipts, including pre-existing receipts. This is containment, not completed eleven-action coverage. Independent scoped settings/profile proof remains valid.
- Mini regression:9/12 before (three expected failures),12/12 after. Logs infra/SaneProcess/outputs/portfolio-review-20260906/hosts-executor-before.log and hosts-executor-after.log. No app launched, no permission or system hosts changes. Full honest workflow runner/proof remains required before release.

## 2026-09-07 04:17 ET — SaneClick guidance on main; verification skill strengthened

- SaneClick mainb2df5f68a2f2812c70122ff96c7543596da10250 synced Air/Mini and origin;198 canonical pre-push tests passed. Populated-folder help and stale catalog both fixed; all11catalog entries updated, English runtime/screenshots prove full help/list/Add Folder with owner storage unchanged. Non-English visual review remains open.
- Apps/SaneClick/outputs/customer-ui/portfolio-20260907/recents-hint-proof.json holds source hashes, build/log/screenshots and commit/test evidence. Runtime10392/log10390/supervisor10389 stopped08:11:04Z. No app test remains active.
- Existing global ~/.codex/skills/verify-app/SKILL.md updated bothhosts: shipped catalog can override Swift defaultValue, compare actual displayed text, align existing language keys and report actual locale coverage. Recoverable preimages verify-app-before-localization-check.md and air-verify-app-before-localization-check.md are in outputs/portfolio-review-20260906. Shared SCREENSHOT_TOOLS documents native scrollbar page-button proof; no new helper.
- Next: remaining native action/library/entitlement and locale proof, replace dishonest legacy SaneClick/SaneHosts executors, versioned releases/LS cleanup, other portfolio work and shared infra review/main integration. Cleanup guard fix remains live and synced but uncommitted. Full goal ACTIVE.

## 2026-09-07 03:48 ET — Active-work cleanup guard fixed; duplicate nightly job retired

- Previous turn made progress: fresh monitored-folder/Finder proof completed, owner storage restored, runtime stopped; default GitHub credentials verified both MrSaneApps. Overall portfolio remains active.
- Fixed shared machine_cleanup server entry: fresh process inventory before any filesystem planning and again before apply, fail closed for active/unknown work, no Dock refresh after refusal. Added actual Mini coding client ChatGPT.app alongside Codex.app. Daily mini-memory-guard now exits before health probes/cleanup when active work/client is present.
- Regression evidence: two entry/apply tests failed before; renamed-client case separately failed before. Final process8, main cleanup23, retention7, daily guard14 and deploy11 tests pass (63 total). Logs outputs/portfolio-review-20260906/cleanup-*.log. Actual Mini command emits skipped/codex_gui_active and actual daily --dry-run emits skipped: active work; no app launch or filesystem cleanup needed for this guard proof.
- Retired duplicate com.saneapps.disk-clean: disabled and booted out; its plist and two ~/.sanemaster/tools scripts moved to Trash after regular-file/symlink checks and recoverable backups. retirement.json proves unloaded/disabled/path absence and canonical daily memory-guard still loaded. Backup directory outputs/portfolio-review-20260906/retired-nightly-disk-20260907. No user data deleted; no new schedule created.
- deploy.sh now retires this duplicate on future deployment. Applied only its retirement steps because full deployment also changes Keychain settings and reinstalls unrelated services. Canonical active guard runs directly from this checkout. Shared changes remain uncommitted among existing portfolio changes; preserve unrelated diffs.
- All10 affected source/docs are synced to Air with recoverable preimages in air-before-cleanup-guard-sync-20260907. Final receipt: cleanup-guard-repair.json. Remaining immediate app work: SaneClick populated-folder Recents guidance, remaining workflows/entitlements and honest executor replacement. Broad portfolio releases/LS cleanup, iPad/other apps, shared infra integration, cross-machine parity and root restart/logout diagnosis remain open.

## 2026-09-07 03:28 ET — Unattended cleanup interrupted active GUI proof

- Mini nightly disk cleanup started02:44 during SaneClick testing; desktop showed ruby data-from-other-apps consent. Cleanup requester attribution is likely, not proven by TCC audit log. Exact chain88766/88769/88771 stopped03:25; active SaneClick98900/logger98897 preserved. Native Don't Allow dismissed lingering prompt; clean desktop03:27:09 proves gone. No broad access granted, no TCC reset.
- Runtime job ~/.sanemaster/tools/mini-nightly-disk.sh calls machine_cleanup --server --apply with cache/DerivedData thresholds0 then legacy mini-disk-clean.sh. Follow-up contains rm -rf, no whole-run active-work guard, and empty-Trash sweep. Existing server blocking flags only protect select collectors; other cache/path probes still run. Fix shared guard before filesystem scan, replace duplicate legacy cleanup path with canonical wrapper, test skipped run does not continue into deletion. Source/deployment mapping pending. No schedule changes yet.
- Evidence private apps/SaneClick/outputs/customer-ui/portfolio-20260907:03:24:19 before,03:25:59 lingering after process termination,03:27:09 after native dismissal; AgentMemorya39d75de-3cf2-41e5-9fee-1dc68edfba92. SaneClick original monitored-folder file is now byte-for-byte restored and all63 owner scripts/folders match backup. Runtime98900/log98898/supervisor98897 stopped07:33:27Z. Actual Finder image menu and submenu proved; Recents guidance hidden for populated folders remains a narrow fix. See app fresh-install-workflow-proof.json and handoff.

# SaneProcess Session Handoff

## 2026-09-07 03:13 ET — SaneClick custom editor fix pushed and synced

- Main2dfd5116666c0bc96c9163787fb38cbf0422cff1 independently confirmed on origin; Air fast-forwarded to same SHA. No PR. Canonical pre-push198 tests PASS, workflow1e3eb4f0f30393cbfcc263120619d04b; apps/SaneClick/outputs/customer-ui/portfolio-20260907/custom-cancel-push.log.
- Existing-action Cancel is runtime verified: changed draft name and code, clicked Cancel, editor dismissed and saved action unchanged. Custom create/edit/disable/relaunch/re-enable/delete also exercised without changing63 owner records. Owner scripts/folders remain identical after full tests. Actual Finder-menu deletion read-back remains pending.
- Six inspected private screenshots, exact source hash and scope limits in custom-workflow-proof.json. Runtime94691/logger94689/supervisor94688 stopped07:09:11Z. No test fixture or owned app remains. Air stash portfolio-click-cancel-before-main-sync-20260907 preserves superseded source/handoff; do not reapply.
- Next SaneClick: fresh monitored-folder setup and actual Finder proof, remaining library categories/entitlement states/settings actions/editor-scroll visuals; replace dishonest legacy executor. Then versioned release/LS replacement. Overall portfolio goal and shared infra integration remain active.


## 2026-09-07 — Diagnostic evidence routing and test registry repaired

- Previous goal turn made progress: SaneClick main9e78189 is synced Air/Mini, paid-state library identity regression verified, full198 tests pass. Owner configuration restored, app81405/log81403/supervisor81402 stopped; no active SaneClick GUI test. See app SESSION_HANDOFF.md for screenshots/runtime receipts.
- Fixed shared verify evidence routing: run_tests_with_progress now retains the failing phase xcresult_path and log_path; verify passes both to diagnose. Diagnostics prints the current command log, avoids searching unrelated bundles when that log identifies the current run, and discovers outputs/verify and outputs/monitor-tests for standalone use. Removed stale test_output.txt advice.
- Regression proof: three new checks failed before; verify_failure_review_test.rb6/6 now pass, verify_guard_test.rb59/59 including actual verify failure-to-diagnose argument flow. Logs outputs/portfolio-review-20260906/diagnostics-current-result-{before,final}.log and diagnostics-verify-guard-final.log. Tests use isolated fixtures; no app rebuild needed for Ruby routing.
- Broader verify guard exposed nine existing unregistered tests. All nine now required in scripts/test_registry.json and each suite passed. registered-test-results-final.json maps each to its log. GUI feedback test now emits its actual count; internal report test uses standard run_tests plus exit status. TestFlight artifact fixture bare remote explicitly uses main, fixing git clone creating an unborn wrong branch;10 tests49 assertions pass.
- Relevant files remain uncommitted in the existing infra branch among prior portfolio changes. Do not blanket stage/revert. Whole-repo diff-check still flags a pre-existing extra EOF blank in AGENTS.md; changed diagnostic files pass scoped diff-check.
- Remaining: replace incomplete SaneClick/SaneHosts action executors; complete native workflow/entitlement/fresh-install proof and release/LS replacements, remaining portfolio apps/iPad/UI, broader infra integration and machine parity. No full portfolio or full infra suite clearance claimed. AgentMemory098cb69f-e306-4f02-a14e-61d806a5ec1b records this process repair.


## 2026-09-07 02:06 ET — Customer workflow proof active; unsafe QA claims blocked

- Source review found scripts/customer_ui_action_executor.rb marks manifest steps complete without performing them: main category plan only navigates, global library plan only opens/closes, custom plan only opens manager; Finder uses internal pending_execution.json, fresh install merely inspects current storage. It also raw-spawns force-Pro and compiles a fresh AX helper from a stale sibling path. These are not complete8-action receipts. SaneHosts contains the same manifest-copy pattern; assess its actual plans separately before trusting them.
- Interim fail-closed guard now stops --execute before GUI setup/receipt writes; --plan remains available. Shared customer_ui_evidence_integrity_test.rb regression failed8/9 before and passed9/9 after. Both changed files match Air/Mini, uncommitted. This is containment, not a rebuilt executor: replace its legacy execution with actual observed workflows, retain full scope, remove copied claim fields and old helper/raw-launch paths. AgentMemory a41d676b-e8ba-4c27-b042-a00be762022b records issue.
- Actual paid-owner UI pass uses canonical signed launch with live log from before launch; workflow10e9f5603adeacd426ed60c7824e677c. ACTIVE appPID72043/window2755; runtime receipt outputs/runtime-logs/20260907T055739Z-20260907-71981-9d39jo/receipt.json, deadline06:57:39Z. Before ending, normal-quit and verify log supervision stops.
- Existing scripts.json and monitored_folders.json copied without alteration to outputs/customer-ui/portfolio-20260907/owner-state-before/. Live JSON remained semantically identical after three category off/on pairs. Do not replace owner data blindly; restore test changes through UI and compare this baseline.
- Real main category toggles passed Essentials14->0->14, Files & Folders9->0->9, Images & Media15->0->15 with every row switch read back. Exact-window Peekaboo snapshots required: --window-id2755 --tree --no-screenshot; app-only snapshot was rejected as incomplete before any observed state change. Click/read-back receipts in portfolio-20260907; raw app snapshot failure retained.
- Clean private screenshots inspected02:00:46 (Essentials all-on),02:02:18 (Essentials all-off),02:04:48 (Files & Folders all-on). Images & Media screenshot capture currently running; inspect it before moving the UI. This is paid-state partial proof, not completed manifest or release clearance. Next Coding/Advanced toggles, individual-toggle persistence, real library controls, custom CRUD/same-name preservation, fresh monitored-folder setup, remaining settings/entitlement cases. Earlier actual five Finder category/file proofs remain separate source-bound evidence.


## 2026-09-07 01:52 ET — Guide release live; workspace fix on main

- SaneClick direct-main push completed at4e1609bb6bb87e2402e9271a8e73a9a4316d4f55 (guide commit3ad3edb plus workspace fix4e1609b), independently confirmed by git ls-remote. No PR created. Required pre-push full197-tests/22-suites PASS; workflow44ca3260af12d2197c018b22fd591abd, outputs/portfolio-guide-facts-final-20260907/push-final.log.
- Air's seven pending files were byte-identical to origin/main. Preserved them in stash portfolio-click-guide-minimum-before-main-sync-20260907, then fast-forwarded. Both hosts reached the same clean code commit before this receipt note. Do not reapply the superseded stash.
- Canonical release.sh --website-only completed; deployment https://7b7f0762.saneclick-site.pages.dev serves saneclick.com. Public14-page/viewport layout checks PASS. Allfour changed HTML pages match inspected source exactly after removing the one exact extra Cloudflare-injected analytics script; content unchanged. layout-live.json and live-guide-parity.json retain the actual assertions/hashes and exact removed line. Initial raw-byte assertion failed only because of this injection; one bare Python urllib request got403, while named SaneApps-QA requests and real browser checks succeeded. No source or behavior override used.
- Eight guide screenshots retain inspected:true receipts. Two clean native workspace screenshots plus AX resize bounds, unchanged1/1 focused test and stopped signed runtime are in window-minimum-visual-verification.json. These private receipts are copied to both hosts. Active native app/log/helper processes from this run stopped; installed Finder extension remains OS-managed. Preview server60504 absent.
- Shared AgentMemory tracks minimum-size cause/fix and guide release. Overall portfolio goal remains ACTIVE: full native customer workflow and versioned artifact release/LS replacement still pending. Installed modified1.3.3 is not a new public app release.
- Process follow-up found during this lane: verify diagnostics searches legacy locations, misses its own outputs/verify/*.xcresult and points to stale test_output.txt. Fix its exact-result handoff with a regression; do not use stale logs. Also inspect manual+Cloudflare automatic analytics beacon coexistence before assuming event counts are deduplicated. No claim of duplicate events yet.


## 2026-09-07 01:47 ET — Workspace minimum verified in signed runtime

- One-line native SwiftUI minimum passed the unchanged restored-license-window regression1/1. Signed workflowd5c07c3b6092d705ed7e3b790ca999e8 built and launched current source with a live log attached before launch.
- Clean private screenshots01:43:54 (1040x772) and01:45:15 (800x552) in outputs/portfolio-guide-facts-final-20260907 were inspected: readable action descriptions, switches and sidebar; long lists scroll at the viewport boundary. A400x300 resize request was clamped to800x552; Peekaboo reported it did not reach the deliberately invalid requested size, and fresh AX read-back proved the expected minimum. Restored1040x772 before normal Quit.
- Runtime log receipt outputs/runtime-logs/20260907T054232Z-20260907-67091-tu9gww/receipt.json stopped05:46:07Z/app_exited. App67269/log67266/supervisor67265 are absent. Python prompt-resolution screenshots01:36/01:38 are private permission evidence only.
- Source commit/full pre-push suite/public guide deployment are next. No native version bump, ZIP release, LS change or full customer-workflow clearance claimed.


## 2026-09-07 01:42 ET — Push gate found a real workspace minimum-size bug

- Guide-copy commit3ad3edb remains local on Mini; origin/main and Air HEAD remain662e655. Pre-push failed only VisualVerificationRenderTests/workspaceReleasesLicenseSizedWindow: content expanded1040px but NSWindow.minSize.width was474 instead of800. Current failing log and xcresult: outputs/verify/20260907T053001.274269Z-63206-f60922cc/. The wrapper's advice to use test_output.txt was wrong; that file was from July.
- NSHostingController defaults to standardBounds and updates window contentMinSize from SwiftUI (Apple docs https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions, verified with installed SDK). ContentView lacked a SwiftUI minimum. One native .frame(minWidth:800,minHeight:500) now expresses the same workspace minimum as the shared window helper; source matches both machines. Existing regression unchanged and passed1/1, workflow4f4faad84f7b75262918b0daac32603f, outputs/monitor-tests/20260907T054044.561720Z-65784-53854eb1/receipt.json. Signed runtime/visual and full pre-push verification pending.
- First focused command selected zero tests because Swift Testing's exact selector needs trailing parentheses; monitor_tests correctly rejected it. The app's scripts/SaneMaster.rb is a shell wrapper, so invoke directly, not via ruby. Preserve both failure logs in portfolio-guide-facts-final-20260907.
- Private clean Mini screenshot01:36 showed a Python local-network prompt. Native Allow clicked under owner standing authorization; screenshot01:38 confirms prompt gone. This is consent read-back, not a fresh Python network-feature test. Signed-in Mini Brave preserved. Preview PID60504 is absent. Air guard renewed until17:41Z without changing lock/logout preferences.
- Broader goal remains active. Do not call native release or guides deployed until remaining proof succeeds.


## 2026-09-07 01:17 ET — Guide factual corrections ready to publish

- Rewrote three existing guide articles (batch rename, image conversion and photo metadata) to describe real outcomes without unsupported negative comparisons. Updated guide cards, titles/descriptions/JSON-LD/dateModified and readable source-link styling. Kept existing layout.
- Traced native execution through ScriptExecutor, AppStoreNativeAction and Media executor. Remove Photo Info writes a unique _clean sibling, leaves the original metadata intact, uses ImageIO rather than sips, and does not guarantee unchanged quality or zero technical metadata. Conversion creates a still image from the first frame and writes a new sibling. Current native media implementation dates to June29, before public1.3.3; existing197-test suite includes real GPS/UserComment/make/model removal and conversion fixtures.
- Current Apple primary guides confirm Finder text replacement/numbered formats and Preview batch conversion. Links and lasting claim constraints are in ARCHITECTURE.md, which also replaces stale no-telemetry and DMG release wording. Public copy describes limitations without implying a new native feature.
- Eight clean screenshots inspected: outputs/portfolio-guide-facts-final-20260907 (three articles desktop/375) and outputs/portfolio-guide-facts-20260907/guides-{desktop,375}. Each receipt records the visual verdict. Earlier article captures with default dark-blue source links are superseded.
- Preview layout checks passed14 page/viewport cases. Shared SEO tests10/10 and95-page audit pass. Source edits match both machines; direct-main commit/push and canonical website deploy/live proof next. No native code, version, LS or permissions changes.
- Separate remaining risks: exact native full-workflow release coverage remains open; direct rename scripts report completion even when mv -n skips name collisions, and sequence rename needs extensionless/conflict testing. Do not infer every batch item changed from its notification. Continue full portfolio audit.

## 2026-09-07 01:00 ET — SaneClick website published and public proof passed

- Commit 662e6552eb2533a40bfe3c34d55e540869281bf7 pushed directly to main with no new PR. Required pre-push native verification passed 197 tests in 22 suites; log apps/SaneClick/outputs/portfolio-web-layout-20260907/push.log. Air fast-forwarded after preserving its identical pending diff in stash portfolio-click-website-before-main-sync-20260907; both hosts reached the same clean source commit before this receipt update.
- Canonical release.sh --website-only succeeded without Keychain prompts. Cloudflare Pages deployment https://20d02d90.saneclick-site.pages.dev serves saneclick.com. Appcast/manual download route verified at existing public 1.3.3; no native binary or LS upload was changed.
- Public layout-live.json passed all 14 page/viewport assertions: H1 clear of nav, no horizontal page overflow, Donate destination and pink fill correct. Six guide HTML responses are byte-identical to source. Homepage becomes exactly identical after decoding Cloudflare's two email hrefs/one email span and removing its exact email-decode script; no other transform. See live-source-parity.json and deploy.log.
- Actual desktop and 375px Donate clicks from the preview reached https://github.com/sponsors/MrSaneApps with the correct Sponsor title and account visible (donate-clicks.json). Final 14 inspected screenshots remain in the directories recorded below; these are private QA.
- Shared SEO tooling files now match Air/Mini; tests 10/10 and local audit 95 pages pass. Their changes remain uncommitted in the existing SaneProcess portfolio branch alongside prior work; preserve and review that full branch before a direct-main integration.
- Preview server PID55156 stopped deliberately after verification; earlier PID51190 also stopped. Both owned SSH sessions ended. No native QA app remains from this website lane. Signed-in Mini Brave session untouched.
- Next: continue remaining SaneClick native eight-action workflow/fresh-install coverage and bump/release only after gates pass; audit guide factual copy against current native/shell behavior (Finder rename, Preview export, image/EXIF claims). Continue other portfolio runtime/iPad/release/LS/machine-sync lanes. Overall goal remains active, not complete.

## 2026-09-07 00:55 ET — Website defects fixed and verified; deploy pending

- Corrected six live Donate anchors from product checkout to GitHub Sponsors, kept heart interiors pink, removed six zero-telemetry slogans contradicting disclosed aggregate counts, and removed the redundant blanket on-device comparison row/metadata wording.
- Five guide titles were hidden behind fixed navigation. A real Mini browser regression failed headingTop 0 < navBottom 88.84. Existing article.container selectors now preserve vertical padding; mobile top spacing accommodates wrapped navigation. Fourteen desktop/mobile layout checks pass, including no horizontal page overflow and correct Donate URL/pink fill.
- Fourteen clean final page/viewport images inspected: outputs/portfolio-web-layout-20260907 (five guides and homepage at desktop/375, reduced motion) plus outputs/portfolio-web-final-20260907/guides-{desktop,375}. Each receipt records the actual visual verdict. Old guide captures with clipped titles are superseded. Homepage scroll animations hide offscreen content in full-page no-preference captures; reduced-motion captures show it. Mobile comparison tables scroll inside containers.
- Runnable check and before/after JSON: outputs/portfolio-web-final-20260907/check-layout.cjs and layout-{before,after}.json. Shared SEO audit passed 10 tests and 95 pages across its eight configured sites. It now catches Donate links aimed at SaneApps /buy routes and accepts the configured SaneScan social-card.png while rejecting paths outside the site. The two shared audit files match Air/Mini.
- This is scoped link/layout/privacy-copy verification, not a full factual clearance of historical guide and competitor claims. Guide wording about Finder rename, Preview batch export and sips metadata removal needs a source/current-runtime content audit. Native release and broader portfolio work remain pending.
- Website commit/push/deploy and live read-back remain next. No native artifact or LS upload changed.

## 2026-09-07 00:27 ET — Native fixes pushed; Air and Mini source aligned

- Direct-main push succeeded: SaneClick2ecc816bc22ff827e31e0b0a8f6e7fa66e27ba04. Remote refs/heads/main independently read back at that SHA. No PR created. Git pre-push ran the canonical full suite again:197 tests/22 suites PASS, workflow c612944566bcd38c5c9e5e739e4476e7, outputs/verify/20260907T042332.348342Z-48907-c4de2050/01-test.log.
- Pre-commit lint removed one extra blank line in VisualVerificationRenderTests; pre-push tested the committed result. The 12 committed files include shared SaneUI pins, native fixes/tests and documentation. Seven website files remain uncommitted.
- Air fast-forwarded from580316e throughd0bd558 to2ecc816. Preserved previous Air work in recoverable stash6a718ed40f70dd51bf02909ea5652e379692c4a9 (portfolio-click-before-main-sync-20260907). Reapplied its website-only patch and brought the new header heart to the same pink as Mini. All19 touched files had identical SHA256 on both hosts after sync.
- Five Finder category actions and stopped runtime are recorded in finder-action-verification.json. Existing broad workflow/release tasks and guide Donate-link repair remain open. Source push is not an app or website release.


## 2026-09-07 00:23 ET — Five real Finder categories verified; source ready for main

- Actual Finder context-menu clicks passed one representative action in every category: Duplicate with Timestamp, Replace Spaces with Underscores, Convert to JPEG, Format JSON and Create SHA256 File. Byte/hash, rename, JSON-content and image-format/dimension assertions all passed. No IPC request was injected.
- Ten clean inspected menu/result screenshots and hashes are recorded in infra/SaneProcess/outputs/portfolio-review-20260906/click-settings-visual/finder-action-verification.json on both machines. Private QA only. Disposable inputs/results moved from Downloads/saneclick-portfolio-agyztmt6 to finder-artifacts in that output directory; the fixture Finder window is closed.
- Normal Quit stopped the signed runtime at2026-09-07T04:21:06.420063Z/app_exited; app36850/log36846/supervisor36845 are absent. Live capture ran before launch through the actual actions. The capture records system/app activity; action proof is the observed menu selection plus independently verified file results.
- Full197-tests/22-suites pass and native source/config/test/doc hashes match Air/Mini. Reviewed native change is ready for a direct-main commit/push under owner authorization. No version bump or app release is claimed; complete the remaining eight-action workflow and release gates before publication.
- SaneProcess native screenshot runner fix passed38 checks and actual open-menu capture. Production fix reuses restoreBundleID and skips focus changes when already frontmost. Updated SCREENSHOT_TOOLS.md supersedes old advice calling native GUI capture unreliable. These shared tooling changes remain uncommitted among prior portfolio changes.
- Newly found website bug: docs/guides.html Donate links to app checkout. Audit sibling guide Donate anchors, correct to the established Sponsor destination and verify before website release. Existing pink-heart website changes remain outside the native source commit. AgentMemory bf6461db-80cc-424d-8aa8-97577266fe45 tracks this open issue.
- Remaining portfolio work continues; this is neither full customer-workflow clearance nor overall completion.


## 2026-09-07 00:06 ET — Full suite and first real Finder action passed

- Full canonical SaneClick verification passed 197 tests in 22 suites, workflow 0e0948e97ebcc0e5a790ca70828270ea. First run failed only three expected-pin assertions in AppStoreReviewGuardrailTests; updated expected SaneUI revision to reviewed 60176f3 on both machines. Entitlement assertions unchanged. Logs: infra/SaneProcess/outputs/portfolio-review-20260906/click-settings-visual/release-suite{-final,}.log.
- Signed runtime workflow 0cac366762f9e86e823d7ec113498e0e is ACTIVE; live log/receipt apps/SaneClick/outputs/runtime-logs/20260907T035034Z-20260906-36540-gv6zqt. Deadline04:50:34Z. Must normal-quit and verify owned log processes stop when finished.
- Actual Finder menu Essentials > Duplicate with Timestamp clicked at04:04:53Z on disposable Downloads/saneclick-portfolio-agyztmt6/Example File.txt. Created Example File_20260907_000454.txt; bytes and SHA256638aa9bb72ac58f87324a7bf8c64524e86d51f6493118f9e7a8e010e01330f78 match original. Clean inspected private screenshots00-04-01(menu) and00-05-27(result).
- Found screenshot GUI launcher stalling120s after successful capture because redundant Finder activate waits while Finder tracks an open menu. Existing restoreBundleID helper now returns immediately for already-frontmost process; default Finder focus reuses that helper. Mini38/38 GUI runner checks pass and canonical screenshot00-02-47 returned0 preserving menu. Two-line production fix + existing test expectation updated on Air/Mini. AgentMemory f5c174b2-46c7-4658-a572-daf20ebd7280.
- Peekaboo AX tree omits Finder context-menu items. Inspected screenshots provide real coordinates. Use global foreground --no-auto-focus for click/move; automatic focus dismisses menu. Do not treat IPC helper as menu proof. Four category actions, full8-action coverage, version bump and release remain pending. No public release or LS change.


## 2026-09-06 23:44 ET — Script runner and modal fixes verified

- Fixed an inherited-output-pipe hang in ScriptExecutor. A regression failed against the previous code after waiting 4.034 seconds for a background child. The shared runner now allows two seconds to drain both pipes after the command exits, then reports incomplete output. Running-command duration and output-memory limits are unchanged.
- Removed the editor's duplicate Bash/AppleScript runners. Editor Test now uses the same methods as Finder, drains large output concurrently and preserves the first selected path. Mini ScriptExecutorTests passed 30/30: outputs/monitor-tests/20260907T032343.491008Z-26533-2f96f927/receipt.json; workflow 665c2965af6aff30b0e7824dad9a693e.
- Actual editor Test produced the expected background-output error and a successful selected-folder result. Result Close and editor Cancel worked. No custom action was saved or owner action executed.
- Custom Actions lacked a visible close control, although Escape worked. Added native Done; its actual AXIdentifier closeCustomActionsButton click closed the sheet. Error text is now bright white on its red background. Import/Export subtitle is complete.
- Final signed build/runtime workflow 37c70102cd90fc120f5c3d13fb0acad4 passed. Clean inspected screenshots: 23-38-03 (Done), 23-39-54 (expanded sidebar), 23-42-13 (final error); 23-35-06 proves successful editor output. All are private QA, under infra/SaneProcess/outputs/portfolio-review-20260906/click-settings-visual on both machines.
- runner-and-modal-verification.json records source hashes, tests and visual verdicts. Five source/test files are identical on Air/Mini. Final runtime receipt outputs/runtime-logs/20260907T033652Z-20260906-30840-ejhaq6/receipt.json stopped at 2026-09-07T03:43:17.094240Z with app_exited; app and owned log processes are absent.
- Shared AgentMemory fact 495992ce-c3f9-4c8a-8057-929534dd1773 records the fixes, superseding the initial pending bug. Full eight-action Finder workflow, release gates, version bump and public release remain open. These app changes are not yet committed or released. Broad portfolio goal remains active.

## 2026-09-06 23:24 ET — Dormant release live; GitHub defaults and SaneCite checkout parity verified

- Default stored GitHub credentials on both Air and Mini independently authenticated as MrSaneApps with GH_TOKEN, GITHUB_TOKEN and GH_CONFIG_DIR removed. Native gh login used existing approved credentials without an OS prompt or ACL change. Host and peer receipts remain at infra/SaneProcess/outputs/portfolio-review-20260906/github-default-auth*.json.
- Owner authorized verified direct pushes to main instead of new PRs. Exact reviewed code67339ce35e4bf88a0bf78150641243bc4973789f passed CI34078513417 and was pushed to main without force. Existing PR8 became merged automatically.
- Production run34078753180 passed verify and deploy at2026-09-07T03:15:18Z. Worker versionfcb65866-aa50-4e54-8acd-5808792905f9 serves exact code67339ce; parser applicationversion108 converged to reviewed source02a126a8 and immutable digestsha256:c8145b48e90ca74274f49aed9bf231384c32aee453fe3e0adba65514ca501384.
- CI and a separate Mini check:live -- --allow-dormant passed the explicit paused-configuration proof. Public health returned200 with ai_enabled:false and no public build SHA. AI remains off and release configuration retains only03:00UTC retention. Model quality and parser serving behavior were deliberately not exercised; activation/campaign readiness still needs full active proof. Python urllib received403 on an optional public probe; the standard Node fetch returned200. No pricing, billing or outreach changed.
- Both canonical SaneCite main checkouts fast-forwarded to67339ce with clean source. Prior policy/dormancy edits are covered by reviewed main. Each host retains a recoverable git stash and full original files/patch/handoff at q3-repair/canonical-sync-20260907; receipt.json records before/after hashes and stash IDs. Do not blindly reapply those superseded changes.
- Production manifest, image/Worker attestation and source receipts are at q3-repair/dormancy-production-proof; fresh live proof is dormancy-production-live-proof.log. This handoff-only follow-up does not redeploy the service.
- Broad portfolio goal remains active. Remaining native/iPad workflows, public app releases, Lemon Squeezy replacement cleanup and full portfolio machine reconciliation are not complete. Historical parser mismatch cause remains unproven; current paired configuration and serving Worker identity are verified.

## 2026-09-06 23:08 ET — GitHub defaults fixed; direct-main release pending CI

- Owner explicitly requested correct default GitHub tokens on both machines and verified direct-main pushes instead of new PRs. Both default gh logins were refreshed with native gh auth login using already-approved cached credentials. Separate fresh gh api user calls with GH_TOKEN, GITHUB_TOKEN and GH_CONFIG_DIR removed returned MrSaneApps on both. No authorization prompt or security ACL change. Receipts: github-default-auth.json on each host, with the peer receipt copied as github-default-auth-mini.json on Air and github-default-auth-air.json on Mini under the portfolio output directory.
- SaneClick caption is now corrected on both machines: complete 1 custom action text replaces the truncated redundant subtitle. Signed canonical workflow eeaf44dd11bfa17feff7bbc5b82f8944 passed build; clean Mini screenshot22:59:32 was inspected. Normal Quit ended its live log at03:00:40.107007Z/app_exited. Updated settings-visual-verification.json and screenshot are saved on both hosts. Full eight-action workflow and public release remain open.
- SaneCite branch67339ce35e4bf88a0bf78150641243bc4973789f is clean and pushed. Previous722e605 full CI passed; latest CI34078513417 is in progress. Latest change reuses an already-published parser image by immutable digest, rejects malformed inventory and validates image source/manifest before Worker deployment. Twenty-one delivery tests passed, and the archived actual image passes the pre-deployment validator.
- After exact latest-head full CI succeeds, push reviewed branch commits directly to main and observe canonical production deployment. PR8 already exists and should close when commits land. Target is safely dormant configuration, not customer activation. Source guard prevents status/selfcheck/old crons/dashboard warming from starting expensive work; campaign readiness still rejects dormant mode. No pricing, campaign or billing changes.
- Historical parser mismatch cause remains uncertain: saved rollout completed23:06:59Z before failed health check23:07:19–23:08:23Z. New authenticated cheap health proof binds the serving Worker before expensive checks, addressing the previous missing evidence. Do not call the historical mismatch confirmed fixed or claim active parser/model quality from a dormant release.
- Shared AgentMemory c4186f45-7c94-484a-af2b-e7252f2e76a5/revision1270 records credential and caption completion. Broad portfolio goal stays active; other native/iPad, LS and full machine reconciliation remain open.

## 2026-09-06 22:52 ET — SaneCite dormant runtime draft PR

- Draft PR https://github.com/MrSaneApps/sanecite-saas/pull/8 contains the dormant runtime and paired recovery changes. Branch fix/dormant-runtime-recovery-20260906 starts at current main3e9c3f4; commit8f9bbb6 passed full GitHub Actions verify run34077442679 (deploy correctly skipped). Follow-up c793ca2 adds actual desktop/mobile paused-status browser coverage; its fresh CI result is pending.
- Mini tests: 150 Node tests,13 parser regression groups and62 real SQLite isolation probes passed. Twenty delivery tests include a real local CLI/server test proving dormant release verification sends only health/selfcheck requests and campaign readiness refuses dormant mode.
- Separate NVM24.18.0/npm11.16.0 installed from nodejs.org with checksum verification for the exact CI pin; Homebrew24.20.0 remains installed. Local pinned predeploy stopped at required Docker proof; no skip flag or Mini Docker startup. CI performed container/artifact/browser proof.
- Mini Brave browser runner passed79 checks and exited normally. Both private QA paused-status images inspected at1440x1000 and390x844: clear heading/status labels, bright readable text, no clipping/overlap, responsive rows and support link. Image paths: candidate/output/playwright/human-e2e-2026-09-07T02-48-52-947Z/private-qa-paused-status-{desktop,mobile}.png; Air copies under q3-repair/dormancy-browser-proof. These are local paused-state QA assets, never public marketing images.
- Live remains the old restored Worker/parser pair plus retention-only schedule correction. No new runtime deployment, price change or campaign send. The earlier parser runtime identity mismatch still needs diagnosis before merge/deploy. Candidate code now prevents stale scheduled events, dashboard warming and public status/selfcheck from waking the parser while dormant, and preserves exact AI mode during recovery.
- Existing cached GITHUB_TOKEN works. Default gh account token is invalid; no login/ACL/token-store changes were made. Cloud AgentMemory fact76b44f04-cabe-4798-8e4e-925388cb88ae/revision1269 records this source-versus-live distinction.
- Portfolio goal remains active. Click custom-actions caption, other app/iPad workflows, release/LS replacements and complete machine reconciliation remain open.

## 2026-09-06 22:20 ET — Owner confirms intentional dormancy; $99 offer under review

- Owner clarified that SaneCite was deliberately dormant to avoid spending credits with no users. Today's recovery deployment had restored daily AI checks and parser keep-warm schedules; the August dormant-mode changes were still outside the release candidate.
- Live schedules corrected and separately read back: only the 03:00 UTC retention job remains. Receipts: infra/SaneProcess/outputs/portfolio-review-20260906/q3-repair/dormancy-schedules-{before,applied,after}.json. This stops scheduled AI checks and keep-warm work; it does not prove all possible AI requests or all platform charges are disabled.
- Existing isolated security-release-candidate now contains the central fail-closed SANECITE_AI_ENABLED guard, default off, retention-only configuration and a regression proving zero inference/meter calls while disabled. Route tests passed 54/54; diff check passed. Source correction is NOT deployed. Pair-recovery tooling and dormant-aware release checks remain unfinished. Do not run live AI selfchecks or parser warming while dormant.
- Recommended experiment: $99/month, month to month, first real questionnaire free, an internal usage-cost ceiling, and a small group of prior prospects before expanding. No prices, billing products or emails changed. Exact campaign text/recipients are not approved. Prior three-subject campaign audit returned zero records; this does not establish that no earlier outreach or responses exist. Reconcile historical roster, delivery and suppression before selecting recipients.
- Cloud AgentMemory correction saved as 650d2ab4-d486-4af5-86af-2ecc422beaef, revision 1268. The earlier August handoff's claim of deployed dormancy is superseded by the verified live/source distinction above.

## 2026-09-06 22:20 ET — Settings proof saved; remaining main caption

- Native license-sized workspace regression passed 1/1 after correcting the test to yield for SwiftUI mounting; original assertions remain intact. Canonical workflow 0ebdb354b8e09d40a18d817d6a184c0a. Initial synchronous fixture failed and is retained as evidence.
- Final signed native workflow 098ba9054636292aa2d536e4a4391cb9 showed the main window at 1040x772 and after resize to 800x650. White counts and wrapped descriptions are visible. One custom-actions subtitle still truncates; shorten the redundant wording and inspect a fresh build before clearing that main view.
- All five settings pages and scrolled General/About bottoms were inspected. Actual Refresh returned Extension Active; paid License was recognized; both Donate hearts are pink. Nine-image receipt and screenshots match both hosts at infra/SaneProcess/outputs/portfolio-review-20260906/click-settings-visual/settings-visual-verification.json.
- Normal Quit ended final runtime capture at 2026-09-07T02:08:19.065827Z with app_exited. No Click test app/log remains active. Full Finder action coverage and public release are still open; current modified 1.3.3 must be version-bumped before release.

- AgentMemory is now confirmed healthy through the Cloud MCP path. Hosts closure saved as 680fecb5-8a47-429f-b560-508a330d763d, revision 1267. Earlier timeout cause remains unknown. Local legacy AgentMemory runtime and old documentation are not proof of the active Cloud path.
- Portfolio goal remains active and incomplete. No further delegation attempted after account-limit failures. Continue serially; preserve signed-in Mini Brave and existing macOS permissions.

## 2026-09-06 21:54 ET active SaneClick visual repair

- Canonical shared60176f3 signed build initially reopened main at520x712 and visibly crushed action names/descriptions (private screenshot click-settings-visual/codex-shot-2026-09-06_21-43-12.png). Cause: LicenseGateView fits520px native canvas; ContentView lacked the existing shared workspace release. Added saneWindowContentSize1040x720,hugging:false and wrapped descriptions. Actual next signed workflowf8a1bed6dfcd64cacf11a50254c47a8d/main AX1040x772 and inspected21:48:12 shows complete descriptions. Live capture apps/SaneClick/outputs/runtime-logs/20260907T014713Z-20260906-95949-x7g3p1 remains active, deadline02:47:13Z; currentPID96195.
- Three dependency pins and four settings scrollbars upgraded, folder paths wrap. Native General top/bottom inspected900x592; actual Refresh returned Extension Active; all five original monitored folders remain visible. Paid license recognized automatically at startup. No Finder restart, folder delete, action toggle or script execution performed.
- Sidebar subtitle wrap/white counts prepared but not in current runtime. Actual NSWindow regression added to existing VisualVerificationRenderTests/workspaceReleasesLicenseSizedWindow; tests and final sidebar build/visual proof PENDING. Source edits match both machines. One intermediate edit assertion stopped before SettingsView because two row types own successGreen; corrected scoped CategoryRow edit after inspection. Backups and scoped manifests under click-settings-visual.
- Launch guard stale messages wrongly instructed automatic TCC reset; five comment/message corrections applied on both machines while preserving existing host differences. Mini dispatcher tests20/20 passed in launch-guard-message-tests.log. No guard logic changed.
- AgentMemory Hosts closure save timed out after300s; durability unconfirmed, no repeat save. Hosts closure handoffs and five-image receipts are saved on both machines. Need repair/verify memory service before claiming shared memory updated.
- Sibling scan: SaneSync also swaps LicenseGateView into main scene and has no saneWindowContentSize call; inspect native sizing in that lane. Clip uses a separate gate window; Video/Sales have no LicenseGateView call. Portfolio remains active and incomplete.

## 2026-09-06 21:40 ET SaneHosts settings and profile proof

- SaneHosts shared60176f3 settings General, paid License and About top/bottom are visually inspected at720x600. Profile readability fix removes repeated Login Items instructions from the active summary and attaches them to both protection action buttons; remaining explanation is13pt and wraps. Actual rebuilt profile900x702 inspected21:29:11; active action AXHelp contains the intended setup instructions. No protection action clicked.
- Final canonical package monitor3af462f0698806827ebb6134a1b4432b passed125/125, selected18 MainViewGatePolicyTests, with continuous log capture. Signed native workflow3c01e9eada956616815e8e415b1ad372 logged before launch and ended by normal Quit01:37:35.039557Z/app_exited. Source/test changes match Air/Mini; four shared-pin files match exactly and package-lock originHash stays host-specific. System hosts hash matches baseline6a3d6fabff8d8a510a11a2d9364aac6e9cde15c6794fe93b7c95e7efa3718056.
- Five-image scoped receipt on both hosts: infra/SaneProcess/outputs/portfolio-review-20260906/hosts-settings-visual/settings-visual-verification.json. Startup log confirmed helper already enabled and paid license valid; no new authorization or permission mutation. Earlier launchctl/sfltool uncertainty is superseded for this actual enabled-helper startup.
- No Hosts test app/log remains. This is local modified1.1.25/1125, not a public release; bump before publishing. Full eleven-action workflow remains open. Portfolio goal remains active; next native lane is SaneClick, then remaining app/iPad and process/release gaps in this handoff. No retry of quota-blocked agents.

## 2026-09-06 21:10 ET active resume

- Video shared60176f3 is now BUILT and visually verified across all eight settings tabs at720x600, with About scrolled to its full bottom. Privacy & AI20:41:20 has complete, non-repeated paragraphs and all actions visible. Current9-image follow-up, hashes and actual Manage API Keys navigation are in video-runtime-20260906/settings-visual-verification.json (adaptive_shared_followup), exact Air/Mini. Normal Quit ended workflowe04d5489dbd822dfcadbbf43b22e9513/PID70560 at00:57:16.726877Z; live log began before launch and survived through exit. Both old valid media fixtures still match exact hashes. No public1.0.5 release.
- Clip current18-image settings receipt and3/3 focused policy tests remain verified; all app/action/iOS and release coverage remains open. Its native app/log ended normally as recorded20:38.
- Hosts five scoped files now select published60176f3 on both machines. Existing obsolete No spying copy guard now checks actual No personal-content upload wording. Canonical package monitor97fa1ae9c76f322c60145ccb39631837:125/125 passed, six selected NavigationSourceTests matched. This is package test evidence, not live customer UI; no dedicated live unified-log stream was attached to that package run. Receipt apps/SaneHosts/outputs/monitor-tests/20260907T010306.515057Z-79784-3309e5ce/receipt.json. Both host backups/manifests under hosts-settings-visual; Package.resolved differs only in originHash, pins match.
- Hosts signed native launch is IN PROGRESS (hosts-settings-visual/signed-launch.log and adjacent status). Before launch, launchctl did not find system/com.mrsane.SaneHostsHelper; sfltool dumpbtm required administrator authorization and stopped with -60007, no retries/elevation. Clean desktop21:01:10 inspected: no OS prompt present. This does not establish exact SMAppService approval status. App startup may open Login Items if helper approval is needed; inspect promptly, preserve platform gate. No helper permission was changed by diagnostics.
- No active Clip/Video app or test remains. Hosts is the only pending native build/runtime lane. All three original agents stopped on account usage limits; root continues serially without quota-bypass retries.
- Remaining portfolio priorities: current Hosts/Click/Sales/Scan/native and iPad proof, SaneCite paired recovery publication and failed new-parser rollout diagnosis, unfinished Sync intent/bootstrap safety, actual LS file replacements after release proof, final scoped machine reconciliation and report. Goal remains ACTIVE, not complete.

## 2026-09-06 20:38 ET Clip settings review and Video rebuild

- Clip settings evidence is now saved as clip-settings-visual/settings-visual-verification.json under this portfolio output directory on both hosts. Eighteen inspected image entries include complete Shortcuts/Sync scroll coverage, Storage, paid License, About with both pink Donate hearts, General sections and Snippet draft/empty-search states. Scope remains settings visual review and the actual recorded safe actions, not all app actions or release clearance.
- Actual Settings close button removed all windows while Clip remained running. Separate normal Quit ended PID47588 and its original runtime capture at2026-09-07T00:35:48.316900Z, stop_reason app_exited. No Clip test surface remains active.
- SettingsColorTests stale green-text assertion updated to white permission text; excluded-app colored status icon policy retained. Mini canonical focused verify passed3/3, workflowedcb0a77f963be796d42f3f01073d69c. These are source-policy assertions, not behavioral visual proof. Continuous test capture ready00:35:48.846267Z survived through explicit stop00:36:30.256120Z. Existing fixture runner now rejects unhealthy final log state. Source/test hashes match Air and Mini; diff --check passes.
- Video shared60176f3 rebuild is in progress via canonical GUI launch. It detected the newer Package.resolved and correctly rejected the old binary. Log video-settings-layout-patches/adaptive-shared-launch.log, status adjacent. New runtime and current Privacy & AI inspection pending; prior verified screenshots remain historical.
- No public app release, LS upload/removal, new OS grant, TCC reset, or credential change in this phase. The portfolio goal remains incomplete.

## 2026-09-06 20:23 ET active verification

- SaneClip signed Release 2.3.24/2324 now runs shared SaneUI 60176f3, PID 47588, workflow 465a6551b519a8b616ae64178e180b63. Continuous log was ready 23:58:42.258539Z before launch 23:58:42.640216Z: apps/SaneClip/outputs/runtime-logs/20260906T235842Z-20260906-47092-3mv5qc/live.log; bounded deadline 00:58:42Z. This supersedes earlier pending-build entries.
- Current native proof under infra/SaneProcess/outputs/portfolio-review-20260906/clip-settings-visual/: 19-45-51 full Per-app paste mode after shared adaptive layout; 20-03-19 real search p gives No Results and bottom-aligned 0 of 3 snippets; clear button restores list. 20-10-23 filled draft has enabled Save; 20-12-08 bottom scroll exposes complete live Preview. Actual Cancel removed sheet and preserved three saved snippets. Save was not clicked. 20-15-13 confirms list bottom reachable; 20-17-12 confirms current Shortcuts top. All named images inspected. Snippet list uses normal scrolling with sticky category header; upper offscreen row is not a full-row screenshot. Further tab checks are active.
- SaneClip SnippetsSettingsView now has white Search label, wrapped instructions, full-height empty results, filtered count, shared editor buttons/background and 520pt minimum. General Granted status is white. Scoped source/pins synchronized with backups; unrelated owner changes preserved. No public Clip release.
- Peekaboo 4.3.1 installed on Mini and Air from official openclaw/tap. Mini retains prior signing team and observed grants; Air old unmanaged 3.4.0 binary retained in portfolio output before install. Air GUI/permissions were not exercised. Dependency baseline now preserves qualified tap names; Mini 31 tests pass, both host checks PASS. No TCC resets or permission requests. Manual Mini helper PID 51635 stopped; auto helper has bounded idle exit.
- SaneCite exact prior Worker/parser pair remains the last verified live state (19:27 entry); newer release remains unshipped. Paired recovery tool/workflow/tests are still unpublished candidate changes. Video is source-pinned 60176f3 but has not rebuilt since prior verified 5931685 run.
- Portfolio goal remains active. Three delegated agents stopped on account usage limits; continue root work without retrying delegation to bypass limits. All-app, release, full action coverage and complete Air/Mini parity remain unproven.

## 2026-09-06 19:42 ET active shared layout correction

- Shared SaneUI60176f30007e0f931195785aa769e4ef5172f7ee is published and synchronized to Air. CompactRow uses native ViewThatFits: full label beside controls when space permits, label above controls when crowded. CompactToggle labels wrap. Native400pt-vs700pt layout regression passes fixed source and fails old source; complete152tests/29suites pass. Two unchanged onboarding-copy/donation assertions were stale and updated; the former source assertion banning vertical wrapping was superseded by the native regression.
- Actual Clip760x532 General screenshot19:28:26 exposed truncated Per-app paste mode, motivating shared root repair. General sections at scroll0.43,0.65,0.85,1 were inspected; no security/history settings changed. Source status text is now white. Clip search now uses a visible white Search label because native placeholder ignored explicit white prompt. Snippet Add sheet was opened, scrolled to bottom and Cancel clicked; zero sheets afterward, no saved snippet changes. Editor shared style,520pt minimum and scroll indicators prepared for verification.
- Clip old PID24822/log3c0df2a3062011b78d2e3f35b61c488d ended normally23:40:45.432Z. New signed Release launch is building via canonical wrapper, log file infra/SaneProcess/outputs/portfolio-review-20260906/clip-settings-visual/adaptive-release-launch.log. Actual new UI proof pending; no public Clip2.3.24 release.
- Clip/Video source pins now60176f3 on both machines. Video has not rebuilt after its verified5931685 settings run; no claim of current601 runtime. Air per-file before backups and hashes in clip-settings-visual/air-adaptive-sync.json; unrelated metadata preserved.

## 2026-09-06 19:27 ET recovery and visual review

- SaneCite production attempt34065679512 failed deep health (parser_current=false); automatic Worker rollback left the new parser. This is superseded by VERIFIED paired recovery: old Workera0d4669c-c6c5-4dea-8fd6-d86a0ca6ee07/build9c0c301d730680ac017c07ba7004ea7f9ce4c881 and parser digest4a047c0f759a729d72001d003df888cf2fd530e941e8ca39c58ce8d8c097948e restored. Rollout9933aad4-b4c5-46d4-97a8-d1dd6aeb7bc4 completed3/3. Public deep health200/current=true; authenticated selfcheck200/pass=true with model, embedding, parser and billing pass. Exact pair verified by existing recovery verifier. Receipts q3-repair/paired-{recovery-verification,selfcheck-final,health-final,rollout-status}.json.
- Existing recovery_state.mjs now has guarded restore-parser; existing delivery suite17/17 passes including PATCH/rollout order, config preservation and no mutation on concurrent image drift. Canonical deploy workflow has paired restore step prepared. These three candidate files are dirty/unpublished on isolated security-release-candidate; initial new-release mismatch root cause still needs investigation. Main3e9c3f4 remains newer than live9c0c301. No repeat deployment authorized by a green local test alone.
- Clip runtime still current PID24822/workflow3c0df2a3062011b78d2e3f35b61c488d; log deadline23:03:39Z+3600s. Final Snippets screenshot19:14:40 inspected: grouped rows no duplicate category chips; search placeholder still rendered gray despite foregroundStyle white (needs native placeholder treatment); last row partly below scroll viewport, bottom still needs actual scroll proof. Final Storage capture in progress. Screens not all cleared.

## 2026-09-06 19:08 ET active portfolio review

- Mini is canonical; all three delegated agents stopped on account usage limit. Root continues. Goal is active and incomplete; no blanket portfolio, release or Air/Mini parity claim.
- Video: all eight settings pages inspected at720x600, actual policy/MIT-license/Donate destinations verified, API Keys confirmation canceled, cache action preserved both valid old media fixtures exactly. Shared license5931685 was built/visually verified18:14. Video is now SOURCE-pinned to newer shared81982cd scrollbar fix; this last pin still needs Video rebuild/runtime after Clip finishes.
- Clip: shared dim text fixed; Sync repeated Status heading changed to Activity, text wraps, image copy shortened; redundant per-row snippet category chips removed, section labels13pt/search prompt white; Storage text explicitly white. Native signed Release rebuilt at23:03:40Z, workflow3c0df2a3062011b78d2e3f35b61c488d, PID24822. Continuous log ready23:03:39.668Z, receipt apps/SaneClip/outputs/runtime-logs/20260906T230339Z-20260906-24011-jef564/receipt.json; expires after3600s or app exit. This is the sole active native GUI test app.
- Clip's previous logged candidate01dab8ed had real General top, full Shortcuts top/bottom, Sync top/bottom, Snippets visible portion, complete Storage/paid Licensed panel, About top inspected. Paid license recognized without resetting/re-entering it. Actual red close button removed Settings while app stayed alive; subsequent normal Quit ended old log23:01:49.660Z. Final new screenshots still in progress; do not claim all Clip flows or a public2.3.24 release.
- Shared SaneUI81982cd6e6f16895aae00859782087aecf25dd44 restores native content scroll indicators in existing SaneSettingsPage (one line, sidebar unchanged). Published and exact Air/Mini;3 existing package tests pass. Before, Clip About exposed no AX scrollbar; rebuilt About exposes settable scrollbar, actual value1 scroll succeeded, screenshot19:05:14 shows complete Links/Donate bottom with filled pink hearts. Physical focus attempts/old absent scrollbar were not successful proof.
- CRITICAL wrapper repair: routine launch previously reset dev-alias Accessibility and attempted stale TCC-row DELETE/tccd restart unconditionally. Removed automatic call and99lines of unused private helpers in test_mode.rb. Updated existing actual launch harness rejects reconciliation; fixed25/25 pass, old-source control23/25 with both launch cases failing exactly at forbidden reconciliation. Both changed files exact Air/Mini. New actual Clip launch has no TCC-repair step. Old ignored command statuses mean actual prior TCC mutation success remains unproven. Separate sane_test repair flags are explicit opt-in and were not used.
- Logged Clip focused regressions: LicenseGateWindowTests1/1 d96013fae7ddd46a74614a6352acdcbd and NonBlockingKeychainServiceTests4/4 e7e0a4646bff332e40b20f6cb415e9b5. Both logs survived until explicit stop after tests, closing the verify-reaper runtime gap.
- Clip reconciliation:12 reviewed source/test/project/pin files exact Air/Mini, with every prior file backed up; .saneprocess unit_dir corrected alone while unrelated Air App Store metadata preserved. PBX semantic comparison proved only version/build, published SaneUI replacement and three reviewed file registrations. Receipts clip-settings-visual/{air-sync,pbx-semantic-diff,source-manifest,followup-manifest,scrollbar-repin}.json.
- Cite PR7 updated head5e1a4afd8eb7335ed076793de2d04ede77ae563d: pypdf6.17.0, parser identity2026-09-06.1-security, Wrangler4.129.0, native macOS test-library/Brave routing, and existing Enterprise schema initialization before fail-closed SSO lookup. Local13 parser groups/142 Node-browser/62 real SQLite/0 npm advisories. PR CI34065204146 fully green; saved predeploy merge tree12f063797ea442d96b1c71f21b8076f43c183531 exactly matches reviewed candidate. Real8page/60row PDF and Worker-parser artifacts verified by CI receipts.
- Cite live Worker remaineda0d4669c-c6c5-4dea-8fd6-d86a0ca6ee07 and main9c0c301 before merge. PR merged23:01:27Z as3e9c3f4d0d962aaa420e4bfe0449114e97c32cb9. Canonical main run34065679512: verify green, deploy IN_PROGRESS at Worker/parser attestation. Do not claim deployment success until final attestation/live/recovery receipts are inspected. No AI activation/billing-policy changes or customer sends.

## 2026-09-06 owner visual-quality correction and current Video proof

- Owner explicitly rejected clipped/repetitive Privacy & AI text and requires every app screen beautiful, readable, non-repetitive and actionable. Actual screenshot15:59:50 shows ellipsized duplicate privacy paragraph. Do not call this screen or the app visually cleared. Prior parent copy-only correction was insufficient; widen to the shared settings layout and all existing tabs. User-stopped narrow review limits any SOP self-rating to5 until honestly reported.
- Canonical Developer ID Release rebuilt and launched workflow160644bd588638b4e47979231653af70 with SaneUI0f04e753. Continuous runtime apps/SaneVideo/outputs/runtime-logs/20260906T194324Z-20260906-53983-b5yn3x was ready19:43:24.790355Z before launch19:43:25.090289Z; appPID55129 quit normally20:04:41.328977Z and capture stopped app_exited.
- Actual Clear Cache button settings.clear_cache was clicked; live UI showed Preview Cache Cleared and actual OK was clicked. Runtime15:48:35.252 confirms preview caches cleared. Both valid old media fixtures remained exact hash/size after startup and action. Receipt: outputs/portfolio-review-20260906/video-runtime-20260906/cache-runtime-verification.json. Retain named fixtures for final rebuilt settings proof.
- Six-file transcription/privacy copy+typography patch is byte-identical Air/Mini under video-settings-copy; compiled in the current Release, but Privacy visual failure above prevents clearance. Sibling PCM native helper has16 real layouts/segmentation combinations plus16 copy-independence assertions, canonical1/1 passed; exact5-file parity under audio-pointer-audit. Live microphone/silence-removal flow remains unverified.
- Current slots: work_guard_review owns Video shared-settings parity/layout/copy source, no app tests; portfolio_tools_skills owns Clip focused pin/gate tests after Video quit; portfolio_config_sync owns validated SaneCite fail-closed security repair and isolated production-baseline release proposal, no deploy yet. Parent owns next serial visual runtime.
- Peekaboo4.3.0 targeted scroll refused exact focus despite AX confirming General; target+no-auto-focus is invalid. No permission prompt was present. Official targetless foreground scroll requires confirmed pointer inside desired pane;4.3.1 has unchanged focus logic. Do not treat an update as a proved fix or blindly retry. Details Q11/peekaboo-scroll-diagnosis.
- Q2/Q4/Q5 sampled reports now exist; Q3 source review confirmed two live SaneCite early-query fail-open branches. Focused7scenarios and full105Node tests pass locally; original-code controls fail as expected. Deployment requires actual production baseline9c0c301, not dirty MiniHEADcf5e9b4. AI-off live/source discrepancy is still being investigated, not silently changed.


## 2026-09-06 Video cache and PCM regression verified

- Canonical focused class `SaneVideoTests/WaveformServiceTests` passed 10/10 tests with xcresult verification, including real preview-cache isolation and real signed PCM negative-extreme decoding. Receipt: `apps/SaneVideo/outputs/monitor-tests/20260906T192325.856432Z-46736-3a8d6442/receipt.json`. Build and tests completed successfully; no nonempty-output failure occurred.
- Runtime log was ready before the test and stopped afterward: `apps/SaneVideo/outputs/runtime-logs/20260906T192325Z-20260906-46733-f5gwom/receipt.json`, 19:23:25–19:23:51 UTC. The test host exited. The earlier one-test/two-assertion failure remains historical evidence, not the current result.
- Both reserved old valid media fixtures still match their original hashes and sizes after tests. Parent owns the next Release rebuild, real startup preservation check, and actual Preview Cache UI action/visual proof. These tests do not clear full 18-action verification or public release.
- Six-file task-only source patch is synchronized to Air with all before/after hashes matching Mini. Host-local before backups and `air-sync.json` are in `infra/SaneProcess/outputs/portfolio-review-20260906/video-cache-safety-patches/`. Preserve the two startup fixtures until the remaining runtime proof completes.

## 2026-09-06 Video focused cache test and PCM follow-up

- Canonical monitor run `20260906T191340.710091Z-43413-55773e96` compiled and executed one real cache test; two assertions failed by comparing different waveform generations exactly. Media bytes, thumbnail invalidation, and post-clear missing-file behavior passed those checks. The failed monitor receipt incorrectly reports zero tests, while xcodebuild reports one executed with two failures; this is a separate reporting defect.
- Pre-test runtime log `20260906T191340Z-20260906-43410-iwlq3o` was ready before the test and stopped in ensure. Testhost 43789 exited. Clean desktop screenshot15:16:49 was inspected: no app window or native permission dialog. Two reserved startup media fixtures remain hash-identical.
- Current six-file patch now also repairs WaveformService: no escaped rebound pointer; typed PCM16 buffer populated through CMBlockBufferCopyDataBytes handles noncontiguous blocks; Float conversion before abs avoids Int16.min overflow, bounded to1. Existing output contract is signed16-bit interleaved little-endian. Downsampling algorithm unchanged.
- Test compares cached samples to the immediately preceding warm generation. Added real two-second negative-extreme PCM WAV regression, requiring nonempty finite full-scale output and stable regeneration. Corrected focused class rerun passed 10/10; see the current verification entry above. Other audio pointer callers are being audited independently.
- Primary references read2026-09-06: installed Apple SDK CMBlockBuffer.h420–443/491–524 and Swift.org `https://www.swift.org/migration-guide-swift3/se-0107-migrate.html` (rebound pointer must stay inside closure). Cause of original waveform differences is not proved merely by seeing numeric variance.

## 2026-09-06 Video media-preservation repair prepared

- Confirmed source defect: Clear Cache deleted all temporary-directory children; startup also deleted old EnhancedAudio and old/small recordings without proving they were unused. EnhancedAudio URLs are saved in projects. No actual customer data loss was exercised.
- Approved five-file patch is prepared under `infra/SaneProcess/outputs/portfolio-review-20260906/video-cache-safety-patches/`: clear only existing preview caches and await completion, truthful Preview Cache copy/wrapping, remove unsafe startup cleanup. The later six-file patch and focused 10/10 test result supersede this prepared status; actual new startup/UI and release proof remain pending.
- Preserve the two UUID-named old valid media fixtures until parent completes real rebuilt startup proof. Exact paths, hashes and timestamps: `startup-media-fixtures.json` in that folder. They are test-owned; no owner file was modified. Q1 findings and proof limits: `q1-video-ux.md` in portfolio outputs.

## 2026-09-06 rebuilt Video pink candidate proof

- Main-screen Donate heart is VISUALLY VERIFIED pink, with white text, in the newly rebuilt candidate consuming SaneUI `7f425682151792572f0cd7b638ffaad2ec5691ab`. Parent observed fixed canonical launch detect newer Package.resolved, rebuild with Developer ID, then launch workflow `3e6defbe8173dbd62416bfc763ef6e40`.
- Clean parent-inspected screenshots are in `infra/SaneProcess/outputs/portfolio-review-20260906/video-runtime-20260906/`: `codex-shot-2026-09-06_14-47-36.png` (main pink heart), `14-49-15` (General partial view, Temporary Files helper truncated, persisted scroll position), `14-50-55` (License shows Licensed and plain-text Donate without a heart, ample blank space). Full filenames use the same date/prefix. Structured proof: `pink-candidate-verification.json`. General is not fully visually verified; absence from a filtered AX query does not prove Donate inaccessible.
- Continuous runtime receipt/log: `apps/SaneVideo/outputs/runtime-logs/20260906T184638Z-20260906-32396-oqrog9/`. PID 32839 exited at 18:52:07 UTC; saved capture confirms `app_exited`. Source/runtime evidence is a candidate, not a public release.
- Full 18-action customer UI proof, complete settings coverage, release, and verified customer hosted-file replacement/removal remain pending. This supersedes the earlier pink-unbuilt status only for Video; other consumers retain their own proof status.

## 2026-09-06 honest Mini-local website capture

- Existing capture-web-screenshot.sh now detects the Mini host and runs the same headless Brave/Playwright body locally, without SSH to itself. Mini before/after source identity must match. Receipts state capture_mode=mini-local, air_mini_parity=null, and source_unchanged_during_capture=true; inspection remains false until actual review. Air execution retains strict peer parity and SSH routing.
- Mini fixture suite passed 37/37, including no-SSH local capture, source-drift rejection and Air routing. The fixture replaces browser output only; no actual browser or GUI was launched. Real 16-page pink render proof remains parent-owned. Scoped patch/hashes: outputs/portfolio-review-20260906/web-local-capture-patches/. Air script base matched; Air test had unrelated preexisting differences, preserved by applying exact task hunks.

## 2026-09-06 launch freshness correction

- Parent observed canonical Video launch workflow `8523c46b1378b97de31820adb6e7528b` at 18:40 UTC claim "fresh build verified" while launching the 18:04 binary after the SaneUI 7f42568 repin. Swift-only timestamps ignored changed package locks and project configuration; this launch does not prove pink UI.
- Shared `scripts/sanemaster/test_mode.rb` now checks known source, package-lock, Xcode configuration, entitlement/privacy and resource inputs. Generated output/dependency directories are excluded. No timestamp-touch workaround or signing change.
- Mini fixture result: 25/25 passed (12 build-input checks, 13 existing runtime lifecycle checks). Newer config requests a rebuild before staging; a failed rebuild cannot launch the stale binary. Scoped patch and before/after hashes: `outputs/portfolio-review-20260906/launch-freshness-patches/`. Air before hashes matched; scoped patch applied with after-hash parity. No app build/launch occurred in this fix lane; parent owns actual rebuilt Video proof.

## 2026-09-06 active Video verification

- Modal command isolation is verified on the Mini: nine of nine TeleprompterActionTests passed with xcresult verification. Receipt: `apps/SaneVideo/outputs/monitor-tests/20260906T180031.868270Z-13902-92a7414f/receipt.json`.
- Parent inspected clean real UI evidence: Command-I opened one Import Video sheet; Command-Shift-G left the same sheet; clicking the actual Cancel button left zero sheets and no queued GIF panel. Saved screenshots: `infra/SaneProcess/outputs/portfolio-review-20260906/video-runtime-20260906/codex-shot-2026-09-06_14-10-31.png` and `codex-shot-2026-09-06_14-14-22.png`. The 14:08:58 capture is invalid because Finder occluded the app. Structured receipt: `modal-verification.json` beside the valid images.
- Launch workflow `9b585b5b216fa8582c5d81c987771123`; continuous log and receipt: `apps/SaneVideo/outputs/runtime-logs/20260906T180423Z-20260906-14858-oeym4/`. This run used PID 15166 and ended at 18:19:06 UTC with `app_exited`. Earlier prepatch PID 86455 was quit before this run and is not current runtime evidence.
- Pink dependency status is superseded by the rebuilt candidate proof above: main pink heart verified. Full 18-action proof and release remain pending.

## 2026-09-06 active portfolio resume: Air logout and Video proof

- Air interruption is confirmed automatic logout, not restart: unchanged boot 01:35:01; loginwindow reached idle3600 at13:17:32, began 60second logout confirmation13:18:32, completed13:19:34; owner logged back in13:37. System AutoLogOutDelay3600 predates this task. Evidence: outputs/portfolio-review-20260906/air-autologout-20260906.log.
- Shared guard fix is VERIFIED for bounded native assertions on both hosts: 6/6 focused regressions, identical base.rb SHA1a96cad850847aba37a0ea52ededd914a2b5a48197c06f94cbd88558abb20041; AirPID86436 active17sec and MiniPID13008 active43sec at13:58. User-active/display/system sleep assertions persist after tool completion. Guard renews12h with safePIDownership/new-before-old readiness, leaves logout/lock policy and legacy snapshots unchanged. AirAutoLogOutDelay remains3600. Evidence: work-session-patches/, air-work-session-assertions.txt, mini-work-session-assertions.txt under portfolio outputs. Actual native one-hour decision is now VERIFIED: at15:18:46–15:20:16 ET, loginwindow read AutoLogOutDelay3600 and idle3900–3990 seconds, then repeatedly reported 'NOT logout: Present:1'. Saved log: outputs/portfolio-review-20260906/air-work-session-autologout-protected.log. This verifies the bounded active guard against idle auto-logout, not protection from crashes, power loss or explicit reboot. Guard expiry~Sep7 01:57ET; parent must renew during longer work and release only after last active task.
- Mini SaneVideo prepatch runtime: isolated new project897FAA16-DE1B-464A-83FD-19CAAAB02A5B imported Tests/Assets/test_video.mp4 through the real picker; editor showed1clip12sec. Prior accidental addition to restored projectEA4301C1-3AE1-4EAD-9AE5-83CAC2FF18ED was undone and saved original has zero fixture references.
- Real Export File produced test video_1788714854.mp4 in SaneVideo container Application Support/SaneVideo/Exports after desktop-unwritable fallback. HEVC1920x1080+AAC,12sec,247020bytes; full ffmpeg decode exit0 with no errors. Log receipt: apps/SaneVideo/outputs/runtime-logs/20260906T164600Z-20260906-86399-8iix7x/live.log. Private screenshots/import observations/decode receipt: outputs/portfolio-review-20260906/video-runtime-20260906/.
- Superseded by the active Video verification section above: modal regression tests and focused real UI proof passed. Full customer UI and release proof remain pending.


As of: 2026-09-06 America/New_York
Owner host: Mac Mini = tree truth; Air = controller.
Repo: `~/SaneApps/infra/SaneProcess`

## ACTIVE GOAL: top-down portfolio review (2026-09-06)

- Progress12:44ET: owner granted missed permission prompt and requested active prompt handling without unattended stalls. Current Mini Terminal GUI path proves AX control works; Automator Node service denied AX, real node Accessibility dialog captured12:38, opened actual System Settings through Terminal UI. Resolving exact off Node switch; no TCC reset/ACL changes. Parent Video app68359 alive; initial live-log deadline elapsed during permission work, relaunch with capture before further Video testing.
- Worker fixes DEPLOYED: sane-dist0712cb66-3e64-4597-93c3-0a95e517be8a, checkout5196d67d-eab0-42c8-b9ef-81edef7e577c; real HEAD caused zero events/downloads, labeled GET emitted only website redirect. Report excludes1201 legacy web clicks. analytics-live-verification.json. Earlier no-deployment line below is superseded.
- Click canonical website deploy completed but immediate route verifier hit propagation; subsequent reads custom/newdeployment302to1.3.3. Video full verify1228passed; actual UI visible Camera is Off +Donate; no full workflow/release proof yet. Q7/Q8/Q10/Q11/Q12/Q13 reports now present; Q9/synthesis incomplete.
- Sync parity:7reviewed taskfiles onAir; Lot15commits/site3cleanFF; validator84/84 andsync8/8;37private restoreverified custody backups, exactthreewayplan saved. No blanket parity claim. Shared UI evidence generator fabricates declaration-only click receipts in Video/Scan/Sales; release agent repairing false-success root contract with regression checks; releases remain blocked until real flow evidence.

- Owner follow-up authorization: Lemon Squeezy is signed in on existing Mini Brave; update apps after verification, remove superseded customer-visible hosted files after confirming replacements. Keep private rollback copies; do not delete historical Sparkle compatibility archives or unrelated products.
- Owner explicitly requests all live products/processes, first principles, current research, subagents, repairs/improvements, unfinished work, Air/Mini sync, and skills upgrades. Rebuilds/high-risk actions need owner decision. Routine reversible work authorized. No blanket overwrite, secret export, forced history or unrequested publish.
- Canonical evidence bundle /tmp/audit_bundle.txt and brief /tmp/audit_context_brief.md; durable receipts outputs/portfolio-review-20260906/. Validation /tmp/portfolio-validation-20260906.log reports55critical/209release blockers; distinguish real live failures from stale/missing evidence before acting.
- Active lanes: portfolio_config_sync Q0 exact repo/config parity and safe reconciliation; portfolio_tools_skills Q11 skills/hooks/tooling simplification; portfolio_releases Q6 live release/distribution vs unfinished candidates. Parent owns credential wrappers, business evidence, research, serial runtime verification and synthesis.
- Initial Q0:31Air/29Mini Git roots,23sharedpaths,16differentHEADs; large unique dirty work. Current sync wrappers may overwrite peer dirt, use skill --delete and suppress copy errors. No blanket sync run. Fix standard route first, then reconcile safely with preserved work and proof.
- Initial Q11: audit/verify/evolve prompts contain obsolete MCP paths, wrong project roster, raw build/no-log instructions and unsupported npm audit --global. Findings must be checked against live tools and source rather than obeying stale checklists.
- Progress11:54ET: Q6 report complete: Video public1.0.5 ZIP404; Click redirect1.3.2 vsfeed1.3.3; Hosts/Bar channels split. Sync1.0.1 distributed with unresolved safety; Lot iOS1.1.1/CWS1.2.1 live, demo tenant404 intent unproven. Report and inventory in outputs/portfolio-review-20260906/.
- Air runaway memorysync PID18578 stopped after9h CPUspin. Recovered prior3bdd16c file-backed probe plus local flock/600s supervisor/Nice10;15/15 Mini fixtures pass. Task-only patch applied Air, identical script SHA3fdb2f29be5c6163a1a84262c03de8d27e5dbd797f1f3583ae3265fb7030e682. Real strict sync11:50 completed checksum parity, then restored only memorysync LaunchAgent (tunnel untouched); scheduled run11:51 exit0/parity, idle/notrunning. Air receipts outputs/portfolio-review-memory-sync-20260906.log and memory_sync.stdout.log.
- Q11 repaired shared skills on both hosts with backups:134/134 Codex +78/78 .agents files identical;34thin adapters,10provider extras retained.11lint regressions pass,78frontmatter valid. q11-change-manifest.json and q11-air-change-manifest.json list exact scope. Q10 meta docs corrections active. Parent independent scenario review pending.
- Parent confirmed live sane-dist counts HEAD and other methods as downloads; sane-checkout deployed code awaits analytics and emits checkout_clicked for all methods. Local checkout already had an unfinished GET-only asynchronous redirect-event fix, but its bundle URL was older than live. Preserved deployed bundle targets. Distribution GET/HEAD/native R2head +405guard repair and saneapps allowlist fix pass6/6 existing/request tests; checkout6/6. No deployment yet. Before versions/content and candidates saved in outputs/portfolio-review-20260906/. Historical analytics contaminated; do not infer user conversion from unqualified totals.
- Active implementation: config agent safe control-plane sync wrappers (no livebulkcopy); release agent shared before-launch saved log lifecycle (no app launches). Parent owns workers and serial app verification.
- Required coverage outstanding: remaining Q7website,Q8signing,Q9support,Q10docs,Q12runtime,Q13historical perspectives; product/customer/architecture/security/value review; fix and regression passes; serial Mini visual/runtime proof; sync verification; final prioritized report with literal Per-Perspective Scores, Root-Cause Matrix, Current Coverage, Would Catch Today?, Checked Evidence. Goal remains active until actual outcome or recurring hard blocker.

## 2026-09-06 permission preflight and maintenance follow-up

- Owner requests standing authorization for routine reversible maintenance on both machines; ask before destructive changes or materially broader security access. Saved in both global AGENTS.md files and SaneProcess AGENTS.md. Preserve signed identities and existing TCC grants; no blanket sudo/ACL changes or TCC reset.
- Prompt flood exact dialog sources remain unproven. Confirmed defects: shared security guard ignored all three existing no-prompt flags; client version probes could bootstrap installers. Fixed on both hosts. Mini guard regression152/152; maintenance regression28/28; syntax/diff checks pass. Both security symlinks use the fixed guard immediately. Native APIs outside this wrapper still need upfront permission review and sequential execution.
- Mini canonical screen capture succeeded without prompting, reporting Screen Recording already granted. Private screenshot: /var/folders/k3/rv4pdt_93w96djzjnsyszgl40000gn/T/codex-shot-2026-09-06_10-26-50.png; controller copy /tmp/mini-permission-review-20260906.png. Image shows desktop with Codex, no blocking permission/billing dialog; not SaneClip visual proof.
- Mini Keychain metadata unavailable over SSH but works through existing mini-gui-run desktop session. No unlock/ACL rewrite needed. Cursor agent --version then succeeded in that session:2026.09.02-c22c1a3.
- Apple billing fixed by owner; mas update completed TestFlight4.3.1. Installed plist confirms4.3.1; mas outdated empty.
- Air native SF Symbols cleanup completed after owner authorization: beta absent; stable7.2 installed, strict codesign passes, com.apple.pkg.SFSymbols receipt7.2.1.1770259514. Homebrew sf-symbols cask removed to prevent another unqualified beta upgrade. PASS receipt /tmp/sf-symbols-stable-finished.txt. Installer volume detached. No password persisted in scripts.
- Activated Mini PostgreSQL17.11 through brew services; clean shutdown/startup logs and SQL version/pg_isready confirm health. Air already runs17.11. No schema or pgvector SQL migration. Restarted only identified Tailscale launchd services; both report1.102.3 and BackendState Running, Mini SSH works. Air uses its configured userspace socket, not the default socket.
- Both Homebrew formula checks show no outdated formulae. Codex CLI0.153.4 on both. Mini Codex desktop updated by owner to26.901.51231/build8109, matching Air. Installed/running process, strict deep codesign and bundled CLI0.153.4 verified. Stable designated identity remains Team2DC432GLL2. Post-update canonical capture10:37:57 reports Screen Recording already granted without prompting.
- Original normal-restart hang root cause remains unproven. SaneClip/SaneSync trial close fixes and focused regressions are recorded previously; clean customer-facing SaneClip paid/expired UI proof and all-app runtime proof remain incomplete. No releases/commits/pushes.

## 2026-09-06 Sunday launch-ops

- Host Mini. livez `ok` on `127.0.0.1:3111`. CLI connected, v0.9.29, 1145 memories. No installer.
- Sunday file-memory refresh **failed before stop/reset**: `/Users/stephansmac/memory_import.py` is missing. Store left untouched.
- Classifier `GET /api/classifier-health` 200, healthy, lastRunAt `2026-09-06T12:00:12Z`; recovered `2026-09-06T00:00:12Z` after lastFailure `2026-09-05T23:00:12Z`. No deploy.
- Inbox: autoresolve 0. Spam #1391 (fake Turkish tax zip/`yazi.js`). #1404 Fogdog departed auto-reply left open (evidence guard). #1331 Setapp agreement and #1343 Apollo nurture still open.
- Launch calendars: nothing due today. No `launch_readiness` sweep. No M/W/F storefront inspect. Friday AI meter and Workers AI watch skipped.

## 2026-09-06 Air and Mini tool refresh completion checks

- Air expanded inventory updated34 requested Homebrew formulas plus dependencies, Cursor3.19.13 and CodeLLDB1.12.3, Grok/Droid/Bun/uv/VoiceMode, six Python tools, eight Ruby tools, five npm packages, and repaired official Codex CLI0.153.4 links. Claude excluded. Receipts: outputs/tool-refresh-20260906/air-summary.json and report.md.
- Mini approved custom-package trust applied to Supabase/CASS/UBS/Peekaboo only; all are updated. Both hosts report no outdated Homebrew formulae; runtime data/service activation boundaries remain in mini-summary.json.
- Shared dependency pins updated on both hosts; Mini tests24/24, Air35/35; both managed npm baseline checks pass. Context7 MCP handshake/listTools passes. Automator launcher had a separate stale0.4.6 pin: corrected to0.4.7 on both, restarted only Mini Automator via canonical singleton install, then real HTTP MCP initialize/listTools passed with2 tools.
- Remaining: Mini Codex desktop updater, Cursor agent locked-keychain block, TestFlight billing block; database/network binary activation deferred to controlled restart. Source changes uncommitted; unrelated dirty work preserved.
- SF Symbols Homebrew8.0 resolves to Apple beta despite unqualified cask version. Air stable7.2 build119 restored from Apple-signed package and codesign strict passed. Native beta uninstall stopped when sudo authentication expired; extra beta bundle and8.0 package/cask receipt need administrator cleanup. Official stable installer retained /tmp/SF-Symbols-7.dmg. Do not repeat beta upgrade blindly.

## 2026-09-06 expanded Mini coding-tool sweep

- Owner expanded scope to all installed tools on both hosts, explicitly including Codex and excluding Claude. This receipt is Mini-only; parent owns Air.
- Updated Docker29.6->29.8, buildx0.35->0.37, Lima2.1.3->2.2, mas5.2->7, OpenCode CLI/plugin1.18.18->1.18.29, plus eight native/document libraries. Installed official Codex CLI0.153.4 and repaired only dangling codex/code-mode-host aliases; auth/config preserved. Signed desktop app remains26.818.41509/build6962 with embedded0.149.0-alpha.4.1. No desktop-updated claim.
- Cursor3.19.13 extensions checked using built-in updater: no update. Integrated `cursor agent --version` bootstrapped the missing agent via official installer, then exited because Mini login keychain is locked; stopped without keychain retry. No uv tools, Rust/Bun/Volta/Mise/ASDF/Deno/Pipx install found. Inactive NVM24.14/npm11.9/corepack0.34.6 remains alongside current active Node24.20.
- Owner approved trust/update all used packages. Trusted only4 specific formulae, no whole tap: Supabase2.116, CASS0.7.1, UBS5.3.13, Peekaboo4.3 updated and version checks pass. UBS needed Bash5.3.15 (ncurses6.6); formula also installed Git2.55. Login stays/bin/zsh and Apple/bin/bash3.2 unchanged; no shellconfig edits. UBS first batch hit Homebrew cmake self-lock; sequential retry after installers exited passed. All Mini formulae now show no outdated packages.
- Postgres17.11/pgvector0.8.6/Tailscale1.102.3 packages installed with no cleanup, old kegs retained. No service restart or ALTER EXTENSION: liveSQL17.10 PID503 remains healthy, Tailscale350 and SaneClip31120 preserved. Their running versions activate at later restart. TestFlight billing blocker not retried.
- Expanded gem inventory: Bundler4.0.20, gem Lefthook2.1.12, Rake13.4.2, RuboCop1.90, ruby-lsp0.26.11, xcodeproj1.28.1, TypeProf0.33 updated and smoke-checked. NVM manager0.40.3->0.40.7 via clean official git tag; active Node/path unchanged. Inactive cloudflared binary2026.5.2->2026.8.3, no daemon started. System Ruby2.6 and major shared Ruby mcp gem remain. Parent reconciled shared Automator pin0.4.7, canonical restart and handshake passed.
- Before/after inventory, install logs and blockers: `outputs/tool-refresh-20260906/mini-summary.json`. Version/help smoke checks pass for changed CLIs; discovery receipt `c19dd6355066ea14c861e818d7d483b6` (MCP health failed; validation partial no-prompt mode). No commits.

## 2026-09-06 Mini restart hang and coding-tool maintenance

- Mini forced restart at 02:32 ET. loginwindow reached LogoutComplete at 02:26:19.612; sessionlogoutd last logged preference write at 02:26:19.616. Final cause remains unproven; SaneClip dialog was not the final shutdown gate. Reset/audiomxd logs and timeline: `outputs/keep-current-20260906.json`.
- Updated and verified Grok1.0.13 plus eight dev CLIs (ripgrep, lefthook, swiftformat, swiftlint, xcodegen, uv, periphery, fastlane). Fastlane2.239.0 brought Ruby4.0.6 bottle revision and terminal-notifier3.1.0. No trust or server-runtime changes. Existing Grok sessions await normal restart.
- Canonical npm pins updated: SDK1.30.0, Automator0.4.7, AgentMemory0.9.29, Playwright1.63.0. Fixed stale baseline test assertions;24/24 pass. `keep_current --apply --npm-only --latest --role mini` passed without latest drift. Receipt `~/SaneApps/outputs/keep-current/20260906T064330Z.json`, workflow `d3a716d652ddf24d3d1c63ea76053578`. Existing local AgentMemory supervisor restarted itself after npm replacement;livez200 and CLI healthy v0.9.29,1145 memories. Cloud MCP routing unchanged.
- Cursor3.19.13 stable feed returned204; Grok Bot0.43.0 feed also204 with rollout qualification in receipt. Codex/Claude absent targets and dangling aliases preserved, not reinstalled. Xcode26.6 not offered an App Store update; macOS softwareupdate reported no new software.
- TestFlight4.3.0 ->4.3.1 blocked by App Store billing problem with prior purchase (private02:44:36 Mini screenshot path in receipt). `sudo -n mas upgrade 899247664` exited ISErrorDomain-128/failureType2021. No billing action or retry. Untrusted custom-tap tools remain unverified; no trust changes. Server/network/container/database formula updates were outside coding-client scope and not applied. No all-tools-current claim.

## 2026-09-01 AgentMemory Access tab is blocked

- The Brave “Authorize Client / MCP CLI Client / localhost:5716” page is
  mcp-remote OAuth, not a broken password. Allow does nothing after the
  callback process dies. Daily Cursor/Grok/Codex now run
  `scripts/grok-bin/agentmemory-mcp-remote.sh`, which will not open Access.
- One-time grant: `agentmemory-mcp-remote.sh --login`. Cache:
  `~/.config/saneapps/agentmemory-mcp-oauth`. Close leftover Access tabs.

## 2026-09-01 SaneHosts 12-week email campaign is live

- Monday 8/31 was empty because Hosts rode an unloaded Lot Grok heartbeat.
  Hosts now has its own Mini LaunchAgent `com.saneapps.sanehosts-email-campaign`
  (weekdays 08:20 ET, Python only). Lot's Grok job stays unloaded.
- Window 2026-09-01 → 2026-11-24. Cap **50 Email 1 / weekday**. Morning slots
  start 09:00 ET at a 3 min step and skip the Lot 09:38–10:12 block. A short
  day tops up to 50 instead of skipping. Email 2/3 drip automatic. Abort:
  campaign dir `campaign-ABORT`.
- Tuesday 9/1: **50 Email 1** (8 at 09:00–09:28, then 42 more 13:54–15:57 ET).
  Receipt `outputs/sanehosts-apollo-2026-08-27/campaign/e1-send-receipt-2026-09-01.json`
  has 50 unique Resend ids. Re-plan is `e1-already-booked`. Afternoon sample
  `last_event=scheduled`.
- Apollo restock after the top-up: +188 people, +176 work emails. **302
  sendable left** (about 6 weekdays at 50/day). Auto-refill when unsent < 150
  (search 250, enrich 200).
- Do not run `install-recurring-agents.sh` just to refresh Hosts: that installer
  also bootstraps the Lot email heartbeat and would dump the dealer 40-cap.

## 2026-08-24 SaneLot 6-week email campaign + Grokbot partner

- Monday canary (`walk-away price?`, 8 dealers, 9:15–9:43 ET) sent. Live 15:53 ET:
  6 delivered + 1 opened (Pearl Motors) + 1 bounce (Schoepp Motors) + 0 complaints + 0 replies.
  GO gates still pass.
- Owner asked for six weeks of lead-finding and copy/reply tweaks, partnered with Grokbot.
  Durable runner is Mini Grok heartbeat `sanelot-email-campaign` at 08:15 and 16:30 ET
  through 2026-10-05 (`com.saneapps.agent-heartbeat.sanelot-email`). Cursor canary
  timers were never installed.
- Split: Mini heartbeat sends (Resend via `monitor_and_scale.py --six-week-morning`).
  Tuesday 2026-08-25 may fire the armed 32 only if GO. After that, 8 first-touches
  per weekday. Grokbot reads `GROKBOT.md` / `LEDGER.md` in
  `outputs/sanelot-resend-outreach-2026-08-21/`, drafts owner-facing replies, and
  does not send in parallel. Dealer sales replies stay pending until owner/Grokbot
  approval. Unsubscribe is auto.
- Abort: `campaign-ABORT` or `tuesday-send-ABORT` in that outputs dir.
- Off-LAN rule still applies: no Mini GUI/TCC prompts.

## 2026-08-24 off-LAN Mini + checkout sync

- Owner is off the Mini LAN for about two weeks. Do not trigger Mini GUI,
  TCC, Screen Recording, Accessibility, or any permission prompt. Mini
  work is SSH/HTTP only against already-granted services.
- `ssh mini` was failing off-LAN for two reasons: SSH ProxyCommand PATH
  cannot see `~/.local/bin/tailscale`, and `tailscale ping` defaults to
  `--until-direct=true`, which exits 1 on a successful DERP pong. The proxy
  now prefers the wrapper and pings with `--until-direct=false`. Raw TCP to
  the Tailscale 100.x IP still times out on the Air userspace daemon;
  `tailscale nc` is required.
- AgentMemory Air tunnel (`com.saneapps.agentmemory-tunnel`) depends on
  `ssh mini`. It was down while the proxy failed, and `ConnectTimeout=3`
  was too short for off-LAN DERP banner exchange (~8s). Timeout is now 15s.
  Kick the Air LaunchAgent after SSH works; do not restart Mini GUI helpers.
- Live `go.saneapps.com/buy/bundle` had drifted to Lemon checkout
  `aa593db3-…` (no bundle name, no $49.99 custom price). Canonical bundle
  remains `products.yml` `b572a5cf-…` / `$49.99` Everything Bundle.
  Worker source and products.yml now match; deploy the Worker from
  `infra/cloudflare-workers/sane-checkout.js`. SaneBar `/buy/sanebar` stays
  GitHub Sponsors.
- `sanescan.saneapps.com` is no longer in `all_domains` expiry checks.

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

## Q0 final bounded reconciliation: shared tools, native Donate, Hosts card (2026-09-06)

- Three retained Air tool changes are now on Mini: SANEHOSTS_ launch environment forwarding; explicit Cursor search_replace classification; exact owner-approved SANE_MINI_UNAVAILABLE consumer parity. Existing guards already recognize the fallback token; no approval flag was set and no Air UI was run. Cursor generic replace matching already covered this spelling.
- Mini focused fixtures: test_mode 31/31, customer UI evidence integrity 8/8, layout guard 19/19. All six source/test files match Air. No registry/base/work-session or SaneUI files touched.
- Parent Donate manifest entries 2–4 applied to Air with original-hash preconditions and three-way review: Scan ContentView, Scan PaywallView, Sales DashboardView+Secondary. Only pink filled-heart icon changes; text/style preserved. All three match Mini; Air Git HEAD/index unchanged. Native visual/runtime proof belongs to parent.
- Hosts og-image-20260827.png is already public and live homepage references it. Local/live SHA256 38194233f4f869c62031d0fe9af453b53bb314d6e320dae84f3dcdcc2a43225b, 86301 bytes, 1200x630. Clean graphic card inspected; 14 current HTML pages reference it. No distinct dated owner asset-approval receipt found in pointed docs. Retaining identical live bytes is not new asset publication.
- Receipts: outputs/portfolio-review-20260906/shared-tail-parity/{tests,parity-proof}.json; donate-heart-air-integration/applied.json; hosts-1.1.25-provenance/og-image-proof.json. Hosts metadata remains source-only pending parent website deployment; historical 1.1.25 artifact remains unchanged. No current native fixes shipped by these edits.

## 2026-09-06 Hosts webhook restoration completed
- Authorized two-filename repair deployed via documented Cloudflare PUT script /content, which preserves config and metadata. Active version90bf5865-8c12-48fb-b760-c58ab65f8746, exact approved SHA38f5db204436db64e93c47fabb736d1a9eb6b4f9735b3978284bad03625640b5. Every binding, operational setting, route and cron unchanged; only provider provenance workers/triggered_by changed version_upload→upload.
- Authenticated standalone and bundle Hosts snapshots return1.1.25 and signed proper archive paths. All nine live product configs equal old deployed bundle with only intended Hosts file/version changes. No emails sent. Private original content/settings/version retained under outputs/portfolio-review-20260906/hosts-webhook-recovery.
- Hosts source literals and existing Hosts test expectations updated bothAir/Mini, preserving independent copy/Click/Video dirt. Mini focused Hosts case1/1 and syntaxpass. Parent website-only deploy completed afterward; final parser check reported empty version, under read-only investigation. No additional deployment yet.

## Hosts website readback verified after deployment (2026-09-06)
- Parent deployed https://eb3873ec.sanehosts-site.pages.dev. Fresh public/deployment appcasts200, SHA6a705ed994a3858d43b17184df03bb8bae24d9d8b357e7bb097a74c90c7b3258, version1.1.25/build1125 with /download link. Both public/deployment /download resolve200 to retained signed archive SHA df61c08e916e41ce2eb4a30a144b00c6027d6f9e85492b86ef7fb6138175b451 (4960814 bytes).
- Verbatim canonical appcast/link helpers pass exit0 on current public body. Old retained1.1.24 body reproduces prior missing-for-v error. Error uses unset global VERSION in website-only mode; initial response body unavailable, so propagation is plausible but not historically proven. No parser behavior changed, no redeploy, no guard bypass. Proof: hosts-webhook-recovery/website-readback/{proof,canonical-parser-proof}.json.
- Restoration republishes only the already authorized Aug18 1.1.25 artifact metadata; current native source fixes are not shipped by this website update.

## Donate website visual proof completed (2026-09-06)
- All 16 changed webpages captured serially with canonical Mini-local headless Brave and all 25 Donate/Sponsor hearts visually inspected at native resolution: pink filled interiors, readable white unclipped labels. Hosts is live; the other 15 pages are source-only candidates. Scope is changed hearts/labels at desktop width, not unrelated layout or mobile coverage.
- Clip, Click, Hosts and hub index use explicit native reduced-motion state; no CSS overrides. Initial Clip default animated capture omitted its lower Support region and remains an incomplete retained attempt. Optional capture-tool flag fixes the evidence path; 38/38 focused fixtures pass. Primary API: https://playwright.dev/docs/api/class-browser#browser-new-page .
- Full PNGs and inspected action receipts live in each exact repo outputs/visual-audit-donate-pink-20260906; central manifest, PNG/source hashes and verdicts: outputs/portfolio-review-20260906/donate-pink-web/render-proof.json. No owned headless browser remains; Mini load at close1.37/1.42/1.48. No other website deployed.
- Capture source matches Air/Mini SHA d81bacf098d245a6d7d07cbbb1d763a54d25378b5e778b83d70836757919ac2e. Motion tests applied on Air preserving its separate ConnectTimeout routing assertion; test files retain that one independent difference. Parent owns routing integration.

## Sibling PCM repair verified and synced (2026-09-06)

- Applied the reviewed four-source repair: promote existing AVAudioPCMBuffer(sampleBuffer:) native-copy initializer with PCM/frame-count preconditions; SilenceDetector uses owned Int16 storage for its unchanged vDSP pipeline; AudioService reduces supported Float32/Int16 native spans without escaped pointers; SoundAnalysis directly uses the initializer and deletes manual channel copying. No Waveform, lifecycle, model, file-analysis feature, threshold, tolerance or downsampling edits.
- Added one focused test in existing SaneAudioServiceTests:16 actual native cases across Float32/Int16, mono/stereo, planar/interleaved, contiguous/two separately allocated segments (split inside a sample). Every case asserts all channel/frame values through returned stride and checks independent ownership after zeroing the original block. This now supersedes the earlier native-helper proof gap.
- Canonical Mini monitor_tests passed1/1 with XCResult verification, workflow ae77aa9a8b861cd2c37bb5521851acf7. Receipt: apps/SaneVideo/outputs/monitor-tests/20260906T193744.043280Z-51129-d3275246/receipt.json. Test includes current cache/Waveform sources; no unrelated suites run. It proves PCM copy/layout/ownership and compilation, not full live metering/silence classification or recording GUI behavior.
- Continuous runtime capture was ready at19:37:43.775741Z before monitor_tests started; stopped19:38:24.491942Z. Receipt: apps/SaneVideo/outputs/runtime-logs/20260906T193743Z-20260906-51125-ysoe9q/receipt.json. All owned test/app/log processes exited and Mini slot returned to parent.
- All five changed source/test files synced to Air after exact precondition hashes and per-file backups. Manifest: outputs/portfolio-review-20260906/audio-pointer-audit/sibling-pcm-parity.json; exact task diff: sibling-pcm-applied.patch. No commits, push, native release, or claimed customer-flow verification. Deferred analyzer deletion/stub feature reuse remain priority proposals only.


### Clip focused assertions and runtime evidence defect — 2026-09-06 20:10 UTC

Clip Mini three-file SaneUI repin to 0f04e7536ca69ef684ef6835034d4916ccdbfd84 resolved successfully; only SaneUI changed in the dependency lock. Canonical verify with SANEMASTER_TEST_TARGET, --no-grant-permissions, --timeout 300 and all four no-prompt/cache flags compiled and passed LicenseGateWindowTests 1/1 (expiredGateCanCloseWithoutUnlocking), then NonBlockingKeychainServiceTests 4/4 (passthrough, stalledReadDegradesToNil, stalledWriteThrows, innerErrorsPropagate). Exact xcresult test trees independently confirmed those five names Passed. Gate fixtures use private UUID defaults and fake keychain; no real paid key, permission reset, activation or release.

Receipts relative to SaneClip: outputs/verify/20260906T200713.253068Z-63725-4c5ac507/01-test.xcresult (workflow 362193a3ae02239d245a7e0c4cad5631) and outputs/verify/20260906T200847.196143Z-64641-bd26814e/01-test.xcresult (workflow 90631375a022255ecce53af91b42948f). Logs adjacent.

Required native runtime evidence is INVALID: both captures were ready before launch but verify preflight killed them before the test phases. Runtime receipts outputs/runtime-logs/20260906T200709Z-20260906-63722-pi88cb/receipt.json and 20260906T200845Z-20260906-64630-na4ocp/receipt.json say state=failed, log stream exited. Second verify explicitly reaped log PID64639. Root cause: SaneProcess scripts/sanemaster/verify.rb:445 uses pgrep -f xctest, then accepts arbitrary command text containing SaneClip; the log stream predicate contains both. terminate_project_test_processes uses the same unsafe selector. Fix real executable/ownership selection; do not rename predicates to evade it. Saved run-fixture.rb also needs final capture-state checking before reuse. No unchanged retry. Operational memory e2d2da03-b601-4d71-9fca-21c84e4c9d62 revision1253.

All test/resolver/capture processes exited. Mini screenshot 16:10:44 shows clean Finder desktop without app windows or prompts (Air outputs/portfolio-review-20260906/license-entry-feedback/clip-post-fixtures-desktop.png). Parent owns next runtime slot. Assertions/compile are green; complete logged verification and real paid/expired visual proof remain pending.

Sales Mini resolve completed20:09:44Z; only SaneUI lock changed. Its three files now match Air by exact SHA256 after before-hash preconditions. Video previously completed the same three-pin parity. Clip Air synchronization stopped before edits because its baseline differs: yml old7f87b04/version2.3.23, generated local SaneUI package, no remote lock, missing Mini gate/keychain source registrations. Requires reviewed source reconciliation, not wholesale overwrite. Exact custody/patches under outputs/portfolio-review-20260906/license-entry-feedback/{SaneClip,SaneSales}-repin/. Clip patch SHA256 deace48be2b5bef79d0c259665faff1d18812d9fb51bc6d40d36a70efd6995f0; Sales 06e6c579d98188f037460627ec8f79f065593ebd3d53809ecbc3a037c000382d. No app release or Air build.

### Verify process reaper repaired — 2026-09-06

The confirmed log-stream reaper defect is source-fixed in scripts/sanemaster/verify.rb: both stale-process and occupied-port selectors now check ps comm executable basename (xcodebuild, xctest, swift-testing, testmanagerd) before project command ownership. Reviewed callers: preflight terminate_stale_test_processes, occupied-port cleanup, verify_support terminate_project_test_processes. scripts/sanemaster/verify_process_guard_test.rb uses the existing test framework with an injected process table and signal recorder; it proves both selectors preserve required log streams and unrelated apps while cleanup signals only project test executables. Mini fixed3/3 versus exact original0/3. No real process signals, GUI or app test. Dedicated fixture file avoids adding to the pre-existing1,327-line verify_guard_test owner. Task patch SHA256 a00b6f546126babb392c08d1338aa4f667023a4902d479168ee2b55ae17c76c7; backups/hashes/logs in outputs/portfolio-review-20260906/verify-log-reaper. Air before hash matched; exact two-file after hashes match Mini. Clip logged rerun still pending parent slot; source-only fixture proof does not retroactively repair failed runtime receipts. Saved task runner needs final capture-state failure checking before reuse. No commit/push.

## 2026-09-07 12:51 ET — Session guardian now pages unexpected CPU

- Extended `scripts/hooks/session-guardian.sh`: still reaps only dead-parent disposable MCP leftovers, and now samples 5-minute load vs cores. Expected work (xcodebuild, signed SaneApps, coding apps, Mini Brave, caffeinate) is logged. Unexpected heat (sync-memory-mini, grep, etc.) pages the Air after two consecutive 10-minute hits, then stays quiet for 30 minutes. Mini never kills live work and never shows a local CPU banner.
- Focused tests 8/8: `ruby scripts/hooks/session_guardian_test.rb`. Live samples: Air load5 2.1/10 ok; Mini 2.63/8 ok with SaneClip test still not an alarm. LaunchAgent `com.saneapps.session-guardian` installed on both hosts, interval 600s, Nice 10. Script copied to Mini checkout; SaneProcess source otherwise still uncommitted.
- AgentMemory watch is unchanged and still only covers memory health.

## 2026-09-20 — Cloudflare mini-cf rescue tunnel (in progress, secret handling verified)

Named-tunnel rescue path for Mini SSH: tunnel `saneapps-mini` + Access app `Mini SSH rescue` on `mini-ssh.saneapps.com`, Air alias `mini-cf` (explicit opt-in; auto ladder still LAN→Tailscale only, fails loudly). Code: `scripts/mini/mini-install-cf-tunnel.sh`, `mini-cf-tunnel-run.sh`, `saneapps-mini-cf-proxy.sh`, `install-mini-cf-ssh.sh`, `scripts/automation/probe-mini-cf.sh`; acceptance `air-private-routes` + new `air-rescue-alias` (quick tunnels stay banned). Docs in `scripts/mini/README.md`.

Secrets (names only; values in env + keychain, NEVER here): `CLOUDFLARE_SETUP_TOKEN` (7-day `mini-tunnel-setup`, expires 2026-09-28 — DELETE in dash + purge stores when done) verified length-match across Air env, Air keychain, Mini env, Mini keychain; `CF_MINI_SSH_CLIENT_ID`/`CF_MINI_SSH_CLIENT_SECRET` verified Air env + keychain; `SANE_CF_TUNNEL_TOKEN` pending tunnel creation. Mini keychain writes must run via `mini-gui-run.sh` (ssh sessions get `User interaction is not allowed`). Full notes in agent memory `cloudflare-mini-cf-secrets.md`.

Status 2026-09-20 20:50 ET — COMPLETE and proven: tunnel `saneapps-mini` (wizard-created, route `mini-ssh.saneapps.com` → `ssh://localhost:22`), connector `com.saneapps.cf-tunnel` registered on Mini, `ssh mini-cf` green on the service token alone (interactive session parked for the proof). Two Access policies (`Owner login` allow + `Rescue service token` non_identity — service tokens silently fail under `allow`). Acceptance: new `air-rescue-alias` + `air-private-routes` PASS; remaining FAILs are pre-existing/environmental (brew drift, xcode MCP down, agentmemory corpus thresholds) except `saneprocess-parity`, which needs the commit the owner has not yet approved. Setup token `mini-tunnel-setup` (expires 2026-09-28) still live in stores — owner decision: delete in dash + purge, or keep. Receipts: `~/SaneApps/outputs/mini-cf-probe/`, `outputs/restart-acceptance/20260921T004735Z.*`.
