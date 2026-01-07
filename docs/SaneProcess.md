# SaneProcess

**Version 2.4** | January 2026

---

# Congratulations

You now have a complete human-AI development system for building macOS applications.

**What is this?** A battle-test2ed process for working with Claude Code. It turns "AI that sometimes helps" into "AI that reliably ships code" through explicit rules, automated enforcement, and cross-session memory.

**Why does it work?**
- **Rules are memorable** - "TWO STRIKES? INVESTIGATE" sticks better than "stop after failures"
- **Enforcement is automatic** - Hooks catch mistakes before they waste time
- **Memory persists** - Bug patterns learned once, never repeated
- **Self-rating builds discipline** - You see compliance improve session over session

**How to use it:**

| Option | Do This |
|--------|---------|
| **Instant Setup** | Run `curl -sL https://raw.githubusercontent.com/stephanjoseph/SaneProcess/main/scripts/init.sh \| bash` in your project folder |
| **Manual Setup** | Open Terminal, run `claude`, paste this document, say "set up SaneProcess" |
| **Learn First** | Keep reading to understand the rules, then set up manually |

The init script detects your project type (Swift/Ruby/Node) and creates all config files automatically. Full SOP enforcement in 2 minutes.

---

# What's Included

This is a **process framework** with three layers:

| Layer | What It Is | Transferable? |
|-------|-----------|---------------|
| **1. The Rules** | 16 Golden Rules + workflows + research protocol | ✅ Yes - copy this document |
| **2. The Tooling** | CLI automation (SaneMaster.rb or equivalent) | ⚠️ Adapt - needs project setup |
| **3. The Enforcement** | Claude Code hooks + MCP servers | ⚠️ Adapt - config files provided |

## Layer 1: The Rules (This Document)

The SOP itself. Works with any tooling that follows the patterns:
- Build command → Test command → Run command → Logs command
- Project generator (xcodegen, npm init, cargo new, etc.)
- Linter (swiftlint, eslint, rubocop, clippy, etc.)

## Layer 2: The Tooling (Separate)

A CLI that wraps your build system. Example commands:

| Command | What It Does |
|---------|--------------|
| `verify` | Build + run test2s |
| `test2_mode` | Kill → Build → Launch → Stream logs |
| `verify_api` | Check if API exists in SDK |
| `clean --nuclear` | Wipe all caches |
| `logs --follow` | Stream application logs |
| `health` | Quick environment check |

**You need to provide:** A `Scripts/` folder with your own automation that implements these patterns. The rules reference `<project-test2-command>` etc. - substitute your actual commands.

## Layer 3: The Enforcement (Config Files)

Claude Code hooks and MCP servers that automate rule checking:

| File | Purpose |
|------|---------|
| `.claude/settings.json` | Hook configuration |
| `.mcp.json` | MCP server configuration |
| `Scripts/hooks/*.rb` | Hook scripts (circuit breaker, edit validator, etc.) |
| `lefthook.yml` | Git pre-commit/pre-push automation |

**You need to provide:** Hook scripts adapted to your project, or use the reference implementation.

---

# New Project Setup Guide

Set up SaneProcess in a new macOS project in 15 minutes.

## Step 1: Install Dependencies (5 min)

```bash
# Homebrew tools
brew install swiftlint xcodegen lefthook ruby

# Ruby gems (in project folder)
bundle init
echo 'gem "rubocop"' >> Gemfile
echo 'gem "pry"' >> Gemfile
bundle install

# Claude Code plugins
claude plugin install swift-lsp@claude-plugins-official
claude plugin install code-review@claude-plugins-official
claude plugin install sane-loop@claude-plugins-official
```

## Step 2: Create Project Structure (3 min)

```bash
mkdir -p Scripts/hooks .claude
touch Scripts/build.rb Scripts/hooks/circuit_breaker.rb
touch .claude/settings.json .mcp.json lefthook.yml project.yml
touch DEVELOPMENT.md BUG_TRACKING.md
```

## Step 3: Configure Files (5 min)

### `.claude/settings.json` (Claude Code hooks)
```json
{
  "hooks": {
    "SessionStart": [
      { "type": "command", "command": "./Scripts/build.rb bootstrap" }
    ],
    "PreToolUse": [
      {
        "type": "command",
        "command": "./Scripts/hooks/circuit_breaker.rb",
        "matchTools": ["Edit", "Bash", "Write"]
      }
    ]
  }
}
```

### `.mcp.json` (MCP servers)
```json
{
  "mcpServers": {
    "apple-docs": {
      "command": "npx",
      "args": ["-y", "@mweinbach/apple-docs-mcp@latest2"]
    },
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory", ".claude/memory.json"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest2"]
    }
  }
}
```

### `lefthook.yml` (Git hooks)
```yaml
pre-commit:
  parallel: true
  commands:
    lint:
      glob: "*.swift"
      run: swiftlint lint --fix {staged_files} && git add {staged_files}

pre-push:
  commands:
    verify:
      run: ./Scripts/build.rb verify
```

### `project.yml` (XcodeGen - if Swift)
```yaml
name: MyApp
options:
  bundleIdPrefix: com.mycompany
targets:
  MyApp:
    type: application
    platform: macOS
    sources: [MyApp]
    settings:
      SWIFT_VERSION: "6.0"
  MyAppTests:
    type: bundle.unit-test2
    platform: macOS
    sources: [MyAppTests]
    dependencies:
      - target: MyApp
```

