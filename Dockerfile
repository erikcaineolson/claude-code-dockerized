FROM node:24-slim

ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG GEMINI_CLI_VERSION=latest
ARG GIT_DELTA_VERSION=0.18.2
ARG PHP_VERSION=8.5

# Optional language toolchains — choose-your-own-adventure. Each is OFF by
# default so the base image stays lean: Node (the base image) plus the agent
# CLIs are always present; everything below is opt-in. Enable the ones you use
# via build args, wired through docker-compose.yml from .env, e.g.:
#   INSTALL_PYTHON=true INSTALL_GO=true docker compose build
# A toggle only takes effect on a (re)build. The safety story is the same for
# all of them: their package managers run third-party code at install time, and
# the container boundary + egress allowlist (SECURITY.md) is what confines it.
ARG INSTALL_PYTHON=false
ARG INSTALL_GO=false
ARG INSTALL_PHP=false
ARG INSTALL_RUBY=false
ARG INSTALL_RUST=false
ARG INSTALL_DOTNET=false

# Install system dependencies and GitHub CLI in a single layer. These are the
# always-present essentials (not language toolchains).
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    less \
    procps \
    fzf \
    jq \
    nano \
    vim-tiny \
    unzip \
    gnupg2 \
    ca-certificates \
    ripgrep \
    openssh-client \
    && mkdir -p -m 755 /etc/apt/keyrings \
    && wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod go+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install git-delta for better diffs
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# -----------------------------------------------------------------------------
# OPTIONAL: Python 3 (+ pip, venv) and uv. Many MCP servers and agent tools
# quietly assume python3 is available, and it's cheap, so this is the toolchain
# most setups want on even when they don't write much Python themselves.
# -----------------------------------------------------------------------------
RUN if [ "$INSTALL_PYTHON" = "true" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends python3 python3-pip python3-venv \
      && apt-get clean && rm -rf /var/lib/apt/lists/* \
      && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh; \
    fi

# -----------------------------------------------------------------------------
# OPTIONAL: Go toolchain (gofmt ships with it, latest stable, arch-aware) + sqlc
# (installed natively, no Docker image needed for codegen) into a shared bin.
# PATH is set unconditionally; the dir simply won't exist if Go isn't installed.
# -----------------------------------------------------------------------------
ENV PATH="/usr/local/go/bin:${PATH}"
RUN if [ "$INSTALL_GO" = "true" ]; then \
      ARCH=$(dpkg --print-architecture) \
      && GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1) \
      && wget -q "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" \
      && tar -C /usr/local -xzf "${GO_VERSION}.linux-${ARCH}.tar.gz" \
      && rm "${GO_VERSION}.linux-${ARCH}.tar.gz" \
      && GOBIN=/usr/local/bin /usr/local/go/bin/go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest; \
    fi

# -----------------------------------------------------------------------------
# OPTIONAL: PHP CLI + extensions (Sury repo — Debian stock tops out at 8.2) and
# Composer, for Laravel work. exif, ctype, fileinfo, tokenizer, pdo, openssl and
# filter ship inside php-cli/common — only the packaged extensions are listed.
# -----------------------------------------------------------------------------
RUN if [ "$INSTALL_PHP" = "true" ]; then \
      curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg \
      && chmod go+r /etc/apt/keyrings/sury-php.gpg \
      && echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ $(. /etc/os-release && echo \"$VERSION_CODENAME\") main" \
        > /etc/apt/sources.list.d/sury-php.list \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
        php${PHP_VERSION}-cli \
        php${PHP_VERSION}-bcmath \
        php${PHP_VERSION}-curl \
        php${PHP_VERSION}-gd \
        php${PHP_VERSION}-intl \
        php${PHP_VERSION}-mbstring \
        php${PHP_VERSION}-mysql \
        php${PHP_VERSION}-redis \
        php${PHP_VERSION}-sqlite3 \
        php${PHP_VERSION}-xml \
        php${PHP_VERSION}-zip \
      && apt-get clean && rm -rf /var/lib/apt/lists/* \
      && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer; \
    fi

# -----------------------------------------------------------------------------
# OPTIONAL: Ruby + Bundler + Rails. build-essential is included so native gem
# extensions (nokogiri, etc.) compile.
# -----------------------------------------------------------------------------
RUN if [ "$INSTALL_RUBY" = "true" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends ruby-full build-essential \
      && apt-get clean && rm -rf /var/lib/apt/lists/* \
      && gem install --no-document bundler rails; \
    fi

# -----------------------------------------------------------------------------
# OPTIONAL: .NET SDK (C#/F#) via Microsoft's distro-agnostic install script,
# into a shared dir (same pattern as Go). Tracks the current LTS channel — edit
# --channel to pin a specific one. libicu is pulled in for globalization.
# -----------------------------------------------------------------------------
ENV DOTNET_ROOT="/usr/local/dotnet"
ENV PATH="/usr/local/dotnet:${PATH}"
# Opt out of .NET's telemetry (it phones home by default — matters under the
# egress posture) and silence the first-run banner. Harmless when .NET is absent.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
RUN if [ "$INSTALL_DOTNET" = "true" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends libicu-dev \
      && apt-get clean && rm -rf /var/lib/apt/lists/* \
      && curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
      && chmod +x /tmp/dotnet-install.sh \
      && /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet \
      && rm /tmp/dotnet-install.sh; \
    fi

# Enable pnpm/yarn shims via corepack (ships with Node)
RUN corepack enable

# Set up non-root user
ARG USERNAME=node
# The codex subdir must exist in the image owned by ${USERNAME}: the external
# codex-auth volume mounts there, and Docker initializes an empty volume with
# the image directory's ownership — without this it's created root-owned and
# entrypoint.sh can't write config.toml.
RUN mkdir -p /workspace /home/${USERNAME}/.claude/codex && \
    chown -R ${USERNAME}:${USERNAME} /workspace /home/${USERNAME}/.claude

# Set up npm global directory for non-root installs
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R ${USERNAME}:${USERNAME} /usr/local/share/npm-global

WORKDIR /workspace

USER ${USERNAME}

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH="/home/${USERNAME}/.local/bin:/usr/local/share/npm-global/bin:${PATH}"
ENV SHELL=/bin/bash
ENV EDITOR=nano
ENV DISABLE_AUTOUPDATER=1
# Persist Codex auth/config on the claude-config volume (mounted at ~/.claude),
# so `codex login` survives restarts and rebuilds just like the Claude Code login.
ENV CODEX_HOME=/home/${USERNAME}/.claude/codex

# Bust the layer cache whenever a new Claude Code release is published, so
# CLAUDE_CODE_VERSION=latest actually tracks latest on every rebuild instead of
# silently reusing a stale cached install. BuildKit re-checks this URL each
# build and only invalidates the layers below when its content changes.
ADD https://registry.npmjs.org/@anthropic-ai/claude-code/latest /tmp/claude-code-latest.json

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Bust the cache on new Codex releases too, so CODEX_VERSION=latest tracks latest
# on every rebuild (same rationale as the Claude Code ADD above).
ADD https://registry.npmjs.org/@openai/codex/latest /tmp/codex-latest.json

# Install OpenAI Codex CLI. Fable drives this as a subordinate coding agent.
# Auth (ChatGPT sign-in) and config persist via CODEX_HOME on the claude-config
# volume — see the ENV CODEX_HOME below — so you log in once, like Claude Code.
RUN npm install -g @openai/codex@${CODEX_VERSION}

# Bust the cache on new Gemini CLI releases (same rationale as above).
ADD https://registry.npmjs.org/@google/gemini-cli/latest /tmp/gemini-cli-latest.json

# Install Google's Gemini CLI. Fable drives it via Bash for second-opinion code
# reviews (`gemini -p "..."`), authenticated by GEMINI_API_KEY from .env.
RUN npm install -g @google/gemini-cli@${GEMINI_CLI_VERSION}

# Headless `gemini -p` refuses to run in an untrusted directory; the container
# is itself the trust/isolation boundary (same posture as Codex), so trust the
# workspace globally rather than per-directory.
ENV GEMINI_CLI_TRUST_WORKSPACE=true

# -----------------------------------------------------------------------------
# OPTIONAL: Rust via rustup (minimal profile — rustc + cargo, no docs). Installed
# for the non-root user so `cargo install`/registry caching work without root.
# PATH/CARGO_HOME/RUSTUP_HOME are set unconditionally; they're harmless (and the
# dirs simply absent) when Rust isn't installed.
# -----------------------------------------------------------------------------
ENV RUSTUP_HOME="/home/${USERNAME}/.rustup" \
    CARGO_HOME="/home/${USERNAME}/.cargo" \
    PATH="/home/${USERNAME}/.cargo/bin:${PATH}"
RUN if [ "$INSTALL_RUST" = "true" ]; then \
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --no-modify-path --default-toolchain stable; \
    fi

# Copy configuration and entrypoint
COPY --chown=${USERNAME}:${USERNAME} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
