#!/usr/bin/env bash
set -e

# Configure git if GIT_USER_NAME and GIT_USER_EMAIL are set
if [ -n "$GIT_USER_NAME" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# Configure GitHub CLI auth if GH_TOKEN is set
if [ -n "$GH_TOKEN" ]; then
  echo "$GH_TOKEN" | gh auth login --with-token 2>/dev/null || true
fi

# Set up Claude Code MCP config for PAL MCP server if any provider key is set
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MCP_CONFIG="${CLAUDE_DIR}/settings.json"

if [ -n "$GEMINI_API_KEY" ] || [ -n "$OPENAI_API_KEY" ] || [ -n "$OPENROUTER_API_KEY" ] || [ -n "$XAI_API_KEY" ]; then
  mkdir -p "$CLAUDE_DIR"

  # Only write MCP config if it doesn't already exist (don't overwrite user config)
  if [ ! -f "$MCP_CONFIG" ]; then
    # Build env block dynamically using jq for safe JSON construction
    ENV_BLOCK="{}"
    for VAR in GEMINI_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY XAI_API_KEY DEFAULT_MODEL DISABLED_TOOLS; do
      VAL="${!VAR}"
      if [ -n "$VAL" ]; then
        ENV_BLOCK=$(echo "$ENV_BLOCK" | jq --arg k "$VAR" --arg v "$VAL" '. + {($k): $v}')
      fi
    done

    # Find uvx binary
    UVX_PATH=$(command -v uvx 2>/dev/null || echo "$HOME/.local/bin/uvx")

    # Build the entire settings.json safely with jq (no string interpolation)
    jq -n \
      --arg cmd "$UVX_PATH --from git+https://github.com/BeehiveInnovations/pal-mcp-server.git@${PAL_MCP_COMMIT} pal-mcp-server" \
      --argjson env "$ENV_BLOCK" \
      '{
        mcpServers: {
          pal: {
            type: "stdio",
            command: "bash",
            args: ["-c", $cmd],
            env: $env
          }
        }
      }' > "$MCP_CONFIG"

    echo "[entrypoint] PAL MCP server configured in ${MCP_CONFIG}"
  else
    echo "[entrypoint] Existing MCP config found at ${MCP_CONFIG}, skipping auto-configuration"
  fi
else
  echo "[entrypoint] No AI provider keys found (GEMINI_API_KEY, OPENAI_API_KEY, etc.) — PAL MCP server not configured"
fi

exec "$@"
