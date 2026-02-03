# SaneProcess

**Stop Claude Code from wasting your time and crashing your machine.**

SaneProcess is a hook-based enforcement framework for Claude Code. It kills orphaned processes, stops doom loops, and forces research before edits.

412 tests. MIT licensed. Ruby. macOS + Linux.

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

SaneProcess blocks all edits until research is done across four categories:

```
🔴 BLOCKED: Research incomplete
   ✅ docs   ✅ web   ❌ github   ❌ local
   Complete all 4 categories before editing.
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
ruby scripts/hooks/saneprompt.rb --self-test    # 176 tests
ruby scripts/hooks/sanetools.rb --self-test     # 38 tests
ruby scripts/hooks/sanetrack.rb --self-test     # 23 tests
```

---

## How It Works

Five hooks map to Claude Code's lifecycle events:

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
2. **MCP daemons** — finds known MCP patterns (context7, apple-docs, xcodebuild, github, serena, etc.) not in your session tree
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
| **docs** | apple-docs MCP, context7 MCP | Only if MCP installed |
| **web** | WebSearch, WebFetch | Always |
| **github** | GitHub MCP | Only if MCP installed |
| **local** | Read, Grep, Glob | Always |

The gate adapts to your setup. With no MCPs, only `web` + `local` are required. With apple-docs and GitHub MCPs installed, all 4 categories enforce. The installer shows which MCPs you have and gives install commands for the rest.

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

412 tests across two frameworks:

**Tier tests (175)** — end-to-end enforcement scenarios:

| Tier | Count | What |
|------|-------|------|
| Easy | 61 | Basic functionality |
| Hard | 55 | Edge cases, state transitions |
| Villain | 59 | Adversarial bypass attempts |

**Self-tests (237)** — per-hook unit tests:

| Hook | Tests |
|------|-------|
| saneprompt | 176 |
| sanetools | 38 |
| sanetrack | 23 |

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

### Hooks not firing

Check that `.claude/settings.json` contains hook entries pointing to your `scripts/hooks/` directory. Re-run `init.sh` if needed.

---

## Requirements

- **macOS or Linux** (process cleanup uses POSIX `ps`; HMAC key uses Keychain on macOS, file-based on Linux)
- **Ruby** (ships with macOS; `apt install ruby` or `dnf install ruby` on Linux)
- **Claude Code** (`npm install -g @anthropic-ai/claude-code`)

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
│       └── tier_tests.rb     # 175 enforcement tests
├── init.sh                   # Project installer
└── qa.rb                     # QA runner
.claude/
├── rules/                    # Path-specific guidance (installed by init.sh)
│   ├── hooks.md              # Hook conventions
│   └── scripts.md            # Ruby script conventions
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
