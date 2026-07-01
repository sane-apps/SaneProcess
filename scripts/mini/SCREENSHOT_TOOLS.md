# Screenshot tooling (Mini / Air) for visual-verification receipts

The Stop-hook visual gate (`customer_facing_ui_file_edited`) requires a screenshot
receipt from a host whose name contains **`mini`** (or `air`, only for notch /
built-in-display work). Validator: `scripts/hooks/core/visual_receipt.rb` — there is
**no local fallback** for visuals, so the capture must happen on the Mini.

## One command (do this first)

```bash
scripts/mini/capture-web-screenshot.sh <url> <outputs/visual-audit-DIR> --label NAME --app APP --version VER
```
Captures the URL on the Mini via Playwright (headless), copies the PNG back, and writes a
`customer_ui_action_receipt.json` scaffold with `inspected:false`. Then **open the PNG**,
confirm the change renders, and set `inspected:true` (top-level + screenshot entry). The
gate stays red until you inspect — intentional, do not fabricate.

## Website / URL screenshots → use Playwright on the Mini (preferred)

The Mini has the `playwright` CLI (1.60.0) on PATH. Chromium is installed
(`playwright install chromium`, chromium-headless-shell cached under
`~/Library/Caches/ms-playwright`). It renders **headless / off-screen**, so there is
no GUI-session focus problem and no Codex/Terminal window contamination.

```bash
ssh stephans-mac-mini.local \
  'playwright screenshot --full-page --wait-for-timeout 4000 "https://sanebar.com" /tmp/shot.png'
scp stephans-mac-mini.local:/tmp/shot.png <app>/outputs/visual-audit-<ver>/
```

Then write `outputs/visual-audit-<ver>/customer_ui_action_receipt.json`:

```json
{
  "type": "visual_audit",
  "status": "passed",
  "host": "stephans-mac-mini.local",
  "inspected": true,
  "screenshots": [{ "path": "shot.png", "view": "...", "result": "...", "inspected": true }],
  "generated_at": "<fresh UTC ISO8601>"
}
```

`path` may be relative to the receipt's own directory. **Actually open and inspect the
PNG** before writing `inspected: true` — do not fabricate a receipt.

## macOS app-window / desktop screenshots → `capture-mini-screenshot.sh`

Use for the real SaneBar app UI (menu bar, Settings windows), not for URLs:

```bash
scripts/mini/capture-mini-screenshot.sh --app "SaneBar" --window-name "Settings" --mode temp --copy-to <dir>
scripts/mini/capture-mini-screenshot.sh desktop --copy-to <dir>
```

Caveats: it captures the Mini's live GUI session, so it **refuses** ("Mini visual
workspace dirty") when Codex/Terminal is visible, and needs the target app focused with
an inspectable window. Raw `screencapture` over ssh is blocked by `sane_bash_guards.rb`.

## Tool inventory (2026-06-30)

| Host | Playwright CLI | Brave | Chrome | Notes |
|------|----------------|-------|--------|-------|
| Mini | ✅ 1.60.0 (chromium installed) | ✅ | ❌ | Use Playwright for URL receipts |
| Air  | ❌ (browser cache only) | ✅ | ✅ | Air is the owner's workstation — don't capture here except notch verification |

`mini-gui-run.sh` was observed running in a context that could not access
`/Users/stephansmac/` — treat as unreliable for scripted screenshots; prefer Playwright.