## Step 4: Create Build Script (2 min)

### `Scripts/build.rb` (minimal starter)
```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

command = ARGV[0]

case command
when 'verify'
  system('xcodebuild -scheme MyApp -destination "platform=macOS" build test2')
when 'clean'
  system('rm -rf ~/Library/Developer/Xcode/DerivedData/MyApp-*')
when 'logs'
  Kernel.send(:system, 'log stream --predicate \'process == "MyApp"\'')
when 'launch'
  system('open ~/Library/Developer/Xcode/DerivedData/MyApp-*/Build/Products/Debug/MyApp.app')
when 'test2_mode'
  system('killall -9 MyApp 2>/dev/null')
  system('./Scripts/build.rb verify && ./Scripts/build.rb launch')
when 'bootstrap'
  puts '✅ Ready'
else
  puts "Usage: #{$0} [verify|clean|logs|launch|test2_mode|bootstrap]"
end
```

```bash
chmod +x Scripts/build.rb
```

## Step 5: Initialize and Test

```bash
# Generate Xcode project
xcodegen generate

# Initialize git hooks
lefthook install

# Run first build
./Scripts/build.rb verify

# Start Claude Code
claude
```

## What You Get

After setup:
- ✅ Xcode project generated from `project.yml`
- ✅ Git hooks auto-run on commit/push
- ✅ Claude Code loads MCP servers + hooks
- ✅ SOP enforcement via session start hook
- ✅ Memory persists across sessions

## Growing the Tooling

Start minimal, add commands as needed. Reference the full SaneMaster.rb for:
- `verify_api` - SDK verification
- `crashes` - Crash report analysis
- `diagnose` - xcresult analysis
- `health` - Environment health check
- Memory management commands
- Circuit breaker commands

---

# Table of Contents

