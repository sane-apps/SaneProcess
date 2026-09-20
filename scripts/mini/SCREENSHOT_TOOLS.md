# Screenshot tooling (Mini / Air) for visual-verification receipts

The Stop-hook visual gate (`customer_facing_ui_file_edited`) requires a screenshot
receipt from a host whose name contains **`mini`** (or `air`, only for notch /
built-in-display work). Validator: `scripts/hooks/core/visual_receipt.rb` — there is
**no local fallback** for visuals, so the capture must happen on the Mini.

## One command (do this first)

```bash
scripts/mini/capture-web-screenshot.sh <url> <outputs/visual-audit-DIR> --source-root <project-root> --viewport desktop --label NAME --app APP --version VER
```
Captures the URL on the Mini via Playwright with the Mini's Brave executable, copies the PNG back, and writes a
`customer_ui_action_receipt.json` scaffold with `inspected:false`. Then **open the PNG**,
confirm the change renders, and set `inspected:true` (top-level + screenshot entry). The
gate stays red until you inspect — intentional, do not fabricate.

`--source-root` must name the exact Git root. On the Mini, the wrapper executes
locally and requires unchanged Mini HEAD, branch, dirty status and source/config
manifest across capture. Its receipt states `capture_mode: mini-local` and
`air_mini_parity: null` (not checked). When called from the Air, it keeps strict
Air/Mini parity before and after capture and records `capture_mode: air-to-mini`.
Both routes reject source/output-path escape and source drift.

## Website / URL screenshots → use Playwright with Brave on the Mini (preferred)

The Mini has the Playwright Node package and Brave. The wrapper launches
`/Applications/Brave Browser.app/Contents/MacOS/Brave Browser` explicitly with
`NODE_PATH=/opt/homebrew/lib/node_modules`. It renders **headless / off-screen**, so there is
no GUI-session focus problem and no Codex/Terminal window contamination.

```bash
scripts/mini/capture-web-screenshot.sh https://sanebar.com <app>/outputs/visual-audit-<ver> \
  --source-root <app> --viewport desktop --label home --app SaneBar --version <ver>
scripts/mini/capture-web-screenshot.sh https://sanebar.com <app>/outputs/visual-audit-<ver> \
  --source-root <app> --viewport 375 --label home --app SaneBar --version <ver>
```

`desktop` is 1440x1000 and `375` is 375x900. The viewport label is included in
the PNG name and receipt so desktop and mobile proof cannot be confused.

Then write `outputs/visual-audit-<ver>/customer_ui_action_receipt.json`:

```json
{
  "type": "visual_audit",
  "status": "passed",
  "host": "stephans-mac-mini.local",
  "inspected": true,
  "claims": [{ "id": "<what this proves>", "status": "passed", "screenshots": ["shot.png"] }],
  "screenshots": [{ "path": "shot.png", "view": "...", "result": "...", "inspected": true }],
  "generated_at": "<fresh UTC ISO8601>"
}
```

`path` may be relative to the receipt's own directory. **Actually open and inspect the
PNG** before writing `inspected: true` — do not fabricate a receipt.
The gate (`scripts/hooks/core/visual_receipt.rb:84-120`) rejects a receipt with
an empty `claims` array, so every receipt needs at least one claim with a
`passed`/`pass`/`clean` status and screenshot paths that exist on disk.
`audit_recorded: true` may stand in for `inspected: true`. Umbrella sessions
running from `~/SaneApps` are covered: the gate also globs
`apps/*/outputs/visual-audit*` receipts.

## macOS app-window / desktop screenshots → `capture-mini-screenshot.sh`

Use for native app windows, Finder menus and the Mini desktop:

```bash
scripts/mini/capture-mini-screenshot.sh desktop --app "SaneBar" --window-name "Settings" --mode temp --copy-to <dir>
scripts/mini/capture-mini-screenshot.sh desktop --copy-to <dir>
```

If the wrapper reports "Screen Recording is not granted" (its direct route runs
in the GUI runner/Terminal session, which may lack the grant), do NOT fall back
to raw `screencapture` over ssh — use the Mini capture agent below instead.

`capture-mini-screenshot.sh` refusals and modes (verbatim from the wrapper —
expect these, do not work around them):

