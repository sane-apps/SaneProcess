# SaneProcess - GitHub Copilot Instructions

## Project Overview

**SaneProcess** is a battle-tested SOP (Standard Operating Procedure) enforcement framework for AI-assisted development with Claude Code. It provides:

- **13 Golden Rules** for AI discipline and reliable code delivery
- **Circuit breaker** pattern to prevent repeated errors and wasted time
- **Memory system** for cross-session bug pattern persistence
- **Hook architecture** for automated compliance enforcement
- **SaneMaster CLI** for build, test, verify, and diagnostics

This repository contains the framework itself (documentation, hooks, scripts, and skills) that users install into their projects via the init script.

## Tech Stack

- **Primary Language**: Ruby 3.0+
- **Documentation**: Markdown
- **Build Automation**: Ruby scripts, Bash
- **Git Hooks**: Lefthook
- **Target Platform**: macOS development workflows (though framework is platform-agnostic)

## Code Structure

```
SaneProcess/
├── docs/                    # User-facing documentation
│   ├── SaneProcess.md       # Complete methodology (1,400+ lines)
│   └── PROJECT_TEMPLATE.md  # Template for users to customize
├── scripts/                 # Core tooling and automation
│   ├── SaneMaster.rb        # Main CLI tool
│   ├── sanemaster/          # 19 SaneMaster modules
│   ├── hooks/               # 4 consolidated enforcement hooks
│   │   ├── saneprompt.rb    # UserPromptSubmit hook
│   │   ├── sanetools.rb     # PreToolUse hook
│   │   ├── sanetrack.rb     # PostToolUse hook
│   │   └── sanestop.rb      # Stop hook
│   ├── init.sh              # Installation script
│   └── skill_loader.rb      # Skill management
├── skills/                  # Modular domain-specific knowledge
└── .claude/                 # Claude Code configuration
    ├── rules/               # Path-specific guidance
    └── settings.json        # Hook registration
```

## Coding Conventions

### Ruby Style

1. **Use RuboCop** - All Ruby code should follow RuboCop conventions
2. **Prefer explicit returns** - Make return values clear
3. **Use meaningful variable names** - Avoid single-letter variables except in common loops
4. **Add comments for complex logic** - Especially in hook scripts
5. **Write self-testing scripts** - Include `--self-test` functionality in major scripts

### Documentation Standards

1. **Keep docs beginner-friendly** - Users range from novice to expert
2. **Use tables for clarity** - Especially for command reference and feature comparisons
3. **Include examples** - Every feature should have working examples
4. **Maintain consistency** - Use the same terminology across all docs
5. **Update version numbers** - Increment version in all relevant files when making releases

### File Organization

1. **One responsibility per file** - Keep scripts focused and modular
2. **Group related files** - Use directories like `hooks/`, `sanemaster/`, `skills/`
3. **Use descriptive filenames** - `circuit_breaker.rb`, not `cb.rb`
4. **Maintain parallel structure** - If SaneBar has a feature, SaneProcess should document it

## Development Workflow

### Before Making Changes

1. **Read existing documentation** - Understand the context in `docs/SaneProcess.md`
2. **Check cross-project consistency** - This repo syncs with SaneBar and SaneVideo
3. **Run QA before pushing** - `ruby scripts/qa.rb` (enforced via lefthook)
4. **Test examples work** - Don't ship broken examples

### Testing

1. **All hooks have self-tests** - Run with `--self-test` flag
2. **Test tiers**: Easy (75), Hard (72), Villain (70), Real Failures (42)
3. **Add regression tests** - When fixing bugs, add tests to prevent recurrence
4. **Verify cross-platform** - Ensure scripts work on different macOS versions

### Key Commands

```bash
# Quality Assurance
ruby scripts/qa.rb                    # Full product QA (hooks, docs, URLs, tests)

# Cross-Project Sync
ruby scripts/sync_check.rb ~/SaneBar  # Detect drift between projects

# Memory Audit
ruby scripts/memory_audit.rb          # Find unfixed bugs in Memory MCP

# Version Management
ruby scripts/version_bump.rb 2.4      # Bump version across all files

# License Management
ruby scripts/license_gen.rb           # Generate customer license
ruby scripts/license_gen.rb --validate SP-XXXX-...  # Validate key
```

## Important Rules

### Never Do This

1. **Never modify .claude/state.json directly** - Always use state_manager.rb
2. **Never break the 13 Golden Rules** - They're the product's core value
3. **Never write files outside the project** - Respect #1: STAY IN YOUR LANE
4. **Never remove tests** - Only add or update them
5. **Never use raw build commands** - Always use project tools (./Scripts/SaneMaster.rb)
6. **Never commit state files** - They're in .gitignore for a reason

### Always Do This

1. **Always test hooks after changes** - Run `--self-test` on affected hooks
2. **Always update version numbers** - When making releases or significant changes
3. **Always maintain consistency** - Check SaneBar/SaneVideo for parallel implementations
4. **Always run QA before pushing** - `ruby scripts/qa.rb` catches most issues
5. **Always preserve user workflows** - Users depend on specific command patterns
6. **Always keep documentation synchronized** - Update README.md when changing features

