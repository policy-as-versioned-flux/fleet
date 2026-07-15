#!/usr/bin/env bash
# Issue 10: a second, independent cluster profile from the same fleet repo --
# `>=2.0.0` only, proving per-cluster narrowing (see clusters/cluster2/). Same
# shape as ./up.sh, deliberately minimal (no monitoring/crossplane/apps --
# those are cluster-agnostic concerns already proven once on cluster1).
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER=cluster2

echo "== 1. KiND cluster =="
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

echo "== 2. Flux Operator =="
helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version 0.55.0 --namespace flux-system --create-namespace --wait --timeout 3m >/dev/null

echo "== 3. FluxInstance (pinned Flux 2.9.2, upstream-alpine) =="
kubectl apply -f flux-instance.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=5m

echo "== 4. Self-referential bootstrap: Flux syncs this repo, installing Kyverno from git =="
kubectl apply -f clusters/cluster2/bootstrap.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready gitrepository/fleet --timeout=2m
kubectl -n flux-system wait --for=condition=Ready kustomization/kyverno --timeout=5m

echo "== 5. Policy versions (>=2.0.0 only) =="
kubectl apply -f clusters/cluster2/policy-versions.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready resourceset/policy-versions --timeout=1m
kubectl -n flux-system wait --for=condition=Ready \
  kustomization/policy-2.0.0-require-department-label \
  kustomization/policy-2.0.0-require-known-department-label \
  kustomization/policy-2.2.0-require-department-label \
  kustomization/policy-2.2.0-require-known-department-label \
  kustomization/policy-2.2.0-require-owner-annotation \
  --timeout=3m
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true validatingpolicy/orphan-guard --timeout=1m

echo "== OK: KiND cluster '$CLUSTER' has Flux Operator + Kyverno + 2 coexisting policy versions (>=2.0.0) + orphan guard =="
kubectl get validatingpolicy
