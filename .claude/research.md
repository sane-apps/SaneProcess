# Research Cache

> **Working scratchpad for research agents.** Check here before researching. Update after finding.
> When findings become permanent knowledge, graduate them to ARCHITECTURE.md or DEVELOPMENT.md.
> **Size cap: 200 lines.** If over cap, graduate oldest verified findings first.

---

## Hook Audit Findings
**Updated:** 2026-02-01 | **Status:** audit-complete | **TTL:** 7d
**Source:** Comprehensive audit of all hook files

| # | File | Line | Issue | Severity |
|---|------|------|-------|----------|
| 1 | saneprompt.rb | 152 | Hardcoded "Must complete: docs, web, github, local" - only lists 4 but says "All 4 research categories cleared" (correct) | LOW |
| 2 | saneprompt.rb | 500 | Comment says "Must complete all 5 research categories for THIS task" but should be 4 | MEDIUM |
| 3 | saneprompt.rb | 582 | Comment says "Research for Task A should NOT unlock edits for Task B" (correct logic) | LOW |
| 4 | saneprompt.rb | 682 | Auto-saneloop comment says "Research ALL 4 categories" - correct | LOW |
| 5 | sanetools.rb | 121-139 | RESEARCH_CATEGORIES hash defines 4 categories (docs, web, github, local) - correct, memory removed | LOW |
| 6 | sanetools.rb | 148 | Function `research_complete?` checks all categories - correct | LOW |
| 7 | sanetools.rb | 179 | Comment says "Reset edit attempt counter ONLY when...ALL 5 categories are now complete" - should be 4 | HIGH |
| 8 | sanetools.rb | 326-330 | Display message says "Missing (do these NOW)" and lists 4 categories - correct | LOW |
| 9 | sanetools_checks.rb | 310-332 | `check_research_before_edit` builds instructions for 4 categories, no memory reference - correct | LOW |
| 10 | sanetools_checks.rb | 627-632 | `check_rapid_research` checks "if timestamps.length < 5" - should be 4 | HIGH |
| 11 | sanetrack.rb | 36 | Comment "NOTE: Memory MCP removed Jan 2026" - correct awareness | LOW |
| 12 | sanetrack.rb | 44-51 | RESEARCH_PATTERNS has 4 categories (docs, web, github, local) - correct | LOW |
| 13 | sanestop.rb | 26 | Comment "DEPRECATED: Memory staging file no longer used (Jan 2026)" - correct awareness | LOW |
| 14 | sanestop.rb | 197 | Function `stage_memory_learnings` is now a no-op stub - correct | LOW |
| 15 | sanestop.rb | 582 | Display says "Research: #{stats[:research_done]}/5 categories" - should be /4 | HIGH |
| 16 | session_start.rb | 222-223 | SESSION_DOC_CANDIDATES array lists docs - correct | LOW |
| 17 | state_manager.rb | 60-65 | research schema defines 5 categories INCLUDING :memory - should remove :memory key | CRITICAL |
| 18 | state_manager.rb | 120-124 | mcp_health schema includes memory MCP - should be removed | MEDIUM |
| 19 | validation_report.rb | Line N/A | No stale "5 categories" references found - uses dynamic count from RESEARCH_CATEGORIES | LOW |
| 20 | sanetools.rb | state_manager | Unbounded data structure: action_log could grow without cap (schema defines [] but no MAX) | MEDIUM |
| 21 | state_manager.rb | 156 | action_log comment says "Last 20 actions" but MAX_ACTION_LOG in sanetrack.rb is 20 - consistent | LOW |
| 22 | state_manager.rb | 98 | patterns.session_scores keeps "Last 100" but sanestop.rb line 183 keeps last 10 - INCONSISTENT | MEDIUM |
| 23 | sanetrack.rb | 156 | MAX_ACTION_LOG = 20, correctly enforced in log_action_for_learning at line 509 | LOW |
| 24 | sanestop.rb | 70 | patterns[:session_scores].last(10) - enforces cap, matches comment | LOW |
| 25 | state_manager.rb | Dead key | research.memory still in schema but never used - should be removed | MEDIUM |
| 26 | state_manager.rb | Dead key | mcp_health.mcps.memory still in schema but MCP doesn't exist | MEDIUM |
| 27 | sanetools_checks.rb | 315 | Comment "NOTE: Memory category removed Jan 2026" - correct awareness | LOW |
| 28 | sanetrack_research.rb | 18 | RESEARCH_SIZE_CAP = 200 lines - enforced, correct | LOW |
| 29 | qa.rb | 53 | EXPECTED_RULE_COUNT = 16 - check if accurate | LOW |
| 30 | session_start.rb | 158 | MEMORY_STAGING_FILE referenced but deprecated - used only for cleanup check | LOW |

### Summary by Severity — ALL FIXED 2026-02-01

**CRITICAL (1): FIXED**
- ~~state_manager.rb schema still has :memory research category~~ → Removed :memory from research schema

**HIGH (3): ALL FIXED**
- ~~sanetools.rb line 179: "ALL 5 categories"~~ → Fixed to "ALL 4 categories"
- ~~sanetools_checks.rb line 627: timestamps.length < 5~~ → Fixed to < 4
- ~~sanestop.rb line 582: "/5 categories"~~ → Fixed to "/4 categories"

