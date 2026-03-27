<p align="center">
  <img src="assets/hero-shield.jpeg" alt="SaneProcess" width="100%">
</p>

# SaneProcess

**Stop Claude Code from wasting your time and crashing your machine.**

SaneProcess is a hook-based enforcement framework for Claude Code. It kills orphaned processes, stops doom loops, and forces research before edits.

452 tests. MIT licensed. Ruby. macOS + Linux.

---

## Documentation Layout

SaneProcess is the source of truth for the anti-fragmentation rule used across SaneApps.

- Update an existing canonical doc before creating a new one.
- The normal app-repo skeleton is `README.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, `PRIVACY.md`, and `SECURITY.md`.
- If a repo needs extra docs, the owning canonical doc and the README must point to them clearly.
- Public site pages should live in one obvious folder and the README should say where that folder is.

See [DEVELOPMENT.md](DEVELOPMENT.md) for the operating procedure behind this rule.

---

## The Problems

### 1. Orphaned processes eating your RAM

Claude Code spawns subagents and MCP server processes that outlive their parent sessions. They accumulate silently until your machine crawls or crashes.

SaneProcess kills them automatically on every session start — without touching your active sessions.

```
🧹 Cleaned up 3 orphaned Claude sessions
🧹 Cleaned up 7 orphaned MCP daemons
🧹 Cleaned up 2 orphaned subagents
```

It uses process tree traversal (BFS) to identify which processes belong to your current session and leaves them alone. Only orphans whose parent sessions have died get cleaned up.

### 2. Doom loops burning tokens

Claude guesses the same broken fix over and over. You watch it burn through tokens on the same error 10 times.

SaneProcess trips a circuit breaker after 3 consecutive failures or 3 identical error signatures. All edit operations are blocked until you acknowledge the problem.

```
🔴 CIRCUIT BREAKER TRIPPED
   3 consecutive failures with same error signature
   Say "reset breaker" after fixing the root cause.
```

The breaker persists across session restarts — Claude can't bypass it by restarting.

### 3. Edits without research

Claude assumes APIs exist without checking. It writes code using methods that don't exist, then fails, then tries a different nonexistent method.

SaneProcess blocks all edits until research is done across the required categories:

```
🔴 BLOCKED: Research incomplete
   ✅ docs   ✅ web   ❌ github   ❌ local
   Complete all required categories before editing.
```

Read-only tools (Read, Grep, Glob, search) are never blocked. The gate only applies to mutations.

---

## Install

```bash
# Clone the repo
git clone https://github.com/sane-apps/SaneProcess.git

