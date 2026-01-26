# SaneApps Release SOP

## Distribution Infrastructure

All SaneApps macOS apps use **Cloudflare** for update distribution:

- **Website + Appcast**: Served from `{app}.com` (Cloudflare Pages)
- **DMG Downloads**: Served from `dist.{app}.com/updates/{App}-{version}.dmg` (Cloudflare R2 via `sane-dist` Worker)
- **Worker**: `sane-dist` handles routing — `/updates/` path is public (Sparkle), root path is gated (signed URLs)

**DO NOT use GitHub Releases for DMG distribution.**

## Release Checklist

### 1. Build & Sign DMG

```bash
# Build release archive
xcodebuild archive -project {App}.xcodeproj -scheme {App} -configuration Release -archivePath /tmp/{App}.xcarchive

# Export DMG (or use create-dmg)
# Sign with Sparkle
sign_update /path/to/{App}-{version}.dmg --account "EdDSA Private Key"
```

### 2. Upload to Cloudflare R2

**Use Cloudflare API directly (NOT wrangler):**

```bash
CF_TOKEN=$(security find-generic-password -s cloudflare -a api_token -w)
CF_ACCOUNT="2c267ab06352ba2522114c3081a8c5fa"

curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/r2/buckets/sanebar-downloads/objects/{App}-{version}.dmg" \
  -H "Authorization: Bearer $CF_TOKEN" \
  --data-binary @/path/to/{App}-{version}.dmg
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
# Copy appcast into website directory
cp docs/appcast.xml website/appcast.xml

# Deploy to Cloudflare Pages
CLOUDFLARE_ACCOUNT_ID=2c267ab06352ba2522114c3081a8c5fa \
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
| dist.saneclip.com | cae3f0bc51596ed8ab14516f012d7db6 |
| dist.sanebar.com | 97c0a91a13da737d28a56469157a5b46 |
| dist.sanehosts.com | 07f406512f51b01fa66c5a7a55df9a28 |

### Adding New App Route

```bash
CF_TOKEN=$(security find-generic-password -s cloudflare -a api_token -w)

# Add worker route
curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/workers/routes" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"pattern": "dist.{app}.com/*", "script": "sane-dist"}'

# Add DNS CNAME
curl -X POST "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type": "CNAME", "name": "dist", "content": "sane-dist.saneapps.workers.dev", "proxied": true}'
```

## R2 Bucket

- **Name**: `sanebar-downloads`
- **Account**: `2c267ab06352ba2522114c3081a8c5fa`
- **Usage**: Stores all DMGs for all apps

## Critical Rules

1. **NEVER use GitHub Releases** for DMG hosting — use Cloudflare R2
2. **NEVER use GitHub Pages** for websites — use Cloudflare Pages
3. **ALWAYS sign DMGs** with Sparkle EdDSA
4. **ALWAYS verify** downloads work before announcing release
5. **Use `wrangler`** for Pages deploy and R2 uploads (Cloudflare API for everything else)
