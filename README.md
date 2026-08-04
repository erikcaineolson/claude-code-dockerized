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

### Outbound SSH (reach your own servers)

So Claude can SSH out to servers in a walled garden, the container generates a
**fresh, dedicated SSH keypair inside itself** on first boot — your personal SSH
key is never mounted in. Nothing listens for inbound connections; the container
only acts as an SSH *client*.

On first boot the public key is printed to the container logs:

```bash
docker compose logs claude | grep -A1 "public key"
```

You can also read it any time:

```bash
docker compose exec claude cat ~/.claude/ssh/id_ed25519.pub
```

Add that public key to each target server's `~/.ssh/authorized_keys`. Then SSH
out from inside the container — the key, `known_hosts`, and config are wired up
automatically:

```bash
docker compose exec claude ssh user@your-server
```

The keypair, config, and `known_hosts` live in the persisted `claude-config`
volume, so the public key you authorize stays stable across restarts. To rotate
it, delete the key and restart:

```bash
docker compose exec claude rm -f ~/.claude/ssh/id_ed25519 ~/.claude/ssh/id_ed25519.pub
docker compose restart claude
```

#### Key permissions

On every boot the entrypoint locks the keypair to `0400` (read-only, owner only).
The keys are generated once and should never be edited in place, so removing the
write bit guards against accidental or unwanted changes — and `ssh` refuses to
use a private key that's group/world-readable anyway. If you ever genuinely need
to modify them (e.g. manual rotation), `chmod 600` first, make the change, and
the next boot will re-lock them to `0400`.

### PHP / Laravel toolchain + dev services

The image ships **PHP 8.4 CLI** (Sury repo, pinned via the `PHP_VERSION` build
arg) with the extension set Laravel apps need — `pdo_mysql`, `gd`
(freetype/jpeg/webp), `zip`, `intl`, `bcmath`, `exif`, `redis`, `mbstring`,
`xml`, `curl`, `sqlite3` — plus **Composer 2**. `php artisan`, `pest`,
`phpstan`, and `pint` all run natively inside the container.

For apps that need a real database, the compose file defines sibling
containers on the same network (not published to the host):

| Service | Image | Reach it at |
|---------|-------|-------------|
| `dev-mariadb` | `mariadb:10.11` | `DB_HOST=dev-mariadb`, port `3306` |
| `dev-redis` | `redis:alpine` | `REDIS_HOST=dev-redis`, port `6379` |

`docker compose up -d` starts them alongside the claude container. A one-shot
`dev-mariadb-init` sidecar creates the empty `testing` database (for test
suites that set `DB_DATABASE=testing`) and grants the app user on it — it's
idempotent and exits after running. Data persists in the `mariadb-data`
volume. Dev credentials default to `app` / `secret` (root: `root`)
and can be overridden in `.env`.

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
| `PHP_VERSION` | `8.4` | PHP CLI version installed from the Sury repo |

## What's Included

- **Node.js 20** (slim) — base image
- **Claude Code** — Anthropic's CLI agent
- **GitHub CLI (gh)** — GitHub operations from the terminal
- **PAL MCP Server** — multi-model AI orchestration
- **uv** — fast Python package manager (for PAL)
- **ripgrep** — fast code search
- **git-delta** — improved diff output
- **OpenSSH client** — outbound SSH to your own servers (auto-keyed)
- **PHP 8.4 CLI + Composer 2** — Laravel development (extensions listed above)
- **dev-mariadb / dev-redis** — sibling database + cache containers for local app runs and test suites
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

### "external volume \"codex-auth\" not found"

The `codex-auth` volume is declared `external` so `docker compose down -v` can't wipe the Codex login, which means Compose won't create it for you. Create it once before the first bring-up:

```bash
docker volume create codex-auth
```

### "config.toml: Permission denied" from entrypoint.sh

The `codex-auth` volume was created root-owned, so the `node` user can't write Codex's config into it. This happens when the volume is first mounted by an image that predates the fix creating `/home/node/.claude/codex` in the image (Docker initializes an empty volume with the image directory's ownership — no directory in the image means the mountpoint defaults to root).

Fix the existing volume's ownership (safe — preserves any Codex login already stored there):

```bash
docker run --rm -v codex-auth:/codex alpine chown -R 1000:1000 /codex
```

Then rebuild so fresh volumes get the right ownership automatically:

```bash
docker compose build && docker compose up -d
```

### GitHub CLI not authenticated

Make sure `GH_TOKEN` is set in your `.env` file. The token needs `repo` scope at minimum.

### Slow first run

The first time PAL MCP is invoked, `uvx` fetches and installs the Python dependencies. Subsequent runs use the cached installation.
