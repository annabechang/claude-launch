#!/usr/bin/env python3
"""
Shared session timer utility for timed autonomous sessions.

Underscore prefix = internal module, not a hook itself.
Used by: timed_session_stop.py, precompact_intent_anchor.py, CLAUDE.md protocol

CLI usage:
  python3 _session_timer.py start <minutes>   # Start a timed session
  python3 _session_timer.py check              # Check status (JSON output)
  python3 _session_timer.py stop               # Deactivate timer
  python3 _session_timer.py status             # Human-readable status
  python3 _session_timer.py extend <minutes>   # Add time to active timer

Timer state: /tmp/claude-session-timer.json
"""

import json
import os
import re
import sys
import time
from datetime import datetime, timezone

DEFAULT_TIMER_FILE = "/tmp/claude-session-timer.json"
_SAFE_INSTANCE_ID = re.compile(r"^[A-Za-z0-9_-]+$")


def get_timer_file():
    """Get timer file path, supporting per-instance files.

    If TIMED_SESSION_INSTANCE env var is set, uses instance-specific path:
      /tmp/claude-session-timer-{instance_id}.json

    Falls back to the default path for backwards compatibility.
    Validates instance ID to prevent path traversal.
    """
    instance_id = os.environ.get("TIMED_SESSION_INSTANCE", "")
    if instance_id and _SAFE_INSTANCE_ID.match(instance_id):
        return f"/tmp/claude-session-timer-{instance_id}.json"
    return DEFAULT_TIMER_FILE


TIMER_FILE = get_timer_file()

# Phase boundaries (percentage of elapsed time)
PHASE_SPRINT_END = 0.60    # 0-60% = SPRINT
PHASE_CRUISE_END = 0.85    # 60-85% = CRUISE
# 85-100% = WRAP_UP


def read_timer():
    """Read timer state from disk. Returns dict or None."""
    try:
        if not os.path.exists(TIMER_FILE):
            return None
        with open(TIMER_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        return None


def write_timer(data):
    """Write timer state to disk."""
    with open(TIMER_FILE, "w") as f:
        json.dump(data, f, indent=2)


def get_phase(elapsed_pct):
    """Determine session phase from elapsed percentage."""
    if elapsed_pct < PHASE_SPRINT_END:
        return "SPRINT"
    elif elapsed_pct < PHASE_CRUISE_END:
        return "CRUISE"
    return "WRAP_UP"


def format_duration(seconds):
    """Human-readable duration from seconds."""
    if seconds <= 0:
        return "0m"
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    if hours > 0:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def cmd_start(minutes):
    """Start a new timed session."""
    now = time.time()
    duration_secs = minutes * 60
    data = {
        "start_ts": now,
        "end_ts": now + duration_secs,
        "duration_min": minutes,
        "active": True,
        "block_timestamps": [],
        "iteration": 0,
        "cwd": os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd()),
    }
    write_timer(data)
    end_time = datetime.fromtimestamp(now + duration_secs, tz=timezone.utc)
    print(f"Timer started: {minutes} minutes (ends at {end_time.strftime('%H:%M UTC')})")


def cmd_check():
    """Check timer status. Returns JSON for programmatic use."""
    timer = read_timer()
    if timer is None or not timer.get("active", False):
        print(json.dumps({"status": "NO_TIMER", "remaining_min": 0, "phase": "NONE"}))
        return

    now = time.time()
    remaining = timer["end_ts"] - now
    elapsed = now - timer["start_ts"]
    total = timer["end_ts"] - timer["start_ts"]
    elapsed_pct = min(elapsed / total, 1.0) if total > 0 else 1.0

    if remaining <= 0:
        # Timer expired — deactivate
        timer["active"] = False
        write_timer(timer)
        print(json.dumps({
            "status": "TIME_UP",
            "remaining_min": 0,
            "elapsed_min": round(elapsed / 60, 1),
            "phase": "DONE",
        }))
        return

    phase = get_phase(elapsed_pct)
    status = "WRAP_UP" if phase == "WRAP_UP" else "CONTINUE"
    print(json.dumps({
        "status": status,
        "remaining_min": round(remaining / 60, 1),
        "elapsed_min": round(elapsed / 60, 1),
        "elapsed_pct": round(elapsed_pct * 100, 1),
        "phase": phase,
        "iteration": timer.get("iteration", 0),
    }))


