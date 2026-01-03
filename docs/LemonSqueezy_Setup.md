# Sane Suite - LemonSqueezy Product Setup

## Quick Start

1. Sign up at [lemonsqueezy.com](https://lemonsqueezy.com)
2. Create a Store called "Sane Labs" or "Sane Suite"
3. Add products below in order
4. Set up the bundle last (it references other products)

---

## Store Settings

**Store Name:** Sane Labs
**Store URL:** `sane.lemonsqueezy.com` (or custom domain later)
**Logo:** Use a clean wordmark or simple icon
**Brand Color:** `#10B981` (emerald green) or `#3B82F6` (blue)

---

## Product 1: SaneProcess

### Basic Info
- **Name:** SaneProcess
- **Type:** Digital Download
- **Price:** $29 (one-time)
- **URL slug:** `saneprocess`

### Description (Short)
```
Battle-tested SOP for Claude Code. Stop AI doom loops with circuit breakers, memory persistence, and 11 Golden Rules.
```

### Description (Long)
```
SaneProcess turns "AI that sometimes helps" into "AI that reliably ships code."

## What You Get

- Complete SOP document (Markdown + PDF)
- Init script for instant project setup
- Claude Code hooks (circuit breaker, edit validator, test quality checker)
- MCP server configurations
- Memory management system
- Git hooks (Lefthook) for automated enforcement

## The Problem It Solves

AI coding assistants fail predictably:
- They guess APIs that don't exist
- They try the same broken fix 5 times
- They forget context between sessions
- They skip tests and claim "done"

SaneProcess enforces discipline through explicit rules and automated hooks.

## The 11 Golden Rules

1. NAME THE RULE BEFORE YOU CODE
2. STAY IN YOUR LANE (files in project)
3. VERIFY BEFORE YOU TRY
4. TWO STRIKES? INVESTIGATE
5. GREEN MEANS GO
6. USE PROJECT TOOLS
7. BUILD, KILL, LAUNCH, LOG
8. NO TEST? NO REST
9. FILE SIZE LIMITS
10. NEW FILE? UPDATE PROJECT
11. TRACK WITH TodoWrite

## Requirements

- Claude Code CLI
- macOS (primary), Linux/Windows (partial support)
- Node.js 18+ (for MCP servers)
```

### Media
- Screenshot of the SOP document
- Demo GIF of circuit breaker stopping a doom loop
- Before/after comparison (failed session vs SaneProcess session)

### Files to Deliver
```
SaneProcess-v2.1/
├── SaneProcess.md          # Main SOP document
├── SaneProcess.pdf         # PDF version
├── scripts/
│   ├── init.sh             # One-line installer
│   └── hooks/              # Claude Code hooks
├── configs/
│   ├── .mcp.json           # MCP server config
│   ├── settings.json       # Claude Code settings
│   └── lefthook.yml        # Git hooks
└── README.md               # Quick start guide
```

---

## Product 2: SaneBar

### Basic Info
- **Name:** SaneBar
- **Type:** macOS App (Digital Download)
- **Price:** $12 (one-time)
- **URL slug:** `sanebar`

### Description (Short)
```
Clean up your Mac menu bar. Hide, organize, and manage menu bar icons with a single click.
```

### Description (Long)
```
Your menu bar is cluttered. SaneBar fixes that.

## Features

- **Hide Icons** - Click to hide any menu bar icon
- **Always Show** - Pin important icons to always be visible
- **Quick Toggle** - One click to show/hide all hidden icons
- **Native macOS** - Built with SwiftUI, feels like it belongs
- **Lightweight** - Uses minimal CPU and memory

## Why SaneBar?

Unlike Bartender or Hidden Bar, SaneBar is:
- Simple (no complex configuration)
- Fast (native Swift, not Electron)
- Affordable (one-time purchase, no subscription)

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
```

### Media
- Screenshot of clean menu bar (before/after)
- GIF showing hide/show animation
- App icon

### Files to Deliver
```
SaneBar.dmg (or .zip containing SaneBar.app)
```

---

## Product 3: SaneVideo

### Basic Info
- **Name:** SaneVideo
- **Type:** macOS App (Digital Download)
- **Price:** $39 (one-time)
- **URL slug:** `sanevideo`

### Description (Short)
```
Record and edit video on Mac without the bloat. Simple, fast, native.
```

### Description (Long)
```
SaneVideo is video recording and editing that respects your time.

## Recording

- Screen recording (full screen or window)
- Camera recording
- System audio + microphone
- Keyboard shortcuts for quick capture

## Editing

- Trim clips
- Cut and join
- Add text overlays
- Export to MP4, MOV, GIF

## Why SaneVideo?

- **No subscription** - One-time purchase
- **No bloat** - Does what you need, nothing more
- **Native performance** - Built with AVFoundation, hardware accelerated
- **Fast export** - Uses Apple's VideoToolbox for hardware encoding

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac
```

### Media
- Screenshot of recording interface
- Screenshot of editing timeline
- Demo video (use SaneVideo to record SaneVideo)

### Files to Deliver
```
SaneVideo.dmg (or .zip containing SaneVideo.app)
```

---

## Product 4: Sane Suite Bundle

### Basic Info
- **Name:** Sane Suite (Complete Bundle)
- **Type:** Bundle
- **Price:** $59 (one-time) - Save $21 vs buying separately
- **URL slug:** `suite`
- **Includes:** SaneProcess + SaneBar + SaneVideo

### Description (Short)
```
All three Sane products at 26% off. Everything you need for sane Mac development.
```

### Description (Long)
```
Get the complete Sane toolkit:

## Included

1. **SaneProcess** ($29 value) - SOP enforcement for Claude Code
2. **SaneBar** ($12 value) - Menu bar manager
3. **SaneVideo** ($39 value) - Video recorder & editor

**Total Value:** $80
**Bundle Price:** $59
**You Save:** $21 (26%)

## Who This Is For

Mac developers who:
- Use AI coding assistants (Claude Code, Cursor, etc.)
- Want a clean, organized workspace
- Need to record demos, tutorials, or bug reports
- Value native, performant software over Electron bloat

One purchase. No subscriptions. Lifetime updates.
```

---

## Pricing Strategy

| Product | Price | Reasoning |
|---------|-------|-----------|
| SaneProcess | $29 | Dev tools sweet spot. Cheap enough to impulse buy, expensive enough to signal value. |
| SaneBar | $12 | Utility app pricing. Bartender is $16, Hidden Bar is free. Split the difference. |
| SaneVideo | $39 | Video tools are worth more. ScreenFlow is $169, but we're simpler. |
| Bundle | $59 | ~26% discount. Makes bundle feel like obvious choice. |

## Discount Codes to Create

| Code | Discount | Use Case |
|------|----------|----------|
| `LAUNCH` | 20% off | Launch week promotion |
| `TWITTER` | 15% off | Social media followers |
| `GITHUB` | 15% off | GitHub stars/contributors |
| `BUNDLE10` | Extra 10% off bundle | Push people to bundle |

---

## Checkout Settings

- **Tax:** Let LemonSqueezy handle it (they do VAT/GST automatically)
- **Receipts:** Enable email receipts
- **License Keys:** Enable for apps (SaneBar, SaneVideo) - useful for future updates

---

## After Setup

1. Add payment links to GitHub READMEs
2. Create a simple landing page (or use LemonSqueezy's built-in store page)
3. Announce on Twitter/X
4. Post in relevant communities (r/macapps, Hacker News, etc.)

---

## Payment Links Format

After creating products, you'll get links like:
```
https://sane.lemonsqueezy.com/buy/saneprocess
https://sane.lemonsqueezy.com/buy/sanebar
https://sane.lemonsqueezy.com/buy/sanevideo
https://sane.lemonsqueezy.com/buy/suite
```

Or with checkout overlay:
```
https://sane.lemonsqueezy.com/checkout/buy/abc123?embed=1
```
