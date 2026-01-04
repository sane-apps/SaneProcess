# SanePrompt: Intelligent Task Orchestration System

> Saved: 2026-01-04 | Status: READY TO BUILD

## The Vision

Transform Claude from "reactive assistant" to "proactive collaborator with guardrails." Rules followed **by design**, not enforcement.

## PRIME DIRECTIVE Integration

Every session/task starts with:

1. READ the user prompt completely (no skimming)
2. CHECK memory for similar past tasks/bugs
3. MAP which Golden Rules apply
4. THEN proceed

From memory: *"The #1 differentiator is SOP INTERNALIZATION not knowledge"*

## The Flow

```
USER INPUT (vague)
    ↓
┌─────────────────────────────────────┐
│  PHASE 0: PRIME DIRECTIVE           │
│  - Read prompt fully (no skim)      │
│  - search_nodes for similar tasks   │
│  - Check for known bugs in area     │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│  PHASE 1: CLARIFICATION             │
│  - Parse intent                      │
│  - Ask 1-3 targeted questions       │
│  - Wait for answers (AskUserQuestion)│
│  - Never proceed with ambiguity     │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│  PHASE 2: STRUCTURING               │
│  - Classify: Question/Task/Big Task │
│  - Map rules that apply             │
│  - Generate SanePrompt plan         │
│  - Show execution mode options      │
│  - Get user approval                │
└─────────────────────────────────────┘
    ↓
USER PICKS MODE + APPROVES
    ↓
┌─────────────────────────────────────┐
│  PHASE 3-N: EXECUTION LOOP          │
│  For each phase:                    │
│                                      │
│  1. RESEARCH BURST (5 parallel)     │
│     - memory (past bugs/patterns)   │
│     - docs (API verification)       │
│     - web (current patterns)        │
│     - github (similar code)         │
│     - local (codebase grep)         │
│                                      │
│  2. EXECUTE PHASE                   │
│     - Two-strike → full stop        │
│     - Log all actions               │
│                                      │
│  3. CHECKPOINT (per mode)           │
│     - Self-rate: SOP + Performance  │
│     - Show user (if phase-by-phase) │
│     - Get approval OR continue      │
└─────────────────────────────────────┘
    ↓
┌─────────────────────────────────────┐
│  FINAL: SESSION SUMMARY             │
│  - What Was Done (numbered list)    │
│  - SOP Compliance: X/10             │
│    ✅ Rules followed (with proof)   │
│    ❌ Rules missed (with reason)    │
│  - Performance: X/10                │
│    ⚠️ Gaps identified               │
│  - Followup items                   │
└─────────────────────────────────────┘
```

## Execution Modes

- **[A] Autonomous** - Execute all, review at end
- **[P] Phase-by-phase** - Check in after each phase (default)
- **[S] Supervised** - Check in after each action
- **[M] Modify plan** - Edit before proceeding

## Planning Lessons (From Memory)

**REJECTED patterns:**
- Plan with unasked questions at end
- Time estimates instead of steps
- No SOP rule mapping
- Unresolved options

**ACCEPTED patterns:**
- Decisions Made section at top
- Each phase has `[Rule #X: NAME]` mapping
- Specific steps with commands
- Use AskUserQuestion BEFORE finalizing

## Rule Mapping (Baked In)

**Bug fix:** #8 (document), #7 (test), #4 (green), #3 (2 strikes)

**New feature:** #0 (name rule), #2 (verify API), #9 (gen pile), #5 (their tools)

**Refactor:** #7 (test), #4 (green), #10 (500 lines)

**Research:** #2 (verify), #3 (2 strikes)

**New file:** #9 (gen pile), #1 (stay in lane)

## Gaming Detection (Anti-Patterns)