# Run the installer from your project directory
cd /path/to/your-project
/path/to/SaneProcess/scripts/init.sh
```

The installer copies hooks into your project's `scripts/hooks/` directory and creates `.claude/settings.json` with hook registration.

**Or configure manually** — add to `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project):

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "ruby /path/to/hooks/session_start.rb", "timeout": 15000 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "ruby /path/to/hooks/saneprompt.rb" }] }],
    "PreToolUse": [{ "hooks": [{ "type": "command", "command": "ruby /path/to/hooks/sanetools.rb" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "ruby /path/to/hooks/sanetrack.rb" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "ruby /path/to/hooks/sanestop.rb" }] }]
  }
}
```

**Verify:**

```bash
ruby scripts/hooks/saneprompt.rb --self-test
ruby scripts/hooks/sanetools.rb --self-test
ruby scripts/hooks/sanetrack.rb --self-test
ruby scripts/hooks/sanestop.rb --self-test
```

---

## How It Works

4 enforcement hooks plus 1 session-start bootstrap hook map to Claude Code's lifecycle events:

| Hook | Event | Purpose |
|------|-------|---------|
| `session_start.rb` | SessionStart | Kills orphans, resets state, bootstraps session |
| `saneprompt.rb` | UserPromptSubmit | Classifies intent, sets research requirements |
| `sanetools.rb` | PreToolUse | Blocks edits until research is done |
| `sanetrack.rb` | PostToolUse | Tracks failures, trips circuit breaker |
| `sanestop.rb` | Stop | Captures session summary |

All state lives in a single HMAC-signed JSON file (`.claude/state.json`). File-locked for concurrent access. Tamper-detected via HMAC key (macOS Keychain or `~/.claude_hook_secret` on Linux). Atomic writes via tempfile + rename.

### Orphan Cleanup

On every session start, three cleanup passes run:

1. **Parent sessions** — finds `claude` processes not in your current process tree
2. **MCP daemons** — finds known MCP patterns (context7, apple-docs, xcodebuild, github, serena, central-memory, etc.) not in your session tree
3. **Subagents** — finds `claude --resume` processes whose parent sessions are dead

Uses BFS process tree traversal. Your active session and any other active terminal sessions are never touched.

### Circuit Breaker

After tool execution, error signatures are normalized and tracked:

- **3 consecutive failures** → breaker trips
- **3 identical error signatures** → breaker trips

When tripped, all edit/write operations are blocked. Say `reset breaker` or `rb-` to clear after fixing the root cause.

### Research Gate

Before any mutation (Edit, Write, Bash with side effects), research categories must be satisfied:

| Category | Satisfied By | Required? |
|----------|-------------|-----------|
| **docs** | apple-docs MCP, context7 MCP | Only if MCP configured |
| **web** | WebSearch, WebFetch | Always |
| **github** | GitHub MCP | Only if MCP configured |
| **local** | Read, Grep, Glob | Always |

The gate adapts to your setup. With no configured MCPs, only `web` + `local` are required. Configure apple-docs/context7 and GitHub in `.mcp.json` to make `docs` and `github` required too. The installer shows recommended MCPs and install commands.

### Tool Discovery Receipt

Before saying a tool is missing, using a workaround, or adding new tooling, generate the receipt:

```bash
ruby scripts/SaneMaster.rb tool_discovery --query "missing screenshot diff tool"
```

That receipt checks the skills registry, runs `doctor`, runs `validation_report.rb`, searches local scripts/docs, and writes proof artifacts to `outputs/tool-discovery/`.

### Tool Categorization (Blast Radius)

| Category | Examples | Blocked Until |
|----------|----------|---------------|
| Read-only | Read, Grep, Glob, search | Never |
| Local mutation | Edit, Write | Research complete |
| Sensitive files | CI/CD, entitlements, Dockerfiles | Confirmed per-file per-session |
| External mutation | GitHub push | Research complete |

---

## Security

- **HMAC-signed state** — `state.json` is signed to detect tampering. Key stored in macOS Keychain (macOS) or `~/.claude_hook_secret` with 600 permissions (Linux).
- **Blocked system paths** — Prevents edits to `/etc/`, `.ssh/`, `.aws/`, `.gnupg/`
- **Inline script detection** — `python -c`, `ruby -e`, `node -e` blocked as bash mutations
- **Sensitive file confirmation** — First edit to CI/CD configs, entitlements, Dockerfiles requires confirmation
- **Fail-safe defaults** — If a hook errors internally, it allows the operation (exit 0). Never blocks randomly.

---

## Tests

452 tests across two frameworks:

**Tier tests (178)** — end-to-end enforcement scenarios:

| Tier | Count | What |
|------|-------|------|
| Easy | 61 | Basic functionality |
| Hard | 58 | Edge cases, state transitions |
| Villain | 59 | Adversarial bypass attempts |

**Self-tests (274)** — per-hook unit tests:

| Hook | Tests |
|------|-------|
| saneprompt | 176 |
| sanetools | 44 |
| sanetrack | 30 |
| sanestop | 24 |

```bash
# Run all tier tests
ruby scripts/hooks/test/tier_tests.rb

# Run per-hook self-tests
ruby scripts/hooks/saneprompt.rb --self-test

# Run a specific tier
ruby scripts/hooks/test/tier_tests.rb --tier villain
```

---

## Configuration

Configurable via `scripts/hooks/core/config.rb`:

| Setting | Default | What |
|---------|---------|------|
| Circuit breaker threshold | 3 | Consecutive failures before trip |
| File size warning | 500 lines | Yellow warning on edit |
| File size limit | 800 lines | Block the edit |
| Blocked paths | `/etc/`, `.ssh/`, `.aws/` | System path protection |

---

## Troubleshooting

### "BLOCKED: Research incomplete"

The hook is working correctly. Complete the required research categories before editing. The gate adapts — categories whose MCPs you don't have auto-skip. With no MCPs, only `web` + `local` are required.

### Circuit breaker tripped

Say `reset breaker` or `rb-` in Claude after fixing the root cause.

### central-memory MCP not working

SaneProcess includes a semantic memory MCP server backed by PostgreSQL + `pgvector`.

```bash
# Provision local database + extension + schema
cd ~/SaneApps/infra/SaneProcess/scripts/mcp-central-memory
./bootstrap-local.sh

