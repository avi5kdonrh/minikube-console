#!/usr/bin/env bash
#
# Associate ONE image pull secret with EVERY ServiceAccount in the cluster —
# every existing SA and every future one — plus replicate the secret into every
# namespace (imagePullSecrets can only reference a same-namespace Secret).
#
#   ./contrib/minikube-pullsecret/deploy.sh
#
# How (idempotent):
#   1. Generates a self-signed CA + serving cert for the webhook Service.
#   2. Builds pullsecret-webhook:minikube into minikube's runtime (no registry).
#   3. Applies manifests.yaml (ns, SA, RBAC, Deployment, Service) + the TLS Secret.
#   4. Creates a MutatingWebhookConfiguration (failurePolicy=Ignore) that injects
#      the pull secret into NEW ServiceAccounts on CREATE — instant coverage.
#   5. The in-pod reconciler backfills existing SAs and replicates the secret into
#      every namespace every RECONCILE_INTERVAL (30s), so "old and new" are both
#      covered even if the webhook is momentarily down.
#
# Point it at a different pull secret with:
#   SOURCE_NAMESPACE=olm SOURCE_SECRET=1979710-adongre-pull-secret ./deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${MINIKUBE_PROFILE:-minikube}"
NS="pullsecret-system"
SVC="pullsecret-webhook"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-olm}"
SOURCE_SECRET="${SOURCE_SECRET:-1979710-adongre-pull-secret}"

log() { printf '\033[1;35m[pullsecret]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[pullsecret] ERROR:\033[0m %s\n' "$*" >&2; }

# ---- preflight -------------------------------------------------------------
command -v openssl >/dev/null || { err "openssl is required"; exit 1; }
minikube -p "$PROFILE" status >/dev/null 2>&1 || { err "minikube profile '$PROFILE' is not running"; exit 1; }
if ! kubectl -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" >/dev/null 2>&1; then
  err "source secret $SOURCE_NAMESPACE/$SOURCE_SECRET not found. Set SOURCE_NAMESPACE / SOURCE_SECRET."
  exit 1
fi

TMP=""; cleanup() { [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# ---- 1. build the webhook image into minikube ------------------------------
log "Building ${SVC}:minikube into minikube's runtime..."
minikube -p "$PROFILE" image build -t "${SVC}:minikube" "$SCRIPT_DIR"

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

# Inject the chosen source secret into the Deployment env, then apply.
sed -e "s|value: \"olm\"|value: \"${SOURCE_NAMESPACE}\"|" \
    -e "s|value: \"1979710-adongre-pull-secret\"|value: \"${SOURCE_SECRET}\"|" \
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
  name: pullsecret-webhook
webhooks:
  - name: pullsecret.${NS}.svc
    admissionReviewVersions: ["v1"]
    # The /mutate endpoint only returns a JSONPatch; it makes no external writes.
    sideEffects: None
    # NEVER block ServiceAccount creation if the webhook is down. Coverage for
    # anything missed here is guaranteed by the in-pod reconciler.
    failurePolicy: Ignore
    matchPolicy: Equivalent
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["serviceaccounts"]
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

$(log "Done. Pull secret ${SOURCE_NAMESPACE}/${SOURCE_SECRET} is now associated with all ServiceAccounts.")

The reconciler runs every 30s. Give it a moment, then verify:

  # secret replicated into (nearly) every namespace:
  kubectl get secret ${SOURCE_SECRET} -A

  # every SA carries the imagePullSecret (spot-check a few namespaces):
  kubectl get sa -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PULL:.imagePullSecrets[*].name'

  # webhook does new SAs instantly:
  kubectl create ns demo-pullsecret && kubectl -n demo-pullsecret create sa demo
  kubectl -n demo-pullsecret get sa demo -o jsonpath='{.imagePullSecrets}'; echo

  kubectl -n ${NS} logs deploy/${SVC} -f

Remove it all with:
  kubectl delete mutatingwebhookconfiguration pullsecret-webhook
  kubectl delete namespace ${NS}
  # (replicated secrets + SA edits remain; that's the intended state)
EOF
