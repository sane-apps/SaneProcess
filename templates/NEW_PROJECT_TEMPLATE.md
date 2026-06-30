# Sane* Project Template

> SaneApps internal template. Use this when setting up a new Sane* project for Claude Code, Codex, and other compatible coding agents.
> Public adopters should treat hardcoded `~/SaneApps/...` paths and Sane* app names as examples to replace with their own repo paths and products.
> Trigger: "set up project template for X" or "use project template for X"

## Quick Setup Checklist

```
[ ] .claude/.gitignore
[ ] .claude/settings.json
[ ] .claude/rules/ (copy from SaneProcess)
[ ] .codex/research.md (active research cache)
[ ] .agents/skills/ (optional compatibility mirror for shared skills)
[ ] .mcp.json (project root)
[ ] AGENTS.md (project root)
[ ] CLAUDE.md (project root, only for Claude-specific overlay)
[ ] README.md (project root)
[ ] DEVELOPMENT.md (project root)
[ ] ARCHITECTURE.md (project root — start from SaneProcess templates)
[ ] SESSION_HANDOFF.md (project root)
[ ] .saneprocess (project root — release config)
[ ] Resources/DMGIcon.icns (for DMG file icon)
[ ] ~/.zshrc cd alias
[ ] Verify all files
```

> **Doc standard:** Core docs are `AGENTS.md`, `README.md`, `DEVELOPMENT.md`,
> `ARCHITECTURE.md`, and `SESSION_HANDOFF.md`. Add `CLAUDE.md` only as a
> compatibility overlay, not as a second source of truth.

---

## Step 0: Copy Rules Directory (Optional but Recommended)

```bash
# Copy rules from SaneProcess (the master hub)
cp -r ~/SaneApps/infra/SaneProcess/.claude/rules /path/to/NewProject/.claude/rules
```

The rules directory contains pattern-matched guidelines that are injected when editing files:

| Rule File | Pattern | Purpose |
|-----------|---------|---------|
| `views.md` | `**/Views/**/*.swift` | SwiftUI: @Observable, <50 line bodies |
| `services.md` | `**/Services/**/*.swift` | Actor isolation, protocols, DI |
| `models.md` | `**/Models/**/*.swift` | Value types, Codable, Sendable |
| `tests.md` | `**/Tests/**/*.swift` | Swift Testing (not XCTest) |
| `hooks.md` | `**/hooks/**/*.rb` | Hook exit codes, error handling |
| `scripts.md` | `**/scripts/**/*.rb` | Ruby frozen_string_literal |

---

## Step 1: Create `.claude/.gitignore`

```gitignore
# Runtime state (session-specific, don't commit)
state.json
state.json.lock
circuit_breaker.json
enforcement_breaker.json
phase_state.json
saneprompt_state.json

# Tracking files
edit_count.json
tool_count.json
read_history.json
recent_actions.json
compliance_streak.json
user_patterns.json
active_skills.json

# Logs
*.log
*.jsonl

# Memory (local session)
memory.json
memory_staging.json

# Temp/backup
*.backup.json
saneloop-archive/

# Keep these (committed)
!rules/
!settings.json
!CLAUDE.md
!SESSION_HANDOFF.md
```

---

