# SaneProcess Hooks

Production-ready hooks for Claude Code SOP enforcement.

## Quick Reference

| Hook | Type | Purpose | Blocks? |
|------|------|---------|---------|
| `session_start.rb` | SessionStart | Bootstraps session, resets circuit breaker | No |
| `circuit_breaker.rb` | PreToolUse | Stops after 3 consecutive failures | **Yes** |
| `edit_validator.rb` | PreToolUse | Blocks dangerous paths, enforces 800-line limit | **Yes** |
| `path_rules.rb` | PreToolUse | Shows context-specific rules for file types | No |
| `sop_mapper.rb` | PreToolUse | Enforces Rule #0 - map rules before coding | No |
| `two_fix_reminder.rb` | PreToolUse | Reminds about Rule #3 every 10 edits | No |
| `version_mismatch.rb` | PreToolUse | Prevents BUG-008 - build/launch path mismatch | No |
| `failure_tracker.rb` | PostToolUse | Tracks failures, trips circuit breaker | No |
| `test_quality_checker.rb` | PostToolUse | Warns on tautology tests like `#expect(true)` | No |
| `verify_reminder.rb` | PostToolUse | Reminds Rule #6 cycle after Swift edits | No |
| `audit_logger.rb` | PostToolUse | Logs all tool calls to `.claude/audit.jsonl` | No |

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
- `1` = Block the tool call

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

These are gitignored - they're session-specific.
