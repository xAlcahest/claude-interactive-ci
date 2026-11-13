#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq filters and Python snippets use $ literally
#
# Offline test suite for bin/claude-interactive.
#
# Every "run" test drives the real driver against tests/fake-claude, a mock of
# the Claude Code TUI, inside a real private tmux server. Nothing talks to the
# network and the user's Claude Code configuration is never touched: each test
# gets its own temp dir, HOME and CLAUDE_CONFIG_DIR.
#
# Usage: tests/run.sh [-j JOBS] [-l] [-h] [NAME|GLOB ...]
#   NAME|GLOB  Run only matching tests ("t_" prefix optional, shell globs
#              allowed, e.g. 'usage_*').
#   -j JOBS    Tests run in parallel (default: $JOBS or 4).
#   -l         List the tests and exit.
#
# Environment:
#   BASH_UNDER_TEST  bash that runs the driver (default: the one running this).
#   DRIVER_UNDER_TEST  driver script to test (default: bin/claude-interactive).
#   KEEP_TMP=1       Keep the temp dirs; failing tests print their path.
#   VERBOSE=1        Print every test's log, not only failing ones.
#
# Works with bash 3.2 (macOS /bin/bash) and bash 5. Needs tmux, jq, python3.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SUITE=$ROOT/tests/$(basename "$0")
DRIVER=${DRIVER_UNDER_TEST:-$ROOT/bin/claude-interactive}
FAKE=$ROOT/tests/fake-claude
BASH_UNDER_TEST=${BASH_UNDER_TEST:-$BASH}
JOBS=${JOBS:-4}
KEEP_TMP=${KEEP_TMP:-0}
VERBOSE=${VERBOSE:-0}

# =============================================================================
# Helpers available to tests
# =============================================================================

cgrep() { LC_ALL=C grep "$@"; }
now_ms() { python3 -I -c 'import time; print(int(time.time() * 1000))'; }

# Print the context of a failure: the driver's view and the mock's view.
dump_context() {
  if [ -n "${OUT:-}" ] && [ -f "$OUT/driver.log" ]; then
    printf -- '--- %s/driver.log (tail)\n' "$OUT"
    tail -n 25 "$OUT/driver.log"
  fi
  if [ -n "${OUT:-}" ] && [ -f "$OUT/result.json" ]; then
    printf -- '--- result.json: '
    jq -c '{status, exit_code, reason, turns: [.turns[] | {status, error}]}' "$OUT/result.json" 2>/dev/null
  fi
  if [ -n "${T:-}" ] && [ -s "$T/stderr" ] && [ ! -f "${OUT:-/nonexistent}/driver.log" ]; then
    printf -- '--- stderr (tail)\n'
    tail -n 10 "$T/stderr"
  fi
  if [ -n "${FAKE_CLAUDE_LOG:-}" ] && [ -f "$FAKE_CLAUDE_LOG" ]; then
    printf -- '--- fake-claude log\n'
    jq -c 'del(.env, .env_names, .t) | if .text then .text |= .[0:80] else . end
           | if .command then .command |= (split(" ") | .[-2]) else . end' "$FAKE_CLAUDE_LOG" 2>/dev/null |
      cut -c1-220 | tail -n 20
  fi
}

fail() {
  printf 'FAIL: %s\n' "$*"
  dump_context
  exit 1
}

expect_rc() { [ "$RC" = "$1" ] || fail "exit status $RC, expected $1"; }

# expect_eq WHAT EXPECTED ACTUAL
expect_eq() { [ "$2" = "$3" ] || fail "$1: got [$3], expected [$2]"; }

# expect_json FILE FILTER EXPECTED: jq -r FILTER must print exactly EXPECTED.
expect_json() {
  local got
  got=$(jq -r "$2" "$1" 2>&1)
  [ "$got" = "$3" ] || fail "${1##*/}: $2 = [$got], expected [$3]"
}

# expect_jq FILE FILTER [JQ ARGS...]: the filter must evaluate to true.
expect_jq() {
  local file=$1 filter=$2
  shift 2
  jq -e "$@" "$filter" "$file" >/dev/null 2>&1 || fail "${file##*/}: expected $filter to hold"
}

expect_grep() { cgrep -Eq -- "$2" "$1" 2>/dev/null || fail "${1##*/} does not match /$2/"; }
expect_no_grep() { ! cgrep -Eq -- "$2" "$1" 2>/dev/null || fail "${1##*/} unexpectedly matches /$2/"; }

# expect_bytes FILE TEXT: FILE holds exactly TEXT, byte for byte.
expect_bytes() {
  printf '%s' "$2" >"$T/.expected"
  [ -f "$1" ] || fail "missing file ${1#"$T"/}"
  cmp -s "$T/.expected" "$1" || fail "${1#"$T"/} is [$(head -c 200 "$1")], expected [$2]"
}

# expect_same_file EXPECTED ACTUAL
expect_same_file() {
  [ -f "$2" ] || fail "missing file ${2#"$T"/}"
  cmp -s "$1" "$2" || fail "${2#"$T"/} differs from ${1#"$T"/}: $(cmp "$1" "$2" 2>&1 | head -n 1)"
}

# Run "claude-interactive run" against the fake Claude Code. The output dir is
# $T/$RUN_NAME (default "out"); sets OUT and RC, stdout/stderr go to $T/stdout
# and $T/stderr. Later options override the defaults given here.
run_ci() {
  OUT=$T/${RUN_NAME:-out}
  "$BASH_UNDER_TEST" "$DRIVER" run --claude-bin "$FAKE" -C "$WORK" -o "$OUT" \
    --startup-timeout 20 --timeout 90 "$@" >"$T/stdout" 2>"$T/stderr" </dev/null
  RC=$?
}

# Run a driver subcommand directly; sets RC, output in $T/stdout and $T/stderr.
ci() {
  "$BASH_UNDER_TEST" "$DRIVER" "$@" >"$T/stdout" 2>"$T/stderr"
  RC=$?
}

result() { printf '%s/result.json' "$OUT"; }

tmux_socket() {
  sed -n 's/.*tmux -L \([^ ]*\) attach.*/\1/p' "${1:-$OUT}/driver.log" 2>/dev/null | head -n 1
}

expect_no_tmux() {
  local sock
  sock=$(tmux_socket "${1:-$OUT}")
  [ -n "$sock" ] || fail "no tmux socket name in driver.log"
  if env -u TMUX tmux -L "$sock" has-session 2>/dev/null; then
    fail "tmux server $sock is still running"
  fi
}

# expect_dead PID WHAT: the process must be gone (zombies count as gone).
expect_dead() {
  local state
  if kill -0 "$1" 2>/dev/null; then
    state=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
    case $state in Z*) ;; *) fail "$2 (pid $1) is still alive" ;; esac
  fi
}

# Mock log accessors.
fake_prompt() { jq -j --argjson n "$1" 'select(.kind == "prompt" and .turn == $n) | .text' "$FAKE_CLAUDE_LOG"; }
fake_prompt_id() { jq -r --argjson n "$1" 'select(.kind == "prompt" and .turn == $n) | .prompt_id' "$FAKE_CLAUDE_LOG"; }
fake_start() { jq -r "select(.kind == \"start\") | $1" "$FAKE_CLAUDE_LOG" | head -n 1; }
fake_count() { jq -c "select($1)" "$FAKE_CLAUDE_LOG" 2>/dev/null | wc -l | tr -d ' '; }
fake_dialogs() { jq -r 'select(.kind == "dialog") | "\(.name)=\(.choice)"' "$FAKE_CLAUDE_LOG" | tr '\n' ';'; }
event_names() { jq -r '.hook_event_name' "$OUT/events.jsonl" | tr '\n' ' ' | sed 's/ $//'; }

