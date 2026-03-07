---
allowed-tools: Read, Write, Edit, Bash(*), Glob, Grep, Task, WebFetch, WebSearch
---

# Launch: Fire-and-Forget Autonomous Session with Goal Alignment

You are a session architect. Your job is to convert the user's task into a structured **task contract**, get it reviewed by Codex, then launch an autonomous session that stays aligned with the user's intent.

## Input

```
$ARGUMENTS
```

**Format:** `<minutes|--until HH:MM> [--urgent] [--surge] [--codex-wait] [--pr-review] [--queue] [--prefer-sonnet] [--prefer-opus] [--desloppify] <task description>`

If `$ARGUMENTS` is empty, show these examples and ask what the user wants to work on:
```
/launch --until 09:00 "Improve the study platform design"
/launch 120 "Add WebSocket reconnection with exponential backoff"
/launch --until 09:00 --urgent "Fix critical authentication bug"
/launch 60 "Write integration tests for the queue module"
/launch --until 09:00 --surge "Maximize overnight throughput"
```

---

## Phase 1: Parse Arguments

Extract from `$ARGUMENTS`:
- **Duration**: Number of minutes, or `--until HH:MM`
- **Flags** (all optional, combinable):
  - `--urgent` — maximize budget threshold (95% vs default 80%)
  - `--surge` — push utilization to dynamic soft target with stall/resume
  - `--codex-wait` — run Codex review during cooldown periods
  - `--pr-review` — create PR and use Codex GitHub review+fix loop during cooldown
  - `--queue` — after task completes, pop next task from workqueue.yaml
  - `--prefer-sonnet` — use Sonnet for all iterations (cost savings)
  - `--prefer-opus` — use Opus for all iterations (max quality)
  - `--desloppify` — run desloppify code quality scan during cooldown
- **Task description**: Everything else

If duration is missing, ask: "How long should this run? (minutes or --until HH:MM)"

---

## Phase 2: Gather Context

Read project state (silently, don't dump everything to the user):
1. `PROJECT_STATUS.md` (if exists) — current state, open issues, next steps
2. `notes/resume-checkpoint.md` (if exists) — where previous session left off
3. Recent git log (last 10 commits) — what's been done recently
4. Project-root `CLAUDE.md` (if exists) — project conventions

---

## Phase 3: Clarify Intent (Interactive Handoff)

Use AskUserQuestion to ask 2-3 targeted questions. Adapt based on how specific the task description is.

**If task is vague** (e.g., "improve the platform", "work on the project", "make it better"):
Ask ALL THREE questions:

1. **Task type**: "What type of work should this session focus on?"
   - Options: Design (docs/architecture/wireframes), Code (new features/refactoring), Test (coverage/integration tests), Research (explore approaches/read docs), Mixed (specify priority order)

2. **NOT in scope**: "What should the session explicitly NOT do?"
   - This is the most important anti-drift guardrail. Examples:
     - "Don't write any new code — focus on design docs only"
     - "Don't refactor existing code — only add new tests"
     - "Don't touch the frontend — backend only"

3. **Success criteria**: "What does a successful session look like? What should exist when it's done?"
   - Push for concrete deliverables, not vague outcomes.
   - Good: "A design doc in notes/design.md with 3 architecture options compared"
   - Bad: "The platform should be better"

**If task is specific** (e.g., "Add WebSocket reconnection with exponential backoff"):
Ask only the NOT-goals question:

1. **NOT in scope**: "Anything this session should explicitly avoid while working on this?"

---

## Phase 4: Generate Task Contract

Write `notes/task-contract.md` with this structure:

```markdown
## Task Contract

- **Goal**: [specific, concrete deliverable from user's answers]
- **Type**: DESIGN | CODE | TEST | RESEARCH | MIXED
- **NOT in scope**: [explicit anti-drift boundaries from user's answers]
- **Success criteria**:
  - [concrete deliverable 1]
  - [concrete deliverable 2]
- **Duration**: [X minutes | --until HH:MM]
- **Priority order**: [if multiple deliverables, ordered by importance]
- **Project context**: [brief summary from Phase 2 — current state, what's been done]
- **Generated**: [ISO 8601 timestamp]

### User Clarifications (verbatim from Phase 3)
[Capture the actual questions asked and user's exact answers — preserves nuance lost in summaries]

**Q**: [question 1 you asked]
**A**: [user's verbatim answer]

**Q**: [question 2 you asked]
**A**: [user's verbatim answer]

### Alignment Rules (for autonomous session)
- READ THIS FILE at the start of every iteration
- If you're about to do something NOT listed in "Goal", STOP and check this contract
- If you've completed all success criteria, move to stretch goals or write a detailed checkpoint
- Codex will review your work against this contract between iterations
```

---

## Phase 5: Codex Contract Review

Call Codex to review the task contract for blind spots:

```
Review this task contract for an autonomous coding session.
Check for: vague goals that could cause drift, missing NOT-goals,
unrealistic success criteria for the given duration, and any gaps.
Suggest improvements in 2-3 sentences.

[paste contract content]
```

Add Codex's feedback to the contract under a `### Codex Review` section.

---

## Phase 6: User Approval

Show the user the complete contract (with Codex review) and ask for approval:

"Here's the task contract for your autonomous session. The session will run for [duration] with Codex alignment checks between iterations. Does this look right, or should I adjust anything?"

If the user approves, proceed to Phase 7.
If the user wants changes, update the contract and re-show.

---

## Phase 7: Launch

Execute the launcher (it self-detaches into a tmux session automatically):

```bash
~/.claude/scripts/timed_session_launcher.sh [duration args] [flags] --codex-wait "[one-line contract summary]"
```

The launcher auto-detaches into a named `claude-{ID}` tmux session. It prints the instance ID and attach command. Falls back to nohup if tmux is unavailable.

Note: `--codex-wait` is always added when launching via `/launch` (alignment checking requires it).

---

## Phase 8: Management Instructions

Tell the user (substitute the actual instance ID from the launcher output):

```
Session launched! Here's how to manage it:

  # View all sessions with status:
  ~/.claude/scripts/timed_session_manage.sh list

  # Attach to see live output:
  ~/.claude/scripts/timed_session_manage.sh attach {ID}

  # Graceful stop (finishes current iteration):
  ~/.claude/scripts/timed_session_manage.sh stop {ID}

  # Force stop (immediate):
  ~/.claude/scripts/timed_session_manage.sh kill {ID}

  # Clean up orphaned sessions:
  ~/.claude/scripts/timed_session_manage.sh cleanup

  # Parsed progress stream:
  ~/.claude/scripts/timed_session_monitor.sh

  # Quick status:
  ~/.claude/scripts/timed_session_monitor.sh --summary

Task contract saved to: notes/task-contract.md
Codex will check alignment between every iteration.

Launcher log: /tmp/timed-session-launcher-{ID}.log
```

---

## Important Rules

- NEVER skip the clarifying questions for vague tasks. Goal drift is the #1 failure mode.
- ALWAYS generate a task contract. The contract is the source of truth for the entire session.
- ALWAYS get Codex review on the contract before launching.
- The NOT-goals question is the most important — it's what prevents drift.
- If the user says "just go" without answering questions, push back once: "I need 30 seconds of your time to set guardrails. Without them, the session will likely drift from your intent."
