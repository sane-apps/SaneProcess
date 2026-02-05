# Sane* Apps Founder Checklist

> **For the non-coder founder who wants to do things right**
> Work through this step-by-step. No rush. Each section is independent.
>
> Trigger: "founder checklist" or "what's missing from my apps"

---

## How to Use This

1. Start a session in SaneProcess: `sp`
2. Say: "Let's work on the founder checklist"
3. Pick ONE section to tackle
4. Check off items as you complete them
5. Don't try to do everything at once

---

## Section 1: Legal Protection (Do First)

**Why**: Protects you from lawsuits and sets clear expectations.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 1.1 | Create Privacy Policy page | All | [ ] | What data you collect (even if none) |
| 1.2 | Create Terms of Service | All | [ ] | User agreements, liability limits |
| 1.3 | Add Privacy Policy link to app Settings | All | [ ] | Required by Apple |
| 1.4 | Add refund policy to SaneClip checkout | SaneClip | [ ] | Lemon Squeezy settings |
| 1.5 | Review MIT license for paid app | SaneClip | [ ] | MIT = anyone can copy. Is that OK? |
| 1.6 | Consider trademark search | All | [ ] | Are "SaneBar" etc. available? |
| 1.7 | Add GDPR notice if serving EU | All | [ ] | Cookie consent, data rights |

**Resources**:
- Free privacy policy generator: termly.io
- Free ToS generator: termsfeed.com

---

## Section 2: Know When Things Break

**Why**: Users won't tell you when your app crashes. You need to know.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 2.1 | Sign up for TelemetryDeck | - | [ ] | Privacy-focused, free tier |
| 2.2 | Add TelemetryDeck SDK to SaneBar | SaneBar | [ ] | ~10 lines of code |
| 2.3 | Add TelemetryDeck SDK to SaneClip | SaneClip | [ ] | Same pattern |
| 2.4 | Add TelemetryDeck SDK to SaneHosts | SaneHosts | [ ] | When ready |
| 2.5 | Set up crash alerting | All | [ ] | Get notified on crashes |
| 2.6 | Sign up for UptimeRobot | - | [ ] | Free, monitors websites |
| 2.7 | Add monitors for sanebar.com | SaneBar | [ ] | Alert when down |
| 2.8 | Add monitors for saneclip.com | SaneClip | [ ] | Alert when down |
| 2.9 | Add monitors for appcast.xml URLs | All | [ ] | Auto-update must work |

**Accounts to Create**:
- [ ] TelemetryDeck.com (analytics + crashes)
- [ ] UptimeRobot.com (website monitoring)

---

## Section 3: Know Your Users

**Why**: You're building blind without knowing who uses your apps.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 3.1 | Add anonymous app launch tracking | All | [ ] | Just count, don't spy |
| 3.2 | Add feature usage tracking | All | [ ] | Which features are popular? |
| 3.3 | Add version distribution tracking | All | [ ] | Are users updating? |
| 3.4 | Set up Plausible for websites | All | [ ] | Privacy-focused web analytics |
| 3.5 | Track download button clicks | All | [ ] | How many downloads? |
| 3.6 | Create a simple dashboard | - | [ ] | One place to see all metrics |

**What to Track (Privacy-Safe)**:
- App launches (daily active users)
- macOS version distribution
- App version distribution
- Feature usage counts (not user behavior)

---

## Section 4: Disaster Recovery

**Why**: What happens if your Mac dies, you're unavailable, or Apple revokes something?

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 4.1 | Export Developer ID certificate | - | [ ] | Save .p12 to secure location |
| 4.2 | Document all keychain profiles | - | [ ] | What's stored where |
| 4.3 | Back up Sparkle private keys | All | [ ] | Can't update without these |
| 4.4 | Document domain registrar logins | - | [ ] | Where are domains registered? |
| 4.5 | Note certificate expiry date | - | [ ] | Set calendar reminder |
| 4.6 | Note domain expiry dates | - | [ ] | Set calendar reminders |
| 4.7 | Create emergency contact doc | - | [ ] | If you're unavailable |
| 4.8 | Test restore on different Mac | - | [ ] | Can you actually recover? |
| 4.9 | Back up API key file (.p8) | - | [ ] | Save to secure location |

**Create a Secure Document With**:
```
- Apple Developer account login
- Keychain profile names and what they contain
- Certificate expiry: [DATE]
- Domain expiry: sanebar.com [DATE], saneclip.com [DATE]
- Sparkle private keys (or where they're stored)
- Lemon Squeezy login
```

---

## Section 5: User Support

**Why**: Happy users = word of mouth = growth.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 5.1 | Create support email | All | [ ] | hi@saneapps.com (already exists) |
| 5.2 | Add support email to websites | All | [ ] | Visible contact method |
| 5.3 | Add support link to app menus | All | [ ] | Help → Contact Support |
| 5.4 | Create FAQ page | All | [ ] | Common questions |
| 5.5 | Create keyboard shortcuts guide | SaneBar, SaneClip | [ ] | Users love these |
| 5.6 | Add "What's New" on update | All | [ ] | Show changelog in app |
| 5.7 | Create simple status page | All | [ ] | status.sanebar.com? |
| 5.8 | Set up canned responses | - | [ ] | Quick replies to common issues |

---

## Section 6: Marketing & Growth

