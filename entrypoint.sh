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

# --- Preflight (v2 diagnostics) -------------------------------------------
# Prove the runtime works as the unprivileged node user before starting
# the real service, so a failure here names its own cause in the log.
echo "=== dsh preflight ==="
gosu node sh -c '
  echo "user=$(whoami) HOME=$HOME DSH_HOME=${DSH_HOME:-unset}"
  node --version
  dsh --version
  for d in "$DSH_HOME" "$HOME" "${DSH_WORKSPACE:-/data/workspace}"; do
    if touch "$d/.write-test" 2>/dev/null; then
      echo "writable: $d"; rm -f "$d/.write-test"
    else
      echo "NOT writable: $d"
    fi
  done
' || echo "WARNING: preflight reported problems (see above)"
df -h /data 2>/dev/null | tail -1 || true
free -m | head -2 || true
echo "=== dsh preflight done ==="

# dsh runs as the unprivileged node user; its state is under $DSH_HOME.
# v2: capture dsh's output to a file AND stream it to the container log.
# If dsh dies during startup, dump the whole file plus diagnostics —
# v1 relied on the output having reached the log on its own, and in
# practice nothing showed up between the start line and the error.
DSH_LOG=/tmp/dsh.log
: > "$DSH_LOG"
gosu node dsh "${DSH_ARGS[@]}" >>"$DSH_LOG" 2>&1 &
DSH_PID=$!
tail -f "$DSH_LOG" &
TAIL_PID=$!

dump_dsh_failure() {
  kill "$TAIL_PID" 2>/dev/null || true
  echo "ERROR: dsh exited during startup." >&2
  echo "=== dsh log (complete) ===" >&2
  cat "$DSH_LOG" >&2 || true
  echo "=== dsh log end ===" >&2
  echo "--- state: ls -la \$DSH_HOME, free, df ---" >&2
  ls -la "$DSH_HOME" 2>&1 | head -20 >&2 || true
  free -m 2>/dev/null | head -2 >&2 || true
  df -h /data 2>/dev/null | tail -1 >&2 || true
}

# Make sure a container stop takes dsh down with Caddy, and vice versa.
trap 'kill "$DSH_PID" "$TAIL_PID" 2>/dev/null || true' EXIT
UP=0
for _ in $(seq 1 90); do
  # dsh answers 401 on / without its token — a response at all means "up"
  # (curl still exits 0; a refused connection exits non-zero).
  if curl -s -o /dev/null "http://127.0.0.1:${DSH_PORT}/"; then UP=1; break; fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    sleep 1  # let the final log lines flush into the file
    dump_dsh_failure
    exit 1
  fi
  sleep 1
done
if [ "$UP" != 1 ]; then
  echo "ERROR: dsh did not answer on 127.0.0.1:${DSH_PORT} within 90s" >&2
  echo "but its process is still running — dumping its log:" >&2
  cat "$DSH_LOG" >&2 || true
  exit 1
fi

echo "dsh is up on 127.0.0.1:${DSH_PORT}; Caddy listening on :${PORT}"
echo "First login: find the 'http(s)://.../?token=...' line in the dsh log"
echo "output above, open it, and pass the Basic Auth prompt first"
echo "(user: ${DSH_UI_USERNAME}). The token changes on every restart."

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
trap 'kill "$DSH_PID" "$CADDY_PID" "$TAIL_PID" 2>/dev/null || true' EXIT
wait -n "$DSH_PID" "$CADDY_PID"