# wait_for SECONDS COMMAND...: poll until COMMAND succeeds.
wait_for() {
  local limit=$1 i=0
  shift
  while ! "$@" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le $((limit * 5)) ] || return 1
    sleep 0.2
  done
}

# with_default_sigint PIDFILE COMMAND...: exec COMMAND with SIGINT at its
# default and its pid in PIDFILE. A background job of a non-interactive shell
# starts with SIGINT ignored, and a script cannot trap a signal that was
# ignored on entry; $! of a backgrounded function is also not COMMAND's pid.
with_default_sigint() {
  python3 -I -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
with open(sys.argv[1], "w") as f:
    f.write("%d\n" % os.getpid())
os.execvp(sys.argv[2], sys.argv[2:])' "$@"
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# Write a prompt file without a trailing newline from a quoted heredoc.
prompt_file() { local s; s=$(cat); printf '%s' "$s" >"$1"; }

# =============================================================================
# Tests: one function per test, named t_<name>, run in definition order.
# Each runs in a subshell with cwd $T, and these variables:
#   T     the test's private temp dir     WORK  workdir for Claude Code
#   FAKE_CLAUDE_HOME, FAKE_CLAUDE_LOG, CLAUDE_CONFIG_DIR, HOME under $T
# =============================================================================

# --- 1. single turn ------------------------------------------------------------

t_single_turn_success() {
  run_ci "Say hello"
  expect_rc 0
  printf 'ECHO: Say hello\n' >"$T/expected.stdout"
  expect_same_file "$T/expected.stdout" "$T/stdout"
  R=$(result)
  expect_json "$R" .schema_version 1
  expect_json "$R" .status success
  expect_json "$R" .exit_code 0
  expect_json "$R" .reason "all 1 turn(s) completed"
  expect_json "$R" .session_id "$(fake_start .session_id)"
  expect_json "$R" .turns_total 1
  expect_json "$R" .turns_completed 1
  expect_json "$R" '.turns[0].index' 1
  expect_json "$R" '.turns[0].status' completed
  expect_json "$R" '.turns[0].prompt_id' "$(fake_prompt_id 1)"
  expect_json "$R" '.turns[0].duration_seconds | type' number
  expect_json "$R" '.turns[0].last_assistant_message' "ECHO: Say hello"
  expect_json "$R" .final_message "ECHO: Say hello"
  expect_json "$R" .claude_exit_status 0
  expect_json "$R" .session_end_reason prompt_input_exit
  expect_json "$R" .claude_version "2.1.314 (Claude Code)"
  expect_json "$R" .transcript transcript.jsonl
  expect_jq "$R" '.usage == {total_cost_usd: 0.01, api_duration_ms: 10, lines_added: 0, lines_removed: 0,
                             model_usage: {fake: {inputTokens: 1, outputTokens: 1}}}'
  expect_no_tmux
}

t_single_turn_artifacts() {
  run_ci "Say hello"
  expect_rc 0
  expect_bytes "$OUT/final-message.txt" "ECHO: Say hello"
  expect_bytes "$OUT/turns/01.prompt.txt" "Say hello"
  expect_bytes "$OUT/turns/01.response.txt" "ECHO: Say hello"
  expect_eq "hook events" "SessionStart UserPromptSubmit Stop SessionEnd" "$(event_names)"
  expect_jq "$OUT/events.jsonl" '[.[].seq] as $s | ($s | all(type == "number")) and $s == ($s | sort | unique)' -s
  expect_jq "$OUT/events.jsonl" 'all(.received_at | type == "string")' -s
  expect_grep "$OUT/screen.txt" 'ECHO: Say hello'
  expect_grep "$OUT/driver.log" 'Success: all 1 turn'
  expect_json "$OUT/transcript.jsonl" 'select(.type == "cost-state") | .totalCostUSD' 0.01
  expect_eq "transcript copy" "$(cat "$(fake_start .transcript_path)")" "$(cat "$OUT/transcript.jsonl")"
  # The hook recorder must print nothing: SessionStart and UserPromptSubmit
  # hook output would be injected into the model context.
  expect_eq "hook runs" 4 "$(fake_count '.kind == "hook"')"
  expect_eq "noisy or failing hooks" 0 "$(fake_count '.kind == "hook" and (.rc != 0 or .stdout != "" or .stderr != "")')"
  expect_no_tmux
}

t_json_flag_prints_result() {
  run_ci --json "Say hello"
  expect_rc 0
  expect_jq "$T/stdout" '.status == "success" and .final_message == "ECHO: Say hello"'
  expect_eq "stdout vs result.json" "$(jq -S . "$(result)")" "$(jq -S . "$T/stdout")"
  expect_no_tmux
}

# --- 2. multiple turns -----------------------------------------------------------

t_three_turns_exact_prompts() {
  prompt_file "$T/p1.txt" <<'EOF'
He said "hi" & 'bye'; costs $5 `uname` $(id -u) ${HOME} \n \\ <tag> * ? [a] ~ ;|
EOF
  prompt_file "$T/p2.txt" <<'EOF'
line one
  indented two

line four after a blank line
	tab-indented five
EOF
  prompt_file "$T/p3.txt" <<'EOF'
Ünïcödé ✓ — "double" 'single' $PATH `whoami` $(echo hi) %s %n \t
second line   with inner spaces
EOF
  run_ci "$(cat "$T/p1.txt")" -f "$T/p2.txt" -p "$(cat "$T/p3.txt")"
  expect_rc 0
  R=$(result)
  expect_json "$R" .turns_total 3
  expect_json "$R" .turns_completed 3
  local i
  for i in 1 2 3; do
    fake_prompt "$i" >"$T/got$i.txt"
    expect_same_file "$T/p$i.txt" "$T/got$i.txt"
    expect_same_file "$T/p$i.txt" "$OUT/turns/0$i.prompt.txt"
    expect_bytes "$OUT/turns/0$i.response.txt" "ECHO: $(head -n 1 "$T/p$i.txt")"
    expect_json "$R" ".turns[$((i - 1))].last_assistant_message" "ECHO: $(head -n 1 "$T/p$i.txt")"
  done
  expect_eq "prompt sources" "argv input input" \
    "$(jq -r 'select(.kind == "prompt") | .source' "$FAKE_CLAUDE_LOG" | tr '\n' ' ' | sed 's/ $//')"
  # Distinct prompt ids, each matching its UserPromptSubmit and its Stop.
  expect_jq "$OUT/events.jsonl" '
    ($r[0].turns | map(.prompt_id)) as $ids
    | ($ids | unique | length) == 3 and all($ids[]; type == "string")
      and ([.[] | select(.hook_event_name == "UserPromptSubmit") | .prompt_id] == $ids)
      and ([.[] | select(.hook_event_name == "Stop") | .prompt_id] == $ids)' -s --slurpfile r "$R"
  expect_jq "$OUT/events.jsonl" '[.[] | select(.hook_event_name == "UserPromptSubmit") | .prompt]
    == [$p1, $p2, $p3]' -s --rawfile p1 "$T/p1.txt" --rawfile p2 "$T/p2.txt" --rawfile p3 "$T/p3.txt"
  printf 'ECHO: %s\n' "$(head -n 1 "$T/p3.txt")" >"$T/expected.stdout"
  expect_same_file "$T/expected.stdout" "$T/stdout"
  expect_no_tmux
}

