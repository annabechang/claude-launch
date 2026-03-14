---
allowed-tools: Read, Write, Edit, Bash(*), Glob, Grep, Task, WebFetch, WebSearch
---

# Launch: Fire-and-Forget Autonomous Session with Goal Alignment

You are a session architect. Convert the user's task into a structured task contract, get it reviewed by Codex, then launch an autonomous session that stays aligned with the user's intent.

## Input

```
$ARGUMENTS
```

**Format:** `<minutes|--until HH:MM> [--urgent] [--surge] [--codex-wait] [--pr-review] [--queue] [--prefer-sonnet] [--prefer-opus] [--desloppify] [--pipeline] [--force] <task description>`

If `$ARGUMENTS` is empty, show examples and ask what the user wants to work on:
```
/launch --until 09:00 "Improve the study platform design"
/launch 120 "Add WebSocket reconnection with exponential backoff"
/launch --until 09:00 --urgent "Fix critical authentication bug"
/launch 60 "Write integration tests for the queue module"
/launch --until 09:00 --surge "Maximize overnight throughput"
/launch 180 --pipeline "Refactor auth system to use JWT tokens"
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
  - `--pipeline` — force cyclic research→implement→review execution mode
  - `--force` — allow launch even if another timed session appears active
- **Task description**: Everything else

If duration is missing, ask: "How long should this run? (minutes or --until HH:MM)"

---

## Phase 2: Gather Context

Read project state (silently, don't dump everything to the user):
1. `PROJECT_STATUS.md` (if exists)
2. `notes/resume-checkpoint.md` (if exists)
3. Recent git log (last 10 commits)
4. Project-root `CLAUDE.md` (if exists)

---

## Phase 3: Clarify Intent (Interactive Handoff)

Use AskUserQuestion to ask 2-3 targeted questions. Adapt based on task specificity.

If task is vague, ask:
1. Task type (design/code/test/research/mixed)
2. NOT in scope (critical anti-drift guardrail)
3. Success criteria (concrete deliverables)

If task is specific, ask at least:
1. NOT in scope (what to avoid)

---

## Phase 4: Generate Task Contract

Write `notes/task-contract.md`:

```markdown
## Task Contract

- **Goal**: [concrete deliverable]
- **Type**: DESIGN | CODE | TEST | RESEARCH | MIXED
- **NOT in scope**: [explicit boundaries]
- **Success criteria**:
  - [deliverable 1]
  - [deliverable 2]
- **Duration**: [X minutes | --until HH:MM]
- **Priority order**: [if multiple]
- **Project context**: [brief summary]
- **Generated**: [ISO 8601 timestamp]

### User Clarifications (verbatim)
**Q**: ...
**A**: ...

### Alignment Rules (for autonomous session)
- READ THIS FILE at the start of every iteration
- If about to do something outside Goal/Success, STOP and realign
- If all success criteria are complete, write checkpoint or move to stretch goals
- Codex reviews alignment between iterations
```

---

## Phase 5: Codex Contract Review

Call Codex:

```
Review this task contract for an autonomous technical session.
Check for: vague goals that could cause drift, missing NOT-goals,
unrealistic success criteria for the given duration, and any gaps.
Suggest improvements in 2-3 sentences.

[paste contract content]
```

Append response under `### Codex Review` in the contract.

---

## Phase 6: User Approval

Show contract and ask for approval before launch.

---

## Phase 7: Launch

Launch the timed session:

```bash
~/.claude/scripts/timed_session_launcher.sh [duration args] [flags] --codex-wait "[one-line contract summary]"
```

If user chose a complex/thorough workflow or explicitly asked for multi-phase execution, include `--pipeline`.

The launcher self-detaches into a `claude-{ID}` tmux session (nohup fallback if tmux is unavailable).

---

## Phase 8: Management Instructions

Tell user:

```
Session launched! Here's how to manage it:

  ~/.claude/scripts/timed_session_manage.sh list
  ~/.claude/scripts/timed_session_manage.sh attach {ID}
  ~/.claude/scripts/timed_session_manage.sh stop {ID}
  ~/.claude/scripts/timed_session_manage.sh kill {ID}
  ~/.claude/scripts/timed_session_manage.sh cleanup

  ~/.claude/scripts/timed_session_monitor.sh
  ~/.claude/scripts/timed_session_monitor.sh --summary

Task contract saved to: notes/task-contract.md
Codex will check alignment between iterations.
Launcher log: /tmp/timed-session-launcher-{ID}.log
```

---

## Important Rules

- Never skip clarifying questions for vague tasks.
- Always generate a task contract.
- Always get Codex review on the contract before launch.
- NOT-goals are mandatory anti-drift guardrails.
- If user says "just go" without clarifications, push back once and request 30 seconds for guardrails.
