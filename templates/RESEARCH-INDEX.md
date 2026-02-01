# SaneApps Research Index

> **One place to find ALL research across all apps.**
> Last updated: 2026-01-19
>
> **Rule:** Every feature research MUST be linked here. No orphaned docs.

---

## Quick Links

| Category | Template/Guide |
|----------|----------------|
| New Research | [RESEARCH-TEMPLATE.md](./RESEARCH-TEMPLATE.md) |
| State Machine Audit | [state-machine-audit.md](./state-machine-audit.md) |
| Project Bootstrap | [FULL_PROJECT_BOOTSTRAP.md](./FULL_PROJECT_BOOTSTRAP.md) |
| Founder Tasks | [FOUNDER_CHECKLIST.md](./FOUNDER_CHECKLIST.md) |

---

## Research by App

### SaneBar

| Topic | File | Status | Date |
|-------|------|--------|------|
| **Rules Engine & Focus Mode** | [rules-engine-focus-mode.md](/Users/sj/SaneApps/apps/SaneBar/.claude/archive/research/rules-engine-focus-mode.md) | ✅ Complete | 2026-01-19 |
| WiFi Network Triggers | [p0-wifinetwork-trigger.md](/Users/sj/SaneApps/apps/SaneBar/.claude/archive/research/p0-wifinetwork-trigger.md) | ✅ Complete | 2026-01-04 |
| Feature Plan (all features) | [FEATURE_PLAN.md](/Users/sj/SaneApps/apps/SaneBar/FEATURE_PLAN.md) | 📋 Living doc | - |
| Roadmap | [ROADMAP.md](/Users/sj/SaneApps/apps/SaneBar/ROADMAP.md) | 📋 Living doc | - |

### SaneClip

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

### SaneHosts

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

### SaneVideo

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

### SaneSync

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

### SaneScript

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

### SaneAI

| Topic | File | Status | Date |
|-------|------|--------|------|
| (Add research here) | - | - | - |

---

## Cross-App Research

| Topic | Applies To | File | Status |
|-------|-----------|------|--------|
| Founder Checklist | ALL | [FOUNDER_CHECKLIST.md](./FOUNDER_CHECKLIST.md) | ✅ Complete |
| Project Bootstrap | ALL | [FULL_PROJECT_BOOTSTRAP.md](./FULL_PROJECT_BOOTSTRAP.md) | ✅ Complete |
| State Machine Template | ALL | [state-machine-audit.md](./state-machine-audit.md) | ✅ Complete |

---

## API Research Quick Reference

### Commonly Used APIs (Verified)

| API | Framework | Purpose | Used In |
|-----|-----------|---------|---------|
| `CWWiFiClient` | CoreWLAN | WiFi network detection | SaneBar |
| `INFocusStatusCenter` | Intents | Focus Mode (boolean only) | SaneBar |
| `DistributedNotificationCenter` | Foundation | System-wide events | SaneBar |
| `NSWorkspace.runningApplications` | AppKit | Running app detection | SaneBar |
| `IOPSCopyPowerSourcesInfo` | IOKit | Battery state | SaneBar |

### Focus Mode Detection Summary

```swift
// Option 1: Official API (boolean only)
import Intents
let isFocused = INFocusStatusCenter.default.focusStatus.isFocused

// Option 2: File-based (gets mode NAME - unsandboxed only)
let path = "~/Library/DoNotDisturb/DB/Assertions.json"
// Parse JSON to get mode identifier, look up in ModeConfigurations.json

// Option 3: Notification monitoring
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.apple.focusui.setStatus"),
    object: nil, queue: .main
) { _ in /* Focus changed */ }
```

---

## How to Add Research

1. Use the [RESEARCH-TEMPLATE.md](./RESEARCH-TEMPLATE.md) for new research
2. Save in the app's `.claude/archive/research/` directory
3. **ADD IT TO THIS INDEX** - don't orphan docs
4. Cross-reference in the app's FEATURE_PLAN.md or ROADMAP.md

---

## Search Tips

If you can't find research:

1. **Check memory MCP:** `mcp__plugin_claude-mem_mcp-search__search`
2. **Grep all projects:** `grep -r "topic" ~/SaneApps/`
3. **Check session handoffs:** Each app has `SESSION_HANDOFF.md`
4. **Ask Claude:** "What research exists for [topic]?"

---

## Avoiding Fragmentation

**As of 2026-02:** SaneApps follows a 5-document standard per project. Research belongs in `ARCHITECTURE.md` §4. See `~/.claude/templates/DOC_STANDARD.md` for the full spec.

**DO:**
- Put new research in the project's `ARCHITECTURE.md` §4 (Research section)
- Link app-specific research in this index for cross-app visibility
- Use consistent file naming for app research: `topic-name.md`
- Cross-reference between docs

**DON'T:**
- Create standalone `RESEARCH_REPORT.md` files (merge into ARCHITECTURE.md)
- Duplicate research across apps
- Leave session notes unlinked
- Forget to update when research is complete
