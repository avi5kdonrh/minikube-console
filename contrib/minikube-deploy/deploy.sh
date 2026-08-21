#!/usr/bin/env bash
#
# Containerize the OpenShift console + networking-console-plugin and deploy them
# INTO minikube (Deployment + Service + Route), running the console in-cluster.
#
#   ./contrib/minikube-deploy/deploy.sh
#
# What it does (idempotent):
#   1. Builds two images directly into minikube's container runtime (no registry):
#        console:minikube                    (bridge + frontend/public/dist)
#        networking-console-plugin:minikube  (plugin dist served by nginx)
#      It uses the PREBUILT artifacts (bin/bridge, frontend/public/dist, and the
#      plugin's dist/). Build them first if missing:
#        ./build-backend.sh && ./build-frontend.sh      (this repo)
#        (cd <plugin> && npm ci && npm run build)        (plugin repo)
#   2. Applies contrib/minikube-deploy/console.yaml (ns, SA, RBAC, long-lived SA
#      token, both Deployments+Services, and a Route).
#   3. Sets the Route host to console.<minikube-ip>.nip.io and prints access URLs.
#
# Optional env vars:
#   NETWORKING_PLUGIN_DIR=/path/to/networking-console-plugin  (default: sibling dir)
#   MINIKUBE_PROFILE=minikube
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_DIR="${NETWORKING_PLUGIN_DIR:-$(cd "$REPO_ROOT/.." && pwd)/networking-console-plugin}"
PROFILE="${MINIKUBE_PROFILE:-minikube}"

log() { printf '\033[1;36m[minikube-deploy]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[minikube-deploy] ERROR:\033[0m %s\n' "$*" >&2; }

# ---- preflight -------------------------------------------------------------
[ -x "$REPO_ROOT/bin/bridge" ] || { err "bin/bridge not found. Build it: ./build-backend.sh"; exit 1; }
[ -f "$REPO_ROOT/frontend/public/dist/index.html" ] || { err "frontend/public/dist not built. Run ./build-frontend.sh"; exit 1; }
[ -f "$PLUGIN_DIR/dist/plugin-manifest.json" ] || { err "plugin dist not found at $PLUGIN_DIR/dist. Build it: (cd $PLUGIN_DIR && npm ci && npm run build)"; exit 1; }
minikube -p "$PROFILE" status >/dev/null 2>&1 || { err "minikube profile '$PROFILE' is not running. minikube start"; exit 1; }

STAGE=""; PSTAGE=""
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; [ -n "$PSTAGE" ] && rm -rf "$PSTAGE"; }
trap cleanup EXIT

# ---- 1. build the console image into minikube ------------------------------
log "Staging console artifacts..."
STAGE="$(mktemp -d)"
cp "$REPO_ROOT/bin/bridge" "$STAGE/bridge"
cp -r "$REPO_ROOT/frontend/public/dist" "$STAGE/static"
cp "$SCRIPT_DIR/Dockerfile.console" "$STAGE/Dockerfile"
log "Building console:minikube (this ships ~320MB of context to the minikube daemon)..."
minikube -p "$PROFILE" image build -t console:minikube "$STAGE"

# ---- 2. build the plugin image into minikube -------------------------------
log "Staging networking-console-plugin artifacts..."
PSTAGE="$(mktemp -d)"
cp -r "$PLUGIN_DIR/dist" "$PSTAGE/dist"
cp "$SCRIPT_DIR/Dockerfile.plugin" "$PSTAGE/Dockerfile"
log "Building networking-console-plugin:minikube..."
minikube -p "$PROFILE" image build -t networking-console-plugin:minikube "$PSTAGE"

# ---- 3. apply manifests ----------------------------------------------------
log "Applying manifests..."
kubectl apply -f "$SCRIPT_DIR/console.yaml"

# Restart to pick up freshly-built images (same tag -> no auto-redeploy).
log "Restarting deployments to pick up rebuilt images..."
kubectl -n console rollout restart deploy/console deploy/networking-console-plugin

# Point the Route at a resolvable host for display (no router actually serves it).
MK_IP="$(minikube -p "$PROFILE" ip)"
kubectl -n console patch route console --type=merge \
  -p "{\"spec\":{\"host\":\"console.${MK_IP}.nip.io\"}}" >/dev/null

log "Waiting for rollouts..."
kubectl -n console rollout status deploy/networking-console-plugin --timeout=180s
kubectl -n console rollout status deploy/console --timeout=180s

# ---- done ------------------------------------------------------------------
NODEPORT="$(kubectl -n console get svc console -o jsonpath='{.spec.ports[0].nodePort}')"
# Report whether an ingress-router is present (it serves the Route).
HAS_ROUTER="$(kubectl get pods -n openshift-ingress -l 'ingresscontroller.operator.openshift.io/deployment-ingresscontroller' 2>/dev/null | grep -c Running || true)"
[ "$HAS_ROUTER" = "0" ] && HAS_ROUTER="$(kubectl get pods -A 2>/dev/null | grep -icE 'router' || true)"

cat <<EOF

$(log "Done.")

Console via Route (if this cluster runs an OpenShift ingress-router):
  http://console.${MK_IP}.nip.io

Console via NodePort (always works):
  http://${MK_IP}:${NODEPORT}
  (or:  minikube -p ${PROFILE} service console -n console --url )

Handy:
  kubectl -n console get pods,svc,route
  kubectl -n console logs deploy/console -f
EOF
