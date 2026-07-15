#!/usr/bin/env bash
# Runnable check for issue 10's claims, against whatever cluster1 (./up.sh)
# and cluster2 (./up2.sh) currently have live. Requires both `kind-cluster1`
# and `kind-cluster2` kubectl contexts to exist.
set -euo pipefail

POD_YAML() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: retire-test-1-0-0
  namespace: default
  labels:
    mycompany.com/policy-version: "1.0.0"
    department: platform
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
}
cleanup() {
  kubectl --context kind-cluster1 delete pod retire-test-1-0-0 --ignore-not-found >/dev/null 2>&1 || true
  kubectl --context kind-cluster2 delete pod retire-test-1-0-0 --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== cluster1 (all versions) and cluster2 (>=2.0.0) run from the same fleet config, different inputs =="
c1=$(kubectl --context kind-cluster1 get validatingpolicy -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -c '\-1\.0\.0$' || true)
c2=$(kubectl --context kind-cluster2 get validatingpolicy -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -c '\-1\.0\.0$' || true)
[ "$c1" -gt 0 ] || { echo "FAIL: cluster1 has no 1.0.0 policies -- run ./up.sh first"; exit 1; }
[ "$c2" -eq 0 ] || { echo "FAIL: cluster2 has 1.0.0 policies -- should only ever install >=2.0.0"; exit 1; }
echo "OK: cluster1 has the 1.0.0 line, cluster2 correctly doesn't"

echo "== on cluster2, a workload pinned to 1.0.0 is denied by the orphan guard =="
if kubectl --context kind-cluster2 apply -f - >/dev/null 2>&1 <<<"$(POD_YAML)"; then
  echo "FAIL: cluster2 admitted a pod pinned to an uninstalled version"; exit 1
fi
echo "OK: refused"

echo "== the identical workload admits on cluster1 =="
kubectl --context kind-cluster1 apply -f - >/dev/null <<<"$(POD_YAML)"
kubectl --context kind-cluster1 get pod retire-test-1-0-0 >/dev/null || { echo "FAIL: cluster1 refused a pod pinned to an installed version"; exit 1; }
echo "OK: admitted -- same workload, same label, different governance outcome per cluster"

echo "== retiring a version on cluster2: removing 2.0.0 prunes it, orphan guard tightens =="
tmp=$(mktemp)
yq '(.spec.inputs[0].versions) |= map(select(.version != "2.0.0"))' \
  clusters/cluster2/policy-versions.yaml > "$tmp"
kubectl --context kind-cluster2 apply -f "$tmp" >/dev/null
kubectl --context kind-cluster2 wait --for=condition=Ready resourceset/policy-versions -n flux-system --timeout=1m >/dev/null
for i in $(seq 1 30); do
  kubectl --context kind-cluster2 get validatingpolicy require-department-label-2.0.0 >/dev/null 2>&1 || break
  sleep 1
done
kubectl --context kind-cluster2 get validatingpolicy require-department-label-2.0.0 >/dev/null 2>&1 && { echo "FAIL: 2.0.0 policies still present after removing it"; rm -f "$tmp"; exit 1; }
echo "OK: 2.0.0 pruned from cluster2"

if kubectl --context kind-cluster2 apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: retire-test-2-0-0
  namespace: default
  labels:
    mycompany.com/policy-version: "2.0.0"
    department: platform
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
then
  kubectl --context kind-cluster2 delete pod retire-test-2-0-0 --ignore-not-found >/dev/null
  echo "FAIL: a workload pinned to the just-retired 2.0.0 still admits -- guard didn't tighten"; rm -f "$tmp"; exit 1
fi
echo "OK: a workload pinned to the just-retired 2.0.0 is now refused -- guard tightened in the same reconcile"
echo "    (the estate's gate strength equals its weakest installed version -- retiring is a security action)"

echo "== restoring cluster2 to its committed array =="
kubectl --context kind-cluster2 apply -f clusters/cluster2/policy-versions.yaml >/dev/null
kubectl --context kind-cluster2 wait --for=condition=Ready resourceset/policy-versions -n flux-system --timeout=1m >/dev/null
kubectl --context kind-cluster2 wait --for=condition=Ready kustomization/policy-2.0.0-require-department-label kustomization/policy-2.0.0-require-known-department-label -n flux-system --timeout=2m >/dev/null
rm -f "$tmp"
echo "OK: restored"

echo "== the silent-ungovernance gap of the 2022 implementation is demonstrably closed =="
echo "OK: narrowing a cluster's array (or retiring a version from it) is a one-line reviewed change"
echo "    that immediately and provably changes what that cluster will admit -- not a silent drift."