- Bare `--active-window` with no explicit target: `Refusing Mini screenshot
  capture with bare --active-window. That path often captures the automation
  Terminal instead of the intended app window. Use --app/--window-name or
  --window-id, then close Safari/Preview after the capture.` (exit 2)
- `--full-screen` / `--out-dir`: `Unsupported Mini screenshot flag: $1. Use the
  canonical desktop path instead: capture-mini-screenshot.sh desktop` (exit 2)
- `--locked-evidence` without the expected helper hash:
  `Locked screenshot evidence requires an expected helper hash.` (exit 1);
  locked evidence also requires an exact Brave PID plus window title (or
  `--preserve-frontmost` with no activation flags)
- Video: `--video --duration N --out FILE` records via ffmpeg inside the Mini
  GUI Terminal session; `--duration must be a positive integer number of
  seconds`. Capture times out after 120s by default
  (`MINI_SCREENSHOT_CAPTURE_TIMEOUT_SECONDS`): `Mini screenshot capture timed
  out after ${timeout_seconds}s; inspect the Mini for a stuck GUI runner or
  permission prompt.` On recording failure: `Mini screen recording failed. If
  it is a permission error, grant Screen Recording to Terminal on the Mini
  (this wrapper runs ffmpeg inside Terminal's session).`

## Desktop capture via the Mini capture agent (verified 2026-09-17)

Agent `com.saneapps.mini-screenshot` runs in the Mini GUI session (which holds
the Screen Recording grant) and serves `~/.sane/capture-queue`: write
`request-<id>.json`, poll `receipt-<id>.json`. From the Air:

```bash
ssh mini 'cat > ~/.sane/capture-queue/request-air1.json' <<'EOF'
{"id": "air1", "args": ["desktop", "--skip-cleanup"]}
EOF
# poll up to ~2 min for ~/.sane/capture-queue/receipt-air1.json:
# {"id","exit","png","error"} — exit 0 + png path = success, nonzero = stop, no retry loop
scp mini:<png-from-receipt> <local-path>   # then inspect, then delete BOTH sides + receipt + request (queue must end empty)
```

Verified 2026-09-17: exit 0, valid 1920x1080 PNG (~393KB), queue left empty.
Raw ssh `screencapture` stays blocked by `sane_bash_guards.rb` (wrong TCC identity).

Capture the target in a healthy, unobstructed state and inspect the saved image.
Use `--skip-cleanup desktop` to preserve an open menu or a blocking dialog for
private diagnosis. Desktop mode may include unrelated background windows; it does
not prove that an obscured app is verified. Raw `screencapture` over SSH is blocked
by `sane_bash_guards.rb`.

Finder menu proof (Mini, verified 2026-09-07): Peekaboo 4.3.1 can omit visible
context-menu items from its accessibility tree. Read a fresh canonical screenshot
and use `click` or `move --global --foreground --no-auto-focus` at the observed
coordinates. Automatic focus can dismiss the menu. The GUI runner now preserves
an already-frontmost process and uses its existing AX focus helper for Finder;
it must not send a redundant synchronous Finder activation while a menu is open.
The former path captured successfully but waited until the 120-second timeout.
Verify every action with another screenshot and its actual result.

SwiftUI sheet proof (Mini, Peekaboo 4.3.1, verified 2026-09-07):
an exact parent-window `see --window-id ID --tree --no-screenshot` includes
sheet controls. AX button clicks work from that snapshot. Background keystrokes
cannot target the parent when the sheet holds keyboard focus; foreground focus
of the parent may time out. For an editable sheet field, use
`set-value 'text' --snapshot SNAPSHOT --on ELEMENT`; this command rejects
combining a snapshot with window/app/PID flags. Re-read the field and actual
filtered rows after setting it. Background AX scrolling is not supported on
SaneClick's library sheet; foreground scrolling remains unverified. Do not
repeat focus failures or count event dispatch alone as a passed action.

Settings scrollbar follow-up (2026-09-07): AX scrollbar set-value changed SaneClick's scroll position but Peekaboo returned an indeterminate receipt-envelope error. Do not repeat it: re-read the scrollbar value and capture the resulting viewport. A Finder WINDOW_NOT_FOUND foreground error also coincided with a visible macOS ruby permission prompt; inspect the desktop before assuming a targeting defect.

Native scrollbar page buttons (2026-09-07): on SaneClick Settings, click the fresh AX increment-page button using its exact window/snapshot/element. Read-back showed scrollbar1 and a clean screenshot confirmed the complete section. Prefer this native action over scrollbar set-value, which returned an indeterminate bridge receipt despite changing the value.

