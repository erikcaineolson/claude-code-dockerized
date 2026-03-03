# Claude Code — Dockerized

A Docker container with [Claude Code](https://claude.ai/code), the [GitHub CLI](https://cli.github.com/), and the [PAL MCP Server](https://github.com/BeehiveInnovations/pal-mcp-server) (formerly Zen MCP) pre-installed.

PAL (Provider Abstraction Layer) lets Claude Code delegate tasks to 50+ AI models from Google Gemini, OpenAI, xAI, OpenRouter, and more — enabling multi-model collaboration, extended reasoning, and consensus-driven code review from inside a single Claude session.

## API Keys Required

| Key | Required? | What For | Where to Get It |
|-----|-----------|----------|-----------------|
| `ANTHROPIC_API_KEY` | **Yes** | Claude Code itself | [console.anthropic.com](https://console.anthropic.com/settings/keys) |
| `GEMINI_API_KEY` | At least one PAL key | PAL MCP → Gemini models | [aistudio.google.com](https://aistudio.google.com/apikey) |
| `OPENAI_API_KEY` | At least one PAL key | PAL MCP → OpenAI models | [platform.openai.com](https://platform.openai.com/api-keys) |
| `OPENROUTER_API_KEY` | Optional | PAL MCP → many models via one key | [openrouter.ai](https://openrouter.ai/keys) |
| `XAI_API_KEY` | Optional | PAL MCP → Grok models | [console.x.ai](https://console.x.ai/) |
| `GH_TOKEN` | Optional | GitHub CLI authentication | [github.com/settings/tokens](https://github.com/settings/tokens) |

You need `ANTHROPIC_API_KEY` plus **at least one** PAL provider key (Gemini has a free tier, making it the easiest starting point).

## Quick Start

```bash
# 1. Clone and enter the directory
cd claude-code-dockerized

# 2. Create your .env file from the template
cp .env.example .env

# 3. Edit .env and add your API keys (at minimum ANTHROPIC_API_KEY + one PAL key)
nano .env    # or your editor of choice

# 4. Build and run
docker compose up -d --build
docker compose exec claude claude

# Or run interactively in one shot
docker compose run --rm claude claude
```

## Usage

### Interactive Session

```bash
# Start the container
docker compose up -d

# Launch Claude Code interactively
docker compose exec claude claude
```

### One-Shot Commands

```bash
# Run a single prompt
docker compose run --rm claude claude -p "explain this codebase"

# Run with full autonomy (use with caution)
docker compose run --rm claude claude -p --dangerously-skip-permissions "fix the bug in main.py"
```

### Working with Your Code

The `workspace/` directory is mounted into the container at `/workspace`. Put your project files there, or change the volume mount in `docker-compose.yml` to point at an existing project:

```yaml
volumes:
  - /path/to/your/project:/workspace
```

### Using the GitHub CLI

```bash
# If GH_TOKEN is set in .env, gh is already authenticated
docker compose exec claude gh repo list
docker compose exec claude gh pr create --title "My PR" --body "Description"
```

## PAL MCP Tools

Once running, Claude Code has access to these PAL tools (enabled by default):

| Tool | Description |
|------|-------------|
| `analyze` | Architecture understanding across codebases |
| `apilookup` | Current-year API/SDK documentation lookup |
| `challenge` | Critical analysis to prevent yes-man behavior |
| `chat` | Multi-turn brainstorming with other AI models |
| `clink` | Bridge external AI CLIs and spawn subagents |
| `codereview` | Professional code reviews with severity levels |
| `consensus` | Multi-model expert opinions |
| `debug` | Systematic root cause investigation |
| `docgen` | Documentation generation |
| `planner` | Break complex projects into structured steps |
| `precommit` | Validate changes before commits |
| `refactor` | Intelligent code refactoring |
| `secaudit` | OWASP Top 10 security audits |
| `testgen` | Test generation with edge cases |
| `thinkdeep` | Extended reasoning and edge case analysis |
| `tracer` | Static analysis for call-flow mapping |

All PAL tools are enabled by default. Use the `DISABLED_TOOLS` environment variable to disable specific tools.

## Configuration

### Environment Variables

See `.env.example` for all available options. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `DEFAULT_MODEL` | `auto` | PAL model selection (`auto`, `pro`, `flash`, `o3`, etc.) |
| `DISABLED_TOOLS` | _(none)_ | Comma-separated PAL tools to disable |
| `GIT_USER_NAME` | — | Git commit author name |
| `GIT_USER_EMAIL` | — | Git commit author email |

### Custom MCP Configuration

The entrypoint auto-generates `~/.claude/settings.json` with PAL MCP on first run. To use your own config, mount it into the container:

```yaml
volumes:
  - ./my-settings.json:/home/node/.claude/settings.json:ro
```

### Build Arguments

| Arg | Default | Description |
|-----|---------|-------------|
| `CLAUDE_CODE_VERSION` | `latest` | Claude Code version (or pin a specific version) |
| `GIT_DELTA_VERSION` | `0.18.2` | Pin git-delta version |

## What's Included

- **Node.js 20** (slim) — base image
- **Claude Code** — Anthropic's CLI agent
- **GitHub CLI (gh)** — GitHub operations from the terminal
- **PAL MCP Server** — multi-model AI orchestration
- **uv** — fast Python package manager (for PAL)
- **ripgrep** — fast code search
- **git-delta** — improved diff output
- **git, curl, wget, jq, nano, vim-tiny** — standard dev tools

## Troubleshooting

### "PAL MCP server not configured"

You need at least one AI provider key (`GEMINI_API_KEY`, `OPENAI_API_KEY`, etc.) in your `.env` file for PAL to be auto-configured.

### Claude Code can't find PAL tools

Check that the MCP config was generated:
```bash
docker compose exec claude cat ~/.claude/settings.json
```

If it's missing or wrong, delete it and restart:
```bash
docker compose exec claude rm ~/.claude/settings.json
docker compose restart claude
```

### GitHub CLI not authenticated

Make sure `GH_TOKEN` is set in your `.env` file. The token needs `repo` scope at minimum.

### Slow first run

The first time PAL MCP is invoked, `uvx` fetches and installs the Python dependencies. Subsequent runs use the cached installation.
