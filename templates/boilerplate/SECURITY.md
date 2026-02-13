# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in TODO:AppName, please report it responsibly:

1. **Email**: security@TODO:appname.com
2. **GitHub**: [Private Security Advisory](https://github.com/sane-apps/TODO:AppName/security/advisories/new)

**Please do not** open public issues for security vulnerabilities.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Release**: Depends on severity (critical: ASAP, high: 1-2 weeks)

## Security Model

### Code Signing

TODO:AppName is:
- Signed with Apple Developer ID
- Notarized by Apple
- Includes hardened runtime

Verify the signature:
```bash
codesign -dv --verbose=4 /Applications/TODO:AppName.app
spctl --assess --verbose /Applications/TODO:AppName.app
```

### Sandboxing

TODO:AppName TODO:is/is not sandboxed because TODO:reason.

Requested entitlements:
```
TODO:List entitlements
```

### Data Protection

- All data stored locally in `~/Library/Application Support/TODO:AppName/`
- TODO:Encryption details if applicable
- No cloud sync (data never leaves your Mac)

## Security Features

| Feature | Description |
|---------|-------------|
| TODO:Feature | TODO:Description |

## Known Limitations

| Limitation | Mitigation |
|------------|------------|
| TODO:Limitation | TODO:Mitigation |

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x     | Yes       |
| < 1.0   | No        |

We recommend always running the latest version.

## Security Best Practices

For users:
1. Download only from official sources (GitHub, Homebrew, TODO:appname.com)
2. Verify code signature before running
3. Keep macOS and TODO:AppName updated
4. Review requested permissions

## Audit History

| Date | Auditor | Scope | Result |
|------|---------|-------|--------|
| TODO:Date | TODO:Auditor | TODO:Scope | TODO:Result |

---

*This security policy follows industry best practices and is reviewed regularly.*
