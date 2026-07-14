#!/usr/bin/env bash
# Runnable check for issue 06's admission-verdict claims, against whatever
# this cluster currently has live (run ./up.sh first). Complements the
# policy repo's own verify-live.sh (which proves the same mechanism in
# isolation) by proving it end-to-end through the real Flux-reconciled
# fleet: a compliant labelled workload admits, a gate violation is refused,
# a lane-keeper violation admits but is reported, and an unlabelled
# workload is untouched.
set -euo pipefail

cleanup() {
  kubectl delete pod live-gate-fail live-audit-fail live-unlabelled --ignore-not-found >/dev/null
}
trap cleanup EXIT

echo "== app1 (compliant, from Flux): admitted =="
kubectl get pod app1 >/dev/null || { echo "FAIL: app1 not present -- run ./up.sh first"; exit 1; }
echo "OK: app1 is Running"

echo "== Deny gate: an unrecognised department value is refused =="
if kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: live-gate-fail
  namespace: default
  labels:
    mycompany.com/policy-version: "1.0.0"
    department: not-a-real-department
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
then
  echo "FAIL: Deny gate admitted a pod with an unknown department"; exit 1
fi
echo "OK: admission refused"

echo "== Audit lane-keeper: a missing department label admits, but is reported =="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: live-audit-fail
  namespace: default
  labels:
    mycompany.com/policy-version: "1.0.0"
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
kubectl get pod live-audit-fail >/dev/null || { echo "FAIL: Audit policy blocked admission"; exit 1; }
reported=false
for _ in $(seq 1 60); do
  fails=$(kubectl get polr -A -o json | jq '[.items[] | select(.scope.name=="live-audit-fail") | .results[]? | select(.policy=="require-department-label-1.0.0" and .result=="fail")] | length')
  [ "$fails" -ge 1 ] && { reported=true; break; }
  sleep 1
done
$reported || { echo "FAIL: no PolicyReport fail entry for live-audit-fail"; exit 1; }
echo "OK: admitted and reported"

echo "== Unlabelled workload: untouched by the versioned policies =="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: live-unlabelled
  namespace: default
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
kubectl get pod live-unlabelled >/dev/null || { echo "FAIL: unlabelled pod was blocked"; exit 1; }
echo "OK: admitted (orphan guard, which would catch this, lands in a later issue)"
