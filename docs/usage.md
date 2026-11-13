# claude-interactive

`bin/claude-interactive` runs the interactive Claude Code TUI unattended. It
starts Claude Code inside a private tmux server, submits one or more prompts as
conversation turns, waits for each turn to finish, exits cleanly and writes a
machine-readable report. It works on a laptop and on CI runners, and the
repository ships a composite GitHub Action around it.

It is a single bash file with three runtime dependencies: tmux, jq and the
Claude Code CLI.

## How it works

Earlier versions of this project decided when Claude was done by watching the
terminal until the output stopped changing. That breaks whenever a tool runs
quietly for a while, and every Claude Code release that rearranges the screen
breaks it again.

The driver now asks Claude Code itself. Before launching, it writes a settings
file that registers a small recorder for six hook events and passes it with
`--settings`:

| Event | What the driver does with it |
| --- | --- |
| `SessionStart` | Records the session id and the transcript path. |
| `UserPromptSubmit` | Confirms the prompt it typed was accepted and remembers its `prompt_id`. Prompts with a `source` other than `user` (loop wakeups and the like) are ignored. |
| `Stop` | A `Stop` carrying the same `prompt_id` ends the turn, unless background tasks are still running (see below). Its `last_assistant_message` becomes the turn's response. |
| `StopFailure` | The turn ended on an API error (rate limit, usage limit, auth). The run fails as `api_error`. |
| `Notification` | `permission_prompt` or `elicitation_dialog` during a turn, or `idle_prompt` mid-turn, means Claude is waiting for a human. The run fails as `blocked` right away instead of sitting until the timeout. |
| `SessionEnd` | Records why the session ended. |

Each hook invocation writes its JSON payload into an event directory with an
atomically allocated sequence number, so events are processed in order and
never half-written. The hook prints nothing and always exits 0, so it cannot
inject context or block Claude.

The screen is read for two things only:

- getting past startup dialogs (workspace trust, bypass-permissions warning,
  custom API key, theme picker), always choosing the option by its label;
- explaining failures (the last lines of the screen go into the report).

Every startup dialog in Claude Code preselects the option that declines or
exits, so pressing Enter blindly quits Claude. The driver moves the cursor
until the line with the wanted label is selected, presses Enter once, and
waits for the screen to change before touching anything else.

### Background tasks

Claude often starts long commands as background tasks and ends its turn with
something like "I will report back when it finishes". The work is not done at
that point, so the driver does not treat that `Stop` as the end of the turn:

- a `Stop` whose `background_tasks` still has running entries pauses the turn;
- when a task finishes, Claude Code wakes the model up by injecting a prompt
  that starts with `<task-notification>`, and the turn continues;
- after every `Stop` the driver waits three seconds before moving on, because
  a task that finished just before the `Stop` triggers that wake-up right
  after it.

The turn ends at the first `Stop` with nothing left running and no wake-up
following it, and the response is the message of that last `Stop`. A task
that never ends, such as a dev server left running, keeps the turn open until
`--turn-timeout` or `--timeout`. `--no-wait-background` ends turns at their
first `Stop` instead; tasks still running at the end are stopped when Claude
exits.

Injected prompts look exactly like typed ones in the hook payload (no
`source`), so while submitting a turn the driver only accepts a
`UserPromptSubmit` whose text matches the prompt it sent.

### Other details

- The first prompt is passed on the command line, so no readiness detection is
  needed. Later prompts, and a first prompt larger than 64 KiB, are pasted with
  tmux bracketed paste, which keeps newlines inside the prompt.
- tmux runs on its own socket with an empty config, so a user's `~/.tmux.conf`
  or running tmux server cannot interfere, and the server is killed at the end.
- Credentials such as `CLAUDE_CODE_OAUTH_TOKEN` reach Claude through the
  inherited environment. They are never written to disk or put on a command
  line.
- Variables that mark a parent Claude Code session (`CLAUDECODE`,
  `CLAUDE_CODE_SESSION_ID` and similar) are removed, so the driver can be run
  from inside Claude Code.
- The `AskUserQuestion` tool is disabled by default because nobody is there to
  answer. `--allow-questions` turns it back on.
