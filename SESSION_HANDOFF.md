# SaneProcess Session Handoff (active state only)

## 2026-09-08 15:57 ET — Clip 2.3.24 Sparkle+LS done; LS SOP is delete-old-keep-newest

- Sparkle/site/Homebrew/webhook already live at 2.3.24 (`5b1c9d7`, dist SHA256 prefix `8fc9df35f96d`).
- Owner deleted leftover `SaneClip-2.3.23.zip` on product 779223. Agent saved; UI showed Product saved. Only `SaneClip-2.3.24.zip` remains, published.
- `release.sh --version 2.3.24 --post-release-checks-only` PASS. Receipt: `outputs/hosted_file_actions/post-release-saneclip-2.3.24-20260908T195702Z-25176.json`.
- SOP correction: after the new hosted ZIP is published, **delete** superseded LS files. Keep only the newest. Unpublishing is not cleanup. Do not claim hosted-file done while an old ZIP is still listed.
- Docs updated on Mini+Air: `templates/RELEASE_SOP.md` step 4, `scripts/automation/hosted-file-actions.py`, `scripts/automation/README.md` dashboard cleanup rule, `scripts/validation_report.rb` stale-file issue text.
- Do not rerun Clip `--full --deploy`. Next: Click 1.3.4, Hosts 1.1.26, Video 1.0.5. Same LS rule on each.
- Mini Brave hidden after Clip LS. Work sessions still on.

## 2026-09-07 20:49 ET — Lemon Squeezy hosted files in sync (SaneBar skipped)

- Owner authorized Mini Brave Google login and hosted-file replace for every app except SaneBar (OSS, no longer serviced).
- SaneClip product 779223 / variant 1228215: uploaded `SaneClip-2.3.23.zip` from Mini `~/Desktop/LemonSqueezy-Uploads` (5268086 bytes, sha256 `c73712ca46f14bcbcd528ebc731e5876ae2d47383cc18b99b0efc9bfbdb78545`, matches live dist). Deleted `SaneClip-2.3.22.zip` after Product saved. Tracker: In sync, published_file_count 1.
- SaneSales product 822714 / variant 1296644: uploaded `SaneSales-1.3.12.zip` (8110807 bytes, sha256 `59d8a412c82f1006adbc0b6e6a2ff3e8eadae0b264e6abb27490a0ee41acedf4`, matches live dist). Deleted `SaneSales-1.3.11.zip` after Product saved. Tracker: In sync, published_file_count 1.
- `hosted_file_actions` 2026-09-08T00:49:17Z `current_actions: []`. Click/Hosts/Video already matched Sparkle. SaneBar left untouched (still In sync at 2.1.89).
- Login: existing Mini Brave Google session via Sign in with Google on `auth.lemonsqueezy.com`. File picker is `com.apple.appkit.xpc.openAndSavePanelService` (no AX); search-then-Return selected the ZIP. JS in the existing LS tab is the working navigation path.
- Not done: public Sparkle/App Store deploys of unpublished source (Clip 2.3.24, Click 1.3.4, Hosts 1.1.26, Video 1.0.5, Scan/Lot ASC). Do not upload the Sep 3 Clip 2.3.24 ZIP.

## 2026-09-07 12:51 ET — Session guardian now pages unexpected CPU

- Extended `scripts/hooks/session-guardian.sh`: still reaps only dead-parent disposable MCP leftovers, and now samples 5-minute load vs cores. Expected work (xcodebuild, signed SaneApps, coding apps, Mini Brave, caffeinate) is logged. Unexpected heat (sync-memory-mini, grep, etc.) pages the Air after two consecutive 10-minute hits, then stays quiet for 30 minutes. Mini never kills live work and never shows a local CPU banner.
- Focused tests 8/8: `ruby scripts/hooks/session_guardian_test.rb`. Live samples: Air load5 2.1/10 ok; Mini 2.63/8 ok with SaneClip test still not an alarm. LaunchAgent `com.saneapps.session-guardian` installed on both hosts, interval 600s, Nice 10. Script copied to Mini checkout; SaneProcess source otherwise still uncommitted.
- AgentMemory watch is unchanged and still only covers memory health.

Archived narrative (2026-09-07 10:24 ET and earlier): outputs/session-handoff-archive-20260917.md
