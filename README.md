# fleet

The config repo Flux reconciles (PRD §5.1). A KiND cluster running the
ControlPlane Flux Operator (`FluxInstance`,
[ADR-0005](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0005-controlplane-flux-operator-resourceset.md)),
the Kyverno engine (`>=1.18`,
[ADR-0003](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0003-kyverno-validatingpolicy-cel.md)),
**three policy versions coexisting side by side** (`v1.0.2`, `v2.0.2`,
`v2.2.0`, ADR-0001 + ADR-0005's `ResourceSet` matrix, issue 08), the
**orphan guard** (issue 09, the deterministic Deny catch-all that makes the
gate tier a locked door), and three consumer apps (one per version) — all
reconciling live from git, not one-shot `kubectl apply`.

**Issue 08/09, resolved:** the version self-scoping mechanism was corrected
from `matchConstraints.objectSelector` to `matchConditions` (see the policy
repo's `1466fdc` and this hub's ADR-0003) after finding Kyverno flattens
every installed ValidatingPolicy's `objectSelector` into one shared webhook
-- only the most-recently-reconciled version's workloads were ever
evaluated at all. `v1.0.0`/`v1.0.1`/`v2.0.0`/`v2.0.1`/`v2.1.1` were already
tagged and immutable with the old pattern baked in, so this repo now points
at `v1.0.2`/`v2.0.2` (new, zero-verdict-impact patch tags carrying just the
fix into the two older lines) and `v2.2.0` (a real content release: same
fix + issue 17's cloud-plane policies) instead.

```
flux-instance.yaml            FluxInstance -- pinned Flux 2.9.2, upstream-alpine variant
infrastructure/kyverno/       Kyverno engine: Namespace + HelmRepository + HelmRelease
infrastructure/monitoring/    issue 14: kube-prometheus-stack + Policy Reporter (both pinned) --
                                PolicyReport results as Prometheus metrics, Policy Reporter's own
                                pre-built Grafana dashboards auto-discovered by the sidecar.
                                Issue 15: kube-state-metrics customResourceState config (the
                                flux2-monitoring-example pattern, trimmed to the 3 Flux kinds
                                this repo uses) exposing gotk_resource_info; a combined
                                Flux-revision + PolicyReports dashboard, same ConfigMap +
                                sidecar mechanism, sharing one cluster+policy-version variable
clusters/cluster1/
  bootstrap.yaml               self-referential GitRepository+Kustomization: this repo
                                syncs itself, so infrastructure/kyverno/ becomes a real
                                Kustomization ("kyverno") other Kustomizations dependsOn
  policy-versions.yaml          the crux (PRD §6.4): one ResourceSet, one input carrying
                                a nested {version, commit, policies} array; the
                                resourcesTemplate ranges over it to generate a
                                GitRepository + one Kustomization per policy, per version.
                                Adding/removing an array element is the only change needed
                                to install/retire a version.
  apps.yaml                     the apps repo (app1/2/3, one per version), branch-tracked
renovate.json                   issue 11: one customManager (git-refs datasource) bumps every
                                {tag, commit} pin to the policy repo -- the only pin surface in
                                this design, see the file's own description field for why
up.sh / down.sh                one command sequence, idempotent, clean teardown+recreate
verify-live.sh                 proves the admission verdicts: compliant admits, gate
                                violation refused, lane-keeper violation admits+reported,
                                unlabelled workload untouched
verify-coexistence.sh          proves issue 08: three versions live side by side,
                                collision-free, each judging only its own opted-in workloads
verify-orphan-guard.sh         proves issue 09: no label denied, unknown version denied,
                                allow-list tracks the installed set, pre-existing orphans
                                reported not evicted
verify-renovate.sh             proves issue 11: the customManager correctly targets each
                                element of the real multi-version array independently (a
                                fixture, not the live cluster -- no kubectl/KiND needed)
verify-monitoring.sh           proves issue 14: PolicyReport metrics for every installed
                                version reach Prometheus; a non-compliant Audit workload
                                shows failing there without being evicted
verify-flux-dashboard.sh       proves issue 15: gotk_resource_info covers every installed
                                version; selecting a version resolves both "where is it
                                installed" and "is it passing" panel queries
infrastructure/crossplane*/    issue 18: Crossplane v2 core + AWS provider-family (S3, RDS)
                                CRDs, free and KiND-only -- no ProviderConfig, no cloud
                                credentials anywhere. Three Kustomizations
                                (crossplane -> crossplane-providers -> crossplane-sample)
                                chained by dependsOn + healthChecks so the provider CRDs
                                reaching Established gates everything downstream -- issue 19's
                                real cloud-policy Kustomizations (blocked on issue 08) will
                                carry the same dependsOn once unblocked.
verify-crossplane.sh           proves issue 18: CRDs Established, the ordering held, and the
                                sample RDS CR sits unreconciled (no auth on the critical path)
pr-gate-check.sh                issue 12: gitsign verify-tag + tag-resolves-to-commit +
                                kyverno test + flux build --dry-run for every array entry in
                                a bump PR. Runs identically in CI
                                (.github/workflows/pr-gate.yml, on PRs touching clusters/**,
                                required by a branch ruleset before merge) and locally
                                (./pr-gate-check.sh <base-ref> <head-ref>) -- no real PR needed
                                to exercise it, only the {tag, commit} pairs it reads
```

## Run it

```sh
./up.sh                  # KiND -> Flux Operator -> Kyverno -> 3 policy versions -> guard -> 3 apps
./verify-live.sh         # admission verdicts against what's live
./verify-coexistence.sh  # multi-version coexistence claims against what's live
./verify-orphan-guard.sh # orphan guard claims against what's live
./verify-renovate.sh     # Renovate customManager against a fixture -- no cluster needed
./verify-monitoring.sh   # PolicyReport -> Prometheus claims against what's live
./verify-flux-dashboard.sh  # Flux-revision + PolicyReports dashboard claims against what's live
./verify-crossplane.sh   # Crossplane CRD install + ordering claims against what's live
./pr-gate-check.sh HEAD~1 HEAD  # PR gate against any two refs -- no cluster, no real PR needed
./down.sh                # tear down; ./up.sh again recreates cleanly
```

Grafana (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`,
`admin`/`admin`) ships three Policy Reporter dashboards out of the box: "PolicyReports"
(cluster-wide, filterable by the `policy` variable -- which carries the version suffix),
"PolicyReport Details", "ClusterPolicyReport Details" -- plus issue 15's own "Flux Revision +
PolicyReports" dashboard, sharing one `cluster`+`policy-version` variable across a "which
version, where" panel (`gotk_resource_info`) and an "is it passing" panel
(`policy_report_result`). `cluster` is a single fixed value today (one Prometheus per cluster) --
real cross-cluster querying (Thanos, federation, or a per-cluster datasource this variable picks
between) is issue 10's design question once `cluster2` exists, not answered here.

Prereqs: docker, kind, kubectl, helm, flux, jq. Readiness is gated by native
`kubectl wait --for=condition=Ready` throughout, never a jsonpath polling
loop.
