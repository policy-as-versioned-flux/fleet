#!/usr/bin/env bash
# Runnable check for issue 18's claims, against whatever this cluster
# currently has live (run ./up.sh first, then merge/reconcile the
# crossplane* Kustomizations -- see infrastructure/crossplane*/).
set -euo pipefail

echo "== crossplane, crossplane-providers, crossplane-sample are all Ready =="
for k in crossplane crossplane-providers crossplane-sample; do
  kubectl wait --for=condition=Ready "kustomization/$k" -n flux-system --timeout=5m
done
echo "OK: all three Ready -- crossplane-sample being Ready proves the ordering held, since"
echo "    applying its Instance CR before the CRD existed fails outright (confirmed at"
echo "    issue-18 dev time: 'no matches for kind \"Instance\" ... ensure CRDs are installed first')"

echo "== provider-family CRDs reached Established =="
kubectl wait --for=condition=Established crd/instances.rds.aws.m.upbound.io --timeout=10s
kubectl wait --for=condition=Established crd/bucketserversideencryptionconfigurations.s3.aws.m.upbound.io --timeout=10s
echo "OK"

echo "== sample RDS CR applied and sits unreconciled (no ProviderConfig, no auth) =="
kubectl get instance.rds.aws.m.upbound.io sample-unreconciled -n default >/dev/null
synced=$(kubectl get instance.rds.aws.m.upbound.io sample-unreconciled -n default \
  -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "")
if [ "$synced" = "True" ]; then
  echo "FAIL: sample CR reports Synced=True -- it should have nothing to reconcile against"
  exit 1
fi
echo "OK: sample CR exists, Synced != True (no ProviderConfig referenced resolves) -- sits unreconciled as designed"
