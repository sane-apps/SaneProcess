# SaneProcess Architecture

> **Project Docs:** [CLAUDE.md](CLAUDE.md) · [README](README.md) · [DEVELOPMENT](DEVELOPMENT.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SESSION_HANDOFF](SESSION_HANDOFF.md)
>
> You are reading **ARCHITECTURE.md** — how the enforcement system works, why decisions were made, and competitive positioning.
> For build/test procedures, see [DEVELOPMENT](DEVELOPMENT.md). For AI instructions, see [CLAUDE](CLAUDE.md).

---

## 1. System Overview

SaneProcess is a hook-based enforcement framework for Claude Code that implements the scientific method as a development workflow. Four Ruby hooks intercept Claude Code events (prompt submission, tool calls, tool results, session end), enforce research-before-edit discipline through a 4-category research gate (docs, web, github, local), and prevent doom loops via a circuit breaker pattern. All state lives in a single HMAC-signed JSON file.

### Component Diagram

```mermaid
graph TD
    CC[Claude Code] -->|UserPromptSubmit| SP[saneprompt.rb]
    CC -->|PreToolUse| ST[sanetools.rb]
    CC -->|PostToolUse| SK[sanetrack.rb]
    CC -->|Stop| SS[sanestop.rb]

    SP --> STATE[state.json]
    ST --> STATE
    SK --> STATE
    SS --> STATE

    ST -->|exit 0| ALLOW[Tool Executes]
    ST -->|exit 2| BLOCK[Tool Blocked]

    subgraph "Core Infrastructure"
        CFG[config.rb] --> STATE
        SM[state_manager.rb] --> STATE
    end

    SP --> CFG
    ST --> CFG
    SK --> CFG
    SS --> CFG
```

### Entry Points

| Hook Type | Script | When | Exit Codes |
|-----------|--------|------|------------|
| UserPromptSubmit | saneprompt.rb | User sends message | 0=allow |
| PreToolUse | sanetools.rb | Before tool executes | 0=allow, 2=block |
| PostToolUse | sanetrack.rb | After tool completes | 0=always |
| Stop | sanestop.rb | Session ends | 0=allow |

### Core Modules

```
scripts/hooks/core/
├── config.rb         # Paths, thresholds, settings
└── state_manager.rb  # Read/write state.json (HMAC-signed, file-locked)
```

- **config.rb** — Single source for all configuration: project paths, state file location, bypass detection, circuit breaker threshold (3), file size limits (500 warn / 800 block), blocked system paths.
- **state_manager.rb** — All state in one signed JSON file. API: `get(:section, :key)`, `set(:section, :key, value)`, `update(:section) { |s| s }`, `reset(:section)`. File locking for concurrent access. HMAC signing for tamper detection.

### File Locations

```
.claude/
├── state.json           # All hook state (signed)
├── state.json.lock      # File lock
├── bypass_active.json   # Safemode marker (exists = active)
├── saneprompt.log       # Prompt hook log
├── sanetools.log        # Tools hook log
├── sanetrack.log        # Track hook log
├── sanestop.log         # Stop hook log
└── audit.jsonl          # Audit log
```

---

## 2. State Machines

### Enforcement State Machine

The main enforcement lifecycle: from user prompt through research gate to edit permission.

```mermaid
stateDiagram-v2
    [*] --> PromptReceived

    PromptReceived --> Classified : saneprompt.rb classifies
    Classified --> Question : is_question?
    Classified --> Task : is_task?

    Question --> ReadAllowed : skip research gate
    Task --> ResearchRequired : set requirements

    ResearchRequired --> Researching : tools used
    Researching --> Researching : category completed
    Researching --> ResearchComplete : all 4 categories done

    ResearchComplete --> EditAllowed : gate opens
    EditAllowed --> Editing : Edit/Write tool
    Editing --> TrackResult : sanetrack.rb

    TrackResult --> EditAllowed : success (reset failures)
    TrackResult --> FailureTracked : error detected
    FailureTracked --> EditAllowed : failures < threshold
    FailureTracked --> BreakerTripped : 3+ consecutive or 3x same signature

    BreakerTripped --> EditAllowed : manual reset (rb- command)
```

### Prompt Classification Flow

