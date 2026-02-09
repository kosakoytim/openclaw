FROM node:22-bookworm

# Install system dependencies for Playwright/Chromium
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpango-1.0-0 \
    libcairo2 \
    xvfb \
    x11vnc \
    && apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY scripts ./scripts

RUN pnpm install --frozen-lockfile

COPY . .
RUN OPENCLAW_A2UI_SKIP_MISSING=1 pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production

# Allow non-root user to write temp files during runtime/tests.
RUN chown -R node:node /app

# Create .openclaw directory with correct permissions for volume mounts
RUN mkdir -p /home/node/.openclaw && chown -R node:node /home/node/.openclaw

# Create playwright cache directory for node user
RUN mkdir -p /home/node/.cache/ms-playwright && chown -R node:node /home/node/.cache

# Switch to node user before installing Playwright browsers
USER node

# Install Playwright Chromium browser as node user
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
RUN node /app/node_modules/playwright-core/cli.js install chromium && \
    # Find the installed Chromium executable and create a symlink in a standard location \
    CHROMIUM_PATH=$(find /home/node/.cache/ms-playwright -name chrome -type f | head -1) && \
    mkdir -p /home/node/bin && \
    ln -s "$CHROMIUM_PATH" /home/node/bin/chromium

# Add chromium to PATH so OpenClaw can find it
ENV PATH="/home/node/bin:${PATH}"

# Set DISPLAY for Xvfb (virtual framebuffer for non-headless mode)
ENV DISPLAY=:99

# Create startup script to launch Xvfb and OpenClaw
USER root
RUN echo '#!/bin/bash\n\
set -e\n\
# Start Xvfb in the background\n\
Xvfb :99 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset &\n\
XVFB_PID=$!\n\
echo "Xvfb started with PID $XVFB_PID"\n\
\n\
# Wait for Xvfb to be ready\n\
sleep 2\n\
\n\
# Switch to node user and start OpenClaw\n\
exec su-exec node node /app/dist/index.js gateway --allow-unconfigured --bind lan\n\
' > /usr/local/bin/start-openclaw.sh && \
    chmod +x /usr/local/bin/start-openclaw.sh && \
    apt-get update && \
    apt-get install -y --no-install-recommends su-exec && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges

# Start gateway server with default config.
# Binds to lan (0.0.0.0) for container/VPS deployments.
# Xvfb is started first to provide a virtual display for non-headless Chrome.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
CMD ["/usr/local/bin/start-openclaw.sh"]