# --- 3. startup dialogs ---------------------------------------------------------

t_trust_and_bypass_dialogs() {
  FAKE_CLAUDE_SCENARIO=trust_bypass run_ci "hello"
  expect_rc 0
  expect_eq "dialog choices" "trust=Yes, I trust this folder;bypass=Yes, I accept;" "$(fake_dialogs)"
  expect_eq "Enter presses" 2 "$(cgrep -c 'dialog matched.*pressing Enter' "$OUT/driver.log")"
  expect_json "$(result)" .final_message "ECHO: hello"
  expect_no_tmux
}

t_numbered_dialog_options() {
  FAKE_CLAUDE_SCENARIO=trust_bypass FAKE_CLAUDE_NUMBERED=1 run_ci "hello"
  expect_rc 0
  expect_eq "dialog choices" "trust=Yes, I trust this folder;bypass=Yes, I accept;" "$(fake_dialogs)"
  expect_no_tmux
}

t_theme_picker_enter() {
  FAKE_CLAUDE_SCENARIO=theme run_ci "hello"
  expect_rc 0
  expect_eq "dialog choices" "theme=Dark mode;" "$(fake_dialogs)"
  expect_no_tmux
}

t_api_key_dialog_wrapping_menu() {
  FAKE_CLAUDE_SCENARIO=api_key FAKE_CLAUDE_MENU_WRAP=1 run_ci "hello"
  expect_rc 0
  expect_eq "dialog choices" "api_key=Yes;" "$(fake_dialogs)"
  expect_no_tmux
}

# The API key dialog preselects "No (recommended)" with "Yes" above it. If the
# menu does not wrap around, pressing only Down can never reach "Yes".
t_api_key_dialog_non_wrapping_menu() {
  FAKE_CLAUDE_SCENARIO=api_key run_ci --startup-timeout 15 "hello"
  expect_rc 0
  expect_eq "dialog choices" "api_key=Yes;" "$(fake_dialogs)"
  expect_no_tmux
}

t_setup_then_run_skips_dialogs() {
  CI=true ci setup --trust "$WORK"
  expect_rc 0
  FAKE_CLAUDE_SCENARIO=trust_bypass run_ci "hello"
  expect_rc 0
  expect_eq "dialogs shown" "" "$(fake_dialogs)"
  expect_no_grep "$OUT/driver.log" 'dialog matched'
  expect_no_tmux
}

# --- 4. authentication -----------------------------------------------------------

t_login_wizard_auth_failed() {
  FAKE_CLAUDE_SCENARIO=login run_ci "hello"
  expect_rc 11
  expect_json "$(result)" .status auth_failed
  expect_json "$(result)" .exit_code 11
  expect_grep "$(result)" 'Select login method'
  expect_eq "prompts received" 0 "$(fake_count '.kind == "prompt"')"
  expect_no_tmux
}

t_not_logged_in_exit_auth_failed() {
  FAKE_CLAUDE_SCENARIO=login_exit run_ci "hello"
  expect_rc 11
  expect_json "$(result)" .status auth_failed
  expect_json "$(result)" .reason "Claude Code exited: Not logged in"
  expect_json "$(result)" .claude_exit_status 1
  expect_no_tmux
}

t_fatal_pattern_auth_failed() {
  FAKE_CLAUDE_SCENARIO=unknown_dialog run_ci --fatal 'frobnicates by default' "hello"
  expect_rc 11
  expect_json "$(result)" .status auth_failed
  expect_grep "$(result)" 'frobnicates by default'
  expect_no_tmux
}

# --- 5. API errors -----------------------------------------------------------------

t_stop_failure_api_error() {
  FAKE_CLAUDE_SCENARIO=stop_failure run_ci "hello"
  expect_rc 15
  R=$(result)
  expect_json "$R" .status api_error
  expect_json "$R" .exit_code 15
  expect_json "$R" '.turns[0].status' api_error
  expect_json "$R" '.turns[0].error' rate_limit
  expect_json "$R" '.turns[0].last_assistant_message' "API Error: Rate limit reached"
  expect_json "$R" .turns_completed 0
  expect_json "$R" .final_message null
  expect_bytes "$T/stdout" ""
  expect_jq "$OUT/events.jsonl" 'any(.[]; .hook_event_name == "StopFailure" and .error == "rate_limit")' -s
  expect_no_tmux
}

# --- 6. blocked on input -------------------------------------------------------------

t_permission_prompt_blocked() {
  FAKE_CLAUDE_SCENARIO=permission run_ci "hello"
  expect_rc 14
  R=$(result)
  expect_json "$R" .status blocked
  expect_json "$R" '.turns[0].status' blocked
  expect_json "$R" '.turns[0].error' permission_prompt
  expect_grep "$R" 'Claude needs your permission to use Bash'
  expect_no_tmux
}

t_idle_prompt_mid_turn_blocked() {
  FAKE_CLAUDE_SCENARIO=permission FAKE_CLAUDE_NOTIFY_TYPE=idle_prompt run_ci "hello"
  expect_rc 14
  expect_json "$(result)" '.turns[0].error' idle_prompt
  expect_no_tmux
}

t_idle_prompt_between_turns_ignored() {
  FAKE_CLAUDE_SCENARIO=idle_notify run_ci "one" "two"
  expect_rc 0
  expect_json "$(result)" .turns_completed 2
  expect_jq "$OUT/events.jsonl" 'any(.[]; .notification_type == "idle_prompt")' -s
  expect_no_tmux
}

# --- 7. timeouts -------------------------------------------------------------------

t_turn_timeout() {
  FAKE_CLAUDE_SCENARIO=hang run_ci --turn-timeout 3 "hello"
  expect_rc 13
  R=$(result)
  expect_json "$R" .status timeout
  expect_json "$R" '.turns[0].status' timeout
  expect_json "$R" '.turns[0].error' "turn timeout"
  expect_grep "$R" 'turn 1 did not finish within 3s'
  expect_jq "$R" '.duration_seconds < 15'
  expect_no_tmux
}

t_run_timeout() {
  FAKE_CLAUDE_SCENARIO=hang run_ci --timeout 4 "hello"
  expect_rc 13
  R=$(result)
  expect_json "$R" .status timeout
  expect_json "$R" '.turns[0].status' timeout
  expect_json "$R" '.turns[0].error' "run timeout"
  expect_grep "$R" 'run did not finish within 4s'
  expect_no_tmux
}

# Leading zeros pass validation, but $((RUN_T0 + TIMEOUT)) reads them as octal.
t_timeout_with_leading_zero() {
  run_ci --timeout 090 "hello"
  expect_rc 0
  expect_no_tmux
}

# --- 8. Claude Code exits ------------------------------------------------------------

t_claude_crash_mid_turn() {
  FAKE_CLAUDE_SCENARIO=crash run_ci "hello"
  expect_rc 12
  R=$(result)
  expect_json "$R" .status claude_exited
  expect_json "$R" .claude_exit_status 3
  expect_json "$R" '.turns[0].status' failed
  expect_json "$R" '.turns[0].error' "claude exited"
  expect_grep "$R" 'exited with status 3 during turn 1'
  expect_no_grep "$R" 'Pane is dead'
  expect_no_tmux
}

