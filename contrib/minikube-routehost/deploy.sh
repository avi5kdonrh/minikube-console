#!/usr/bin/env bash
#
# Give every OpenShift Route a hostname on minikube. Operator-created Routes that
# don't let you set a host (e.g. Strimzi/AMQ Kafka bootstrap & broker routes)
# come out with an empty .spec.host on a cluster without the openshift-apiserver,
# so the ingress-router can't serve them. This deploys a webhook + reconciler
# that sets a deterministic host "<name>.<namespace>.<BASE_DOMAIN>" on any Route
# that is missing one (never touching Routes that already have a host).
#
#   ./contrib/minikube-routehost/deploy.sh
#
# How (idempotent):
#   1. Generates a self-signed CA + serving cert for the webhook Service.
#   2. Builds routehost-webhook:minikube into minikube's runtime (no registry).
#   3. Applies manifests.yaml (ns, SA, RBAC, Deployment, Service) + the TLS Secret.
#   4. Creates a MutatingWebhookConfiguration (failurePolicy=Ignore) that sets the
#      host on NEW/updated Routes with an empty host — instant coverage.
#   5. The in-pod reconciler backfills existing host-less Routes every
#      RECONCILE_INTERVAL (30s), so pre-existing Routes are covered too.
#
# Point it at a different wildcard domain with:
#   BASE_DOMAIN=minikube ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${MINIKUBE_PROFILE:-minikube}"
NS="routehost-system"
SVC="routehost-webhook"
BASE_DOMAIN="${BASE_DOMAIN:-minikube}"

log() { printf '\033[1;34m[routehost]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[routehost] ERROR:\033[0m %s\n' "$*" >&2; }

# ---- preflight -------------------------------------------------------------
command -v openssl >/dev/null || { err "openssl is required"; exit 1; }
minikube -p "$PROFILE" status >/dev/null 2>&1 || { err "minikube profile '$PROFILE' is not running"; exit 1; }
if ! kubectl get crd routes.route.openshift.io >/dev/null 2>&1; then
  err "route.openshift.io is not served on this cluster; nothing to do."
  exit 1
fi

TMP=""; cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---- 1. build the webhook image into minikube ------------------------------
log "Building ${SVC}:minikube into minikube's runtime..."
minikube -p "$PROFILE" image build -t "${SVC}:minikube" "$SCRIPT_DIR"
# `minikube image build` exits 0 even when the build FAILED, so verify the image
# actually landed; otherwise the pod would end up in ImagePullBackOff.
if ! minikube -p "$PROFILE" image ls 2>/dev/null | grep -q "${SVC}:minikube"; then
  err "image ${SVC}:minikube was not built — check the build output above."
  exit 1
fi

# ---- 2. generate CA + serving cert -----------------------------------------
log "Generating serving certificate for ${SVC}.${NS}.svc..."
TMP="$(mktemp -d)"
DNS1="${SVC}.${NS}.svc"
DNS2="${SVC}.${NS}.svc.cluster.local"
cat > "$TMP/csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = dn
prompt = no
[dn]
CN = ${DNS1}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
DNS.1 = ${DNS1}
DNS.2 = ${DNS2}
EOF

openssl genrsa -out "$TMP/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$TMP/ca.key" -subj "/CN=${SVC}-ca" -days 3650 -out "$TMP/ca.crt" 2>/dev/null
openssl genrsa -out "$TMP/tls.key" 2048 2>/dev/null
openssl req -new -key "$TMP/tls.key" -out "$TMP/server.csr" -config "$TMP/csr.conf" 2>/dev/null
openssl x509 -req -in "$TMP/server.csr" -CA "$TMP/ca.crt" -CAkey "$TMP/ca.key" \
  -CAcreateserial -out "$TMP/tls.crt" -days 3650 -extensions v3_req -extfile "$TMP/csr.conf" 2>/dev/null

# ---- 3. apply manifests + TLS secret ---------------------------------------
log "Applying manifests..."
# Namespace first so the TLS secret + workload land in it.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret tls "${SVC}-tls" \
  --cert="$TMP/tls.crt" --key="$TMP/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Inject the chosen base domain into the Deployment env, then apply.
sed -e "s|value: \"minikube\"|value: \"${BASE_DOMAIN}\"|" \
    "$SCRIPT_DIR/manifests.yaml" | kubectl apply -f - >/dev/null

# Pick up a freshly-built image (same tag -> no auto-redeploy).
kubectl -n "$NS" rollout restart deploy/"$SVC" >/dev/null

# ---- 4. MutatingWebhookConfiguration with matching caBundle ----------------
log "Registering MutatingWebhookConfiguration..."
CABUNDLE="$(base64 -w0 "$TMP/ca.crt")"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: routehost-webhook
webhooks:
  - name: routehost.${NS}.svc
    admissionReviewVersions: ["v1"]
    # The /mutate endpoint only returns a JSONPatch; it makes no external writes.
    sideEffects: None
    # NEVER block Route creation if the webhook is down. Coverage for anything
    # missed here is guaranteed by the in-pod reconciler.
    failurePolicy: Ignore
    matchPolicy: Equivalent
    rules:
      - apiGroups: ["route.openshift.io"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["routes"]
        scope: "*"
    clientConfig:
      service:
        name: ${SVC}
        namespace: ${NS}
        path: /mutate
        port: 443
      caBundle: ${CABUNDLE}
EOF

# ---- 5. wait + report ------------------------------------------------------
log "Waiting for the webhook to become ready..."
kubectl -n "$NS" rollout status deploy/"$SVC" --timeout=180s

cat <<EOF

$(log "Done. Host-less Routes now get <name>.<namespace>.${BASE_DOMAIN}.")

The reconciler runs every 30s. Give it a moment, then verify:

  # every Route now has a host:
  kubectl get routes -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOST:.spec.host'

  # webhook does new Routes instantly:
  kubectl -n default create route passthrough demo --service=kubernetes --port=443 2>/dev/null || true
  kubectl -n default get route demo -o jsonpath='{.spec.host}'; echo

  kubectl -n ${NS} logs deploy/${SVC} -f

NOTE: your DNS must resolve *.${BASE_DOMAIN} (e.g. dnsmasq address=/${BASE_DOMAIN}/<minikube-ip>)
to the ingress IP for these hosts to be reachable.

Remove it all with:
  kubectl delete mutatingwebhookconfiguration routehost-webhook
  kubectl delete namespace ${NS}
  # (hosts already written onto Routes remain; that's the intended state)
EOF
