# SaneApps Release SOP

## Distribution Infrastructure

All SaneApps macOS apps use **Cloudflare** for update distribution:

- **Website + Appcast**: Served from `{app}.com` (Cloudflare Pages)
- **ZIP Downloads**: Served from `dist.{app}.com/updates/{App}-{version}.zip` (Cloudflare R2 via `sane-dist` Worker; shipped artifacts are ZIPs — corrected 2026-07-15, DMG wording retired)
- **Worker**: `sane-dist` handles routing — `/updates/` path is public (Sparkle), root path is gated (signed URLs)

**DO NOT use GitHub Releases for release artifact distribution.**

## Release Checklist

### 0. Preflight (MANDATORY — Run First)

```bash
./scripts/SaneMaster.rb release_preflight
```

If production Swift changes touch defaults or migration behavior, first run
`./scripts/SaneMaster.rb upgrade_path_proof`. The app's `.saneprocess` must
configure `release.upgrade_path_test.command` as an argv array and set
`from_version`. A hand-written result file or source/string-only test is not
proof: the configured command must exercise the runtime upgrade path and emit
the challenge-bound result and runtime artifact requested by SaneMaster.
Preflight and full release verify the signed receipt, current source digest,
Mini runtime, versions, test count, and evidence artifact digests.

Runs automated safety checks before release, including:
1. Tests pass
2. API compatibility against `release.min_system_version`
3. Git working directory clean
4. UserDefaults/migration changes flagged (upgrade path test required if found)
5. Sparkle SUPublicEDKey VALUE matches shared key
6. Open GitHub issues reviewed
7. Pending customer emails checked
8. Release timing (warns on evening — 8-18hr discovery window if broken)
9. License API connectivity verified
10. Homebrew cask/tap consistency checked

The API compatibility gate blocks known newer-SDK symbols that can crash before launch on supported macOS versions. Example: macOS 15 direct builds must not reference the ScreenCaptureKit macOS 26 screenshot API family (`SCScreenshotConfiguration`, `SCScreenshotOutput`, `captureScreenshot(...)`) unless `.saneprocess` deliberately raises `release.min_system_version`.

**If preflight reports BLOCKED (red), fix before proceeding. Warnings (yellow) require review.**

**Hard rule (no workaround releases):**
- If any release/preflight guard fails, stop immediately.
- Fix the underlying problem first (code, config, tests, issue triage, or inbox triage).
- Verify the fix by re-running the failing check(s) and then full preflight.
- Continue release only after preflight is clean.
- Never self-approve an override to bypass a failing guard.

**Hard rule (known open bug issues):**
- Do not ship a patch while a known bug issue is still open and unreproduced, reconfirmed by customers, or explicitly confirmed as `not fixed` in the current candidate.
- `Please update and retest` is not enough if the current candidate has not been proven against the reported path.
- Before release, audit the full open bug queue, not just the current regression cluster.
- If a bug is still live, either fix it, prove it is already fixed with current evidence, or hold the release.

**Hard rule (appcast and historical downloads):**
- Never publish an appcast that points at dead download URLs.
- If appcast history is kept, every advertised enclosure URL must resolve.
- Do not delete historical direct-download binaries by default. Only purge them intentionally after also pruning any public references.
- A docs-only/appcast repair deploy is valid when the feed is wrong and the binary is not changing.

Preflight review requirement:
- Review every open bug-like GitHub issue that could plausibly affect the release, including tint/appearance, updater behavior, build-from-source, browse/focus, and layout/reset issues.
- If a bug is open only because we are waiting on reporter confirmation and we have current proof, note that explicitly before release.
- If there is no current proof, the issue is still release-blocking.

### 0a. Release Notes Audit (MANDATORY Before `--notes`)

Before drafting or approving release notes, do a customer-facing audit instead of writing bullets from memory:

1. Check recent customer promises:
   - recent email replies where I said `next build`, `next release`, or similar
   - recent GitHub issue comments with the same promise