**Why**: Great apps don't sell themselves. People need to find you.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 6.1 | Create press kit folder | All | [ ] | Hi-res assets for journalists |
| 6.2 | Write one-paragraph pitch | All | [ ] | For each app |
| 6.3 | Collect testimonials | All | [ ] | Ask happy users |
| 6.4 | Add testimonials to websites | All | [ ] | Social proof |
| 6.5 | Create Product Hunt listing | SaneBar | [ ] | Free visibility |
| 6.6 | Create Product Hunt listing | SaneClip | [ ] | Free visibility |
| 6.7 | Set up email list | All | [ ] | Buttondown.email is simple |
| 6.8 | Add email signup to websites | All | [ ] | "Get notified of updates" |
| 6.9 | Create Twitter/X presence | - | [ ] | @SaneApps? |
| 6.10 | Submit to macOS app directories | All | [ ] | macupdate.com, etc. |
| 6.11 | Write a blog post about each app | All | [ ] | SEO + story |
| 6.12 | Consider Mac App Store | SaneBar | [ ] | Free apps get visibility |

**Press Kit Contents**:
```
/press/
├── icon-1024.png
├── icon-512.png
├── screenshot-main.png
├── screenshot-settings.png
├── logo-dark.svg
├── logo-light.svg
├── one-pager.pdf (description + features)
└── founder-photo.jpg (optional)
```

---

## Section 7: App Store Consideration

**Why**: Even free apps benefit from App Store visibility.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 7.1 | Research App Store requirements | - | [ ] | Sandboxing, review guidelines |
| 7.2 | Evaluate sandboxing feasibility | SaneBar | [ ] | Menu bar apps are tricky |
| 7.3 | Evaluate sandboxing feasibility | SaneClip | [ ] | Clipboard access needs |
| 7.4 | Create App Store screenshots | All | [ ] | Specific dimensions required |
| 7.5 | Write App Store descriptions | All | [ ] | Different from website |
| 7.6 | Decide: App Store or direct only | All | [ ] | Pros/cons for each |

**App Store Pros**: Discoverability, trust, automatic updates
**App Store Cons**: 30% cut, sandboxing limits, review delays

---

## Section 8: Code Quality & Security

**Why**: Protect users and yourself from vulnerabilities.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 8.1 | Add SECURITY.md to repos | All | [ ] | How to report vulnerabilities |
| 8.2 | Set up Dependabot | All | [ ] | Auto-update dependencies |
| 8.3 | Review hardened runtime settings | All | [ ] | Security best practices |
| 8.4 | Audit for sensitive data logging | All | [ ] | Don't log passwords/keys |
| 8.5 | Add security contact email | All | [ ] | hi@saneapps.com (already exists) |
| 8.6 | Consider security audit | All | [ ] | For paid apps especially |

---

## Section 9: Accessibility

**Why**: More users, and it's the right thing to do.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 9.1 | Test with VoiceOver | All | [ ] | Can blind users navigate? |
| 9.2 | Add accessibility labels | All | [ ] | Describe UI elements |
| 9.3 | Test keyboard-only navigation | All | [ ] | No mouse required |
| 9.4 | Check color contrast | All | [ ] | WCAG guidelines |
| 9.5 | Add to accessibility statement | All | [ ] | What's supported |

---

## Section 10: Future-Proofing

**Why**: Think ahead to avoid rework.

| # | Task | Project | Status | Notes |
|---|------|---------|--------|-------|
| 10.1 | Plan localization strategy | All | [ ] | Support other languages? |
| 10.2 | Set up string localization | All | [ ] | Even if English-only now |
| 10.3 | Document architecture decisions | All | [ ] | Why things are built this way |
| 10.4 | Create roadmap | All | [ ] | Public or private |
| 10.5 | Plan iOS/iPadOS versions | SaneClip | [ ] | Clipboard manager on iOS? |
| 10.6 | Consider subscription model | SaneClip | [ ] | Recurring revenue? |

---

## Priority Order (Suggested)

### Week 1: Legal + Safety
- [ ] Privacy Policy (1.1-1.4)
- [ ] Crash reporting setup (2.1-2.5)
- [ ] Uptime monitoring (2.6-2.9)

### Week 2: Know Your Users
- [ ] Analytics setup (3.1-3.5)
- [ ] Document credentials (4.1-4.9)

### Week 3: Support + Marketing
- [ ] Support email + FAQ (5.1-5.4)
- [ ] Press kit (6.1-6.4)

### Week 4+: Growth
- [ ] Product Hunt launches (6.5-6.6)
- [ ] Email list (6.7-6.8)
- [ ] Testimonials (6.3-6.4)

---

## Tools Summary

| Tool | Purpose | Cost | URL |
|------|---------|------|-----|
| TelemetryDeck | Analytics + Crashes | Free tier | telemetrydeck.com |
| UptimeRobot | Website monitoring | Free tier | uptimerobot.com |
| Plausible | Web analytics | $9/mo | plausible.io |
| Buttondown | Email list | Free tier | buttondown.email |
| Termly | Privacy policy | Free | termly.io |
| 1Password | Credential backup | $3/mo | 1password.com |

---

## Notes & Progress

*Add your notes here as you work through the list*

```
Date:
Section worked on:
Completed:
Next up:
Blockers:
```

---

## Remember

> "Perfect is the enemy of done."

You don't need to do everything. Pick what matters most for YOUR goals:
- **Want revenue?** Focus on marketing (Section 6)
- **Want peace of mind?** Focus on monitoring (Section 2)
- **Want to scale?** Focus on automation and docs (Section 4)
- **Want to sleep at night?** Focus on legal (Section 1)

Start anywhere. Make progress. Iterate.
