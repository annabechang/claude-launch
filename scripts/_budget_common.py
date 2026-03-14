"""
Shared budget utilities for dual-budget (Claude + Codex) awareness.

Underscore prefix = internal module, not a standalone script.
Used by: timed_session_launcher.sh (budget checks, SURGE mode, delegation matrix)
"""

import hashlib
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_CACHE = "/tmp/claude-usage-cache.json"
CODEX_CACHE = "/tmp/claude-codex-usage-cache.json"
PHASE_MARKER = "/tmp/.claude_budget_last_phase"
CODEX_PHASE_MARKER = "/tmp/.claude_codex_last_phase"
SURGE_MARKER = "/tmp/.claude_surge_mode"

CACHE_MAX_AGE_START = 300  # 5 min — acceptable for session start
CACHE_MAX_AGE_STOP = 120   # 2 min — tighter for per-turn checks
SURGE_MARKER_MAX_AGE = 43200  # 12 hours — stale marker cleanup


# --- Task fingerprint helpers (anti-drift alignment) ---

def compute_task_fingerprint(text: str) -> str:
    """Compute a stable 8-char hex fingerprint from task description.

    Used to detect when a checkpoint/plan belongs to a different task
    than the current session.
    """
    normalized = text.strip()[:200].lower()
    return hashlib.md5(normalized.encode()).hexdigest()[:8]


def read_task_fingerprint(filepath) -> str | None:
    """Read a task fingerprint from a notes file (checkpoint or plan).

    Looks for a line containing 'Fingerprint:' followed by an 8-char hex hash.
    """
    try:
        with open(filepath) as f:
            for line in f:
                if "fingerprint" in line.lower():
                    match = re.search(r"[0-9a-f]{8}", line)
                    if match:
                        return match.group(0)
    except Exception:
        pass
    return None


# --- SURGE mode helpers ---

def write_surge_marker(soft_target: float = 90, hard_cap: float = 95,
                       resume_target: float = 60, reason: str = "manual"):
    """Write SURGE marker file to activate SURGE phase boundaries."""
    try:
        data = {
            "active": True,
            "soft_target": soft_target,
            "hard_cap": hard_cap,
            "resume_target": resume_target,
            "reason": reason,
            "activated_at": time.time(),
        }
        with open(SURGE_MARKER, "w") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass


def read_surge_marker():
    """Read SURGE marker. Returns dict or None if missing/stale."""
    try:
        if not os.path.exists(SURGE_MARKER):
            return None
        age = time.time() - os.path.getmtime(SURGE_MARKER)
        if age > SURGE_MARKER_MAX_AGE:
            clear_surge_marker()
            return None
        with open(SURGE_MARKER) as f:
            data = json.load(f)
        if not data.get("active"):
            return None
        return data
    except Exception:
        return None


def clear_surge_marker():
    """Remove SURGE marker file."""
    try:
        if os.path.exists(SURGE_MARKER):
            os.remove(SURGE_MARKER)
    except Exception:
        pass


def is_surge_active() -> bool:
    """Check if SURGE mode is active via env var or marker file."""
    if os.environ.get("TIMED_SESSION_SURGE") == "1":
        return True
    return read_surge_marker() is not None


