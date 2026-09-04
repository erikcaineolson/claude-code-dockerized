# Claude Code — Dockerized

A Docker container with [Claude Code](https://claude.ai/code), the [GitHub CLI](https://cli.github.com/), and two subordinate agent CLIs — [OpenAI Codex](https://github.com/openai/codex) and [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) — pre-installed and pre-authorized, so Claude can delegate work and get second-opinion code reviews from other models out of the box.

## API Keys Required

| Key | Required? | What For | Where to Get It |
|-----|-----------|----------|-----------------|
| `ANTHROPIC_API_KEY` | **Yes** | Claude Code itself | [console.anthropic.com](https://console.anthropic.com/settings/keys) |
| `GEMINI_API_KEY` | Optional | Gemini CLI (second-opinion reviews) | [aistudio.google.com](https://aistudio.google.com/apikey) |
| `GH_TOKEN` | Optional | GitHub CLI authentication | [github.com/settings/tokens](https://github.com/settings/tokens) |

Codex needs no API key: it signs in once with your ChatGPT account (`codex login`), persisted in the `codex-auth` volume.

## Quick Start

```bash
# 1. Clone and enter the directory
cd claude-code-dockerized

# 2. Create your .env file from the template
cp .env.example .env

# 3. Edit .env and add your API keys (at minimum ANTHROPIC_API_KEY)
nano .env    # or your editor of choice

# 4. Create the Codex auth volume (once per machine — it is declared `external`
#    so `docker compose down -v` can never wipe the Codex login)
docker volume create codex-auth

# 5. Build and run
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

#### Extra directories (machine-specific)

To mount additional host directories without touching the committed
`docker-compose.yml`, copy `docker-compose.override.yml.example` to
`docker-compose.override.yml` (gitignored) and list them there:

```yaml
services:
  claude:
    volumes:
      - ${HOME}/Documents/Notes:/projects/notes
```

Compose loads the override file automatically — no `-f` flags — and appends
these mounts to the base file's. Relative paths resolve against the repo
directory, `~` is not expanded (use `${HOME}`), and each target path must be
unique. Apply with `docker compose up -d claude`.

### Using the GitHub CLI

```bash
# If GH_TOKEN is set in .env, gh is already authenticated
docker compose exec claude gh repo list
docker compose exec claude gh pr create --title "My PR" --body "Description"
```

### OpenAI Codex (subordinate coding agent)

The image ships the [Codex CLI](https://github.com/openai/codex), and everything
Codex needs to work **out of the box** is codified in the build — the only
manual step, ever, is the one-time ChatGPT sign-in:

```bash
docker compose exec claude codex login
```

The login lands in the external `codex-auth` volume (`CODEX_HOME` points there),
so it survives restarts, rebuilds, and even `docker compose down -v`. Everything
else is automatic:

- **Claude Code permissions** — on every boot the entrypoint merges
  `Bash(codex exec:*)` and `Bash(codex-worker:*)` (plus version/login-status
  checks) into the allowlist in `~/.claude/settings.json`, so Claude can drive
  Codex without permission prompts even on a brand-new `claude-config` volume.
  The merge is a set-union: rules and settings you add yourself are preserved.
- **Codex defaults** — `~/.claude/codex/config.toml` is written on first boot
  with `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`
  (the container itself is the sandbox; see the comment in `entrypoint.sh`).
- **Worker launcher** — `bin/codex-worker.sh` is baked into the image on PATH
  as `codex-worker`, so Claude can spawn disposable sibling-container Codex
  workers from any project directory:

  ```bash
  codex-worker /projects/myapp "Review src/parser for edge cases"
  ```

  Workers mount only the `codex-auth` volume and the task's project directory —
  never the `claude-config` volume, SSH keys, or `.env` secrets.

If boot logs show `config.toml: Permission denied` or
`external volume "codex-auth" not found`, see [Troubleshooting](#troubleshooting).

### Google Gemini (second-opinion code reviews)

The image also ships the [Gemini CLI](https://github.com/google-gemini/gemini-cli),
which Claude drives over Bash the same way it drives Codex. Setup is one line:
put a `GEMINI_API_KEY` in `.env` (free tier at
[aistudio.google.com/apikey](https://aistudio.google.com/apikey)) — no login
flow, nothing stored in a volume. The entrypoint pre-authorizes
`Bash(gemini -p:*)` in the Claude Code allowlist, and the image sets
`GEMINI_CLI_TRUST_WORKSPACE=true` (headless `gemini -p` refuses untrusted
directories; the container is the trust boundary, same posture as Codex).

```bash
# Non-interactive, from any project directory — @path pulls files into context
gemini -p "@src/ Review this module for bugs and race conditions"
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

#### Importing your own keys and config (`./ssh`)

Files dropped into the repo's `ssh/` directory (gitignored and excluded from the
build context — only its README is committed) are **automatically copied into
`~/.ssh` inside the container on every start**: private keys land with mode
`600` and are wired up as `IdentityFile` fallbacks, `*.pub` files get `644`, a
file named `config` is `Include`d ahead of the container defaults so its
per-host settings win, and a `known_hosts` file is merged into the persisted
one. See `ssh/README.md` for details. Changes take effect on the next
`docker compose restart claude` — note a plain restart of an *old* container
re-runs that container's baked-in entrypoint, so after pulling entrypoint
changes, recreate it (`docker compose up -d --build`).

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

## Configuration

### Environment Variables

See `.env.example` for all available options. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_API_KEY` | — | Enables the Gemini CLI for second-opinion reviews |
| `GIT_USER_NAME` | — | Git commit author name |
| `GIT_USER_EMAIL` | — | Git commit author email |
| `PROJECTS_HOST_ROOT` | _(derived)_ | Host path of `/projects`, for codex-worker bind mounts |

### Custom MCP Configuration

To add MCP servers, register them user-scope from inside the container, or add
them per-project with a committed `.mcp.json` in the project root:

```bash
docker compose exec claude claude mcp add-json my-server '{"type":"stdio","command":"...","args":[]}' --scope user
```

Two gotchas worth knowing: user-scope servers live in `~/.claude.json` — an
`mcpServers` key in `~/.claude/settings.json` is silently ignored — and
`~/.claude.json` sits on the container filesystem, not the `claude-config`
volume, so user-scope registrations do not survive a container recreate.
Project-scope `.mcp.json` files live with the project and do.

### Build Arguments

| Arg | Default | Description |
|-----|---------|-------------|
| `CLAUDE_CODE_VERSION` | `latest` | Claude Code version (or pin a specific version) |
| `CODEX_VERSION` | `latest` | OpenAI Codex CLI version |
| `GEMINI_CLI_VERSION` | `latest` | Google Gemini CLI version |
| `GIT_DELTA_VERSION` | `0.18.2` | Pin git-delta version |
| `PHP_VERSION` | `8.4` | PHP CLI version installed from the Sury repo |

## What's Included

- **Node.js 20** (slim) — base image
- **Claude Code** — Anthropic's CLI agent
- **GitHub CLI (gh)** — GitHub operations from the terminal
- **OpenAI Codex CLI + `codex-worker`** — subordinate coding agent, pre-authorized for Claude and runnable in disposable sibling containers
- **Google Gemini CLI** — second-opinion code reviews via `gemini -p`, keyed by `GEMINI_API_KEY`
- **uv** — fast Python package manager
- **ripgrep** — fast code search
- **git-delta** — improved diff output
- **OpenSSH client** — outbound SSH to your own servers (auto-keyed)
- **PHP 8.4 CLI + Composer 2** — Laravel development (extensions listed above)
- **dev-mariadb / dev-redis** — sibling database + cache containers for local app runs and test suites
- **git, curl, wget, jq, nano, vim-tiny** — standard dev tools

## Troubleshooting

### Gemini CLI errors out

`API key not valid` means the `GEMINI_API_KEY` in `.env` is wrong, expired, or
revoked — mint a new one at [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
and recreate the container so the new env lands (`docker compose up -d claude`).
A "not running in a trusted directory" error means `GEMINI_CLI_TRUST_WORKSPACE`
isn't set — it's baked into the image, so this only happens if you've overridden
the environment; rebuild or export `GEMINI_CLI_TRUST_WORKSPACE=true`.

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
