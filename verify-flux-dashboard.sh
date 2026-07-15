#!/usr/bin/env bash
# Runnable check for issue 15, against whatever this cluster currently has
# live (run ./up.sh first, and apply infrastructure/monitoring/ once its PR
# is merged; see the fleet README).
set -euo pipefail

cleanup() { [ -n "${PROM_PID:-}" ] && kill "$PROM_PID" 2>/dev/null || true; }
trap cleanup EXIT

kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 39090:9090 >/dev/null 2>&1 &
PROM_PID=$!
sleep 3

echo "== gotk_resource_info shows every pinned policy version =="
for v in 1.0.0 2.0.0 2.1.1; do
  n=$(curl -s "http://localhost:39090/api/v1/query" \
    --data-urlencode "query=gotk_resource_info{customresource_kind=\"GitRepository\",name=\"policy-$v\"}" \
    | jq '.data.result | length')
  [ "$n" -eq 1 ] || { echo "FAIL: no gotk_resource_info for policy-$v GitRepository"; exit 1; }
done
echo "OK: all 3 installed versions have a GitRepository revision metric"

echo "== the flux-policy-dashboard ConfigMap exists, labelled for Grafana sidecar discovery =="
kubectl -n monitoring get configmap flux-policy-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}' | grep -qx 1 \
  || { echo "FAIL: flux-policy-dashboard missing the grafana_dashboard label"; exit 1; }
echo "OK"

echo "== selecting a version shows where it's installed and whether workloads on it pass =="
for v in 1.0.0 2.0.0 2.1.1; do
  where=$(curl -s "http://localhost:39090/api/v1/query" \
    --data-urlencode "query=gotk_resource_info{customresource_kind=~\"GitRepository|Kustomization\",name=~\".*$v.*\"}" \
    | jq '.data.result | length')
  passing=$(curl -s "http://localhost:39090/api/v1/query" \
    --data-urlencode "query=sum(policy_report_result{policy=~\".*$v\"})" \
    | jq -r '.data.result[0].value[1] // "0"')
  [ "$where" -ge 1 ] || { echo "FAIL: $v has no Flux resources shown"; exit 1; }
  [ "$passing" != "0" ] || { echo "FAIL: $v has no PolicyReport results shown"; exit 1; }
  echo "  $v: $where Flux resources, $passing PolicyReport results"
done
echo "OK: every version resolves both 'where' and 'passing?' panels"
