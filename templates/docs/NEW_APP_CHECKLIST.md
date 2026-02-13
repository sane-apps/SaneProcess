# New SaneApp Checklist

> Complete checklist for launching a new SaneApp

## Phase 1: Setup (Day 1)

### Repository Setup
- [ ] Run setup script: `./scripts/setup_new_app.sh AppName com.appname.app`
- [ ] Create GitHub repo: `gh repo create sane-apps/AppName --public`
- [ ] Push initial commit
- [ ] Add GitHub Secrets for CI/CD:
  - `APPLE_CERTIFICATE_BASE64`
  - `APPLE_CERTIFICATE_PASSWORD`
  - `KEYCHAIN_PASSWORD`
  - `NOTARY_APPLE_ID`
  - `NOTARY_PASSWORD`
  - `NOTARY_TEAM_ID`
  - `SPARKLE_PRIVATE_KEY`

### Domain Setup
- [ ] Buy/transfer domain to Cloudflare Registrar
- [ ] Create Cloudflare Pages project: `appname-site`
- [ ] Configure DNS in Cloudflare:
  - CNAME `@` → `appname-site.pages.dev` (proxied)
  - CNAME `www` → `appname.com` (proxied)
  - CNAME `dist` → `sane-dist.saneapps.workers.dev` (proxied)
- [ ] Add custom domain to Pages project
- [ ] Verify HTTPS working

### Project Configuration
- [ ] Generate Sparkle EdDSA key pair
- [ ] Add `SUPublicEDKey` to project.yml
- [ ] Store private key securely
- [ ] Customize bundle ID in project.yml
- [ ] Set initial version (1.0.0)

## Phase 2: Documentation (Day 1-2)

### Required Files (search and replace TODO:)
- [ ] README.md - Description, features, installation
- [ ] CHANGELOG.md - Initial release notes
- [ ] CONTRIBUTING.md - Review dev setup instructions
- [ ] LICENSE - Verify MIT license
- [ ] PRIVACY.md - Document permissions and data storage
- [ ] SECURITY.md - Document security model
- [ ] CODE_OF_CONDUCT.md - Usually no changes needed
- [ ] .github/FUNDING.yml - Verify donation links

### Website (docs/)
- [ ] Create index.html (copy from SaneClip/SaneBar and customize)
- [ ] Add og-image.png (1200x630 for social previews)
- [ ] Add favicon
- [ ] Add screenshots
- [ ] Test mobile responsiveness
- [ ] Verify Open Graph tags work (use ogp.me debugger)
- [ ] Add robots.txt and sitemap.xml for SEO
- [ ] Deploy to Cloudflare Pages: `npx wrangler pages deploy ./docs --project-name=appname-site`

### Brand Consistency (Required)
- [ ] Footer includes: "Part of the Sane Apps family" with link to saneapps.com
- [ ] Footer includes GitHub Sponsors link: github.com/sponsors/sane-apps
- [ ] Privacy pledge in footer: "0% Telemetry. 0% Spying. 100% On-Device."
- [ ] Copyright: "&copy; 2026 AppName"
- [ ] Contact email in footer or about page

### Distribution Model
- [ ] $5 one-time purchase on website for signed/notarized DMG
- [ ] Free source on GitHub (MIT license)
- [ ] NO Homebrew cask (users build from source or pay)
- [ ] Download button links to purchase flow OR GitHub Releases
- [ ] Appcast URL points to appname.com/appcast.xml

## Phase 3: Development (Days 2-7)

### Core Functionality
- [ ] Implement main features
- [ ] Add keyboard shortcuts (if applicable)
- [ ] Add settings view
- [ ] Add menu bar icon (if applicable)
- [ ] Integrate SaneUI components

### Testing
- [ ] Write unit tests
- [ ] Manual QA checklist
- [ ] Test on fresh macOS install
- [ ] Test with different system settings

### Polish
- [ ] App icon in all sizes (16-512 @1x and @2x)
- [ ] About window with version info
- [ ] Help menu / documentation links

## Phase 4: Release Prep (Day 7-8)

### Build & Sign
- [ ] Build release: `./scripts/SaneMaster.rb release --skip-notarize`
- [ ] Test the DMG on another Mac
- [ ] Full release with notarization: `./scripts/SaneMaster.rb release --version 1.0.0`
- [ ] Verify notarization: `spctl --assess -v /path/to/app.app`

### Update Feeds
- [ ] Update docs/appcast.xml with first release
- [ ] Sign update with EdDSA key
### Final Checks
- [ ] All TODO: markers resolved
- [ ] Version consistent across all files
- [ ] Download links work
- [ ] Payment flow works on website

## Phase 5: Launch (Day 8)

### Release
- [ ] Upload DMG to Cloudflare R2: `npx wrangler r2 object put sanebar-downloads/AppName-1.0.0.dmg --file=releases/AppName-1.0.0.dmg --remote`
- [ ] Deploy website + appcast to Cloudflare Pages
- [ ] Tag: `git tag v1.0.0 && git push origin v1.0.0`

### Announcement (optional)
- [ ] Product Hunt
- [ ] Reddit (r/macapps, relevant subreddits)
- [ ] Hacker News
- [ ] Twitter/X
- [ ] Mastodon

### Post-Launch
- [ ] Monitor GitHub issues
- [ ] Respond to feedback
- [ ] Plan v1.1 features

---

## Quick Reference

### Key URLs After Launch
- Website: https://appname.com
- GitHub: https://github.com/sane-apps/AppName
- Releases: https://github.com/sane-apps/AppName/releases
- Issues: https://github.com/sane-apps/AppName/issues
- Purchase: $5 at appname.com
- Appcast: https://appname.com/appcast.xml

### Key Files to Update Each Release
1. `project.yml` - MARKETING_VERSION, CURRENT_PROJECT_VERSION
2. `CHANGELOG.md` - Release notes
3. `docs/appcast.xml` - New item with EdDSA signature
4. `docs/index.html` - Download button version (optional)

### Secrets Reference
| Secret | Source |
|--------|--------|
| APPLE_CERTIFICATE_BASE64 | Export from Keychain, base64 encode |
| APPLE_CERTIFICATE_PASSWORD | Password used when exporting |
| KEYCHAIN_PASSWORD | Any secure password for CI keychain |
| NOTARY_APPLE_ID | Apple ID email |
| NOTARY_PASSWORD | App-specific password from appleid.apple.com |
| NOTARY_TEAM_ID | M78L6FXD48 |
| SPARKLE_PRIVATE_KEY | From `./Sparkle/bin/generate_keys` |