- At the end the driver types `/exit`, answers the "Background work is
  running" dialog with "Exit and stop tasks" if it shows up, and then stops
  the whole process tree of the tmux pane (SIGTERM, then SIGKILL after five
  seconds). Claude Code can take a while to react to tmux closing, and tool
  processes may live in their own process groups; nothing started by the run
  keeps writing to the workdir after the driver returns.

## Requirements

- bash 3.2 or newer (macOS system bash works)
- tmux 3.0 or newer
- jq 1.6 or newer
- Claude Code, authenticated through a stored login, `CLAUDE_CODE_OAUTH_TOKEN`
  (from `claude setup-token`) or `ANTHROPIC_API_KEY`

`claude-interactive doctor` checks all of the above.

## Running it locally

```sh
bin/claude-interactive run -C ~/src/project -m sonnet \
  'Run the test suite and fix the first failing test.' \
  'Summarize what you changed in three bullet points.'
```

Each positional argument is one turn. `--prompt TEXT` and
`--prompt-file FILE` add turns too (`-` reads a file from stdin). Logs go to
stderr; the final assistant message goes to stdout, or the whole report with
`--json`.

While it runs, the log prints a read-only attach command:

```
Watch live (read-only): tmux -L claude-interactive-12345-678 attach -r -t main
```

`--keep-session` leaves Claude running after the last turn so you can attach
and continue by hand. `--dry-run` prints the generated launch script and
settings without starting anything.

On a fresh machine the workspace trust dialog is answered automatically. To
avoid it, and the onboarding screens, on a CI runner use `setup` (below).

## Running it in GitHub Actions

```yaml
jobs:
  claude:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - id: claude
        uses: xAlcahest/claude-interactive-ci@master
        with:
          prompt: Update CHANGELOG.md for the commits since the last tag.
          oauth-token: ${{ secrets.CLAUDE_OAUTH_TOKEN }}
          claude-version: '2.1.314'
          timeout: '900'
      - run: echo "Claude finished with ${{ steps.claude.outputs.status }}"
```

The action installs tmux and jq when missing, installs the requested Claude
Code version, runs `claude-interactive setup` for the workdir, runs the
prompts, writes a job summary, sets outputs and uploads the artifacts.

Inputs: `prompt`, `prompt-files` (newline-separated, one turn each),
`workdir`, `oauth-token`, `api-key`, `base-config`, `model`,
`permission-mode`, `timeout`, `turn-timeout`, `claude-version`
(`preinstalled` skips the install), `claude-args` and `extra-args`
(newline-separated), `output-dir`, `upload-artifact`, `artifact-name`,
`artifact-retention-days`, `fail-on-error`.

Outputs: `status`, `exit-code`, `session-id`, `final-message`, `cost-usd`,
`result-file`, `output-dir`.

Pin `claude-version`. The driver depends on hook payloads and dialog labels,
and both have changed between releases before. Upgrade on purpose, after a run
with the new version.

`.github/workflows/claude-interactive-cron.yml` is a complete example: it runs
on a schedule, lets Claude edit `log.txt` and `REPORT.md`, fails when the log
was not touched, and commits the result.

### Preparing the runner: `setup`

```sh
CI=true bin/claude-interactive setup --trust "$GITHUB_WORKSPACE"
```

`setup` merges a few keys into the Claude Code config of the current user
(`$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude.json` and
`~/.claude/settings.json`) and leaves everything else untouched:

- `hasCompletedOnboarding: true`, and a theme when none is set;
- `projects[DIR].hasTrustDialogAccepted: true` for each `--trust DIR`, using
  both the given path and its symlink-free form;
- `skipDangerousModePermissionPrompt: true`.

`--base-config FILE` merges a JSON object first, for example an exported
config kept in a secret. Because it edits your configuration, `setup` refuses
to run when `CI=true` is not set unless you pass `--force`.

## Artifacts

Every run writes to its output directory (`--output-dir`, by default a new
directory under `$RUNNER_TEMP` or `$TMPDIR`):

