# SaneApps Development Environment

> Complete setup guide for developing SaneApps on macOS

## Prerequisites

### Hardware
- Mac with Apple Silicon (M1/M2/M3/M4)
- macOS 14.0+ (Sonoma or later)

### Software Requirements

```bash
# Xcode 16+
xcode-select --install

# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Required tools
brew install xcodegen swiftlint ruby create-dmg gh

# Optional but recommended
brew install lefthook periphery mockolo
```

---

## Claude Code Setup

### Install Claude Code

```bash
# Via npm (recommended)
npm install -g @anthropic-ai/claude-code

# Or via Homebrew
brew install claude-code
```

### MCP Servers

SaneApps development uses these MCP servers:

| Server | Purpose | Install |
|--------|---------|---------|
| `apple-docs` | Apple API documentation | Built-in |
| `context7` | Library documentation | Built-in |
| `memory` | Persistent learnings | Official Memory MCP |
| `github` | GitHub operations | Built-in |
| `macos-automator` | macOS automation/testing | Built-in |
| `xcode` | Xcode build/test/preview | `xcrun mcpbridge` |

### Global Settings

Copy to `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "Bash(xcodegen:*)",
      "Bash(git:*)",
      "Bash(brew:*)",
      "Bash(swiftlint:*)",
      "Bash(xcodebuild:*)",
      "Bash(xcrun:*)",
      "Bash(open:*)",
      "mcp__memory__*",
      "mcp__apple-docs__*",
      "mcp__context7__*",
      "mcp__github__*",
      "mcp__macos-automator__*",
      "mcp__xcode__*"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$CLAUDE_CODE\" ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb ] && ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb || true",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$CLAUDE_CODE\" ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/saneprompt.rb ] && ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/saneprompt.rb || true",
            "timeout": 5
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$CLAUDE_CODE\" ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetools.rb ] && ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetools.rb || true",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$CLAUDE_CODE\" ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetrack.rb ] && ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetrack.rb || true",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$CLAUDE_CODE\" ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanestop.rb ] && ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanestop.rb || true",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "swift-lsp@claude-plugins-official": true,
    "context7@claude-plugins-official": true
  }
}
```

### Claude Code Rules (CLAUDE.md)

Every SaneApp should have a project-level `.claude/CLAUDE.md` or root `CLAUDE.md` with:

```markdown
# Project: AppName

## Build Commands
- `xcodegen generate` - Regenerate Xcode project
- `./scripts/SaneMaster.rb release` - Build release DMG

## Testing
- Run tests: Cmd+U in Xcode or `xcodebuild test`
- Manual QA: See docs/E2E_TESTING_CHECKLIST.md

## Code Style
- SwiftLint enforced (see .swiftlint.yml)
- Swift 6 strict concurrency

## Key Files
- `project.yml` - XcodeGen configuration
- `docs/appcast.xml` - Sparkle update feed
```

---

## Code Signing Setup

### One-Time Setup

