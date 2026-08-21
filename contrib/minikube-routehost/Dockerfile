# Multi-stage build for the routehost-webhook. The builder resolves modules from
# the internet (GOFLAGS=-mod=mod writes go.sum in-container) so nothing is
# vendored in the repo. Static binary -> distroless.
#
# Built into minikube's runtime by deploy.sh:  minikube image build -t routehost-webhook:minikube .
FROM golang:1.23-alpine AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-mod=mod GOTOOLCHAIN=auto
COPY go.mod ./
COPY main.go ./
RUN go build -trimpath -ldflags="-s -w" -o /routehost-webhook .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /routehost-webhook /routehost-webhook
USER 65532:65532
ENTRYPOINT ["/routehost-webhook"]
