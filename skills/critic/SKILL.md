# Critic Skill

> **Adversarial code review with multiple specialized perspectives**

## Triggers

- "ask the critic"
- "have the critic review"
- "critic review"
- "adversarial review"
- "challenge this"

---

## CRITICAL: SPAWN AGENTS, DON'T REVIEW YOURSELF

**When this skill is triggered, you MUST:**
1. **Spawn 6 parallel sub-agents** using the Task tool
2. **Wait for all results** before synthesizing
3. **Present the consolidated report** to the user

**DO NOT:**
- Review the code yourself and "pretend" to be multiple perspectives
- Read the prompts and apply them yourself
- Skip perspectives because "it's faster"
- Report findings without running all agents

**The whole point is PARALLEL adversarial thinking, not sequential you-pretending.**

---

## The 6 Perspectives

| # | Agent | Focus | Prompt File |
|---|-------|-------|-------------|
| 1 | Bug Hunter | Logic errors, null safety, crashes | `prompts/bug-hunter.md` |
| 2 | Data Flow Tracer | Feature completeness across code paths | `prompts/data-flow-tracer.md` |
| 3 | Integration Auditor | Cross-system config consistency | `prompts/integration-auditor.md` |
| 4 | Edge Case Explorer | Unusual states, environments | `prompts/edge-case-explorer.md` |
| 5 | UX Critic | UI/UX quality, clarity, accessibility | `prompts/ux-critic.md` |
| 6 | Security Auditor | Attack vectors, data exposure | `prompts/security-auditor.md` |

---

## How to Execute This Skill

### Step 1: Identify the Target

Ask the user (or infer from context):
- What to review? (recent changes, specific feature, entire component)
- Which files are involved?

### Step 2: Spawn 6 Agents in PARALLEL

**IMPORTANT: Send a SINGLE message with 6 Task tool calls.**

For each agent, use these parameters:
- `subagent_type`: `feature-dev:code-reviewer`
- `model`: `sonnet` (reliable for catching real issues in parallel work)
- `description`: "[Agent Name] Review"
- `prompt`: Include the full prompt from the corresponding `prompts/*.md` file, followed by the files/feature to review

**Example prompt structure:**
```
You are the [AGENT NAME]. Your mission is adversarial review.

[PASTE FULL CONTENT FROM prompts/[agent].md]

---

## Your Task

Review the following for [PROJECT NAME]:
- Files: [list files]
- Feature: [describe if applicable]
- Recent changes: [describe if applicable]

Report findings in the format specified in your prompt.
```

### Step 3: Collect and Synthesize Results

Wait for all 6 agents to complete. Then:
1. Collect all findings
2. Deduplicate (same issue found by multiple agents = higher confidence)
3. Prioritize: CRITICAL > HIGH > MEDIUM > LOW
4. Present consolidated report

---

## Output Format

```markdown
## Critic Review: [Feature/Component Name]

### Agents Run
- [x] Bug Hunter
- [x] Data Flow Tracer
- [x] Integration Auditor
- [x] Edge Case Explorer
- [x] UX Critic
- [x] Security Auditor

### Critical Issues (Must Fix)
| Issue | Found By | Location | Impact |
|-------|----------|----------|--------|
| [Title] | Bug Hunter, Data Flow | `file.swift:123` | [Impact] |

### High Priority
...

### Medium Priority
...

### Observations (Low/Informational)
...

### Verified Working
- [List of things that passed all reviews]

### Confidence Notes
- Issues found by 2+ agents: Higher confidence
- Issues with unclear impact: Flagged for manual review
```

---

## When to Use

- **Before shipping a release** - Final gate check
- **After implementing a feature** - Verify completeness
- **When uncertain** - "Does this actually work in all cases?"
- **After fixing a bug** - Did the fix introduce new issues?

---

## Why Multiple Perspectives?

Single-perspective code review misses entire categories of bugs:

- **Code review alone** doesn't catch config drift or integration failures. That's why the Integration Auditor exists.
- **Features have multiple code paths.** A setting checked in 1 of 6 places is a bug the Data Flow Tracer catches.
- **Security auditors think differently** than bug hunters — they look for what an attacker would exploit, not what might crash.

---

## Quick Mode

For faster reviews, you can run a subset:

- `critic review --code-only`: Bug Hunter + Data Flow + Security (3 agents)
- `critic review --ux-only`: UX Critic only (1 agent)
- `critic review --integration`: Integration Auditor only (1 agent)

Default is always full 6-agent review.
