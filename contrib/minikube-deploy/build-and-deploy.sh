#!/usr/bin/env bash
#
# One-shot: BUILD the console (backend + frontend) and the networking-console-plugin,
# then DEPLOY both into minikube. This is the convenience wrapper around the
# individual build steps + contrib/minikube-deploy/deploy.sh.
#
#   ./contrib/minikube-deploy/build-and-deploy.sh
#
# What it does (in order):
#   1. Backend   -> ./build-backend.sh          (produces bin/bridge)   [only if missing, or --backend]
#   2. Frontend  -> (cd frontend && yarn build)  (produces frontend/public/dist)
#   3. Plugin    -> (cd $PLUGIN_DIR && npm run build)  (production dist/)
#   4. Deploy    -> contrib/minikube-deploy/deploy.sh (images + rollout)
#
# Flags (all optional; by default frontend + plugin + deploy always run,
# backend only builds if bin/bridge is missing):
#   --backend           Force a backend rebuild even if bin/bridge exists.
#   --skip-backend      Never build the backend (fail later if bin/bridge missing).
#   --skip-frontend     Reuse the existing frontend/public/dist.
#   --skip-plugin       Reuse the existing plugin dist/.
#   --skip-deploy       Build only; do not touch minikube.
#   -h | --help         Show this help.
#
# Env vars (passed through to deploy.sh):
#   NETWORKING_PLUGIN_DIR=/path/to/networking-console-plugin  (default: sibling dir)
#   MINIKUBE_PROFILE=minikube
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="${NETWORKING_PLUGIN_DIR:-$(cd "$REPO_ROOT/.." && pwd)/networking-console-plugin}"

log()  { printf '\033[1;36m[build-and-deploy]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[build-and-deploy] ERROR:\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

FORCE_BACKEND=0
DO_BACKEND=1
DO_FRONTEND=1
DO_PLUGIN=1
DO_DEPLOY=1

while [ $# -gt 0 ]; do
  case "$1" in
    --backend)       FORCE_BACKEND=1 ;;
    --skip-backend)  DO_BACKEND=0 ;;
    --skip-frontend) DO_FRONTEND=0 ;;
    --skip-plugin)   DO_PLUGIN=0 ;;
    --skip-deploy)   DO_DEPLOY=0 ;;
    -h|--help)       sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

[ -d "$PLUGIN_DIR" ] || { err "plugin dir not found: $PLUGIN_DIR (set NETWORKING_PLUGIN_DIR)"; exit 1; }

SECONDS=0

# ---- 1. backend (bin/bridge) ----------------------------------------------
if [ "$DO_BACKEND" = "1" ] && { [ "$FORCE_BACKEND" = "1" ] || [ ! -x "$REPO_ROOT/bin/bridge" ]; }; then
  step "Building backend (bin/bridge)"
  ( cd "$REPO_ROOT" && ./build-backend.sh )
else
  log "Skipping backend build (bin/bridge present; use --backend to force)."
fi

# ---- 2. frontend (frontend/public/dist) -----------------------------------
if [ "$DO_FRONTEND" = "1" ]; then
  step "Building console frontend (yarn build)"
  ( cd "$REPO_ROOT/frontend" && yarn build )
else
  log "Skipping frontend build (--skip-frontend)."
fi

# ---- 3. plugin (dist/) -----------------------------------------------------
if [ "$DO_PLUGIN" = "1" ]; then
  step "Building networking-console-plugin (npm run build, production)"
  ( cd "$PLUGIN_DIR" && npm run build )
else
  log "Skipping plugin build (--skip-plugin)."
fi

# ---- 4. deploy -------------------------------------------------------------
if [ "$DO_DEPLOY" = "1" ]; then
  step "Deploying to minikube"
  "$SCRIPT_DIR/deploy.sh"
else
  log "Skipping deploy (--skip-deploy). Built artifacts are ready."
fi

log "All done in ${SECONDS}s."
