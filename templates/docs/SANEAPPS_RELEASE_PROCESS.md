# SaneApps Release Process

> Standard operating procedure for releasing SaneApps (SaneClip, SaneBar, SaneHosts, etc.)

## Quick Start: New App Checklist

```bash
# 1. Copy templates
cp -r /Users/sj/Projects/SaneProcess/templates/* /path/to/NewApp/

# 2. Run setup script
/Users/sj/Projects/SaneProcess/scripts/setup_new_app.sh NewAppName com.newapp.app

# 3. Customize templates (search for TODO markers)
grep -r "TODO:" /path/to/NewApp/*.md

# 4. Set up GitHub repo with standard settings
# 5. Buy domain and configure DNS
# 6. Create first release
```

---

## 1. Repository Structure

Every SaneApp must have this structure:

```
AppName/
├── .github/
│   ├── FUNDING.yml              # Donation links
│   ├── PULL_REQUEST_TEMPLATE.md
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── workflows/
│       └── release.yml          # CI/CD automation
├── docs/
│   ├── index.html               # Website (Cloudflare Pages)
│   ├── appcast.xml              # Sparkle update feed
│   └── images/                  # Screenshots, og-image
├── marketing/
│   └── images/                  # App icon, screenshots
├── scripts/
│   ├── SaneMaster.rb            # Build/test/release entrypoint
│   └── generate_dmg_background.swift
├── releases/                    # DMG archive
├── Resources/
│   └── Assets.xcassets/
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE                      # MIT
├── PRIVACY.md
├── SECURITY.md
├── ROADMAP.md
├── CODE_OF_CONDUCT.md
├── project.yml                  # XcodeGen config
└── .swiftlint.yml
```

---

## 2. Required Documentation

### Core Files (Required)

| File | Purpose | Template |
|------|---------|----------|
| `README.md` | User-facing overview | `templates/README.md` |
| `CHANGELOG.md` | Version history | `templates/CHANGELOG.md` |
| `CONTRIBUTING.md` | Developer guide | `templates/CONTRIBUTING.md` |
| `LICENSE` | MIT License | `templates/LICENSE` |
| `PRIVACY.md` | Privacy policy | `templates/PRIVACY.md` |
| `SECURITY.md` | Security policy | `templates/SECURITY.md` |
| `CODE_OF_CONDUCT.md` | Community standards | `templates/CODE_OF_CONDUCT.md` |

### Optional Files (Recommended)

| File | Purpose |
|------|---------|
| `ROADMAP.md` | Feature roadmap |
| `DEVELOPMENT.md` | Dev environment setup |
| `CODE_REVIEW.md` | Security audit findings |

---

## 3. Version Management

### Semantic Versioning

```
MAJOR.MINOR.PATCH

1.0.0 - Initial release
1.1.0 - New features (backward compatible)
1.1.1 - Bug fixes
2.0.0 - Breaking changes
```

### Version Locations (Keep in Sync)

1. `project.yml` → `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`
2. `CHANGELOG.md` → Add release notes
3. `docs/appcast.xml` → Sparkle feed
4. `docs/index.html` → Download button version (optional)

---

## 4. Code Signing & Notarization

### Prerequisites

```bash
# Keychain profile for notarization (one-time setup)
xcrun notarytool store-credentials "notarytool" \
  --apple-id "your@email.com" \
  --team-id "M78L6FXD48" \
  --password "app-specific-password"
```

### Signing Identity

- **Development**: `Apple Development`
- **Release**: `Developer ID Application` (Team: M78L6FXD48)

### Release Build

```bash
# Build, sign, notarize, DMG
./scripts/SaneMaster.rb release --version 1.2.0
```

---

## 5. Distribution Channels

### Website (Paid DMG - $5)

DMGs are sold through the website via Lemon Squeezy:
- Users purchase on `appname.com`
- Receive immediate download link
- No subscriptions - one-time purchase

### GitHub (Free Source)

- Source code available for free
- Users can clone and build themselves
- Tag format: `v1.2.0` (for version tracking)
- No DMG assets in GitHub Releases

### Sparkle Auto-Updates

```xml
<item>
  <title>Version 1.2.0</title>
  <sparkle:version>3</sparkle:version>
  <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <enclosure
    url="https://dist.appname.com/updates/AppName-1.2.0.dmg"
    sparkle:edSignature="..."
    length="2000000"
    type="application/octet-stream"/>
</item>
```

---

## 6. Website Setup

### Domain & DNS (Cloudflare)

1. Buy/transfer domain to Cloudflare Registrar
2. Create Cloudflare Pages project: `appname-site`
3. Deploy website: `npx wrangler pages deploy ./docs --project-name=appname-site`
4. Add custom domain via Cloudflare API or dashboard
5. Add DNS records:
   ```
   CNAME  @    appname-site.pages.dev  (proxied)
   CNAME  www  appname.com             (proxied)
   ```

### Cloudflare Pages Deployment

```bash
# Deploy website + appcast
CLOUDFLARE_ACCOUNT_ID=2c267ab06352ba2522114c3081a8c5fa \
  npx wrangler pages deploy ./docs --project-name=appname-site \
  --commit-dirty=true --commit-message="Release vX.Y.Z"
```

**DO NOT use GitHub Pages.** All SaneApps websites are hosted on Cloudflare Pages.

### Website Checklist

