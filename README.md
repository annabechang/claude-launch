# claude-launch

Fire-and-forget autonomous Claude Code sessions with task contracts, alignment checking, and time budgets.



## The problem

Autonomous coding sessions drift. You say "improve the platform" and come back to find Claude refactored your database schema. `/launch` prevents this with explicit NOT-goals, success criteria, and periodic alignment checks.

## Quick start

```bash
# Install
git clone https://github.com/rongstuff/claude-launch.git
cd claude-launch
chmod +x install.sh && ./install.sh

# Use (inside any Claude Code session)
/launch 60 "Add WebSocket reconnection with exponential backoff"
/launch --until 09:00 "Improve test coverage for the auth module"
/launch 120 --surge "Maximize overnight throughput"
```

### Option: Make your own

The core ideas fit in a prompt. Tell your coding agent:

> Implement a fire-and-forget autonomous session launcher for Claude Code according to this spec:
> [commands/launch.md](commands/launch.md)

The [`commands/launch.md`](commands/launch.md) file is the spec — it defines the 8-phase workflow. Everything in `scripts/` is one implementation of that spec.

## Requirements

### Required

| Dependency | Why | Install |
|-----------|-----|---------|
| **Claude Code CLI** | The coding agent that runs inside sessions | `npm install -g @anthropic-ai/claude-code` |
| **Python 3.10+** | Timer, budget tracking, usage cache (stdlib only) | Pre-installed on most systems |

### Required for full functionality

| Dependency | Why | Install |
|-----------|-----|---------|
| **Codex CLI** | Cross-model alignment review during cooldowns. Without this, sessions still run but skip the alignment check — the #1 anti-drift mechanism. | [Install Codex](https://github.com/openai/codex) and ensure `codex` is in PATH |
| **tmux** | Named sessions you can attach/detach. Without this, sessions use nohup (not attachable). | `brew install tmux` (macOS) / `apt install tmux` (Linux) |

### Optional

| Dependency | Why | Install |
|-----------|-----|---------|
| **timeout / gtimeout** | Time-limited subprocess execution (Codex review, test gates). Falls back to no-timeout if missing. | `brew install coreutils` (macOS) / pre-installed (Linux) |
| **PyYAML** | Only for `--queue` mode (workqueue.yaml parsing) | `pip install pyyaml` |
| **terminal-notifier** | macOS desktop notifications on session complete | `brew install terminal-notifier` |

### Platform notes

The launcher reads Claude's OAuth token from **macOS Keychain** to query usage data for budget tracking. Linux is not currently supported for usage tracking — sessions will still run but without budget-aware cooldown optimization.

## `/launch` vs `/loop`

These solve different problems and work well together.

| | `/launch` | `/loop` |
|---|---|---|
| **What it does** | Structures intent → generates contract → launches detached session | Re-feeds the same prompt every time Claude tries to stop |
| **Runs where** | Detached tmux session (fire-and-forget, walk away) | Current terminal session (blocks your terminal) |
| **Anti-drift** | Task contract + NOT-goals + Codex alignment review between iterations | Completion promise only ("keep going until done") |
| **Budget** | Time budget + usage API tracking + SURGE mode | Iteration count only |
| **Handles rate limits** | Yes — detects exit, computes cooldown, restarts with `--continue` | No — session ends on rate limit |
| **Best for** | Ambiguous or large tasks where you walk away | Well-defined tasks with clear pass/fail ("fix all failing tests") |

**Use together:** `/launch` structures the task and runs it detached. Inside the detached session, a stop hook keeps Claude working (similar to `/loop`) until the time budget expires or the contract is complete.

**When to use which:**
- "Run this overnight while I sleep" → `/launch`
- "Keep iterating until tests pass" → `/loop`
- "Work on this for 2 hours, check alignment every iteration" → `/launch --codex-wait`

## How it works

The `/launch` command runs an 8-phase workflow:

1. **Parse** — Extract duration, flags, and task description
2. **Gather context** — Read PROJECT_STATUS.md, git log, checkpoints
3. **Clarify intent** — Ask targeted questions, especially **NOT-goals** (the #1 anti-drift mechanism)
4. **Generate task contract** — Write `notes/task-contract.md` as the session's source of truth
5. **Cross-model review** — Codex reviews the contract for blind spots
6. **User approval** — You confirm before anything launches
7. **Launch** — Detached tmux session with restart loop and budget management
8. **Management** — List, attach, stop, kill, monitor sessions

### Architecture

The launcher wraps `claude -p` (non-interactive mode) in a restart loop:

```
┌─────────────────────────────────────────┐
│  tmux session: claude-{ID}              │
│                                         │
│  ┌─ Restart Loop ────────────────────┐  │
│  │                                   │  │
│  │  1. Check timer (time remaining?) │  │
│  │  2. Check budget (usage %)        │  │
│  │  3. Run claude -p --continue      │  │
│  │  4. Claude exits (rate limit)     │  │
│  │  5. Compute cooldown              │  │
│  │  6. [Optional] Codex review       │  │
│  │  7. Sleep cooldown                │  │
│  │  8. Go to 1                       │  │
│  │                                   │  │
│  └───────────────────────────────────┘  │
│                                         │
└─────────────────────────────────────────┘
```

Rate limits cause clean exits in `-p` mode. The wrapper detects this, waits for the 5-hour window to decay, then restarts with `--continue` to resume work.

## Flags

| Flag | Effect |
|------|--------|
| `--urgent` | Maximize budget threshold (95% vs default 80%) |
| `--surge` | Push utilization to dynamic soft target with stall/resume |
| `--codex-wait` | Run Codex review during cooldown periods (auto-added by /launch) |
| `--pr-review` | Create PR and use Codex GitHub review loop during cooldown |
| `--queue` | After task completes, pop next task from workqueue |
| `--prefer-sonnet` | Use Sonnet for iterations (cost savings) |
| `--prefer-opus` | Use Opus for iterations (max quality) |
| `--desloppify` | Run desloppify code quality scan during cooldown |

## Session management

```bash
# View all sessions
~/.claude/scripts/timed_session_manage.sh list

# Attach to see live output
~/.claude/scripts/timed_session_manage.sh attach <ID>

# Graceful stop (finishes current iteration)
~/.claude/scripts/timed_session_manage.sh stop <ID>

# Force stop
~/.claude/scripts/timed_session_manage.sh kill <ID>

# Clean up orphaned sessions
~/.claude/scripts/timed_session_manage.sh cleanup

# Real-time progress stream
~/.claude/scripts/timed_session_monitor.sh

# Quick status summary
~/.claude/scripts/timed_session_monitor.sh --summary
```

## Security

Sessions run with `--dangerously-skip-permissions` by default, which is required for autonomous operation. Review the generated task contract before approving launch. Sessions execute in your user security context with full file system and network access.

## Acknowledgements

Patterns and concepts implemented in this codebase:

**Architecture & Session Management**
- [Boris Cherny](https://github.com/anthropics/claude-code) — Claude Code's `-p` mode, `--continue`, and stream-json output make the restart loop possible
- [Anthropic](https://docs.anthropic.com) — Rate limit bucket modeling (5-hour rolling window) used in cooldown calculation and budget tracking

**Anti-Drift & Alignment**
- [Garry Tan](https://gist.github.com/garrytan/001f9074cab1a8f545ebecbc73a813df) — NOT-goals as the primary anti-drift mechanism, scope challenge questions in the task contract
- Leo ([@runes_leo](https://x.com/runes_leo)) — Phase-tiered delegation matrix: when to use Codex review vs ship on passing tests
- Eno Reyes ([@EnoReyes](https://x.com/EnoReyes)) — "Encoded taste": phase guidance rules and checkpoint policies as programmatic judgment

**Design Influences**
- [Stripe Engineering](https://stripe.com) — Context pre-hydration (gather project state before clarifying intent), scoped delegation matrix
- [OpenAI Symphony](https://github.com/openai/symphony) — Spec-as-contract pattern (launch.md defines the workflow, scripts/ implements it)
- [OpenAI](https://openai.com) (Ryan Lopopolo) — "Harness Engineering" framing reflected in timer phases, budget phases, and SURGE mode

## License

MIT



> [!WARNING]
> This codebase was largely written by Claude Code (with human oversight and review). It may contain bugs, edge cases, or assumptions that don't hold in your environment. Review before trusting it with production work.