**MEDIUM (5): ALL FIXED**
- ~~saneprompt.rb line 500: "5 research categories"~~ → Fixed to "4 research categories"
- ~~state_manager.rb line 98: "Last 100 scores"~~ → Fixed to "Last 10"
- ~~state_manager.rb line 120: memory MCP in mcp_health~~ → Removed memory entry
- ~~state_manager.rb: research.memory dead key~~ → Removed
- ~~state_manager.rb: mcp_health.mcps.memory dead key~~ → Removed

**Additional fixes (same batch):**
- All markdown docs updated (CLAUDE.md, ARCHITECTURE.md, DEVELOPMENT.md, README.md, copilot-instructions.md)
- real_failures_test.rb and sanetools_test.rb updated
- session_started_at timestamp added (replaces Time.now - 3600 approximation)
- enforcement.blocks capped at 50 entries (trimmed at session start)
- Q3 SOP scoring redesigned: measures blocks-before-compliance instead of violations

**Remaining LOW items (cosmetic, not blocking):**
- MEMORY_STAGING_FILE in session_start.rb (cleanup check only — harmless)
- `stage_memory_learnings()` no-op stub in sanestop.rb (prevents NoMethodError)
- action_log unbounded in schema but MAX_ACTION_LOG = 20 enforced in sanetrack.rb

---

## MCP Tool Inventory & Utilization Audit
**Updated:** 2026-02-01 | **Status:** verified | **TTL:** 30d
**Source:** ToolSearch across all 8 MCP servers

### Gemini (30+ tools — mostly unused)
- `gemini-deep-research` — Multi-step web research, offloads from Claude context
- `gemini-brainstorm` — Cross-model ideation
- `gemini-analyze-code` — Second opinion on code quality/security
- `gemini-generate-image` — Marketing assets, app icons, landing page graphics
- `gemini-generate-video` — Product demo clips
- `gemini-analyze-image` — Screenshot analysis for customer support
- `gemini-analyze-url` / `gemini-compare-urls` — Competitor website analysis
- `gemini-youtube-summary` — Summarize WWDC/tech videos
- `gemini-speak` / `gemini-dialogue` — Voiceover for demos
- `gemini-count-tokens` — Estimate costs before expensive operations
- `gemini-run-code` — Sandboxed code execution
- `gemini-search` — Web search from Gemini's perspective
- `gemini-structured` / `gemini-extract` — Structured data extraction
- `gemini-summarize-pdf` / `gemini-extract-tables` — Document processing

### Serena LSP (available but rarely used)
- `find_symbol` — LSP symbol lookup (better than grep for code navigation)
- `find_referencing_symbols` — Find all callers of a function
- `rename_symbol` — Safe rename across entire codebase
- `replace_symbol_body` — Replace a method/class definition precisely
- `get_symbols_overview` — File structure without reading entire file
- `think_about_collected_information` — Built-in reflection checkpoint
- `think_about_task_adherence` — "Am I on track?" checkpoint
- `open_dashboard` — Web UI for project browsing
- Memories: write/read/edit/list — Per-project curated knowledge

### Apple-Docs WWDC (underused)
- `search_wwdc_content` — Full-text search across ALL WWDC transcripts
- `get_wwdc_code_examples` — Code snippets by framework/year
- `find_related_wwdc_videos` — Topic-based video discovery
- `get_documentation_updates` — What changed in latest SDK
- `find_similar_apis` — Alternative API discovery
- `get_platform_compatibility` — Cross-platform availability check

### macos-automator (493 scripts, rarely invoked)
- `get_scripting_tips` — Search 493 pre-built scripts across 13 categories
- `execute_script` — Run AppleScript/JXA with knowledge base IDs
- Categories: browsers, mail, calendar, Finder, Terminal, accessibility

## Claude-Mem vs Serena Memories
**Updated:** 2026-02-01 | **Status:** verified | **TTL:** 30d
**Source:** ToolSearch + direct MCP testing

| Aspect | Claude-Mem | Serena Memories |
|--------|-----------|-----------------|
| Storage | SQLite + ChromaDB (port 37777) | Markdown files in `.serena/memories/` |
| Capture | Auto via hooks | Manual write_memory |
| Search | Semantic vector search | File name / content grep |
| Scope | Cross-project (global DB) | Per-project (directory-scoped) |
| Format | Structured observations with timestamps | Free-form markdown |
| Best for | "What did we learn about X?" | "Project-specific curated knowledge" |

They're complementary, not duplicates. Claude-Mem is the automatic journal; Serena is the curated wiki.

## Subagent Capability Matrix
**Updated:** 2026-02-01 | **Status:** verified | **TTL:** 30d
**Source:** Task tool definition analysis

| Agent Type | Write/Edit | Ask User | MCP Tools | Sub-Tasks | Default Model |
|------------|-----------|----------|-----------|-----------|--------------|
| Explore | NO | NO | YES | NO | Haiku |
| general-purpose | YES | YES | YES | YES | Inherits (parent) |
| Plan | NO | YES | YES | NO | Inherits |
| Bash | NO | NO | NO | NO | Inherits |
| feature-dev:code-explorer | NO | NO | Limited | NO | Inherits |
| feature-dev:code-architect | NO | NO | Limited | NO | Inherits |
| feature-dev:code-reviewer | NO | NO | Limited | NO | Inherits |

**Key insight:** Explore agents are search drones. For research that persists, asks questions, or branches into sub-topics, use general-purpose + sonnet.