- [ ] Hero section with app icon and tagline
- [ ] Feature highlights (3-4 key features)
- [ ] Screenshots/demo
- [ ] Purchase button ($5 via Lemon Squeezy)
- [ ] "Build from source" link to GitHub
- [ ] Privacy/security callout
- [ ] Links: GitHub, Support, Privacy Policy
- [ ] Open Graph meta tags (`og:image`, `og:title`, etc.)
- [ ] Twitter Card meta tags
- [ ] JSON-LD structured data (SoftwareApplication schema)
- [ ] Mobile responsive
- [ ] Dark mode support

---

## 7. Monetization & Donations

### Donation Options

Add to `.github/FUNDING.yml`:

```yaml
github: sane-apps
custom:
  - https://appname.com
```

### Crypto Addresses (Standard across SaneApps)

| Currency | Address |
|----------|---------|
| BTC | `3Go9nJu3dj2qaa4EAYXrTsTf5AnhcrPQke` |
| SOL | `FBvU83GUmwEYk3HMwZh3GBorGvrVVWSPb8VLCKeLiWZZ` |
| ZEC | `t1PaQ7LSoRDVvXLaQTWmy5tKUAiKxuE9hBN` |

### Pricing Models

- **Free + Donations**: SaneBar, SaneHosts
- **Paid ($5)**: SaneClip (via Lemon Squeezy)

---

## 8. CI/CD Automation

### GitHub Actions Workflow

See `templates/release.yml` for the standard workflow:

- Triggered on: manual dispatch, weekly schedule, or version tag
- Steps: build → sign → notarize → DMG → upload to distribution

### Required Secrets

```
APPLE_CERTIFICATE_BASE64    # Developer ID cert as base64
APPLE_CERTIFICATE_PASSWORD  # Cert password
KEYCHAIN_PASSWORD           # Temp keychain password
NOTARY_APPLE_ID             # Apple ID email
NOTARY_PASSWORD             # App-specific password
NOTARY_TEAM_ID              # M78L6FXD48
SPARKLE_PRIVATE_KEY         # EdDSA signing key
```

---

## 9. Quality Standards

### Code Style

```yaml
# .swiftlint.yml
disabled_rules:
  - line_length
  - identifier_name
opt_in_rules:
  - empty_count
  - closure_spacing
```

### Pre-commit Hooks (lefthook)

```yaml
# lefthook.yml
pre-commit:
  commands:
    swiftlint:
      run: swiftlint --strict
```

### Testing Checklist

- [ ] Unit tests pass
- [ ] UI tests pass (if any)
- [ ] Manual QA on fresh macOS install
- [ ] Notarization successful
- [ ] Sparkle update works from previous version
- [ ] Website purchase flow works

---

## 10. Release Checklist

### Pre-Release

- [ ] All tests pass
- [ ] CHANGELOG.md updated
- [ ] Version bumped in project.yml
- [ ] Screenshots updated (if UI changed)
- [ ] README.md current

### Release

```bash
# 1. Build and notarize
./scripts/SaneMaster.rb release --version X.Y.Z

# 2. Upload DMG to Cloudflare R2
npx wrangler r2 object put sanebar-downloads/AppName-X.Y.Z.dmg \
  --file=releases/AppName-X.Y.Z.dmg --content-type="application/octet-stream" --remote

# 3. Update appcast.xml
# - Add new <item> with version, signature, URL (dist.appname.com/updates/...)
# - Generate EdDSA signature: sign_update releases/AppName-X.Y.Z.dmg

# 4. Deploy website + appcast to Cloudflare Pages
CLOUDFLARE_ACCOUNT_ID=2c267ab06352ba2522114c3081a8c5fa \
  npx wrangler pages deploy ./docs --project-name=appname-site \
  --commit-dirty=true --commit-message="Release vX.Y.Z"

# 5. Commit and push
git add docs/appcast.xml
git commit -m "release: vX.Y.Z"
git push
```

### Post-Release

- [ ] Verify DMG downloads correctly from website
- [ ] Verify payment flow works
- [ ] Verify auto-update from previous version
- [ ] Announce on social media (optional)
- [ ] Close related GitHub issues

---

## 11. Shared Resources

### SaneUI Package

All apps should use the shared design system:

```yaml
# project.yml
packages:
  SaneUI:
    path: ../Projects/SaneUI
```

### Common Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| KeyboardShortcuts | 2.0.0+ | Global hotkeys |
| Sparkle | 2.6.0+ | Auto-updates |
| SaneUI | local | Design system |

---

## 12. Support & Community

### Standard Links

- **Website**: `https://appname.com`
- **GitHub**: `https://github.com/sane-apps/AppName`
- **Issues**: `https://github.com/sane-apps/AppName/issues`
- **Email**: `support@appname.com` or `security@appname.com`

### Response SLAs

- Security issues: 24-48 hours acknowledgment
- Bug reports: 1 week
- Feature requests: Best effort

---

## Appendix: Quick Commands

```bash
# Generate app icon
swift scripts/generate_icon.swift

# Generate DMG background
swift scripts/generate_dmg_background.swift

# Build release
./scripts/SaneMaster.rb release --version 1.0.0

# Skip notarization (dev testing)
./scripts/SaneMaster.rb release --skip-notarize

# Generate EdDSA signature for Sparkle
./Sparkle/bin/sign_update releases/AppName-1.0.0.dmg

# Calculate SHA256 for verification
shasum -a 256 releases/AppName-1.0.0.dmg
```
