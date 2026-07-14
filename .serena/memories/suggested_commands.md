# Suggested Commands for SaneProcess

> **Status: superseded command list refreshed on 2026-07-14.** Prefer
> `AGENTS.md`, `scripts/mini/README.md`, and current `SaneMaster.rb` help over
> remembered command snippets.

## Testing
```bash
# Run hook tier tests
ruby scripts/hooks/test/tier_tests.rb

# Run specific tier
ruby scripts/hooks/test/tier_tests.rb --tier easy
ruby scripts/hooks/test/tier_tests.rb --tier hard
ruby scripts/hooks/test/tier_tests.rb --tier villain

# Run real-world failure tests
ruby scripts/hooks/test/real_failures_test.rb

# Focused hook/client guard regressions
ruby scripts/hooks/grok_and_security_guard_test.rb
ruby scripts/hooks/session_docs_test.rb
ruby scripts/hooks/sanetools_test.rb
SANE_SKIP_MCP_WATCHDOG_CLEANUP=1 ruby scripts/hooks/sanestop.rb --self-test

# Full SaneProcess verification
ruby scripts/SaneMaster.rb verify --timeout 900
```

## Cross-Project Sync
```bash
# Check for hook drift between projects
ruby scripts/sync_check.rb ~/SaneBar
ruby scripts/sync_check.rb ~/SaneVideo
```

Local SaneAI/SaneSync and ML-training clones are retired from the Mini. Do not
recreate them for sync checks.

## Hook Testing (Manual)
```bash
# Test individual hooks with JSON input
echo '{"tool_name": "Edit", "tool_input": {"file_path": "/test"}}' | ruby scripts/hooks/sanetools.rb
echo '{"prompt": "fix the bug"}' | ruby scripts/hooks/saneprompt.rb
```

## State Management
```bash
# View current state
jq . .claude/state.json
```

Hook state is signed and managed through the existing state manager/session
hooks. Do not delete `.claude` state files by hand. Use the documented
SaneMaster or hook-specific reset command for the exact subsystem being reset.

## macOS Utilities
```bash
# Standard Darwin commands
ls -la
git status --short
git diff
git log --oneline -n 20
```
