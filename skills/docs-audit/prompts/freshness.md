# Freshness Audit

> You are auditing for **stale documentation that no longer matches reality**.
> This is the "does it actually work if I follow it?" check.

---

## The Problem You're Solving

Documentation rots faster than code:
- Code example uses API that was renamed
- Screenshot shows UI from 2 versions ago
- Version numbers are outdated
- Installation steps fail on current OS
- Dependencies changed but docs didn't

Users who follow stale docs get frustrated and lose trust.

---

## What To Check

### 1. Version Numbers

Find all version references and verify they're current:

```bash
# In docs
grep -rn -E "v?[0-9]+\.[0-9]+(\.[0-9]+)?" *.md

# Compare to actual
cat package.json | grep version
cat *.podspec | grep version
cat Info.plist | grep CFBundleShortVersionString
```

**Check:**
- README badge version matches actual release
- "Requires macOS X.X" is still accurate
- Dependency versions in examples match package.json/Podfile

### 2. Code Examples Actually Work

For EVERY code block in docs:

1. **Can it compile/run?**
   - Copy-paste the example
   - Does it work without modification?
   - Are imports included?

2. **Does it use current API?**
   - Check if method names still exist
   - Check if parameter order is correct
   - Check if return types match

3. **Are dependencies available?**
   - npm packages still exist and not deprecated
   - APIs not sunset

### 3. Screenshots Match Current UI

For EVERY screenshot:
- Does the UI still look like this?
- Are the menu items still there?
- Are the settings in the same place?
- Is the color scheme current?

**Signs of stale screenshots:**
- Old macOS window chrome
- Missing features that were added
- Features shown that were removed
- Different icon/branding

### 4. Links Still Work

Check ALL links:
```bash
# Find all links
grep -roh -E '\[.*?\]\(https?://[^)]+\)' *.md

# Test each one (or use a link checker)
```

**Types of link rot:**
- External docs moved (Apple, GitHub)
- Blog posts deleted
- Stack Overflow answers removed
- YouTube videos taken down

### 5. Installation Steps Work

Actually run the installation steps on a clean system (or document assumptions):

- [ ] Prerequisites still accurate?
- [ ] `brew install X` - does X still exist?
- [ ] `npm install` - no deprecated warnings?
- [ ] Clone URL correct?
- [ ] Build command succeeds?

### 6. Dates and Temporal References

Find and verify:
- "As of January 2024..." - is this still true?
- "Coming soon..." - did it ship?
- "New in v2.0..." - v3.0 is out now
- "Recently added..." - added 2 years ago

### 7. SDK/API Changes (Apple-Docs MCP)

Use Apple-Docs MCP tools to check for SDK changes that affect documentation:

```
# Check what changed in the latest SDK
get_documentation_updates(platform="macOS", framework="AppKit")

# Search WWDC for relevant sessions about APIs we use
search_wwdc_content(query="[relevant framework or API name]")

# Verify our documented API patterns are still current
get_platform_compatibility(symbol="[API name]")
```

**Check:**
- Are documented APIs deprecated in latest SDK?
- Did behavior change that our docs don't reflect?
- Are there new recommended patterns from WWDC sessions?

---

## Output Format

```markdown
## Freshness Audit Report

### 🔴 STALE (Definitely Wrong)
| Location | Issue | Current Reality |
|----------|-------|-----------------|
| README.md:15 | Shows v1.2.0 | Actually v2.4.0 |
| install.md:8 | `brew install foo` | Package renamed to `bar` |
| screenshot.png | Old settings UI | UI redesigned in v2.0 |

### 🟡 POSSIBLY STALE (Verify)
| Location | Issue | Action Needed |
|----------|-------|---------------|
| api.md:45 | Example uses `fetchData()` | Confirm method still exists |
| README.md:30 | Links to blog post | Test if URL still works |

### ✅ VERIFIED CURRENT
- [ ] Version numbers match releases
- [ ] Code examples compile
- [ ] Screenshots match current UI
- [ ] Links tested and working
- [ ] Installation steps verified
```

---

## Rules

1. **If you can't verify it, flag it** - "I think this is current" isn't good enough
2. **Screenshots age fastest** - Check these every release
3. **External links rot** - Check quarterly or link to archived versions
4. **Version numbers in 3+ places = drift** - Automate or reduce to 1

---

## Freshness Indicators

**Good signs:**
- "Last updated: [recent date]"
- Version badge that auto-updates
- Generated docs from code
- CI that tests doc examples

**Bad signs:**
- "TODO: update this"
- Dates more than 1 year old
- Manual version numbers everywhere
- No last-modified info

---

## Automation Opportunities

Flag if project should have:
- [ ] Version badge that pulls from release
- [ ] Doc testing in CI (doctest, mdx-test)
- [ ] Link checker in CI
- [ ] Screenshot automation (if UI changes often)

---

## MANDATORY: Persistent Record

**You MUST write findings to `DOCS_AUDIT_FINDINGS.md` in the project root.**

- Append your findings to the appropriate section as you discover them
- Use the Edit tool to update the file incrementally (don't wait until the end)
- On subsequent audits, mark resolved issues as `[RESOLVED YYYY-MM-DD]`
- Never delete old findings - maintain the audit trail
- This file is the permanent record that survives context loss
