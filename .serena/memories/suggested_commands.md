# Suggested Commands for SaneProcess

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
ruby scripts/sync_check.rb ~/SaneSync
```

## Hook Testing (Manual)
```bash
# Test individual hooks with JSON input
echo '{"tool_name": "Edit", "tool_input": {"file_path": "/test"}}' | ruby scripts/hooks/sanetools.rb
echo '{"prompt": "fix the bug"}' | ruby scripts/hooks/saneprompt.rb
```

## State Management
```bash
# View current state
cat .claude/state/enforcement_state.json | jq .

# Reset state (for testing)
rm .claude/state/*.json
```

## macOS Utilities
```bash
# Standard Darwin commands
ls -la, cd, pwd, grep, find, cat, head, tail
git status, git diff, git log
```