| File | Content |
| --- | --- |
| `result.json` | The report, see below. |
| `final-message.txt` | Last assistant message of the last completed turn. |
| `turns/NN.prompt.txt`, `turns/NN.response.txt` | Each turn's prompt and response. |
| `events.jsonl` | Every hook payload, in order, with `seq` and `received_at`. |
| `screen.txt` | The full terminal scrollback at the end. |
| `transcript.jsonl` | Copy of Claude Code's session transcript (`--no-transcript` skips it). |
| `driver.log` | The driver's own log. |
| `internal/` | Generated launch script, settings and tmux config, for debugging. |

The driver removes these files at start when it reuses a directory, so a
report never mixes two runs.

`result.json` (schema version 1):

```json
{
  "schema_version": 1,
  "status": "success",
  "exit_code": 0,
  "reason": "all 2 turn(s) completed",
  "driver_version": "0.1.0",
  "run_id": "20261112T181016Z-17728",
  "session_id": "baaf498b-f0d9-4781-b3c5-e69c6c928a1a",
  "claude_version": "2.1.314 (Claude Code)",
  "workdir": "/path/to/project",
  "started_at": "2026-11-12T18:10:16Z",
  "finished_at": "2026-11-12T18:10:38Z",
  "duration_seconds": 22,
  "claude_exit_status": 0,
  "session_end_reason": "prompt_input_exit",
  "turns_total": 2,
  "turns_completed": 2,
  "turns": [
    {
      "index": 1,
      "status": "completed",
      "prompt_id": "a95a309a-12cf-46bb-9311-f2d25d683cb8",
      "prompt_file": "turns/01.prompt.txt",
      "submitted_at": "2026-11-12T18:10:16Z",
      "started_at": "2026-11-12T18:10:19Z",
      "finished_at": "2026-11-12T18:10:27Z",
      "duration_seconds": 11,
      "error": null,
      "last_assistant_message": "DONE"
    }
  ],
  "final_message": "HI FROM TURN ONE",
  "transcript": "transcript.jsonl",
  "usage": {
    "total_cost_usd": 0.1288,
    "api_duration_ms": 21615,
    "lines_added": 1,
    "lines_removed": 0,
    "model_usage": { "claude-haiku-4-5": { "inputTokens": 1788, "outputTokens": 120 } }
  }
}
```

`usage` is read from bookkeeping entries Claude Code writes into its
transcript. That format is internal to Claude Code, so `usage` is `null` when
it is missing or changes shape.

## Exit status

| Code | Status | Meaning |
| --- | --- | --- |
| 0 | `success` | Every turn completed. |
| 1 | `error` | Unexpected driver failure. |
| 2 | | Usage error. |
| 3 | | Missing dependency. |
| 10 | `startup_failed`, `submit_failed` | A prompt was never accepted: an unknown startup dialog, or a pasted prompt that did not go through. |
| 11 | `auth_failed` | Login screen or authentication error during startup. |
| 12 | `claude_exited` | Claude Code exited before the work was done. |
| 13 | `timeout` | `--timeout`, `--turn-timeout` or `--idle-timeout` expired. |
| 14 | `blocked` | Claude stopped to wait for a human (permission prompt, question). |
| 15 | `api_error` | A turn ended with an API error (`StopFailure`). |
| 130 | `interrupted` | The driver got SIGINT or SIGTERM. The report is still written. |

## Handling a new startup dialog

When a Claude Code release adds a dialog the driver does not know, the run
fails with `startup_failed` and the reason shows the last lines of the screen.
Teach it the dialog without editing the script:

```sh
bin/claude-interactive run \
  --dialog 'Enable the new feature\?::No, thanks' \
  --fatal 'Your plan does not include' \
  'your prompt'
```

`--dialog 'REGEX::LABEL'` selects the option matching `LABEL` whenever `REGEX`
matches the screen before the first prompt is accepted (an empty `LABEL` just
presses Enter). `--fatal REGEX` turns a screen into an `auth_failed` exit.
Both use extended regular expressions and are checked before the built-in
rules. With the action, pass them through `extra-args`, one argument per line.

## Security

