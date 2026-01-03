# SaneProcess Hooks

Production-ready hooks for Claude Code SOP enforcement.

## Quick Reference

| Hook | Type | Purpose | Blocks? |
|------|------|---------|---------|
| `rule_tracker.rb` | Module | Shared tracking for rule enforcement analytics | N/A |
| `session_start.rb` | SessionStart | Bootstraps session, resets circuit breaker | No |
| `circuit_breaker.rb` | PreToolUse | Stops after 3 consecutive failures | **Yes** |
| `edit_validator.rb` | PreToolUse | Blocks dangerous paths, enforces 800-line limit | **Yes** |
| `path_rules.rb` | PreToolUse | Shows context-specific rules for file types | No |
| `sop_mapper.rb` | PreToolUse | Enforces Rule #0 - map rules before coding | No |
| `skill_validator.rb` | PreToolUse | Validates sane-loop has exit conditions | **Yes** |
| `two_fix_reminder.rb` | PostToolUse | Reminds about Rule #3 every 10 edits | No |
| `version_mismatch.rb` | PostToolUse | Prevents BUG-008 - build/launch path mismatch | No |
| `failure_tracker.rb` | PostToolUse | Tracks failures, trips circuit breaker | No |
| `test_quality_checker.rb` | PostToolUse | Warns on tautology tests like `#expect(true)` | No |
| `verify_reminder.rb` | PostToolUse | Reminds Rule #6 cycle after Swift edits | No |
| `audit_logger.rb` | PostToolUse | Logs all tool calls to `.claude/audit.jsonl` | No |
| `deeper_look_trigger.rb` | PostToolUse | Reminds to audit when issues discovered | No |
| `saneloop_enforcer.rb` | PreToolUse | Blocks if user requested saneloop but not started | **Yes** |
| `session_summary_validator.rb` | PostToolUse | Validates session summaries, rewards streaks, shames cheating | No |
| `prompt_analyzer.rb` | UserPromptSubmit | Detects trigger words, tracks patterns, learns from corrections | No |
| `pattern_learner.rb` | PostToolUse | Logs actions for pattern learning, correlates with corrections | No |
| `process_enforcer.rb` | PreToolUse | **BLOCKS** if bypassing required processes (research, plan, commit, verify, bash-file-bypass, subagent-bypass) | **Yes** |

## How They Work

All hooks read JSON from **stdin** (Claude Code standard):

```json
{
  "tool_name": "Edit",
  "tool_input": { "file_path": "/path/to/file.swift", ... },
  "tool_output": "...",
  "session_id": "abc123"
}
```

**Exit codes:**
- `0` = Allow the tool call
- `2` = **BLOCK** the tool call (Claude Code standard)
- `1` = Non-blocking error (shows warning but proceeds)

**Output:**
- `stdout` = JSON response (for hooks that return data)
- `stderr` = Messages shown to user (warnings, blocks)

## Running Tests

```bash
ruby scripts/hooks/test/hook_test.rb
```

All 28 tests should pass.

## Manual Testing

```bash
# Test circuit breaker allows when not tripped
echo '{"tool_name":"Edit"}' | ruby scripts/hooks/circuit_breaker.rb
echo "Exit: $?"

# Test edit validator blocks /etc
echo '{"tool_input":{"file_path":"/etc/passwd"}}' | ruby scripts/hooks/edit_validator.rb
echo "Exit: $?"

# Test path rules shows view rules
echo '{"tool_name":"Edit","tool_input":{"file_path":"/Project/Views/Test.swift"}}' | ruby scripts/hooks/path_rules.rb
```

## Configuration

Hooks are registered in `.claude/settings.json`:

```json
{
  "hooks": {
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

## Files Created

| File | Purpose |
|------|---------|
| `.claude/circuit_breaker.json` | Breaker state (failures, tripped) |
| `.claude/failure_state.json` | Failure tracking state |
| `.claude/audit.jsonl` | Audit log (JSON Lines) |
| `.claude/sop_state.json` | SOP rule mapping state |
| `.claude/edit_state.json` | Edit count per session |
| `.claude/edit_count.json` | Cumulative edit count |
| `.claude/build_state.json` | Build path tracking |
| `.claude/rule_tracking.jsonl` | Rule enforcement analytics |

These are gitignored - they're session-specific.

## Bypass Protection (v2)

The enforcement hooks have been hardened against common bypass attempts:

| Bypass Attempt | Protection | Hook |
|---------------|------------|------|
| Casual conversation resets requirements | Triggers now MERGE instead of overwrite (except fresh-start triggers like `saneloop`) | `prompt_analyzer.rb` |
| Bash `echo >> file` or `sed -i` | Detected and blocked when requirements unsatisfied | `process_enforcer.rb` |
| Spawn subagent to edit | Task prompts scanned for edit keywords | `process_enforcer.rb` |
| MCP GitHub file push | ⚠️ Not covered (needs Claude Code feature) | N/A |

### Fresh-Start vs Additive Triggers

**Fresh-start triggers** (reset requirements):
- `saneloop`, `test_mode`, `commit`

**Additive triggers** (merge with existing):
- `explain`, `show`, `remember`, `research`, `plan`, `verify`, `bug_note`
