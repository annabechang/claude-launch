# claude-launch

Fire-and-forget autonomous Claude Code sessions with task contracts, alignment checking, and time budgets.

## What it does

`/launch` converts a vague task description into a structured **task contract**, gets it reviewed by a cross-model reviewer (Codex), then launches a detached autonomous session that stays aligned with your intent.

**The problem it solves:** Autonomous coding sessions drift. You say "improve the platform" and come back to find Claude refactored your database schema. `/launch` prevents this with explicit NOT-goals, success criteria, and periodic alignment checks.

## Quick Start

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

## Session Management

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

## How it compares to Ralph Loop

| | `/launch` | Ralph Loop |
|---|---|---|
| **Focus** | Pre-launch intent structuring + detached execution | In-session iteration loop |
| **Runs where** | Detached tmux session (fire-and-forget) | Current session (blocks terminal) |
| **Anti-drift** | Task contract + NOT-goals + Codex alignment review | Completion promise only |
| **Budget** | Time budget + usage API tracking + SURGE mode | Iteration count only |
| **Best for** | Ambiguous/large tasks where you walk away | Well-defined tasks with clear pass/fail |

They're complementary — `/launch` structures the task, Ralph iterates until done.

## Requirements

- **Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`)
- **Python 3.10+** (stdlib only, no pip packages for core functionality)
- **tmux** (optional, falls back to nohup)
- **PyYAML** (optional, only for `--queue` mode: `pip install pyyaml`)

## Architecture

The launcher runs a restart loop around `claude -p` (non-interactive mode):

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

## Security

Sessions run with `--dangerously-skip-permissions` by default, which is required for autonomous operation. Review the generated task contract before approving launch. Sessions execute in your user security context with full file system and network access.

## License

MIT
