#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Timed Session Launcher — Fire-and-forget autonomous Claude
#
# Runs Claude Code in -p (non-interactive) mode inside a restart
# loop. Rate limits cause clean exits (no menu), and the wrapper
# waits for cooldown then restarts with --continue.
#
# Usage:
#   timed_session_launcher.sh <minutes> [flags] <task>
#   timed_session_launcher.sh --until <HH:MM> [flags] <task>
#
# Flags:
#   --urgent         Maximize budget (95% threshold vs 80% default)
#   --codex-wait     Run Codex review during cooldown (stretch goal)
#
# Examples:
#   timed_session_launcher.sh 60 "Refine the study platform"
#   timed_session_launcher.sh --until "09:00" "Improve test coverage"
#   timed_session_launcher.sh 120 --urgent "Fix critical production bug"
# ─────────────────────────────────────────────────────────────

set -uo pipefail
# Note: NOT using set -e — the restart loop must survive command failures

# Ensure PATH includes common install locations for claude binary
# (launchd agents run with minimal PATH that excludes /usr/local/bin)
export PATH="/usr/local/bin:/usr/local/sbin:/opt/homebrew/bin:${HOME}/.local/bin:$PATH"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMER_SCRIPT="$SCRIPTS_DIR/_session_timer.py"
USAGE_CACHE="/tmp/claude-usage-cache.json"
CODEX_USAGE_CACHE="/tmp/claude-codex-usage-cache.json"

# ─── Global Claude binary discovery ───────────────────────
# Used by all functions that need to invoke claude (review, main loop, etc.)
CLAUDE_BIN=""
for _candidate in \
    /usr/local/bin/claude \
    /opt/homebrew/bin/claude \
    "${HOME}/.local/bin/claude" \
    "${HOME}/.npm-global/bin/claude" \
    "$(command -v claude 2>/dev/null)"; do
    if [ -n "$_candidate" ] && [ -x "$_candidate" ]; then
        CLAUDE_BIN="$_candidate"
        break
    fi
done
unset _candidate

# ─── Instance ID (unique per invocation) ────────────────────
# Uses timestamp + random to ensure each launcher gets its own log/timer files.
# Preserved across self-detach via env var so parent and child use the same ID.
if [ -n "${LAUNCHER_INSTANCE_ID:-}" ]; then
    INSTANCE_ID="$LAUNCHER_INSTANCE_ID"
else
    INSTANCE_ID=$(printf '%04x%04x' "$((RANDOM % 65536))" "$(($(date +%s) % 65536))")
    export LAUNCHER_INSTANCE_ID="$INSTANCE_ID"
fi

LAUNCHER_LOG="/tmp/timed-session-launcher-${INSTANCE_ID}.log"
STREAM_LOG="/tmp/timed-session-stream-${INSTANCE_ID}.jsonl"
PID_FILE="/tmp/timed-session-launcher-${INSTANCE_ID}.pid"

# Portable timeout wrapper (stock macOS has no `timeout`)
_timeout() {
    if command -v timeout &>/dev/null; then
        timeout "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$@"
    else
        # No timeout available — run without time limit
        local duration="$1"; shift
        "$@"
    fi
}

