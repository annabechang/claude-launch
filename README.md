# claude-launch

## Contribution

This project contributes an autonomous launcher for open-ended technical work that tends to drift.

1. It keeps long-running work aligned using contract-first scope control (goal, NOT-goals, success criteria) plus iterative alignment checks.
2. It runs one or more detached headless Claude sessions (parallel when needed) toward the target outcome, with optional headless Codex review loops for quality/alignment.
3. It is **budget-aware**: tracks your 5h and 7d API utilization and adjusts behavior across phases (`SPRINT/CRUISE/WRAP_UP`) so work paces itself around your remaining capacity.
4. It **auto-recovers from rate limits**: when Claude hits a rate limit, the launcher automatically waits for cooldown and restarts with `--continue` — no work is lost, no manual intervention needed.
5. It gives operators continuous control: run by time budget, intervene any time (`attach/stop/kill`), and feed updated guidance between iterations.

## Why this exists

Most automation loops optimize for persistence ("keep going").
This project optimizes for **intent fidelity under autonomy**:

- Clarify intent before launch.
- Convert intent into a concrete contract.
- Keep checking alignment while the agent runs unattended.
- Enforce time and budget guardrails across restarts.

## What is distinctive here

1. **Anti-drift by design**
- NOT-goals are required and treated as first-class constraints.
- Contract and original request are embedded into iteration prompts.
- Alignment checks run during cooldowns and feed corrective guidance back in.

2. **Autonomous time + budget control**
- Detached session management with timer states.
- Budget-aware pacing (`SPRINT/CRUISE/WRAP_UP`) and optional SURGE mode.
- Rate-limit aware restart loop with `--continue` recovery.

3. **Cross-session operational control**
- List/attach/stop/kill/cleanup commands for all live sessions.
- Real-time stream monitor and summary parsing.
- Optional queue mode for back-to-back task execution.

4. **Handles non-deterministic tasks better than pure "loop" tools**
- Better for design/refactor/research-heavy tasks where scope can drift.
- Pipeline mode (`--pipeline`) supports research -> implement -> review cycles.



## Quick start

```bash
git clone https://github.com/rongstuff/claude-launch.git
cd claude-launch
chmod +x install.sh && ./install.sh
```

Inside any Claude Code session:

```bash
/launch 60 "Add WebSocket reconnection with exponential backoff"
/launch --until 09:00 "Improve test coverage for auth"
/launch 120 --surge "Maximize overnight throughput"
/launch 180 --pipeline "Refactor auth into staged migration"
```

## Requirements

- **Required**: Claude Code CLI (`claude`) and Python 3.10+.
- **Required for Codex review/alignment features**: Codex CLI (`codex`) installed and available on `PATH`.
- **Optional but recommended**: `tmux` for attachable detached sessions (otherwise launcher falls back to `nohup`).

### Optional dependencies

| Dependency | Used by | Install |
|---|---|---|
| `gh` (GitHub CLI) | `--pr-review` flag | `brew install gh` |
| `PyYAML` | `--queue` mode (workqueue.yaml) | `pip install pyyaml` |
| `terminal-notifier` | macOS desktop notifications on session events | `brew install terminal-notifier` |
| `desloppify` | `--desloppify` code quality scans | `pip install desloppify[full]` |
| `coreutils` | `timeout` for subprocess time limits on macOS | `brew install coreutils` |

All optional — each feature degrades gracefully if its dependency is missing.

### Platform notes

- **macOS**: Fully supported. Budget-aware pacing uses the macOS Keychain (`security find-generic-password`) to read your Claude OAuth token for usage API calls. This enables automatic cooldown timing and SURGE mode.
- **Linux**: Core launcher, timer, and session management work. Budget-aware features (`_refresh_usage_cache.py`) require adapting the OAuth token retrieval to your credential store — the Keychain call will silently fail and budget checks will be skipped.

## System workflow

### 1. Launch workflow (intent -> contract -> run)

