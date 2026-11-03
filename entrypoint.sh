#!/usr/bin/env bash
set -e

# Configure git if GIT_USER_NAME and GIT_USER_EMAIL are set
if [ -n "$GIT_USER_NAME" ]; then
  git config --global user.name "$GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
fi

# -----------------------------------------------------------------------------
# GitHub auth — multiple accounts, kept OUT of the interactive environment
#
# Declare one token per GitHub account in .env using the convention
#   GH_TOKEN_<OWNER>   (OWNER = the github.com owner/org name, uppercased, with
#                       every non-alphanumeric turned into `_`), e.g.
#                       GH_TOKEN_EFFINA, GH_TOKEN_ERIKCAINEOLSON.
# A bare GH_TOKEN (no suffix) still works as the default/fallback account.
#
# At boot we:
#   1. write each token to a private 0600 file under $GH_TOKENS_DIR (NOT a
#      persisted volume, NOT the process environment),
#   2. unset every GH_TOKEN* variable from this shell so it is NOT inherited by
#      Claude Code or any command it runs — nothing leaks the token via an `env`
#      dump, /proc/<pid>/environ, a crash log, or `docker inspect`, and
#   3. wire git (via a credential helper) and a `gh-for` helper to select the
#      right token by repository owner.
#
# IMPORTANT: this limits *accidental* leakage and `docker inspect` exposure. It
# does NOT stop a command the agent deliberately runs from reading the token
# files — the agent runs unsandboxed in here by design. The real blast-radius
# control is scoping each token service-side (fine-grained PAT, least
# privilege, short expiry). See SECURITY.md.
# -----------------------------------------------------------------------------
export GH_TOKENS_DIR="${GH_TOKENS_DIR:-$HOME/.config/gh-tokens}"
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$GH_TOKENS_DIR" "$LOCAL_BIN"
chmod 700 "$GH_TOKENS_DIR"
# Start clean so a token removed from .env doesn't linger from a previous boot.
rm -f "$GH_TOKENS_DIR"/* "$GH_TOKENS_DIR"/.owner-map 2>/dev/null || true

gh_wrote_any=0
for _var in "${!GH_TOKEN_@}"; do
  [ -n "$_var" ] || continue
  _acct="${_var#GH_TOKEN_}"
  _val="${!_var}"
  [ -n "$_val" ] || continue
  printf '%s' "$_val" > "$GH_TOKENS_DIR/$_acct"
  chmod 600 "$GH_TOKENS_DIR/$_acct"
  gh_wrote_any=1
done
if [ -n "${GH_TOKEN:-}" ]; then
  printf '%s' "$GH_TOKEN" > "$GH_TOKENS_DIR/_DEFAULT"
  chmod 600 "$GH_TOKENS_DIR/_DEFAULT"
  gh_wrote_any=1
fi

if [ "$gh_wrote_any" = 1 ]; then
  # Optional explicit owner->account overrides for when a repo owner/org name
  # doesn't match its token's account key. Format: "owner1=ACCT1,owner2=ACCT2".
  printf '%s' "${GH_OWNER_MAP:-}" > "$GH_TOKENS_DIR/.owner-map"
  chmod 600 "$GH_TOKENS_DIR/.owner-map"

  # git credential helper: picks the token by repo owner from the request path.
  cat > "$LOCAL_BIN/git-credential-ghmap" <<'HELPER'
#!/usr/bin/env bash
# git credential helper — route github.com auth to the per-owner token written
# by entrypoint.sh. Stateless; reads token files, never the environment.
[ "${1:-}" = get ] || exit 0
host="" ; path=""
while IFS='=' read -r k v; do
  case "$k" in host) host=$v ;; path) path=$v ;; esac
done
[ "$host" = github.com ] || exit 0
dir="${GH_TOKENS_DIR:-$HOME/.config/gh-tokens}"
owner="${path%%/*}"
norm() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g'; }
acct="$(norm "$owner")"
if [ -r "$dir/.owner-map" ]; then
  mapped="$(tr ',' '\n' < "$dir/.owner-map" | sed -n "s/^${owner}=//Ip" | head -1)"
  [ -n "$mapped" ] && acct="$mapped"
fi
tok=""
[ -r "$dir/$acct" ] && tok="$(cat "$dir/$acct")"
[ -z "$tok" ] && [ -r "$dir/_DEFAULT" ] && tok="$(cat "$dir/_DEFAULT")"
[ -n "$tok" ] || exit 0
echo "username=x-access-token"
echo "password=$tok"
HELPER
  chmod +x "$LOCAL_BIN/git-credential-ghmap"

  # gh-for <owner> <gh args...> — run gh as the account that owns <owner>.
  cat > "$LOCAL_BIN/gh-for" <<'GHFOR'
#!/usr/bin/env bash
set -euo pipefail
dir="${GH_TOKENS_DIR:-$HOME/.config/gh-tokens}"
[ $# -ge 1 ] || { echo "usage: gh-for <owner> <gh args...>" >&2; exit 2; }
owner="$1"; shift
norm() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g'; }
acct="$(norm "$owner")"
if [ -r "$dir/.owner-map" ]; then
  mapped="$(tr ',' '\n' < "$dir/.owner-map" | sed -n "s/^${owner}=//Ip" | head -1)"
  [ -n "$mapped" ] && acct="$mapped"
fi
tokfile="$dir/$acct"; [ -r "$tokfile" ] || tokfile="$dir/_DEFAULT"
[ -r "$tokfile" ] || { echo "gh-for: no token for owner '$owner' (looked for account '$acct')" >&2; exit 1; }
GH_TOKEN="$(cat "$tokfile")" exec gh "$@"
GHFOR
  chmod +x "$LOCAL_BIN/gh-for"

  # Point git at our helper for github.com only, passing the repo path so the
  # helper can see the owner. --replace-all clears any inherited helper so ours
  # is the sole one consulted.
  git config --global --replace-all credential.https://github.com.helper "$LOCAL_BIN/git-credential-ghmap"
  git config --global credential.https://github.com.useHttpPath true

  # Make bare `gh` usable with the default account (bare GH_TOKEN). gh's config
  # dir isn't a persisted volume, so this re-logs in cheaply on each boot.
  if [ -r "$GH_TOKENS_DIR/_DEFAULT" ]; then
    gh auth login --with-token < "$GH_TOKENS_DIR/_DEFAULT" >/dev/null 2>&1 || true
  fi

  echo "[entrypoint] GitHub: wrote per-owner token files to ${GH_TOKENS_DIR}; git routes by repo owner, use 'gh-for <owner> ...' for gh. Tokens scrubbed from the environment."
fi

# Scrub every GH_TOKEN* from this shell so none is inherited by `exec "$@"`.
for _var in "${!GH_TOKEN_@}"; do [ -n "$_var" ] && unset "$_var"; done
unset GH_TOKEN GH_OWNER_MAP _var _acct _val gh_wrote_any 2>/dev/null || true

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