def cmd_stop():
    """Manually stop the timer."""
    timer = read_timer()
    if timer is None:
        print("No active timer")
        return
    timer["active"] = False
    write_timer(timer)
    elapsed = time.time() - timer["start_ts"]
    print(f"Timer stopped after {format_duration(elapsed)}")


def cmd_status():
    """Human-readable status string."""
    timer = read_timer()
    if timer is None or not timer.get("active", False):
        print("No active timed session")
        return

    now = time.time()
    elapsed = now - timer["start_ts"]
    remaining = timer["end_ts"] - now
    total = timer["end_ts"] - timer["start_ts"]
    elapsed_pct = min(elapsed / total, 1.0) if total > 0 else 1.0
    phase = get_phase(elapsed_pct)

    if remaining <= 0:
        print(f"Timed session COMPLETE | Duration: {timer['duration_min']}m | Elapsed: {format_duration(elapsed)}")
    else:
        print(
            f"Timed session ACTIVE | "
            f"Duration: {timer['duration_min']}m | "
            f"Elapsed: {format_duration(elapsed)} ({elapsed_pct*100:.0f}%) | "
            f"Remaining: {format_duration(remaining)} | "
            f"Phase: {phase} | "
            f"Iteration: {timer.get('iteration', 0)}"
        )


def cmd_extend(minutes):
    """Extend the active timer by additional minutes."""
    timer = read_timer()
    if timer is None:
        print("No timer to extend")
        return
    timer["end_ts"] += minutes * 60
    timer["duration_min"] += minutes
    timer["active"] = True  # Re-activate if expired
    write_timer(timer)
    remaining = timer["end_ts"] - time.time()
    print(f"Timer extended by {minutes}m. New remaining: {format_duration(remaining)}")


def cmd_increment_iteration():
    """Increment the iteration counter."""
    timer = read_timer()
    if timer is None:
        return
    timer["iteration"] = timer.get("iteration", 0) + 1
    write_timer(timer)


def record_block():
    """Record a block timestamp for debounce tracking."""
    timer = read_timer()
    if timer is None:
        return
    now = time.time()
    # Keep only blocks from last 120 seconds
    window = [ts for ts in timer.get("block_timestamps", []) if now - ts < 120]
    window.append(now)
    timer["block_timestamps"] = window
    write_timer(timer)
    return len(window)


def count_recent_blocks():
    """Count blocks in the last 120 seconds."""
    timer = read_timer()
    if timer is None:
        return 0
    now = time.time()
    return len([ts for ts in timer.get("block_timestamps", []) if now - ts < 120])


def main():
    if len(sys.argv) < 2:
        print("Usage: _session_timer.py <start|check|stop|status|extend|increment> [args]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "start":
        if len(sys.argv) < 3:
            print("Usage: _session_timer.py start <minutes>")
            sys.exit(1)
        try:
            minutes = int(sys.argv[2])
        except ValueError:
            print(f"Invalid minutes: {sys.argv[2]}")
            sys.exit(1)
        if minutes < 1 or minutes > 1440:
            print(f"Minutes must be 1-1440, got: {minutes}")
            sys.exit(1)
        cmd_start(minutes)

    elif cmd == "check":
        cmd_check()

    elif cmd == "stop":
        cmd_stop()

    elif cmd == "status":
        cmd_status()

    elif cmd == "extend":
        if len(sys.argv) < 3:
            print("Usage: _session_timer.py extend <minutes>")
            sys.exit(1)
        try:
            minutes = int(sys.argv[2])
        except ValueError:
            print(f"Invalid minutes: {sys.argv[2]}")
            sys.exit(1)
        if minutes < 1 or minutes > 1440:
            print(f"Minutes must be 1-1440, got: {minutes}")
            sys.exit(1)
        cmd_extend(minutes)

    elif cmd == "increment":
        cmd_increment_iteration()

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