def check_auto_surge(claude_cache_data: dict) -> tuple:
    """Check if auto-SURGE should activate based on 7-day waste detection.

    Args:
        claude_cache_data: Raw Claude cache dict (from json.load, not read_claude_cache)

    Returns:
        (should_activate, reason_str) tuple
    """
    try:
        five = claude_cache_data.get("five_hour") or {}
        seven = claude_cache_data.get("seven_day") or {}

        five_pct = float(five.get("utilization", 0) or 0)
        seven_pct = float(seven.get("utilization", 0) or 0)
        seven_reset = seven.get("resets_at", "")

        if not seven_reset:
            return False, ""

        # Parse 7-day reset time
        reset_time = datetime.fromisoformat(seven_reset.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        hours_until = (reset_time - now).total_seconds() / 3600

        # Auto-SURGE triggers when:
        # 1. 7-day reset within 48 hours
        # 2. 7-day utilization below 50% (significant waste)
        # 3. 5-hour not already stressed (< 60%)
        if hours_until <= 0 or hours_until > 48:
            return False, ""
        if seven_pct >= 50:
            return False, ""
        if five_pct >= 60:
            return False, ""

        waste_pct = 100 - seven_pct
        reason = (
            f"7-day budget at {seven_pct:.0f}% with reset in {hours_until:.0f}h. "
            f"~{waste_pct:.0f}% capacity expiring. "
            f"Activating SURGE to maximize throughput."
        )
        return True, reason
    except Exception:
        return False, ""


def compute_surge_soft_target(seven_pct: float, urgent: bool = False) -> float:
    """Dynamic soft target based on 7-day headroom."""
    base = 95.0 if urgent else 90.0
    if seven_pct >= 80:
        return min(base, 75.0)
    elif seven_pct >= 60:
        return min(base, 85.0)
    elif seven_pct >= 40:
        return base
    else:
        return min(base + 2, 99.0)


def progress_bar(pct: float, width: int = 10) -> str:
    """Render a visual progress bar: ████░░░░░░ 37%"""
    filled = int(round(pct / 100 * width))
    filled = max(0, min(width, filled))
    return "█" * filled + "░" * (width - filled)


def get_phase(pct: float) -> str:
    if is_surge_active():
        if pct >= 95:
            return "CHECKPOINT"
        elif pct >= 85:
            return "CONSERVE"
        elif pct >= 60:
            return "CRUISE"
        return "SPRINT"
    if pct >= 80:
        return "CHECKPOINT"
    elif pct >= 60:
        return "CONSERVE"
    elif pct >= 30:
        return "CRUISE"
    return "SPRINT"


def time_until_iso(iso_str: str) -> str:
    """Human-readable countdown from ISO 8601 timestamp."""
    try:
        reset_time = datetime.fromisoformat(iso_str)
        now = datetime.now(timezone.utc)
        total_seconds = int((reset_time - now).total_seconds())
        if total_seconds <= 0:
            return "now"
        hours, remainder = divmod(total_seconds, 3600)
        minutes = remainder // 60
        return f"{hours}h{minutes:02d}m" if hours > 0 else f"{minutes}m"
    except Exception:
        return "?"


def time_until_unix(ts) -> str:
    """Human-readable countdown from unix timestamp."""
    try:
        reset_time = datetime.fromtimestamp(float(ts), tz=timezone.utc)
        now = datetime.now(timezone.utc)
        total_seconds = int((reset_time - now).total_seconds())
        if total_seconds <= 0:
            return "now"
        hours, remainder = divmod(total_seconds, 3600)
        minutes = remainder // 60
        return f"{hours}h{minutes:02d}m" if hours > 0 else f"{minutes}m"
    except Exception:
        return "?"


def read_claude_cache(max_age: int):
    """Read Claude usage cache. Returns dict or None."""
    try:
        if not os.path.exists(CLAUDE_CACHE):
            return None
        if time.time() - os.path.getmtime(CLAUDE_CACHE) > max_age:
            return None
        with open(CLAUDE_CACHE) as f:
            data = json.load(f)
        five = data.get("five_hour") or {}
        seven = data.get("seven_day") or {}
        extra = data.get("extra_usage") or {}
        pct = float(five.get("utilization", 0) or 0)
        phase = get_phase(pct)

        # Override phase to CHECKPOINT if monthly extra_usage is exhausted.
        # When extra_usage >= 100%, the API rejects ALL requests regardless of 5h window.
        extra_pct = float(extra.get("utilization", 0) or 0) if extra.get("is_enabled") else 0
        if extra_pct >= 100:
            phase = "CHECKPOINT"

        # Model recommendation: derive from final phase, not just five_hour pct
        if phase == "CHECKPOINT":
            recommended_model = "sonnet-simple-only"  # checkpoint: sonnet for mechanical tasks only
        else:
            recommended_model = "opus"

        return {
            "pct": pct,
            "phase": phase,
            "reset_str": time_until_iso(five.get("resets_at", "")),
            "seven_pct": float(seven.get("utilization", 0) or 0),
            "seven_reset_str": time_until_iso(seven.get("resets_at", "")),
            "extra_pct": extra_pct,
            "recommended_model": recommended_model,
        }
    except Exception:
        return None


def read_codex_cache(max_age: int):
    """Read Codex usage cache. Returns dict or None."""
    try:
        if not os.path.exists(CODEX_CACHE):
            return None
        if time.time() - os.path.getmtime(CODEX_CACHE) > max_age:
            return None
        with open(CODEX_CACHE) as f:
            data = json.load(f)
        primary = data.get("primary") or {}
        secondary = data.get("secondary") or {}
        pct = float(primary.get("used_percent", 0) or 0)
        return {
            "pct": pct,
            "phase": get_phase(pct),
            "reset_str": time_until_unix(primary.get("resets_at", 0)),
            "secondary_pct": float(secondary.get("used_percent", 0) or 0),
            "secondary_reset_str": time_until_unix(secondary.get("resets_at", 0)),
        }
    except Exception:
        return None


# --- Phase marker I/O ---

def read_marker(path: str) -> str:
    try:
        if os.path.exists(path):
            with open(path) as f:
                return f.read().strip()
    except Exception:
        pass
    return ""


def write_marker(path: str, value: str):
    try:
        with open(path, "w") as f:
            f.write(value)
    except Exception:
        pass


# --- Delegation Matrix ---
# (claude_phase, codex_phase) -> {mode, label, guidance}

DELEGATION_MATRIX = {
    ("SPRINT", "SPRINT"): {
        "mode": "MAX_THROUGHPUT",
        "label": "Both fresh -- maximum throughput",
        "guidance": (
            "- Use Codex aggressively for ALL reviews, analysis, and verification\n"
            "- Spawn parallel work freely; use Codex for cross-model sanity checks\n"
            "- Batch similar reviews into single Codex calls (saves API calls)\n"
            "- Use thread continuation (codex-reply) for multi-round reviews"
        ),
    },
    ("SPRINT", "CRUISE"): {
        "mode": "MAX_THROUGHPUT",
        "label": "Both available -- full capability",
        "guidance": (
            "- Use Codex for reviews, analysis, spec verification\n"
            "- Batch where possible to conserve Codex calls\n"
            "- Use threads for follow-ups instead of fresh sessions"
        ),
    },
    ("SPRINT", "CONSERVE"): {
        "mode": "CLAUDE_PRIMARY",
        "label": "Claude fresh, Codex tight -- internalize more",
        "guidance": (
            "- Claude does most work internally (plenty of budget)\n"
            "- Use Codex ONLY for: architecture decisions (Critical tier), final PR review\n"
            "- Skip optional Codex sanity checks\n"
            "- If using Codex, always use threads to minimize API calls"
        ),
    },
    ("SPRINT", "CHECKPOINT"): {
        "mode": "CLAUDE_ONLY",
        "label": "Claude fresh, Codex exhausted -- no Codex",
        "guidance": (
            "- Do NOT call Codex (budget exhausted)\n"
            "- Claude handles all reviews and analysis internally\n"
            "- Wait for Codex reset before scheduling Codex-dependent work"
        ),
    },
    ("CRUISE", "SPRINT"): {
        "mode": "OFFLOAD_TO_CODEX",
        "label": "Claude moderate, Codex fresh -- offload aggressively",
        "guidance": (
            "- OFFLOAD to Codex: reviews, analysis, spec verification, competitive analysis\n"
            "- Codex has headroom -- use it for tasks Claude would normally do internally\n"
            "- Batch reviews: combine related checks into one Codex call\n"
            "- Use Standard tier (high) for most tasks; save Critical (xhigh) for architecture"
        ),
    },
    ("CRUISE", "CRUISE"): {
        "mode": "BALANCED",
        "label": "Both moderate -- balanced usage",
        "guidance": (
            "- Normal delegation: Codex for reviews and cross-model checks\n"
            "- Claude for implementation and orchestration\n"
            "- Use threads for follow-ups"
        ),
    },
    ("CRUISE", "CONSERVE"): {
        "mode": "CLAUDE_PRIMARY",
        "label": "Claude moderate, Codex tight -- limit Codex",
        "guidance": (
            "- Claude handles most analysis internally\n"
            "- Codex ONLY for: critical architecture review, final PR review\n"
            "- Always use thread continuation, never fresh sessions for minor checks"
        ),
    },
    ("CRUISE", "CHECKPOINT"): {
        "mode": "CLAUDE_ONLY",
        "label": "Claude moderate, Codex exhausted -- no Codex",
        "guidance": "- Do NOT call Codex. Handle all work internally.",
    },
    ("CONSERVE", "SPRINT"): {
        "mode": "OFFLOAD_TO_CODEX",
        "label": "Claude tight, Codex fresh -- OFFLOAD AGGRESSIVELY",
        "guidance": (
            "- MAXIMIZE Codex delegation to conserve Claude budget\n"
            "- Offload to Codex: ALL reviews, analysis, spec checks, planning verification\n"
            "- Codex can do decomposition and multi-round assessment (it excels at this)\n"
            "- Batch multiple review items into single Codex calls\n"
            "- Use Standard tier by default; Codex budget is plentiful"
        ),
    },
    ("CONSERVE", "CRUISE"): {
        "mode": "OFFLOAD_TO_CODEX",
        "label": "Claude tight, Codex available -- offload reviews",
        "guidance": (
            "- Offload reviews and analysis to Codex to conserve Claude\n"
            "- Skip optional Claude-side analysis; let Codex handle verification\n"
            "- Use threads to minimize Codex API calls"
        ),
    },
    ("CONSERVE", "CONSERVE"): {
        "mode": "MINIMAL",
        "label": "Both tight -- minimal usage",
        "guidance": (
            "- Reduce all resource usage. Lean mode only.\n"
            "- Skip optional reviews. Only critical Codex calls.\n"
            "- Start writing checkpoints"
        ),
    },
    ("CONSERVE", "CHECKPOINT"): {
        "mode": "MINIMAL",
        "label": "Both tight/exhausted -- wind down",
        "guidance": (
            "- No Codex. Minimal Claude usage.\n"
            "- Write checkpoints. Commit work. Prepare for session end."
        ),
    },
    ("CHECKPOINT", "SPRINT"): {
        "mode": "CODEX_CHECKPOINT",
        "label": "Claude exhausted, Codex fresh -- Codex for final review only",
        "guidance": (
            "- Claude: STOP new work. Write checkpoint.\n"
            "- ONE final Codex call allowed: review checkpoint/PR before session ends\n"
            "- Do not start new Codex threads or multi-round analysis"
        ),
    },
    ("CHECKPOINT", "CRUISE"): {
        "mode": "CODEX_CHECKPOINT",
        "label": "Claude exhausted, Codex available -- Codex for final review only",
        "guidance": (
            "- Claude: STOP new work. Write checkpoint. Commit.\n"
            "- Optional: one Codex call to review final state"
        ),
    },
    ("CHECKPOINT", "CONSERVE"): {
        "mode": "SHUTDOWN",
        "label": "Both exhausted -- shut down",
        "guidance": "- Write checkpoint immediately. Commit. No new work. No Codex calls.",
    },
    ("CHECKPOINT", "CHECKPOINT"): {
        "mode": "SHUTDOWN",
        "label": "Both exhausted -- emergency shutdown",
        "guidance": "- IMMEDIATE: Write checkpoint, commit, inform user. No tool calls.",
    },
}


def get_delegation(claude_phase: str, codex_phase: str) -> dict:
    """Look up delegation strategy from the 4x4 matrix."""
    return DELEGATION_MATRIX.get(
        (claude_phase, codex_phase),
        DELEGATION_MATRIX[("CRUISE", "CRUISE")],
    )


# --- Claude phase guidance (for external hook consumers) ---

CLAUDE_PHASE_GUIDANCE = {
    "SPRINT": (
        "- Go all-in: spawn parallel subagents, use Codex reviews freely, batch work\n"
        "- Full autonomy: subagents + Codex inside iterations\n"
        "- No pacing constraints -- maximize output while budget is fresh"
    ),
    "CRUISE": (
        "- Normal pacing: standard approach, use subagents and Codex as needed\n"
        "- Full or lean autonomy depending on task complexity\n"
        "- No special constraints -- steady state operation"
    ),
    "CONSERVE": (
        "- Reduce resource usage: fewer subagents, skip optional Codex reviews\n"
        "- Lean mode: no subagents, comparable quality\n"
        "- Start thinking about checkpoints\n"
        "- Warn user: mention budget is getting tight"
    ),
    "CHECKPOINT": (
        "- STOP new major work immediately\n"
        "- Write notes/resume-checkpoint.md with: Task, Status, Next Steps, Files to Read, Modified Files\n"
        "- Commit all changes\n"
        "- Do NOT start new autonomous loops or spawn subagents\n"
        "- Inform user: 'Budget at X%. Writing checkpoint for next session.'"
    ),
}

SURGE_PHASE_GUIDANCE = {
    "SPRINT": (
        "- SURGE: Go all-in. Maximum throughput. No pacing constraints.\n"
        "- The launcher/system manages budget externally -- push hard.\n"
        "- Spawn subagents, use Codex for reviews, full autonomy."
    ),
    "CRUISE": (
        "- SURGE: Still working aggressively. Budget approaching soft target.\n"
        "- Continue making progress -- system will stall when needed.\n"
        "- Do NOT self-throttle."
    ),
    "CONSERVE": (
        "- SURGE: Nearing soft target. Continue current work item.\n"
        "- System handles the stall -- finish what you're doing."
    ),
    "CHECKPOINT": (
        "- SURGE hard cap reached. Write checkpoint immediately.\n"
        "- Commit all work. System will stall and resume after window decay."
    ),
}


# --- Auto-checkpoint writing ---

# Marker to avoid writing checkpoint multiple times per session
# Scoped by session ID to prevent cross-session suppression
def _checkpoint_marker_path() -> str:
    session_id = os.environ.get("CLAUDE_SESSION_ID", "default")
    return f"/tmp/.claude_checkpoint_written_{session_id}"


def _run_git(cmd: str, cwd: str) -> str:
    """Run a git command and return stdout. Returns empty string on failure."""
    try:
        result = subprocess.run(
            cmd, shell=True, cwd=cwd,
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except Exception:
        return ""


def write_auto_checkpoint(cwd: str, reason: str = "budget_checkpoint") -> bool:
    """Write notes/resume-checkpoint.md if it doesn't already exist.

    Called by the launcher on session end or budget exhaustion.
    Can also be called by external budget/session hooks if installed.

    Returns True if a checkpoint was written, False if skipped.
    """
    notes_dir = Path(cwd) / "notes"
    checkpoint_path = notes_dir / "resume-checkpoint.md"
    request_path = notes_dir / "original-request.md"

    # Don't overwrite existing checkpoint (Claude may have written a better one)
    if checkpoint_path.exists():
        return False

    # Don't write multiple times per session (Stop hook fires every turn)
    if reason == "budget_checkpoint" and os.path.exists(_checkpoint_marker_path()):
        try:
            # Check if marker is from current session (< 6 hours old)
            age = time.time() - os.path.getmtime(_checkpoint_marker_path())
            if age < 21600:  # 6 hours
                return False
        except Exception:
            pass

    # Gather context
    has_request = request_path.exists()
    modified_files = _run_git("git status --porcelain", cwd)
    has_changes = bool(modified_files)

    if not has_request and not has_changes:
        return False

    # Read original request
    task_desc = "Unknown task"
    if has_request:
        try:
            content = request_path.read_text(encoding="utf-8")
            match = re.search(
                r"## (?:Initial|Original) Request\n(.*?)(?=\n## |\Z)",
                content, re.DOTALL,
            )
            if match:
                task_desc = match.group(1).strip()[:500]
            elif content.strip():
                stripped = re.sub(r"^#+\s+.*\n+", "", content.strip())
                task_desc = (stripped.strip() or content.strip())[:500]
        except Exception:
            pass

    # Format modified files
    files_list = ""
    if modified_files:
        files = [line.strip() for line in modified_files.split("\n") if line.strip()]
        files_list = "\n".join(f"  - `{f}`" for f in files[:20])
        if len(files) > 20:
            files_list += f"\n  - ... and {len(files) - 20} more"

    last_commit = _run_git("git log -1 --format='%s'", cwd)
    diff_stat = _run_git("git diff --stat", cwd)
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    fingerprint = compute_task_fingerprint(task_desc)

    checkpoint = (
        f"## Resume Checkpoint (auto-generated)\n\n"
        f"- **Task**: {task_desc}\n"
        f"- **Fingerprint**: {fingerprint}\n"
        f"- **Status**: Session ended ({reason}). Last commit: {last_commit or 'none'}\n"
        f"- **Next Steps**: Continue the task described above. "
        f"Check modified files for work in progress.\n"
        f"- **Files to Read**: notes/original-request.md"
    )

    if files_list:
        checkpoint += f"\n- **Modified Files**:\n{files_list}"
    if diff_stat:
        checkpoint += f"\n- **Diff Summary**: {diff_stat}"
    checkpoint += f"\n- **Generated**: {timestamp}\n"

    # Write checkpoint (exclusive create to prevent TOCTOU race)
    notes_dir.mkdir(parents=True, exist_ok=True)
    try:
        with open(checkpoint_path, "x", encoding="utf-8") as f:
            f.write(checkpoint)
    except FileExistsError:
        return False  # Another writer created it between our check and write

    # Mark as written (prevents duplicate writes from Stop hook)
    try:
        with open(_checkpoint_marker_path(), "w") as f:
            f.write(timestamp)
    except Exception:
        pass

    return True