1. **Developer ID Certificate**
   - Log into [developer.apple.com](https://developer.apple.com)
   - Certificates → Create "Developer ID Application"
   - Download and install in Keychain

2. **Notarization Credentials**
   ```bash
   # Create App-Specific Password at appleid.apple.com
   # Then store in keychain:
   xcrun notarytool store-credentials "notarytool" \
     --apple-id "your@email.com" \
     --team-id "M78L6FXD48" \
     --password "app-specific-password"
   ```

3. **Sparkle EdDSA Key** (for auto-updates)
   ```bash
   # Generate key pair (one-time)
   ./Sparkle/bin/generate_keys

   # Store public key in Info.plist as SUPublicEDKey
   # Store private key securely for signing updates
   ```

### Verify Setup

```bash
# List signing identities
security find-identity -v -p codesigning

# Should show:
# "Developer ID Application" (Team: M78L6FXD48)
```

---

## Project Structure

### XcodeGen Configuration

All SaneApps use XcodeGen for project generation:

```yaml
# project.yml
name: AppName
options:
  bundleIdPrefix: com.appname
  deploymentTarget:
    macOS: 15.0
  xcodeVersion: 16.0

packages:
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: 2.0.0
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
  SaneUI:
    path: ../Projects/SaneUI

settings:
  SWIFT_STRICT_CONCURRENCY: complete
  ENABLE_HARDENED_RUNTIME: YES

targets:
  AppName:
    type: application
    platform: macOS
    dependencies:
      - package: KeyboardShortcuts
      - package: Sparkle
      - package: SaneUI
```

### Regenerate Project

```bash
cd /path/to/AppName
xcodegen generate
open AppName.xcodeproj
```

---

## Build & Release

### Local Development

```bash
# Build debug
xcodebuild -project AppName.xcodeproj -scheme AppName -configuration Debug build

# Run tests
xcodebuild -project AppName.xcodeproj -scheme AppName test

# Or use Xcode Tools MCP:
# mcp__xcode__XcodeListWindows
# mcp__xcode__BuildProject
# mcp__xcode__RunAllTests
```

### Release Build

```bash
# Full release (build, sign, notarize, DMG)
./scripts/SaneMaster.rb release --version 1.2.0

# Skip notarization for local testing
./scripts/SaneMaster.rb release --skip-notarize

# Output:
# - releases/AppName-1.2.0.dmg (signed, notarized)
# - SHA256 hash for Homebrew
```

---

## Quality Tools

### SwiftLint

```yaml
# .swiftlint.yml
disabled_rules:
  - line_length
  - identifier_name
  - type_body_length
  - file_length

opt_in_rules:
  - empty_count
  - closure_spacing

excluded:
  - .build
  - DerivedData
```

### Pre-commit Hooks (lefthook)

```yaml
# lefthook.yml
pre-commit:
  commands:
    swiftlint:
      glob: "*.swift"
      run: swiftlint --strict {staged_files}
```

Install hooks:
```bash
lefthook install
```

---

## Testing

### Unit Tests

Use Swift Testing framework (`@Test` macro):

```swift
import Testing
@testable import AppName

@Suite("MyFeature Tests")
struct MyFeatureTests {
    @Test("Does the thing")
    func doesTheThing() {
        #expect(result == expected)
    }
}
```

### UI Testing (macOS)

Xcode Tools does not drive UI. Use `macos-automator` for real macOS interactions:

```
mcp__macos-automator__get_scripting_tips list_categories:true
mcp__macos-automator__get_scripting_tips search_term:"Finder"
```

### Manual QA Checklist

See `docs/E2E_TESTING_CHECKLIST.md` for:
- Fresh install testing
- Upgrade testing
- Permission flows
- Edge cases

---

## Debugging

### Common Issues

| Issue | Solution |
|-------|----------|
| Code sign error | Check identity: `security find-identity -v` |
| Notarization failed | Check `xcrun notarytool log <submission-id>` |
| Sparkle not updating | Verify `SUPublicEDKey` matches signing key |
| Package resolution | Delete `Package.resolved`, clean DerivedData |

### Logs

```bash
# App logs
log stream --predicate 'subsystem == "com.appname.app"'

# Build logs
cat build/build.log

# Notarization logs
xcrun notarytool log <submission-id> --keychain-profile notarytool
```

---

## Useful Aliases

Add to `~/.zshrc`:

```bash
# SaneApps development
alias xgen="xcodegen generate && open *.xcodeproj"
alias release="./scripts/SaneMaster.rb release"
alias notary-check="xcrun notarytool info"

# Quick builds
alias build-debug="xcodebuild -configuration Debug build"
alias build-release="xcodebuild -configuration Release build"
```

---

## Directory Structure

```
~/
├── Projects/
│   ├── SaneUI/          # Shared design system
│   ├── SaneProcess/     # This process documentation
│   └── SaneHosts/       # Individual apps...
├── SaneClip/
├── SaneBar/
└── .claude/
    ├── CLAUDE.md        # Global Claude rules
    ├── settings.json    # MCP & hooks config
    └── hooks/           # Session hooks
```

---

## Getting Help

1. **Apple APIs**: Use `mcp__apple-docs__search_apple_docs`
2. **Library docs**: Use `mcp__context7__query-docs`
3. **Past learnings**: Use Serena memories or Official Memory MCP
4. **This documentation**: `/Users/sj/Projects/SaneProcess/docs/`