2. Check recent research and memory:
   - `.claude/research.md` first, or the existing project research cache if a
     different active cache is already documented
   - file memory / AgentMemory notes for the app
3. Check the actual user-facing fixes since the last tag:
   - commits between tags
   - recent shipped/unshipped issue fixes
4. Make sure every customer-visible fix that shipped is either:
   - mentioned in the release notes, or
   - explicitly deferred and not claimed as shipped

Hard rule:
- Do not publish release notes that omit a fix I already promised to a customer for `the next release`.
- If a fix shipped and matters to a reporter, close the loop in both the notes and the customer follow-up.
- Release notes must reduce fear, not create it. Write calm, reassuring, benefit-first bullets.
- Do not use alarming words like `critical`, `severe`, `broken`, `failure`, `corruption`, or `regression` in customer-facing notes.
- Every bullet should answer the customer's question: `what does this do for me?`
- Prefer outcomes like `opens faster`, `stays in place after restart`, or `less nagging`, not internal causes or engineering details.

**Headless App Store rule:**
- If `.saneprocess` enables `appstore.platforms: [macos, ios]`, run the mini bootstrap before release:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/mini/bootstrap-build-server.sh
```

- Required signals before calling the machine ready:
  - `codesign:probe`
  - `asc:jwt`
  - `codesign:ios-probe` when an iOS signing identity is installed
- The release path now sets the login-keychain partition list automatically. Do not bypass that with raw `xcodebuild` unless you are intentionally doing recovery work.

### 0b. App Store Rejection / Resubmission Workflow

When App Review rejects a lane, do this in order:

1. Collect the full review package before diagnosing or replying.

- Record the exact platform, version, build, submission ID, and review date.
- Read the exact reviewer message first.
- Download every attachment from the App Review page: screenshots, video, PDF, or any other file.
- Open every downloaded image/video file locally and inspect what Apple actually captured.
- Do not draft a reviewer reply, change code, or resubmit until all reviewer evidence has been reviewed.

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/appstore_submit.rb \
  --app-id YOUR_APP_ID \
  --platform macos \
  --version X.Y.Z \
  --project-root "$(pwd)" \
  --fetch-review-package
```

- This command is the canonical evidence collector.
- It saves the reviewer message, page text, and any downloaded App Review attachments into a local evidence folder.
- Review that saved package before drafting a reviewer reply or changing code.

2. Confirm whether the rejection matches the current source tree or an older uploaded build.

- Compare the rejected version/build from App Review against the current local version/build.
- If the rejected evidence is from an older build, do not assume the current tree is still broken. Verify it.

3. Run App Store preflight before changing code only if `.saneprocess` has `appstore.enabled: true`.

4. If macOS export fails, read the full Xcode distribution logs before trying another upload.

- Inspect `IDEDistribution.standard.log`, `IDEDistributionPipeline.log`, and `IDEDistribution.verbose.log`.
- If the failure is `productbuild failed` with `errSecInteractionNotAllowed` / `CSSMERR_CSP_NO_USER_INTERACTION`, the Mini is missing headless keychain access for the installer identity.
- Fix the keychain session first. Do not retry uploads blindly.

5. If App Store Connect or Apple Developer portal state must be inspected or repaired, use the authenticated Brave session on the Mini.

- App Store Connect login and `developer.apple.com` login are separate. Verify both on the Mini.
- Use the existing authenticated Brave profile for App Store Connect / Apple Developer / Apple ID login work. Reuse a matching tab when possible; repeated login tabs can invalidate the session and lock Passwords/2FA flows.
- Preferred control path is the active Browser/Chrome control surface or `macos-automator` JXA against `Brave Browser`:
  - enumerate Brave tabs and confirm the exact URL before acting
  - read `document.body.innerText` through the active Brave tab
  - use DOM selectors and `.click()` only after confirming the exact target review/profile page
  - use `document.querySelector(...)` / `.click()` only after confirming the tab URL is the exact target review/profile page
