#!/bin/bash
# ─────────────────────────────────────────────────────────────
# claude-launch installer
#
# Copies launch command and scripts to ~/.claude/
# ─────────────────────────────────────────────────────────────

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
SCRIPTS_DEST="${CLAUDE_DIR}/scripts"
COMMANDS_DEST="${CLAUDE_DIR}/commands"

echo "claude-launch installer"
echo "======================="
echo ""

# Check prerequisites
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found."
    echo "Install Python 3.10+ and try again."
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "WARNING: 'claude' CLI not found in PATH."
    echo "Install with: npm install -g @anthropic-ai/claude-code"
    echo "Continuing anyway (the launcher will search additional locations)..."
    echo ""
fi

if command -v tmux &>/dev/null; then
    echo "  tmux: found (sessions will run in named tmux sessions)"
else
    echo "  tmux: not found (sessions will use nohup fallback)"
    echo "  Install tmux for attachable sessions: brew install tmux"
fi

if command -v codex &>/dev/null; then
    echo "  codex: found (enables Codex alignment review during cooldowns)"
else
    echo "  codex: not found (required for Codex review/alignment features)"
    echo "  Sessions still run without codex, but Codex review checks will be skipped."
fi

if command -v timeout &>/dev/null; then
    echo "  timeout: found (enables time-limited subprocess execution)"
elif command -v gtimeout &>/dev/null; then
    echo "  gtimeout: found (enables time-limited subprocess execution)"
else
    echo "  timeout: not found (optional, enables time-limited subprocess execution)"
    echo "  Install coreutils on macOS: brew install coreutils"
fi
echo ""

# Create directories
mkdir -p "$SCRIPTS_DEST"
mkdir -p "$COMMANDS_DEST"

# Copy scripts
echo "Installing scripts to $SCRIPTS_DEST/"
for script in \
    timed_session_launcher.sh \
    timed_session_manage.sh \
    timed_session_monitor.sh \
    _session_timer.py \
    _refresh_usage_cache.py \
    _budget_common.py; do
    if [ ! -f "$REPO_DIR/scripts/$script" ]; then
        echo "ERROR: Missing required script: scripts/$script"
        exit 1
    fi
    cp "$REPO_DIR/scripts/$script" "$SCRIPTS_DEST/$script"
    echo "  $script"
done

# Optional advanced helpers
for script in _execution_engine.py _budget_predictor.py; do
    if [ -f "$REPO_DIR/scripts/$script" ]; then
        cp "$REPO_DIR/scripts/$script" "$SCRIPTS_DEST/$script"
        echo "  $script"
    else
        echo "  $script (optional, not found; advanced pipeline/queue prediction features will be limited)"
    fi
done

# Make shell scripts executable
chmod +x "$SCRIPTS_DEST/timed_session_launcher.sh"
chmod +x "$SCRIPTS_DEST/timed_session_manage.sh"
chmod +x "$SCRIPTS_DEST/timed_session_monitor.sh"

# Copy command
echo ""
echo "Installing command to $COMMANDS_DEST/"
cp "$REPO_DIR/commands/launch.md" "$COMMANDS_DEST/launch.md"
echo "  launch.md"

echo ""
echo "Installation complete!"
echo ""
echo "Usage:"
echo "  /launch 60 \"Build feature X\""
echo "  /launch --until 09:00 \"Improve test coverage\""
echo "  /launch 120 --surge \"Maximize overnight throughput\""
echo ""
echo "Session management:"
echo "  ~/.claude/scripts/timed_session_manage.sh list"
echo "  ~/.claude/scripts/timed_session_manage.sh attach <ID>"
echo "  ~/.claude/scripts/timed_session_manage.sh stop <ID>"
echo ""