```mermaid
flowchart TD
    INPUT[User Message] --> CMD{Is command?}
    CMD -->|s+/s-/s?| SAFE[Safemode Toggle]
    CMD -->|rb-/rb?| BREAKER[Breaker Control]
    CMD -->|research| PROGRESS[Show Progress]
    CMD -->|No| CLASS{Classify}

    CLASS -->|Question| Q[Skip Gate]
    CLASS -->|Task| T[Set Requirements]
    CLASS -->|Edit request| E[Check Gates]

    E --> CB{Circuit breaker<br/>tripped?}
    CB -->|Yes| WARN[Warn + Suggest Reset]
    CB -->|No| PROCEED[Allow Prompt]
```

### Research Gate

Before any edit (Edit, Write, Bash with mutation) is allowed, 4 research categories must be satisfied:

```mermaid
flowchart LR
    EDIT[Edit/Write Request] --> GATE{All 4 done?}

    GATE -->|No| BLOCKED[EXIT 2: BLOCKED]
    GATE -->|Yes| ALLOWED[EXIT 0: ALLOW]

    subgraph "4 Categories"
        DOC[docs<br/>apple-docs / context7]
        WEB[web<br/>WebSearch / WebFetch]
        GH[github<br/>mcp__github__*]
        LOC[local<br/>Read / Grep / Glob]
    end

    DOC --> GATE
    WEB --> GATE
    GH --> GATE
    LOC --> GATE
```

### Circuit Breaker Flow

```mermaid
flowchart TD
    FAIL[Tool Failure Detected] --> NORM[Normalize Error Signature]
    NORM --> INC[Increment failures + per-signature count]

    INC --> CHECK{Thresholds}
    CHECK -->|3 consecutive| TRIP[TRIP BREAKER]
    CHECK -->|3x same signature| TRIP
    CHECK -->|Below threshold| CONTINUE[Continue]

    TRIP --> BLOCK_EDITS[Block all edits]
    BLOCK_EDITS --> SHOW[Show warning + suggest reset]

    RESET[User: rb- / reset breaker] --> CLEAR[Clear failures, untrip]
    CLEAR --> CONTINUE
```

### Tool Categorization (Blast Radius)

| Category | Examples | Blocked Until |
|----------|----------|---------------|
| Read-only | Read, Grep, Glob, search | Never blocked |
| Local mutation | Edit, Write | Research complete |
| Sensitive files | CI/CD, entitlements, .xcconfig, Fastfile | Confirmed once per file per session |
| External mutation | GitHub push | Research complete |

### State Schema

```json
{
  "circuit_breaker": {
    "failures": 0,
    "tripped": false,
    "tripped_at": null,
    "last_error": null,
    "error_signatures": {}
  },
  "requirements": {
    "requested": [],
    "satisfied": [],
    "is_task": false,
    "is_big_task": false,
    "is_research_only": false
  },
  "research": {
    "docs": null,
    "web": null,
    "github": null,
    "local": null
  },
  "edits": {
    "count": 0,
    "unique_files": [],
    "last_file": null
  },
  "saneloop": {
    "active": false,
    "task": null,
    "iteration": 0,
    "max_iterations": 20,
    "acceptance_criteria": [],
    "started_at": null
  },
  "enforcement": {
    "blocks": [],
    "halted": false,
    "halted_at": null,
    "halted_reason": null,
    "session_started_at": null
  },
  "edit_attempts": {
    "count": 0,
    "last_attempt": null,
    "reset_at": null
  },
  "sensitive_approvals": {},
  "action_log": [],
  "learnings": [],
  "patterns": {
    "weak_spots": {},
    "triggers": {},
    "strengths": [],
    "session_scores": []
  },
  "validation": {
    "sessions_total": 0,
    "sessions_with_tests_passing": 0,
    "sessions_with_breaker_trip": 0,
    "blocks_that_were_correct": 0,
    "blocks_that_were_wrong": 0,
    "doom_loops_caught": 0,
    "doom_loops_missed": 0,
    "time_saved_estimates": [],
    "first_tracked": null,
    "last_updated": null
  },
  "mcp_health": {
    "verified_this_session": false,
    "last_verified": null,
    "mcps": {
      "apple_docs": { "verified": false, "last_success": null, "failure_count": 0 },
      "context7": { "verified": false, "last_success": null, "failure_count": 0 },
      "github": { "verified": false, "last_success": null, "failure_count": 0 }
    }
  },
  "refusal_tracking": {},
  "task_context": {
    "task_type": null,
    "task_keywords": [],
    "task_hash": null,
    "researched_at": null
  },
  "session_docs": {
    "required": [],
    "read": [],
    "enforced": true
  },
  "verification": {
    "tests_run": false,
    "verification_run": false,
    "last_test_at": null,
    "test_commands": [],
    "edits_before_test": 0
  },
  "planning": {
    "required": false,
    "plan_shown": false,
    "plan_approved": false,
    "replan_count": 0,
    "forced_at": null
  },
  "skill": {
    "required": null,
    "invoked": false,
    "invoked_at": null,
    "subagents_spawned": 0,
    "files_read": [],
    "satisfied": false,
    "satisfaction_reason": null
  }
}
```