- Use this path to inspect reviewer screenshots/download links, App Review page text, and Apple Developer profile detail/edit pages.
- Use the same path for listing/directory activation links when distribution status matters.
- Do not blind-click. Prove the front tab URL and visible text first.
- If a provisioning profile is stale, inspect the exact certificate shown on the Apple Developer edit page before regenerating it.

```bash
./scripts/SaneMaster.rb appstore_preflight  # active App Store lanes only
```

If the lane is disabled, do not diagnose App Store policy failures for that app as part of a normal release. Use `release_preflight` for direct-download readiness and treat App Store metadata as dormant reference until the lane is explicitly re-enabled. SaneClick is direct-download-only under the current strategy; SaneBar is retired (free + open source — it still ships direct-download builds but is no longer paid or advertised).

4. Fix the reviewer issue at the root:
- Accessibility request for non-accessibility use: remove the runtime path from the App Store build.
- Direct license keys / external checkout: remove them from the App Store build and use StoreKit only.
- Outside updates / Sparkle / manual update UI: remove every update check surface from the App Store build and verify the compiled artifact no longer exposes update strings or Sparkle linkage.
- Rejected IAP metadata: rotate both the `appstore.product_id` and the IAP display name before recreating the product in ASC. Apple keeps the old rejected IAP record, and duplicate names will block the replacement.
- First IAP submission blocker: if ASC leaves the replacement IAP in `READY_TO_SUBMIT`, attach it under `Included Assets > In-App Purchases and Subscriptions` on the rejected/inflight platform version page before resubmitting.
- Free plan incompleteness: verify a fresh install can complete the free path without special reviewer steps.
- `launchd` daemon / privileged helper / `SMAppService.daemon`: stop and reassess the product architecture.

5. Do **not** keep resubmitting a macOS App Store build that still depends on a `launchd` daemon, agent, or privileged helper.
- Mac App Store apps cannot ship `launchd` daemons or agents.
- Either redesign the App Store build around an App-Store-safe architecture or disable/remove the App Store lane for that app.

6. If Mini signing works only in the logged-in GUI session and plain `ssh` shells still fail with `errSecInternalComponent`, use the shared GUI runner instead of ad hoc AppleScripts:

```bash
ssh mini '~/SaneApps/infra/SaneProcess/scripts/mini/mini-gui-run.sh \
  --title "App Store archive" \
  --log-file /tmp/appstore-archive.log \
  --close-window \
  -- "cd ~/SaneApps/apps/<App> && xcodebuild archive ..."'
```

- This is the standard recovery path for GUI-only codesign access on the Mini.
- The runner must close its own Terminal window when the command is done.
- Do not leave throwaway remote Terminal windows behind after App Store work.

7. After the code fix, rerun:

```bash
./scripts/SaneMaster.rb verify
./scripts/SaneMaster.rb appstore_preflight  # active App Store lanes only
```

6. Repair the ASC lane before upload:

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/appstore_submit.rb \
  --app-id YOUR_APP_ID \
  --platform macos \
  --withdraw-version X.Y.Z

ruby ~/SaneApps/infra/SaneProcess/scripts/appstore_submit.rb \
  --app-id YOUR_APP_ID \
  --platform macos \
  --version X.Y.Z \
  --preflight-version-state
```

7. Build/export with the standard release script, then submit the pkg with `appstore_submit.rb`.
- Use full `release.sh --deploy` only when the direct channel should also ship.
- Use build/export plus `appstore_submit.rb --pkg` when you only need to repair the App Store lane.
- `release.sh` runs `./scripts/SaneMaster.rb appstore_preflight` before any active App Store submit step. Direct-download-only apps skip this lane because `.saneprocess appstore.enabled: false` is authoritative.

### 0d. Mini Visual Verification Workflow

For user-facing desktop changes, do visual verification on the Mini before release.

Preferred order:

1. Launch the signed or release-like app on the Mini:

```bash
./scripts/SaneMaster.rb test_mode --release --no-logs
```

2. Capture the live Mini window through the GUI session:

Run this wrapper from the controlling machine with Codex installed. It copies the helper to the Mini and executes the capture inside the Mini's logged-in GUI Terminal session.

```bash
~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh \
  --list-windows --app "SaneClip"

