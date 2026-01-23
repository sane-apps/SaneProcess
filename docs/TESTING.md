# SaneProcess Testing Checklist

## init.sh Fresh Install Test

Run on a fresh machine or directory without SaneProcess installed.

### Prerequisites
- [ ] macOS with Ruby installed
- [ ] `claude` CLI installed (`npm install -g @anthropic-ai/claude-code`)
- [ ] Valid license key in `~/.saneprocess/license.key`

### Test Steps

```bash
# 1. Create test directory
mkdir /tmp/saneprocess-test && cd /tmp/saneprocess-test

# 2. Run init.sh
curl -sL https://raw.githubusercontent.com/sane-apps/SaneProcess/main/scripts/init.sh | bash
```

### Verification Checklist

**Directories Created:**
- [ ] `.claude/` exists
- [ ] `.claude/rules/` exists
- [ ] `Scripts/hooks/` exists
- [ ] `Scripts/sanemaster/` exists

**Hooks Downloaded (16 files):**
```bash
ls Scripts/hooks/*.rb | wc -l  # Should be 16
```
- [ ] rule_tracker.rb (shared module)
- [ ] circuit_breaker.rb
- [ ] edit_validator.rb
- [ ] failure_tracker.rb
- [ ] test_quality_checker.rb
- [ ] path_rules.rb
- [ ] session_start.rb
- [ ] audit_logger.rb
- [ ] sop_mapper.rb
- [ ] two_fix_reminder.rb
- [ ] verify_reminder.rb
- [ ] version_mismatch.rb
- [ ] deeper_look_trigger.rb
- [ ] skill_validator.rb
- [ ] saneloop_enforcer.rb
- [ ] session_summary_validator.rb

**Configuration Files:**
- [ ] `.claude/settings.json` exists and is valid JSON
- [ ] `.mcp.json` exists and is valid JSON
- [ ] `DEVELOPMENT.md` exists (if not pre-existing)

**Syntax Validation:**
```bash
for f in Scripts/hooks/*.rb; do ruby -c "$f"; done  # All should say "Syntax OK"
```

**Hook Registration:**
```bash
grep -c "Scripts/hooks" .claude/settings.json  # Should be >= 13
```

**SaneMaster:**
```bash
./Scripts/SaneMaster.rb --help  # Should show usage
```

### Cleanup
```bash
rm -rf /tmp/saneprocess-test
```

## Regression Tests

Run the hook test suite:
```bash
ruby scripts/hooks/test/hook_test.rb
```

Expected: 28 tests, 0 failures

## qa.rb Full Check

```bash
./scripts/qa.rb
```

Expected: All checks passed
