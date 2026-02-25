FROM node:20-slim

ARG CLAUDE_CODE_VERSION=latest
ARG GIT_DELTA_VERSION=0.18.2

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    less \
    procps \
    sudo \
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
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN mkdir -p -m 755 /etc/apt/keyrings && \
    wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install git-delta for better diffs
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Install uv to a shared location
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

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

# Install Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Pre-fetch PAL MCP server so first run is faster
RUN uvx --from git+https://github.com/BeehiveInnovations/pal-mcp-server.git pal-mcp-server --help 2>/dev/null || true

# Copy configuration and entrypoint
COPY --chown=${USERNAME}:${USERNAME} entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