## Step 2: Create `.claude/settings.json`

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(xcodebuild:*)",
      "Bash(xcrun:*)",
      "Bash(swift:*)",
      "Bash(swiftlint:*)",
      "Bash(xcodegen:*)",
      "Bash(open:*)",
      "Bash(brew:*)",
      "Bash(ruby:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(wc:*)",
      "Bash(which:*)",
      "Bash(killall:*)",
      "Bash(pgrep:*)",
      "Bash(pkill:*)",
      "Bash(du:*)",
      "Bash(df:*)",
      "Bash(curl:*)",
      "mcp__memory__*",
      "mcp__apple-docs__*",
      "mcp__context7__*",
      "mcp__github__*",
      "mcp__xcode__*",
      "mcp__macos-automator__*"
    ]
  },
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/session_start.rb; else exit 0; fi",
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
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/saneprompt.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/saneprompt.rb; else exit 0; fi",
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
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetools.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetools.rb; else exit 0; fi",
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
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetrack.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanetrack.rb; else exit 0; fi",
            "timeout": 5
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/task_completed_gate.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/task_completed_gate.rb; else exit 0; fi",
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
            "command": "if [ -n \"${CLAUDECODE}${CLAUDE_CODE}\" ] && [ -f .saneprocess ] && [ -f ~/SaneApps/infra/SaneProcess/scripts/hooks/sanestop.rb ]; then ruby ~/SaneApps/infra/SaneProcess/scripts/hooks/sanestop.rb; else exit 0; fi",
            "timeout": 5
          }
        ]
      }
    ]
  },
  "enabledPlugins": {
    "swift-lsp@claude-plugins-official": true,
    "code-review@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true
  }
}
```

---

## Step 3: Create `.mcp.json` (at project root)

```json
{
  "mcpServers": {
    "apple-docs": {
      "command": "npx",
      "args": ["-y", "@mweinbach/apple-docs-mcp@1.3.1"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@2.2.5"]
    }
  }
}
```

GitHub MCP is provided by the hardened user-level bridge at
`~/.codex/bin/github-mcp-bridge.mjs` after SaneProcess sync. Do not add a
project-local `npx @modelcontextprotocol/server-github` entry with a token.

**For menu bar apps**, add macos-automator:
```json
    "macos-automator": {
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@0.4.1"]
    }
```

---

## Step 4: Create `CLAUDE.md` (at project root)

Before the Claude overlay, add a shared `AGENTS.md` at the project root so Codex and other agents land on the same rules first:

```markdown
# Project Agent Instructions

Use plain English. Keep it short and direct.

## Read First
1. AGENTS.md
2. README.md
3. DEVELOPMENT.md
4. ARCHITECTURE.md
5. SESSION_HANDOFF.md if it exists

## Rules
1. Verify tools and APIs before using them.
2. After two failures, stop and research.
3. Use project scripts instead of ad hoc commands.
4. Do not say "done" without checks or approval.
5. Update existing docs before creating new ones.
```

Then add `CLAUDE.md` only for Claude-specific overlays:

```markdown
# [ProjectName] Claude Code Configuration

## Xcode Tools (Apple's Official MCP)

Requires Xcode running with the project open. Get the `tabIdentifier` first:

```
mcp__xcode__XcodeListWindows
mcp__xcode__BuildProject
mcp__xcode__RunAllTests
mcp__xcode__RenderPreview
```

## Build Commands

- `BuildProject` - Build the app (Xcode Tools MCP)
- `RunAllTests` - Run tests
- `GetBuildLog` - Inspect build output

## Project Structure

```
ProjectName/
├── Sources/           # Main app code
│   ├── App/          # App entry point
│   ├── Services/     # Business logic
│   ├── Models/       # Data models
│   └── Views/        # SwiftUI views
├── Tests/            # Unit tests
└── Scripts/          # Build automation
```

## Key Components

- **[ServiceName]**: [Description]
- **[ModelName]**: [Description]

## MCP Optimization

### apple-docs
- Use for Apple API verification before coding

### context7
- Use `resolve-library-id` first, then `query-docs`
```

---

## Step 5: Create `.saneprocess` (at project root)

This config drives the unified release pipeline. See [RELEASE_SOP.md](RELEASE_SOP.md) for the full process.

```yaml
# SaneProcess compliance manifest
name: ProjectName
type: macos_app
scheme: ProjectName
project: ProjectName.xcodeproj
bundle_id: com.projectname.app

build:
  xcodegen: true  # set false if not using XcodeGen

release:
  dist_host: dist.projectname.com
  site_host: projectname.com
  r2_bucket: sanebar-downloads
  use_sparkle: true
  min_system_version: "15.0"
  dmg:
    volume_icon: Resources/DMGIcon.icns
    file_icon: Resources/DMGIcon.icns
    window_size: "800 400"
    app_icon_pos: "200 185"
    drop_pos: "600 185"

commands:
  verify: ./scripts/SaneMaster.rb verify
  test_mode: ./scripts/SaneMaster.rb tm
  lint: ./scripts/SaneMaster.rb lint
  clean: ./scripts/SaneMaster.rb clean
  launch: ./scripts/SaneMaster.rb launch
  logs: ./scripts/SaneMaster.rb logs

docs:
  - AGENTS.md
  - README.md
  - DEVELOPMENT.md
  - ARCHITECTURE.md
  - SESSION_HANDOFF.md

mcps:
  - apple-docs
  - context7
  - github
  - xcode
```

**DMGIcon.icns**: Copy from `build/Export/AppName.app/Contents/Resources/AppIcon.icns` after first build, or generate from your asset catalog. Must be full-square opaque (no squircle, no shadow).

---

## Step 6: Add Alias to `~/.zshrc`

```bash
# Claude Code compatibility alias (2-letter code)
alias XX='cd /path/to/ProjectName'
```

**IMPORTANT**: Avoid `sh` as alias (shadows `/bin/sh`)

### Current Aliases

| Alias | Project | Path |
|-------|---------|------|
| `sb` | SaneBar | ~/SaneApps/apps/SaneBar |
| `sc` | SaneClip | ~/SaneApps/apps/SaneClip |
| `sp` | SaneProcess | ~/SaneApps/infra/SaneProcess |
| `ss` | SaneSync | ~/SaneApps/apps/SaneSync |
| `sv` | SaneVideo | ~/SaneApps/apps/SaneVideo |
| `sah` | SaneHosts | ~/SaneApps/apps/SaneHosts |

---

## Step 7: Verify Setup

```bash
# Check .claude directory
ls -la PROJECT/.claude/

# Check root config files
ls -la PROJECT/.mcp.json PROJECT/AGENTS.md PROJECT/CLAUDE.md

# Check aliases
grep "alias.*PROJECT" ~/.zshrc

# Activate aliases
source ~/.zshrc
```

---

## Reference Projects

| Project | Type | Notes |
|---------|------|-------|
| **SaneBar** | Menu bar app | Full mature setup, UI automation |
| **SaneProcess** | Hook master | Central hub for hooks system |
| **SaneSync** | macOS app | Cloud sync, file operations |
| **SaneHosts** | macOS app | Privileged helper, XPC |
| **SaneClip** | Menu bar app | Clipboard manager |

---

## Special Cases

### Menu Bar Apps
- Add `macos-automator` MCP for UI testing
- Xcode Tools doesn't drive UI; use macos-automator for real UI
- Use `macos-automator` to click real UI elements

### Apps with Privileged Helpers
- Document XPC service in AGENTS.md and CLAUDE.md if Claude needs extra overlay detail
- Note SMAppService registration
- Security considerations for admin privileges

### Apps using XcodeGen
- Add `xcodegen` to permissions
- Document `xcodegen generate` in build commands
- Note that projectPath changes after regeneration

---

## Swift Style Guide

### Core Rules

| Rule | Standard | Don't Use |
|------|----------|-----------|
| State Management | `@Observable` | `@StateObject`, `ObservableObject` |
| Testing | Swift Testing (`import Testing`, `@Test`, `#expect`) | XCTest |
| Services | `actor` for shared state | Singletons (`static let shared`) |
| Errors | Typed enums | `NSError`, strings |
| View Bodies | < 50 lines, extract subviews | Massive inline views |

### Views (`**/Views/**/*.swift`, `**/UI/**/*.swift`)

```swift
// RIGHT: @Observable + extracted subviews
@Observable
class SettingsModel {
    var darkMode: Bool = false
}

struct SettingsView: View {
    @State private var model = SettingsModel()

    var body: some View {
        List {
            GeneralSection(model: model)  // Extracted
            PrivacySection(model: model)  // Extracted
        }
    }
}

// WRONG: @StateObject + massive body
@StateObject var viewModel = ViewModel()  // Don't use
```

### Services (`**/Services/**/*.swift`)

```swift
// RIGHT: Protocol + Actor + Typed errors
protocol CameraServiceProtocol: Sendable {
    func startCapture() async throws
}

actor CameraService: CameraServiceProtocol {
    private var session: AVCaptureSession?

    func startCapture() async throws {
        // Actor isolation = thread-safe
    }
}

enum CameraError: Error {
    case permissionDenied
    case deviceNotFound
}

// WRONG: Singleton + NSError
class CameraService {
    static let shared = CameraService()  // Don't use
}
```

### Tests (`**/Tests/**/*.swift`)

```swift
// RIGHT: Swift Testing
import Testing
@testable import MyApp

struct ParserTests {
    @Test("Parses valid JSON")
    func parsesValidJSON() throws {
        let result = try parser.parse(json)
        #expect(result.count == 3)
    }

    @Test("Throws on invalid input")
    func throwsOnInvalid() {
        #expect(throws: ParserError.self) {
            try parser.parse(invalid)
        }
    }
}

// WRONG: XCTest
import XCTest  // Don't use
class ParserTests: XCTestCase {  // Don't use
    func testParser() {
        XCTAssertTrue(true)  // Tautology
    }
}
```

### Swift Testing Cheat Sheet

| XCTest (Don't Use) | Swift Testing (Use This) |
|--------------------|--------------------------|
| `import XCTest` | `import Testing` |
| `class FooTests: XCTestCase` | `struct FooTests` |
| `func testSomething()` | `@Test func something()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertThrowsError` | `#expect(throws:)` |

### Models (`**/Models/**/*.swift`)

```swift
// RIGHT: Value type, Codable, Sendable
struct ClipboardItem: Codable, Sendable, Identifiable {
    let id: UUID
    let content: String
    let timestamp: Date
}

// WRONG: Class with mutable state
class ClipboardItem {
    var content: String  // Mutable = bugs
}
```