# The reason should carry Claude Code's last words, which come after the TUI's
# full-width horizontal rules in the scrollback.
t_claude_crash_reason_shows_last_output() {
  FAKE_CLAUDE_SCENARIO=crash run_ci "hello"
  expect_rc 12
  expect_grep "$(result)" 'Error: simulated crash \(exit status 3\)'
}

t_relative_claude_bin() {
  OUT=$T/out
  (cd "$ROOT" && "$BASH_UNDER_TEST" "$DRIVER" run --claude-bin tests/fake-claude \
    -C "$WORK" -o "$OUT" --timeout 60 "hello" >"$T/stdout" 2>"$T/stderr" </dev/null)
  RC=$?
  expect_rc 0
  expect_no_tmux
}

# --- 9. later prompts not accepted ---------------------------------------------------

t_turn2_paste_ignored_submit_failed() {
  FAKE_CLAUDE_SCENARIO=ignore_input_turn2 run_ci --submit-timeout 20 "one" "two"
  expect_rc 10
  R=$(result)
  expect_json "$R" .status submit_failed
  expect_json "$R" '.turns[0].status' completed
  expect_json "$R" '.turns[1].status' failed
  expect_json "$R" '.turns[1].error' "not accepted"
  expect_grep "$R" 'turn 2 was not accepted within 20s'
  expect_grep "$OUT/driver.log" 'not accepted after 15s, pressing Enter again'
  expect_eq "prompts received" 1 "$(fake_count '.kind == "prompt"')"
  expect_no_tmux
}

t_turn2_lost_enter_retried() {
  FAKE_CLAUDE_SCENARIO=ignore_enter_turn2 run_ci --submit-timeout 30 "one" "two"
  expect_rc 0
  expect_grep "$OUT/driver.log" 'pressing Enter again'
  expect_eq "turn 2 prompts received" 1 "$(fake_count '.kind == "prompt" and .turn == 2')"
  expect_bytes "$OUT/final-message.txt" "ECHO: two"
  expect_no_tmux
}

# --- 10. unknown dialogs ------------------------------------------------------------

t_unknown_dialog_startup_timeout() {
  FAKE_CLAUDE_SCENARIO=unknown_dialog run_ci --startup-timeout 5 "hello"
  expect_rc 10
  R=$(result)
  expect_json "$R" .status startup_failed
  expect_grep "$R" 'not accepted within 5s'
  expect_grep "$R" 'Frobnicator|frobnicat'
  expect_eq "prompts received" 0 "$(fake_count '.kind == "prompt"')"
  expect_no_tmux
}

t_unknown_dialog_custom_rule() {
  FAKE_CLAUDE_SCENARIO=unknown_dialog run_ci --startup-timeout 15 \
    --dialog 'Frobnicator settings changed::Yes, keep frobnicating' "hello"
  expect_rc 0
  expect_eq "dialog choices" "unknown_dialog=Yes, keep frobnicating;" "$(fake_dialogs)"
  expect_no_tmux
}

# After a failed startup no turn should still be reported as "running".
t_failed_startup_leaves_no_running_turn() {
  FAKE_CLAUDE_SCENARIO=unknown_dialog run_ci --startup-timeout 3 "hello"
  expect_rc 10
  expect_jq "$(result)" 'all(.turns[]; .status != "running")'
}

# --- 11. large prompts ---------------------------------------------------------------

t_large_first_prompt_is_pasted() {
  python3 -I -c '
import sys
lines = ["line %05d: quotes \" '"'"' $HOME `x` \\ tab\t end" % i for i in range(1500)]
sys.stdout.write("\n".join(lines))' >"$T/big.txt"
  [ "$(wc -c <"$T/big.txt" | tr -d ' ')" -gt 65536 ] || fail "test prompt is not larger than 64 KiB"
  FAKE_CLAUDE_REPLY='LEN {prompt_chars}' run_ci -f "$T/big.txt"
  expect_rc 0
  expect_no_grep "$OUT/internal/launch.sh" 'prompt\.txt'
  expect_eq "argv prompt" null "$(fake_start .initial_prompt)"
  expect_eq "prompt source" input "$(jq -r 'select(.kind == "prompt") | .source' "$FAKE_CLAUDE_LOG")"
  fake_prompt 1 >"$T/got.txt"
  expect_same_file "$T/big.txt" "$T/got.txt"
  expect_bytes "$OUT/final-message.txt" "LEN $(python3 -I -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$T/big.txt")"
  expect_no_tmux
}

t_argv_limit_boundary() {
  head -c 65536 /dev/zero | tr '\0' 'a' >"$T/at.txt"
  head -c 65537 /dev/zero | tr '\0' 'a' >"$T/over.txt"
  RUN_NAME=limit run_ci --dry-run -f "$T/at.txt"
  expect_rc 0
  expect_grep "$T/limit/internal/launch.sh" ' -- "\$\(cat '
  RUN_NAME=above run_ci --dry-run -f "$T/over.txt"
  expect_rc 0
  expect_no_grep "$T/above/internal/launch.sh" ' -- '
}

# --- 12. environment -----------------------------------------------------------------

