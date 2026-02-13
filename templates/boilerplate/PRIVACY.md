# Privacy Policy

**TODO:AppName** is built with privacy as a core principle. This document explains how your data is handled.

## Our Commitment

- **100% Local** - All your data stays on your Mac
- **No Analytics** - We don't track usage or behavior
- **No Telemetry** - No data is sent to our servers
- **No Account Required** - Use the app without signing up

## Data Storage

### What We Store

TODO:AppName stores the following data locally on your Mac:

| Data | Location | Purpose |
|------|----------|---------|
| TODO:Data1 | `~/Library/Application Support/TODO:AppName/` | TODO:Purpose |
| Preferences | macOS Preferences system | App settings |

### What We Don't Store

- Personal information
- Usage statistics
- Crash reports (unless you opt-in)
- Any data on remote servers

## Network Access

TODO:AppName makes network requests only for:

1. **Update Checks** (optional)
   - Checks `TODO:appname.com/appcast.xml` for updates
   - Can be disabled in Settings
   - Only sends: app version, macOS version

2. **TODO:Other network features if any**

### Verify Network Activity

You can verify TODO:AppName's network behavior:

```bash
# Monitor network connections
sudo lsof -i -n -P | grep TODO:AppName

# Check with Little Snitch or similar firewall
```

## Permissions

TODO:AppName requests these permissions:

| Permission | Why It's Needed |
|------------|-----------------|
| TODO:Permission | TODO:Reason |

## Data Export & Deletion

- **Export**: TODO:How to export data
- **Delete**: Remove `~/Library/Application Support/TODO:AppName/` to delete all data

## Third-Party Code

TODO:AppName uses these open-source libraries:

| Library | Purpose | License |
|---------|---------|---------|
| Sparkle | Auto-updates | MIT |
| KeyboardShortcuts | Hotkeys | MIT |
| SaneUI | UI components | MIT |

None of these libraries collect user data.

## Changes to This Policy

We'll update this policy if our practices change. Check the [changelog](CHANGELOG.md) for updates.

## Contact

Questions about privacy? Open an issue on [GitHub](https://github.com/sane-apps/TODO:AppName/issues).

---

*Last updated: TODO:Date*
