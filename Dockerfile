# DeepSeek Harness (dsh) Web UI for Render — wrapper image.
#
# Why a wrapper at all: upstream @deepseek-ai/dsh only binds 127.0.0.1 and
# refuses --host 0.0.0.0, and it ships no Dockerfile. This image keeps dsh on
# loopback inside the container and puts Caddy on Render's $PORT in front of
# it, with HTTP Basic Auth as the gate. See README.md before deploying:
# anyone with that password can run shell commands in this container.

FROM node:24-slim

# Pinned versions — bump deliberately, dsh is a developer preview and
# releases can break compatibility. 0.2.2-rc.5 is the version verified on
# Enoch's own Ubuntu host (2026-11-23).
ARG DSH_VERSION=0.2.2-rc.5
ARG PNPM_VERSION=12.21.0
ARG CADDY_VERSION=2.11.2

# Tools the agent itself needs in its workspace: git/ripgrep/jq/python3,
# bubblewrap for dsh's command sandbox, gosu to drop from root to node,
# tini as PID 1.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq python3 bubblewrap gosu tini \
 && rm -rf /var/lib/apt/lists/*

# Caddy (single static binary) — the public-port reverse proxy / auth gate.
RUN curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin caddy \
 && caddy version

# dsh itself, plus pnpm (dsh's plugin manager needs it).
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" "pnpm@${PNPM_VERSION}" \
 && dsh --version

COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# State lives on the Render persistent disk mounted at /data (see
# render.yaml). Anything outside /data is lost on redeploy.
ENV DSH_HOME=/data/.dsh \
    DSH_WORKSPACE=/data/workspace \
    HOME=/data/home \
    DSH_TELEMETRY_MODE=DISABLED \
    NODE_ENV=production

EXPOSE 10000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
