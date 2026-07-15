#!/usr/bin/env bash
# Runnable check for issue 14, against whatever this cluster currently has
# live (run ./up.sh first, and apply infrastructure/monitoring/ -- it lands
# via Flux once its PR is merged; see the fleet README).
set -euo pipefail

cleanup() {
  kubectl delete pod monitoring-fail-test --ignore-not-found >/dev/null
  [ -n "${PROM_PID:-}" ] && kill "$PROM_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "== PolicyReport results for all installed versions appear as Prometheus metrics =="
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 39090:9090 >/dev/null 2>&1 &
PROM_PID=$!
sleep 3
for v in 1.0.0 2.0.0 2.2.0; do
  n=$(curl -s "http://localhost:39090/api/v1/query" --data-urlencode "query=policy_report_result{policy=~\".*-$v\"}" \
    | jq '.data.result | length')
  [ "$n" -gt 0 ] || { echo "FAIL: no policy_report_result metric mentions version $v"; exit 1; }
done
echo "OK: metrics present for every installed version"

echo "== a deliberately non-compliant Audit-mode workload shows as failing without being evicted =="
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: monitoring-fail-test
  namespace: default
  labels:
    mycompany.com/policy-version: "2.2.0"
    department: platform
spec:
  containers:
    - name: app
      image: nginx:latest
EOF
kubectl get pod monitoring-fail-test >/dev/null || { echo "FAIL: Audit-mode violation was refused, should only report"; exit 1; }

found=false
for _ in $(seq 1 30); do
  n=$(curl -s "http://localhost:39090/api/v1/query" \
    --data-urlencode 'query=policy_report_result{name="monitoring-fail-test",status="fail"}' \
    | jq '.data.result | length')
  [ "$n" -gt 0 ] && { found=true; break; }
  kubectl get pod monitoring-fail-test >/dev/null 2>&1 || { echo "FAIL: pod was evicted, not just reported"; exit 1; }
  sleep 2
done
kubectl get pod monitoring-fail-test >/dev/null 2>&1 || { echo "FAIL: pod was evicted, not just reported"; exit 1; }
$found || { echo "FAIL: no fail metric appeared in Prometheus"; exit 1; }
echo "OK: reported as failing in Prometheus, pod still running"
