---
name: docs-audit
description: 'Legacy SaneProcess alias for the global Codex audit skill. Trigger on /docs-audit, audit docs, update docs, release docs, prepare for release, ship docs.'
---

# Documentation Audit Skill

This repo-local skill is a compatibility shim. The canonical implementation lives in
`~/.codex/skills/audit/SKILL.md`; do not fork audit retention, artifact, or subagent
policy here.

## Standard Path

1. Load and follow the global Codex `audit` skill.
2. Use GPT subagents for broad docs/release audits.
3. Write temporary per-perspective artifacts under `/tmp/docs_audit_outputs/` by default.
4. Do not create a repo-root `DOCS_AUDIT_FINDINGS.md` unless the user explicitly asks
   for a durable checked-in audit trail.
5. Promote durable conclusions into existing source-of-truth docs, Serena, the knowledge
   graph, or GitHub issues.

## Fallback

If the global audit skill is unavailable, use this directory's `prompts/*.md` files as
the perspective prompt set, but keep the same artifact and promotion rules above.
