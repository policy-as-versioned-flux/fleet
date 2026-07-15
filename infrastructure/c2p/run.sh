#!/bin/sh
# Issue 21: the real, continuously-running C2P collection job (ADR-0009's
# "CronJob / Flux Kustomization, small glue we own"), against the LIVE
# fleet's PolicyReports -- not a spike, not a throwaway cluster. Runs
# in-cluster (kubectl auto-detects the mounted ServiceAccount token), writes
# its output to a ConfigMap Grafana's infinity datasource reads (issue 21's
# "only first-party Grafana datasource plugins -- no bespoke exporters":
# infinity IS first-party-listed, this script is glue, not an exporter
# service).
set -eu
WORK=/work
mkdir -p "$WORK"
cd "$WORK"

echo "== install kubectl (pinned version, checksum fetched from the same official release -- not hand-copied) =="
KUBECTL_VERSION=1.31.4
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -sSLo kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
curl -sSLo kubectl.sha256 "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c -
chmod +x kubectl
export PATH="$WORK:$PATH"

echo "== build C2P v2.0.0-rc.1 (pinned, from source -- ADR-0009 pre-GA acceptance) =="
git clone --depth 1 --branch v2.0.0-rc.1 https://github.com/oscal-compass/compliance-to-policy-go.git c2p
( cd c2p && go build -o bin/c2pcli ./cmd/c2pcli && go build -o bin/kyverno-plugin ./cmd/kyverno-plugin )
CLI="$WORK/c2p/bin/c2pcli"

echo "== assemble C2P inputs =="
mkdir -p plugins policy-resources tmp tmp-out reports
cp c2p/bin/kyverno-plugin plugins/kyverno-plugin
sum=$(sha256sum plugins/kyverno-plugin | cut -d' ' -f1)
cat > plugins/c2p-kyverno-manifest.json <<EOF
{ "metadata": { "id": "kyverno", "description": "Kyverno PVP Plugin", "version": "0.0.1", "types": ["pvp"] },
  "executablePath": "kyverno-plugin", "sha256": "$sum",
  "configuration": [
    { "name": "policy-dir", "required": true },
    { "name": "policy-results-dir", "required": true },
    { "name": "temp-dir", "required": true },
    { "name": "output-dir", "required": false, "default": "." } ] }
EOF
cat > c2p-config.yaml <<EOF
component-definition: /config/component-definition.json
plugins:
  kyverno:
    policy-dir: $WORK/policy-resources
    policy-results-dir: $WORK/reports
    temp-dir: $WORK/tmp
    output-dir: $WORK/tmp-out
EOF
empty(){ printf 'apiVersion: v1\nkind: List\nitems: []\n' > "$1"; }
empty reports/policies.kyverno.io.yaml
empty reports/clusterpolicies.kyverno.io.yaml
empty reports/clusterpolicyreports.wgpolicyk8s.io.yaml

echo "== collect PolicyReports from the live cluster, shim, run result2oscal =="
# The shim (ADR-0009, proven in issue 20): scope -> results[].resources
# (Kyverno >=1.18 per-resource reports), and strip the coexistence
# nameSuffix (results[].policy comes back as e.g.
# require-s3-bucket-encryption-2.2.0; the component-definition's Check_Id
# is the unsuffixed base name) so one component-definition matches every
# coexisting version.
kubectl get policyreports.wgpolicyk8s.io -A -o json \
  | jq '.items |= map(.scope as $s | .results |= map(
          .policy    = (.policy | sub("-[0-9]+\\.[0-9]+\\.[0-9]+$"; "")) |
          .resources = [{apiVersion:$s.apiVersion, kind:$s.kind, namespace:$s.namespace, name:$s.name, uid:$s.uid}]))' \
  > reports/policyreports.wgpolicyk8s.io.yaml

"$CLI" result2oscal -c c2p-config.yaml -n nist_800_53 -o assessment-results.json -p plugins

echo "== publish as a ConfigMap for Grafana's infinity datasource to read =="
kubectl create configmap oscal-assessment-results -n monitoring \
  --from-file=assessment-results.json=assessment-results.json \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== done: $(jq '[.["assessment-results"].results[0].findings[]?]|length' assessment-results.json) finding(s) =="