### Concurrency Model

**Single-writer, file-locked state:**
- All hooks read/write `state.json` through `StateManager`
- File locking (`state.json.lock`) prevents concurrent writes
- Hooks execute sequentially per Claude Code event — no parallel hook execution
- HMAC signing prevents external tampering with state

**Race condition mitigations:**
- `StateManager.update(:section)` does atomic read-modify-write under lock
- If lock acquisition fails, hook fails safe (exit 0, allows tool)
- PostToolUse (sanetrack) and PreToolUse (sanetools) never run simultaneously for the same tool call

### User Commands

| Command | Hook | Effect |
|---------|------|--------|
| `s+` | saneprompt | Enable safemode (blocks all edits) |
| `s-` | saneprompt | Disable safemode |
| `s?` | saneprompt | Show safemode status |
| `rb-` / `rb+` / `reset breaker` | saneprompt | Reset circuit breaker |
| `rb?` / `breaker status` | saneprompt | Show breaker status |
| `research` | saneprompt | Show research progress |

### Design Principles

1. **One state file** — No scattered JSON files
2. **Exit codes matter** — 0 allow, 2 block
3. **Fail safe** — On error, allow (don't block randomly)
4. **Self-testable** — Every hook has `--self-test`
5. **Centralized config** — All paths in Config module
6. **Text ≠ Error** — Check explicit error fields, not content

---

## 3. Architecture Decisions

### ADR-001: Consolidate from 23 hooks to 4 (2026-01-04)

**Context:** The original hook system had 23 files (~4,260 lines) with significant duplication: circuit breaker logic in 3 files, research tracking in 2 files, SaneLoop enforcement in 3 files, edit counting in 5 files, bypass checking in 5 files. `process_enforcer.rb` alone was 924 lines. 15+ separate state files made reasoning difficult.

**Options:**
1. Keep granular hooks, fix duplication
2. Consolidate into 4 event-driven hooks with shared core
3. Registry/coordinator pattern (detector → decision → action pipeline)

**Decision:** Option 2 — consolidate into 4 hooks (saneprompt, sanetools, sanetrack, sanestop) with shared `core/` modules. The registry pattern (Option 3) was designed but deferred as premature — `hook_registry.rb` and `coordinator.rb` exist as stubs.

**Rationale:**
- Industry patterns (pre-commit, ESLint, Husky) all use centralized state + separation of concerns
- 4 hooks maps 1:1 to Claude Code's 4 event types
- Single state file eliminates 15 scattered JSON files
- File locking + HMAC signing solved both concurrency and tampering
- Result: every file under 500 lines, single state file, all detectors testable

### ADR-002: SanePrompt orchestration design (2026-01-04)

**Context:** Claude Code needed a system to transform vague user prompts into structured, research-gated execution plans with explicit rule mapping.

**Decision:** Designed a multi-phase orchestration: prompt → classification → research burst → execution → checkpoint → summary. Execution modes: Autonomous, Phase-by-phase (default), Supervised, Modify plan.

**Key design choices:**
- 4-category parallel research burst before any edits
- Rule mapping baked into classification (bug fix → #8, #7, #4, #3; new feature → #0, #2, #9, #5)
- Gaming detection: rating inflation (5+ consecutive 8+/10), bypass creation, research skipping, rule citation without evidence
- Passthrough patterns for commands (`/commit`, `yes`, `continue`) skip transformation
- Frustration detection: ALL CAPS, repeated instructions, "read the prompt" trigger re-read

**Status:** Core classification shipped in saneprompt.rb. Advanced orchestration (phase runner, gaming detector, clarifier) designed but not implemented — the hook-based enforcement catches the same issues.

### ADR-003: GitHub org migration — personal → sane-apps (2026-01-19)

**Context:** All repos under personal `stephanjoseph` account. Needed professional branding for paid products.

**Decision:** Transfer all repos to `sane-apps` GitHub organization. Public apps (SaneBar, SaneClip, SaneProcess, SaneHosts, SaneSync, SaneAI), private tools (SaneVideo, forks).

**Completed:** Phase 1 (repo transfer), Phase 2 (file reference updates), Phase 4 (distribution model).
**Deferred:** Phase 3 (copyright holder update), Phase 5 (bundle ID standardization — changing breaks user preferences/keychain).

**Distribution model decision:** Open source (free on GitHub) + paid binaries ($5 via Lemon Squeezy). No Homebrew. DMGs served from Cloudflare R2 (`dist.{app}.com/updates/`), not GitHub Releases.

**Bundle ID policy:** Keep existing inconsistent bundle IDs (`com.sanebar.app`, `com.mrsane.SaneHosts`, etc.) — changing breaks user data. Standardize only for NEW apps: `com.mrsane.{AppName}`.

### ADR-004: Hook matcher wildcard feature request (2026-01-04)

**Context:** MCP tools (e.g., `mcp__github__push_files`) bypass all enforcement because hook matchers require exact tool names. Any enforcement layer built with hooks has a fundamental bypass via dynamically-named MCP tools.

**Decision:** Filed feature request with Anthropic for wildcard/pattern matching in hook matchers. Workaround: explicit matchers for known MCP tools (maintenance burden, incomplete coverage).

**Proposed solutions:**
1. Glob-style wildcards: `"matcher": "mcp__*"`
2. Catch-all: `"matcher": "*"`
3. Regex: `"matcher": "/^mcp__/"`

**Status:** Request filed. Workaround (explicit matchers) in use.

---

## 4. Research & Competitive Analysis

### Competitive Landscape (2026-01-02)

**Positioning:** "Your AI Developer is drunk. Here is the Supervisor."

| Tool | Model | Strength | Weakness |
|------|-------|----------|----------|
| [steipete/agent-scripts](https://github.com/steipete/agent-scripts) | Free/OSS | Skills library, pointer workflow | Personal setup, not productized |
| [rulesync](https://github.com/dyoshikawa/rulesync) | Free/OSS | Multi-tool sync (Cursor, Claude, Gemini) | No enforcement, just file sync |
| [Codacy Guardrails](https://www.codacy.com/guardrails) | SaaS | Security focus, IDE integration | Enterprise pricing, not Mac-native |
| Cursor .cursorrules | Built-in | Path-specific rules, rule types | Rules often ignored |

**Where we lead:**
- Circuit breaker (unique in Claude Code ecosystem)
- Research gate (4-category verification before edits)
- HMAC-signed state (tamper detection)
- 259 tests including 42 from real Claude failures

**Where we lag:**
- Path-specific rules (Cursor has, we use `.claude/rules/` convention)
- Cross-tool sync (rulesync exports to Cursor/Gemini format)
- Enterprise features (Codacy has IDE integration, dashboards)

### Skills Ecosystem

Inspired by steipete's agent-scripts library. Shipped:
- `swift-concurrency` — Actor isolation, Sendable, Swift 6.2 (176 lines)
- `swiftui-performance` — View anti-patterns, optimization (218 lines)
- `crash-analysis` — Reading crash reports, symbolication (212 lines)

Key insight: Skills are **loadable on demand**, not always-on context bloat.

### Mac Context (757 lines shipped)

Covers: build system rules, Info.plist templates, entitlements, security-scoped bookmarks, notarization workflow, crash analysis, WWDC 2025 APIs (Liquid Glass, Swift 6.2, Foundation Models, WebView, Chart3D, Spotlight App Intents), SwiftUI performance anti-patterns, menu bar patterns, Instruments profiling.

### Marketing Insights

**Killer differentiators:**
- "Constraint is the Feature" — competitors add flexibility, we add discipline
- "Zero Project Corruption" — unique value prop
- "No pip, no npm, no brew. Double click and build." — addresses real developer pain

**Refinements needed:**
- "Zero Hallucinations" → "Supervised Hallucinations" (it still hallucinates, we catch it)
- Add skills library to pitch: "Comes with 8 domain skills"
- Add memory persistence: "Learns from your crashes. Remembers your patterns."
- Add circuit breaker visual: "Stops after 3 failures. No more $20 token burns."

### Trademark Landscape (2026-01-19)

| Name | USPTO Status | Risk |
|------|-------------|------|
| SaneBar | No results | LOW |
| SaneClip | No results | LOW |
| SaneHosts | No results | LOW |
| SaneApps | Potential conflict (saneapps.com "App Hits") | MEDIUM |
| SANE | Open-source scanner project (different category) | LOW |

**Recommended actions:** Search USPTO TESS directly, clarify saneapps.com ownership history, file Intent-to-Use trademark ($250-350/class), consider LLC formation.

**Trademark classes:** Class 9 (computer software — primary for macOS apps), Class 42 (SaaS).

### Sources

- [steipete/agent-scripts](https://github.com/steipete/agent-scripts)
- [rulesync](https://github.com/dyoshikawa/rulesync)
- [Codacy Guardrails](https://www.codacy.com/guardrails)
- [Anthropic - Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [WWDC 2025 Recap](https://povio.com/blog/wwdc-2025-updates-for-apple-developers)
- [Swift 6.2 Approachable Concurrency](https://www.avanderlee.com/concurrency/approachable-concurrency-in-swift-6-2-a-clear-guide/)

---

## 5. Error Handling & Security

### Error Matrix

| Error | Source | Severity | Recovery |
|-------|--------|----------|----------|
| JSON parse failure (stdin) | Hook input | Low | Fail safe: exit 0 (allow tool) |
| State file corrupted/missing | state.json | Medium | Reset to defaults, log warning |
| HMAC signature mismatch | state.json | High | Reset state, log tamper attempt |
| File lock timeout | state.json.lock | Medium | Fail safe: exit 0 |
| Hook script syntax error | Any hook | High | Fail safe: `|| true` in settings.json |
| Circuit breaker false positive | sanetrack | Medium | Manual reset via `rb-` command |

### Security Model

**Threats addressed:**
- **State tampering:** HMAC signing on state.json detects manual edits
- **HMAC key protection:** Secret stored in macOS Keychain (not file-readable by agent tools)
- **Research gate bypass:** Only PostToolUse (sanetrack) can mark research categories complete
- **Path traversal:** Blocked system paths (`.ssh`, `.aws`, `/etc`)
- **Edit without research:** PreToolUse blocks mutations until gate satisfied
- **Inline script detection:** `python -c`, `ruby -e`, `node -e`, `perl -e` blocked as bash mutations
- **Doom loops:** Circuit breaker trips after 3 consecutive failures

**Known gaps:**
- MCP tools can bypass enforcement (no wildcard matcher support — see ADR-004)
- State file can be deleted (hook fails safe, re-creates with defaults)
- `|| true` in settings.json means broken hooks silently pass

### Exit Codes

| Code | Meaning | Effect |
|------|---------|--------|
| 0 | Allow | Tool proceeds |
| 1 | Warning (deprecated) | Tool proceeds |
| 2 | Block | Tool prevented |

---

## 6. Dependencies & External APIs

| Dependency | Version | Purpose | Risk |
|------------|---------|---------|------|
| Ruby | System (macOS) | Hook execution | None (ships with macOS) |
| Claude Code | Latest | Host platform | Breaking changes to hook API |
| JSON (stdlib) | Ruby stdlib | State parsing | None |
| OpenSSL (stdlib) | Ruby stdlib | HMAC signing | None |
| MCP servers | Various | Research tools | Network dependency |

### MCP Stack (per project)

| MCP Server | Purpose | Required? |
|------------|---------|-----------|
| apple-docs | Apple API verification | For Swift projects |
| github | External code search | For research gate |
| context7 | Library documentation | For research gate |
| XcodeBuildMCP | Build/test automation | For Xcode projects |
| macos-automator | Desktop UI automation | For menu bar apps |

---

## 7. Test Coverage Map

| Component | Self-Test | Tier Tests | Total |
|-----------|----------|------------|-------|
| saneprompt.rb | 176 | 62 | 238 |
| sanetools.rb | 25 | 66 | 91 |
| sanetrack.rb | 23 | 37 | 60 |
| sanestop.rb | 17 | 5 | 22 |
| Integration | — | 5 | 5 |
| **Total** | **241** | **175** | **416** |

### Running Tests

```bash
# Self-tests (per hook)
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
ruby scripts/hooks/core/config.rb --self-test

# Tier tests (all enforcement scenarios)
ruby scripts/hooks/test/tier_tests.rb
ruby scripts/hooks/test/tier_tests.rb --tier easy
ruby scripts/hooks/test/tier_tests.rb --tier hard
ruby scripts/hooks/test/tier_tests.rb --tier villain
```
