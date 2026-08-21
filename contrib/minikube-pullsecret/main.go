// pullsecret-webhook: associates a single image pull secret with EVERY
// ServiceAccount in the cluster, old and new.
//
// Two cooperating parts, one binary:
//
//  1. Mutating admission webhook (/mutate) — on ServiceAccount CREATE it returns
//     a JSONPatch adding the pull secret to .imagePullSecrets. Instant coverage
//     for brand-new ServiceAccounts. failurePolicy=Ignore on the webhook config
//     guarantees it can never block SA creation.
//
//  2. Reconciler goroutine — every RECONCILE_INTERVAL it (a) replicates the
//     source pull secret into every namespace (a SA's imagePullSecrets can only
//     reference a Secret in its OWN namespace), and (b) patches every existing
//     ServiceAccount that is missing the reference. This backfills old SAs, seeds
//     new namespaces, and repairs any drift or webhook misses.
//
// Config (env):
//
//	SOURCE_NAMESPACE   namespace holding the source secret   (default: olm)
//	SOURCE_SECRET      name of the source pull secret        (default: 1979710-adongre-pull-secret)
//	RECONCILE_INTERVAL reconcile period                      (default: 30s)
//	TLS_CERT_FILE      serving cert                          (default: /tls/tls.crt)
//	TLS_KEY_FILE       serving key                           (default: /tls/tls.key)
//	LISTEN_ADDR        https listen address                  (default: :8443)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"io"
	"net/http"
	"os"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
)

const managedByLabel = "app.kubernetes.io/managed-by"
const managedByValue = "pullsecret-webhook"

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

var (
	srcNamespace = env("SOURCE_NAMESPACE", "olm")
	srcSecret    = env("SOURCE_SECRET", "1979710-adongre-pull-secret")
)