# ─── Self-detach for terminal resilience ─────────────────────
# On first invocation, re-launch in a detached tmux session so
# the launcher survives terminal closure. User can attach with:
#   tmux attach -t claude-{ID}
#
# Uses tmux's native -e flag for env vars and direct argv (no eval).
# Falls back to nohup if tmux is unavailable.
if [ -z "${LAUNCHER_DETACHED:-}" ]; then
    SESSION_NAME="claude-${INSTANCE_ID}"
    # Resolve absolute script path (tmux may change cwd)
    SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    # Detect cloud storage paths where tmux lacks Full Disk Access.
    # macOS grants FDA per-app; tmux server runs as its own process without FDA,
    # so it can't access Dropbox/iCloud/OneDrive directories. Use nohup instead.
    USE_TMUX=true
    case "$PWD" in
        */Library/CloudStorage/*|*/Library/Mobile\ Documents/*)
            USE_TMUX=false
            echo "NOTE: Cloud storage path detected — using nohup instead of tmux (FDA restriction)"
            ;;
    esac

    if [ "$USE_TMUX" = true ] && command -v tmux &>/dev/null; then
        # Collision detection: retry with new ID if session name exists
        local_retry=0
        while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
            local_retry=$((local_retry + 1))
            if [ "$local_retry" -ge 3 ]; then
                echo "ERROR: tmux session name collision after 3 retries"
                echo "Active: $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' | tr '\n' ' ')"
                exit 1
            fi
            INSTANCE_ID=$(printf '%04x%04x' "$((RANDOM % 65536))" "$(( ($(date +%s) + RANDOM) % 65536))")
            export LAUNCHER_INSTANCE_ID="$INSTANCE_ID"
            SESSION_NAME="claude-${INSTANCE_ID}"
            LAUNCHER_LOG="/tmp/timed-session-launcher-${INSTANCE_ID}.log"
            STREAM_LOG="/tmp/timed-session-stream-${INSTANCE_ID}.jsonl"
            PID_FILE="/tmp/timed-session-launcher-${INSTANCE_ID}.pid"
            echo "Session name collision, retrying with ID: $INSTANCE_ID"
        done

        # Launch via tmux with direct argv and explicit env vars.
        # No eval needed — tmux -e passes env reliably even when server exists.
        tmux new-session -d -s "$SESSION_NAME" \
            -e LAUNCHER_DETACHED=1 \
            -e LAUNCHER_INSTANCE_ID="$INSTANCE_ID" \
            -e CLAUDE_PROJECT_DIR="$PWD" \
            -c "$PWD" \
            "$SCRIPT_ABS" "$@"

        # Verify session was actually created
        if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "ERROR: tmux session creation failed for '$SESSION_NAME'"
            echo "Falling back to nohup..."
            LAUNCHER_DETACHED=1 LAUNCHER_INSTANCE_ID="$INSTANCE_ID" \
                nohup "$SCRIPT_ABS" "$@" >> "$LAUNCHER_LOG" 2>&1 &
            CHILD_PID=$!
            disown "$CHILD_PID" 2>/dev/null || true
            echo "$CHILD_PID" > "$PID_FILE"
            echo "Launcher detached via nohup fallback (PID $CHILD_PID)"
        else
            echo "$SESSION_NAME" > "$PID_FILE"
            echo "Launcher running in tmux session '$SESSION_NAME'"
            echo "  Attach: tmux attach -t $SESSION_NAME"
        fi
    else
        # nohup fallback — not attachable but survives terminal close
        export LAUNCHER_DETACHED=1
        nohup "$SCRIPT_ABS" "$@" >> "$LAUNCHER_LOG" 2>&1 &
        CHILD_PID=$!
        disown "$CHILD_PID" 2>/dev/null || true
        echo "$CHILD_PID" > "$PID_FILE"
        echo "Launcher detached via nohup (PID $CHILD_PID)"
    fi

    echo "  Instance: $INSTANCE_ID"
    echo "  Log: $LAUNCHER_LOG"
    echo "  Stream: $STREAM_LOG"
    echo "  Monitor: tail -f $LAUNCHER_LOG"
    exit 0
fi

# Defaults
DURATION_MIN=""
UNTIL_TIME=""
URGENT=false
CODEX_WAIT=false
PR_REVIEW=false
SURGE=false
FORCE=false
QUEUE_MODE=false
WORKQUEUE_FILE="$HOME/.claude/daemon/workqueue.yaml"
MODEL_PREFERENCE=""  # "", "sonnet", "opus" — user override for model selection
DESLOPPIFY=false     # Run desloppify code quality scan during cooldown
PIPELINE=false       # Multi-phase pipeline: research→implement→review across iterations
BUDGET_THRESHOLD=80
SURGE_SOFT_TARGET=90
SURGE_HARD_CAP=95
SURGE_RESUME_TARGET=60
TASK=""
ITERATION=0
CLAUDE_PID=""
CODEX_PID=""

# ─── Logging ─────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LAUNCHER_LOG"
}

# ─── Arg Parsing ─────────────────────────────────────────────

usage() {
    echo "Usage:"
    echo "  $(basename "$0") <minutes> [--urgent] [--surge] [--codex-wait] [--pr-review] [--queue] [--prefer-sonnet] [--prefer-opus] [--desloppify] [--pipeline] [--force] <task>"
    echo "  $(basename "$0") --until <HH:MM> [--urgent] [--surge] [--codex-wait] [--pr-review] [--queue] [--prefer-sonnet] [--prefer-opus] [--desloppify] [--pipeline] [--force] <task>"
    echo ""
    echo "Flags:"
    echo "  --urgent       Maximize budget threshold (95% vs default 80%)"
    echo "  --surge        Push utilization to dynamic soft target with stall/resume"
    echo "  --codex-wait   Run Codex review during cooldown periods"
    echo "  --pr-review    Create PR and use Codex GitHub review+fix loop during cooldown"
    echo "  --queue        After task completes, pop next task from workqueue.yaml"
    echo "  --prefer-sonnet  Use Sonnet for all iterations (cost savings)"
    echo "  --prefer-opus    Use Opus for all iterations (max quality)"
    echo "  --desloppify   Run desloppify scan during cooldown"
    echo "  --pipeline     Multi-phase: iteration 1=research, 2+=implement, final=review"
    echo "  --force        Allow running even if another instance is active"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") 60 \"Refine the study platform\""
    echo "  $(basename "$0") --until \"09:00\" \"Improve test coverage\""
    echo "  $(basename "$0") 120 --urgent \"Fix critical bug\""
    echo "  $(basename "$0") --until \"09:00\" --surge \"Maximize overnight throughput\""
    echo "  $(basename "$0") 180 --surge --urgent \"Critical deadline push\""
    exit 1
}

parse_args() {
    if [ $# -lt 1 ]; then
        usage
    fi

    local task_parts=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --until)
                shift
                UNTIL_TIME="$1"
                shift
                ;;
            --urgent)
                URGENT=true
                BUDGET_THRESHOLD=95
                shift
                ;;
            --surge)
                SURGE=true
                shift
                ;;
            --codex-wait)
                CODEX_WAIT=true
                shift
                ;;
            --pr-review)
                PR_REVIEW=true
                shift
                ;;
            --queue)
                QUEUE_MODE=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --prefer-sonnet)
                MODEL_PREFERENCE="sonnet"
                shift
                ;;
            --prefer-opus)
                MODEL_PREFERENCE="opus"
                shift
                ;;
            --desloppify)
                DESLOPPIFY=true
                shift
                ;;
            --pipeline)
                PIPELINE=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                # First non-flag arg: if no duration yet and it's a number, treat as minutes
                if [ -z "$DURATION_MIN" ] && [ -z "$UNTIL_TIME" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    DURATION_MIN="$1"
                else
                    task_parts+=("$1")
                fi
                shift
                ;;
        esac
    done

    TASK="${task_parts[*]}"

    if [ -z "$TASK" ]; then
        echo "Error: No task description provided"
        usage
    fi

    # Handle --until: compute minutes from now
    if [ -n "$UNTIL_TIME" ]; then
        compute_until_duration
    fi

    if [ -z "$DURATION_MIN" ]; then
        echo "Error: No duration specified (provide minutes or --until HH:MM)"
        usage
    fi

    # Compute SURGE targets based on flag combinations
    if [ "$SURGE" = true ]; then
        if [ "$URGENT" = true ]; then
            SURGE_SOFT_TARGET=95
            SURGE_HARD_CAP=99
            SURGE_RESUME_TARGET=50
        else
            SURGE_SOFT_TARGET=90
            SURGE_HARD_CAP=95
            SURGE_RESUME_TARGET=60
        fi
        # SURGE overrides BUDGET_THRESHOLD to the hard cap
        BUDGET_THRESHOLD="$SURGE_HARD_CAP"
    fi
}

compute_until_duration() {
    local now_epoch
    now_epoch=$(date +%s)

    # Parse target time (macOS date -j vs GNU date)
    local target_epoch
    if date -j -f "%H:%M" "$UNTIL_TIME" +%s >/dev/null 2>&1; then
        # macOS
        target_epoch=$(date -j -f "%H:%M" "$UNTIL_TIME" +%s 2>/dev/null)
    else
        # GNU/Linux
        target_epoch=$(date -d "$UNTIL_TIME" +%s 2>/dev/null)
    fi

    if [ -z "$target_epoch" ]; then
        echo "Error: Could not parse time '$UNTIL_TIME'. Use HH:MM format."
        exit 1
    fi

    # If target is in the past, assume next day
    if [ "$target_epoch" -le "$now_epoch" ]; then
        target_epoch=$((target_epoch + 86400))
    fi

    DURATION_MIN=$(( (target_epoch - now_epoch) / 60 ))

    if [ "$DURATION_MIN" -lt 1 ]; then
        echo "Error: Computed duration is less than 1 minute"
        exit 1
    fi

    log "Computed duration: ${DURATION_MIN}min (until $UNTIL_TIME)"
}

# ─── Signal Handling ─────────────────────────────────────────

cleanup() {
    log "Caught interrupt — shutting down"

    # Kill running Claude process
    if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
        kill "$CLAUDE_PID" 2>/dev/null || true
        wait "$CLAUDE_PID" 2>/dev/null || true
    fi

    # Kill running Codex process
    if [ -n "$CODEX_PID" ] && kill -0 "$CODEX_PID" 2>/dev/null; then
        kill "$CODEX_PID" 2>/dev/null || true
        wait "$CODEX_PID" 2>/dev/null || true
    fi

    # Clean up any stale state files
    cleanup_stale_state "$(pwd)"

    # Only stop timer if we own it (check launcher_pid matches)
    local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
    local owner_pid
    owner_pid=$(python3 -c "import json; print(json.load(open('$timer_file')).get('launcher_pid',0))" 2>/dev/null || echo "0")
    if [ "$owner_pid" = "$$" ]; then
        TIMED_SESSION_INSTANCE="$INSTANCE_ID" python3 "$TIMER_SCRIPT" stop 2>/dev/null || true
        log "Timer stopped (owned by this launcher)"
    else
        log "Timer NOT stopped (owned by PID $owner_pid, we are $$)"
    fi

    log "Launcher stopped"
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# ─── Graceful Stop (cooperative) ─────────────────────────────

check_stop_requested() {
    # Check if an external stop was requested via timed_session_manage.sh
    local stop_file="/tmp/timed-session-stop-${INSTANCE_ID}"
    if [ -f "$stop_file" ]; then
        local reason
        reason=$(cat "$stop_file" 2>/dev/null || echo "external request")
        rm -f "$stop_file"
        log "Graceful stop requested: $reason"
        return 0  # true = stop requested
    fi
    return 1  # false = no stop
}

# ─── Timer Helpers ───────────────────────────────────────────

check_timer() {
    # Returns: CONTINUE, WRAP_UP, TIME_UP, or NO_TIMER
    # CRITICAL: In launcher context, NO_TIMER is treated as an error
    # because the launcher created the timer. Use check_timer_file_directly()
    # as a fallback to avoid premature loop exit.
    local result
    result=$(TIMED_SESSION_INSTANCE="$INSTANCE_ID" python3 "$TIMER_SCRIPT" check 2>/dev/null || echo '{"status":"PYTHON_ERROR"}')
    local status
    status=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','PYTHON_ERROR'))" 2>/dev/null || echo "PYTHON_ERROR")

    # If python3 failed, fall back to direct file check
    if [ "$status" = "PYTHON_ERROR" ]; then
        log "WARNING: python3 timer check failed, falling back to direct file check"
        status=$(check_timer_file_directly)
    fi

    echo "$status"
}

check_timer_file_directly() {
    # Direct bash fallback: read the timer JSON file and check if time remains.
    # Used when python3 fails (e.g., PATH issues in nohup, corrupted env).
    local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
    if [ ! -f "$timer_file" ]; then
        echo "NO_TIMER"
        return
    fi

    # Check if timer is active
    local active
    active=$(python3 -c "import json; print(json.load(open('$timer_file')).get('active', False))" 2>/dev/null || echo "")
    if [ "$active" != "True" ]; then
        echo "NO_TIMER"
        return
    fi

    # Check remaining time using epoch comparison
    local now_epoch end_epoch
    now_epoch=$(date +%s)
    end_epoch=$(python3 -c "import json; print(int(json.load(open('$timer_file'))['end_ts']))" 2>/dev/null || echo "0")

    if [ "$end_epoch" -eq 0 ]; then
        # Can't even read the file — assume continue (fail-closed for launcher)
        echo "CONTINUE"
        return
    fi

    if [ "$now_epoch" -ge "$end_epoch" ]; then
        echo "TIME_UP"
    else
        echo "CONTINUE"
    fi
}

get_remaining_min() {
    local result
    result=$(TIMED_SESSION_INSTANCE="$INSTANCE_ID" python3 "$TIMER_SCRIPT" check 2>/dev/null || echo '{"remaining_min":0}')
    echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('remaining_min',0))" 2>/dev/null || echo "0"
}

# ─── Cooldown Calculation ────────────────────────────────────

compute_cooldown() {
    # Compute cooldown seconds before retrying after a rate-limited exit.
    # Checks BOTH five_hour (rolling 5h window) AND extra_usage (monthly credits).
    # Returns seconds to wait. Default 120, max 18000 (5 hours).
    python3 -c "
import json, os, sys, subprocess, time as _time
from datetime import datetime, timezone

default = 120
max_cd = 18000  # 5 hours max

def parse_iso(s):
    \"\"\"Parse ISO 8601 timestamp, handle both aware and naive.\"\"\"
    if not s:
        return None
    try:
        s = s.replace('Z', '+00:00')
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None

try:
    # Force-refresh cache (we just exited, need current data)
    cache_path = '$USAGE_CACHE'
    subprocess.run(
        ['python3', '$SCRIPTS_DIR/_refresh_usage_cache.py'],
        capture_output=True, timeout=10
    )

    if not os.path.exists(cache_path):
        print(default)
        sys.exit(0)
    with open(cache_path) as f:
        data = json.load(f)

    # Check extra_usage — when monthly credits are exhausted, the API rejects
    # ALL requests regardless of 5h window. Always use escalating backoff.
    extra = data.get('extra_usage', {})
    if extra.get('is_enabled') and float(extra.get('utilization', 0) or 0) >= 100:
        # Monthly exhausted — escalating backoff
        iteration = int(os.environ.get('TIMED_SESSION_ITERATION', '1'))
        backoffs = [300, 900, 1800, 3600]  # 5m, 15m, 30m, 60m
        idx = min(iteration - 1, len(backoffs) - 1)
        print(backoffs[idx])
        sys.exit(0)

    # Check five_hour rolling window
    five = data.get('five_hour', {})
    pct = float(five.get('utilization', 0) or 0)
    resets_at = five.get('resets_at', '')

    # If utilization is low, short cooldown (might have exited for other reasons)
    if pct < 50:
        print(30)
        sys.exit(0)

    reset_time = parse_iso(resets_at)
    if reset_time is None:
        # No reset time available — use default cooldown
        print(default)
        sys.exit(0)

    now = datetime.now(timezone.utc)
    seconds = int((reset_time - now).total_seconds()) + 30  # 30s buffer

    if seconds <= 0:
        print(30)  # Already reset
    elif seconds > max_cd:
        print(max_cd)
    else:
        print(max(30, seconds))
except Exception:
    print(default)
" 2>/dev/null || echo 120
}

# ─── SURGE Mode Functions ────────────────────────────────────

compute_surge_targets() {
    # Dynamically adjust SURGE soft target based on 7-day headroom.
    # Outputs: "<adjusted_soft_target> <current_five_pct>"
    python3 -c "
import json, os, sys
try:
    with open('$USAGE_CACHE') as f:
        data = json.load(f)
    five_pct = float(data.get('five_hour', {}).get('utilization', 0) or 0)
    seven_pct = float(data.get('seven_day', {}).get('utilization', 0) or 0)
    urgent = '$URGENT' == 'true'
    base = 95.0 if urgent else 90.0
    if seven_pct >= 80:
        target = min(base, 75.0)
    elif seven_pct >= 60:
        target = min(base, 85.0)
    elif seven_pct >= 40:
        target = base
    else:
        target = min(base + 2, 99.0)
    print(f'{target:.0f} {five_pct:.1f}')
except Exception:
    print('90 0')
" 2>/dev/null || echo "90 0"
}

compute_surge_stall() {
    # Compute stall duration: how long to wait for 5h window to decay to resume target.
    # Outputs: seconds to stall (clamped to [120, 7200])
    python3 -c "
import json, os, sys
from datetime import datetime, timezone

def parse_iso(s):
    if not s: return None
    try:
        s = s.replace('Z', '+00:00')
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None: dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except: return None

try:
    with open('$USAGE_CACHE') as f:
        data = json.load(f)
    five = data.get('five_hour', {})
    pct = float(five.get('utilization', 0) or 0)
    resets_at = five.get('resets_at', '')
    resume_target = float('$SURGE_RESUME_TARGET')

    reset_time = parse_iso(resets_at)
    if reset_time is None:
        # Fallback: fixed stall
        print(1800 if '$URGENT' != 'true' else 900)
        sys.exit(0)

    now = datetime.now(timezone.utc)
    secs_until_reset = max(0, (reset_time - now).total_seconds())

    if secs_until_reset <= 0:
        print(60)  # Already resetting
        sys.exit(0)

    # Proportional wait estimate for decay to resume_target
    if pct > 0:
        decay_fraction = (pct - resume_target) / pct
        wait = secs_until_reset * decay_fraction
    else:
        wait = 60

    # Clamp to [120, 7200]
    wait = max(120, min(int(wait), 7200))
    print(wait)
except Exception:
    print(1800)
" 2>/dev/null || echo 1800
}

get_five_pct() {
    # Get just the 5h utilization percentage as a float
    python3 -c "
import json
try:
    with open('$USAGE_CACHE') as f:
        d = json.load(f)
    print(float(d.get('five_hour', {}).get('utilization', 0) or 0))
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

# ─── Usage Cache Refresh ─────────────────────────────────────

refresh_usage_cache() {
    # Refresh the usage cache by calling the Anthropic API directly.
    # Critical for -p mode where statusline.py never runs.
    python3 "$SCRIPTS_DIR/_refresh_usage_cache.py" 2>/dev/null || true
}

get_usage_pct() {
    # Get current utilization summary from cache (call refresh_usage_cache first)
    python3 -c "
import json, os
try:
    with open('$USAGE_CACHE') as f:
        data = json.load(f)
    five = float(data.get('five_hour', {}).get('utilization', 0) or 0)
    extra = data.get('extra_usage', {})
    parts = [f'5h:{five:.0f}%']
    if extra.get('is_enabled'):
        eu = float(extra.get('utilization', 0) or 0)
        parts.append(f'extra:{eu:.0f}%')
    print(' '.join(parts))
except Exception:
    print('?')
" 2>/dev/null || echo "?"
}

# ─── Codex During Cooldown ───────────────────────────────────

should_use_codex() {
    # Check if Codex budget is available (< 50% utilization)
    python3 -c "
import json, os, sys
try:
    if not os.path.exists('$CODEX_USAGE_CACHE'):
        print('yes')  # No cache = assume available
        sys.exit(0)
    with open('$CODEX_USAGE_CACHE') as f:
        data = json.load(f)
    primary_pct = float(data.get('primary', {}).get('used_percent', 0) or 0)
    if primary_pct < 50:
        print('yes')
    else:
        print('no')
except Exception:
    print('yes')  # Default to available
" 2>/dev/null || echo "yes"
}

run_codex_during_wait() {
    local cooldown_secs="$1"
    local codex_timeout=$((cooldown_secs - 30))  # Stop 30s before cooldown ends

    if [ "$codex_timeout" -lt 30 ]; then
        log "Cooldown too short for Codex work (${cooldown_secs}s)"
        return
    fi

    # Check Codex budget before using it
    local codex_avail
    codex_avail=$(should_use_codex)
    if [ "$codex_avail" != "yes" ]; then
        log "Codex budget too high — skipping review during cooldown"
        return
    fi

    log "Running Codex review during cooldown (${codex_timeout}s timeout)"

    # Run Codex review in background
    (
        _timeout "$codex_timeout" codex review --uncommitted \
            --title "Review of autonomous session iteration $ITERATION" \
            > notes/codex-review.md 2>/dev/null
    ) &
    CODEX_PID=$!

    # Wait for Codex to finish or be killed
    wait "$CODEX_PID" 2>/dev/null || true
    CODEX_PID=""

    if [ -f "notes/codex-review.md" ] && [ -s "notes/codex-review.md" ]; then
        log "Codex review saved to notes/codex-review.md"
    fi
}

run_desloppify_during_wait() {
    local cooldown_secs="$1"
    local deslo_timeout=$((cooldown_secs - 30))

    if [ "$deslo_timeout" -lt 30 ]; then
        log "Cooldown too short for desloppify (${cooldown_secs}s)"
        return
    fi

    if ! command -v desloppify &>/dev/null; then
        log "Desloppify not installed — skipping (pip install desloppify[full])"
        return
    fi

    log "Running desloppify scan during cooldown (${deslo_timeout}s timeout)"

    (
        _timeout "$((deslo_timeout / 2))" desloppify scan --path . \
            > notes/desloppify-report.md 2>&1 || true

        _timeout "$((deslo_timeout / 2))" desloppify next \
            >> notes/desloppify-report.md 2>&1 || true
    ) &
    local DESLO_PID=$!
    wait "$DESLO_PID" 2>/dev/null || true

    if [ -f "notes/desloppify-report.md" ] && [ -s "notes/desloppify-report.md" ]; then
        log "Desloppify report saved to notes/desloppify-report.md"
        # Sync discovered issues to notes/issues.json
        python3 -c "
import json, os, hashlib
from datetime import datetime, timezone

issues_file = 'notes/issues.json'
issues = []
if os.path.exists(issues_file):
    try:
        with open(issues_file) as f:
            issues = json.load(f)
    except Exception:
        issues = []

existing_ids = {i.get('id') for i in issues}
report = open('notes/desloppify-report.md').read()
now = datetime.now(timezone.utc).isoformat()

for line in report.split('\n'):
    line = line.strip()
    if not line or line.startswith('#') or len(line) < 20:
        continue
    issue_id = 'deslo-' + hashlib.md5(line[:60].encode()).hexdigest()[:6]
    if issue_id not in existing_ids:
        issues.append({
            'id': issue_id,
            'status': 'open',
            'description': line[:200],
            'source': 'desloppify',
            'created': now,
            'updated': now,
        })
        existing_ids.add(issue_id)

os.makedirs('notes', exist_ok=True)
with open(issues_file, 'w') as f:
    json.dump(issues, f, indent=2)
" 2>/dev/null || true
    fi
}

run_codex_pr_review() {
    # Create/update a PR for the current branch and let Codex review it via
    # GitHub's native code review (uses separate weekly review quota).
    # If Codex requests changes, the codex-fix-loop.yml GitHub Action triggers
    # @codex fix automatically. We poll for completion then git pull.

    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$branch" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        log "PR review: skipped (on main/master branch or no git repo)"
        return
    fi

    # Check if we have any commits to push
    local unpushed
    unpushed=$(git log "origin/${branch}..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [ "$unpushed" -gt 0 ]; then
        log "PR review: pushing ${unpushed} unpushed commit(s)..."
        git push origin HEAD 2>/dev/null || {
            log "PR review: push failed — skipping PR review"
            return
        }
    fi

    # Check for existing open PR, or create one
    local pr_url
    pr_url=$(gh pr view --json url --jq '.url' 2>/dev/null || echo "")

    if [ -z "$pr_url" ]; then
        log "PR review: creating PR for branch ${branch}..."
        local task_summary="${TASK:-Autonomous session changes}"
        pr_url=$(gh pr create \
            --title "[auto] ${task_summary:0:60}" \
            --body "Automated PR from timed session launcher (iteration ${ITERATION})." \
            --base main 2>/dev/null || echo "")

        if [ -z "$pr_url" ]; then
            log "PR review: failed to create PR — skipping"
            return
        fi
        log "PR review: created $pr_url"
    else
        log "PR review: using existing PR $pr_url"
        # For existing PRs, auto-review only triggers on open/ready-for-review.
        # Subsequent pushes need an explicit @codex review comment.
        log "PR review: requesting Codex review on updated PR..."
        gh pr comment --body "@codex review" 2>/dev/null || true
    fi

    # Track review count for this week (local counter)
    local counter_file="/tmp/codex-pr-review-count-$(date +%Y-W%V).txt"
    local review_count
    review_count=$(cat "$counter_file" 2>/dev/null || echo "0")
    review_count=$((review_count + 1))
    echo "$review_count" > "$counter_file"
    log "PR review: week review count = $review_count"

    # Wait for Codex to post a review (poll every 30s, max 5 min)
    log "PR review: waiting for Codex review (polling every 30s, max 5min)..."
    local pr_number
    pr_number=$(gh pr view --json number --jq '.number' 2>/dev/null || echo "")
    if [ -z "$pr_number" ]; then
        log "PR review: could not determine PR number — skipping wait"
        return
    fi

    local waited=0
    local max_wait=300  # 5 minutes
    local review_state=""

    while [ "$waited" -lt "$max_wait" ]; do
        # Check for Codex review (look for any review from codex-related users)
        review_state=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" \
            --jq '[.[] | select(.user.login | test("codex|openai|chatgpt")) | .state] | last' \
            2>/dev/null || echo "")

        if [ -n "$review_state" ]; then
            log "PR review: Codex review state = $review_state"
            break
        fi

        sleep 30
        waited=$((waited + 30))
        log "PR review: still waiting... (${waited}s/${max_wait}s)"
    done

    if [ -z "$review_state" ]; then
        log "PR review: no Codex review received within ${max_wait}s — continuing"
        echo "No Codex PR review received within timeout." > notes/codex-pr-review.md
        return
    fi

    # If changes requested, wait for fix loop to complete (poll for approval or new commits)
    if [ "$review_state" = "CHANGES_REQUESTED" ]; then
        log "PR review: Codex requested changes — waiting for auto-fix loop..."
        local fix_waited=0
        local fix_max=300  # 5 minutes for fixes

        while [ "$fix_waited" -lt "$fix_max" ]; do
            sleep 30
            fix_waited=$((fix_waited + 30))

            # Check if a new review appeared (approved or another round)
            local latest_state
            latest_state=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" \
                --jq '[.[] | select(.user.login | test("codex|openai|chatgpt")) | .state] | last' \
                2>/dev/null || echo "")

            if [ "$latest_state" = "APPROVED" ]; then
                log "PR review: Codex approved after fix!"
                review_state="APPROVED"
                break
            fi

            # Check if new commits appeared (fix was pushed)
            local remote_sha
            remote_sha=$(git ls-remote origin "$branch" 2>/dev/null | cut -f1 || echo "")
            local local_sha
            local_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

            if [ -n "$remote_sha" ] && [ "$remote_sha" != "$local_sha" ]; then
                log "PR review: new commits detected from Codex fix — pulling..."
                git pull --rebase origin "$branch" 2>/dev/null || git pull origin "$branch" 2>/dev/null || true
                log "PR review: synced Codex fixes to local"
            fi

            log "PR review: fix loop waiting... (${fix_waited}s/${fix_max}s)"
        done
    fi

    # Pull any remaining remote changes (Codex fixes)
    local remote_sha local_sha
    remote_sha=$(git ls-remote origin "$branch" 2>/dev/null | cut -f1 || echo "")
    local_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$remote_sha" ] && [ "$remote_sha" != "$local_sha" ]; then
        log "PR review: final sync — pulling Codex fixes..."
        git pull --rebase origin "$branch" 2>/dev/null || git pull origin "$branch" 2>/dev/null || true
    fi

    # Save review summary for injection into next iteration
    {
        echo "## Codex PR Review (Iteration ${ITERATION})"
        echo ""
        echo "PR: ${pr_url}"
        echo "Review state: ${review_state}"
        echo ""
        echo "### Review Comments"
        gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" \
            --jq '[.[] | select(.user.login | test("codex|openai|chatgpt"))] | last | .body' \
            2>/dev/null || echo "(Could not fetch review body)"
    } > notes/codex-pr-review.md

    log "PR review: saved review to notes/codex-pr-review.md (state: ${review_state})"
}

run_codex_alignment_check() {
    # Compare task contract against actual work done. Detects goal drift.
    # Only runs if notes/task-contract.md exists (generated by /launch command).
    local contract="notes/task-contract.md"
    if [ ! -f "$contract" ]; then
        return
    fi

    log "Running Codex alignment check against task contract..."

    # Get recent changes (last 3 commits or all if < 3)
    local diff files_changed
    diff=$(git diff HEAD~3..HEAD --stat 2>/dev/null || git diff --stat 2>/dev/null || echo "No recent commits")
    files_changed=$(git diff HEAD~3..HEAD --name-only 2>/dev/null || echo "")

    # Build alignment prompt
    local contract_content
    contract_content=$(cat "$contract" 2>/dev/null || echo "Could not read contract")

    # Include original user request for stronger drift detection
    local original_request=""
    if [ -f "notes/original-request.md" ]; then
        original_request=$(head -c 500 notes/original-request.md 2>/dev/null || echo "")
    fi

    local prompt
    prompt="You are an alignment reviewer for an autonomous technical session.
Compare the TASK CONTRACT and ORIGINAL USER REQUEST against ACTUAL WORK DONE (git changes).

Report one of: ON_TRACK, DRIFTING, or OFF_TRACK.
If DRIFTING or OFF_TRACK, explain what went wrong and provide corrective guidance
that should be injected into the next iteration's prompt.

ORIGINAL USER REQUEST (verbatim):
${original_request}

TASK CONTRACT:
${contract_content}

RECENT WORK (git diff --stat):
${diff}

FILES CHANGED:
${files_changed}

Your response format:
STATUS: [ON_TRACK|DRIFTING|OFF_TRACK]
ASSESSMENT: [1-2 sentence summary]
CORRECTIVE_GUIDANCE: [only if DRIFTING/OFF_TRACK — specific instructions for next iteration]"

    # Call Codex CLI (_timeout 120s, read-only sandbox)
    _timeout 120 codex --approval-policy never --sandbox read-only "$prompt" \
        > notes/codex-alignment.md 2>/dev/null || true

    if [ -f "notes/codex-alignment.md" ] && [ -s "notes/codex-alignment.md" ]; then
        log "Codex alignment check saved to notes/codex-alignment.md"
        # Check for drift
        if grep -qi "DRIFTING\|OFF_TRACK" notes/codex-alignment.md 2>/dev/null; then
            log "WARNING: Codex detected goal drift! Corrective guidance will be injected."
        else
            log "Codex alignment: ON_TRACK"
        fi
    else
        log "Codex alignment check returned no output (may be unavailable)"
    fi
}

# ─── Model Selection ──────────────────────────────────────────

select_model() {
    # Returns "opus" or "sonnet" based on user preference and pipeline phase.
    # Priority: user override > engine phase routing > default (opus)
    local iter_num="${1:-1}"

    # User override always wins
    if [ -n "$MODEL_PREFERENCE" ]; then
        echo "$MODEL_PREFERENCE"
        return
    fi

    # Pipeline phase-aware routing via execution engine
    if [ "$PIPELINE" = true ] && [ -f "${EXECUTION_ENGINE:-}" ]; then
        # Read current phase from state file (cyclic pipeline, not hardcoded iterations)
        local phase_file="/tmp/timed-session-phase-${INSTANCE_ID:-$$}.txt"
        local phase
        if [ -f "$phase_file" ]; then
            phase=$(cat "$phase_file")
        elif [ "$iter_num" -eq 1 ]; then
            phase="research"
        else
            phase="implement"
        fi

        local route_result
        route_result=$(python3 "$EXECUTION_ENGINE" route "complex" "$phase" 2>/dev/null || echo "")
        if [ -n "$route_result" ]; then
            local routed_model
            routed_model=$(echo "$route_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model','claude'))" 2>/dev/null || echo "claude")
            # Map engine model names to launcher model names
            case "$routed_model" in
                claude) echo "opus"; return ;;
                codex)
                    # Codex runs as a separate tool, not as a Claude model.
                    # For launcher iterations, use opus but flag that Codex review should run.
                    echo "opus"; return ;;
            esac
        fi
    fi

    # Default: Opus for all iterations (quality over cost savings)
    echo "opus"
}

run_opus_quality_review() {
    # Short Opus review of Sonnet's work. Writes CLEAN or ISSUES_FOUND to notes/opus-review.md.
    # Skipped if: iteration was already Opus, or no meaningful changes.

    local diff
    diff=$(git diff HEAD~1..HEAD --stat 2>/dev/null || git diff --stat 2>/dev/null || echo "")
    if [ -z "$diff" ]; then
        log "Opus review: skipped (no changes to review)"
        return
    fi

    local full_diff
    full_diff=$(git diff HEAD~1..HEAD 2>/dev/null | head -c 8000 || git diff 2>/dev/null | head -c 8000 || echo "")

    local contract_summary=""
    if [ -f "notes/task-contract.md" ]; then
        contract_summary=$(head -c 500 notes/task-contract.md 2>/dev/null || echo "")
    fi

    log "Running Opus quality review of Sonnet's work..."

    local review_prompt
    review_prompt="You are reviewing code changes from an autonomous Sonnet iteration.

TASK CONTEXT:
${contract_summary}

CHANGES (git diff --stat):
${diff}

FULL DIFF (truncated):
${full_diff}

Review for: bugs, missed requirements, code quality issues, security concerns.
Report exactly one of:
- CLEAN: No significant issues found. [1 sentence summary]
- ISSUES_FOUND: [brief description of issues that need fixing]

Be concise — 3-5 sentences max."

    if [ -z "$CLAUDE_BIN" ]; then
        log "Opus review: skipped (claude binary not found)"
        return
    fi
    CLAUDECODE="" _timeout 90 "$CLAUDE_BIN" -p --model opus "$review_prompt" \
        --dangerously-skip-permissions --no-session-persistence \
        > notes/opus-review.md 2>/dev/null || true

    if [ -f "notes/opus-review.md" ] && [ -s "notes/opus-review.md" ]; then
        log "Opus review saved to notes/opus-review.md"
        if grep -qi "ISSUES_FOUND" notes/opus-review.md 2>/dev/null; then
            log "WARNING: Opus found issues — next iteration will escalate to Opus"
        else
            log "Opus review: CLEAN"
        fi
    else
        log "Opus review: no output (may have timed out)"
    fi
}

# ─── Test & Security Gates ─────────────────────────────────

discover_test_command() {
    # Discovers the project's test command from standard locations.
    # Prints the command string to stdout, or empty if none found.

    # 1. AGENTS.md — look for explicit test command
    if [ -f "AGENTS.md" ]; then
        local cmd
        cmd=$(grep -iA2 'run.*all\|test command\|run test' AGENTS.md 2>/dev/null \
            | grep -oE '`[^`]+`' | head -1 | tr -d '`' | xargs 2>/dev/null || true)
        if [ -n "$cmd" ] && [ "$cmd" != "command" ]; then
            echo "$cmd"; return
        fi
    fi

    # 2. Project CLAUDE.md
    if [ -f "CLAUDE.md" ]; then
        local cmd
        cmd=$(grep -iA2 'test command\|run test' CLAUDE.md 2>/dev/null \
            | grep -oE '`[^`]+`' | head -1 | tr -d '`' | xargs 2>/dev/null || true)
        if [ -n "$cmd" ] && [ "$cmd" != "command" ]; then
            echo "$cmd"; return
        fi
    fi

    # 3. package.json
    if [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
        echo "npm test"; return
    fi

    # 4. pytest
    if [ -f "pytest.ini" ] || ([ -f "pyproject.toml" ] && grep -q 'pytest' pyproject.toml 2>/dev/null); then
        echo "pytest"; return
    fi
    # Also check for tests/ directory with python files
    if [ -d "tests" ] && ls tests/*.py >/dev/null 2>&1; then
        echo "pytest"; return
    fi

    # 5. Cargo
    if [ -f "Cargo.toml" ]; then echo "cargo test"; return; fi

    # 6. Go
    if [ -f "go.mod" ]; then echo "go test ./..."; return; fi

    # 7. Makefile
    if [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
        echo "make test"; return
    fi

    echo ""
}

run_test_suite_gate() {
    # Between-iteration test gate. Runs test suite, measures coverage, tracks delta.
    # Writes structured report to notes/test-suite-report.md

    local test_cmd
    test_cmd=$(discover_test_command)

    if [ -z "$test_cmd" ]; then
        log "Test gate: no test command found (skipping)"
        cat > notes/test-suite-report.md <<'TESTREPORT'
TEST_STATUS: NO_TESTS_FOUND
ACTION_REQUIRED: This project has no discoverable test suite. Consider adding basic tests.
TESTREPORT
        return
    fi

    log "Test gate: running '$test_cmd'..."

    local test_output exit_code
    test_output=$(_timeout 180 bash -c "$test_cmd" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    # Parse results based on test framework
    local passed=0 failed=0 errors=0 status="ALL_PASSING" failing_tests="" raw_summary=""

    case "$test_cmd" in
        *pytest*)
            passed=$(echo "$test_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
            failed=$(echo "$test_output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)
            errors=$(echo "$test_output" | grep -oE '[0-9]+ error' | grep -oE '[0-9]+' || echo 0)
            raw_summary=$(echo "$test_output" | grep -E '=+.*=+' | tail -1 || true)
            failing_tests=$(echo "$test_output" | grep -E '^FAILED ' | head -20 || true)
            ;;
        *npm*test*|*jest*|*yarn*test*)
            passed=$(echo "$test_output" | grep -oiE 'Tests:.*[0-9]+ passed' | grep -oE '[0-9]+' | tail -1 || echo 0)
            failed=$(echo "$test_output" | grep -oiE 'Tests:.*[0-9]+ failed' | grep -oE '[0-9]+' | tail -1 || echo 0)
            raw_summary=$(echo "$test_output" | grep -i 'Tests:' | tail -1 || true)
            failing_tests=$(echo "$test_output" | grep -E '✕|✗|FAIL ' | head -20 || true)
            ;;
        *cargo*test*)
            passed=$(echo "$test_output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
            failed=$(echo "$test_output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)
            raw_summary=$(echo "$test_output" | grep 'test result:' | tail -1 || true)
            failing_tests=$(echo "$test_output" | grep -E '---- .* ----' | head -20 || true)
            ;;
        *go*test*)
            passed=$(echo "$test_output" | grep -c '^ok' || echo 0)
            failed=$(echo "$test_output" | grep -c '^FAIL' || echo 0)
            raw_summary="go test: $passed ok, $failed failed"
            failing_tests=$(echo "$test_output" | grep '^FAIL' | head -20 || true)
            ;;
        *)
            # Generic fallback
            if [ "$exit_code" -eq 0 ]; then
                passed=1; failed=0; raw_summary="Tests exited with code 0 (assumed passing)"
            else
                passed=0; failed=1; raw_summary="Tests exited with code $exit_code (assumed failing)"
                failing_tests=$(echo "$test_output" | tail -30)
            fi
            ;;
    esac

    [ "${failed:-0}" -gt 0 ] || [ "${errors:-0}" -gt 0 ] && status="FAILURES_DETECTED"

    # Attempt coverage measurement
    local coverage="" coverage_cmd=""
    case "$test_cmd" in
        *pytest*)
            if python3 -c "import pytest_cov" 2>/dev/null; then
                coverage_cmd="pytest --cov=. --cov-report=term-missing -q"
            fi
            ;;
        *npm*test*)
            if [ -f "node_modules/.bin/c8" ] || command -v c8 >/dev/null 2>&1; then
                coverage_cmd="npx c8 npm test"
            fi
            ;;
        *go*test*)
            coverage_cmd="go test -cover ./..."
            ;;
    esac

    if [ -n "$coverage_cmd" ]; then
        local cov_output
        cov_output=$(_timeout 180 bash -c "$coverage_cmd" 2>&1 || true)
        # Extract coverage percentage
        coverage=$(echo "$cov_output" | grep -oE '[0-9]+\.?[0-9]*%' | tail -1 | tr -d '%' || true)
    fi

    # Track coverage baseline
    local baseline_file="/tmp/claude-coverage-baseline-${INSTANCE_ID}.txt"
    local coverage_baseline="" coverage_delta=""
    if [ -n "$coverage" ]; then
        if [ -f "$baseline_file" ]; then
            coverage_baseline=$(cat "$baseline_file")
            coverage_delta=$(echo "$coverage - $coverage_baseline" | bc 2>/dev/null || echo "unknown")
        else
            echo "$coverage" > "$baseline_file"
            coverage_baseline="$coverage"
            coverage_delta="0 (baseline set)"
        fi
    fi

    # Write report
    mkdir -p notes
    cat > notes/test-suite-report.md <<TESTREPORT
TEST_STATUS: ${status}
PASSED: ${passed:-0}
FAILED: ${failed:-0}
ERRORS: ${errors:-0}
COMMAND: ${test_cmd}
COVERAGE: ${coverage:-unmeasurable}%
COVERAGE_BASELINE: ${coverage_baseline:-not set}%
COVERAGE_DELTA: ${coverage_delta:-unknown}
RAW_SUMMARY: ${raw_summary}
$([ -n "$failing_tests" ] && echo "FAILING_TESTS:
$failing_tests")
ACTION_REQUIRED: $(
    if [ "$status" = "FAILURES_DETECTED" ]; then
        echo "Fix these test failures BEFORE any new work. Failing tests are a P0 blocker."
    elif [ -n "$coverage_delta" ] && echo "$coverage_delta" | grep -q '^-'; then
        echo "Coverage regressed from ${coverage_baseline}% to ${coverage}%. Add tests to restore coverage before continuing."
    elif [ -n "$coverage" ] && [ "${coverage%.*}" -lt 50 ] 2>/dev/null; then
        echo "Coverage is low (${coverage}%). Add tests for new code this iteration (target +5-10%)."
    elif [ -n "$coverage" ]; then
        echo "Coverage is ${coverage}% (baseline: ${coverage_baseline}%). Target +5-10% improvement this iteration."
    else
        echo "Tests passing. Coverage unmeasurable — add tests for new code when possible."
    fi
)
TESTREPORT

    # Also write to standard location for test_results_capture hook compatibility
    cat > /tmp/claude-last-test-results.json <<TESTJSON
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","command":"${test_cmd}","passed":${passed:-0},"failed":${failed:-0},"errors":${errors:-0},"all_passed":$([ "$status" = "ALL_PASSING" ] && echo true || echo false),"coverage":"${coverage:-null}","raw_summary":"$(echo "$raw_summary" | tr '"' "'")"}
TESTJSON

    log "Test gate: ${status} (${passed:-0} passed, ${failed:-0} failed, coverage: ${coverage:-?}%)"
}

run_security_scan() {
    # Between-iteration security scan. Lightweight bash-native, no API calls.
    # Scans changed files for secrets and runs dependency audit if manifests changed.
    # Writes findings to notes/security-scan-report.md

    log "Security scan: checking for secrets and vulnerabilities..."

    local changed_files secrets_found="" dep_issues="" status="CLEAN"

    # Get files changed in recent commits (since last iteration, ~last 3 commits)
    changed_files=$(git diff HEAD~3..HEAD --name-only 2>/dev/null || git diff --name-only 2>/dev/null || echo "")

    if [ -z "$changed_files" ]; then
        log "Security scan: no changed files to scan"
        mkdir -p notes
        echo "SECURITY_STATUS: CLEAN (no changed files)" > notes/security-scan-report.md
        return
    fi

    # Secret patterns to scan for
    local secret_patterns='(sk-[a-zA-Z0-9]{20,}|AKIA[A-Z0-9]{16}|password\s*[=:]\s*["\x27][^"\x27]{4,}|token\s*[=:]\s*["\x27][^"\x27]{4,}|SECRET_KEY\s*[=:]\s*["\x27][^"\x27]+|api[_-]?key\s*[=:]\s*["\x27][^"\x27]+|-----BEGIN (RSA |EC )?PRIVATE KEY)'

    # Scan changed files (exclude test files, docs, and lockfiles)
    local scan_files
    scan_files=$(echo "$changed_files" | grep -vE '(test_|_test\.|\.test\.|spec\.|\.md$|\.txt$|\.lock$|lock\.json$)' || true)

    if [ -n "$scan_files" ]; then
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            local hits
            hits=$(grep -nE "$secret_patterns" "$f" 2>/dev/null || true)
            if [ -n "$hits" ]; then
                secrets_found="${secrets_found}${f}:
${hits}
"
                status="ISSUES_FOUND"
            fi
        done <<< "$scan_files"
    fi

    # Dependency audit if manifests changed
    if echo "$changed_files" | grep -qE 'package\.json|package-lock\.json'; then
        if command -v npm >/dev/null 2>&1; then
            local npm_audit
            npm_audit=$(_timeout 60 npm audit --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    vulns = d.get('metadata', {}).get('vulnerabilities', {})
    critical = vulns.get('critical', 0)
    high = vulns.get('high', 0)
    if critical + high > 0:
        print(f'{critical} critical, {high} high severity vulnerabilities')
except: pass
" 2>/dev/null || true)
            if [ -n "$npm_audit" ]; then
                dep_issues="npm: $npm_audit"
                status="ISSUES_FOUND"
            fi
        fi
    fi

    if echo "$changed_files" | grep -qE 'requirements\.txt|pyproject\.toml|setup\.py'; then
        if command -v pip-audit >/dev/null 2>&1; then
            local pip_issues
            pip_issues=$(_timeout 60 pip-audit 2>/dev/null | grep -c 'VULNERABLE' || echo 0)
            if [ "$pip_issues" -gt 0 ]; then
                dep_issues="${dep_issues:+$dep_issues; }pip: $pip_issues vulnerable packages"
                status="ISSUES_FOUND"
            fi
        fi
    fi

    # Write report
    mkdir -p notes
    cat > notes/security-scan-report.md <<SECREPORT
SECURITY_STATUS: ${status}
FILES_SCANNED: $(echo "$changed_files" | wc -l | xargs) files
$([ -n "$secrets_found" ] && echo "SECRETS_FOUND:
$secrets_found" || echo "SECRETS: None detected")
$([ -n "$dep_issues" ] && echo "DEPENDENCY_VULNERABILITIES: $dep_issues" || echo "DEPENDENCIES: Clean (or not checked)")
ACTION: $(
    if [ -n "$secrets_found" ]; then
        echo "CRITICAL: Hardcoded secrets detected. Remove them IMMEDIATELY — this is a P0 blocker."
    elif [ -n "$dep_issues" ]; then
        echo "Update vulnerable dependencies during this iteration."
    else
        echo "No security issues found."
    fi
)
SECREPORT

    log "Security scan: ${status}"
}

# ─── State File Cleanup ──────────────────────────────────────

cleanup_stale_state() {
    # Clean up any stale state files from previous launcher runs
    local work_dir="$1"
    # Nothing to clean currently — placeholder for future state files
    :
}

# ─── Progress Summary ───────────────────────────────────────

print_progress_summary() {
    # Parse stream-json log for a human-readable summary of this iteration
    if [ ! -f "$STREAM_LOG" ] || [ ! -s "$STREAM_LOG" ]; then
        log "No stream data to summarize"
        return
    fi

    local summary
    summary=$(python3 -c "
import json, sys

tools = {}
text_blocks = 0
errors = 0
total_cost = 0.0

for line in open('$STREAM_LOG'):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        t = e.get('type', '')
        if t == 'assistant':
            for c in e.get('message', {}).get('content', []):
                if c.get('type') == 'tool_use':
                    name = c.get('name', 'unknown')
                    tools[name] = tools.get(name, 0) + 1
                elif c.get('type') == 'text':
                    text_blocks += 1
        elif t == 'result':
            total_cost = e.get('total_cost_usd', 0) or 0
            if e.get('is_error'):
                errors += 1
    except Exception:
        pass

# Build summary
top_tools = sorted(tools.items(), key=lambda x: -x[1])[:5]
tool_str = ', '.join(f'{n}={c}' for n, c in top_tools)
print(f'Tools: {sum(tools.values())} calls ({tool_str})')
print(f'Text blocks: {text_blocks} | Errors: {errors} | Cost: \${total_cost:.2f}')
" 2>/dev/null || echo "Could not parse stream log")

    log "Progress: $summary"
}

inject_active_issues() {
    # Reads notes/issues.json, prints formatted block of open issues for prompt injection.
    # Returns empty if file missing, empty, or no open issues.
    local issues_file="notes/issues.json"
    [ -f "$issues_file" ] || return 0

    python3 -c "
import json, sys
try:
    with open('$issues_file') as f:
        issues = json.load(f)
    open_issues = [i for i in issues if i.get('status') == 'open']
    if not open_issues:
        sys.exit(0)
    print('═══ ACTIVE ISSUES (from notes/issues.json) ═══')
    for i in open_issues:
        src = i.get('source', 'unknown')
        desc = i.get('description', 'No description')
        print(f'  [{i[\"id\"]}] ({src}) {desc}')
    print()
    print('As you work, update notes/issues.json: set status to \"fixed\" when resolved,')
    print('\"wontfix\" if intentional, or \"deferred\" if deprioritized. Add new issues you discover')
    print('with status \"open\", a unique id (e.g. \"manual-xxxx\"), and source \"session\".')
    print('═══════════════════════════════════════════════')
except Exception:
    pass
" 2>/dev/null || true
}

# ─── Work Queue Helpers ──────────────────────────────────────

pop_next_queue_task() {
    # Pop the highest-priority pending task from workqueue.yaml.
    # Returns 0 if a task was found (sets QUEUE_TASK_* vars), 1 if queue empty.
    # Requires: PyYAML (pip install pyyaml)
    local queue_file="$WORKQUEUE_FILE"
    if [ ! -f "$queue_file" ]; then
        return 1
    fi

    local py="python3"

    local result_json
    result_json=$("$py" -c "
import sys, json
try:
    import yaml
except ImportError:
    sys.exit(1)

with open('$queue_file') as f:
    data = yaml.safe_load(f)

tasks = data.get('tasks', [])
settings = data.get('settings', {})
ceiling = settings.get('budget_ceiling_5h', 40)

# Find highest-priority pending task (lowest number = highest priority)
# Respect not_before gate — skip tasks whose time hasn't arrived
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
pending = []
for t in tasks:
    if t.get('status') != 'pending':
        continue
    nb = t.get('not_before')
    if nb:
        try:
            dt = datetime.fromisoformat(str(nb))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            if dt > now:
                continue  # not yet eligible
        except Exception:
            pass  # malformed — treat as eligible
    pending.append(t)
if not pending:
    sys.exit(1)

pending.sort(key=lambda t: t.get('priority', 5))
task = pending[0]

# Mark it as running in the file
task['status'] = 'running'
with open('$queue_file', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

# Output JSON payload for safe parsing in bash (no eval)
print(json.dumps({
    'id': str(task.get('id', 'unknown')),
    'project': str(task.get('project', '.')),
    'description': str(task.get('description', 'queued task')),
    'duration_min': int(task.get('duration_min', 60) or 60),
    'contract': str(task.get('contract', '')),
    'budget_ceiling_5h': float(ceiling),
}))
" 2>/dev/null) || return 1

    local parsed
    parsed=$("$py" -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(1)
print(d.get('id', 'unknown'))
print(d.get('project', '.'))
print(d.get('description', 'queued task'))
print(int(d.get('duration_min', 60) or 60))
print(d.get('contract', ''))
print(d.get('budget_ceiling_5h', 40))
" "$result_json" 2>/dev/null) || return 1

    {
        IFS= read -r QUEUE_TASK_ID
        IFS= read -r QUEUE_TASK_PROJECT
        IFS= read -r QUEUE_TASK_DESC
        IFS= read -r QUEUE_TASK_DURATION
        IFS= read -r QUEUE_TASK_CONTRACT
        IFS= read -r QUEUE_BUDGET_CEILING
    } <<< "$parsed"
    return 0
}

mark_queue_task_done() {
    # Mark the current queue task as completed (or partial if checker fails).
    # If an optional contract_completion_checker.py exists, use it for verification.
    local task_id="$1"
    local queue_file="$WORKQUEUE_FILE"
    [ ! -f "$queue_file" ] && return

    local py="python3"

    # Run optional contract completion checker (errors -> partial, missing checker -> completed)
    local checker="${SCRIPTS_DIR}/contract_completion_checker.py"
    local final_status="completed"
    local checker_result=""
    if [ -f "$checker" ]; then
        checker_result=$("$py" "$checker" "$task_id" --json 2>&1)
        local checker_exit=$?
        if [ $checker_exit -ne 0 ] || [ -z "$checker_result" ]; then
            final_status="partial"
            log "CONTRACT CHECKER ERROR for '$task_id' (exit=$checker_exit): defaulting to PARTIAL"
            log "  Output: $checker_result"
        else
            local verdict=$(echo "$checker_result" | "$py" -c "import sys,json; print(json.load(sys.stdin).get('verdict','FAIL'))" 2>/dev/null)
            local message=$(echo "$checker_result" | "$py" -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)
            if [ -z "$verdict" ]; then
                verdict="FAIL"
                log "CONTRACT CHECKER: JSON parse failed for '$task_id', defaulting to PARTIAL"
            fi

            if [ "$verdict" = "FAIL" ]; then
                final_status="partial"
                log "CONTRACT CHECK FAILED for '$task_id': $message"
                log "  Marking as 'partial' instead of 'completed'"
            else
                log "Contract check passed for '$task_id': $message"
            fi
        fi
    else
        log "No contract_completion_checker.py found — marking as completed (no verification)"
    fi

    "$py" -c "
import yaml, datetime
with open('$queue_file') as f:
    data = yaml.safe_load(f)
for t in data.get('tasks', []):
    if t.get('id') == '$task_id':
        t['status'] = '$final_status'
        t['completed_at'] = datetime.datetime.now().isoformat()
        break
with open('$queue_file', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
" 2>/dev/null || true
}

check_queue_budget() {
    # Check if budget is below the queue ceiling. Returns 0 if OK, 1 if too high.
    local ceiling="${1:-40}"
    local five_pct
    five_pct=$(python3 -c "
import json, sys
try:
    with open('/tmp/claude-usage-cache.json') as f:
        d = json.load(f)
    print(d.get('five_hour', {}).get('utilization', 0) or 0)
except: print(100)
" 2>/dev/null || echo "100")

    python3 -c "exit(0 if float('$five_pct') < float('$ceiling') else 1)" 2>/dev/null
}

# ─── Build Prompts ───────────────────────────────────────────

build_first_prompt() {
    local remaining
    remaining=$(get_remaining_min)
    local mode="normal"
    if [ "$URGENT" = true ]; then mode="urgent"; fi

    # Embed task contract directly if it exists (saves ~3min of file reading)
    local contract_embed=""
    if [ -f "notes/task-contract.md" ]; then
        local contract_content
        contract_content=$(head -c 2000 "notes/task-contract.md" 2>/dev/null || true)
        if [ -n "$contract_content" ]; then
            contract_embed="
═══ TASK CONTRACT (embedded for speed) ═══
${contract_content}
$([ "$(wc -c < "notes/task-contract.md" 2>/dev/null || echo 0)" -gt 2000 ] && echo "... [truncated — see notes/task-contract.md for full contract]")
═══════════════════════════════════════════
"
        fi
    fi

    # Pipeline/autoresearch mode: phase-aware injection for first iteration
    local pipeline_inject=""
    local phase_file="/tmp/timed-session-phase-${INSTANCE_ID:-$$}.txt"
    if [ "$PIPELINE" = true ]; then
        if [ "${PIPELINE_STRATEGY:-}" = "autoresearch" ]; then
            # Autoresearch mode: first iteration is setup
            echo "setup" > "$phase_file"
            pipeline_inject="
═══ AUTORESEARCH MODE ═══
This session runs an autonomous experiment loop (modify→run→eval→keep/discard).
THIS IS ITERATION 1 — SETUP PHASE.

Follow /autoresearch setup:
1. Read docs/autoresearch-pattern.md if present
2. Identify: eval harness (immutable metric), experiment file (agent-mutable), constraints
3. Create branch: autoresearch/<tag>
4. Initialize results.tsv with header
5. Run baseline (unmodified) to establish starting metric
6. Begin the experiment loop — NEVER STOP, loop until interrupted

Your task: $TASK
═══════════════════════════════
"
        else
            # Standard pipeline: first iteration is research
            echo "research" > "$phase_file"
            pipeline_inject="
═══ PIPELINE MODE ACTIVE (CYCLIC) ═══
This session uses cyclic pipeline execution (research→implement→review→loop if needed).
THIS IS ITERATION 1 — RESEARCH PHASE.

Your ONLY job this iteration:
1. Explore the codebase thoroughly (use subagents for parallel exploration)
2. Research patterns, dependencies, edge cases
3. Write notes/research-notes.md with architecture findings
4. Write notes/implementation-plan.md with step-by-step plan:
   - Files to modify/create
   - Key functions/classes to implement
   - Edge cases to handle
   - Test strategy
   - Estimated complexity per step
5. Commit and push both files

Do NOT write any implementation code. Research and plan ONLY.
The next iteration will implement based on your plan.
═══════════════════════════════
"
        fi
    fi

    cat <<PROMPT
You are running in an autonomous timed session via the launcher script.
Timer: ${DURATION_MIN}min total, ~${remaining}min remaining | Mode: ${mode} | Budget threshold: ${BUDGET_THRESHOLD}%

TASK: ${TASK}
${contract_embed}${pipeline_inject}
Do NOT jump straight into coding. Follow these phases in order:

═══ PHASE 1: ASSESS (first ~5 minutes) ═══
1. Read notes/task-contract.md if it exists — this is your SOURCE OF TRUTH for scope (already embedded above if present)
2. Read notes/original-request.md if it exists — the user's original verbatim request and clarifications
3. Read notes/resume-checkpoint.md if it exists — context from previous sessions
4. Read notes/codex-alignment.md and notes/codex-review.md if they exist — Codex feedback
5. Check current state: run full test suite, note pass/fail counts and coverage %.
   This is your BASELINE — you must leave tests BETTER than you found them.
6. Read recent git log (last 10 commits), scan key project files
7. Summarize: what's done, what's broken, test health, what needs attention
$(inject_active_issues)

═══ PHASE 2: PLAN WITH INTENT ALIGNMENT (~5-8 minutes) ═══
Before writing any code, reason through your approach WITH explicit intent tracing:

Step A — Intent reasoning (write this at the top of notes/current-plan.md):
  "The user's intent is: [restate from original-request.md / task-contract.md]"
  "Current state: [what exists, what's done from assessment]"
  "Therefore, this iteration should focus on: [logical next steps that serve the intent]"

Step B — Decompose into ordered work items:
1. For each item: what to do, which files, acceptance criterion
2. For each item: WHY does this serve the user's intent? (If you can't answer, don't do it)
3. Prioritize: highest-impact + most-feasible first. Risky items early (fail fast).
4. Budget time: don't plan more than 80% of remaining time

Step C — Codex plan review (if budget allows):
  Call Codex CLI (codex --approval-policy never --sandbox read-only) to review your plan:
  "Review this plan against the user's intent. Is every item aligned? Any drift risks?"
  If Codex flags issues, adjust the plan before executing.

═══ PHASE 3: EXECUTE (bulk of session) ═══
1. Work through plan items in order
2. For EACH item: implement → run tests → fix failures → verify coverage → commit → push
   - NEVER commit code that breaks existing tests
   - If you wrote new functions/modules, write tests for them BEFORE committing
   - If coverage drops below baseline, add tests to restore it
3. When tests fail or errors occur — follow the Debugging Protocol:
   a. TRIAGE: Read the full error. Run linter. Check git diff for recent changes.
   b. REPRODUCE: Re-run the failing command. If intermittent, note conditions.
   c. ISOLATE: Binary search — comment out code or run subset of tests to narrow the cause.
   d. INVESTIGATE: Read full logs. Add targeted debug logging if unclear. Check environment/deps.
   e. RESEARCH: If still stuck, web search the exact error message. Check library docs.
   f. FIX from evidence, not guessing. Remove debug logging. Verify with full test suite.
4. If you discover new work, ADD it to the plan first — don't start unplanned work silently
5. If an item takes 2x longer than expected, stop and reprioritize the plan
6. Periodically check: are your tests realistic?
   - Do they test behavior, not implementation details?
   - Do assertions check meaningful outcomes, not just "no error thrown"?
   - Would the test FAIL if the feature broke? If not, it's not a real test.
7. Use Codex for reviews when available (check budget first)

═══ PHASE 4: WRAP UP (when timer enters WRAP_UP or budget > ${BUDGET_THRESHOLD}%) ═══
1. Run full test suite — ALL tests must pass before wrapping up
2. Check coverage: did it grow this iteration? Report the delta.
3. If new code has no tests, write tests now (even basic behavioral ones)
4. Security scan: check for hardcoded secrets, run dependency audit if manifests changed
5. Commit and push ALL remaining changes (git push origin HEAD)
6. Update notes/current-plan.md (mark done items, note what remains)
7. Write detailed checkpoint to notes/resume-checkpoint.md
   Include in checkpoint: test pass count, coverage %, coverage delta from baseline

RULES:
- Work autonomously — NEVER ask user questions or use EnterPlanMode
- Commit and push after EVERY logical change (atomic push for rollback safety)
- The stop hook keeps you working until timer expires or budget threshold is reached
- If the task contract defines NOT-goals, do NOT drift into those areas
- Tests are fundamental: never trade test quality for speed
PROMPT
}

build_continue_prompt() {
    local remaining
    remaining=$(get_remaining_min)

    # Pipeline mode: inject phase-specific instructions for continuation iterations
    # Phase is determined by execution engine (cyclic), not hardcoded iteration numbers
    local pipeline_inject=""
    local phase_file="/tmp/timed-session-phase-${INSTANCE_ID:-$$}.txt"
    if [ "$PIPELINE" = true ]; then
        local current_phase="implement"
        if [ -f "$phase_file" ]; then
            current_phase=$(cat "$phase_file")
        fi

        # Use execution engine to determine next phase based on previous verdict
        local verdict_file="/tmp/timed-session-verdict-${INSTANCE_ID:-$$}.txt"
        if [ -f "${EXECUTION_ENGINE:-}" ] && [ -f "$verdict_file" ]; then
            local prev_verdict
            prev_verdict=$(cat "$verdict_file")
            local next_result
            next_result=$(python3 "$EXECUTION_ENGINE" next-phase "$current_phase" "$prev_verdict" --strategy "${PIPELINE_STRATEGY:-pipeline}" 2>/dev/null || echo '{"phase":"implement"}')
            current_phase=$(echo "$next_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('phase','implement'))" 2>/dev/null || echo "implement")
            log "CYCLIC PIPELINE: $current_phase (from verdict: $prev_verdict)"
            echo "$current_phase" > "$phase_file"
            rm -f "$verdict_file"
        fi

        case "$current_phase" in
            research)
                pipeline_inject="
═══ PIPELINE: RESEARCH PHASE (Iteration ${ITERATION}) ═══
Review found issues requiring re-research. Re-examine the approach.

1. Read notes/pipeline-review.md — what went wrong
2. Re-explore the codebase with fresh eyes
3. Update notes/research-notes.md with new findings
4. Update notes/implementation-plan.md with revised approach
5. Commit and push

Do NOT implement yet — plan first, then next iteration implements.
═══════════════════════════════════════════════════════════════════
"
                ;;
            implement)
                pipeline_inject="
═══ PIPELINE: IMPLEMENTATION PHASE (Iteration ${ITERATION}) ═══
Research is complete. Now IMPLEMENT based on the research.

1. Read notes/research-notes.md — architecture findings
2. Read notes/implementation-plan.md — your step-by-step plan
3. Follow the plan step by step — deviate only if you find a clear error
4. Write tests for every new function/class
5. Commit and push each logical unit of work

After implementation, if time remains: run Codex review (codex review --uncommitted).
If Codex returns SUBSTANTIVE_ISSUES, address them before stopping.
═══════════════════════════════════════════════════════════════════
"
                ;;
            review)
                pipeline_inject="
═══ PIPELINE: REVIEW PHASE (Iteration ${ITERATION}) ═══
Implementation is done. REVIEW and assess quality.

1. Read notes/research-notes.md and notes/implementation-plan.md
2. Review ALL code changes against the plan — were all steps implemented?
3. Run full test suite — fix any failures
4. Run Codex review (codex review --uncommitted) for cross-model quality check
5. Address any issues found by Codex (max 3 rounds)
6. Check edge cases, missing error handling, security
7. Write notes/pipeline-review.md with verdict (APPROVE / NEEDS_CHANGES / DESIGN_FLAW)
8. Write the verdict to the phase transition file so the next iteration routes correctly:
   echo '<verdict>' > /tmp/timed-session-verdict-${INSTANCE_ID}.txt
   - approve → session completes
   - needs_changes → loops back to implement
   - design_flaw → loops back to research
═══════════════════════════════════════════════════════════════════
"
                ;;
            experiment)
                pipeline_inject="
═══ AUTORESEARCH: EXPERIMENT LOOP (Iteration ${ITERATION}) ═══
Continue the autonomous experiment loop. NEVER STOP.

1. Read results.tsv — what experiments have been tried
2. Read the eval harness and experiment file for new ideas
3. Propose a change, commit, run, evaluate, keep/discard
4. Log results to results.tsv
5. Loop — do NOT ask if you should continue

Your task: $TASK
═══════════════════════════════════════════════════════════════════
"
                ;;
            done)
                pipeline_inject="
═══ PIPELINE COMPLETE ═══
Review approved. All phases done. Wrap up: final commit, push, write checkpoint.
═══════════════════════════════════════════════════════════════════
"
                ;;
        esac
    fi

    cat <<PROMPT
Continuing autonomous timed session. ~${remaining}min remaining (iteration ${ITERATION}).
${pipeline_inject}
═══ PHASE 1: RECONNECT (~3 minutes) ═══
1. Read notes/task-contract.md — your alignment boundaries
2. Read notes/original-request.md — the user's original verbatim request (ALWAYS re-read this)
3. Read notes/resume-checkpoint.md — where you left off
4. Read notes/current-plan.md — your work plan from previous iteration
5. Read notes/codex-alignment.md if it exists — Codex drift assessment
6. Read notes/codex-review.md if it exists — Codex code review from between iterations
7. Read notes/opus-review.md if it exists — Opus quality review of your last iteration
   → If ISSUES_FOUND: address these issues FIRST before continuing new work
8. Read notes/codex-pr-review.md if it exists — Codex PR review from GitHub
   → If CHANGES_REQUESTED: address review comments BEFORE continuing new work
9. Read notes/test-suite-report.md if it exists — test results from between iterations
   → If FAILURES_DETECTED: fix these regressions FIRST — they are a P0 blocker
   → If coverage dropped: restore coverage before continuing new work
   → If coverage flat: plan to add tests for new code this iteration (target +5-10%)
10. Read notes/security-scan-report.md if it exists — security scan results
    → If secrets found: fix IMMEDIATELY — this is a P0 blocker, remove before any other work
    → If vulnerable deps: schedule fix during this iteration
11. Read notes/desloppify-report.md if it exists — code quality scan from between iterations
    → If issues found: pick the top-priority issue and fix it this iteration
    → Use the exact guidance from the report for file, line, and fix approach
12. Read notes/refinement-critique.json if it exists — cross-model refinement critique
    → If SUBSTANTIVE_ISSUES: address ALL issues BEFORE continuing new work
    → If MINOR_ISSUES: fix inline during this iteration
    → If APPROVE: continue with confidence
$(inject_active_issues)
13. Run tests to verify current state matches the between-iteration report

═══ PHASE 2: ADJUST PLAN WITH INTENT CHAIN ═══
Build the sequential reasoning chain at the top of notes/current-plan.md:
  "The user's intent is: [restate from task-contract.md / original-request.md]"
  "In previous iterations, we accomplished: [list key completions]"
  "Codex alignment feedback: [ON_TRACK/DRIFTING/OFF_TRACK + guidance]"
  "Opus review feedback: [CLEAN or ISSUES_FOUND + summary]"
  "Codex PR review: [APPROVED or CHANGES_REQUESTED + summary]"
  "Test suite: [ALL_PASSING at X% coverage / FAILURES_DETECTED: N failing]"
  "Coverage delta from session start: [+X% / -X% / flat / unmeasurable]"
  "Security scan: [CLEAN / ISSUES_FOUND: summary]"
  "Therefore: [fix blockers first] [then continue intent-aligned work] [add tests for new code]"

Then adjust:
1. If tests are failing or secrets found: these are P0 — fix BEFORE any other work
2. If Codex flagged DRIFTING or OFF_TRACK, correct course BEFORE continuing
3. Update notes/current-plan.md — reorder, add, or remove items based on new context
4. If plan is complete, generate new items from the task contract
5. Call Codex CLI (codex --approval-policy never --sandbox read-only) to review adjusted plan if budget allows

═══ PHASE 3: EXECUTE ═══
1. Resume work through plan items in order
2. For EACH item: implement → run tests → fix failures → verify coverage → commit → push
   - NEVER commit code that breaks existing tests
   - If you wrote new functions/modules, write tests for them BEFORE committing
   - If coverage drops below baseline, add tests to restore it
3. When tests fail or errors occur — follow the Debugging Protocol:
   a. TRIAGE: Read the full error. Run linter. Check git diff for recent changes.
   b. REPRODUCE: Re-run the failing command. If intermittent, note conditions.
   c. ISOLATE: Binary search — comment out code or run subset of tests to narrow the cause.
   d. INVESTIGATE: Read full logs. Add targeted debug logging if unclear. Check environment/deps.
   e. RESEARCH: If still stuck, web search the exact error message. Check library docs.
   f. FIX from evidence, not guessing. Remove debug logging. Verify with full test suite.
4. Don't start unplanned work — add to plan first
5. Periodically check: are your tests realistic?
   - Test behavior, not implementation details
   - Assert meaningful outcomes, not just "no error"
   - Would the test FAIL if the feature broke? If not, rewrite it.

═══ PHASE 4: WRAP UP (when timer says WRAP_UP or budget high) ═══
1. Run full test suite — ALL tests must pass
2. Check coverage: did it grow this iteration? Report delta from baseline.
3. If new code has no tests, write tests now (even basic behavioral ones)
4. Security scan: check for hardcoded secrets in your changes
5. Commit and push ALL remaining changes
6. Update notes/current-plan.md and write checkpoint to notes/resume-checkpoint.md
   Include in checkpoint: test pass count, coverage %, coverage delta

RULES:
- Work autonomously — NEVER ask questions or use EnterPlanMode
- Commit and push after EVERY logical change (git push origin HEAD)
- Stay within the contract's scope. Do NOT drift into NOT-goals.
- Tests are fundamental: never trade test quality for speed
PROMPT
}

# ─── Main Loop ───────────────────────────────────────────────

main() {
    parse_args "$@"

    # ─── Multi-instance awareness ─────────────────────────
    # Warn about parallel launchers (separate tmux sessions, separate budgets).
    # No longer blocks — each session is independent.
    local active_instances=0
    local active_ids=""
    for timer_f in /tmp/claude-session-timer-*.json; do
        [ -f "$timer_f" ] || continue
        local other_id
        other_id=$(echo "$timer_f" | sed 's|.*timer-\(.*\)\.json|\1|')
        [ "$other_id" = "$INSTANCE_ID" ] && continue  # skip self
        local is_active
        is_active=$(python3 -c "
import json, time
try:
    d = json.load(open('$timer_f'))
    if d.get('active', False) and d.get('end_ts', 0) > time.time():
        print('yes')
    else:
        print('no')
except: print('no')
" 2>/dev/null || echo "no")
        if [ "$is_active" = "yes" ]; then
            active_instances=$((active_instances + 1))
            active_ids="${active_ids} ${other_id}"
        fi
    done
    if [ "$active_instances" -gt 0 ]; then
        echo "NOTE: ${active_instances} other launcher(s) also running:${active_ids}"
        echo "Parallel sessions use separate tmux windows. Budget burns ~${active_instances}x faster."
    fi

    log "═══════════════════════════════════════════════════"
    log "Timed Session Launcher starting"
    log "  Duration: ${DURATION_MIN}min"
    log "  Task: ${TASK}"
    log "  Urgent: ${URGENT} (threshold: ${BUDGET_THRESHOLD}%)"
    log "  Surge: ${SURGE} (soft: ${SURGE_SOFT_TARGET}%, hard: ${SURGE_HARD_CAP}%, resume: ${SURGE_RESUME_TARGET}%)"
    log "  Model preference: ${MODEL_PREFERENCE:-auto (opus for all iterations)}"
    log "  Codex wait: ${CODEX_WAIT}"
    log "  PR review: ${PR_REVIEW}"
    log "  Desloppify: ${DESLOPPIFY}"
    log "  Force: ${FORCE}"
    log "  Working dir: $(pwd)"
    log "  Instance ID: ${INSTANCE_ID}"
    log "═══════════════════════════════════════════════════"

    # Export instance ID so timer script and stop hook use instance-specific files
    export TIMED_SESSION_INSTANCE="$INSTANCE_ID"

    # Start timer and mark as launcher-owned (with PID for cleanup safety)
    local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
    log "Creating timer: TIMED_SESSION_INSTANCE=$INSTANCE_ID -> $timer_file"
    python3 "$TIMER_SCRIPT" start "$DURATION_MIN"
    local timer_start_rc=$?
    if [ "$timer_start_rc" -ne 0 ]; then
        log "FATAL: Timer start failed with rc=$timer_start_rc"
        exit 1
    fi
    if [ ! -f "$timer_file" ]; then
        log "FATAL: Timer file not created at $timer_file despite rc=0"
        log "  TIMED_SESSION_INSTANCE=$TIMED_SESSION_INSTANCE"
        log "  INSTANCE_ID=$INSTANCE_ID"
        log "  Files in /tmp/claude-session-timer-*:"
        ls -la /tmp/claude-session-timer-*.json 2>&1 | while read line; do log "    $line"; done
        # Check if it was created at the default path instead
        if [ -f "/tmp/claude-session-timer.json" ]; then
            log "  WARNING: Timer was created at DEFAULT path instead of instance path!"
            log "  Moving /tmp/claude-session-timer.json -> $timer_file"
            mv /tmp/claude-session-timer.json "$timer_file"
        else
            log "  Timer not at default path either. Creating manually."
            python3 -c "
import json, time
data = {
    'start_ts': time.time(),
    'end_ts': time.time() + $DURATION_MIN * 60,
    'duration_min': $DURATION_MIN,
    'active': True,
    'block_timestamps': [],
    'iteration': 0,
    'cwd': '$(pwd)'
}
with open('$timer_file', 'w') as f:
    json.dump(data, f, indent=2)
print('Timer manually created at $timer_file')
"
        fi
    fi
    # Add launcher ownership metadata
    python3 -c "
import json, os
with open('$timer_file') as f:
    data = json.load(f)
data['launcher'] = True
data['launcher_pid'] = $$
with open('$timer_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>&1 || log "WARNING: Failed to add launcher metadata to timer file"
    # Final verification
    if [ ! -f "$timer_file" ]; then
        log "FATAL: Timer file still missing after all recovery attempts"
        exit 1
    fi
    log "Timer file verified: $(cat "$timer_file" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f"active={d.get(\"active\")}, duration={d.get(\"duration_min\")}min")' 2>/dev/null || echo 'UNREADABLE')"

    # Write initial checkpoint so Claude knows the task
    mkdir -p notes
    cat > notes/resume-checkpoint.md <<EOF
## Resume Checkpoint (launcher-generated)

- **Task**: ${TASK}
- **Status**: Starting autonomous timed session (${DURATION_MIN}min)
- **Mode**: $([ "$SURGE" = true ] && echo "SURGE (soft:${SURGE_SOFT_TARGET}% hard:${SURGE_HARD_CAP}%)" || ([ "$URGENT" = true ] && echo "urgent (95% threshold)" || echo "normal (80% threshold)"))
- **Next Steps**: Begin working on the task immediately
- **Generated**: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

    log "Timer started, checkpoint written"

    # Export env vars for stop hook integration
    export TIMED_SESSION_BUDGET_THRESHOLD="$BUDGET_THRESHOLD"
    export TIMED_SESSION_LAUNCHER="1"  # tells stop hook this is a launcher session
    export TIMED_SESSION_INSTANCE="$INSTANCE_ID"  # tells stop hook which timer file to read

    # SURGE env vars for budget hooks
    if [ "$SURGE" = true ]; then
        export TIMED_SESSION_SURGE="1"
        export TIMED_SESSION_SURGE_SOFT_TARGET="$SURGE_SOFT_TARGET"
        # Write surge marker so hooks in -p mode can detect SURGE
        python3 -c "
import sys
sys.path.insert(0, '$SCRIPTS_DIR')
from _budget_common import write_surge_marker
write_surge_marker(
    soft_target=$SURGE_SOFT_TARGET,
    hard_cap=$SURGE_HARD_CAP,
    resume_target=$SURGE_RESUME_TARGET,
    reason='launcher'
)
" 2>/dev/null || true
        log "SURGE marker written (soft:${SURGE_SOFT_TARGET}% hard:${SURGE_HARD_CAP}% resume:${SURGE_RESUME_TARGET}%)"
    fi

    # Unset CLAUDECODE to allow nested invocation
    unset CLAUDECODE 2>/dev/null || true

    # Clear stream log for this session
    : > "$STREAM_LOG"

    # ─── Claude binary check (uses global CLAUDE_BIN from top of script) ───
    if [ -z "$CLAUDE_BIN" ]; then
        log "FATAL: Cannot find 'claude' binary in any expected location"
        log "Checked: /usr/local/bin, /opt/homebrew/bin, ~/.local/bin, ~/.npm-global/bin, PATH"
        log "Install with: npm install -g @anthropic-ai/claude-code"
        # Send local notification about the failure
        terminal-notifier -title "Claude Launcher FAILED" -message "claude binary not found" -sound Basso 2>/dev/null || true
        exit 1
    fi
    log "Claude binary: $CLAUDE_BIN"

    # ─── Auto-classify task via unified execution engine ──────
    local ENGINE="${SCRIPTS_DIR}/_execution_engine.py"
    local auto_strategy="direct"
    if [ "$PIPELINE" != true ] && [ -f "$ENGINE" ]; then
        local classification
        classification=$(python3 "$ENGINE" classify "$TASK" 2>/dev/null || echo '{}')
        auto_strategy=$(echo "$classification" | python3 -c "import sys,json; print(json.load(sys.stdin).get('strategy','direct'))" 2>/dev/null || echo "direct")
        local auto_reason
        auto_reason=$(echo "$classification" | python3 -c "import sys,json; print(json.load(sys.stdin).get('reason',''))" 2>/dev/null || echo "")

        if [ "$auto_strategy" = "pipeline" ]; then
            PIPELINE=true
            log "ENGINE: Auto-activated pipeline mode — $auto_reason"
        elif [ "$auto_strategy" = "autoresearch" ]; then
            PIPELINE=true  # Autoresearch uses pipeline infrastructure for phase injection
            log "ENGINE: Auto-activated autoresearch mode — $auto_reason"
        elif [ "$auto_strategy" = "bug_hunt" ]; then
            PIPELINE=true  # Bug hunt uses pipeline infrastructure
            log "ENGINE: Auto-activated bug hunt pipeline — $auto_reason"
        elif [ "$auto_strategy" = "lightweight" ]; then
            log "ENGINE: Lightweight mode (plan-then-code with review) — $auto_reason"
        else
            log "ENGINE: Direct mode — $auto_reason"
        fi
    elif [ "$PIPELINE" = true ]; then
        log "Pipeline mode: explicitly enabled via --pipeline flag"
    fi

    # ─── Phase-aware model routing ────────────────────────────
    # Store engine path for use in model selection and prompts
    export EXECUTION_ENGINE="$ENGINE"
    export PIPELINE_STRATEGY="${auto_strategy:-direct}"

    # Restart loop
    local consecutive_failures=0
    local MAX_CONSECUTIVE_FAILURES=5
    local MAX_INSTANT_FAILURES=2  # Bail faster for instant exits (code 127, ran 0s)

    while true; do
        # Check timer
        local status
        status=$(check_timer)
        log "Timer check: status=$status"
        if [ "$status" = "TIME_UP" ]; then
            log "Timer expired — session complete"
            break
        elif [ "$status" = "NO_TIMER" ]; then
            # In launcher context, NO_TIMER is abnormal — we just created the timer.
            # Retry with direct file check, and if first iteration, try recovery.
            log "WARNING: check_timer returned NO_TIMER unexpectedly"
            local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
            log "  Timer file exists: $([ -f "$timer_file" ] && echo 'YES' || echo 'NO')"
            log "  TIMED_SESSION_INSTANCE=$TIMED_SESSION_INSTANCE"
            log "  INSTANCE_ID=$INSTANCE_ID"

            # On first iteration, wait briefly and retry (race condition mitigation)
            if [ "$ITERATION" -eq 0 ]; then
                log "First iteration NO_TIMER — waiting 2s and retrying..."
                sleep 2
                status=$(check_timer)
                log "Retry after wait: status=$status"
                if [ "$status" = "CONTINUE" ] || [ "$status" = "SPRINT" ] || [ "$status" = "CRUISE" ] || [ "$status" = "WRAP_UP" ]; then
                    log "Timer recovered after retry. Proceeding."
                elif [ ! -f "$timer_file" ]; then
                    # Timer file truly gone — recreate it
                    log "Timer file missing. Recreating timer for ${DURATION_MIN}min..."
                    TIMED_SESSION_INSTANCE="$INSTANCE_ID" python3 "$TIMER_SCRIPT" start "$DURATION_MIN"
                    if [ -f "$timer_file" ]; then
                        log "Timer recreated successfully."
                    else
                        log "FATAL: Cannot create timer file. Exiting."
                        break
                    fi
                else
                    log "Timer file exists but not active. Continuing anyway."
                fi
            else
                local direct_status
                direct_status=$(check_timer_file_directly)
                log "Direct file check: status=$direct_status"
                if [ "$direct_status" = "TIME_UP" ]; then
                    log "Timer expired (confirmed by direct check) — session complete"
                    break
                elif [ "$direct_status" = "CONTINUE" ]; then
                    log "Timer still active (direct check). Proceeding despite NO_TIMER."
                else
                    log "Timer genuinely gone — session complete"
                    break
                fi
            fi
        fi

        # Check for external graceful stop request (from timed_session_manage.sh)
        if check_stop_requested; then
            break
        fi

        local remaining
        remaining=$(get_remaining_min)
        ITERATION=$((ITERATION + 1))

        export TIMED_SESSION_ITERATION="$ITERATION"
        log "─── Iteration $ITERATION (${remaining}min remaining) ───"

        # SURGE pre-flight: check if already at/above soft target
        if [ "$SURGE" = true ]; then
            refresh_usage_cache
            local surge_data
            surge_data=$(compute_surge_targets)
            SURGE_SOFT_TARGET=$(echo "$surge_data" | awk '{print $1}')
            local preflight_five
            preflight_five=$(echo "$surge_data" | awk '{print $2}')
            log "SURGE pre-flight: 5h=${preflight_five}%, soft_target=${SURGE_SOFT_TARGET}%, hard_cap=${SURGE_HARD_CAP}%"

            if python3 -c "exit(0 if float('$preflight_five') >= float('$SURGE_SOFT_TARGET') else 1)" 2>/dev/null; then
                log "SURGE: Usage at ${preflight_five}% >= soft target ${SURGE_SOFT_TARGET}% — proactive stall"
                local stall_secs
                stall_secs=$(compute_surge_stall)
                log "SURGE STALL: Waiting ${stall_secs}s for window decay (resume target: ${SURGE_RESUME_TARGET}%)"

                # Check if stall exceeds remaining time
                local remaining_secs
                remaining_secs=$(python3 -c "print(int(float('$remaining') * 60))" 2>/dev/null || echo "0")
                if [ "$remaining_secs" -lt "$stall_secs" ]; then
                    log "SURGE: Stall (${stall_secs}s) exceeds remaining time (${remaining_secs}s) — ending session"
                    break
                fi

                sleep "$stall_secs"

                # Re-check after stall
                refresh_usage_cache
                local post_stall_pct
                post_stall_pct=$(get_five_pct)
                log "SURGE: Post-stall 5h usage: ${post_stall_pct}%"

                if python3 -c "exit(0 if float('$post_stall_pct') >= float('$SURGE_HARD_CAP') else 1)" 2>/dev/null; then
                    log "SURGE: Still above hard cap after stall — re-entering loop"
                    continue
                fi
                log "SURGE: Resuming (below hard cap after stall)"
            fi
        fi

        # Build prompt
        local prompt
        if [ "$ITERATION" -eq 1 ]; then
            prompt=$(build_first_prompt)
        else
            prompt=$(build_continue_prompt)
        fi

        # Select model (Opus default for all iterations, Sonnet only via --prefer-sonnet override)
        local model
        model=$(select_model "$ITERATION")

        # Launch Claude in -p mode with stream-json for real-time visibility
        local claude_args=("-p" "$prompt" "--model" "$model" "--fallback-model" "sonnet" "--output-format" "stream-json" "--verbose" "--dangerously-skip-permissions")
        if [ "$ITERATION" -gt 1 ]; then
            claude_args+=("--continue")
        fi

        log "Launching: $CLAUDE_BIN -p --model $model --fallback-model sonnet --stream-json (iter $ITERATION)..."
        log "Monitor with: ~/.claude/scripts/timed_session_monitor.sh"
        local exec_start
        exec_start=$(date +%s)
        "$CLAUDE_BIN" "${claude_args[@]}" >> "$STREAM_LOG" 2>&1 &
        CLAUDE_PID=$!

        # Wait for Claude to finish
        local exit_code=0
        wait "$CLAUDE_PID" || exit_code=$?
        CLAUDE_PID=""
        local exec_end exec_secs
        exec_end=$(date +%s)
        exec_secs=$((exec_end - exec_start))

        log "Claude exited (code: $exit_code)"

        # Print progress summary from stream-json
        print_progress_summary

        # ─── Stall detection ─────────────────────────────────────
        # If Claude ran >120s but produced 0 tool calls, it was likely stalled
        # (e.g., spinning on context, waiting for something, or stuck in a loop)
        local tool_count=0
        if [ -f "$STREAM_LOG" ] && [ -s "$STREAM_LOG" ]; then
            tool_count=$(python3 -c "
import json
count = 0
for line in open('$STREAM_LOG'):
    try:
        e = json.loads(line.strip())
        if e.get('type') == 'assistant':
            for c in e.get('message', {}).get('content', []):
                if c.get('type') == 'tool_use':
                    count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo "0")
        fi

        if [ "$exit_code" -eq 0 ] && [ "$exec_secs" -gt 120 ] && [ "$tool_count" -eq 0 ]; then
            log "STALL DETECTED: Ran ${exec_secs}s but produced 0 tool calls"
            log "This iteration was unproductive — Claude may have been stuck"
            consecutive_failures=$((consecutive_failures + 1))
            if [ "$consecutive_failures" -ge 2 ]; then
                log "Multiple stalled iterations — ending session to avoid wasting time"
                terminal-notifier -title "Claude Launcher" -message "Session ended: stalled (0 tool calls)" -sound Basso 2>/dev/null || true
                break
            fi
        fi

        # Refresh usage cache (critical — statusline.py doesn't run in -p mode)
        refresh_usage_cache
        log "Usage after exit: $(get_usage_pct)"

        # Detect rate limit from stream log
        local is_rate_limit=false
        if [ "$exit_code" -ne 0 ]; then
            if grep -q "hit your limit\|rate limit\|Too many requests\|429" "$STREAM_LOG" 2>/dev/null; then
                is_rate_limit=true
                log "Rate limit detected in stream log"
            fi
        fi

        # Classify exit type for cooldown routing
        # GRACEFUL: code=0, ran >60s → context exhaustion, normal completion
        # QUICK_EXIT: code=0, ran <60s → something odd, be cautious
        # RATE_LIMITED: code=1 + rate limit in stream → API rate limit
        # COMMAND_NOT_FOUND: code=127 → binary missing, unrecoverable
        # ERROR: code=1, no rate limit marker → unexpected error
        local exit_type="UNKNOWN"
        if [ "$exit_code" -eq 127 ]; then
            exit_type="COMMAND_NOT_FOUND"
        elif [ "$exit_code" -eq 0 ]; then
            if [ "$exec_secs" -gt 60 ]; then
                exit_type="GRACEFUL"
            else
                exit_type="QUICK_EXIT"
            fi
        elif [ "$is_rate_limit" = true ]; then
            exit_type="RATE_LIMITED"
        else
            exit_type="ERROR"
        fi
        log "Exit classification: $exit_type (ran ${exec_secs}s)"

        # FATAL: exit code 127 = command not found — bail immediately
        if [ "$exit_type" = "COMMAND_NOT_FOUND" ]; then
            log "FATAL: claude binary not found (exit 127). Cannot recover by retrying."
            log "Verify claude is installed: npm install -g @anthropic-ai/claude-code"
            terminal-notifier -title "Claude Launcher FATAL" -message "claude binary not found (exit 127)" -sound Basso 2>/dev/null || true
            break
        fi

        # Predictive rate limit warning
        local five_pct
        five_pct=$(python3 -c "
import json, os
try:
    with open('$USAGE_CACHE') as f:
        d = json.load(f)
    print(int(float(d.get('five_hour', {}).get('utilization', 0) or 0)))
except Exception:
    print(0)
" 2>/dev/null || echo "0")
        if [ "$five_pct" -ge 85 ]; then
            log "WARNING: 5h usage at ${five_pct}% — high rate limit risk on next iteration"
        elif [ "$five_pct" -ge 70 ]; then
            log "NOTE: 5h usage at ${five_pct}% — approaching rate limit zone"
        fi

        # Check timer again after Claude exits
        status=$(check_timer)
        log "Post-exit timer check: status=$status"
        if [ "$status" = "TIME_UP" ]; then
            log "Timer expired after Claude exit — session complete"
            break
        elif [ "$status" = "NO_TIMER" ]; then
            # Timer gone after Claude exit — might be a bug. Do direct check.
            local direct_status
            direct_status=$(check_timer_file_directly)
            log "Post-exit direct file check: status=$direct_status"
            if [ "$direct_status" = "CONTINUE" ]; then
                log "Timer still active (direct check). Continuing despite NO_TIMER."
            elif [ "$direct_status" = "TIME_UP" ]; then
                log "Timer expired (direct check) — session complete"
                break
            else
                # Genuinely no timer — reactivate it if we're within the original window
                local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
                if [ -f "$timer_file" ]; then
                    log "Reactivating timer (file exists but inactive)"
                    python3 -c "
import json
with open('$timer_file') as f:
    data = json.load(f)
import time
if data.get('end_ts', 0) > time.time():
    data['active'] = True
    with open('$timer_file', 'w') as f:
        json.dump(data, f, indent=2)
    print('reactivated')
else:
    print('expired')
" 2>/dev/null
                else
                    log "Timer file gone — session complete"
                    break
                fi
            fi
        fi

        # Check for external graceful stop request (post-iteration)
        if check_stop_requested; then
            break
        fi

        # Track consecutive failures for safety
        if [ "$exit_code" -ne 0 ] && [ "$is_rate_limit" = false ]; then
            consecutive_failures=$((consecutive_failures + 1))
            # Instant failures (ran 0-1s) are likely unrecoverable — bail faster
            local effective_max="$MAX_CONSECUTIVE_FAILURES"
            if [ "$exec_secs" -le 1 ]; then
                effective_max="$MAX_INSTANT_FAILURES"
                log "Instant failure ($consecutive_failures/$effective_max) — ran ${exec_secs}s, likely unrecoverable"
            else
                log "Non-rate-limit failure ($consecutive_failures/$effective_max)"
            fi
            if [ "$consecutive_failures" -ge "$effective_max" ]; then
                log "Too many consecutive failures — ending session"
                terminal-notifier -title "Claude Launcher" -message "Session ended: ${consecutive_failures} consecutive errors" -sound Basso 2>/dev/null || true
                break
            fi
        else
            consecutive_failures=0
        fi

        # Timer still active — route cooldown by exit type
        local cooldown
        case "$exit_type" in
            GRACEFUL)
                # Context exhaustion or normal completion — short cooldown
                cooldown=60
                log "Graceful exit (${exec_secs}s) — using short cooldown (${cooldown}s)"
                ;;
            RATE_LIMITED)
                # API rate limit — use API-based cooldown from resets_at
                cooldown=$(compute_cooldown)
                log "Rate limit exit — computed cooldown: ${cooldown}s"
                ;;
            QUICK_EXIT)
                # Suspiciously fast exit — use moderate API-based cooldown
                cooldown=$(compute_cooldown)
                log "Quick exit (${exec_secs}s) — computed cooldown: ${cooldown}s"
                ;;
            ERROR)
                # Unexpected error — exponential backoff (inspired by OpenClaw)
                # 60s → 120s → 300s → 600s → 900s based on consecutive failures
                local error_backoffs=(60 120 300 600 900)
                local backoff_idx=$((consecutive_failures - 1))
                if [ "$backoff_idx" -lt 0 ]; then backoff_idx=0; fi
                if [ "$backoff_idx" -ge ${#error_backoffs[@]} ]; then backoff_idx=$(( ${#error_backoffs[@]} - 1 )); fi
                cooldown=${error_backoffs[$backoff_idx]}
                log "Error exit — exponential backoff: ${cooldown}s (failure #${consecutive_failures})"
                ;;
            *)
                cooldown=$(compute_cooldown)
                log "Unknown exit type — computed cooldown: ${cooldown}s"
                ;;
        esac

        # SURGE: override cooldown if at/above soft target — proactive stall
        if [ "$SURGE" = true ]; then
            local post_exit_five
            post_exit_five=$(get_five_pct)
            if python3 -c "exit(0 if float('$post_exit_five') >= float('$SURGE_SOFT_TARGET') else 1)" 2>/dev/null; then
                local surge_stall
                surge_stall=$(compute_surge_stall)
                log "SURGE: Post-exit 5h at ${post_exit_five}% >= soft target ${SURGE_SOFT_TARGET}% — proactive stall: ${surge_stall}s"
                cooldown=$surge_stall
            fi
        fi

        # Add jitter only when multiple instances are running (multi-instance safety)
        local jitter=0
        local other_instances
        other_instances=$(ls /tmp/claude-session-timer-*.json 2>/dev/null | grep -cv "${INSTANCE_ID}" 2>/dev/null || echo "0")
        if [ "$other_instances" -gt 0 ]; then
            jitter=$((RANDOM % 46))
            cooldown=$((cooldown + jitter))
        fi

        remaining=$(get_remaining_min)
        local remaining_secs
        remaining_secs=$(python3 -c "print(int(float('$remaining') * 60))" 2>/dev/null || echo "0")

        # If rate limit and remaining_secs is 0 (fallback), use end_ts directly
        if [ "$remaining_secs" -eq 0 ] && [ "$is_rate_limit" = true ]; then
            local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
            remaining_secs=$(python3 -c "
import json, time
with open('$timer_file') as f:
    d = json.load(f)
print(max(0, int(d['end_ts'] - time.time())))
" 2>/dev/null || echo "0")
            remaining=$(python3 -c "print(round($remaining_secs / 60, 1))" 2>/dev/null || echo "0")
            log "Computed remaining from file: ${remaining}min (${remaining_secs}s)"
        fi

        # Skip restart if remaining time < cooldown (includes jitter)
        if [ "$remaining_secs" -lt "$cooldown" ]; then
            log "Remaining time (${remaining}min) < cooldown (${cooldown}s incl jitter) — ending session"
            break
        fi

        if [ "$jitter" -gt 0 ]; then
            log "Cooldown: ${cooldown}s (includes ${jitter}s jitter — ${other_instances} other instance(s) detected)"
        else
            log "Cooldown: ${cooldown}s"
        fi

        # Run Codex alignment check if task contract exists (always, regardless of --codex-wait)
        if [ -f "notes/task-contract.md" ]; then
            run_codex_alignment_check
        fi

        # Run Opus quality review of Sonnet's work (quality gate)
        if [ "$model" = "sonnet" ]; then
            run_opus_quality_review
        fi

        # Run Codex code review: always when Sonnet was used (quality gate), or with --codex-wait
        if [ "$model" = "sonnet" ] || [ "$CODEX_WAIT" = true ]; then
            run_codex_during_wait "$cooldown"
        fi

        # Run Codex PR review via GitHub (uses separate weekly review quota)
        if [ "$PR_REVIEW" = true ]; then
            run_codex_pr_review
        fi

        # Run desloppify code quality scan during cooldown
        if [ "$DESLOPPIFY" = true ]; then
            run_desloppify_during_wait "$cooldown"
        fi

        # Run refinement critique (pipeline mode, iteration 2+)
        # Brings conductor's cross-model refinement into launched sessions
        if [ "$PIPELINE" = true ] && [ "$ITERATION" -ge 2 ] && [ -f "${EXECUTION_ENGINE:-}" ]; then
            if should_use_codex; then
                log "Running cross-model refinement critique (pipeline iter $ITERATION)..."
                local critique_model="codex"
                if [ "$model" = "sonnet" ] || [ "$model" = "opus" ]; then
                    critique_model="codex"  # Claude produced → Codex critiques
                fi
                local round_num=$((ITERATION - 1))
                local critique_timeout=120
                (
                    _timeout "$critique_timeout" codex exec -s read-only --json \
                        "You are reviewing code changes from an autonomous session.

Review ALL uncommitted changes and recent commits. Produce a structured critique:

1. Verdict: APPROVE, MINOR_ISSUES, or SUBSTANTIVE_ISSUES
2. Issues found: list each with severity (critical/high/medium/low)
3. Suggestions: concrete, actionable improvements
4. Score: 1-10 quality rating

Write your review as JSON to stdout:
{\"verdict\": \"...\", \"score\": N, \"issues\": [{\"severity\": \"...\", \"description\": \"...\", \"file\": \"...\", \"suggestion\": \"...\"}], \"summary\": \"...\"}" \
                        > "notes/refinement-critique.json" 2>/dev/null
                ) &
                local refine_pid=$!
                wait "$refine_pid" 2>/dev/null || true
                if [ -f "notes/refinement-critique.json" ] && [ -s "notes/refinement-critique.json" ]; then
                    log "Refinement critique saved to notes/refinement-critique.json"
                else
                    log "Refinement critique: no output (skipped or timed out)"
                fi
            fi
        fi

        # Run test suite gate (always — tests are fundamental to every iteration)
        run_test_suite_gate

        # Run security scan (always — lightweight bash operations, zero API cost)
        run_security_scan

        # Clear stream log for next iteration (append mode, but fresh for progress tracking)
        : > "$STREAM_LOG"

        # Sleep for cooldown
        log "Sleeping ${cooldown}s..."
        sleep "$cooldown"
    done

    # Clean up stale state files
    cleanup_stale_state "$(pwd)"

    # Clean up SURGE marker if we wrote it
    if [ "$SURGE" = true ]; then
        python3 -c "
import sys
sys.path.insert(0, '$SCRIPTS_DIR')
from _budget_common import clear_surge_marker
clear_surge_marker()
" 2>/dev/null || true
        log "SURGE marker cleared"
    fi

    # Cleanup — only stop timer if we own it
    local timer_file="/tmp/claude-session-timer-${INSTANCE_ID}.json"
    local owner_pid
    owner_pid=$(python3 -c "import json; print(json.load(open('$timer_file')).get('launcher_pid',0))" 2>/dev/null || echo "0")
    if [ "$owner_pid" = "$$" ]; then
        TIMED_SESSION_INSTANCE="$INSTANCE_ID" python3 "$TIMER_SCRIPT" stop 2>/dev/null || true
    fi

    # Compute total cost from all iteration cost lines
    local total_cost
    total_cost=$(grep -oE 'Cost: \$[0-9.]+' "$LAUNCHER_LOG" 2>/dev/null | grep -oE '[0-9.]+' | awk '{s+=$1}END{printf "%.2f",s}' || echo "?")

    log "═══════════════════════════════════════════════════"
    log "Timed session COMPLETE"
    log "  Task: ${TASK}"
    log "  Folder: $(pwd)"
    log "  Iterations: $ITERATION"
    log "  Duration: ${DURATION_MIN}min | Cost: \$${total_cost}"
    log "  Instance: ${INSTANCE_ID}"
    log "═══════════════════════════════════════════════════"

    # ─── Write session completion summary (JSON for external integrations) ───
    local summary_file="/tmp/timed-session-done-${INSTANCE_ID}.json"
    local last_text=""
    if [ -f "$STREAM_LOG" ] && [ -s "$STREAM_LOG" ]; then
        last_text=$(python3 -c "
import json
last = ''
for line in open('$STREAM_LOG'):
    try:
        e = json.loads(line.strip())
        if e.get('type') == 'assistant':
            for b in e.get('message', {}).get('content', e.get('content', [])):
                if isinstance(b, dict) and b.get('type') == 'text':
                    t = b.get('text', '')
                    if len(t) > 50:
                        last = t
    except Exception:
        pass
print(last[:600] if len(last) > 600 else last)
" 2>/dev/null || echo "")
    fi
    local task_escaped
    task_escaped=$(printf '%s' "${TASK}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    local text_escaped
    text_escaped=$(printf '%s' "${last_text}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
    python3 -c "
import json
d = {'instance_id': '${INSTANCE_ID}', 'task': ${task_escaped}, 'iterations': ${ITERATION},
     'cost': '${total_cost}', 'duration_min': ${DURATION_MIN}, 'status': 'completed',
     'cwd': '$(pwd)', 'summary_text': ${text_escaped}}
with open('${summary_file}', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null || true
    log "Session summary written to $summary_file"

    # ─── Queue Mode: Pop next task if --queue ──────────────────
    if [ "$QUEUE_MODE" = true ]; then
        log "Queue mode active — checking for next task..."

        # Mark current queue task as done (if we were running one)
        if [ -n "${QUEUE_TASK_ID:-}" ]; then
            mark_queue_task_done "$QUEUE_TASK_ID"
            log "Marked queue task '$QUEUE_TASK_ID' as completed"
        fi

        # Check budget before popping next task
        local queue_ceiling="${QUEUE_BUDGET_CEILING:-40}"
        if ! check_queue_budget "$queue_ceiling"; then
            log "Queue: budget above ceiling (${queue_ceiling}%) — stopping queue"
        elif pop_next_queue_task; then
            log "Queue: popped next task — ${QUEUE_TASK_ID}: ${QUEUE_TASK_DESC}"
            log "  Project: ${QUEUE_TASK_PROJECT}"
            log "  Duration: ${QUEUE_TASK_DURATION}min"

            # Budget prediction: estimate consumption before launching
            local py="python3"
            local predictor="${SCRIPTS_DIR}/_budget_predictor.py"
            if [ -f "$predictor" ]; then
                local task_json
                task_json=$("$py" -c "
import json, sys
print(json.dumps({
    'duration_min': ${QUEUE_TASK_DURATION},
    'description': $(printf '%s' "${QUEUE_TASK_DESC}" | "$py" -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""'),
    'contract': $(printf '%s' "${QUEUE_TASK_CONTRACT:-}" | "$py" -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null || echo '""')
}))
" 2>/dev/null || echo '{"duration_min": 60}')
                local prediction
                prediction=$("$py" "$predictor" "$task_json" 2>/dev/null || echo '{}')
                local pred_five=$(echo "$prediction" | "$py" -c "import sys,json; d=json.load(sys.stdin); print(d.get('five_hour_pct', '?'))" 2>/dev/null || echo "?")
                local pred_confidence=$(echo "$prediction" | "$py" -c "import sys,json; d=json.load(sys.stdin); print(d.get('confidence', '?'))" 2>/dev/null || echo "?")
                log "  Budget prediction: ~${pred_five}% of 5h window (confidence: ${pred_confidence})"

                # Check if predicted consumption would bust the budget
                local current_five=$("$py" -c "
import json
try:
    with open('/tmp/claude-usage-cache.json') as f:
        d = json.load(f)
    print(d.get('five_hour', {}).get('utilization', 0) or 0)
except: print(0)
" 2>/dev/null || echo "0")
                local would_exceed=$("$py" -c "
cur = float('$current_five')
pred = float('${pred_five}') if '${pred_five}' != '?' else 0
ceiling = float('$queue_ceiling')
print('yes' if cur + pred > ceiling else 'no')
" 2>/dev/null || echo "no")

                if [ "$would_exceed" = "yes" ]; then
                    log "  Budget prediction: task would push 5h to ~$(echo "$current_five + $pred_five" | bc 2>/dev/null || echo '?')% (ceiling: ${queue_ceiling}%)"
                    log "  Skipping task — marking back to pending"
                    "$py" -c "
import yaml
with open('$WORKQUEUE_FILE') as f:
    data = yaml.safe_load(f)
for t in data.get('tasks', []):
    if t.get('id') == '${QUEUE_TASK_ID}':
        t['status'] = 'pending'
        t['skip_reason'] = 'budget_prediction_exceeded'
        break
with open('$WORKQUEUE_FILE', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
" 2>/dev/null || true
                    log "Queue: task skipped due to budget prediction — stopping queue"
                    return 0 2>/dev/null || true
                fi
            fi

            # Write task contract if provided
            if [ -n "${QUEUE_TASK_CONTRACT:-}" ]; then
                local contract_dir="${QUEUE_TASK_PROJECT}/notes"
                mkdir -p "$contract_dir"
                echo "$QUEUE_TASK_CONTRACT" > "$contract_dir/task-contract.md"
                log "  Wrote task contract to ${contract_dir}/task-contract.md"
            fi

            # Recurse: launch new session for the next task
            local queue_args=("$QUEUE_TASK_DURATION" "--queue")
            [ "$CODEX_WAIT" = true ] && queue_args+=("--codex-wait")
            [ "$PR_REVIEW" = true ] && queue_args+=("--pr-review")
            [ "$SURGE" = true ] && queue_args+=("--surge")
            [ "$DESLOPPIFY" = true ] && queue_args+=("--desloppify")
            queue_args+=("$QUEUE_TASK_DESC")

            log "Queue: launching next task in ${QUEUE_TASK_PROJECT}..."
            if cd "$QUEUE_TASK_PROJECT" 2>/dev/null; then
                # Re-invoke launcher for next task (clean state)
                exec "$0" "${queue_args[@]}"
            else
                log "Queue: failed to cd to ${QUEUE_TASK_PROJECT} — skipping task"
            fi
        else
            log "Queue: no more pending tasks — queue complete"
        fi
    fi
}

main "$@"
