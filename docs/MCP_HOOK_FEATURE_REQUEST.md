# Feature Request: Wildcard/Pattern Matching for Hook Matchers

## Summary
Add support for wildcard or pattern matching in Claude Code hook matchers to enable hooks on MCP tools and other dynamically-named tools.

## Problem
Currently, hook matchers require exact tool names:
```json
{ "matcher": "Edit", "hooks": [...] }
{ "matcher": "Bash", "hooks": [...] }
```

This means MCP tools (e.g., `mcp__github__push_files`, `mcp__memory__create_entities`) cannot be hooked without:
1. Listing every single MCP tool explicitly (brittle, incomplete)
2. Updating settings.json every time a new MCP tool is added

## Proposed Solution
Add wildcard or regex pattern matching support:

```json
// Option 1: Glob-style wildcards
{ "matcher": "mcp__*", "hooks": [...] }
{ "matcher": "mcp__github__*", "hooks": [...] }

// Option 2: Catch-all
{ "matcher": "*", "hooks": [...] }

// Option 3: Regex
{ "matcher": "/^mcp__/", "hooks": [...] }
```

## Use Case
We have enforcement hooks that validate tool usage (e.g., blocking dangerous operations, enforcing workflows). These work for built-in tools but MCP tools bypass all enforcement because we can't match them.

**Specific bypass vulnerability:**
- User can push code directly to GitHub via `mcp__github__push_files`
- No PreToolUse hook can intercept this
- All our safety checks are bypassed

## Workaround Attempted
We added explicit matchers for known MCP tools, but:
- Any new MCP tool bypasses hooks until manually added
- MCP servers can add tools at runtime
- Maintenance burden is unsustainable

## Impact
Without this feature, any enforcement/safety layer built with hooks has a fundamental bypass via MCP tools.

## Suggested Implementation
1. Check if matcher contains `*` → treat as glob pattern
2. Or add `matcherType: "glob" | "regex" | "exact"` option

---

## How to Submit This Request

Copy the above content and create an issue at:
**https://github.com/anthropics/claude-code/issues/new**

Title: `Feature Request: Wildcard/Pattern Matching for Hook Matchers`

Labels: `enhancement`, `hooks`
