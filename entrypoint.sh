#!/bin/bash
# Entrypoint: start dsh on loopback, then Caddy on Render's $PORT in front.
#
# Required env (set in the Render dashboard / render.yaml):
#   DSH_UI_PASSWORD   plain password for the Basic Auth gate. This is the
#                     ONLY thing between the internet and an agent that can
#                     run shell commands here — make it long and unique.
# Optional env:
#   DSH_UI_USERNAME   default: admin
#   DSH_PUBLIC_URL    public root of this service, e.g.
#                     https://dsh-xxxx.onrender.com — if unset, Render's
#                     RENDER_EXTERNAL_URL is used. Set it explicitly when
#                     you attach a custom domain.
#   DEEPSEEK_API_KEY  if unset, add the key later in the UI under
#                     Settings -> Models.
set -euo pipefail

PORT="${PORT:-10000}"
DSH_PORT=3080
export DSH_HOME="${DSH_HOME:-/data/.dsh}"
export DSH_WORKSPACE="${DSH_WORKSPACE:-/data/workspace}"
export HOME="${HOME:-/data/home}"
export DSH_UI_USERNAME="${DSH_UI_USERNAME:-admin}"

if [ -z "${DSH_UI_PASSWORD:-}" ]; then
  echo "ERROR: DSH_UI_PASSWORD is not set. Refusing to start without the" >&2
  echo "Basic Auth gate — dsh can execute shell commands in this container." >&2
  exit 1
fi

mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$HOME" /data/home
chown -R node:node /data

# Caddyfile expects the bcrypt hash, not the plain password.
DSH_UI_PASSWORD_HASH="$(caddy hash-password --plaintext "$DSH_UI_PASSWORD")"
export DSH_UI_PASSWORD_HASH
export PORT

# Public URL / trusted host: dsh's --public-url only advertises the address;
# --trusted-host is what actually admits that authority at its /api fence.
# Both come from the same value so the printed token URL works as-is.
PUBLIC_URL="${DSH_PUBLIC_URL:-${RENDER_EXTERNAL_URL:-}}"
DSH_ARGS=(web --no-open --port "$DSH_PORT")
if [ -n "$PUBLIC_URL" ]; then
  TRUSTED_HOST="$(printf '%s' "$PUBLIC_URL" | sed -E 's#^https?://##; s#/.*$##')"
  DSH_ARGS+=(--public-url "$PUBLIC_URL" --trusted-host "$TRUSTED_HOST")
  echo "dsh: public-url=$PUBLIC_URL trusted-host=$TRUSTED_HOST"
else
  echo "WARNING: no DSH_PUBLIC_URL / RENDER_EXTERNAL_URL — the token URL" >&2
  echo "printed below will point at 127.0.0.1 and Settings may refuse the" >&2
  echo "public domain. Set DSH_PUBLIC_URL and redeploy." >&2
fi

# dsh runs as the unprivileged node user; its state is under $DSH_HOME.
gosu node dsh "${DSH_ARGS[@]}" &
DSH_PID=$!

# Make sure a container stop takes dsh down with Caddy, and vice versa.
trap 'kill "$DSH_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  # dsh answers 401 on / without its token — a response at all means "up"
  # (curl still exits 0; a refused connection exits non-zero).
  if curl -s -o /dev/null "http://127.0.0.1:${DSH_PORT}/"; then break; fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "ERROR: dsh exited during startup; see its log lines above." >&2
    exit 1
  fi
  sleep 1
done

echo "dsh is up on 127.0.0.1:${DSH_PORT}; Caddy listening on :${PORT}"
echo "First login: find the 'http(s)://.../?token=...' line in the dsh log"
echo "output above, open it, and pass the Basic Auth prompt first"
echo "(user: ${DSH_UI_USERNAME}). The token changes on every restart."

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
trap 'kill "$DSH_PID" "$CADDY_PID" 2>/dev/null || true' EXIT
wait -n "$DSH_PID" "$CADDY_PID"
