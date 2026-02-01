# Sane* Project Template

> Use this template when setting up a new Sane* project with Claude Code configuration.
> Trigger: "set up project template for X" or "use project template for X"

## Quick Setup Checklist

```
[ ] .claude/.gitignore
[ ] .claude/settings.json
[ ] .claude/rules/ (copy from SaneProcess)
[ ] .mcp.json (project root)
[ ] CLAUDE.md (project root)
[ ] README.md (project root)
[ ] DEVELOPMENT.md (project root)
[ ] ARCHITECTURE.md (project root — use ~/.claude/templates/ARCHITECTURE.md)
[ ] SESSION_HANDOFF.md (project root)
[ ] ~/.zshrc alias
[ ] Verify all files
```

> **Doc standard:** Every project gets exactly 5 docs. See `~/.claude/templates/DOC_STANDARD.md`.

---

## Step 0: Copy Rules Directory (Optional but Recommended)

```bash
# Copy rules from SaneProcess (the master hub)
cp -r /Users/sj/SaneProcess/.claude/rules /path/to/NewProject/.claude/rules
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
      "mcp__XcodeBuildMCP__*",
      "mcp__macos-automator__*"
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
    "code-review@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "claude-mem@thedotmack": true
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
      "args": ["-y", "@mweinbach/apple-docs-mcp@latest"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    }
  }
}
```

**For menu bar apps**, add macos-automator:
```json
    "macos-automator": {
      "command": "npx",
      "args": ["-y", "@steipete/macos-automator-mcp@latest"]
    }
```

---

## Step 4: Create `CLAUDE.md` (at project root)

```markdown
# [ProjectName] Claude Code Configuration

## XcodeBuildMCP Session Setup

At session start, configure:

```
mcp__XcodeBuildMCP__session-set-defaults:
  workspacePath: /path/to/ProjectName.xcworkspace  # OR projectPath for .xcodeproj
  scheme: ProjectName
  arch: arm64
```

## Build Commands

- `build_macos` - Build the app
- `test_macos` - Run tests
- `build_run_macos` - Build and launch

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

### claude-mem 3-Layer Workflow
```
1. search(query, project: "ProjectName") → Index with IDs
2. timeline(anchor=ID) → Context around results
3. get_observations([IDs]) → Fetch ONLY filtered IDs
```

### apple-docs
- Use for Apple API verification before coding

### context7
- Use `resolve-library-id` first, then `query-docs`
```

---

## Step 5: Add Alias to `~/.zshrc`

```bash
# Claude Code (2-letter code)
alias XX='cd /path/to/ProjectName && claude --dangerously-skip-permissions'

# Gemini (g + 2-letter code)
alias gXX='cd /path/to/ProjectName && gemini'
```

**IMPORTANT**: Avoid `sh` as alias (shadows `/bin/sh`)

### Current Aliases

| Alias | Project | Path |
|-------|---------|------|
| `sb` | SaneBar | ~/SaneBar |
| `sc` | SaneClip | ~/SaneClip |
| `sp` | SaneProcess | ~/SaneProcess |
| `ss` | SaneSync | ~/SaneSync |
| `sv` | SaneVideo | ~/SaneVideo |
| `sah` | SaneHosts | ~/Projects/SaneHosts |

---

## Step 6: Verify Setup

```bash
# Check .claude directory
ls -la PROJECT/.claude/

# Check root config files
ls -la PROJECT/.mcp.json PROJECT/CLAUDE.md

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
- XcodeBuildMCP simulator tools don't work for macOS desktop apps
- Use `macos-automator` to click real UI elements

### Apps with Privileged Helpers
- Document XPC service in CLAUDE.md
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