Peekaboo 4.3.3 command map (Mini, verified 2026-09-08):
`peekaboo image` and `peekaboo list` were removed in v4. Use these instead:

| Old (removed) | Working 4.3.3 command |
|---------------|------------------------|
| `peekaboo image --mode screen --path FILE` | `peekaboo see --mode screen --no-elements --path FILE` |
| `peekaboo image --app menubar --path FILE` | `peekaboo see --app menubar --no-elements --path FILE` |
| `peekaboo list apps` | `peekaboo app list` |
| `peekaboo list windows --app NAME` | `peekaboo window list --app NAME` |
| `peekaboo list menubar` | `peekaboo menubar list` |

Raw ssh `peekaboo image/capture/list` is blocked by `sane_bash_guards.rb:68-72`.
`peekaboo see` and `peekaboo click` over ssh are NOT blocked by the guard —
still run Peekaboo inside `mini-gui-run.sh` (raw ssh Peekaboo runs under the
wrong TCC identity), but that is guidance, not enforcement. Visual smoke hides
the `SaneApps Automation:` Terminal runner window and does not count it as a
dirty desktop.

SaneClip history popover and NSMenu (Mini, Peekaboo 4.3.3, verified 2026-09-08):
`peekaboo see --app SaneClip` / `--pid` keeps **layer 0** windows only. The
history NSPopover is **layer 25** (about 346×526). Context menus and the AI
submenu are **layer 101**. Combined `see --app` then reports a 64×64
minimized window and is the wrong observation tool.

Working capture (must run inside `mini-gui-run.sh`; raw ssh Peekaboo see/click
is the wrong TCC identity):

```bash
# Window ids: /usr/bin/python3 + Quartz CGWindowListCopyWindowInfo.
# Homebrew python3 has no Quartz.
peekaboo see --window-id ID --no-elements --json --path /tmp/clip.png --no-remote
```

That returns a PNG plus `snapshot_id`. Coordinate space is
`global_display_points` (scale 1 on the Mini). Inspect the PNG before clicking.

NSMenu snapshot clicks fail immediately (`SNAPSHOT_STALE`, "no longer
interactive"), even when `see` and `click --snapshot` run in the same
process. Do not retry snapshot clicks on layer 101 menus. `--no-auto-focus`
without `--foreground` is `VALIDATION_ERROR`.

Working click, after measuring pixels against the window origin:

```bash
peekaboo click --at X,Y --global --foreground --no-auto-focus --json --no-remote
```

Status-item open: `peekaboo menubar list` / `menubar click --index/--title --foreground --verify`.
An extra status-item click toggles history closed. An extra right-click
dismisses the open menu. Do not type into history search without a pixel
proof of rows; a poisoned search shows "No Results" while the footer still
says "50 items" — relaunch to clear `@State`, do not guess backspace clicks.

AI vs Transform: the 5th context-menu row is `AI — On Device (macOS 26+)`.
The 6th is `Paste As...`, which opens Transform (UPPERCASE / Trimmed), not
Rewrite. Photograph the submenu. Rewrite is the first row of the small
~142×82 AI menu. The Rewrite sheet is 520×420; Copy is bottom-right after a
result, Cancel is bottom-left. `copyTextWithoutPaste` must not add a history
row. Never `pbcopy`/`pbpaste` for this proof — Universal Clipboard injects
into the other machine's Clip history. Store pasteboard hashes only.

Clip's live receipt is `outputs/customer-ui/ai-proof/runtime-traversal.json`
(booleans + hashes, no prompt/result/pasteboard text). Details also live in
`apps/SaneClip/DEVELOPMENT.md`.

## Tool inventory (2026-06-30)

| Host | Playwright CLI | Brave | Chrome | Notes |
|------|----------------|-------|--------|-------|
| Mini | ✅ Node package | ✅ | ❌ | Use the wrapper's explicit Brave executable for URL receipts |
| Air  | ❌ (browser cache only) | ✅ | ✅ | Air is the owner's workstation — don't capture here except notch verification |

The June inventory above is historical. Native desktop/menu capture was verified
on the Mini on 2026-09-07 through `mini-gui-run.sh`; use the native capture wrapper
for that work. Playwright remains the separate website capture path.
