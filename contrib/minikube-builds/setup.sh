#!/usr/bin/env bash
#
# One-command setup for REAL, working container builds on minikube, driven from
# the OpenShift console UI.
#
#   ./contrib/minikube-builds/setup.sh
#
# WHAT THIS GIVES YOU
# -------------------
# The console's classic "Builds" (build.openshift.io) "Start Build" button POSTs
# a BuildRequest to the buildconfigs/{name}/instantiate SUBRESOURCE, which only
# the OpenShift aggregated apiserver can serve. On plain minikube there is no
# controller/registry behind it, so classic builds can never actually run.
#
# Instead we use Shipwright (shipwright.io), a Kubernetes-native build system
# that runs on vanilla minikube via Tekton. The console ships a static
# @console/shipwright-plugin, so once the shipwright.io/v1beta1 API is served the
# SHIPWRIGHT_BUILD feature flag flips on and a real Builds UI appears. Clicking
# "Start" on a Build creates a BuildRun that clones the source, builds the image
# with buildah, and PUSHES it to the in-cluster registry.
#
# This script installs (idempotently):
#   1. A lightweight in-cluster registry            (00-registry.yaml)
#   2. Tekton Pipelines            (Shipwright's execution engine)
#   3. Shipwright Build            (server-side apply; CRDs exceed the 256KB
#                                   client-side last-applied annotation limit)
#   4. Shipwright sample ClusterBuildStrategies (buildah, kaniko, s2i, ...)
#   5. Two workarounds for a limitation of the upstream release on a cluster
#      with no cert-manager (see WEBHOOK below)
#   6. A sample Build "sample-go-build" in namespace default  (10-sample-build.yaml)
#
# WEBHOOK / cert workaround
# -------------------------
# Shipwright's webhook deployment serves ONLY CRD conversion (v1alpha1<->v1beta1)
# and needs a TLS serving cert. The upstream release expects an operator or
# cert-manager to mint it; on a bare cluster nothing does, so the webhook pod
# stays stuck (missing secret) and any conversion call would fail. Since the
# storage version is v1beta1 and the console + this script use v1beta1
# exclusively, no conversion is ever needed. So we:
#   * set spec.conversion.strategy=None on all four shipwright CRDs, and
#   * scale the webhook deployment to 0.
# (Shipwright v0.20.x uses NO validating/mutating admission webhooks, so creates
#  are unaffected.)
#
# Pinned versions (bump here if you want newer):
TEKTON_VERSION="${TEKTON_VERSION:-v1.6.0}"
SHIPWRIGHT_VERSION="${SHIPWRIGHT_VERSION:-v0.20.12}"

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;36m[minikube-builds]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[minikube-builds] ERROR:\033[0m %s\n' "$*" >&2; }

if ! kubectl cluster-info >/dev/null 2>&1; then
  err "kubectl cannot reach a cluster. Is minikube running?  minikube start"
  exit 1
fi

# ---- 1. registry -----------------------------------------------------------
log "Applying in-cluster registry..."
kubectl apply -f "$SCRIPT_DIR/00-registry.yaml"
log "Waiting for registry to be ready..."
kubectl -n registry rollout status deploy/registry --timeout=180s

# ---- 2. Tekton Pipelines ---------------------------------------------------
log "Installing Tekton Pipelines $TEKTON_VERSION..."
kubectl apply --server-side --force-conflicts \
  -f "https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml"
log "Waiting for Tekton controller..."
kubectl -n tekton-pipelines rollout status deploy/tekton-pipelines-controller --timeout=300s

# ---- 3. Shipwright Build ---------------------------------------------------
# Server-side apply: the shipwright CRDs are larger than the 262144-byte
# kubectl.kubernetes.io/last-applied-configuration annotation limit.
log "Installing Shipwright Build $SHIPWRIGHT_VERSION..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/shipwright-io/build/releases/download/${SHIPWRIGHT_VERSION}/release.yaml"

log "Waiting for shipwright.io CRDs to be Established..."
for c in builds buildruns buildstrategies clusterbuildstrategies; do
  kubectl wait --for=condition=Established "crd/${c}.shipwright.io" --timeout=120s
done

# ---- 4. sample build strategies -------------------------------------------
log "Installing Shipwright sample ClusterBuildStrategies..."
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/shipwright-io/build/releases/download/${SHIPWRIGHT_VERSION}/sample-strategies.yaml"

# ---- 5. webhook / conversion workaround -----------------------------------
log "Disabling CRD conversion (webhook has no cert on a bare cluster)..."
for c in builds buildruns buildstrategies clusterbuildstrategies; do
  kubectl patch "crd/${c}.shipwright.io" --type=merge \
    -p '{"spec":{"conversion":{"strategy":"None","webhook":null}}}'
done

log "Scaling the (unusable) shipwright webhook to 0..."
kubectl -n shipwright-build scale deploy/shipwright-build-webhook --replicas=0

log "Waiting for shipwright controller..."
kubectl -n shipwright-build rollout status deploy/shipwright-build-controller --timeout=300s

# ---- 6. sample Build -------------------------------------------------------
log "Applying sample Build 'sample-go-build' (namespace default)..."
kubectl apply -f "$SCRIPT_DIR/10-sample-build.yaml"

cat <<EOF

$(log "Done.")

Try it from the console UI:
  Builds  ->  (Shipwright) Builds  ->  sample-go-build  ->  Actions -> Start
A BuildRun runs and pushes to:
  registry.registry.svc.cluster.local:5000/sample-go:latest

Or from the CLI:
  kubectl create -n default -f - <<'YAML'
  apiVersion: shipwright.io/v1beta1
  kind: BuildRun
  metadata: { generateName: sample-go-build- }
  spec: { build: { name: sample-go-build } }
  YAML

Watch it:
  kubectl -n default get buildruns.shipwright.io -w

Verify the pushed image (NOTE: use fully-qualified names — 'builds'/'build'
collides with the classic build.openshift.io CRD if that is also installed):
  kubectl -n registry exec deploy/registry -- wget -qO- http://localhost:5000/v2/_catalog
  kubectl -n registry exec deploy/registry -- wget -qO- http://localhost:5000/v2/sample-go/tags/list
EOF
