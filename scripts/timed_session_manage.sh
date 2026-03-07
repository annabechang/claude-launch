#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Timed Session Manager — List, stop, attach, clean up sessions
#
# Usage:
#   timed_session_manage.sh list              # List all sessions with status
#   timed_session_manage.sh stop <ID|all>     # Gracefully stop a session
#   timed_session_manage.sh kill <ID|all>     # Force-kill a session
#   timed_session_manage.sh attach <ID>       # Attach to tmux session
#   timed_session_manage.sh cleanup           # Remove orphaned sessions + stale files
#   timed_session_manage.sh cleanup --dry-run # Show what would be cleaned
# ─────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Helpers ────────────────────────────────────────────────

get_all_instance_ids() {
    for f in /tmp/timed-session-launcher-*.log; do
        [ -f "$f" ] || continue
        echo "$f" | sed 's|.*launcher-\(.*\)\.log|\1|'
    done
}

get_session_info() {
    local id="$1"
    local timer_file="/tmp/claude-session-timer-${id}.json"

    local timer_active="false"
    local launcher_pid=""
    local remaining_min="0"
    local timer_project="unknown"

    if [ -f "$timer_file" ]; then
        eval "$(python3 -c "
import json, time
from pathlib import Path
try:
    d = json.load(open('$timer_file'))
    active = d.get('active', False)
    pid = d.get('launcher_pid', '')
    remaining = max(0, d.get('end_ts', 0) - time.time())
    cwd = d.get('cwd', '')
    project = Path(cwd).name if cwd else 'unknown'
    print(f'timer_active={str(active).lower()}')
    print(f'launcher_pid={pid}')
    print(f'remaining_min={int(remaining/60)}')
    project = project.replace(chr(39), '')
    print(f'timer_project={chr(39)}{project}{chr(39)}')
except Exception:
    print('timer_active=false')
    print('launcher_pid=')
    print('remaining_min=0')
    print(f'timer_project={chr(39)}unknown{chr(39)}')
" 2>/dev/null || echo "timer_active=false")"
    fi

    # Check tmux session
    local has_tmux="false"
    local tmux_pane_pid=""
    if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
        has_tmux="true"
        tmux_pane_pid=$(tmux list-panes -t "claude-${id}" -F '#{pane_pid}' 2>/dev/null | head -1)
    fi

    # Determine status
    local pid_alive="false"
    if [ -n "$launcher_pid" ] && kill -0 "$launcher_pid" 2>/dev/null; then
        pid_alive="true"
    fi

    local status="unknown"
    if [ "$timer_active" = "true" ] && [ "$pid_alive" = "true" ]; then
        status="RUNNING"
    elif [ "$timer_active" = "true" ] && [ "$pid_alive" = "false" ]; then
        status="ORPHANED"
    elif [ "$timer_active" = "false" ] && [ "$has_tmux" = "true" ]; then
        if [ -n "$tmux_pane_pid" ] && kill -0 "$tmux_pane_pid" 2>/dev/null; then
            status="COMPLETED"
        else
            status="STALE"
        fi
    elif [ "$timer_active" = "false" ]; then
        status="COMPLETED"
    fi

    echo "${id}|${status}|${timer_active}|${remaining_min}|${launcher_pid}|${pid_alive}|${has_tmux}|${timer_project}"
}

# ─── Commands ───────────────────────────────────────────────

