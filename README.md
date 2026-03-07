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

### Configuration

The launcher reads Claude's OAuth token from macOS Keychain to query usage data. On Linux, it falls back to cached data. No API keys or manual configuration required — it uses the same credentials as your Claude Code CLI.

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

This project integrates patterns and insights from many sources in the Claude Code community and beyond:

**Architecture & Session Management**
- [Boris Cherny](https://github.com/anthropics/claude-code) — Claude Code creator; `-p` mode, `--continue`, stream-json output that make the restart loop possible
- [Anthropic](https://docs.anthropic.com) — Rate limit bucket modeling (5-hour rolling window), MCP protocol, SKILL.md standard
- [arXiv:2602.11988](https://arxiv.org/abs/2602.11988) (Kangwook Lee et al.) — Context degradation research proving verbose context reduces agent success 0.5–2%

**Anti-Drift & Alignment**
- [Garry Tan](https://gist.github.com/garrytan/001f9074cab1a8f545ebecbc73a813df) — Plan-mode review v2.0.0: scope challenge, failure mode gap analysis, NOT-goals as primary anti-drift mechanism
- Leo ([@runes_leo](https://x.com/runes_leo)) — Risk-tiered review: high-risk code gets cross-model review, low-risk ships on passing tests
- Eno Reyes ([@EnoReyes](https://x.com/EnoReyes)) — "Encoded taste" concept: automated rules/hooks = programmatically enforced judgment

**Agent Engineering**
- [Stripe Engineering](https://stripe.com) — Blueprint pattern (deterministic nodes + agentic loops), scoped rules over global conditionals, context pre-hydration (1,300+ merged agent PRs/week)
- [OpenAI Symphony](https://github.com/openai/symphony) — Orchestrator architecture, WORKFLOW.md-as-contract pattern, workspace isolation
- [GSD](https://github.com/hasantoxr/gsd) (19K stars) — Fresh subagent context per task to prevent context rot, atomic commits per task
- [Systematicls](https://systematicls.com) — Adversarial 3-agent bug-finding pattern (hunter → skeptic → referee), neutral prompts to avoid sycophancy bias
- [Voyager](https://arxiv.org/abs/2305.16291) + [Butter](https://butter.dev) — Meta-tool generation: agents auto-extract reusable tools from multi-tool sequences

**Community Patterns**
- [affaan-m/claude-code-patterns](https://github.com/affaan-m/everything-claude-code) — Search-first workflow, session persistence hooks, strategic compaction at phase transitions
- [Peter Steinberger](https://steipete.com) (steipete) — "Config shrinks with models" insight; challenge over-engineering, audit hook/MCP ROI regularly
- [Ole Lehmann](https://x.com/itsolelehmann) — Voice DNA anti-AI writing patterns (50+ banned phrases)
- [Aakash Gupta](https://x.com/aaborofficial) — 100+ CLAUDE.md iterations proving minimal config > comprehensive config
- [Jonny Miller](https://x.com/jonnymiller) — Agent latches & reactive meta-learning (Nine Meta-Learning Loops)

**Code Quality**
- [Dan Peguine](https://github.com/danpeg) — `/bug-hunt` adversarial skill (hunter/skeptic/referee scoring)
- [SkillsMP](https://skillsmp.com) — Skill marketplace indexing 270K+ SKILL.md-standard agent skills
- [OpenAI](https://openai.com) (Ryan Lopopolo) — "Harness Engineering" framing: context engineering → architectural constraints → entropy management

## License

MIT

> [!NOTE]
> claude-launch is a working implementation, but it's also a starting point. The patterns here — task contracts, NOT-goals, cross-model review, restart loops — are more important than any specific script. Fork it, rewrite it, make it yours.

> [!WARNING]
> This codebase was largely written by Claude Code (with human oversight and review). It may contain bugs, edge cases, or assumptions that don't hold in your environment. Review before trusting it with production work.