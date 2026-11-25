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
set -uo pipefail

PORT="${PORT:-10000}"
DSH_PORT=3080
export DSH_HOME="${DSH_HOME:-/data/.dsh}"
export DSH_WORKSPACE="${DSH_WORKSPACE:-/data/workspace}"
# Render overrides the Dockerfile's ENV HOME with /home/node (ephemeral
# overlay). Force HOME onto the persistent disk so npm/pnpm caches and
# any home-relative dsh state survive redeploys. (v3 — preflight on the
# first deploys showed HOME=/home/node.)
export HOME=/data/home
export DSH_UI_USERNAME="${DSH_UI_USERNAME:-admin}"

if [ -z "${DSH_UI_PASSWORD:-}" ]; then
  echo "ERROR: DSH_UI_PASSWORD is not set. Refusing to start without the" >&2
  echo "Basic Auth gate — dsh can execute shell commands in this container." >&2
  exit 1
fi

mkdir -p "$DSH_HOME" "$DSH_WORKSPACE" "$HOME"
chown -R node:node /data

# Is /data actually a mounted disk, or just a directory on the overlay?
# (v3 — the first deploys' df showed /data resolving to the overlay /,
# i.e. NO persistent disk was attached, so all state would be lost on
# every redeploy and the instance was likely a small no-disk plan.)
if [ "$(df /data | tail -1 | awk '{print $1}')" = "$(df / | tail -1 | awk '{print $1}')" ]; then
  echo "WARNING: /data is NOT a separate mount — no persistent disk is" >&2
  echo "attached to this service. State in /data will be lost on every" >&2
  echo "redeploy. Add a disk mounted at /data in the Render dashboard." >&2
else
  echo "disk: /data is a persistent mount: $(df -h /data | tail -1)"
fi

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

# --- Preflight -------------------------------------------------------------
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
grep -E 'MemTotal|MemAvailable' /proc/meminfo || true
echo "=== dsh preflight done ==="

# --- dsh startup, with one diagnostic retry --------------------------------
# v2 showed dsh dying seconds after start with a COMPLETELY EMPTY log —
# the signature of a SIGKILL (e.g. OOM on a too-small instance), not a
# normal error exit. v3 therefore records the exact exit status/signal
# (137 = 128+SIGKILL), and if the public-URL attempt dies, retries once
# WITHOUT --public-url/--trusted-host so the next log separates
# "those arguments / that environment" from "dsh cannot run here at all".
DSH_LOG=/tmp/dsh.log
TAIL_PID=""
DSH_PID=""

stop_tail() { [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true; TAIL_PID=""; }
trap 'stop_tail; [ -n "$DSH_PID" ] && kill "$DSH_PID" 2>/dev/null || true' EXIT

start_dsh() {  # $1 = log file, rest = args
  local log="$1"; shift
  : > "$log"
  gosu node dsh "$@" >>"$log" 2>&1 &
  DSH_PID=$!
  tail -f "$log" &
  TAIL_PID=$!
}

# Returns 0 if dsh answers on $DSH_PORT, 1 if it died, 2 on timeout.
# On death, DSH_RC holds the wait status (128+signal for kills).
wait_for_dsh() {
  local i
  for i in $(seq 1 90); do
    if curl -s -o /dev/null "http://127.0.0.1:${DSH_PORT}/"; then return 0; fi
    if ! kill -0 "$DSH_PID" 2>/dev/null; then
      wait "$DSH_PID"; DSH_RC=$?
      sleep 1  # let final log lines flush
      return 1
    fi
    sleep 1
  done
  return 2
}

dump_state() {
  echo "--- state diagnostics ---" >&2
  grep -E 'MemTotal|MemAvailable' /proc/meminfo >&2 || true
  dmesg 2>/dev/null | tail -5 >&2 || echo "(dmesg not readable)" >&2
  echo "--- \$DSH_HOME tree (depth 3) ---" >&2
  find "$DSH_HOME" -maxdepth 3 2>/dev/null | head -40 >&2 || true
}

echo "=== dsh attempt 1: with --public-url/--trusted-host ==="
start_dsh "$DSH_LOG" "${DSH_ARGS[@]}"
wait_for_dsh; RC1=$?
if [ "$RC1" = 1 ]; then
  stop_tail
  echo "ERROR: attempt 1 died, exit status ${DSH_RC:-unknown}" >&2
  echo "(137 = SIGKILL, usually OOM or a platform kill; 139 = SIGSEGV)" >&2
  echo "=== dsh log attempt 1 (complete) ===" >&2
  cat "$DSH_LOG" >&2 || true
  echo "=== dsh log attempt 1 end ===" >&2
  dump_state

  echo "=== dsh attempt 2: plain, no --public-url/--trusted-host ==="
  start_dsh "$DSH_LOG" web --no-open --port "$DSH_PORT"
  wait_for_dsh; RC1=$?
  if [ "$RC1" = 1 ]; then
    stop_tail
    echo "ERROR: attempt 2 also died, exit status ${DSH_RC:-unknown}" >&2
    echo "=== dsh log attempt 2 (complete) ===" >&2
    cat "$DSH_LOG" >&2 || true
    echo "=== dsh log attempt 2 end ===" >&2
    dump_state
    exit 1
  fi
fi
if [ "$RC1" = 2 ]; then
  echo "ERROR: dsh did not answer within 90s; dumping its log:" >&2
  cat "$DSH_LOG" >&2 || true
  exit 1
fi
# Note: if we got here via attempt 2, dsh is running WITHOUT the public
# URL arguments — the UI is reachable through Caddy, but the token URL
# in the log points at 127.0.0.1 (swap in the public host to use it)
# and Settings may be limited. That is a diagnostic fallback, not the
# intended final state.
trap 'stop_tail; kill "$DSH_PID" 2>/dev/null || true' EXIT

echo "dsh is up on 127.0.0.1:${DSH_PORT}; Caddy listening on :${PORT}"
echo "First login: find the 'http(s)://.../?token=...' line in the dsh log"
echo "output above, open it, and pass the Basic Auth prompt first"
echo "(user: ${DSH_UI_USERNAME}). The token changes on every restart."

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!
trap 'stop_tail; kill "$DSH_PID" "$CADDY_PID" 2>/dev/null || true' EXIT
wait -n "$DSH_PID" "$CADDY_PID"
