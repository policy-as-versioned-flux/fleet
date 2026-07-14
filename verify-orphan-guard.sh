#!/usr/bin/env bash
# Runnable check for issue 09's orphan guard claims, against whatever this
# cluster currently has live (run ./up.sh first).
set -euo pipefail

cleanup() {
  kubectl delete pod orphan-no-label orphan-bad-version preexisting-orphan --ignore-not-found >/dev/null
}
trap cleanup EXIT

echo "== no policy-version label: denied at admission =="
if kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: orphan-no-label
  namespace: default
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
then
  echo "FAIL: admitted a pod with no policy-version label"; exit 1
fi
echo "OK: refused"

echo "== unknown/retired version: denied at admission =="
if kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: orphan-bad-version
  namespace: default
  labels:
    mycompany.com/policy-version: "9.9.9"
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
then
  echo "FAIL: admitted a pod labelled with an uninstalled version"; exit 1
fi
echo "OK: refused"

echo "== allow-list templates from the same ResourceSet array as the installed versions =="
expr=$(kubectl get validatingpolicy orphan-guard -o jsonpath='{.spec.validations[0].expression}')
for v in 1.0.0 2.0.0 2.1.1; do
  grep -q "'$v'" <<<"$expr" || { echo "FAIL: orphan-guard's allow-list doesn't mention installed version $v"; exit 1; }
done
echo "OK: allow-list contains every currently-installed version"

echo "== background scan reports pre-existing orphans without evicting them =="
# Simulate the brownfield case: the pod became an orphan before the guard
# existed (or before its version was retired) -- remove the guard, create
# the orphan (bypassing admission since nothing's there to refuse it),
# reinstall the guard, and confirm it's reported, not deleted.
kubectl delete validatingpolicy orphan-guard --ignore-not-found >/dev/null
sleep 2
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: preexisting-orphan
  namespace: default
  labels:
    mycompany.com/policy-version: "9.9.9"
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
kubectl annotate resourceset policy-versions -n flux-system \
  fluxcd.controlplane.io/reconcileRequestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null
# kubectl wait errors immediately (not "wait") if the target doesn't exist
# yet -- it only waits for a condition on an object already there, not for
# creation. Poll for existence first.
for _ in $(seq 1 30); do
  kubectl get validatingpolicy orphan-guard >/dev/null 2>&1 && break
  sleep 1
done
kubectl wait --for=jsonpath='{.status.conditionStatus.ready}'=true validatingpolicy/orphan-guard --timeout=60s >/dev/null

reported=false
for _ in $(seq 1 60); do
  fails=$(kubectl get polr -A -o json | jq '[.items[] | select(.scope.name=="preexisting-orphan") | .results[]? | select(.policy=="orphan-guard" and .result=="fail")] | length')
  [ "$fails" -ge 1 ] && { reported=true; break; }
  kubectl get pod preexisting-orphan >/dev/null 2>&1 || { echo "FAIL: pre-existing orphan was evicted, not just reported"; exit 1; }
  sleep 1
done
kubectl get pod preexisting-orphan >/dev/null 2>&1 || { echo "FAIL: pre-existing orphan was evicted, not just reported"; exit 1; }
$reported || { echo "FAIL: no PolicyReport fail entry for the pre-existing orphan"; exit 1; }
echo "OK: still running, reported as a violation"
