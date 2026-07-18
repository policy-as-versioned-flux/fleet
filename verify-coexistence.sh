#!/usr/bin/env bash
# Runnable check for issue 08's coexistence claims, against whatever this
# cluster currently has live (run ./up.sh first).
set -euo pipefail

echo "== three versions live side by side, collision-free (9 policies: 2+2+5) =="
# issue 19 added the two cloud-plane policies to 2.2.0 -- this list drifted
# stale until noticed live while verifying ticket 07/08's app rewiring.
got=$(kubectl get validatingpolicy -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort)
want=$(cat <<'EOF' | sort
orphan-guard
require-department-label-1.0.0
require-known-department-label-1.0.0
require-department-label-2.0.0
require-known-department-label-2.0.0
require-department-label-2.2.0
require-known-department-label-2.2.0
require-owner-annotation-2.2.0
require-rds-multi-az-2.2.0
require-s3-bucket-encryption-2.2.0
EOF
)
[ "$got" = "$want" ] || { echo "FAIL: expected exactly these ValidatingPolicies, got:"; echo "$got"; exit 1; }
echo "OK: all 9 present, no name collisions"

echo "== every per-version Kustomization dependsOn kyverno and waits =="
# wave-2 audit (2026-07-18): this selector was wrong (`fluxcd.controlplane.io/name`, a label that
# doesn't exist on these objects) and silently matched zero Kustomizations -- the loop body never
# ran, so this check vacuously printed OK regardless of live state. The real label the ResourceSet
# stamps on everything it generates is `resourceset.fluxcd.controlplane.io/name`.
matched=0
for ks in $(kubectl -n flux-system get kustomization -l "resourceset.fluxcd.controlplane.io/name=policy-versions" -o name); do
  matched=$((matched + 1))
  deps=$(kubectl -n flux-system get "$ks" -o jsonpath='{.spec.dependsOn[*].name}')
  wait=$(kubectl -n flux-system get "$ks" -o jsonpath='{.spec.wait}')
  # issue 19: cloud-plane Kustomizations dependsOn kyverno AND crossplane-providers (CRDs-Established
  # gate); workload-plane ones dependsOn kyverno only. Both are correct -- assert kyverno is present,
  # not that it's the sole entry.
  case " $deps " in *" kyverno "*) ;; *) echo "FAIL: $ks dependsOn '$deps', expected to include 'kyverno'"; exit 1 ;; esac
  [ "$wait" = "true" ] || { echo "FAIL: $ks wait=$wait, expected true"; exit 1; }
done
[ "$matched" -gt 0 ] || { echo "FAIL: selector matched zero Kustomizations -- label wrong, or nothing installed"; exit 1; }
echo "OK: every generated Kustomization ($matched) dependsOn kyverno, wait: true"

echo "== each version judges only its own opted-in workloads: same missing-department shape, different verdict per version =="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: coexist-1-0-0
  namespace: default
  labels:
    mycompany.com/policy-version: "1.0.0"
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
kubectl get pod coexist-1-0-0 >/dev/null || { echo "FAIL: pinned to 1.0.0 (Audit there) should admit"; exit 1; }
echo "OK: missing-department pod pinned to 1.0.0 admits (still Audit at that version)"

if kubectl apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: coexist-2-0-0
  namespace: default
  labels:
    mycompany.com/policy-version: "2.0.0"
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
then
  echo "FAIL: pinned to 2.0.0 (Deny there) should be refused"; exit 1
fi
echo "OK: the identical shape pinned to 2.0.0 is refused (promoted to Deny at that version) -- live, simultaneous, differential proof"
kubectl delete pod coexist-1-0-0 --ignore-not-found >/dev/null

echo "== removing a version from the array uninstalls it (prune); re-adding reinstalls =="
tmp=$(mktemp)
yq '(.spec.inputs[0].versions) |= map(select(.version != "1.0.0"))' \
  clusters/cluster1/policy-versions.yaml > "$tmp"
kubectl apply -f "$tmp" >/dev/null
kubectl wait --for=condition=Ready resourceset/policy-versions -n flux-system --timeout=1m >/dev/null
for i in $(seq 1 30); do
  kubectl get validatingpolicy require-department-label-1.0.0 >/dev/null 2>&1 || break
  sleep 1
done
kubectl get validatingpolicy require-department-label-1.0.0 >/dev/null 2>&1 && { echo "FAIL: 1.0.0 policies still present after removing it from the array"; rm -f "$tmp"; exit 1; }
echo "OK: removing the 1.0.0 array element pruned its GitRepository + Kustomizations + ValidatingPolicies"

kubectl apply -f clusters/cluster1/policy-versions.yaml >/dev/null
kubectl wait --for=condition=Ready resourceset/policy-versions -n flux-system --timeout=1m >/dev/null
kubectl -n flux-system wait --for=condition=Ready \
  kustomization/policy-1.0.0-require-department-label \
  kustomization/policy-1.0.0-require-known-department-label \
  --timeout=2m >/dev/null
echo "OK: re-applying the full array reinstalled 1.0.0 -- adding/removing an array element is the only change needed"
rm -f "$tmp"
