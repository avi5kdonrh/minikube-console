// Self-contained module, INTENTIONALLY separate from the console's go.mod so it
// does not touch the repo's vendor tree. Deps are resolved inside the Docker
// builder (GOFLAGS=-mod=mod), not vendored here.
module pullsecret-webhook

go 1.23

require (
	k8s.io/api v0.31.3
	k8s.io/apimachinery v0.31.3
	k8s.io/client-go v0.31.3
	k8s.io/klog/v2 v2.130.1
)
