# SaneApps Internal Operator Setup

This file documents the private SaneApps production operator environment. It is
not required for public SaneProcess contributors. Public adopters should start
with `README.md`, `DEVELOPMENT.md`, and their own project credentials.

---

## Prerequisites

- macOS (Apple Silicon)
- Current Xcode supported by the active app projects
- Homebrew Node 24 LTS and its bundled npm
- Homebrew Ruby 4.x for SaneApps automation; macOS Ruby is bootstrap fallback only
- Python 3.14 for the shared operator baseline unless a repo has a documented pin
- [GitHub CLI](https://cli.github.com/) (`brew install gh`)

Install and verify the role-aware baseline instead of assembling versions by
hand:

```bash
ruby scripts/automation/dependency_baseline.rb --check
# Add --apply only when intentionally converging this machine.
```

Do not install global Wrangler. Release paths pin `wrangler@4.104.0` so Air and
Mini behavior cannot drift with a global npm update.

## Tool Install Log (Required)

When any new local tool is installed for build/release/test work, record it here immediately.

| Date (YYYY-MM-DD) | Machine | Tool | Version | Install command | Why installed | Verification command |
|---|---|---|---|---|---|---|
| _add row_ | `mini` / `air` | _name_ | _x.y.z_ | _exact command_ | _blocking issue or workflow need_ | _exact check command_ |

---

## 1. Cloudflare

**What it does:** Hosts all websites (Pages), distribution workers (R2 + Workers), email automation, analytics.

| Resource | Purpose |
|----------|---------|
| Workers | Download gating (sane-dist), email automation, click tracking, redirects |
| R2 Buckets | Shared distribution bucket (sanebar-downloads) for all SaneApps (.zip; legacy .dmg objects remain) |
| D1 Database | Email/customer storage |
| KV Namespace | Email caching |
| Pages | Product websites (sanebar.com, saneclick.com, etc.) |
| Email Routing | hi@saneapps.com → Worker |

**Setup:**
```bash
# Login to Cloudflare
npx --yes wrangler@4.104.0 login

# Verify access
npx --yes wrangler@4.104.0 whoami
```

**API token** (ask owner for token with these permissions):
- Account: Workers Scripts, R2, D1, KV — Edit
- Zone: DNS, Workers Routes — Edit
- All zones in account

Store in keychain:
```bash
security add-generic-password -s cloudflare -a api_token -w "YOUR_TOKEN"
```

**Wrangler vs Cloudflare API:**
- Prefer the Cloudflare REST API for admin mutations. The two standing wrangler
  exceptions are `wrangler r2` and `wrangler pages deploy` (release.sh uses
  both).
- Trap: `wrangler r2 object` commands operate on the LOCAL dev simulator unless
  you pass `--remote`. Always pass `--remote` when touching the real bucket, and
  verify the object actually landed remotely.

---

## 2. Apple Developer

**What it does:** Code signing, notarization, App Store Connect (for Fastlane).

| Credential | Value |
|-----------|-------|
| Team ID | `M78L6FXD48` |
| Signing Identity | `Developer ID Application` (Team: M78L6FXD48) |
| Primary API Key ID | `S34998ZCRT` (App Store Connect, Admin role) |
| Legacy API Key ID | `7LMFF3A258` (no local `.p8`; do not use for new work) |
| Issuer ID | `c98b1e0a-8d10-4fce-a417-536b31c09bfb` |
| .p8 Location | `~/.private_keys/AuthKey_S34998ZCRT.p8` (chmod 600) |

**App Store Connect app IDs:**

| App | ASC App ID |
|-----|-----------|
| SaneClip | `6758898132` |
| SaneSales | `6759010976` |
| SaneLot (iOS) | `6789208379` |

App Review rejection reasons and attachments are only available in the
Resolution Center on the ASC website — there is no API lane for them.

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
4. Copy `.p8` file from the account owner to `~/.private_keys/AuthKey_S34998ZCRT.p8` (chmod 600)

**Headless mini release requirements (SSH/non-interactive):**
```bash
export NOTARY_API_KEY_PATH="$HOME/.private_keys/AuthKey_S34998ZCRT.p8"
export NOTARY_API_KEY_ID="S34998ZCRT"
export NOTARY_API_ISSUER_ID="c98b1e0a-8d10-4fce-a417-536b31c09bfb"
# Validate all release gates before building/publishing:
cd ~/SaneApps/infra/SaneProcess/scripts
./release.sh --project ~/SaneApps/apps/SaneHosts --preflight-only --allow-unsynced-peer --version 1.0.9
```
If preflight reports `Codesign cannot access signing key`, run
`scripts/mini/bootstrap-build-server.sh` in the logged-in Mini session. Do not
store a login password in an environment variable or startup file.

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

Before shipping, verify the built app's `Info.plist` `SUPublicEDKey` matches the
shared public key above (release preflight checks this).

## Keychain Secrets (Quick Reference)

| Service | Account | Used by |
|---------|---------|---------|
| `cloudflare` | `api_token` | release.sh deploys, Cloudflare API |
| `lemonsqueezy` | `api_key` | sales/license tooling |
| `resend` | `api_key` | email automation |
| notarytool profile `notarytool` | — | `xcrun notarytool --keychain-profile notarytool` |

Fetch each secret once per run and reuse it — no `security` calls in loops
(see `AGENTS.md` Secrets).

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
npx --yes wrangler@4.104.0 secret put LEMONSQUEEZY_API_KEY
npx --yes wrangler@4.104.0 secret put LEMONSQUEEZY_WEBHOOK_SECRET
```

---

## 5. Resend (Email)

**What it does:** Sends emails from `hi@saneapps.com`, handles transactional email.

**Setup:**
```bash
# Store API key in keychain
security add-generic-password -s resend -a api_key -w "YOUR_KEY"

# For Cloudflare Worker
npx --yes wrangler@4.104.0 secret put RESEND_API_KEY
```

Domain `saneapps.com` is already verified in Resend.

---

## 6. GitHub

**What it does:** Source code, issues, releases, CI.

| Item | Detail |
|------|--------|
| Org | `sane-apps` |
| Repos | Active repos are discovered from `~/SaneApps/apps` and `config/products.yml`; local SaneAI/SaneSync runtime is retired |

**Setup:**
```bash
gh auth login

# For Cloudflare Worker (issue creation from emails)
npx --yes wrangler@4.104.0 secret put GITHUB_TOKEN
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
npx --yes wrangler@4.104.0 secret put API_KEY
npx --yes wrangler@4.104.0 secret put RESEND_API_KEY
npx --yes wrangler@4.104.0 secret put GITHUB_TOKEN
npx --yes wrangler@4.104.0 secret put LEMONSQUEEZY_API_KEY
npx --yes wrangler@4.104.0 secret put LEMONSQUEEZY_WEBHOOK_SECRET
npx --yes wrangler@4.104.0 secret put DOWNLOAD_SIGNING_SECRET

# Deploy
npx --yes wrangler@4.104.0 deploy
```

API key for local testing (ask owner, stored in keychain as `sane-email-automation` / `api_key`).

---

## 8. Distribution Workers (Download Gating)

**What it does:** Signed URL download system. Customers get time-limited links to release ZIPs on R2.

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
npx --yes wrangler@4.104.0 whoami

# GitHub
gh auth status

# Apple signing
security find-identity -v -p codesigning | grep "Developer ID"

# Notarization
xcrun notarytool history --keychain-profile "notarytool" | head -5

# Build an app (Mini-first: run on the Mac Mini)
ssh mini 'cd ~/SaneApps/apps/SaneHosts && ./scripts/SaneMaster.rb verify'
```

---

## Operator Conventions

- **MCP env vars go in `~/.zprofile`, not `~/.zshrc`** — GUI-launched agent
  clients only read the login profile, so `~/.zshrc`-only exports silently
  never reach MCP servers.
- **App icons:** full-square, fully opaque artwork across the entire canvas —
  no pre-rounded corners, no transparency. macOS applies the rounding mask
  itself; pre-rounded or transparent icons render smaller with a visible rim.
- **Clean relaunch pattern:** `killall AppName; sleep 1; pgrep -x AppName ||
  open -a AppName` — kill, wait, confirm it is dead, then launch, so you never
  race a dying instance.
- **Mini helper scripts + log paths:** inventoried in `scripts/mini/README.md`
  (bootstrap, screenshots, GUI-run, memory guard, weekly restart). Tunnel and
  admin details live in `DEVELOPMENT.md`.

---

## What NOT to Do

- **NEVER run Sparkle `generate_keys`** — breaks updates for shipped versions
- **NEVER commit secrets** to git — use keychain or `wrangler secret put`
- **NEVER use GitHub Releases for release ZIPs** — use Cloudflare R2 via dist.{app}.com (shipped artifacts are ZIPs; DMG wording retired 2026-07-15)
- **Never hand-create Homebrew formulas/casks** — the tap (`~/SaneApps/homebrew-tap`) is a live release channel managed by `release.sh` only (corrected 2026-07-15: the old "no Homebrew" rule is wrong — never delete the tap)
