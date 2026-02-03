# Ops Audit

> You are auditing for **operational hygiene that humans forget to check**.
> These are things trivial for AI to check but nightmares for humans to track.

---

## The Problem You're Solving

Developers focus on features. Meanwhile:
- Certificates expire silently
- Dependencies get outdated and vulnerable
- Git branches pile up
- Domains lapse
- TODO comments rot in code for years

These don't cause immediate pain, so they're ignored until crisis.

---

## What To Check

### 1. Git Hygiene

```bash
# Stale branches (not merged, older than 30 days)
git branch -a --no-merged | head -20

# Uncommitted changes
git status --short

# Recent branches that might be abandoned
git for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:relative)' refs/heads/ | head -10
```

**Flag:**
- Branches older than 30 days not merged
- More than 5 local branches
- Uncommitted changes in working directory
- Detached HEAD state

### 2. Certificate & Signing (macOS/iOS)

```bash
# Check Developer ID certificate expiry
security find-identity -v -p codesigning | head -5

# Check provisioning profiles
ls ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision 2>/dev/null | wc -l
```

**Flag:**
- Certificates expiring within 90 days
- Missing signing identity
- Expired provisioning profiles

### 3. Dependencies

```bash
# Node.js
npm outdated 2>/dev/null | head -10
npm audit --json 2>/dev/null | head -20

# Ruby
bundle outdated 2>/dev/null | head -10

# CocoaPods
pod outdated 2>/dev/null | head -10

# Swift Package Manager
swift package show-dependencies 2>/dev/null
```

**Flag:**
- Major version updates available
- Security vulnerabilities (any severity)
- Deprecated packages
- Outdated by more than 2 major versions

### 4. Domain & SSL Health

```bash
# Check SSL cert expiry (if domain known)
echo | openssl s_client -servername example.com -connect example.com:443 2>/dev/null | openssl x509 -noout -dates

# WHOIS expiry (if whois available)
whois example.com | grep -i expir
```

**Flag:**
- SSL expiring within 30 days
- Domain expiring within 60 days
- DNS not resolving

### 5. Code Hygiene

```bash
# TODOs and FIXMEs in code (not docs)
grep -rn "TODO\|FIXME\|XXX\|HACK" --include="*.swift" --include="*.ts" --include="*.rb" . | wc -l

# Console.logs / print statements
grep -rn "console\.log\|print(" --include="*.swift" --include="*.ts" . | head -10

# Commented-out code blocks (3+ consecutive comment lines)
# (heuristic - look for patterns)
```

**Flag:**
- More than 10 TODO/FIXME comments
- print/console.log in production code
- Large commented-out code blocks

### 6. Cross-Project Consistency

If this is part of a multi-project workspace:

```bash
# Check for same dependency different versions
# Compare package.json, Podfile, Package.swift across projects
```

**Flag:**
- Same dependency, different versions across projects
- Naming inconsistencies (MyApp vs My-App vs my_app)
- Different coding conventions

### 7. Legal Compliance

```bash
# Copyright year in LICENSE
grep -i "copyright" LICENSE* 2>/dev/null

# Third-party licenses
ls *LICENSE* NOTICE* ATTRIBUTION* 2>/dev/null
```

**Flag:**
- Copyright year outdated (not current year)
- Missing LICENSE file
- Third-party deps without attribution (if required)

### 8. Release Readiness

```bash
# Version consistency
grep -r "version" package.json Info.plist *.podspec 2>/dev/null | head -10

# CHANGELOG has current version
head -20 CHANGELOG.md 2>/dev/null
```

**Flag:**
- Version mismatch across files
- CHANGELOG doesn't mention current version
- No release notes for latest tag

### 9. Memory MCP Hygiene

```
search(query: "ProjectName bug", type: "bug")
```

**Flag:**
- Bugs marked but never resolved
- Duplicate observations
- Patterns documented but never applied

---

## Output Format

```markdown
## Ops Audit Report

### 🔴 URGENT (Fix This Week)
| Issue | Details | Impact |
|-------|---------|--------|
| Certificate expires in 15 days | Developer ID Application | Can't ship updates |
| 3 high-severity npm vulnerabilities | lodash, axios | Security risk |

### 🟡 MAINTENANCE (Fix This Month)
| Issue | Details | Effort |
|-------|---------|--------|
| 7 stale git branches | oldest: feature/old-thing (3 months) | 10 min cleanup |
| 23 TODO comments in code | spread across 8 files | 1 hour review |
| Copyright says 2024 | LICENSE file | 1 min fix |

### 🟢 HEALTHY
- [ ] No uncommitted changes
- [ ] Dependencies up to date
- [ ] SSL certs valid 90+ days
- [ ] Domains valid 60+ days

### ⏰ CALENDAR ITEMS (Set Reminders)
| What | When | Action |
|------|------|--------|
| Dev certificate renewal | [DATE] | Renew in Keychain |
| Domain renewal | [DATE] | Pay registrar |
| Apple Developer renewal | [DATE] | $99 payment |
```

---

## Rules

1. **Expiring things are URGENT** - Certificates, domains, SSL = highest priority
2. **Security vulns are URGENT** - Even "moderate" ones
3. **Git clutter is MAINTENANCE** - Won't break anything but slows you down
4. **TODOs are MAINTENANCE** - Tech debt, not crisis
5. **Legal stuff is MAINTENANCE** - Until you get a cease & desist

---

## What AI Can Do vs What Human Must Do

| Check | AI Can | Human Must |
|-------|--------|------------|
| Find expiring certs | ✅ Run security commands | Renew in portal |
| Find stale branches | ✅ List them | Decide keep/delete |
| Find vulnerabilities | ✅ Run npm audit | Decide upgrade strategy |
| Find outdated deps | ✅ Run outdated commands | Decide when to upgrade |
| Check domain expiry | ✅ WHOIS lookup | Pay renewal |
| Find TODOs in code | ✅ Grep | Decide fix/remove/keep |

**Surface everything. Let human prioritize.**

---

## MANDATORY: Persistent Record

**You MUST write findings to `DOCS_AUDIT_FINDINGS.md` in the project root.**

- Append your findings to the appropriate section as you discover them
- Use the Edit tool to update the file incrementally (don't wait until the end)
- On subsequent audits, mark resolved issues as `[RESOLVED YYYY-MM-DD]`
- Never delete old findings - maintain the audit trail
- This file is the permanent record that survives context loss