- The default permission mode is `bypassPermissions`: Claude runs any command
  without asking. That is reasonable on an ephemeral CI runner and dangerous
  anywhere else. Use `--permission-mode dontAsk` together with
  `--allowed-tools` for a locked-down run; anything Claude is not allowed to
  do is then refused instead of asked.
- Treat prompt content as code. A prompt built from issue text, PR comments or
  any other input you do not control can steer Claude into running commands
  with the job's permissions and secrets.
- The transcript and `events.jsonl` contain the prompts, tool output and file
  contents Claude read. On a public repository, uploaded artifacts are visible
  to anyone who can see the workflow runs. Use `--no-transcript` or
  `upload-artifact: 'false'` when that matters.
- Pass tokens from secrets. The action never interpolates inputs into shell
  code; they travel as environment variables.

## Limitations

- The driver depends on Claude Code's hook payloads (`prompt_id`, `source`,
  `last_assistant_message`) as of 2.1.314. Older releases without `prompt_id`
  still work because a `Stop` without one is accepted for the current turn.
- If another `Stop` hook in your own settings blocks the stop and makes Claude
  continue, the first `Stop` event already ends the turn. CI runners, which
  start from an empty config, are not affected.
- Scheduled wake-ups (`session_crons`, `/loop`) are not waited for; they are
  dropped when the driver exits Claude after the last turn.
- A turn has to be a prompt for the model. Local slash commands that never
  reach the model (for example `/clear`) do not produce a `Stop` event and
  would hit the submit or turn timeout.
- If all you need is a headless answer and you do not depend on the
  interactive TUI, `claude -p --output-format stream-json` is simpler.

## Development

The test suite runs offline. `tests/fake-claude` is a Python stand-in for the
Claude Code TUI that reproduces what the driver depends on: startup dialogs
with "No, exit" preselected, hook payloads, bracketed paste, background tasks
with `<task-notification>` wake-ups, the exit dialog, crashes and hangs. Its
scenarios are selected with environment variables documented at the top of
the file. `tests/run.sh` drives the real driver against it inside real tmux
servers, with a private `HOME` and `CLAUDE_CONFIG_DIR` per test, so your own
Claude Code configuration is never touched.

```sh
tests/run.sh                 # everything, 4 tests in parallel
tests/run.sh 'bg_*' usage_*  # a subset, by name or glob
tests/run.sh -l              # list the tests
BASH_UNDER_TEST=/opt/homebrew/bin/bash tests/run.sh   # another bash
shellcheck -x bin/claude-interactive scripts/interactive-claude.sh tests/run.sh
```

The suite needs tmux, jq and python3. CI runs it on Ubuntu (bash 5) and on
macOS with the system bash 3.2.

### Pre-commit hook

```sh
scripts/install-hooks.sh   # once per clone: git config core.hooksPath .githooks
```

From then on every commit runs `.githooks/pre-commit`, and a failing check
aborts the commit. The hook exports the staged snapshot to a temporary
directory and checks that, not your working tree, so what passes is exactly
what gets committed:

1. when the commit touches `bin/`, `scripts/`, `tests/`, `.githooks/` or
   `action.yml`, untracked files under `bin/` or `tests/` stop the commit
   right away (they would be missing from the snapshot);
2. `bash -n` on the staged shell scripts and a parse of `tests/fake-claude`;
3. shellcheck on the staged shell scripts, if it is installed;
4. a YAML parse of the staged `action.yml` and workflows, if ruby is
   available;
5. the full offline test suite with `/bin/bash`, for commits that touch the
   paths in step 1. It takes about 90 seconds; documentation-only commits
   skip it.

Steps 2 to 4 only look at files changed by the commit, so an unrelated commit
is never blocked by an older file. When the suite fails, the first failures
are printed and the full log is in `.git/precommit-tests.log`.

`git commit --no-verify` skips the hook once.
`CLAUDE_INTERACTIVE_PRECOMMIT_TESTS=always` or `never` overrides step 5.
CI runs every check on every push regardless, so the hook is a fast local
safety net, not the only gate.

When a Claude Code release changes behavior, reproduce it in the fake first,
then fix the driver.
