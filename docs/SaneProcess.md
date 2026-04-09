*SaneProcess v2.4 - Canonical SOP Index*

# SaneProcess

This file still exists so older links and QA checks have a stable landing page.
It is no longer the full operating manual.

SaneProcess still enforces the same **17 Golden Rules**, but the live source of
truth is now split across the standard project docs:

| Need | Read this |
|------|-----------|
| Product overview and install path | `README.md` |
| Daily commands, release flow, manual utilities | `DEVELOPMENT.md` |
| Design decisions, research graduation, system shape | `ARCHITECTURE.md` |
| Agent rules, hooks, session flow | `AGENTS.md` and local `CLAUDE.md` |
| Current operational state | `SESSION_HANDOFF.md` |

## The 17 Golden Rules

SaneProcess still enforces these core rules:

1. Name it before you tame it
2. Stay in lane, no pain
3. Verify, then try
4. Two strikes? stop and check
5. Green means go
6. House rules, use tools
7. Build, kill, launch, log
8. No test? no rest
9. Bug found? write it down
10. New file? gen the pile
11. Five hundred's fine, eight's the line
12. Tool broke? fix the yoke
13. Talk while I walk
14. Context or chaos
15. Prompt like a pro
16. Review before you ship
17. Don't fragment, integrate

## Canonical Start Path

For a fresh project or fresh machine:

```bash
curl -sL https://raw.githubusercontent.com/sane-apps/SaneProcess/main/scripts/init.sh | bash
```

Then use the current command surface:

```bash
ruby scripts/SaneMaster.rb verify
ruby scripts/SaneMaster.rb test_mode
ruby scripts/SaneMaster.rb release_preflight
ruby scripts/SaneMaster.rb tool_discovery --query "missing tool"
```

## What Changed

- The old monolithic SOP doc drifted away from the live tooling.
- `SaneMaster.rb`, the shared hooks, and the 5-doc standard are now the real
  contract.
- This file is intentionally short so it can stay accurate and keep older links
  from rotting.

## If You Need The Full Current SOP

Start here, in order:

1. `README.md`
2. `DEVELOPMENT.md`
3. `AGENTS.md`
4. `CLAUDE.md`
5. `SESSION_HANDOFF.md`