func main() {
	klog.InitFlags(nil)
	flag.Parse() // honor -v for klog verbosity

	cfg, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("in-cluster config: %v", err)
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("clientset: %v", err)
	}

	interval, err := time.ParseDuration(env("RECONCILE_INTERVAL", "30s"))
	if err != nil {
		klog.Fatalf("bad RECONCILE_INTERVAL: %v", err)
	}

	// Reconciler: replicate the secret + backfill all SAs, forever.
	go func() {
		// Small delay so the API server / caches settle on startup.
		time.Sleep(2 * time.Second)
		for {
			reconcile(context.Background(), cs)
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
	klog.Infof("pullsecret-webhook: source=%s/%s, reconcile=%s, listening on %s",
		srcNamespace, srcSecret, interval, addr)
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

	if req.Resource.Resource == "serviceaccounts" {
		var sa corev1.ServiceAccount
		if err := json.Unmarshal(req.Object.Raw, &sa); err == nil {
			if !hasSecret(sa.ImagePullSecrets, srcSecret) {
				var ops []map[string]interface{}
				if len(sa.ImagePullSecrets) == 0 {
					ops = []map[string]interface{}{{
						"op":    "add",
						"path":  "/imagePullSecrets",
						"value": []map[string]string{{"name": srcSecret}},
					}}
				} else {
					ops = []map[string]interface{}{{
						"op":    "add",
						"path":  "/imagePullSecrets/-",
						"value": map[string]string{"name": srcSecret},
					}}
				}
				patch, _ := json.Marshal(ops)
				pt := admissionv1.PatchTypeJSONPatch
				resp.Patch = patch
				resp.PatchType = &pt
				klog.V(2).Infof("mutate: injecting pull secret into %s/%s", req.Namespace, sa.Name)
			}
		} else {
			klog.Warningf("mutate: could not decode ServiceAccount: %v", err)
		}
	}

	out := admissionv1.AdmissionReview{TypeMeta: review.TypeMeta, Response: resp}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

// ---- reconciler ------------------------------------------------------------

func reconcile(ctx context.Context, cs kubernetes.Interface) {
	src, err := cs.CoreV1().Secrets(srcNamespace).Get(ctx, srcSecret, metav1.GetOptions{})
	if err != nil {
		klog.Errorf("reconcile: cannot read source secret %s/%s: %v", srcNamespace, srcSecret, err)
		return
	}

	nsList, err := cs.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		klog.Errorf("reconcile: list namespaces: %v", err)
		return
	}

	var secretsEnsured, sasPatched int
	for i := range nsList.Items {
		ns := &nsList.Items[i]
		if ns.Status.Phase == corev1.NamespaceTerminating {
			continue
		}
		if ensureSecret(ctx, cs, ns.Name, src) {
			secretsEnsured++
		}
		sasPatched += ensureServiceAccounts(ctx, cs, ns.Name)
	}
	klog.V(2).Infof("reconcile: %d namespaces, %d secret copies written, %d service accounts patched",
		len(nsList.Items), secretsEnsured, sasPatched)
}

// ensureSecret makes sure a copy of the source pull secret exists (and is
// current) in namespace ns. Returns true if it created or updated the copy.
func ensureSecret(ctx context.Context, cs kubernetes.Interface, ns string, src *corev1.Secret) bool {
	if ns == srcNamespace {
		return false // the source lives here already
	}
	existing, err := cs.CoreV1().Secrets(ns).Get(ctx, src.Name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		copy := &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{
				Name:      src.Name,
				Namespace: ns,
				Labels:    map[string]string{managedByLabel: managedByValue},
				Annotations: map[string]string{
					"pullsecret-webhook/source": srcNamespace + "/" + src.Name,
				},
			},
			Type: src.Type,
			Data: src.Data,
		}
		if _, err := cs.CoreV1().Secrets(ns).Create(ctx, copy, metav1.CreateOptions{}); err != nil && !apierrors.IsAlreadyExists(err) {
			klog.Warningf("ensureSecret: create %s/%s: %v", ns, src.Name, err)
			return false
		}
		return true
	}
	if err != nil {
		klog.Warningf("ensureSecret: get %s/%s: %v", ns, src.Name, err)
		return false
	}
	// Only manage (update) copies we created; never clobber a pre-existing secret.
	if existing.Labels[managedByLabel] != managedByValue {
		return false
	}
	if existing.Type == src.Type && dataEqual(existing.Data, src.Data) {
		return false
	}
	existing.Type = src.Type
	existing.Data = src.Data
	if _, err := cs.CoreV1().Secrets(ns).Update(ctx, existing, metav1.UpdateOptions{}); err != nil {
		klog.Warningf("ensureSecret: update %s/%s: %v", ns, src.Name, err)
		return false
	}
	return true
}

// ensureServiceAccounts patches every SA in ns that is missing the pull secret.
// Returns the number patched.
func ensureServiceAccounts(ctx context.Context, cs kubernetes.Interface, ns string) int {
	saList, err := cs.CoreV1().ServiceAccounts(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		klog.Warningf("ensureServiceAccounts: list %s: %v", ns, err)
		return 0
	}
	patched := 0
	for i := range saList.Items {
		sa := &saList.Items[i]
		if hasSecret(sa.ImagePullSecrets, srcSecret) {
			continue
		}
		newList := append([]corev1.LocalObjectReference{}, sa.ImagePullSecrets...)
		newList = append(newList, corev1.LocalObjectReference{Name: srcSecret})
		// Merge patch limited to imagePullSecrets to avoid conflicts on token/secret churn.
		payload, _ := json.Marshal(map[string]interface{}{"imagePullSecrets": newList})
		if _, err := cs.CoreV1().ServiceAccounts(ns).Patch(ctx, sa.Name, types.MergePatchType, payload, metav1.PatchOptions{}); err != nil {
			klog.Warningf("ensureServiceAccounts: patch %s/%s: %v", ns, sa.Name, err)
			continue
		}
		patched++
	}
	return patched
}

// ---- helpers ---------------------------------------------------------------

func hasSecret(refs []corev1.LocalObjectReference, name string) bool {
	for _, r := range refs {
		if r.Name == name {
			return true
		}
	}
	return false
}

func dataEqual(a, b map[string][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	for k, av := range a {
		bv, ok := b[k]
		if !ok || string(av) != string(bv) {
			return false
		}
	}
	return true
}
