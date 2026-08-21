# shellcheck shell=bash
#
# Environment for running the OpenShift console (bridge) against a local
# minikube cluster.
#
# Unlike contrib/environment.sh, this does NOT rely on a legacy
# ServiceAccount token secret (removed in Kubernetes 1.24+). Instead it mints
# a short-lived token with `kubectl create token` for a dedicated `console`
# ServiceAccount that is bound to cluster-admin.
#
# One-time setup (already done, safe to re-run):
#   kubectl create serviceaccount console -n kube-system
#   kubectl create clusterrolebinding console-admin \
#     --clusterrole=cluster-admin --serviceaccount=kube-system:console
#   # Namespace the console user-settings feature writes into (the OpenShift
#   # console operator creates this on a real cluster; minikube needs it manually):
#   kubectl create namespace openshift-console-user-settings
#
# Usage:
#   source ./contrib/minikube-environment.sh
#   ./bin/bridge
#
# Then open http://localhost:9000. Tokens are time-limited; re-source this
# script to refresh the token when it expires.

BRIDGE_USER_AUTH="disabled"
export BRIDGE_USER_AUTH

BRIDGE_K8S_MODE="off-cluster"
export BRIDGE_K8S_MODE

BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
export BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT

BRIDGE_K8S_MODE_OFF_CLUSTER_SKIP_VERIFY_TLS=true
export BRIDGE_K8S_MODE_OFF_CLUSTER_SKIP_VERIFY_TLS

# Trust the cluster CA via Go's trust store (SSL_CERT_FILE).
#
# The skip-verify flag above only covers the k8s proxy and the internal client's
# own transport. It does NOT reach the "anonymous" internal round-tripper built
# in cmd/bridge/main.go with rest.AnonymousClientConfig(), which the user-settings
# handler uses (SelfSubjectReview -> ConfigMap). That client verifies against the
# system trust store, so a self-signed minikube API cert fails with
# "x509: certificate signed by unknown authority". Adding the cluster CA to a
# bundle here makes that verification succeed.
_ssl_system_bundle=""
for _f in /etc/ssl/certs/ca-bundle.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
  [ -r "$_f" ] && { _ssl_system_bundle="$_f"; break; }
done
_ssl_cluster_ca_file=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}')
_ssl_cluster_ca_data=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
_ssl_bundle="${TMPDIR:-/tmp}/minikube-console-ca-bundle.crt"
{
  [ -n "$_ssl_system_bundle" ] && cat "$_ssl_system_bundle"
  if [ -n "$_ssl_cluster_ca_data" ]; then
    echo "$_ssl_cluster_ca_data" | base64 --decode
  elif [ -n "$_ssl_cluster_ca_file" ]; then
    cat "$_ssl_cluster_ca_file"
  fi
} > "$_ssl_bundle"
SSL_CERT_FILE="$_ssl_bundle"
export SSL_CERT_FILE

BRIDGE_K8S_AUTH_BEARER_TOKEN=$(kubectl create token console -n kube-system --duration=24h)
export BRIDGE_K8S_AUTH_BEARER_TOKEN

# Dynamic plugins to load. The networking-console-plugin restores the
# Networking nav section (Services, Ingresses, NetworkPolicies, ...).
# Run its dev server first from the plugin repo: `npm run start` (serves :9001).
# Add more comma-separated "name=url" pairs here to load additional plugins.
BRIDGE_PLUGINS="networking-console-plugin=http://localhost:9001"
export BRIDGE_PLUGINS

echo "Using $BRIDGE_K8S_MODE_OFF_CLUSTER_ENDPOINT"
echo "Token minted for kube-system:console (valid 24h)"
echo "Plugins: $BRIDGE_PLUGINS"
echo "Trusting cluster CA via SSL_CERT_FILE=$SSL_CERT_FILE"