## The "Sane" Naming Convention

All components use the **Sane** prefix for brand consistency:

- **SaneProcess** - The methodology + product
- **SaneMaster** - CLI tool for build, verify, launch, logs
- **SaneLoop** - Iteration loop with enforced exit conditions
- **SaneSkills** - Load/unload domain knowledge on demand
- **SaneRules** - Path-specific guidance
- **SaneBreaker** - Circuit breaker for repeated failures

When adding new components, follow this naming pattern.

## The 13 Golden Rules (Reference)

These are the product's core value proposition. Never modify their numbering or core meaning:

```
#0  NAME THE RULE BEFORE YOU CODE
#1  STAY IN YOUR LANE (files in project)
#2  VERIFY BEFORE YOU TRY (check docs first)
#3  TWO STRIKES? INVESTIGATE
#4  GREEN MEANS GO (tests must pass)
#5  THEIR HOUSE, THEIR RULES (use project tools)
#6  BUILD, KILL, LAUNCH, LOG
#7  NO TEST? NO REST
#8  BUG FOUND? WRITE IT DOWN
#9  NEW FILE? GEN THAT PILE
#10 FIVE HUNDRED'S FINE, EIGHT'S THE LINE
#11 TOOL BROKE? FIX THE YOKE
#12 TALK WHILE I WALK (stay responsive)
```

## Hook Architecture Principles

### Exit Codes

- **0** = Allow the operation
- **2** = BLOCK the operation

### State Management

- All state in `.claude/state.json` (signed with HMAC)
- Thread-safe via file locking (`.claude/state.json.lock`)
- Never manipulate state files directly - use `state_manager.rb`

### Research Gate

Before edits are allowed, must complete 5 research categories:

| Category | Satisfied by Tools |
|----------|-------------------|
| memory | `mcp__memory__*` |
| docs | `mcp__context7__*`, `mcp__apple-docs__*` |
| web | `WebSearch`, `WebFetch` |
| github | `mcp__github__*` |
| local | `Read`, `Grep`, `Glob` |

### Circuit Breaker

Trips when either:
- 3 consecutive failures, OR
- 3x same error signature (even with successes between)

Reset with `rb-` command or `./Scripts/SaneMaster.rb bootstrap`

## Security Considerations

1. **License validation** - All license keys use HMAC-SHA256 signatures
2. **State integrity** - State files are signed to prevent tampering
3. **No secrets in code** - Never commit API keys or credentials
4. **Safe defaults** - Hooks should fail-safe (allow on error, not block)

## User Experience Priorities

1. **Beginner-friendly** - Clear error messages and helpful guidance
2. **Minimal friction** - One-command setup via init.sh
3. **Self-documenting** - Commands should be memorable and intuitive
4. **Fail gracefully** - Provide recovery steps, not just error messages
5. **Preserve state** - Never lose user's work or context

## Cross-Project Consistency

SaneProcess is part of a family of products:

- **SaneProcess** - The framework (this repo)
- **SaneBar** - macOS menu bar app implementation
- **SaneVideo** - Video processing app implementation

When adding features or fixing bugs, check if the change should be propagated to sibling projects using `ruby scripts/sync_check.rb`.

## Performance Considerations

1. **Keep hooks fast** - They run on every tool use, so optimize for speed
2. **Lazy load skills** - Only load what's needed for the current task
3. **Cache expensive operations** - Don't re-read files unnecessarily
4. **Minimize state writes** - Batch updates when possible

## Common Pitfalls to Avoid

1. **Breaking backward compatibility** - Users depend on specific command patterns
2. **Inconsistent terminology** - Stick to established terms (circuit breaker, not error stopper)
3. **Over-engineering** - Keep solutions simple and maintainable
4. **Incomplete error handling** - Every hook should handle malformed inputs gracefully
5. **Forgetting to update docs** - Code changes must sync with documentation

## When in Doubt

1. Check `docs/SaneProcess.md` for methodology guidance
2. Check `.claude/SOP_CONTEXT.md` for project-specific context
3. Run `ruby scripts/qa.rb` to verify changes
4. Test with `--self-test` flags on affected scripts
5. Verify consistency with `ruby scripts/sync_check.rb ~/SaneBar`

## Contributing Guidelines

While this is a commercial product, contributions should:

1. **Maintain the existing architecture** - Don't introduce new paradigms without discussion
2. **Follow the 13 Golden Rules** - Practice what we preach
3. **Add tests for new features** - Maintain test coverage
4. **Update documentation** - Code without docs is incomplete
5. **Preserve user workflows** - Don't break existing commands or patterns

## Questions or Clarifications?

Refer to:
- `docs/SaneProcess.md` - Complete methodology and setup guide
- `docs/PROJECT_TEMPLATE.md` - Template showing expected usage patterns
- `scripts/hooks/README.md` - Hook architecture and testing
- `.claude/SOP_CONTEXT.md` - Project purpose and key files
