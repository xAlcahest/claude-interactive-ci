#!/usr/bin/env bash
# ===========================================================================
#  interactive-claude.sh — PoC: run Claude Code "interactively" in CI
#
#  Spawns Claude Code inside a tmux PTY session exactly as a human would,
#  sends a prompt via tmux send-keys, waits for completion, and exits.
#
#  From Anthropic's perspective this is indistinguishable from a user
#  opening a terminal, typing a command, and closing it when done.
#  Because that's literally what it is. Just automated.
#
#  Requirements: tmux, claude (Claude Code CLI), jq
# ===========================================================================

set -euo pipefail

# --- Config -----------------------------------------------------------------
SESSION_NAME="claude-interactive-$$"
PROMPT="${1:?Usage: $0 '<prompt>' [timeout_seconds]}"
TIMEOUT="${2:-300}"          # 5 min default, adjust for longer tasks
POLL_INTERVAL=3              # seconds between completion checks
LOG_DIR="${GITHUB_WORKSPACE:-.}/logs"
TRANSCRIPT_DIR="$HOME/.claude/projects"

mkdir -p "$LOG_DIR"

# --- Utilities --------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { log "FATAL: $*" >&2; cleanup; exit 1; }

cleanup() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    # Capture final buffer before killing
    tmux capture-pane -t "$SESSION_NAME" -p > "$LOG_DIR/final-buffer.txt" 2>/dev/null || true
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- Preflight checks -------------------------------------------------------
for cmd in tmux claude jq; do
  command -v "$cmd" &>/dev/null || die "$cmd not found in PATH"
done

# Verify Claude auth is working (quick non-interactive check)
log "Verifying Claude Code authentication..."
if ! claude auth status 2>&1 | grep -qi "logged in\|authenticated\|active"; then
  log "WARN: Auth status unclear — proceeding anyway (may fail)"
fi

# --- Phase 1: Create tmux session with Claude Code -------------------------
log "Creating tmux session: $SESSION_NAME"
tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50

# Give the shell a moment to initialize
sleep 1

# Launch Claude Code interactively (NO -p flag = interactive = subscription pool)
# We set TERM explicitly so Claude Code's TUI renders properly
log "Launching Claude Code interactively..."
tmux send-keys -t "$SESSION_NAME" "TERM=xterm-256color claude --verbose" Enter

# Wait for Claude Code to fully initialize (the TUI needs a moment)
log "Waiting for Claude Code TUI to initialize..."
INIT_TIMEOUT=30
INIT_ELAPSED=0
while [ $INIT_ELAPSED -lt $INIT_TIMEOUT ]; do
  BUFFER=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null || true)
  # Claude Code shows a ">" prompt or the model name when ready
  if echo "$BUFFER" | grep -qE '(>|claude|sonnet|opus|haiku|Enter a prompt)'; then
    log "Claude Code is ready"
    break
  fi
  sleep 1
  INIT_ELAPSED=$((INIT_ELAPSED + 1))
done

if [ $INIT_ELAPSED -ge $INIT_TIMEOUT ]; then
  tmux capture-pane -t "$SESSION_NAME" -p > "$LOG_DIR/init-timeout-buffer.txt"
  die "Claude Code failed to initialize within ${INIT_TIMEOUT}s (buffer saved to logs)"
fi

# --- Phase 2: Send the prompt -----------------------------------------------
log "Sending prompt to Claude Code..."

# For multi-line or long prompts, use bracket paste mode
# This is exactly what your terminal does when you Ctrl+V
if [ ${#PROMPT} -gt 200 ] || echo "$PROMPT" | grep -q $'\n'; then
  # Bracket paste: \033[200~ ... \033[201~
  tmux send-keys -t "$SESSION_NAME" -l "$(printf '\033[200~')${PROMPT}$(printf '\033[201~')"
  sleep 0.5
  tmux send-keys -t "$SESSION_NAME" Enter
else
  tmux send-keys -t "$SESSION_NAME" -l "$PROMPT"
  sleep 0.2
  tmux send-keys -t "$SESSION_NAME" Enter
fi

log "Prompt sent. Waiting for Claude Code to finish..."

# --- Phase 3: Wait for completion -------------------------------------------
ELAPSED=0
LAST_BUFFER=""
STABLE_COUNT=0
STABLE_THRESHOLD=3   # Buffer unchanged for N consecutive polls = done

while [ $ELAPSED -lt $TIMEOUT ]; do
  sleep $POLL_INTERVAL
  ELAPSED=$((ELAPSED + POLL_INTERVAL))

  BUFFER=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null || true)

  # Save periodic snapshots for debugging
  if [ $((ELAPSED % 30)) -eq 0 ]; then
    echo "$BUFFER" > "$LOG_DIR/buffer-${ELAPSED}s.txt"
    log "  ... still working (${ELAPSED}s elapsed)"
  fi

  # Detect completion: Claude Code returns to the input prompt
  # The prompt line typically shows ">" at the start or "Cost: $X.XX"
  LAST_LINE=$(echo "$BUFFER" | grep -v '^$' | tail -1)

  if echo "$LAST_LINE" | grep -qE '^(>|❯|\$)'; then
    # Looks like the prompt returned — but verify it's stable
    if [ "$BUFFER" = "$LAST_BUFFER" ]; then
      STABLE_COUNT=$((STABLE_COUNT + 1))
      if [ $STABLE_COUNT -ge $STABLE_THRESHOLD ]; then
        log "Claude Code finished (output stable for $((STABLE_COUNT * POLL_INTERVAL))s)"
        break
      fi
    else
      STABLE_COUNT=0
    fi
  fi

  # Also check for explicit completion markers
  if echo "$BUFFER" | grep -qE '(Cost:|tokens used|session ended)'; then
    log "Claude Code finished (completion marker detected)"
    break
  fi

  LAST_BUFFER="$BUFFER"
done

if [ $ELAPSED -ge $TIMEOUT ]; then
  log "WARN: Timeout reached (${TIMEOUT}s). Capturing state and proceeding."
fi

# --- Phase 4: Capture output and clean up -----------------------------------
tmux capture-pane -t "$SESSION_NAME" -p -S -500 > "$LOG_DIR/full-output.txt"
log "Output captured to $LOG_DIR/full-output.txt"

# Gracefully exit Claude Code
tmux send-keys -t "$SESSION_NAME" "/exit" Enter
sleep 2

# Try to find the session transcript for structured data
LATEST_TRANSCRIPT=$(find "$TRANSCRIPT_DIR" -name "*.jsonl" -newer "$LOG_DIR" 2>/dev/null | sort -r | head -1 || true)
if [ -n "$LATEST_TRANSCRIPT" ]; then
  cp "$LATEST_TRANSCRIPT" "$LOG_DIR/transcript.jsonl"
  log "Session transcript saved to $LOG_DIR/transcript.jsonl"
fi

log "Done. Session: $SESSION_NAME"
