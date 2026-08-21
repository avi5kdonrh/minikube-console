#!/usr/bin/env bash
#
# One-command dev launcher: runs the OpenShift console (bridge) against a local
# minikube cluster WITH the networking-console-plugin, from a single terminal.
#
#   ./contrib/minikube-up.sh
#
# It sources contrib/minikube-environment.sh (off-cluster auth, cluster CA trust,
# a fresh 24h token, and BRIDGE_PLUGINS), starts the networking plugin dev server
# in its own process group, waits for it to compile, then runs bridge in the
# foreground. Press Ctrl-C once to stop everything cleanly.
#
# Optional env vars:
#   NETWORKING_PLUGIN_DIR=/path/to/networking-console-plugin   (default: sibling dir)
#   RUN_FRONTEND=1   also run `yarn dev` for live console-UI editing (default: use prebuilt dist)
#   PLUGIN_PORT=9001 CONSOLE_PORT=9000
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_DIR="${NETWORKING_PLUGIN_DIR:-$(cd "$REPO_ROOT/.." && pwd)/networking-console-plugin}"
PLUGIN_PORT="${PLUGIN_PORT:-9001}"
CONSOLE_PORT="${CONSOLE_PORT:-9000}"
PLUGIN_LOG="${TMPDIR:-/tmp}/networking-plugin-dev.log"
FRONTEND_LOG="${TMPDIR:-/tmp}/console-frontend-dev.log"

PLUGIN_PID=""
FRONTEND_PID=""

log()  { printf '\033[1;36m[minikube-up]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[minikube-up] ERROR:\033[0m %s\n' "$*" >&2; }

cleanup() {
  log "Shutting down..."
  # Kill each child's whole process group (they were started via setsid).
  for pid in "$PLUGIN_PID" "$FRONTEND_PID"; do
    [ -n "$pid" ] && kill -TERM -- -"$pid" 2>/dev/null
  done
  wait 2>/dev/null
  log "Done."
}
trap cleanup EXIT INT TERM

port_in_use() { ss -ltn 2>/dev/null | grep -q ":$1[[:space:]]"; }

# ---- preflight -------------------------------------------------------------
[ -x "$REPO_ROOT/bin/bridge" ] || { err "bin/bridge not found. Build it: ./build-backend.sh"; exit 1; }
[ -d "$PLUGIN_DIR" ] || { err "Plugin dir not found: $PLUGIN_DIR
  Clone it:  git clone https://github.com/openshift/networking-console-plugin.git \"$PLUGIN_DIR\"
  or set NETWORKING_PLUGIN_DIR."; exit 1; }

if ! kubectl cluster-info >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster. Is minikube running?  minikube start"
  exit 1
fi

if port_in_use "$CONSOLE_PORT"; then err "Port $CONSOLE_PORT already in use (bridge already running?)."; exit 1; fi
if port_in_use "$PLUGIN_PORT"; then err "Port $PLUGIN_PORT already in use (plugin already running?)."; exit 1; fi

if [ ! -d "$PLUGIN_DIR/node_modules" ]; then
  log "Installing plugin dependencies (first run)..."
  ( cd "$PLUGIN_DIR" && npm install ) || { err "npm install failed"; exit 1; }
fi

# ---- environment -----------------------------------------------------------
log "Applying minikube environment..."
# shellcheck source=contrib/minikube-environment.sh
source "$SCRIPT_DIR/minikube-environment.sh"

# ---- networking plugin dev server -----------------------------------------
log "Starting networking-console-plugin dev server on :$PLUGIN_PORT (log: $PLUGIN_LOG)"
setsid bash -c "cd '$PLUGIN_DIR' && exec npm run start" >"$PLUGIN_LOG" 2>&1 &
PLUGIN_PID=$!

log "Waiting for plugin to compile (first build can take ~45s)..."
for i in $(seq 1 120); do
  if curl -sf -o /dev/null "http://localhost:$PLUGIN_PORT/plugin-manifest.json"; then
    log "Plugin is serving."
    break
  fi
  if ! kill -0 "$PLUGIN_PID" 2>/dev/null; then
    err "Plugin dev server exited early. Last log lines:"; tail -20 "$PLUGIN_LOG" >&2; exit 1
  fi
  [ "$i" = 120 ] && { err "Plugin did not become ready in time. See $PLUGIN_LOG"; exit 1; }
  sleep 1
done

# ---- optional: live console frontend build --------------------------------
if [ "${RUN_FRONTEND:-0}" = "1" ]; then
  log "Starting console frontend (yarn dev) on watch mode (log: $FRONTEND_LOG)"
  setsid bash -c "cd '$REPO_ROOT/frontend' && exec yarn dev" >"$FRONTEND_LOG" 2>&1 &
  FRONTEND_PID=$!
  log "Waiting for initial frontend build (this is slow, several minutes)..."
  for i in $(seq 1 900); do
    [ -f "$REPO_ROOT/frontend/public/dist/index.html" ] && grep -q "main-chunk" "$REPO_ROOT/frontend/public/dist/index.html" 2>/dev/null && break
    if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then err "frontend build exited. See $FRONTEND_LOG"; exit 1; fi
    sleep 1
  done
fi

# ---- bridge (foreground) ---------------------------------------------------
log "Starting console (bridge) on http://localhost:$CONSOLE_PORT  —  Ctrl-C to stop everything."
cd "$REPO_ROOT"
./bin/bridge