# Verify MCP health
~/.codex/bin/check-mcps
codex mcp list | rg central-memory
```

Expected: `check-mcps` shows `[PASS] central-memory`.

If it fails:

- Ensure `OPENAI_API_KEY` is available to the Codex app process.
- Ensure PostgreSQL is running: `brew services list | rg postgresql@17`.

### memory MCP search feels weak

Codex uses a separate graph-style memory MCP for entity/relation recall.

- Config key: `memory` in `/Users/sj/.codex/config.toml`
- Server: `~/SaneApps/infra/SaneProcess/scripts/mcp-memory-enhanced/server.mjs`
- Store: `~/.claude/memory/knowledge-graph.jsonl`

Use `memory` when you need exact graph cross-reference like:

- issue ↔ email thread ↔ root cause bucket
- canonical entity names
- linked neighbors from a matched node

Use `central-memory` when you need semantic recall across free-form notes.

### Hooks not firing

Check that `.claude/settings.json` contains hook entries pointing to your `scripts/hooks/` directory. Re-run `init.sh` if needed.

---

## Requirements

- **macOS or Linux** (process cleanup uses POSIX `ps`; HMAC key uses Keychain on macOS, file-based on Linux)
- **Ruby 3.x** (`brew install ruby` on macOS; `apt install ruby` or `dnf install ruby` on Linux)
- **Claude Code** (`npm install -g @anthropic-ai/claude-code`)

---

## Included Skills

SaneProcess ships two multi-agent audit skills that Claude reads and executes automatically.

### Critic (`/critic`)

6-persona adversarial code review. Spawns parallel subagents that each review from a different angle:

| Agent | Focus |
|-------|-------|
| Bug Hunter | Logic errors, null safety, crashes |
| Data Flow Tracer | Feature completeness across code paths |
| Integration Auditor | Cross-system config consistency |
| Edge Case Explorer | Unusual states, environments |
| UX Critic | UI/UX quality, clarity, accessibility |
| Security Auditor | Attack vectors, data exposure |

Findings are deduplicated and ranked by severity. Issues caught by multiple agents get higher confidence scores.

### Docs Audit (`/docs-audit`)

11-perspective documentation audit. Each perspective runs as its own subagent:

| # | Perspective | Focus |
|---|-------------|-------|
| 1 | Engineer | Technical accuracy, API docs |
| 2 | Designer | Screenshots, visual storytelling |
| 3 | Marketer | Value proposition, "why should I care?" |
| 4 | User Advocate | Onboarding clarity |
| 5 | QA | Edge cases, gotchas, troubleshooting |
| 6 | Hygiene | Duplication, terminology drift |
| 7 | Security | Leaked secrets, PII, internal URLs |
| 8 | Freshness | Stale examples, broken links |
| 9 | Completeness | TODO placeholders, unchecked items |
| 10 | Ops | Git hygiene, dependencies, certificates |
| 11 | Consistency | Broken references in CLAUDE.md vs actual code |

Produces a consolidated gap report with scores, critical issues, and recommended fixes — sorted by what Claude can fix vs what needs human action.

Skills are installed to `.claude/skills/` during `init.sh` setup.

---

## Project Structure

```
scripts/
├── hooks/                    # All enforcement hooks
│   ├── session_start.rb      # SessionStart — orphan cleanup, state reset
│   ├── saneprompt.rb         # UserPromptSubmit — classify, set requirements
│   ├── sanetools.rb          # PreToolUse — block until research done
│   ├── sanetrack.rb          # PostToolUse — track failures, circuit breaker
│   ├── sanestop.rb           # Stop — session summary
│   ├── core/                 # Shared infrastructure
│   │   ├── config.rb         # Paths, thresholds, settings
│   │   ├── state_manager.rb  # Signed state file management
│   │   └── context_compact.rb
│   └── test/                 # Test suites
│       └── tier_tests.rb     # 178 enforcement tests
├── init.sh                   # Project installer
└── qa.rb                     # QA runner
skills/
├── critic/                   # 6-persona adversarial code review
│   ├── SKILL.md
│   └── prompts/              # 6 agent prompts
└── docs-audit/               # 11-perspective documentation audit
    ├── SKILL.md
    └── prompts/              # 11 agent prompts
.claude/
├── rules/                    # Path-specific guidance (installed by init.sh)
│   ├── hooks.md              # Hook conventions
│   └── scripts.md            # Ruby script conventions
├── skills/                   # Installed by init.sh from skills/
└── settings.json             # Hook registration
```

---

## Uninstall

Remove hook entries from `.claude/settings.json`. Delete `scripts/hooks/`. Delete `.claude/state.json`.

No global state modified. No daemons installed. No system changes.

---

## License

MIT License. See [LICENSE](LICENSE).

---

*Built by [SaneApps](https://saneapps.com). Used in production across 7 projects.*

<!-- SANEAPPS_AI_CONTRIB_START -->
### Become a Contributor (Even if You Don't Code)

Are you tired of waiting on the dev to get around to fixing your problem?  
Do you have a great idea that could help everyone in the community, but think you can't do anything about it because you're not a coder?

Good news: you actually can.

Copy and paste this into Claude or Codex, then describe your bug or idea:

```text
I want to contribute to this repo, but I'm not a coder.

Repository:
https://github.com/sane-apps/SaneProcess

Bug or idea:
[Describe your bug or idea here in plain English]

Please do this for me:
1) Understand and reproduce the issue (or understand the feature request).
2) Make the smallest safe fix.
3) Open a pull request to https://github.com/sane-apps/SaneProcess
4) Give me the pull request link.
5) Open a GitHub issue in https://github.com/sane-apps/SaneProcess/issues that includes:
   - the pull request link
   - a short summary of what changed and why
6) Also give me the exact issue link.

Important:
- Keep it focused on this one issue/idea.
- Do not make unrelated changes.
```

If needed, you can also just email the pull request link to hi@saneapps.com.

I review and test every pull request before merge.

If your PR is merged, I will publicly give you credit, and you'll have the satisfaction of knowing you helped ship a fix for everyone.
<!-- SANEAPPS_AI_CONTRIB_END -->
