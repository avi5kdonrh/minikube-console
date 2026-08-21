// routehost-webhook: gives every OpenShift Route a hostname on a plain
// Kubernetes cluster (e.g. minikube).
//
// On real OpenShift the openshift-apiserver auto-fills an empty Route
// .spec.host from the cluster ingress domain. On minikube only the
// ingress-router pod runs (no such admission), so operator-created Routes that
// don't let you set a host — e.g. Strimzi/AMQ Kafka bootstrap & broker routes —
// stay host-less and the router cannot serve them.
//
// This fills the gap with a deterministic host derived from the Route's name and
// namespace: "<name>.<namespace>.<BASE_DOMAIN>" (BASE_DOMAIN defaults to
// "minikube"). Deterministic (not random) so the value is STABLE across operator
// re-reconciliation — important because Strimzi reads .spec.host back into the
// Kafka advertised listener addresses and broker TLS cert SANs.
//
// Two cooperating parts, one binary:
//
//  1. Mutating admission webhook (/mutate) — on Route CREATE/UPDATE, if
//     .spec.host is empty it returns a JSONPatch setting it. Instant coverage.
//     failurePolicy=Ignore on the webhook config guarantees it can never block
//     Route creation.
//
//  2. Reconciler goroutine — every RECONCILE_INTERVAL it lists every Route in
//     the cluster and patches any with an empty host. This backfills Routes that
//     already existed before the webhook was installed, and repairs anything the
//     webhook missed while it was down.
//
// It only ever sets a host when one is MISSING; a Route that already has a host
// is never touched.
//
// Config (env):
//
//	BASE_DOMAIN        DNS suffix for generated hosts   (default: minikube)
//	RECONCILE_INTERVAL reconcile period                 (default: 30s)
//	TLS_CERT_FILE      serving cert                      (default: /tls/tls.crt)
//	TLS_KEY_FILE       serving key                       (default: /tls/tls.key)
//	LISTEN_ADDR        https listen address             (default: :8443)
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var (
	baseDomain = env("BASE_DOMAIN", "minikube")
	routeGVR   = schema.GroupVersionResource{Group: "route.openshift.io", Version: "v1", Resource: "routes"}
)

func main() {
	klog.InitFlags(nil)
	flag.Parse() // honor -v for klog verbosity

	cfg, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("in-cluster config: %v", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("dynamic client: %v", err)
	}

	interval, err := time.ParseDuration(env("RECONCILE_INTERVAL", "30s"))
	if err != nil {
		klog.Fatalf("bad RECONCILE_INTERVAL: %v", err)
	}

	// Reconciler: backfill existing host-less Routes, forever.
	go func() {
		// Small delay so the API server / caches settle on startup.
		time.Sleep(2 * time.Second)
		for {
			reconcile(context.Background(), dyn)
			time.Sleep(interval)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutateHandler)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	addr := env("LISTEN_ADDR", ":8443")
	klog.Infof("routehost-webhook: baseDomain=%s, reconcile=%s, listening on %s", baseDomain, interval, addr)
	srv := &http.Server{Addr: addr, Handler: mux}
	if err := srv.ListenAndServeTLS(env("TLS_CERT_FILE", "/tls/tls.crt"), env("TLS_KEY_FILE", "/tls/tls.key")); err != nil {
		klog.Fatalf("serve: %v", err)
	}
}

// ---- admission webhook -----------------------------------------------------

func mutateHandler(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
		http.Error(w, "invalid AdmissionReview", http.StatusBadRequest)
		return
	}
	req := review.Request

	resp := &admissionv1.AdmissionResponse{UID: req.UID, Allowed: true}

	// Only the main "routes" resource; never a subresource like routes/status.
	if req.Resource.Resource == "routes" && req.SubResource == "" {
		var obj unstructured.Unstructured
		if err := json.Unmarshal(req.Object.Raw, &obj.Object); err == nil {
			host, _, _ := unstructured.NestedString(obj.Object, "spec", "host")
			name := obj.GetName()
			ns := obj.GetNamespace()
			if ns == "" {
				ns = req.Namespace
			}
			// name can be empty when the object uses generateName on CREATE
			// (assigned after mutation); the reconciler will catch those.
			if host == "" && name != "" {
				generated := hostFor(name, ns)
				resp.Patch = hostPatch(generated)
				pt := admissionv1.PatchTypeJSONPatch
				resp.PatchType = &pt
				klog.V(2).Infof("mutate: setting host %q on route %s/%s", generated, ns, name)
			}
		} else {
			klog.Warningf("mutate: could not decode Route: %v", err)
		}
	}

	out := admissionv1.AdmissionReview{TypeMeta: review.TypeMeta, Response: resp}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// ---- reconciler ------------------------------------------------------------

func reconcile(ctx context.Context, dyn dynamic.Interface) {
	list, err := dyn.Resource(routeGVR).Namespace(metav1.NamespaceAll).List(ctx, metav1.ListOptions{})
	if err != nil {
		// The route.openshift.io API may be absent; just try again next tick.
		if apierrors.IsNotFound(err) {
			klog.V(2).Infof("reconcile: route.openshift.io not served yet, skipping")
		} else {
			klog.Errorf("reconcile: list routes: %v", err)
		}
		return
	}

	var patched int
	for i := range list.Items {
		route := &list.Items[i]
		host, _, _ := unstructured.NestedString(route.Object, "spec", "host")
		if host != "" {
			continue
		}
		name := route.GetName()
		ns := route.GetNamespace()
		generated := hostFor(name, ns)
		if _, err := dyn.Resource(routeGVR).Namespace(ns).Patch(
			ctx, name, types.JSONPatchType, hostPatch(generated), metav1.PatchOptions{},
		); err != nil {
			klog.Warningf("reconcile: patch %s/%s: %v", ns, name, err)
			continue
		}
		klog.V(2).Infof("reconcile: set host %q on route %s/%s", generated, ns, name)
		patched++
	}
	klog.V(2).Infof("reconcile: %d routes, %d host-less routes fixed", len(list.Items), patched)
}

// ---- helpers ---------------------------------------------------------------

// hostFor builds a deterministic, DNS-safe host of the form
// "<name>.<namespace>.<baseDomain>". Because it depends only on the Route's
// identity, re-running it always yields the same host (no operator churn).
func hostFor(name, ns string) string {
	return clampLabel(sanitizeLabel(name)) + "." + clampLabel(sanitizeLabel(ns)) + "." + baseDomain
}

// sanitizeLabel lowercases and reduces s to the RFC1123 DNS-label charset
// (a-z, 0-9, '-'), trimming leading/trailing dashes. Route names and namespaces
// are already valid labels, so this is normally a no-op guard.
func sanitizeLabel(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		out = "x"
	}
	return out
}

// clampLabel keeps a DNS label within the 63-char limit, preserving uniqueness
// by appending a short hash of the original when it must be truncated.
func clampLabel(s string) string {
	const max = 63
	if len(s) <= max {
		return s
	}
	sum := sha256.Sum256([]byte(s))
	h := hex.EncodeToString(sum[:])[:8]
	return strings.Trim(s[:max-9], "-") + "-" + h
}

// hostPatch returns a JSONPatch that sets .spec.host. "add" replaces the value
// when the key is present-but-empty and inserts it when absent; .spec always
// exists on a Route, so the parent path is guaranteed.
func hostPatch(host string) []byte {
	ops := []map[string]interface{}{{"op": "add", "path": "/spec/host", "value": host}}
	b, _ := json.Marshal(ops)
	return b
}