~/SaneApps/infra/SaneProcess/scripts/mini/capture-mini-screenshot.sh \
  --app "SaneClip" --window-name "Settings" --mode temp
```

- This wrapper copies the shared screenshot helper to the Mini and runs it through `mini-gui-run.sh`.
- It is the canonical live-window path.
- First use may require one-time Screen Recording permission for Terminal on the Mini.

3. If live capture is blocked, use a deterministic render artifact from tests.

- For SwiftUI settings/screens, prefer test-generated PNG renders over guessing from logs.
- Save at least one visual artifact for the release record.

Hard rule:
- Do not claim a user-facing fix is visually verified unless you have a saved screenshot/render from the Mini path or the deterministic render lane.

### 0c. Setapp Lane Prep

Treat Setapp as a separate channel, not as a direct-build shortcut.

Before any Setapp submission or handoff:

1. Confirm the business lane:
- Direct website sales stay on Lemon Squeezy.
- Setapp's Stripe onboarding does **not** replace the website/direct flow.

2. Confirm the product lane:
- separate `-setapp` bundle ID
- explicit Setapp build config
- no Sparkle in the Setapp build
- no direct key-entry / Lemon Squeezy purchase UI
- no Donate / GitHub Sponsors UI
- if the Setapp build still shares a target with the direct lane, plan a final bundle sanitation + re-sign step

3. Confirm Setapp resources and policies:
- `setappPublicKey.pem` bundled
- macOS 13+ update policy for `com.setapp.DesktopClient.SetappAgent`
- if sandboxed, `com.setapp.ProvisioningService` Mach exception
- privacy policy, terms, support email/link, and listing description are current
  in the Setapp developer account before review
- Setapp listing copy is concise, customer-facing, and focused on the app's
  actual Setapp build capabilities
- Setapp listing screenshots are sourced from the owned website's real
  app-in-use screenshots, declared in `.saneprocess` under
  `setapp.listing.screenshots`, and exported as macOS listing assets at 16:10
  with minimum 1280x800 dimensions. The manifest must also declare
  `screenshot_source`, `screenshot_asset_root`, `screenshot_roles`, and
  `setapp_url`; the first screenshots must show the actual working app, at
  least one screenshot must cover privacy/Touch ID, and the gallery must not be
  settings-heavy. Do not upload icon-only, abstract, stale, or portal-only
  screenshots when owned-site product screenshots already exist.
- Run `./scripts/SaneMaster.rb setapp_media_sync --dry-run` before upload to
  validate the declared listing screenshots, then run
  `./scripts/SaneMaster.rb setapp_media_sync --app AppName` after any listing
  screenshot change. The command uploads the manifest screenshots to the Setapp
  developer portal and re-fetches the version to verify the screenshot IDs,
  order, and any preserved non-screenshot media.

4. Confirm the app-specific gotchas:
- menu bar apps must report Setapp usage events such as `.userInteraction`
- arm64-only projects must not assume Setapp universal readiness without proof
- widget/extension bundle families must be reviewed explicitly if they ship in the Setapp lane

5. Confirm channel drift is not being introduced:
- direct release notes still describe the direct lane
- App Store text still describes the App Store lane
- Setapp wording stays in the Setapp-specific surfaces only
- Setapp **Release notes** are public customer copy. Do not put reviewer
  comments, Setapp process details, icon geometry, build/archive/signing
  details, direct-store licensing/update terms, or placeholder notes there.
  Put review-team context in the portal's **Comments for review team** field or
  in the MacPaw email thread, not in Release notes.
- Setapp release notes must be short, user-facing update copy. For a first
  launch or metadata-only correction, use a simple public note such as
  `Launch.` rather than describing the internal review fix.
- Private Setapp reviewer context must go through `--review-comments-file` or
  be explicitly skipped with `--no-review-comments-needed`. Do not rely on a
  memory-only browser step for reviewer comments.

6. Confirm the built artifact, not just the source config:
- run `sanitize_distribution_bundle.rb --channel setapp /path/to/App.app`
- re-sign the sanitized bundle before launch verification
- verify the sanitized bundle has:
  - no embedded `Sparkle.framework`
  - no `SU*` keys
  - no direct key-entry / checkout copy
  - no Lemon Squeezy, license-key, direct-download, donation, or GitHub Sponsors
    residue in the final uploaded archive
  - `CFBundleName`, `CFBundleIconFile`, `NSUpdateSecurityPolicy`,
    `MPSupportedArchitectures`, and the sibling root `AppName.png`
  - Developer ID signing, notarization/stapling, Gatekeeper acceptance, and
    quarantined launch proof from the final ZIP

7. Upload through the standard Setapp lane (CANONICAL — token first):
- **Auth**: the portal token lives in the keychain (`sane-env` /
  `SETAPP_PORTAL_TOKEN`, both machines). Load it before any Setapp command:

```bash
source ~/.config/nv/env   # exports SETAPP_PORTAL_TOKEN from the keychain
```

  `setapp_upload.rb` reads `ENV['SETAPP_PORTAL_TOKEN']` first, then falls back
  to the Brave `access_token` cookie on the Mini. Brave is the canonical
  authenticated admin browser; Safari is not a Setapp dependency. If the API returns 401 the
  token expired: harvest a fresh `access_token` cookie from a logged-in
  developer.setapp.com browser session and have the owner re-store it
  (`security add-generic-password -U -s sane-env -a SETAPP_PORTAL_TOKEN -w
  '<token>'`) — agent hooks intentionally block keychain writes. Never PRINT
  token values into logs or chat; keychain + env var only.
  (`SETAPP_AUTOMATION_TOKEN` — the official CI Bearer lane — was never
  provisioned; the portal-token lane is the working path.)
- **New public release** (the pinned version is Released/status 10 — the
  normal case): the portal API rejects PATCH with HTTP 400 "The archive tmp
  name field is forbidden". Create a NEW version record:

```bash
./scripts/SaneMaster.rb setapp_upload \
  --portal-fallback --create-version \
  --app-id <setapp_app_id> \
  --allow-needs-revision \
  --zip /path/to/App-Setapp.zip \
  --release-notes-file /path/to/notes.txt \
  --review-comments-file /path/to/private-review-comments.txt
