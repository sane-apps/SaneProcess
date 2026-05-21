# SaneApps Release SOP

## Distribution Infrastructure

All SaneApps macOS apps use **Cloudflare** for update distribution:

- **Website + Appcast**: Served from `{app}.com` (Cloudflare Pages)
- **DMG Downloads**: Served from `dist.{app}.com/updates/{App}-{version}.dmg` (Cloudflare R2 via `sane-dist` Worker)
- **Worker**: `sane-dist` handles routing — `/updates/` path is public (Sparkle), root path is gated (signed URLs)

**DO NOT use GitHub Releases for DMG distribution.**

## Release Checklist

### 0. Preflight (MANDATORY — Run First)

```bash
./scripts/SaneMaster.rb release_preflight
```

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
   - `.codex/research.md` first, or the existing project research cache if a
     different active cache is already documented
   - Serena memory / knowledge graph notes for the app
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

5. If App Store Connect or Apple Developer portal state must be inspected or repaired, drive Safari on the Mini directly before looking for new browser tools.

- App Store Connect login and `developer.apple.com` login are separate. Verify both on the Mini.
- Use one Safari window and one active portal tab for App Store Connect / Apple Developer / Apple ID login work. Do not open a new ASC/developer/idmsa tab for each action; repeated tabs can invalidate the session and lock Passwords/2FA flows.
- Preferred control path is Mini Safari + AppleScript/JavaScript:
  - `tell application "Safari" to return URL of front document`
  - `tell application "Safari" to do JavaScript "document.body.innerText"` in front document
  - `~/SaneApps/infra/SaneProcess/scripts/mini/mini-safari.sh list-tabs`
  - `~/SaneApps/infra/SaneProcess/scripts/mini/mini-safari.sh open-read-current "<url>"` for ASC/developer/idmsa pages
  - `~/SaneApps/infra/SaneProcess/scripts/mini/mini-safari.sh read <tab_index>`
  - `~/SaneApps/infra/SaneProcess/scripts/mini/mini-safari.sh js <tab_index> "<javascript>"`
  - use `document.querySelector(...)` / `.click()` only after confirming the tab URL is the exact target review/profile page
- Use this path to inspect reviewer screenshots/download links, App Review page text, and Apple Developer profile detail/edit pages.
- Use the same path for listing/directory activation links when distribution status matters.
- Do not blind-click. Prove the front tab URL and visible text first.
- If a provisioning profile is stale, inspect the exact certificate shown on the Apple Developer edit page before regenerating it.

```bash
./scripts/SaneMaster.rb appstore_preflight  # active App Store lanes only
```

If the lane is disabled, do not diagnose App Store policy failures for that app as part of a normal release. Use `release_preflight` for direct-download readiness and treat App Store metadata as dormant reference until the lane is explicitly re-enabled. SaneBar and SaneClick are direct-download-only under the current strategy.

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

4. Confirm the app-specific gotchas:
- menu bar apps must report Setapp usage events such as `.userInteraction`
- arm64-only projects must not assume Setapp universal readiness without proof
- widget/extension bundle families must be reviewed explicitly if they ship in the Setapp lane

5. Confirm channel drift is not being introduced:
- direct release notes still describe the direct lane
- App Store text still describes the App Store lane
- Setapp wording stays in the Setapp-specific surfaces only

6. Confirm the built artifact, not just the source config:
- run `sanitize_distribution_bundle.rb --channel setapp /path/to/App.app`
- re-sign the sanitized bundle before launch verification
- verify the sanitized bundle has:
  - no embedded `Sparkle.framework`
  - no `SU*` keys
  - no direct key-entry / checkout copy

7. Upload through the standard Setapp lane:
- Preferred: `./scripts/SaneMaster.rb setapp_upload --zip /path/to/App-Setapp.zip --release-notes-file /path/to/notes.txt` with `SETAPP_AUTOMATION_TOKEN`.
- Fallback for the known portal defect where an in-review page shows `Reupload .ZIP` but clicking it does nothing:

```bash
./scripts/SaneMaster.rb setapp_upload \
  --portal-fallback \
  --app-id <setapp_app_id> \
  --version-id <existing_version_id> \
  --zip /path/to/App-Setapp.zip \
  --release-notes-file /path/to/notes.txt
```

- After fallback upload, verify both the Apps page and `GET /v1/versions/<version_id>` show the expected build/display versions.
- Never print or store Setapp browser `access_token` / `refresh_token` values.

### 1. Build, Sign, Notarize, DMG (Single Command)

```bash
# Unified entrypoint (uses per-project .saneprocess config)
./scripts/SaneMaster.rb release

# Full release (version bump + tests + GitHub metadata)
./scripts/SaneMaster.rb release --full --version X.Y.Z --notes "Release notes"
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
- **Usage**: Shared bucket for ALL SaneApps distribution files (.dmg and .zip)

## Critical Rules

1. **NEVER use GitHub Releases** for DMG hosting — use Cloudflare R2
2. **NEVER use GitHub Pages** for websites — use Cloudflare Pages
3. **ALWAYS sign DMGs** with Sparkle EdDSA
4. **ALWAYS verify** downloads work before announcing release
5. **Use `release.sh`** for Pages deploy and R2 uploads; raw `wrangler` is fallback-only
6. **ONE Sparkle key per org** — store in keychain, never generate per-project keys
7. **Verify SUPublicEDKey in built Info.plist** matches your shared key before shipping
8. **Homebrew tap sync uses SSH** — `owner/repo` tap names resolve to `git@github.com:owner/repo.git` for headless push
9. **Setapp is a third lane** — do not replace direct Lemon Squeezy with Stripe because Setapp uses Stripe
10. **No channel drift** — every release lane must keep its own licensing, updater, and support surfaces clean
11. **Email worker deploys need a clean repo** — if `sane-email-automation` is dirty or behind `origin/main`, the release lane should use a fresh temporary clone instead of failing or mixing unrelated worker changes into the app release
