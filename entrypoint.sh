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

# -----------------------------------------------------------------------------
# Agent CLI access for Claude Code (Codex, Gemini)
#
# Neither CLI is registered as an MCP server: under the supervisor model Fable
# drives them over Bash — Codex in-process via `codex exec`, Gemini in-process
# for second-opinion reviews (`gemini -p`, keyed by GEMINI_API_KEY from .env).
#
# Both are pre-authorized in the user-scope permission allowlist so a fresh
# claude-config volume drives them out of the box instead of stopping at
# permission prompts. `Bash(codex:*)` covers every subcommand (exec, login,
# resume, mcp, apply) so no Codex invocation stops for approval.
#
# The container is the sandbox, so Claude Code's own confinement is switched
# off to match the posture Codex already runs under here (approval_policy
# "never" / sandbox_mode "danger-full-access", written further down):
#   permissions.defaultMode  bypassPermissions — no tool prompts at all
#   sandbox.enabled          false — Bash is never wrapped; bwrap/socat aren't
#                            in the image and can't init under
#                            no-new-privileges anyway
#   skipDangerousModePermissionPrompt — don't re-ask to confirm bypass mode
# Revert these three if you ever run this image without the container boundary.
#
# This merges on EVERY boot (jq set-union — user-added rules and all other
# settings survive untouched), so it also upgrades volumes whose settings.json
# predates this feature.
# -----------------------------------------------------------------------------
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_JSON="${CLAUDE_DIR}/settings.json"
mkdir -p "$CLAUDE_DIR"

AGENT_CLI_ALLOW='["Bash(codex:*)","Bash(codex exec:*)","Bash(codex --version)","Bash(codex login status)","Bash(gemini -p:*)","Bash(gemini --version)"]'
[ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
TMP_SETTINGS="$(mktemp)"
if jq --argjson add "$AGENT_CLI_ALLOW" \
     '.permissions.allow = ((.permissions.allow // []) + $add | unique)
      | .permissions.defaultMode = "bypassPermissions"
      | .sandbox = ((.sandbox // {}) + {enabled: false, autoAllowBashIfSandboxed: true})
      | .skipDangerousModePermissionPrompt = true' \
     "$SETTINGS_JSON" > "$TMP_SETTINGS" 2>/dev/null; then
  mv "$TMP_SETTINGS" "$SETTINGS_JSON"
  echo "[entrypoint] Codex/Gemini allowlist + unsandboxed bypass mode ensured in ${SETTINGS_JSON}"
else
  rm -f "$TMP_SETTINGS"
  echo "[entrypoint] WARNING: ${SETTINGS_JSON} is not valid JSON — skipped agent CLI permission merge"
fi

# Drop the PAL MCP registration earlier images wrote into ~/.claude.json —
# PAL was removed (upstream is dormant and broken against the current MCP SDK).
claude mcp remove pal --scope user >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Codex non-interactive defaults
#
# So Fable can drive Codex without it stopping for approval. This container is
# itself the isolation boundary (non-root, no-new-privileges, disposable) — the
# same posture Claude Code runs under here — and Codex's own Landlock/seccomp
# sandbox can't initialize under no-new-privileges anyway, so we let Codex run
# with full in-container access and never block. Tighten sandbox_mode to
# "workspace-write" if you drop no-new-privileges and want Codex confined.
# Written only if absent, so your edits to config.toml survive restarts.
# -----------------------------------------------------------------------------
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_DIR"
if [ ! -f "${CODEX_DIR}/config.toml" ]; then
  cat > "${CODEX_DIR}/config.toml" <<'EOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF
  echo "[entrypoint] Wrote default Codex config to ${CODEX_DIR}/config.toml"
fi

# -----------------------------------------------------------------------------
# Outbound SSH client key
#
# On first boot we generate a fresh, dedicated keypair *inside* the container so
# it can SSH out to your own servers — without ever mounting your personal key.
# Add the printed public key to the remote server's ~/.ssh/authorized_keys, then
# `ssh user@host` from inside the container just works.
# -----------------------------------------------------------------------------
SSH_DIR="${CLAUDE_DIR}/ssh"
CLIENT_KEY="${SSH_DIR}/id_ed25519"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Fresh, container-generated key — persisted via the claude-config volume so the
# public key you authorize on remote servers stays stable across restarts.
if [ ! -f "$CLIENT_KEY" ]; then
  ssh-keygen -t ed25519 -f "$CLIENT_KEY" -N "" -C "claude-code-container" -q
  echo "[entrypoint] Generated a fresh outbound SSH key for this container."
  echo "[entrypoint] Add this public key to your servers' ~/.ssh/authorized_keys:"
  echo "    $(cat "${CLIENT_KEY}.pub")"
fi

# Lock the keypair read-only (0400). These should never be edited; if you ever
# truly need to (e.g. manual rotation), chmod up first, then change them.
chmod 400 "$CLIENT_KEY" "${CLIENT_KEY}.pub"

# -----------------------------------------------------------------------------
# Host-provided SSH config and keys (optional)
#
# The repo's gitignored ./ssh directory (see ssh/README.md) is bind-mounted
# read-only at /home/node/host-ssh. Its contents are copied into ~/.ssh here
# rather than used in place: bind mounts preserve host permissions, and ssh
# refuses group/world-readable keys. A file named `config` is Include'd ahead
# of the defaults below so its per-host settings win; every other private key
# is appended as an IdentityFile fallback so a bare key works without a config.
# -----------------------------------------------------------------------------
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

HOST_SSH_SRC="/home/node/host-ssh"
HOST_SSH_INCLUDE=""
EXTRA_IDENTITIES=""
if [ -d "$HOST_SSH_SRC" ]; then
  for f in "$HOST_SSH_SRC"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      README*|*.md|.DS_Store)
        ;;
      config)
        cp "$f" "$HOME/.ssh/host_config"
        chmod 600 "$HOME/.ssh/host_config"
        HOST_SSH_INCLUDE="Include ${HOME}/.ssh/host_config"
        echo "[entrypoint] Imported host SSH config from ./ssh"
        ;;
      known_hosts)
        # Merged into the persisted known_hosts below.
        ;;
      *.pub)
        cp "$f" "$HOME/.ssh/$base"
        chmod 644 "$HOME/.ssh/$base"
        ;;
      *)
        cp "$f" "$HOME/.ssh/$base"
        chmod 600 "$HOME/.ssh/$base"
        EXTRA_IDENTITIES="${EXTRA_IDENTITIES}
    IdentityFile ${HOME}/.ssh/${base}"
        echo "[entrypoint] Imported host SSH key ${base} from ./ssh"
        ;;
    esac
  done
fi

# Point the ssh client at the persisted key and known_hosts by default.
touch "$KNOWN_HOSTS"
if [ -f "${HOST_SSH_SRC}/known_hosts" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$line" ]; then
      grep -qxF "$line" "$KNOWN_HOSTS" || echo "$line" >> "$KNOWN_HOSTS"
    fi
  done < "${HOST_SSH_SRC}/known_hosts"
fi
cat > "$HOME/.ssh/config" <<EOF
${HOST_SSH_INCLUDE}
Host *
    IdentityFile ${CLIENT_KEY}${EXTRA_IDENTITIES}
    UserKnownHostsFile ${KNOWN_HOSTS}
    IdentitiesOnly yes
EOF
chmod 600 "$HOME/.ssh/config"

exec "$@"
