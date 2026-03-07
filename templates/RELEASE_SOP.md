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

Runs 9 automated safety checks without building:
1. Tests pass
2. Git working directory clean
3. UserDefaults/migration changes flagged (upgrade path test required if found)
4. Sparkle SUPublicEDKey VALUE matches shared key
5. Open GitHub issues reviewed
6. Pending customer emails checked
7. Release timing (warns on evening — 8-18hr discovery window if broken)
8. License API connectivity verified
9. Homebrew cask/tap consistency checked

**If preflight reports BLOCKED (red), fix before proceeding. Warnings (yellow) require review.**

**Hard rule (no workaround releases):**
- If any release/preflight guard fails, stop immediately.
- Fix the underlying problem first (code, config, tests, issue triage, or inbox triage).
- Verify the fix by re-running the failing check(s) and then full preflight.
- Continue release only after preflight is clean.
- Never self-approve an override to bypass a failing guard.

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

### 2. Upload to Cloudflare R2

**Use wrangler for R2 uploads (single shared bucket):**

```bash
npx wrangler r2 object put sanebar-downloads/{App}-{version}.dmg \
  --file="releases/{App}-{version}.dmg" --content-type="application/octet-stream" --remote
```

### 3. Update Appcast

Edit `docs/appcast.xml`:

```xml
<enclosure
  url="https://dist.{app}.com/updates/{App}-{version}.dmg"
  sparkle:edSignature="{signature from step 1}"
  length="{file size in bytes}"
  type="application/octet-stream" />
```

### 4. Deploy Website + Appcast to Cloudflare Pages

```bash
# Option A: Use release.sh --website-only (preferred)
bash ~/SaneApps/infra/SaneProcess/scripts/release.sh \
  --project $(pwd) --website-only

# Option B: Manual deploy
# Copy appcast into website directory
cp docs/appcast.xml website/appcast.xml

# Deploy to Cloudflare Pages
CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID \
  npx wrangler pages deploy ./website --project-name={app}-site \
  --commit-dirty=true --commit-message="Release v{version}"

# Verify:
curl -s "https://{app}.com/appcast.xml" | grep 'url="https://dist'
curl -sI "https://dist.{app}.com/updates/{App}-{version}.dmg" | grep HTTP
```

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

```bash
CF_TOKEN=$(security find-generic-password -s cloudflare -a api_token -w)

# Add worker route
curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/workers/routes" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pattern": "dist.{app}.com/*", "script": "your-dist-worker"}'

# Add DNS CNAME
curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "CNAME", "name": "dist", "content": "your-worker.workers.dev", "proxied": true}'
```

## R2 Bucket

- **Name**: `sanebar-downloads`
- **Account**: `$CLOUDFLARE_ACCOUNT_ID`
- **Usage**: Shared bucket for ALL SaneApps distribution files (.dmg and .zip)

## Critical Rules

1. **NEVER use GitHub Releases** for DMG hosting — use Cloudflare R2
2. **NEVER use GitHub Pages** for websites — use Cloudflare Pages
3. **ALWAYS sign DMGs** with Sparkle EdDSA
4. **ALWAYS verify** downloads work before announcing release
5. **Use `wrangler`** for Pages deploy and R2 uploads
6. **ONE Sparkle key per org** — store in keychain, never generate per-project keys
7. **Verify SUPublicEDKey in built Info.plist** matches your shared key before shipping
8. **Homebrew tap sync uses SSH** — `owner/repo` tap names resolve to `git@github.com:owner/repo.git` for headless push