t_parent_session_env_scrubbed() {
  export CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=x CLAUDE_CODE_ENTRYPOINT=cli \
    CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_MESSAGING_SOCKET=/x \
    CLAUDE_CODE_MESSAGING_TOKEN=t CLAUDE_CODE_EXECPATH=/x CLAUDE_CODE_SSE_PORT=1 CLAUDE_PID=1 \
    CLAUDE_AGENT_SDK_VERSION=1
  export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-fake FAKE_CLAUDE_MARKER=kept
  FAKE_CLAUDE_SCENARIO=echo_env run_ci "hello"
  expect_rc 0
  expect_bytes "$OUT/final-message.txt" "ENV CLAUDECODE=<unset> CLAUDE_CODE_SESSION_ID=<unset>"
  local v leaked=""
  for v in CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION \
    CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN \
    CLAUDE_CODE_EXECPATH CLAUDE_CODE_SSE_PORT CLAUDE_PID CLAUDE_AGENT_SDK_VERSION; do
    if [ "$(fake_start ".env_names | index(\"$v\") != null")" = true ]; then leaked="$leaked $v"; fi
  done
  expect_eq "parent session variables seen by Claude Code" "" "$leaked"
  expect_eq "unrelated variable" kept "$(fake_start .env.FAKE_CLAUDE_MARKER)"
  expect_eq "OAuth token passed through" true "$(fake_start '.env_names | index("CLAUDE_CODE_OAUTH_TOKEN") != null')"
  expect_no_grep "$OUT/internal/launch.sh" 'sk-ant-oat01-fake'
  expect_no_tmux
}

# --- 13. tmux cleanup ---------------------------------------------------------------

t_no_tmux_server_after_success() {
  run_ci "hello"
  expect_rc 0
  expect_no_tmux
  expect_eq "mock processes alive" "" "$(for f in "$FAKE_CLAUDE_HOME"/pids/*; do [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null && echo "$f"; done)"
}

t_no_tmux_server_after_failure() {
  FAKE_CLAUDE_SCENARIO=permission run_ci "hello"
  expect_rc 14
  expect_no_tmux
  expect_dead "$(fake_start .pid)" "fake Claude Code"
}

t_stubborn_processes_killed() {
  FAKE_CLAUDE_SCENARIO=orphan_child FAKE_CLAUDE_IGNORE_SIGNALS=1 run_ci --timeout 4 "hello"
  expect_rc 13
  local child
  child=$(jq -r 'select(.kind == "child") | .child_pid' "$FAKE_CLAUDE_LOG")
  [ -n "$child" ] || fail "the mock did not start its child"
  expect_dead "$(fake_start .pid)" "fake Claude Code ignoring SIGHUP/SIGTERM"
  expect_dead "$child" "child ignoring SIGHUP/SIGTERM in its own session"
  expect_grep "$OUT/driver.log" 'ignored SIGTERM'
  expect_no_tmux
}

t_keep_session_leaves_tmux() {
  run_ci --keep-session "hello"
  expect_rc 0
  local sock
  sock=$(tmux_socket)
  expect_grep "$OUT/driver.log" "Session left running. Attach with: tmux -L $sock attach"
  env -u TMUX tmux -L "$sock" has-session 2>/dev/null || fail "tmux server $sock is gone despite --keep-session"
  env -u TMUX tmux -L "$sock" kill-server 2>/dev/null
}

# --- 14. hook recorder -----------------------------------------------------------------

t_hook_recorder_parallel() {
  local d=$T/events i pids="" p bad=0
  mkdir -p "$d/.seq"
  i=0
  while [ "$i" -lt 50 ]; do
    printf '{"hook_event_name":"Stop","n":%d}' "$i" |
      "$BASH_UNDER_TEST" "$DRIVER" __hook Stop "$d" >"$T/hook.$i.out" 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
  done
  for p in $pids; do wait "$p" || bad=$((bad + 1)); done
  expect_eq "non-zero exits" 0 "$bad"
  expect_eq "hook output bytes" 0 "$(cat "$T"/hook.*.out | wc -c | tr -d ' ')"
  expect_eq "event files" 50 "$(find "$d" -maxdepth 1 -name '[0-9][0-9][0-9][0-9][0-9][0-9]-Stop.json' | wc -l | tr -d ' ')"
  expect_eq "other files" 0 "$(find "$d" -maxdepth 1 -type f ! -name '[0-9][0-9][0-9][0-9][0-9][0-9]-Stop.json' | wc -l | tr -d ' ')"
  expect_eq "distinct sequence numbers" 50 \
    "$(find "$d" -maxdepth 1 -name '*-Stop.json' | sed 's|.*/||; s/-.*//' | sort -u | wc -l | tr -d ' ')"
  cat "$d"/*-Stop.json >"$T/all.json"
  expect_jq "$T/all.json" 'map(.n) | sort == [range(50)]' -s
}

t_hook_recorder_missing_dir() {
  printf '{"x":1}' | "$BASH_UNDER_TEST" "$DRIVER" __hook Stop "$T/missing" >"$T/out.txt" 2>&1
  RC=$?
  expect_rc 0
  expect_bytes "$T/out.txt" ""
  [ ! -e "$T/missing" ] || fail "the hook created the missing directory"
}

t_hook_recorder_rejects_bad_event_name() {
  mkdir -p "$T/events/.seq"
  printf '{"x":1}' | "$BASH_UNDER_TEST" "$DRIVER" __hook '../Stop' "$T/events" >"$T/out.txt" 2>&1
  RC=$?
  expect_rc 0
  expect_bytes "$T/out.txt" ""
  expect_eq "files written" "" "$(find "$T" -name '*Stop*.json')"
}

# --- 15. setup --------------------------------------------------------------------------

t_setup_refuses_outside_ci() {
  (unset CI; ci setup --trust "$WORK"; echo "$RC" >"$T/rc")
  RC=$(cat "$T/rc")
  expect_rc 2
  expect_grep "$T/stderr" 'outside CI pass --force'
  [ ! -e "$CLAUDE_CONFIG_DIR/.claude.json" ] || fail ".claude.json was written"
}

t_setup_force_outside_ci() {
  (unset CI; ci setup --force --trust "$WORK"; echo "$RC" >"$T/rc")
  RC=$(cat "$T/rc")
  expect_rc 0
  expect_json "$CLAUDE_CONFIG_DIR/.claude.json" .hasCompletedOnboarding true
}

t_setup_writes_config() {
  mkdir -p "$T/real"
  ln -s "$T/real" "$T/link"
  CI=true ci setup --trust "$T/link"
  expect_rc 0
  C=$CLAUDE_CONFIG_DIR/.claude.json
  expect_json "$C" .hasCompletedOnboarding true
  expect_json "$C" .theme dark
  expect_json "$C" ".projects[\"$T/link\"].hasTrustDialogAccepted" true
  expect_json "$C" ".projects[\"$(cd "$T/real" && pwd -P)\"].hasTrustDialogAccepted" true
  expect_json "$CLAUDE_CONFIG_DIR/settings.json" .skipDangerousModePermissionPrompt true
}

t_setup_keeps_existing_keys() {
  printf '%s\n' '{"theme":"light","userID":"u1","projects":{"/other":{"allowedTools":["Bash"]}}}' \
    >"$CLAUDE_CONFIG_DIR/.claude.json"
  printf '%s\n' '{"model":"opus","env":{"A":"1"},"skipDangerousModePermissionPrompt":false}' \
    >"$CLAUDE_CONFIG_DIR/settings.json"
  CI=true ci setup --trust "$WORK"
  expect_rc 0
  C=$CLAUDE_CONFIG_DIR/.claude.json
  expect_json "$C" .theme light
  expect_json "$C" .userID u1
  expect_json "$C" '.projects["/other"].allowedTools[0]' Bash
  expect_json "$C" ".projects[\"$WORK\"].hasTrustDialogAccepted" true
  S=$CLAUDE_CONFIG_DIR/settings.json
  expect_json "$S" .model opus
  expect_json "$S" .env.A 1
  expect_json "$S" .skipDangerousModePermissionPrompt true
}

t_setup_files_are_private() {
  printf '{}\n' >"$CLAUDE_CONFIG_DIR/.claude.json"
  chmod 644 "$CLAUDE_CONFIG_DIR/.claude.json"
  CI=true ci setup --trust "$WORK"
  expect_rc 0
  expect_eq ".claude.json mode" 600 "$(file_mode "$CLAUDE_CONFIG_DIR/.claude.json")"
  expect_eq "settings.json mode" 600 "$(file_mode "$CLAUDE_CONFIG_DIR/settings.json")"
}

t_setup_base_config_merge() {
  printf '%s\n' '{"userID":"u1","projects":{"/other":{"a":1}}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
  printf '%s\n' '{"oauthAccount":{"accountUuid":"acc"},"theme":"light-daltonized","projects":{"/b":{"k":2}}}' \
    >"$T/base.json"
  CI=true ci setup --base-config "$T/base.json" --trust "$WORK"
  expect_rc 0
  C=$CLAUDE_CONFIG_DIR/.claude.json
  expect_json "$C" .userID u1
  expect_json "$C" .oauthAccount.accountUuid acc
  expect_json "$C" .theme light-daltonized
  expect_json "$C" '.projects["/other"].a' 1
  expect_json "$C" '.projects["/b"].k' 2
  expect_json "$C" ".projects[\"$WORK\"].hasTrustDialogAccepted" true
  expect_json "$C" .hasCompletedOnboarding true
}

t_setup_base_config_stdin() {
  printf '%s' '{"userID":"from-stdin"}' | CI=true "$BASH_UNDER_TEST" "$DRIVER" setup --base-config - \
    --trust "$WORK" >"$T/stdout" 2>"$T/stderr"
  RC=$?
  expect_rc 0
  expect_json "$CLAUDE_CONFIG_DIR/.claude.json" .userID from-stdin
}

t_setup_rejects_non_object_base_config() {
  printf '[1,2]' >"$T/base.json"
  CI=true ci setup --base-config "$T/base.json" --trust "$WORK"
  expect_rc 2
}

t_setup_rejects_non_object_config() {
  printf '[1]\n' >"$CLAUDE_CONFIG_DIR/.claude.json"
  CI=true ci setup --trust "$WORK"
  [ "$RC" != 0 ] || fail "setup accepted a .claude.json that is not an object"
  expect_bytes "$CLAUDE_CONFIG_DIR/.claude.json" '[1]
'
}

t_setup_missing_trust_dir() {
  CI=true ci setup --trust "$T/nope"
  expect_rc 2
}

t_setup_home_fallback() {
  (unset CLAUDE_CONFIG_DIR; CI=true ci setup --trust "$WORK"; echo "$RC" >"$T/rc")
  RC=$(cat "$T/rc")
  expect_rc 0
  expect_json "$HOME/.claude.json" .hasCompletedOnboarding true
  expect_json "$HOME/.claude/settings.json" .skipDangerousModePermissionPrompt true
}

# --- 16. usage errors --------------------------------------------------------------------

t_usage_no_prompt() { ci run --claude-bin "$FAKE"; expect_rc 2; expect_grep "$T/stderr" 'no prompt given'; }
t_usage_bad_number() { ci run --timeout abc hello; expect_rc 2; expect_grep "$T/stderr" "non-negative integer, got 'abc'"; }
t_usage_negative_number() { ci run --turn-timeout -1 hello; expect_rc 2; }
t_usage_zero_timeout() { ci run --timeout 0 hello; expect_rc 2; }
t_usage_unknown_option() { ci run --bogus hello; expect_rc 2; expect_grep "$T/stderr" 'unknown option: --bogus'; }
t_usage_bad_dialog_format() { ci run --dialog 'no separator' hello; expect_rc 2; expect_grep "$T/stderr" 'REGEX::LABEL'; }
t_usage_missing_option_value() { ci run hello --timeout; expect_rc 2; expect_grep "$T/stderr" 'needs a value'; }
t_usage_unknown_permission_mode() { ci run --permission-mode yolo hello; expect_rc 2; }
t_usage_terminal_too_small() { ci run --cols 40 hello; expect_rc 2; }
t_usage_unknown_command() { ci frobnicate; expect_rc 2; }

t_usage_empty_prompt() {
  ci run --claude-bin "$FAKE" -o "$T/out" "   "
  expect_rc 2
  expect_grep "$T/stderr" 'empty prompt'
}

t_usage_missing_prompt_file() {
  ci run --claude-bin "$FAKE" -o "$T/out" -f "$T/nope.txt"
  expect_rc 2
}

t_usage_stdin_read_twice() {
  printf 'x' | "$BASH_UNDER_TEST" "$DRIVER" run --claude-bin "$FAKE" -o "$T/out" -f - -f - \
    >"$T/stdout" 2>"$T/stderr"
  RC=$?
  expect_rc 2
  expect_grep "$T/stderr" 'stdin can only be read once'
}

t_usage_settings_not_json() {
  ci run --claude-bin "$FAKE" -o "$T/out" --settings '{not json' hello
  expect_rc 2
}

t_usage_output_dir_root() {
  [ "$(id -u)" != 0 ] || { echo "skipped as root"; return 0; }
  ln -s / "$T/rootlink"
  ci run --claude-bin "$FAKE" -o "$T/rootlink" --dry-run hello
  expect_rc 2
  expect_grep "$T/stderr" 'refusing to use /'
}

t_missing_claude_bin_exit_3() {
  ci run --claude-bin "$T/no-such-claude" hello
  expect_rc 3
}

# --- 17. signals ---------------------------------------------------------------------------

signal_mid_turn() {
  local sig=$1 job pid
  OUT=$T/out
  FAKE_CLAUDE_SCENARIO=hang with_default_sigint "$T/driver.pid" "$BASH_UNDER_TEST" "$DRIVER" run \
    --claude-bin "$FAKE" -C "$WORK" -o "$OUT" --timeout 60 "hello" >"$T/stdout" 2>"$T/stderr" </dev/null &
  job=$!
  if ! wait_for 20 cgrep -q 'accepted' "$OUT/driver.log"; then
    kill -KILL "$(cat "$T/driver.pid")" 2>/dev/null
    fail "turn 1 was never accepted"
  fi
  pid=$(cat "$T/driver.pid")
  kill "-$sig" "$pid"
  wait "$job"
  RC=$?
  expect_rc 130
  R=$(result)
  expect_json "$R" .status interrupted
  expect_json "$R" .exit_code 130
  expect_no_tmux
  expect_dead "$(fake_start .pid)" "fake Claude Code"
}

t_sigint_mid_turn() { signal_mid_turn INT; }
t_sigterm_mid_turn() { signal_mid_turn TERM; }

# --- background tasks -----------------------------------------------------------------------

t_bg_task_waits_for_final_answer() {
  FAKE_CLAUDE_SCENARIO=bg_running run_ci "start the job"
  expect_rc 0
  R=$(result)
  expect_json "$R" .final_message "BACKGROUND DONE: final answer"
  expect_json "$R" '.turns[0].last_assistant_message' "BACKGROUND DONE: final answer"
  expect_json "$R" .turns_total 1
  expect_json "$R" .turns_completed 1
  expect_grep "$OUT/driver.log" 'paused: 1 background task'
  expect_jq "$OUT/events.jsonl" '[.[] | select(.hook_event_name == "Stop") | .background_tasks | length] == [1, 0]' -s
  expect_no_tmux
}

t_bg_notification_right_after_stop() {
  FAKE_CLAUDE_SCENARIO=bg_race run_ci "start the job"
  expect_rc 0
  expect_json "$(result)" .final_message "BACKGROUND DONE: final answer"
  expect_json "$(result)" '.turns[0].prompt_id' "$(fake_prompt_id 1)"
  expect_grep "$OUT/driver.log" 'continues, Claude Code resumed it'
  expect_no_tmux
}

t_bg_no_wait_background_keeps_first_answer() {
  FAKE_CLAUDE_SCENARIO=bg_running run_ci --no-wait-background "start the job"
  expect_rc 0
  expect_json "$(result)" .final_message "ECHO: start the job"
  expect_no_tmux
}

t_bg_exit_dialog_stops_tasks() {
  FAKE_CLAUDE_SCENARIO=bg_stuck run_ci --no-wait-background "start the job"
  expect_rc 0
  R=$(result)
  expect_json "$R" .final_message "ECHO: start the job"
  expect_json "$R" .claude_exit_status 0
  expect_json "$R" .session_end_reason prompt_input_exit
  expect_jq "$R" '.duration_seconds < 15'
  expect_eq "dialog choices" "exit_background=Exit and stop tasks;" "$(fake_dialogs)"
  expect_grep "$OUT/driver.log" 'Exit dialog matched'
  expect_no_grep "$OUT/driver.log" 'did not exit within'
  expect_no_tmux
}

t_bg_stuck_task_turn_timeout() {
  FAKE_CLAUDE_SCENARIO=bg_stuck run_ci --turn-timeout 5 --idle-timeout 2 "start the job"
  expect_rc 13
  R=$(result)
  expect_json "$R" '.turns[0].error' "turn timeout"
  expect_grep "$R" 'state background'
  expect_no_tmux
}

t_bg_permission_prompt_blocked() {
  FAKE_CLAUDE_SCENARIO=bg_permission run_ci --timeout 15 "start the job"
  expect_rc 14
  expect_json "$(result)" .status blocked
  expect_no_tmux
}

t_notification_while_submitting_ignored() {
  FAKE_CLAUDE_SCENARIO=notify_on_paste run_ci "one" "two"
  expect_rc 0
  R=$(result)
  expect_json "$R" '.turns[1].prompt_id' "$(fake_prompt_id 2)"
  expect_json "$R" '.turns[1].last_assistant_message' "ECHO: two"
  expect_json "$R" .final_message "ECHO: two"
  expect_eq "injected prompts" 1 "$(fake_count '.kind == "injected"')"
  expect_grep "$OUT/driver.log" 'injected a prompt while turn 2 was being submitted'
  expect_no_tmux
}

t_rewritten_prompt_accepted_with_warning() {
  FAKE_CLAUDE_SCENARIO=rewrite_prompt run_ci "hello"
  expect_rc 0
  expect_grep "$OUT/driver.log" 'accepted prompt text differs'
  expect_json "$(result)" .final_message "ECHO: hello"
  expect_no_tmux
}

t_loop_prompt_with_source_ignored() {
  FAKE_CLAUDE_SCENARIO=injected_prompt run_ci "hello"
  expect_rc 0
  R=$(result)
  expect_json "$R" '.turns[0].prompt_id' "$(fake_prompt_id 1)"
  expect_json "$R" .final_message "ECHO: hello"
  expect_no_tmux
}

# --- other options ----------------------------------------------------------------------------

t_dry_run_writes_launch_script() {
  ci run --claude-bin "$FAKE" -C "$WORK" -o "$T/out" --dry-run "hello"
  expect_rc 0
  OUT=$T/out
  L=$OUT/internal/launch.sh
  expect_grep "$T/stdout" '^--- launch.sh ---$'
  expect_grep "$L" '^unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID'
  expect_grep "$L" "--dangerously-skip-permissions' '--disallowedTools' 'AskUserQuestion' --"
  expect_jq "$OUT/internal/settings.json" \
    '[.hooks | to_entries[] | select(.key as $k | .value[0].hooks[0].command | test("__hook " + $k + " "))]
     | length == 6'
  [ ! -e "$FAKE_CLAUDE_LOG" ] || fail "--dry-run started Claude Code"
}

t_claude_args_passthrough() {
  run_ci --model opus --permission-mode acceptEdits --allowed-tools 'Bash(git:*)' \
    --disallowed-tools WebFetch --append-system-prompt 'Be brief.' --claude-arg --verbose "hello"
  expect_rc 0
  expect_eq "argv" \
    "--settings $OUT/internal/settings.json --permission-mode acceptEdits --model opus --allowedTools Bash(git:*) --disallowedTools AskUserQuestion,WebFetch --append-system-prompt Be brief. --verbose -- hello" \
    "$(fake_start '.argv | join(" ")')"
  expect_json "$OUT/events.jsonl" 'select(.hook_event_name == "UserPromptSubmit") | .permission_mode' acceptEdits
  expect_no_tmux
}

t_allow_questions_keeps_tool() {
  ci run --claude-bin "$FAKE" -C "$WORK" -o "$T/out" --dry-run --allow-questions "hello"
  expect_rc 0
  expect_no_grep "$T/out/internal/launch.sh" 'AskUserQuestion'
}

t_user_settings_hooks_merged() {
  local s
  s=$(jq -nc --arg f "$T/user-hook.txt" \
    '{env: {FOO: "bar"}, hooks: {Stop: [{hooks: [{type: "command", command: ("echo user-hook >> " + $f)}]}]}}')
  run_ci --settings "$s" "hello"
  expect_rc 0
  expect_bytes "$T/user-hook.txt" 'user-hook
'
  expect_json "$OUT/internal/settings.json" .env.FOO bar
  expect_json "$OUT/internal/settings.json" '.hooks.Stop | length' 2
  expect_no_tmux
}

t_no_transcript_flag() {
  run_ci --no-transcript "hello"
  expect_rc 0
  [ ! -e "$OUT/transcript.jsonl" ] || fail "transcript.jsonl was copied"
  expect_json "$(result)" .transcript null
  expect_json "$(result)" .usage null
  expect_no_tmux
}

t_prompt_from_stdin() {
  OUT=$T/out
  printf 'from stdin\nsecond line\n' | "$BASH_UNDER_TEST" "$DRIVER" run --claude-bin "$FAKE" -C "$WORK" \
    -o "$OUT" --timeout 60 -f - >"$T/stdout" 2>"$T/stderr"
  RC=$?
  expect_rc 0
  expect_bytes "$OUT/turns/01.prompt.txt" 'from stdin
second line'
  expect_eq "received" "$(printf 'from stdin\nsecond line')" "$(fake_prompt 1)"
  expect_no_tmux
}

t_reused_output_dir_is_cleaned() {
  OUT=$T/out
  mkdir -p "$OUT/turns" "$OUT/internal/events/.seq"
  printf 'stale' >"$OUT/turns/02.prompt.txt"
  printf 'stale' >"$OUT/turns/02.response.txt"
  printf '{"hook_event_name":"Stop","prompt_id":"","last_assistant_message":"STALE"}' \
    >"$OUT/internal/events/000000-Stop.json"
  printf '{"seq":99}\n' >"$OUT/events.jsonl"
  run_ci "hello"
  expect_rc 0
  [ ! -e "$OUT/turns/02.prompt.txt" ] || fail "stale turns/02.prompt.txt survived"
  expect_json "$(result)" .final_message "ECHO: hello"
  expect_no_grep "$OUT/events.jsonl" '"seq":99'
  expect_no_tmux
}

t_version_and_help() {
  ci version
  expect_rc 0
  expect_grep "$T/stdout" '^claude-interactive [0-9]+\.[0-9]+\.[0-9]+$'
  ci run --help
  expect_rc 0
  expect_grep "$T/stdout" '^Usage: claude-interactive run'
  ci setup --help
  expect_rc 0
  expect_grep "$T/stdout" '^Usage: claude-interactive setup'
}

t_doctor_reports_claude() {
  CLAUDE_BIN=$FAKE ci doctor
  expect_rc 0
  expect_grep "$T/stdout" '^claude +2\.1\.314 \(Claude Code\)'
}

# =============================================================================
# Runner
# =============================================================================

list_tests() { sed -n 's/^t_\([A-Za-z0-9_]*\)() *{.*/\1/p' "$SUITE"; }

select_tests() {
  local t p
  for t in $(list_tests); do
    if [ $# -eq 0 ]; then
      echo "$t"
      continue
    fi
    for p in "$@"; do
      # shellcheck disable=SC2254 # the argument is a glob on purpose
      case $t in ${p#t_}) echo "$t"; break ;; esac
    done
  done
}

# PIDs of every live descendant of $1.
descendants() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { parent[$1] = $2 }
    END {
      keep[root] = 1
      do {
        changed = 0
        for (p in parent) if (!(p in keep) && (parent[p] in keep)) { keep[p] = 1; changed = 1 }
      } while (changed)
      for (p in keep) if (p != root && (p in parent)) print p
    }'
}

# Stop and report anything a test left running: tmux servers named in driver
# logs and processes recorded by the mock. Returns 1 when something was left.
reap_leftovers() {
  local dir=$1 f sock pid i bad=0 sockdir
  sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sock=$(sed -n 's/.*tmux -L \([^ ]*\) attach.*/\1/p' "$f" | head -n 1)
    [ -n "$sock" ] || continue
    if env -u TMUX tmux -L "$sock" has-session 2>/dev/null; then
      echo "LEFTOVER: tmux server $sock was still running"
      env -u TMUX tmux -L "$sock" kill-server 2>/dev/null
      bad=1
    fi
    # tmux 3.x leaves the socket file behind after kill-server.
    rm -f "$sockdir/$sock" 2>/dev/null
  done <<EOF
$(find "$dir" -name driver.log -type f 2>/dev/null)
EOF
  for f in "$dir"/home/pids/*; do
    [ -f "$f" ] || continue
    pid=$(cat "$f")
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
      case $(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') in Z*) break ;; esac
      sleep 0.2
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      case $(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') in
        Z*) ;;
        *)
          echo "LEFTOVER: process $pid ($(ps -o command= -p "$pid" 2>/dev/null | cut -c1-80)) was still running"
          kill -KILL "$pid" 2>/dev/null
          bad=1
          ;;
      esac
    fi
  done
  return "$bad"
}

# Run one test (in the background); leaves "<rc> <ms>" in $RESULTS/<name>.
run_test() {
  local name=$1 dir=$RUN_ROOT/$1 t0 rc
  mkdir -p "$dir"
  t0=$(now_ms)
  (
    T=$dir
    cd "$T" || exit 1
    # Hermetic environment: nothing from the caller's environment configures
    # the mock, the driver's defaults, tmux, or the real Claude Code config.
    for v in $(env | sed -n 's/^\(FAKE_CLAUDE_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
    unset TMUX TMUX_PANE CLAUDE_BIN GITHUB_ACTIONS RUNNER_TEMP
    WORK=$T/work
    export FAKE_CLAUDE_HOME=$T/home FAKE_CLAUDE_LOG=$T/fake.log CLAUDE_CONFIG_DIR=$T/config HOME=$T/userhome
    mkdir -p "$WORK" "$FAKE_CLAUDE_HOME" "$CLAUDE_CONFIG_DIR" "$HOME"
    "t_$name"
  ) >"$dir/test.log" 2>&1 </dev/null
  rc=$?
  reap_leftovers "$dir" >>"$dir/test.log" 2>&1 || rc=1
  printf '%s %s\n' "$rc" "$(($(now_ms) - t0))" >"$RESULTS/$name"
}

report_test() {
  local name=$1 rc ms secs
  read -r rc ms <"$RESULTS/$name"
  secs=$(awk -v ms="$ms" 'BEGIN { printf "%.1f", ms / 1000 }')
  if [ "$rc" = 0 ]; then
    PASSED=$((PASSED + 1))
    printf 'PASS  %-46s %6ss\n' "$name" "$secs"
    [ "$VERBOSE" != 1 ] || sed 's/^/      /' "$RUN_ROOT/$name/test.log"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES="$FAILED_NAMES $name"
    printf 'FAIL  %-46s %6ss\n' "$name" "$secs"
    sed 's/^/      /' "$RUN_ROOT/$name/test.log"
    [ "$KEEP_TMP" != 1 ] || printf '      (files kept in %s)\n' "$RUN_ROOT/$name"
  fi
}

cleanup_run() {
  local p
  for p in $(descendants $$); do kill -TERM "$p" 2>/dev/null; done
  if [ -n "${RUN_ROOT:-}" ] && [ -d "$RUN_ROOT" ]; then
    reap_leftovers "$RUN_ROOT" >/dev/null 2>&1
    for p in "$RUN_ROOT"/*/; do reap_leftovers "$p" >/dev/null 2>&1; done
    [ "$KEEP_TMP" = 1 ] || rm -rf "$RUN_ROOT"
  fi
}

on_interrupt() {
  trap - INT TERM
  echo "interrupted, cleaning up" >&2
  cleanup_run
  exit 130
}

usage() { sed -n '4,24p' "$SUITE" | sed 's/^# \{0,1\}//'; }

main() {
  local list=0 names name pid i
  while [ $# -gt 0 ]; do
    case $1 in
      -j) JOBS=${2:-}; shift 2 || { usage; exit 2; } ;;
      -j*) JOBS=${1#-j}; shift ;;
      -l) list=1; shift ;;
      -h | --help) usage; exit 0 ;;
      --) shift; break ;;
      -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
      *) break ;;
    esac
  done
  case $JOBS in '' | *[!0-9]* | 0) echo "-j needs a positive number" >&2; exit 2 ;; esac
  if [ "$list" = 1 ]; then select_tests "$@"; exit 0; fi

  for c in tmux jq python3; do
    command -v "$c" >/dev/null 2>&1 || { echo "missing dependency: $c" >&2; exit 2; }
  done
  names=$(select_tests "$@")
  [ -n "$names" ] || { echo "no test matches: $*" >&2; exit 2; }

  RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-interactive-tests.XXXXXX") || exit 2
  RUN_ROOT=$(cd "$RUN_ROOT" && pwd -P)
  RESULTS=$RUN_ROOT/.results
  mkdir -p "$RESULTS"
  trap on_interrupt INT TERM

  printf 'bash under test: %s (%s), tmux %s, %s, %s job(s)\n' "$BASH_UNDER_TEST" \
    "$("$BASH_UNDER_TEST" -c 'echo $BASH_VERSION')" "$(tmux -V | sed 's/^tmux //')" "$(jq --version)" "$JOBS"
  PASSED=0
  FAILED=0
  FAILED_NAMES=""
  local t_start running="" nrunning=0 queue still
  t_start=$(now_ms)
  queue=$names
  while [ -n "$queue" ] || [ "$nrunning" -gt 0 ]; do
    # Start tests while there is a free slot.
    while [ -n "$queue" ] && [ "$nrunning" -lt "$JOBS" ]; do
      name=${queue%%$'\n'*}
      if [ "$name" = "$queue" ]; then queue=""; else queue=${queue#*$'\n'}; fi
      run_test "$name" &
      running="$running $!:$name"
      nrunning=$((nrunning + 1))
    done
    sleep 0.2
    # Report the ones that finished, in the order they finish.
    still=""
    for i in $running; do
      pid=${i%%:*}
      name=${i#*:}
      if kill -0 "$pid" 2>/dev/null; then
        still="$still $i"
      else
        wait "$pid" 2>/dev/null
        nrunning=$((nrunning - 1))
        report_test "$name"
      fi
    done
    running=$still
  done

  printf '\n%d passed, %d failed in %ss\n' "$PASSED" "$FAILED" \
    "$(awk -v ms="$(($(now_ms) - t_start))" 'BEGIN { printf "%.1f", ms / 1000 }')"
  [ "$FAILED" = 0 ] || printf 'failed:%s\n' "$FAILED_NAMES"
  trap - INT TERM
  [ "$KEEP_TMP" = 1 ] || rm -rf "$RUN_ROOT"
  [ "$FAILED" = 0 ]
}

main "$@"
