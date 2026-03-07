#!/bin/bash
# ─────────────────────────────────────────────────────────────
# Timed Session Monitor — Real-time progress viewer
#
# Parses the stream-json log from the launcher and displays
# human-readable progress. Run in a separate terminal.
#
# Usage:
#   timed_session_monitor.sh                        # Live tail (auto-detect instance)
#   timed_session_monitor.sh --summary              # Summary (auto-detect instance)
#   timed_session_monitor.sh --instance <id>        # Specific instance
#   timed_session_monitor.sh --list                 # List active instances
# ─────────────────────────────────────────────────────────────

INSTANCE_ID=""

# Parse --instance and --list flags
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --instance)
            shift
            INSTANCE_ID="$1"
            shift
            ;;
        --list)
            # Delegate to management helper for rich status display
            SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
            if [ -x "$SCRIPTS_DIR/timed_session_manage.sh" ]; then
                exec "$SCRIPTS_DIR/timed_session_manage.sh" list
            fi

            # Fallback if manage.sh not available
            echo "Active timed session instances:"
            found=0
            for f in /tmp/timed-session-launcher-*.log; do
                [ -f "$f" ] || continue
                id=$(echo "$f" | sed 's|.*launcher-\(.*\)\.log|\1|')
                timer_file="/tmp/claude-session-timer-${id}.json"
                active="inactive"
                if [ -f "$timer_file" ]; then
                    active=$(python3 -c "
import json, time
d=json.load(open('$timer_file'))
if not d.get('active'): print('done')
else:
    r = max(0, int((d['end_ts'] - time.time()) / 60))
    print(f'ACTIVE ({r}m left)')
" 2>/dev/null || echo "?")
                fi
                session=""
                if command -v tmux &>/dev/null && tmux has-session -t "claude-${id}" 2>/dev/null; then
                    pane_pid=$(tmux list-panes -t "claude-${id}" -F '#{pane_pid}' 2>/dev/null | head -1)
                    if [ -n "$pane_pid" ] && kill -0 "$pane_pid" 2>/dev/null; then
                        session="[tmux:alive]"
                    else
                        session="[tmux:ORPHAN]"
                    fi
                fi
                last_line=$(tail -1 "$f" 2>/dev/null | head -c 60)
                echo "  ${id}  [${active}] ${session} ${last_line}"
                found=1
            done
            if [ "$found" -eq 0 ]; then
                echo "  (none found)"
            fi
            exit 0
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
set -- "${args[@]}"

# Auto-detect instance if not specified
if [ -z "$INSTANCE_ID" ]; then
    # Find the most recently modified stream log
    latest=$(ls -t /tmp/timed-session-stream-*.jsonl 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        INSTANCE_ID=$(echo "$latest" | sed 's|.*stream-\(.*\)\.jsonl|\1|')
    fi
fi

if [ -z "$INSTANCE_ID" ]; then
    echo "No active session found. Start a launcher session first."
    echo "Use --list to see all instances, or --instance <id> to specify one."
    exit 1
fi

STREAM_LOG="/tmp/timed-session-stream-${INSTANCE_ID}.jsonl"
LAUNCHER_LOG="/tmp/timed-session-launcher-${INSTANCE_ID}.log"

if [ ! -f "$STREAM_LOG" ]; then
    echo "No stream log found for instance ${INSTANCE_ID}"
    echo "  Expected: $STREAM_LOG"
    echo "Use --list to see available instances."
    exit 1
fi

# Summary mode: parse the full log and print stats
if [ "${1:-}" = "--summary" ]; then
    echo "═══ Session Summary ═══"
    echo ""

    python3 -c "
import json, sys
from collections import Counter
from datetime import datetime

tools = Counter()
text_blocks = 0
errors = 0
total_cost = 0.0
turns = 0
first_ts = None
last_ts = None

for line in open('$STREAM_LOG'):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        t = e.get('type', '')

        if t == 'assistant':
            turns += 1
            for c in e.get('message', {}).get('content', []):
                if c.get('type') == 'tool_use':
                    tools[c.get('name', 'unknown')] += 1
                elif c.get('type') == 'text':
                    text_blocks += 1

        elif t == 'result':
            total_cost += float(e.get('total_cost_usd', 0) or 0)
            if e.get('is_error'):
                errors += 1

        elif t == 'system':
            pass  # hooks, etc.

    except Exception:
        pass

print(f'Turns: {turns}')
print(f'Total tool calls: {sum(tools.values())}')
print(f'Total cost: \${total_cost:.2f}')
print(f'Errors: {errors}')
print()
print('Top tools:')
for name, count in tools.most_common(10):
    print(f'  {name}: {count}')
" 2>/dev/null

    echo ""
    echo "═══ Launcher Log (last 20 lines) ═══"
    tail -20 "$LAUNCHER_LOG" 2>/dev/null
    exit 0
fi

# Live mode: tail the stream log with real-time parsing
echo "═══ Timed Session Monitor ═══"
echo "Stream: $STREAM_LOG"
echo "Press Ctrl+C to stop monitoring (does NOT stop the session)"
echo ""

tail -f "$STREAM_LOG" 2>/dev/null | python3 -u -c "
import sys, json
from datetime import datetime

tool_count = 0
turn_count = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        t = e.get('type', '')
        ts = datetime.now().strftime('%H:%M:%S')

        if t == 'assistant':
            turn_count += 1
            for c in e.get('message', {}).get('content', []):
                if c.get('type') == 'tool_use':
                    tool_count += 1
                    name = c.get('name', '?')
                    inp = c.get('input', {})
                    # Show relevant info based on tool type
                    detail = ''
                    if name == 'Bash':
                        detail = inp.get('description', inp.get('command', ''))[:80]
                    elif name == 'Read':
                        detail = inp.get('file_path', '')
                    elif name == 'Write':
                        detail = inp.get('file_path', '')
                    elif name == 'Edit':
                        detail = inp.get('file_path', '')
                    elif name == 'Grep':
                        detail = f'{inp.get(\"pattern\",\"\")} in {inp.get(\"path\",\".\")}'
                    elif name == 'Glob':
                        detail = inp.get('pattern', '')
                    elif name == 'Task':
                        detail = inp.get('description', '')
                    else:
                        detail = str(inp)[:60]
                    print(f'[{ts}] #{tool_count} {name}: {detail}', flush=True)

                elif c.get('type') == 'text':
                    text = c.get('text', '').strip()
                    if text:
                        # Show first line, truncated
                        first_line = text.split('\\n')[0][:120]
                        print(f'[{ts}] TEXT: {first_line}', flush=True)

        elif t == 'result':
            cost = e.get('total_cost_usd', 0) or 0
            num_turns = e.get('num_turns', 0) or 0
            is_err = e.get('is_error', False)
            status = 'ERROR' if is_err else 'SUCCESS'
            print(f'[{ts}] === {status} | Turns: {num_turns} | Cost: \${cost:.2f} ===', flush=True)

    except Exception:
        pass
" 2>/dev/null
