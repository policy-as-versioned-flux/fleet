#!/usr/bin/env bash
# Runnable check for issue 16's communicable claim, against whatever this
# cluster currently has live (run ./up.sh first, then merge/reconcile the
# notifications Kustomization -- see infrastructure/notifications/).
# Forces a reconcile of a real policy source and proves the resulting event
# reaches the in-cluster receiver within one reconcile, naming the revision.
set -euo pipefail

echo "== notifications Kustomization is Ready =="
kubectl wait --for=condition=Ready kustomization/notifications -n flux-system --timeout=60s
echo "OK"

before=$(kubectl logs deploy/revision-echo -n flux-system --tail=-1 2>/dev/null | wc -l | tr -d ' ')

echo "== forcing a reconcile of a real policy source =="
flux reconcile source git policy-2.1.1 -n flux-system --timeout=60s

echo "== waiting for the alert to reach the receiver =="
for _ in $(seq 1 30); do
  after=$(kubectl logs deploy/revision-echo -n flux-system --tail=-1 2>/dev/null | wc -l | tr -d ' ')
  if [ "$after" -gt "$before" ]; then
    body=$(kubectl logs deploy/revision-echo -n flux-system --tail=-1 2>/dev/null | tail -n $((after - before)))
    if grep -q '"involvedObject"' <<<"$body" && grep -q 'policy-2.1.1' <<<"$body"; then
      echo "OK: revision-echo received an event naming policy-2.1.1's revision within one reconcile"
      exit 0
    fi
  fi
  sleep 2
done
echo "FAIL: no matching event reached revision-echo within 60s"
exit 1