```

  The script prints the NEW version id — update the app's `.saneprocess`
  `setapp.version_id` to it and commit. The new record lands in **Pending
  Submission** (status 1): the owner must click **Submit for review** in the
  portal.
- **Reupload during review** (version is In Review / Needs Revision and the
  portal's `Reupload .ZIP` button is broken): same command WITHOUT
  `--create-version`, adding `--version-id <pinned_version_id>` — this PATCHes
  the existing record.
- After upload, verify both the Apps page and `GET /v1/versions/<version_id>`
  show the expected build/display versions (the script also downloads the
  hosted archive and proves SHA256 byte-match against the local zip).
- After any `setapp_media_sync`, verify the public `https://setapp.com/apps/...`
  page. A successful portal sync is necessary but not sufficient because the
  public listing page may continue serving older cached/generated screenshot
  URLs until Setapp's public layer refreshes.
- Approval is not release. If the Setapp portal says the version is waiting for
  manual release, release it in the portal, wait for the public state to update,
  and rerun `./scripts/SaneMaster.rb setapp_status` until it shows released/live
  with no action required.

### 1. Build, Sign, Notarize, ZIP (Single Command)

```bash
# Canonical release entrypoint (Corrected 2026-07-15: the old
# `SaneMaster.rb release` recipe is retired)
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh --project <app-dir> --full --deploy
```