**Red flags:**
- Rating inflation: 5+ consecutive 8+/10
- Bypass creation: Any "skip_once" or "escape hatch" additions
- Research skipping: Phase complete without research logs
- Rule citation without evidence: "followed #2" but no API check in logs
- Time anomalies: Phase faster than research could run
- Repeated "fix" attempts: Same fix 3+ times = not a fix

**Audit tracking:**
- All self-ratings logged with timestamps
- Research actions tracked per phase
- Edit counts vs research counts ratio
- Streak tracking (resets on validation fail)

## Passthrough Patterns (Skip Transformation)

- Commands: `/commit`, `/review-pr`, `commit`, `push`
- Continuations: `y`, `yes`, `continue`, `approved`
- Short confirms: < 10 chars, no question mark

## Frustration Detection

Watch for signals that Claude isn't reading:
- "understand better", "explain", "I already said"
- Repetition of instructions
- ALL CAPS emphasis
- "read the prompt", "check memory"

Response: Stop, re-read everything, acknowledge what was missed.

## Output Format

```
## SanePrompt: [Task Description]

### Memory Check
- Similar past tasks: [found/none]
- Known bugs in area: [found/none]
- Relevant patterns: [list]

### Classification
Type: [Question | Task | Big Task]
Scope: [S/M/L] | Phases: [N if Big Task]

### Rules Triggered
- #X: [NAME] → [why it applies]
  - Right: [example of compliance]
  - Wrong: [example of violation]

### Research Required
- [ ] memory - [specific query]
- [ ] docs - [what to verify]
- [ ] web - [what to search]
- [ ] github - [what to find]
- [ ] local - [what to grep]

### Acceptance Criteria
- [ ] [criterion] - verify: `[command]`

### Completion Promise
"[what must be true when done]"

### Execution Mode
[A] Autonomous | [P] Phase-by-phase | [S] Supervised

### First Action
[exact command - includes `saneloop start` for Big Tasks]

---
Approve? [A/P/S/M/n]
```

## Files to Create

```
scripts/hooks/core/
├── saneprompt_engine.rb      # Main orchestrator
├── clarifier.rb              # Question generation
├── phase_runner.rb           # Single phase execution
├── checkpoint.rb             # User check-in
└── gaming_detector.rb        # Audit analysis
```

## Key Files to Read First

1. `~/.claude/CLAUDE.md` - Golden Rules #0-#12
2. `scripts/hooks/legacy/prompt_analyzer.rb` - Existing classification
3. `scripts/hooks/legacy/phase_manager.rb` - 5-phase structure
4. `scripts/sanemaster/sop_loop.rb` - SaneLoop spec format
5. `.claude/architecture/HOOK_CONSOLIDATION.md` - Hook architecture
6. `.claude/SESSION_HANDOFF.md` - Prompt structure example

## Acceptance Criteria

- [ ] PRIME DIRECTIVE: memory check runs first
- [ ] Vague prompt → clarifying questions via AskUserQuestion
- [ ] Structured plan → rules visibly mapped with Right/Wrong examples
- [ ] Big task → phases with research burst each
- [ ] Two failures → automatic research pause
- [ ] Mode selection → respected throughout execution
- [ ] Phase complete → self-rate (SOP + Performance split)
- [ ] Gaming patterns → flagged in logs
- [ ] Session end → proper summary format
- [ ] `ruby -c` passes all files

## Completion Promise

"Every user prompt becomes a structured, phase-gated execution plan with research-first discipline. Rules are followed by design. Self-rating is honest with audit trails. User controls execution pace. Gaming is detected and flagged."

## First Action

```bash
./scripts/SaneMaster.rb saneloop start "Build SanePrompt orchestration system"
```

Then: PRIME DIRECTIVE check (memory search), read 6 key files, create `saneprompt_engine.rb`.

---

## TODO for Next Session

1. Update `~/.claude/hooks/edit_validator.rb` table rule:
   - Tables OK in docs (.claude/, architecture/, SPEC.md, README.md)
   - Tables blocked in user-facing terminal output only
