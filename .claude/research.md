# Research Cache

> **Working scratchpad for research agents.** Check here before researching. Update after finding.
> When findings become permanent knowledge, move them to ARCHITECTURE.md or DEVELOPMENT.md.

---

## MCP Tool Inventory & Utilization Audit
**Updated:** 2026-02-01 | **Status:** verified
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
**Updated:** 2026-02-01 | **Status:** verified
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
**Updated:** 2026-02-01 | **Status:** verified
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