cmd_list() {
    echo "Timed Session Instances:"
    echo ""
    printf "  %-10s %-12s %-8s %-10s %-12s %-8s %-20s\n" \
        "ID" "STATUS" "TIMER" "REMAINING" "LAUNCHER" "SESSION" "PROJECT"
    printf "  %-10s %-12s %-8s %-10s %-12s %-8s %-20s\n" \
        "----------" "------------" "--------" "----------" "------------" "--------" "--------------------"

    local found=0
    for id in $(get_all_instance_ids); do
        found=1
        local info
        info=$(get_session_info "$id")
        IFS='|' read -r sid status t_active remaining l_pid p_alive has_tmux project <<< "$info"

        local timer_str="done"
        [ "$t_active" = "true" ] && timer_str="active"

        local remain_str="-"
        [ "$remaining" != "0" ] && remain_str="${remaining}m"

        local pid_str="-"
        if [ -n "$l_pid" ]; then
            if [ "$p_alive" = "true" ]; then
                pid_str="${l_pid}(alive)"
            else
                pid_str="${l_pid}(dead)"
            fi
        fi

        local session_str="-"
        [ "$has_tmux" = "true" ] && session_str="tmux"

        local proj_str="${project:-unknown}"
        printf "  %-10s %-12s %-8s %-10s %-12s %-8s %-20s\n" \
            "$sid" "$status" "$timer_str" "$remain_str" "$pid_str" "$session_str" "$proj_str"
    done

    if [ "$found" -eq 0 ]; then
        echo "  (no sessions found)"
    fi
}

stop_one() {
    local id="$1"
    local stop_file="/tmp/timed-session-stop-${id}"

    echo "Requesting graceful stop for instance $id..."

    # 1. Write stop file (cooperative — checked by launcher between iterations)
    echo "User requested stop via timed_session_manage.sh at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$stop_file"

    # 2. Deactivate timer (lets stop hook release Claude)
    local timer_file="/tmp/claude-session-timer-${id}.json"
    if [ -f "$timer_file" ]; then
        TIMED_SESSION_INSTANCE="$id" python3 "$SCRIPTS_DIR/_session_timer.py" stop 2>/dev/null || true
        echo "  Timer deactivated"
    fi

    # 3. Send Ctrl-C to tmux session (triggers bash SIGINT trap)
    if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
        tmux send-keys -t "claude-${id}" C-c 2>/dev/null || true
        echo "  Sent SIGINT to tmux session claude-${id}"
    fi

    echo "  Stop requested. Session will end after current iteration."
    echo "  If stuck after 60s, use: $(basename "$0") kill $id"
}

cmd_stop() {
    local target="$1"
    if [ "$target" = "all" ]; then
        for id in $(get_all_instance_ids); do
            local info
            info=$(get_session_info "$id")
            IFS='|' read -r sid status _ _ _ _ _ <<< "$info"
            [ "$status" = "RUNNING" ] || [ "$status" = "ORPHANED" ] && stop_one "$id"
        done
    else
        stop_one "$target"
    fi
}

kill_one() {
    local id="$1"
    local timer_file="/tmp/claude-session-timer-${id}.json"

    echo "Force-killing instance $id..."

    # 1. Kill launcher process
    if [ -f "$timer_file" ]; then
        local l_pid
        l_pid=$(python3 -c "import json; print(json.load(open('$timer_file')).get('launcher_pid',''))" 2>/dev/null || echo "")
        if [ -n "$l_pid" ] && kill -0 "$l_pid" 2>/dev/null; then
            kill -9 "$l_pid" 2>/dev/null || true
            echo "  Killed launcher PID $l_pid"
        fi
    fi

    # 2. Kill tmux session (kills all processes inside it)
    if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
        tmux kill-session -t "claude-${id}" 2>/dev/null || true
        echo "  Killed tmux session claude-${id}"
    fi

    # 3. Deactivate timer
    if [ -f "$timer_file" ]; then
        TIMED_SESSION_INSTANCE="$id" python3 "$SCRIPTS_DIR/_session_timer.py" stop 2>/dev/null || true
        echo "  Timer deactivated"
    fi

    # 4. Clean up stop file
    rm -f "/tmp/timed-session-stop-${id}" 2>/dev/null || true

    echo "  Instance $id force-killed"
}

cmd_kill() {
    local target="$1"
    if [ "$target" = "all" ]; then
        for id in $(get_all_instance_ids); do
            kill_one "$id"
        done
    else
        kill_one "$target"
    fi
}

cmd_attach() {
    local id="$1"
    if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
        echo "Attaching to tmux session claude-${id}..."
        echo "(Detach with Ctrl-b d)"
        exec tmux attach -t "claude-${id}"
    else
        echo "No tmux session found for instance $id"
        echo "Monitor with: tail -f /tmp/timed-session-launcher-${id}.log"
        exit 1
    fi
}