1. Parse duration, flags, and task input from `/launch`.
2. Gather project context (`git`, notes, status files).
3. Clarify intent with the user, especially NOT-goals.
4. Generate `notes/task-contract.md` as the scope source of truth.
5. Run a Codex contract review for drift/blind-spot checks.
6. Get explicit user approval.
7. Start detached session runtime (`tmux` or `nohup` fallback).

### 2. Runtime workflow (headless iteration loop)

1. Start a per-session timer and budget guardrails.
2. Run headless Claude (`claude -p`) for the next iteration.
3. On stop/rate-limit/exit, collect status and evaluate next action.
4. During cooldown windows, optionally run headless Codex checks/reviews.
5. Inject alignment corrections into the next Claude iteration when needed.
6. Repeat until timer expires, contract is complete, or user stops the session.

### 3. Control workflow (multi-session operations)

1. `timed_session_manage.sh list` shows all known sessions and health.
2. `attach/stop/kill/cleanup` provide operational control.
3. `timed_session_monitor.sh` streams live progress and summary stats.
4. Multiple launcher instances can run in parallel; each gets its own instance ID, logs, and timer state.

## Flags

| Flag | Purpose |
|---|---|
| `--urgent` | Raise budget threshold (95%) |
| `--surge` | Aggressive budget utilization with stall/resume controls |
| `--codex-wait` | Run Codex review during cooldown windows |
| `--pr-review` | Run Codex GitHub PR review loop during cooldown |
| `--queue` | Pop next task from queue after completion |
| `--prefer-sonnet` | Force Sonnet iterations |
| `--prefer-opus` | Force Opus iterations |
| `--desloppify` | Run desloppify checks during cooldown |
| `--pipeline` | Enable cyclic research -> implement -> review execution |
| `--force` | Allow launch even if another timed session is active |

## Script Reference

The launcher is intentionally script-first. Each file has one operational responsibility.

| Script | Role |
|---|---|
| `scripts/timed_session_launcher.sh` | Main runtime. Parses args, starts detached session, manages restart loop, budget/timer logic, pipeline phases, cooldown work, and queue chaining. |
| `scripts/timed_session_manage.sh` | Session control plane (`list`, `attach`, `stop`, `kill`, `cleanup`). |
| `scripts/timed_session_monitor.sh` | Live stream parser and summary monitor for active session logs. |
| `scripts/_session_timer.py` | Timer state machine for `CONTINUE/WRAP_UP/TIME_UP` decisions and per-instance timer files. |
| `scripts/_refresh_usage_cache.py` | Refreshes Claude usage cache from OAuth usage endpoint (for budget decisions in `-p` mode). |
| `scripts/_budget_common.py` | Shared budget phase helpers and marker utilities. |
| `scripts/_execution_engine.py` | Strategy/phase routing engine used by pipeline mode and model routing logic. |
| `scripts/_budget_predictor.py` | Queue-task budget estimator used before chaining the next task. |

## Security note

- Sessions run with `--dangerously-skip-permissions` to support autonomous operation.
- Treat this as **full user-context execution** (file system + network privileges of your user).
- Always review task contract before launch.

## Acknowledgements

Patterns and concepts in this codebase were influenced by:

- [Anthropic Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference): `-p` print mode, `--continue`, and `--output-format=stream-json` capabilities used by launcher runtime design.
- [Anthropic API rate limits docs](https://platform.claude.com/docs/en/api/rate-limits): model/rate-limit constraints that inform cooldown and budget-aware behavior.
- [Garry Tan's plan-exit-review skill gist](https://gist.github.com/garrytan/001f9074cab1a8f545ebecbc73a813df): "Scope Challenge" and explicit "NOT in scope" review structure used as anti-drift planning influence.
- [OpenAI Symphony](https://github.com/openai/symphony): "manage work, not agents" framing and isolated autonomous run orchestration influence.


## License

MIT

> [!WARNING]
> This codebase is automation-heavy, environment-sensitive, and substantially vibe-coded. Use with caution, review prompts/contracts/logs before running on sensitive repositories, and use Claude/Codex to adapt it to your own workflow rather than treating it as drop-in production automation.
