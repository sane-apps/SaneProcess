# SaneApps Developer Setup

Guide for new developers to get all APIs and services working.

---

## Prerequisites

- macOS (Apple Silicon)
- Xcode 16+
- Node.js 18+ (for Cloudflare Workers)
- Ruby 3+ (for build scripts)
- [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/) (`npm i -g wrangler`)
- [GitHub CLI](https://cli.github.com/) (`brew install gh`)

---

## 1. Cloudflare

**What it does:** Hosts all websites (Pages), distribution workers (R2 + Workers), email automation, analytics.

| Resource | Purpose |
|----------|---------|
| Workers | Download gating (sane-dist), email automation, click tracking, redirects |
| R2 Buckets | DMG file storage per app (sanebar-dist, saneclick-dist, etc.) |
| D1 Database | Email/customer storage |
| KV Namespace | Email caching |
| Pages | Product websites (sanebar.com, saneclick.com, etc.) |
| Email Routing | hi@saneapps.com → Worker |

**Setup:**
```bash
# Login to Cloudflare
npx wrangler login

# Verify access
npx wrangler whoami
```

**API token** (ask owner for token with these permissions):
- Account: Workers Scripts, R2, D1, KV — Edit
- Zone: DNS, Workers Routes — Edit
- All zones in account

Store in keychain:
```bash
security add-generic-password -s cloudflare -a api_token -w "YOUR_TOKEN"
```

---

## 2. Apple Developer

**What it does:** Code signing, notarization, App Store Connect (for Fastlane).

| Credential | Value |
|-----------|-------|
| Team ID | `M78L6FXD48` |
| Signing Identity | `Developer ID Application` (Team: M78L6FXD48) |
| Primary API Key ID | `S34998ZCRT` (SaneApps — Admin access) |
| Issuer ID | `c98b1e0a-8d10-4fce-a417-536b31c09bfb` |
| .p8 Location | `~/.private_keys/AuthKey_S34998ZCRT.p8` |

**Setup:**
1. Get invited to the Apple Developer team
2. Install signing certificate in Keychain Access
3. Store notarization profile:
```bash
xcrun notarytool store-credentials "notarytool" \
  --key ~/.private_keys/AuthKey_S34998ZCRT.p8 \
  --key-id S34998ZCRT \
  --issuer c98b1e0a-8d10-4fce-a417-536b31c09bfb
```
4. Copy `.p8` file from owner to `~/.private_keys/AuthKey_S34998ZCRT.p8` (chmod 600)

---

## 3. Sparkle (Auto-Updates)

**What it does:** In-app update mechanism for all macOS apps.

**ONE shared EdDSA key for ALL SaneApps.**

| Item | Value |
|------|-------|
| Public key (SUPublicEDKey) | `7Pl/8cwfb2vm4Dm65AByslkMCScLJ9tbGlwGGx81qYU=` |
| Private key location | macOS Keychain, account: `EdDSA Private Key` |

**Setup:** Ask owner to export the Sparkle private key. Import it:
```bash
# The key is stored under the Sparkle keychain service
# Owner will provide the base64 private key to import
```

**NEVER run `generate_keys`** — that creates a new keypair and breaks updates for shipped versions.

---

## 4. LemonSqueezy (Payments)

**What it does:** Payment processing, license keys, checkout pages.

| Item | Detail |
|------|--------|
| Store | `saneapps.lemonsqueezy.com` |
| Checkout URLs | Via `go.saneapps.com` redirect Worker |

**Setup:**
```bash
# Store API key in keychain
security add-generic-password -s lemonsqueezy -a api_key -w "YOUR_KEY"

# For Cloudflare Worker (email automation)
cd ~/SaneApps/infra/sane-email-automation
npx wrangler secret put LEMONSQUEEZY_API_KEY
npx wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET
```

---

## 5. Resend (Email)

**What it does:** Sends emails from `hi@saneapps.com`, handles transactional email.

**Setup:**
```bash
# Store API key in keychain
security add-generic-password -s resend -a api_key -w "YOUR_KEY"

# For Cloudflare Worker
npx wrangler secret put RESEND_API_KEY
```

Domain `saneapps.com` is already verified in Resend.

---

## 6. GitHub

**What it does:** Source code, issues, releases, CI.

| Item | Detail |
|------|--------|
| Org | `sane-apps` |
| Repos | SaneBar, SaneClick, SaneClip, SaneHosts, SaneSync, SaneVideo, sane-email-automation |

**Setup:**
```bash
gh auth login

# For Cloudflare Worker (issue creation from emails)
npx wrangler secret put GITHUB_TOKEN
```

---

## 7. Email Automation Worker

**What it does:** Receives hi@saneapps.com, AI-categorizes, auto-responds, creates GitHub issues.

All `/api/*` endpoints require bearer token auth.

**Setup (after getting access to Cloudflare):**
```bash
cd ~/SaneApps/infra/sane-email-automation
npm install

# Set all secrets
npx wrangler secret put API_KEY
npx wrangler secret put RESEND_API_KEY
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put LEMONSQUEEZY_API_KEY
npx wrangler secret put LEMONSQUEEZY_WEBHOOK_SECRET
npx wrangler secret put DOWNLOAD_SIGNING_SECRET

# Deploy
npx wrangler deploy
```

API key for local testing (ask owner, stored in keychain as `sane-email-automation` / `api_key`).

---

## 8. Distribution Workers (Download Gating)

**What it does:** Signed URL download system. Customers get time-limited links to DMGs on R2.

Each app has a dist worker at `dist.{appname}.com` with a shared signing secret.

**Setup:**
```bash
# Store signing secret in keychain
security add-generic-password -s sanebar-dist -a signing_secret -w "YOUR_SECRET"
```

The signing secret must match the `SIGNING_SECRET` Worker secret on Cloudflare.

---

## 9. X/Twitter (Optional)

**What it does:** Social media posting via API.

**Setup:**
```bash
security add-generic-password -s x-api -a consumer_key -w "KEY"
security add-generic-password -s x-api -a consumer_secret -w "SECRET"
security add-generic-password -s x-api -a access_token -w "TOKEN"
security add-generic-password -s x-api -a access_token_secret -w "SECRET"
```

---

## Domains

| Domain | Purpose | Hosting |
|--------|---------|---------|
| sanebar.com | Product site + appcast | Cloudflare Pages |
| saneclick.com | Product site + appcast | Cloudflare Pages |
| saneclip.com | Product site + appcast | Cloudflare Pages |
| sanehosts.com | Product site + appcast | Cloudflare Pages |
| sanesync.com | Product site | Cloudflare Pages |
| sanevideo.com | Product site | Cloudflare Pages |
| saneapps.com | Main brand site + email | Cloudflare Pages |
| dist.*.com | Download gating | Cloudflare Workers + R2 |
| go.saneapps.com | Checkout redirects | Cloudflare Worker |
| email-api.saneapps.com | Email automation API | Cloudflare Worker |

---

## Quick Verification

After setup, verify everything works:

```bash
# Cloudflare
npx wrangler whoami

# GitHub
gh auth status

# Apple signing
security find-identity -v -p codesigning | grep "Developer ID"

# Notarization
xcrun notarytool history --keychain-profile "notarytool" | head -5

# Build SaneBar
cd ~/SaneApps/apps/SaneBar
./scripts/SaneMaster.rb verify
```

---

## What NOT to Do

- **NEVER run Sparkle `generate_keys`** — breaks updates for shipped versions
- **NEVER commit secrets** to git — use keychain or `wrangler secret put`
- **NEVER use GitHub Releases for DMGs** — use Cloudflare R2 via dist.{app}.com
- **NEVER create Homebrew formulas** — distribution is Cloudflare R2 + Sparkle only
