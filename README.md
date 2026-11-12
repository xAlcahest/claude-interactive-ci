# Claude Interactive PoC

Proof of concept: running Claude Code as an **interactive session** inside GitHub Actions via `tmux`.

## What this does

Every 6 hours, a GitHub Action:

1. Starts a `tmux` session (real PTY)
2. Launches `claude` **without the `-p` flag** (interactive mode)
3. Sends a prompt via `tmux send-keys` (simulating keyboard input)
4. Waits for Claude Code to finish (output stabilization detection)
5. Commits the result to `log.txt`

## Setup

### 1. Generate a Long-Lived Token

On a machine where you're logged into Claude Code with your Max/Pro subscription, generate a long-lived token:

```bash
claude setup-token
```

Output:

```
✓ Long-lived authentication token created successfully!
Your OAuth token (valid for 1 year):
sk-ant-oat01-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Store this token securely. You won't be able to see it again.
Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>
```

Copy the `sk-ant-oat01-...` token. This one lasts a year.

### 2. Add GitHub Secret

Go to your repository → Settings → Secrets and variables → Actions → New repository secret:

- **Name:** `CLAUDE_OAUTH_TOKEN`  
- **Value:** Just the token string (`sk-ant-oat01-...`), nothing else

The workflow passes it as the `CLAUDE_CODE_OAUTH_TOKEN` environment variable inside the tmux session. No credentials files, no JSON formatting — Claude Code reads the env var directly.

### 3. Enable the workflow

The workflow runs on:
- **Schedule:** Every 6 hours (`0 */6 * * *`)
- **Manual dispatch:** Click "Run workflow" in the Actions tab

### 4. Permissions

The workflow needs `contents: write` permission to commit changes. This is configured in the workflow file.

## How it works

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
└─────────────────────────────────────────┘
```

The process tree: `bash → tmux → bash → claude`

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

## Standalone usage

The orchestration script also works standalone on any Linux/macOS machine:

```bash
chmod +x scripts/interactive-claude.sh
./scripts/interactive-claude.sh "Add today's date to log.txt"
```

## Disclaimer

This is a technical proof of concept. You are responsible for making sure your use of it complies with Anthropic's Terms of Service.
