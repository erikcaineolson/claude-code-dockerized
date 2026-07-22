FROM node:22-slim

ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG GIT_DELTA_VERSION=0.18.2
ARG PAL_MCP_COMMIT=7afc7c1cc96e23992c8f105f960132c657883bb1
ARG PHP_VERSION=8.4

# Install system dependencies and GitHub CLI in a single layer
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
    python3 \
    python3-pip \
    python3-venv \
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

# Install uv to a shared location
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install the Go toolchain (gofmt ships with it) — latest stable, arch-aware
RUN ARCH=$(dpkg --print-architecture) && \
    GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n1) && \
    wget -q "https://go.dev/dl/${GO_VERSION}.linux-${ARCH}.tar.gz" && \
    tar -C /usr/local -xzf "${GO_VERSION}.linux-${ARCH}.tar.gz" && \
    rm "${GO_VERSION}.linux-${ARCH}.tar.gz"
ENV PATH="/usr/local/go/bin:${PATH}"

# Install sqlc natively (no Docker image needed for codegen) into a shared bin
RUN GOBIN=/usr/local/bin go install github.com/sqlc-dev/sqlc/cmd/sqlc@latest

# Install PHP CLI + extensions (Sury repo — Debian stock tops out at 8.2) and
# Composer, for Laravel work (the Laravel app prod runs 8.4; see
# project-notes.md). exif, ctype, fileinfo, tokenizer, pdo, openssl and
# filter ship inside php-cli/common — only the packaged extensions are listed.
RUN curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg \
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
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# Enable pnpm/yarn shims via corepack (ships with Node)
RUN corepack enable

# Set up non-root user
ARG USERNAME=node
RUN mkdir -p /workspace /home/${USERNAME}/.claude && \
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
ENV PAL_MCP_COMMIT=${PAL_MCP_COMMIT}
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

# Pre-fetch PAL MCP server (pinned commit) so first run is faster
RUN uvx --from git+https://github.com/BeehiveInnovations/pal-mcp-server.git@${PAL_MCP_COMMIT} pal-mcp-server --help 2>&1 \
    || echo "[WARNING] PAL MCP pre-fetch failed, will download on first run"

# Copy configuration and entrypoint
COPY --chown=${USERNAME}:${USERNAME} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