For dual-platform App Store releases, `release.sh` is still the primary path. If the iOS leg needs recovery after a partial release, the known-good fallback is:

```bash
# 1. Archive the iOS scheme
xcodebuild archive \
  -project AppName.xcodeproj \
  -scheme AppNameIOS \
  -configuration Release-AppStore \
  -archivePath build/AppName-iOS.xcarchive \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates

# 2. Export the IPA with ASC auth
xcodebuild -exportArchive \
  -archivePath build/AppName-iOS.xcarchive \
  -exportPath build/Export-AppStore-iOS \
  -exportOptionsPlist build/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_AUTH_KEY_PATH" \
  -authenticationKeyID "$ASC_AUTH_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_AUTH_ISSUER_ID"

# 3. Submit the exported IPA
ruby ~/SaneApps/infra/SaneProcess/scripts/appstore_submit.rb \
  --pkg build/Export-AppStore-iOS/AppName.ipa \
  --app-id YOUR_APP_ID \
  --version X.Y.Z \
  --platform ios \
  --project-root "$(pwd)"
```

If App Store Connect has a stale editable lane, repair it first:

```bash
ruby ~/SaneApps/infra/SaneProcess/scripts/appstore_submit.rb \
  --app-id YOUR_APP_ID \
  --platform ios \
  --version X.Y.Z \
  --repair-version-state \
  --preflight-version-state
```

### 2. Publish Through The Release Wrapper

The release wrapper owns R2 upload, appcast update, website/appcast deployment,
postflight checks, and receipt creation. Do not run raw `wrangler` for a normal
release.

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project "$(pwd)" --full --version X.Y.Z --notes "Customer-facing release notes" --deploy
```

### 3. Website-Only Deploy

Use this for website copy/media/appcast-only changes:

```bash
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project "$(pwd)" --website-only
```

### 4. Verify Live Surfaces

```bash
./scripts/SaneMaster.rb release_postflight --version X.Y.Z --build BUILD
```

Manual `wrangler` commands are fallback-only. Use them only after the wrapper
fails, the failure is understood, and the user approves the fallback. Record the
reason in `SESSION_HANDOFF.md`.

### 5. Commit & Push

```bash
git add docs/appcast.xml Config/Shared.xcconfig
git commit -m "release: v{version}"
git push
```

## Worker Routes

| Domain | Zone ID |
|--------|---------|
| dist.yourapp.com | YOUR_ZONE_ID |

### Adding New App Route

Use the Cloudflare dashboard or add a guarded SaneMaster automation before making
repeatable DNS/route changes. Do not paste raw Cloudflare API curls into a normal
release session.

## R2 Bucket

- **Name**: `sanebar-downloads`
- **Account**: `$CLOUDFLARE_ACCOUNT_ID`
- **Usage**: Shared bucket for ALL SaneApps distribution files (.zip; legacy .dmg objects remain)

## Critical Rules

1. **NEVER use GitHub Releases** for release ZIP hosting — use Cloudflare R2
2. **NEVER use GitHub Pages** for websites — use Cloudflare Pages
3. **ALWAYS sign release ZIPs** with Sparkle EdDSA
4. **ALWAYS verify** downloads work before announcing release
5. **Use `release.sh`** for Pages deploy and R2 uploads; raw `wrangler` is fallback-only
6. **ONE Sparkle key per org** — store in keychain, never generate per-project keys
7. **Verify SUPublicEDKey in built Info.plist** matches your shared key before shipping
8. **Homebrew tap sync uses SSH** — `owner/repo` tap names resolve to `git@github.com:owner/repo.git` for headless push
9. **Setapp is a third lane** — do not replace direct Lemon Squeezy with Stripe because Setapp uses Stripe
10. **No channel drift** — every release lane must keep its own licensing, updater, and support surfaces clean
11. **Email worker deploys need a clean repo** — if `sane-email-automation` is dirty or behind `origin/main`, the release lane should use a fresh temporary clone instead of failing or mixing unrelated worker changes into the app release