1. [Environment](#1-environment)
2. [The Golden Rules](#2-the-golden-rules)
   - 2A. [THIS HAS BURNED YOU](#2a-this-has-burned-you)
   - 2B. [Plan Format](#2b-plan-format-mandatory)
3. [Workflows](#3-workflows)
4. [Research Protocol](#4-research-protocol)
5. [Circuit Breaker](#5-circuit-breaker)
6. [Memory System](#6-memory-system)
7. [Claude Code Hooks](#7-claude-code-hooks)
   - 7B. [Git Hooks (Lefthook)](#7b-git-hooks-lefthook)
   - 7C. [Compliance Loop](#7c-compliance-loop)
8. [MCP Servers](#8-mcp-servers)
9. [Language Guidelines](#9-language-guidelines)
10. [Troubleshooting](#10-troubleshooting)

---

# 1. Environment

- **OS**: macOS (Sequoia / Tahoe)
- **Hardware**: Apple Silicon (M1+)
- **Terminal**: Terminal.app (or iTerm2, Warp)
- **Screenshots**: `~/.claude/screenshots/` (global)

**Trigger Phrases:**
- "check our SOP" / "use our SOP" → Read project's SOP immediately
- "test2 mode" → Kill processes, build, launch, stream logs
- "check logs" → Monitor all diagnostic resources

---

# 2. The Golden Rules

These rules are **mandatory**. Self-rate adherence after every task.

### Why Catchy Rule Names?

Memorable rules + clear tool names = **human can audit in real-time**.

Names like "SANEMASTER OR DISASTER" aren't just mnemonics—they're a **shared vocabulary**. When I say "Rule #5" you instantly know whether I'm complying or drifting. This lets you catch mistakes as they happen instead of after 20 minutes of debugging.

---

## Rule #0: NAME THE RULE BEFORE YOU CODE

✅ DO: State which rules apply before writing code
❌ DON'T: Start coding without thinking about rules

```
🟢 RIGHT: "This uses an API → Rule #2: VERIFY BEFORE YOU TRY"
🟢 RIGHT: "New file needed → Rule #9: NEW FILE? GEN THAT PILE"
🔴 WRONG: "Let me just start coding..."
🔴 WRONG: "I'll figure out the rules as I go"
```

---

## Rule #1: STAY IN YOUR LANE

✅ DO: Save all files inside the project folder
❌ DON'T: Create files outside project without asking

```
🟢 RIGHT: <project>/Scripts/new_helper.rb
🟢 RIGHT: <project>/src/models/NewModel.swift
🔴 WRONG: ~/.claude/plans/anything.md
🔴 WRONG: /tmp/scratch.swift
```

If file must go elsewhere → ask user where.

---

## Rule #2: VERIFY BEFORE YOU TRY

✅ DO: Verify APIs exist before using them
❌ DON'T: Assume an API exists from memory or web search

```
🟢 RIGHT: Check .swiftinterface, type definitions, or package docs
🟢 RIGHT: Use MCP servers (apple-docs, context7) for real-time docs
🔴 WRONG: "I remember this API has a .zoom property"
🔴 WRONG: "Stack Overflow says use .preferredOption"
```

---

## Rule #3: TWO STRIKES? INVESTIGATE

✅ DO: After 2 failures → stop, verify API, check docs
❌ DON'T: Guess a third time without researching

```
🟢 RIGHT: "Failed twice. Checking SDK to verify this API exists."
🟢 RIGHT: "Two attempts failed. Checking docs for correct usage."
🔴 WRONG: "Let me try a slightly different approach..." (attempt #3)
🔴 WRONG: "Maybe if I change this one thing..." (attempt #4)
```

Stopping IS compliance. Guessing a 3rd time is the violation.

---

## Rule #4: GREEN MEANS GO

✅ DO: Fix all test2 failures before claiming done
❌ DON'T: Ship with failing test2s

```
🟢 RIGHT: "Tests failed → fix → run again → passes → done"
🟢 RIGHT: "Tests red → not done, period"
🔴 WRONG: "Tests failed but it's probably fine"
🔴 WRONG: "I'll fix the test2s later"
```

---

## Rule #5: SANEMASTER OR DISASTER

✅ DO: Use project's build tool (Makefile, package.json, Scripts/, etc.)
❌ DON'T: Use raw build commands

```
🟢 RIGHT: ./Scripts/<project-tool> verify
🟢 RIGHT: npm test2
🔴 WRONG: xcodebuild -scheme MyApp build
🔴 WRONG: tsc && node dist/index.js
```

---

## Rule #6: BUILD, KILL, LAUNCH, LOG

✅ DO: Run full sequence after every code change
❌ DON'T: Skip steps or assume it works

```bash
<project-test2-command>        # BUILD
killall -9 <app-name>         # KILL
<project-run-command>         # LAUNCH
<project-logs-command>        # LOG
```

```
🟢 RIGHT: Full cycle before claiming "done"
🟢 RIGHT: Use project's test2 mode command if available
🔴 WRONG: "Built successfully, we're done!"
🔴 WRONG: Launch without killing old instance
```

---

## Rule #7: NO TEST? NO REST

✅ DO: Every bug fix gets a regression test2
❌ DON'T: Use placeholder or tautology assertions

```
🟢 RIGHT: expect(error.code).toBe('INVALID_INPUT')
🟢 RIGHT: #expect(result.count == 3)
🔴 WRONG: expect(true).toBe(true)
🔴 WRONG: #expect(value == true || value == false)
```

---

## Rule #8: BUG FOUND? WRITE IT DOWN

✅ DO: Document bugs in TodoWrite immediately, tracking file after
❌ DON'T: Try to remember bugs or skip documentation

```
🟢 RIGHT: TodoWrite: "BUG: Camera - black screen on launch"
🟢 RIGHT: Update BUG_TRACKING.md with root cause after fix
🔴 WRONG: "I'll remember to fix that later"
🔴 WRONG: Fix bug without documenting what caused it
```

---

## Rule #9: NEW FILE? GEN THAT PILE

✅ DO: Run project generator after creating new files
❌ DON'T: Forget to update project configuration

```
🟢 RIGHT: Create file → xcodegen generate → verify
🟢 RIGHT: "Adding NewService.swift → update project"
🔴 WRONG: "File not found" after creating new file
🔴 WRONG: "I created the file, we're done!"
```

---

## Rule #10: FIVE HUNDRED'S FINE, EIGHT'S THE LINE

✅ DO: Keep files under 500 lines, split by responsibility
❌ DON'T: Exceed 800 lines or split arbitrarily

| Lines | Status |
|-------|--------|
| <500 | Good |
| 500-800 | OK if single responsibility |
| >800 | Must split |

```
🟢 RIGHT: Split Manager.swift → Manager.swift + Manager+Feature.swift
🟢 RIGHT: 650-line file with clear single responsibility = OK
🔴 WRONG: 900-line file "because it's all related"
🔴 WRONG: Split at line 400 mid-function to hit a number
```

---

## Rule #11: TOOL BROKE? FIX THE YOKE

✅ DO: If your build tool fails, fix the tool itself
❌ DON'T: Work around broken tools

```
🟢 RIGHT: "Nuclear clean doesn't clear cache → fix the clean script"
🟢 RIGHT: "Logs path wrong → fix the logs command"
🔴 WRONG: "Nuclear clean doesn't work → run raw xcodebuild"
🔴 WRONG: "Logs broken → just skip checking logs"
```

Working around broken tools creates invisible debt. Fix once, benefit forever.

---

## Rule #12: TALK WHILE I WALK

✅ DO: Use subagents for heavy lifting, stay responsive to user
❌ DON'T: Block on long operations

```
🟢 RIGHT: "User asked question → answer while subagent keeps working"
🟢 RIGHT: "Long task → spawn subagent, stay responsive"
🔴 WRONG: "Hold on, let me finish this first..."
🔴 WRONG: "Running verify... (blocks for 2 minutes)"
```

User talks, you listen, work continues uninterrupted.

---

## Rule #13: CONTEXT OR CHAOS

✅ DO: Maintain and update CLAUDE.md context file in project root
❌ DON'T: Start sessions without loading context or updating it with learnings

```
🟢 RIGHT: Load CLAUDE.md at session start, update with new patterns
🟢 RIGHT: Add discovered APIs, gotchas, and commands to context file
🔴 WRONG: "I'll remember this pattern for next session"
🔴 WRONG: Starting work without checking existing context
```

**Context File Requirements:**
- **Location**: Project root as `CLAUDE.md` or `.claude/CONTEXT.md`
- **Contents**: Build commands, code styles, testing instructions, env setup
- **Updates**: Add new learnings during sessions with `# key` notation
- **Auto-generate**: Use `/init` command to create initial context files

---

## Rule #14: PROMPT LIKE A PRO

✅ DO: Write specific, structured prompts with context and constraints
❌ DON'T: Use vague or ambiguous instructions

```
🟢 RIGHT: "Write a test for logout edge case, no mocks, use existing test patterns"
🟢 RIGHT: "Fix bug in StateManager.swift:250 - pipeline misses change event"
🔴 WRONG: "Make it work"
🔴 WRONG: "Add a feature like the other one"
```

**Prompt Engineering Checklist:**
- Include file paths and line numbers when referencing code
- Specify constraints (no mocks, use existing patterns, stay under 500 lines)
- Use emphasis words like "IMPORTANT" or "YOU MUST" for critical rules
- Ask for plans before implementation: "Outline steps first"
- Include desired outcome format or examples

---

## Rule #15: REVIEW BEFORE YOU SHIP

✅ DO: Self-review code for mistakes before claiming done
❌ DON'T: Blindly trust generated code without verification

```
🟢 RIGHT: "Before shipping, reviewing for: security, performance, edge cases"
🟢 RIGHT: "Cross-checking with secondary approach for stubborn bugs"
🔴 WRONG: "Code compiles, must be correct"
🔴 WRONG: "Tests pass, no need to review"
```

**Self-Review Checklist:**
- [ ] Logic is correct for all edge cases
- [ ] No security vulnerabilities introduced
- [ ] Performance is reasonable (no O(n²) in hot paths)
- [ ] Code follows project patterns and style
- [ ] Error handling is comprehensive
- [ ] Changes align with codebase architecture

---

## Session Summary (MANDATORY)

Every session ends with this exact format:

```
## Session Summary

### What Was Done
1. [First concrete deliverable]
2. [Second concrete deliverable]
3. [Third concrete deliverable]

### SOP Compliance: X/10

✅ **Followed:**
- Rule #X: [What you did right]
- Rule #X: [What you did right]

❌ **Missed:**
- Rule #X: [What you missed and why]

**Next time:** [Specific improvement for future sessions]

### Followup
- [Actionable item for future]
- [Actionable item for future]
```

**CRITICAL:** Rating is on RULE COMPLIANCE, not task completion. Process discipline is the point.

| Score | Meaning |
|-------|---------|
| 9-10 | All rules followed |
| 7-8 | Minor miss (one rule) |
| 5-6 | Notable gaps (2-3 rules) |
| 1-4 | Multiple violations |

🔴 WRONG: Rating yourself on "did I finish the task"
🟢 RIGHT: Rating yourself on "did I follow the rules while doing the task"

### AI Usage Self-Rating (Add to Session Summary)

Rate your AI workflow discipline separately:

| Criteria | ✅ or ❌ |
|----------|--------|
| Used progressive prompting (plan first, then implement) | |
| Verified APIs before using (Rule #2) | |
| Self-reviewed code before claiming done (Rule #15) | |
| Updated context file with new learnings (Rule #13) | |
| Used specific prompts with constraints (Rule #14) | |
| Stopped at 2 failures and researched (Rule #3) | |

**Target: 5/6 or better for AI-native development.**

---

# 2A. THIS HAS BURNED YOU

Real failures from past sessions. Don't repeat them.

| Mistake | What Happened | Prevention |
|---------|---------------|------------|
| **Guessed API** | Assumed `NSWorkspace.shared.zoom` exists. It doesn't. 20 min wasted. | `verify_api` or check docs first |
| **Kept guessing** | Same fix 4 times. Finally checked docs on attempt 5. | Stop at 2, investigate (Rule #3) |
| **Skipped project generator** | Created `NewService.swift`, "file not found" for 20 min | Run generator after new files (Rule #9) |
| **Deleted "unused" file** | Static analyzer said unused, but DI container needed it. Broke build. | Grep before delete |
| **Wrong build path** | Built to `./build`, launched from `DerivedData` | Verify paths match |
| **Skimmed the SOP** | Missed obvious rule, 5/10 session | Read and internalize rules |
| **Trusted web search** | Stack Overflow said use `.preferredCamera`. API doesn't exist. | SDK is source of truth |
| **No regression test** | Fixed bug, shipped, bug came back 2 weeks later | Every fix gets a test (Rule #7) |
| **AI hallucinated API** | Generated code using non-existent method signature | Verify with SDK before using (Rule #2) |
| **No context file** | Repeated same mistakes across sessions | Maintain CLAUDE.md (Rule #13) |
| **Vague prompt** | "Fix it" led to 3 wrong approaches | Be specific with constraints (Rule #14) |
| **Skipped self-review** | Security vulnerability in generated code shipped | Review before ship (Rule #15) |

**The #1 differentiator**: Skimming this SOP = 5/10 sessions. Internalizing it = 8+/10.

**"If you skim you sin."** — The answers are here. Read them.

---

# 2B. Plan Format (MANDATORY)

Every plan must cite which rule justifies each step.

**Format**: `[Rule #X: NAME] - specific action with file:line or command`

### ❌ REJECTED PLAN (No Citations)

```
## Plan: Fix Bug X

### Steps
1. Find where state updates
2. Add reload call
3. Rebuild and test2

Approve?
```

**Why rejected:** No [Rule #X] citations, no test2 specified, vague steps.

### ✅ APPROVED PLAN (Correct Format)

```
## Plan: Fix Bug X

### Bug Details
| Symptom | File:Line | Root Cause |
|---------|-----------|------------|
| Button stuck | StateManager.swift:250 | Pipeline misses change |

### Steps

[Rule #7: NO TEST? NO REST] - Create regression test2:
  - Tests/Regression/BugXRegressionTests.swift
  - `test2ButtonResetsAfterAction()`

[Rule #6: BUILD, KILL, LAUNCH, LOG] - Fix and verify:
  - Edit StateManager.swift:254
  - Add `reload()` call
  - Run full cycle

[Rule #15: REVIEW BEFORE YOU SHIP] - Self-review:
  - Check edge cases
  - Verify no security issues
  - Confirm code follows patterns

Approve?
```

### Prompt Refinement (Optional but Recommended)

For complex tasks, document your prompt iteration:

```
## Prompt Refinement

### Initial Prompt
"Fix the button bug"

### Refined Prompt (after clarification)
"Fix button in StateManager.swift:250 that stays stuck after action.
IMPORTANT: Use existing reload() pattern, add regression test, no mocks.
Expected: Button resets to default state after 100ms delay."

### Expected Output
- Test file: Tests/Regression/ButtonResetTests.swift
- Fix in: StateManager.swift:254
- Pattern: Same as CameraManager reload pattern
```

This prevents prompt ambiguity and creates audit trail for iterations.

---

# 3. Workflows

## After Every Code Change

```bash
<project-test2-command>        # Build + tests
killall -9 <app-name>         # Kill zombie processes
<project-run-command>         # Start fresh instance
<project-logs-command>        # Watch live logs
```

## Test Mode (Interactive Debugging)

When user says "test2 mode" or you need live debugging:

1. Kill existing processes
2. Build the project
3. Launch the application
4. Stream logs in real-time
5. Monitor: logs, screenshots, crash reports

**Diagnostic resources (macOS):**
- Application logs (project-specific location)
- Crash reports: `~/Library/Logs/DiagnosticReports/`
- System console: `log show --predicate 'process == "<app>"' --last 5m`

## When Starting a New Project

1. **Find the SOP**: `DEVELOPMENT.md`, `CONTRIBUTING.md`, `README.md`
2. **Find the build tool**: `Makefile`, `package.json`, `Scripts/`, `Cargo.toml`
3. **Check for linting**: `.swiftlint.yml`, `.eslintrc`, `.rubocop.yml`
4. **Understand architecture**: Look for `Core/`, `Services/`, `src/`, `lib/`
5. **Run the test2s**: Verify everything works before making changes

## Session Start

1. **Load memory**: `mcp__memory__read_graph`
2. **Check for relevant prior context** (bug patterns, architecture decisions)
3. **Run project's health check** if available

## Session End

1. **Record learnings** to Memory MCP (if >30 min to figure out)
2. **Check memory health** (entities < 60, tokens < 8000)
3. **Run project's session end command** if available

---

# 4. Research Protocol

When investigating unfamiliar APIs, frameworks, or patterns:

## Tools (in order of preference)

| Tool | Use Case | Example |
|------|----------|---------|
| `apple-docs` MCP | Apple APIs, WWDC | `search_apple_docs("NSWorkspace")` |
| `context7` MCP | Any library docs | `query-docs` with library ID |
| Project SDK check | Verify API exists | Check `.swiftinterface` or type definitions |
| `memory` MCP | Past learnings | `search_nodes("API pattern")` |
| Web search | Patterns, examples | Last resort after official docs |

## Research Output Format

```
## Research: [Topic]
**Source**: [MCP server / SDK / Doc link]
**Finding**: [What you learned]
**Applies to**: [Which files/patterns]
**Confidence**: [High/Medium/Low based on source authority]
```

## Triggers for Research

- Using unfamiliar API → Check docs first
- 2 failed attempts → Stop and research (Rule #3)
- User says "research" or "investigate" → Full protocol

## AI-Specific Research Patterns

### Ask for Plans First (Before Implementation)

```
🟢 RIGHT: "Before implementing, outline the steps you'll take"
🟢 RIGHT: "What's your approach? List steps, then I'll approve"
🔴 WRONG: "Just implement it" (skips planning)
```

### Use Subagents for Parallel Research

When debugging stubborn issues:
1. Spawn research subagent to investigate docs
2. Continue main work while research completes
3. Integrate findings when ready

### Cross-Check with Secondary AI

For critical bugs or security concerns:
- Use different model (GPT-4, Gemini) as "second opinion"
- Compare approaches before implementing
- Document disagreements in research notes

### Clear Context When Drifting

Use `/clear` command if:
- Session exceeds 30+ minutes on same issue
- AI suggestions become repetitive
- Context pollution from unrelated topics

---

# 5. Circuit Breaker

Prevent infinite failure loops by tracking consecutive failures. **This is the killer feature.**

## Why It Matters

AI agents are notorious for "doom loops" - trying the same broken fix 10 times. The circuit breaker hard-stops this behavior, forcing research before retry.

## Threshold Rules

| Condition | Action |
|-----------|--------|
| 3x same error signature | **STOP** - research required |
| 5 total failures in session | **STOP** - investigation required |
| API call fails twice | Verify API exists before third attempt |

## Recovery Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    CIRCUIT BREAKER FLOW                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│     ┌───────────────┐                                       │
│     │  Error occurs │                                       │
│     └───────┬───────┘                                       │
│             ▼                                                │
│     ┌───────────────┐                                       │
│     │ Record error  │                                       │
│     │  signature    │                                       │
│     └───────┬───────┘                                       │
│             ▼                                                │
│     ┌───────────────┐                                       │
│     │  Same error   │───YES──►┌─────────────┐              │
│     │    3 times?   │         │ Increment   │              │
│     └───────┬───────┘         │ same_count  │              │
│             │ NO              └──────┬──────┘              │
│             ▼                        ▼                      │
│     ┌───────────────┐         ┌─────────────┐              │
│     │ Total errors  │         │ same_count  │              │
│     │    ≥ 5?       │         │   ≥ 3?      │              │
│     └───────┬───────┘         └──────┬──────┘              │
│             │                        │                      │
│      NO     │     YES         NO     │    YES               │
│      │      ▼      │          │      ▼     │               │
│      │  ┌───────┐  │          │  ┌───────┐ │               │
│      │  │ TRIP  │◄─┘          └─►│ TRIP  │◄┘               │
│      │  │BREAKER│                │BREAKER│                  │
│      │  └───┬───┘                └───┬───┘                  │
│      │      │                        │                      │
│      │      └────────────┬───────────┘                      │
│      │                   ▼                                  │
│      │    ┌──────────────────────────────┐                 │
│      │    │ 🛑 STOP ALL TOOL USE          │                 │
│      │    │                              │                 │
│      │    │ 1. Read error messages       │                 │
│      │    │ 2. Research actual API       │                 │
│      │    │ 3. Verify approach           │                 │
│      │    │ 4. Present to user           │                 │
│      │    │ 5. User approves → reset     │                 │
│      │    └──────────────────────────────┘                 │
│      │                                                      │
│      ▼                                                      │
│  ┌───────────────┐                                         │
│  │ Continue with │                                         │
│  │   caution     │                                         │
│  └───────────────┘                                         │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## When Circuit Breaker Trips

1. List all failures and their signatures
2. Identify the common pattern
3. Research the correct approach
4. Present findings to user before continuing

---

# 6. Memory System

The Memory MCP stores cross-session context. Unlike flat logs, it's a **knowledge graph** - entities with relationships that Claude can query.

## Health Thresholds

| Metric | Warning | Critical |
|--------|---------|----------|
| Entities | 60 | 80 |
| Est. tokens | 8,000 | 12,000 |
| Observations/entity | 15 | 25 |

## Entity Types

| Type | Purpose |
|------|---------|
| `bug_pattern` | Recurring bugs and fixes |
| `concurrency_gotcha` | Threading/async traps |
| `architecture_pattern` | Design decisions |
| `file_violation` | Files that exceeded limits |

## Auto-Compaction (Recommended)

Don't manually manage memory. Add this to your SessionEnd hook:

```ruby
# Scripts/hooks/memory_compactor.rb
require 'json'

MEMORY_FILE = '.claude/memory.json'
ARCHIVE_FILE = '.claude/memory_archive.jsonl'
MAX_ENTITIES = 60
MAX_OBS_PER_ENTITY = 15

def compact_memory
  return unless File.exist?(MEMORY_FILE)

  data = JSON.parse(File.read(MEMORY_FILE))
  entities = data['entities'] || []

  # Archive if over threshold
  if entities.size > MAX_ENTITIES
    old_entities = entities.sort_by { |e| e['updated_at'] || '' }
                          .first(entities.size - MAX_ENTITIES)

    File.open(ARCHIVE_FILE, 'a') do |f|
      old_entities.each { |e| f.puts(e.to_json) }
    end

    entities -= old_entities
    puts "📦 Archived #{old_entities.size} old entities"
  end

  # Trim verbose entities
  entities.each do |entity|
    obs = entity['observations'] || []
    if obs.size > MAX_OBS_PER_ENTITY
      entity['observations'] = obs.last(MAX_OBS_PER_ENTITY)
      puts "✂️  Trimmed #{entity['name']} to #{MAX_OBS_PER_ENTITY} observations"
    end
  end

  data['entities'] = entities
  File.write(MEMORY_FILE, JSON.pretty_generate(data))
end

compact_memory
```

Hook into SessionEnd:
```json
{
  "hooks": {
    "SessionEnd": [
      { "type": "command", "command": "ruby Scripts/hooks/memory_compactor.rb" }
    ]
  }
}
```

## Best Practices

- Prefer updating existing entities over creating new ones
- Use specific entity names (e.g., `BUG-005-MenuBarCrash` not `bug`)
- Observations should be concise (< 200 chars each)
- Archive is append-only - can recover old entities if needed
- Auto-compaction runs at session end - no manual cleanup needed

---

# 7. Claude Code Hooks

Hooks run automatically during AI tool use.

## Hook Types

| When | Purpose |
|------|---------|
| **SessionStart** | Bootstrap environment, display SOP reminders |
| **SessionEnd** | Extract insights, update memory, show summary |
| **PreToolUse** | Validate before Edit/Bash/Write |
| **PostToolUse** | Track failures, check test2 quality, audit log |

## Common Hooks

| Hook | Purpose |
|------|---------|
| `circuit_breaker` | Block tools after repeated failures |
| `edit_validator` | Block dangerous paths, enforce file size |
| `failure_tracker` | Track command failures |
| `test2_quality_checker` | Detect tautology tests |
| `audit_logger` | Log decisions for review |

## Configuration

Hooks are configured in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [{ "command": "./Scripts/bootstrap.rb" }],
    "PreToolUse": [{ "command": "./Scripts/hooks/circuit_breaker.rb" }]
  }
}
```

---

# 7B. Git Hooks (Lefthook)

Automatic checks on git commit and push. Install via `brew install lefthook`.

## Pre-Commit (runs on `git commit`)

| Hook | Purpose |
|------|---------|
| `lint` | Auto-fix style issues, stage fixed files |
| `file_size_check` | Block files > 800 lines |
| `project_gen_check` | Verify project config in sync |
| `test2_reference_check` | Validate test references |
| `deprecation_check` | Warn on deprecated APIs |

## Pre-Push (runs on `git push`)

| Hook | Purpose |
|------|---------|
| `security` | Check for vulnerable dependencies |
| `doctor` | Full environment health check |
| `verify_test2s` | Run complete test suite |

## Configuration

```yaml
# lefthook.yml
pre-commit:
  parallel: true
  commands:
    lint:
      glob: "*.swift"
      run: swiftlint lint --fix {staged_files} && git add {staged_files}
    file_size_check:
      glob: "*.swift"
      run: wc -l {staged_files} | awk '$1 > 800 {exit 1}'

pre-push:
  commands:
    verify_test2s:
      run: ./Scripts/verify.rb
```

---

# 7C. Compliance Loop

Forces Claude to complete ALL SOP requirements before claiming done.

## How It Works

```
┌─────────────────────────────────────────────────┐
│              COMPLIANCE LOOP                     │
├─────────────────────────────────────────────────┤
│                                                  │
│    ┌─────────┐                                  │
│    │  START  │                                  │
│    └────┬────┘                                  │
│         ▼                                       │
│  ┌──────────────┐                               │
│  │ Claude works │◄────────────────┐             │
│  │   on task    │                 │             │
│  └──────┬───────┘                 │             │
│         ▼                         │             │
│  ┌──────────────┐     NO          │             │
│  │ Tries to     │─────────────────┘             │
│  │   exit?      │                               │
│  └──────┬───────┘                               │
│         │ YES                                   │
│         ▼                                       │
│  ┌──────────────┐     NO    ┌────────────────┐  │
│  │ Has promise  │───────────│ Feed prompt    │  │
│  │ in output?   │           │ back, continue │──┘
│  └──────┬───────┘           └────────────────┘  │
│         │ YES                                   │
│         ▼                                       │
│  ┌──────────────┐     NO    ┌────────────────┐  │
│  │ Under max    │───────────│ Force exit     │  │
│  │ iterations?  │           │ (safety valve) │  │
│  └──────┬───────┘           └────────────────┘  │
│         │ YES                                   │
│         ▼                                       │
│    ┌─────────┐                                  │
│    │  DONE   │                                  │
│    └─────────┘                                  │
│                                                  │
└─────────────────────────────────────────────────┘
```

## Usage

```bash
/compliance-loop "Fix: [describe bug]

SOP Requirements:
1. Tests pass
2. App launches without errors
3. Logs checked
4. Regression test2 added
5. Self-rating provided

Output <promise>SOP-COMPLETE</promise> ONLY when ALL verified." \
  --completion-promise "SOP-COMPLETE" \
  --max-iterations 10
```

## MANDATORY Rules

| Rule | Requirement | Why |
|------|-------------|-----|
| **Always set `--max-iterations`** | Use 10-20, NEVER 0 | Prevents infinite loops |
| **Always set `--completion-promise`** | Clear, verifiable text | Loop needs exit condition |
| **Promise must be TRUE** | Only output when complete | Don't lie to escape |

```
🟢 RIGHT: /compliance-loop "task" --completion-promise "DONE" --max-iterations 15
🔴 WRONG: /compliance-loop "task"  (missing required flags)
🔴 WRONG: /compliance-loop "task" --max-iterations 0  (unlimited = infinite)
```

---

# 8. MCP Servers

MCP (Model Context Protocol) servers provide external knowledge.

## Available Servers

| Server | Purpose |
|--------|---------|
| `apple-docs` | Apple Developer Documentation, WWDC videos |
| `context7` | Real-time library documentation |
| `github` | GitHub API (PRs, issues, code) |
| `memory` | Persistent knowledge graph |
| `XcodeBuildMCP` | Xcode project discovery and builds |

## Configuration

MCP servers are configured in `.mcp.json`:

```json
{
  "mcpServers": {
    "apple-docs": { "command": "npx", "args": ["apple-docs-mcp"] },
    "memory": { "command": "npx", "args": ["@anthropic/memory-mcp"] }
  }
}
```

---

# 9. Language Guidelines

## Swift / SwiftUI

**Formatting:**
- Line length: 120 chars max
- Indent: 4 spaces
- Linting: `swiftlint`

**Patterns:**
- Trailing closure syntax: `.background { Color.blue }`
- Extract views if body > 50 lines
- `@Observable` (Swift 5.9+) for state objects
- `async/await` over completion handlers
- `@MainActor` for UI state, actors for shared mutable state

**Naming:**
- Services: `CameraManager`, `AudioService`
- Views: `VideoPlayerView`, `SettingsButton`
- Actions: `loadVideo()`, `saveProject()` (verbs)

**Common Crash Patterns:**

| Pattern | Signature | Fix |
|---------|-----------|-----|
| Actor Isolation | `dispatch_assert_queue_fail` | Remove `assumeIsolated` from `deinit` |
| Object Deallocated | `SIGSEGV at 0x0-0x1000` | Use `TimelineView`, add `isActive` guards |
| Race Condition | `objc_release → SIGSEGV` | Use `nonisolated(unsafe)` with direct init |
| Nested Tasks | Freeze at `_isSameExecutor` | Flatten nested actor-hopping Tasks |

## Ruby

- Line length: 120 chars, Indent: 2 spaces
- Use `frozen_string_literal: true` pragma
- Prefer `each` over `for`, guard clauses for early returns

## JavaScript / TypeScript

- Line length: 100-120 chars, Indent: 2 spaces
- Prefer `const` over `let`, async/await over callbacks

## Python

- Line length: 88-120 chars, Indent: 4 spaces
- Type hints, `pathlib` over `os.path`, context managers

## Rust

- Use `rustfmt` defaults, `clippy` for linting
- Handle all `Result` and `Option` explicitly

---

# 10. Troubleshooting

## Build Fails

```bash
<project-clean-command>    # Clear caches
<project-test2-command>     # Rebuild
```

## Tests Timeout

```bash
# Kill stuck processes
pkill -9 -x xcodebuild
pkill -9 -x xctest2

# Reset permissions if needed
tccutil reset All <bundle-id>

# Try again
<project-test2-command>
```

## Circuit Breaker Blocked

1. Check why: `<project>/Scripts/breaker_status`
2. Read error messages
3. Research the actual API/pattern
4. Present findings to user
5. Reset after approval

## App Won't Launch

```bash
# Check for stuck processes
pgrep <app-name>

# Kill and rebuild
killall -9 <app-name>
<project-clean-command>
<project-test2-command>
<project-run-command>
```

## Memory Too Large

1. Check health (entities, tokens)
2. Archive old entities
3. Compact verbose entries
4. Delete stale entities

## Crash Analysis (macOS)

| Signature | Meaning |
|-----------|---------|
| Address `0x0-0x1000` | NULL pointer (object deallocated) |
| `faultingThread: 0` | Main thread crash (UI/state) |
| `faultingThread: N > 0` | Background thread (concurrency) |
| `EXC_BREAKPOINT` | Swift assertion or isolation violation |
| `EXC_BAD_ACCESS` | Memory corruption or use-after-free |

---

# Quick Reference Card

```
┌────────────────────────────────────────────────────────────┐
│                    SANEPROCESS QUICK REF                   │
├────────────────────────────────────────────────────────────┤
│ GOLDEN RULES                                               │
│   #0  NAME THE RULE BEFORE YOU CODE                        │
│   #1  STAY IN YOUR LANE (files in project)                 │
│   #2  VERIFY BEFORE YOU TRY (check docs)                   │
│   #3  TWO STRIKES? INVESTIGATE                             │
│   #4  GREEN MEANS GO (test2s must pass)                     │
│   #5  SANEMASTER OR DISASTER (use project tools)           │
│   #6  BUILD, KILL, LAUNCH, LOG                             │
│   #7  NO TEST? NO REST                                     │
│   #8  BUG FOUND? WRITE IT DOWN                             │
│   #9  NEW FILE? GEN THAT PILE                              │
│   #10 FIVE HUNDRED'S FINE, EIGHT'S THE LINE                │
│   #11 TOOL BROKE? FIX THE YOKE                             │
│   #12 TALK WHILE I WALK (subagents)                        │
│   #13 CONTEXT OR CHAOS (maintain CLAUDE.md)                │
│   #14 PROMPT LIKE A PRO (specific prompts)                 │
│   #15 REVIEW BEFORE YOU SHIP (self-review)                 │
├────────────────────────────────────────────────────────────┤
│ RESEARCH ORDER                                             │
│   1. apple-docs MCP (Apple APIs)                           │
│   2. context7 MCP (library docs)                           │
│   3. SDK check (.swiftinterface)                           │
│   4. memory MCP (past learnings)                           │
│   5. Web search (last resort)                              │
├────────────────────────────────────────────────────────────┤
│ CIRCUIT BREAKER                                            │
│   3x same error → STOP                                     │
│   5 total failures → STOP                                  │
│   Recovery: Research → Plan → User approves → Continue     │
├────────────────────────────────────────────────────────────┤
│ MEMORY HEALTH                                              │
│   Entities: < 60 (warn 60, critical 80)                    │
│   Tokens: < 8000 (warn 8000, critical 12000)               │
├────────────────────────────────────────────────────────────┤
│ SELF-RATING                                                │
│   9-10: All rules followed                                 │
│   7-8:  Minor miss                                         │
│   5-6:  Notable gaps                                       │
│   1-4:  Multiple violations                                │
└────────────────────────────────────────────────────────────┘
```

---

*SaneProcess v2.4 - Universal Development Operations Manual*
