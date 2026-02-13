# Contributing to TODO:AppName

Thank you for your interest in contributing! This document provides guidelines for contributing to TODO:AppName.

## Getting Started

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 16.0+
- Swift 6.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [SwiftLint](https://github.com/realm/SwiftLint): `brew install swiftlint`

### Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/TODO:AppName.git
   cd TODO:AppName
   ```
3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
4. Open in Xcode:
   ```bash
   open TODO:AppName.xcodeproj
   ```

## Development Workflow

### Branching

- `main` - Stable release branch
- `develop` - Development branch (if used)
- `feature/*` - New features
- `fix/*` - Bug fixes

### Making Changes

1. Create a branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes following the [Code Style](#code-style) guidelines

3. Test your changes:
   - Run unit tests (Cmd+U)
   - Manual testing for UI changes
   - Test on fresh macOS install if possible

4. Commit with clear messages:
   ```
   feat: Add new clipboard format support

   - Added RTF clipboard handling
   - Updated ClipboardManager to detect RTF
   - Added tests for RTF parsing
   ```

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftLint (runs automatically on build)
- Swift 6 strict concurrency required
- No force unwrapping (`!`) without justification
- Document public APIs with `///` comments

### Testing

Before submitting:

- [ ] All existing tests pass
- [ ] New tests added for new functionality
- [ ] Manual QA completed
- [ ] No SwiftLint warnings

## Pull Request Process

1. Update documentation if needed
2. Update CHANGELOG.md with your changes
3. Create PR with clear description:
   - What changes were made
   - Why the changes were needed
   - How to test

### PR Template

```markdown
## Summary
Brief description of changes

## Changes
- Change 1
- Change 2

## Testing
- [ ] Unit tests pass
- [ ] Manual testing completed
- [ ] Tested on macOS [version]

## Screenshots (if UI changes)
[Add screenshots]
```

## Reporting Issues

### Bug Reports

Please include:
- macOS version
- App version
- Steps to reproduce
- Expected vs actual behavior
- Screenshots/logs if applicable

### Feature Requests

Please include:
- Clear description of the feature
- Use case / why it's needed
- Any implementation ideas

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Please be respectful and constructive.

## Questions?

- Open a [Discussion](https://github.com/sane-apps/TODO:AppName/discussions)
- Check existing [Issues](https://github.com/sane-apps/TODO:AppName/issues)

Thank you for contributing!