cmd_cleanup() {
    local dry_run=false
    [ "${1:-}" = "--dry-run" ] && dry_run=true && echo "DRY RUN — showing what would be cleaned:"

    local cleaned=0

    for id in $(get_all_instance_ids); do
        local info
        info=$(get_session_info "$id")
        IFS='|' read -r sid status _ _ _ _ has_tmux <<< "$info"

        if [ "$status" = "ORPHANED" ]; then
            echo "  ORPHANED: $id (timer active, launcher dead)"
            if [ "$dry_run" = false ]; then
                kill_one "$id"
                cleaned=$((cleaned + 1))
            fi
        elif [ "$status" = "STALE" ]; then
            echo "  STALE: $id (timer done, tmux session lingering)"
            if [ "$dry_run" = false ]; then
                if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
                    tmux kill-session -t "claude-${id}" 2>/dev/null || true
                fi
                cleaned=$((cleaned + 1))
            fi
        fi
    done

    # Clean up stale /tmp files (>7 days, no active session)
    for f in /tmp/timed-session-launcher-*.log /tmp/timed-session-stream-*.jsonl /tmp/claude-session-timer-*.json /tmp/timed-session-launcher-*.pid; do
        [ -f "$f" ] || continue
        local file_age
        file_age=$(( $(date +%s) - $(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo "0") ))
        if [ "$file_age" -gt 604800 ]; then
            local file_id
            file_id=$(echo "$f" | sed 's|.*[-]\([0-9a-f]*\)\..*|\1|')
            local timer_file="/tmp/claude-session-timer-${file_id}.json"
            local is_active="false"
            if [ -f "$timer_file" ]; then
                is_active=$(python3 -c "import json; print('true' if json.load(open('$timer_file')).get('active') else 'false')" 2>/dev/null || echo "false")
            fi
            if [ "$is_active" = "false" ]; then
                echo "  STALE FILE: $f ($(( file_age / 86400 ))d old)"
                if [ "$dry_run" = false ]; then
                    rm -f "$f"
                    cleaned=$((cleaned + 1))
                fi
            fi
        fi
    done

    if [ "$cleaned" -eq 0 ] && [ "$dry_run" = false ]; then
        echo "No orphans or stale files found."
    elif [ "$dry_run" = false ]; then
        echo "Cleaned up $cleaned items."
    fi
}

# ─── Main ───────────────────────────────────────────────────

case "${1:-}" in
    list|ls)
        cmd_list
        ;;
    stop)
        [ -z "${2:-}" ] && echo "Usage: $(basename "$0") stop <ID|all>" && exit 1
        cmd_stop "$2"
        ;;
    kill)
        [ -z "${2:-}" ] && echo "Usage: $(basename "$0") kill <ID|all>" && exit 1
        cmd_kill "$2"
        ;;
    attach|a)
        [ -z "${2:-}" ] && echo "Usage: $(basename "$0") attach <ID>" && exit 1
        cmd_attach "$2"
        ;;
    cleanup|clean)
        cmd_cleanup "${2:-}"
        ;;
    *)
        echo "Timed Session Manager"
        echo ""
        echo "Usage: $(basename "$0") <command> [args]"
        echo ""
        echo "Commands:"
        echo "  list              List all sessions with status"
        echo "  stop <ID|all>     Gracefully stop (finishes current iteration)"
        echo "  kill <ID|all>     Force-kill immediately"
        echo "  attach <ID>       Attach to tmux session"
        echo "  cleanup           Remove orphaned sessions + stale files"
        echo "  cleanup --dry-run Show what would be cleaned"
        echo ""
        echo "Examples:"
        echo "  $(basename "$0") list"
        echo "  $(basename "$0") stop a1b2c3d4"
        echo "  $(basename "$0") stop all"
        echo "  $(basename "$0") attach a1b2c3d4"
        echo "  $(basename "$0") cleanup --dry-run"
        ;;
esac
