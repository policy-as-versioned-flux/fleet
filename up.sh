#!/usr/bin/env bash
# One documented command sequence: laptop -> KiND cluster with Flux Operator
# (FluxInstance, ADR-0005), Kyverno engine (>=1.18, ADR-0003), three
# coexisting policy versions + the orphan guard via one ResourceSet (issues
# 08, 09), and three consumer apps, all reconciling live via Flux GitOps.
# Idempotent -- safe to re-run. Readiness is gated throughout by native
# `kubectl wait` on Ready conditions, never a jsonpath polling loop.
#
# Prereqs: docker, kind, kubectl, helm. ~3-5 min from cold (varies with image pull speed).
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER=cluster1

echo "== 1. KiND cluster =="
kind get clusters 2>/dev/null | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --wait 120s

echo "== 2. Flux Operator =="
helm upgrade --install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version 0.55.0 --namespace flux-system --create-namespace --wait --timeout 3m >/dev/null

echo "== 3. FluxInstance (pinned Flux 2.9.2, upstream-alpine) =="
kubectl apply -f flux-instance.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready fluxinstance/flux --timeout=5m

echo "== 4. Self-referential bootstrap: Flux syncs this repo, installing Kyverno from git =="
kubectl apply -f clusters/cluster1/bootstrap.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready gitrepository/fleet --timeout=2m
kubectl -n flux-system wait --for=condition=Ready kustomization/kyverno --timeout=5m

echo "== 5. Policy versions (ResourceSet: range over the {version,commit} array) + three consumer apps =="
kubectl apply -f clusters/cluster1/policy-versions.yaml >/dev/null
kubectl apply -f clusters/cluster1/apps.yaml >/dev/null
kubectl -n flux-system wait --for=condition=Ready resourceset/policy-versions --timeout=1m
kubectl -n flux-system wait --for=condition=Ready \
  kustomization/policy-1.0.0-require-department-label \
  kustomization/policy-1.0.0-require-known-department-label \
  kustomization/policy-2.0.0-require-department-label \
  kustomization/policy-2.0.0-require-known-department-label \
  kustomization/policy-2.1.1-require-department-label \
  kustomization/policy-2.1.1-require-known-department-label \
  kustomization/policy-2.1.1-require-owner-annotation \
  --timeout=3m
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true validatingpolicy/orphan-guard --timeout=1m
kubectl -n flux-system wait --for=condition=Ready kustomization/apps --timeout=2m

echo "== OK: KiND cluster '$CLUSTER' has Flux Operator + Kyverno + 3 coexisting policy versions + orphan guard + 3 apps healthy =="
kubectl -n kyverno get deploy
kubectl get validatingpolicy
kubectl get pods -l 'mycompany.com/policy-version' --show-labels
