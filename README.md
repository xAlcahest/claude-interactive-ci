# Claude Interactive PoC

Proof of concept: running Claude Code as an **interactive session** inside GitHub Actions via `tmux`, bypassing the programmatic usage credit pool introduced on June 15, 2026.

## What this does

Every 6 hours, a GitHub Action:

1. Starts a `tmux` session (real PTY)
2. Launches `claude` **without the `-p` flag** (interactive mode)
3. Sends a prompt via `tmux send-keys` (simulating keyboard input)
4. Waits for Claude Code to finish (output stabilization detection)
5. Commits the result to `log.txt`

From Claude Code's perspective, this is indistinguishable from a human opening a terminal and typing. Because it *is* a terminal. `isatty()` returns `true`. The PTY is real. The input arrives as keystrokes.

## Why this exists

On May 13, 2026, Anthropic announced that starting June 15, `claude -p` and Agent SDK usage would be separated into a dedicated credit pool billed at full API rates ($20-$200/month depending on plan), while interactive usage remains on the subsidized subscription pool.

This PoC demonstrates that the distinction between "interactive" and "programmatic" is a policy fiction, not a technical boundary.

## Setup

### 1. Get your OAuth credentials

On a machine where you're logged into Claude Code with your subscription:

```bash
cat ~/.claude/credentials.json
```

Copy the entire content.

### 2. Add GitHub Secret

Go to your repository → Settings → Secrets and variables → Actions → New repository secret:

- **Name:** `CLAUDE_OAUTH_TOKEN`  
- **Value:** The content from step 1

### 3. Enable the workflow

The workflow runs on:
- **Schedule:** Every 6 hours (`0 */6 * * *`)
- **Manual dispatch:** Click "Run workflow" in the Actions tab

### 4. Permissions

The workflow needs `contents: write` permission to commit changes. This is configured in the workflow file.

## How the tmux bypass works

```
┌─────────────────────────────────────────┐
│  GitHub Actions Runner                  │
│                                         │
│  ┌───────────────────────────────────┐  │
│  │  tmux session (real PTY)          │  │
│  │                                   │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  bash (login shell)         │  │  │
│  │  │                             │  │  │
│  │  │  ┌───────────────────────┐  │  │  │
│  │  │  │  claude (interactive) │  │  │  │
│  │  │  │  No -p flag           │  │  │  │
│  │  │  │  isatty() = true      │  │  │  │
│  │  │  │  TERM = xterm-256color│  │  │  │
│  │  │  └───────────────────────┘  │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
│                                         │
│  tmux send-keys "prompt" Enter          │
│  ↑ This is identical to a human typing  │
└─────────────────────────────────────────┘
```

The process tree: `bash → tmux → bash → claude`

This is the same process tree you'd see from any terminal emulator (GNOME Terminal, iTerm2, Alacritty). There is no technical mechanism to differentiate the two.

## Files

```
.
├── .github/workflows/
│   └── claude-interactive-cron.yml    # The workflow
├── scripts/
│   └── interactive-claude.sh          # Reusable orchestration script
├── log.txt                            # File modified by Claude
└── README.md                          # You are here
```

## Limitations

- **Auth token management:** OAuth tokens expire. You may need to refresh `CLAUDE_OAUTH_TOKEN` periodically.
- **Completion detection:** Uses output stabilization (buffer unchanged for 9s) which is heuristic. Complex tasks may need longer timeouts.
- **No streaming output:** You see the result after completion, not in real-time.
- **Runner IP ranges:** Anthropic *could* theoretically block GitHub Actions IP ranges, but this would also break legitimate interactive usage from cloud VMs, Codespaces, and remote development environments.

## Standalone usage

The orchestration script also works standalone on any Linux/macOS machine:

```bash
chmod +x scripts/interactive-claude.sh
./scripts/interactive-claude.sh "Add today's date to log.txt"
```

## Disclaimer

This is a technical proof of concept demonstrating that the interactive/programmatic distinction is unenforceable at the protocol level. Use responsibly and in compliance with Anthropic's Terms of Service as you understand them.
