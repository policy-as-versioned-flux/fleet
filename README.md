# fleet

The config repo Flux reconciles (PRD §5.1). A KiND cluster running the
ControlPlane Flux Operator (`FluxInstance`,
[ADR-0005](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0005-controlplane-flux-operator-resourceset.md)),
the Kyverno engine (`>=1.18`,
[ADR-0003](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0003-kyverno-validatingpolicy-cel.md)),
**three policy versions coexisting side by side** (`v1.0.1`, `v2.0.1`,
`v2.1.1`, ADR-0001 + ADR-0005's `ResourceSet` matrix, issue 08), the
**orphan guard** (issue 09, the deterministic Deny catch-all that makes the
gate tier a locked door), and three consumer apps (one per version) — all
reconciling live from git, not one-shot `kubectl apply`.

**Known gap (issue 08/09):** the version self-scoping mechanism was
corrected from `matchConstraints.objectSelector` to `matchConditions`
partway through (see the policy repo's `1466fdc` and this hub's ADR-0003)
after finding Kyverno flattens every installed ValidatingPolicy's
objectSelector into one shared webhook. The fix is on the policy repo's
`main`, but `v1.0.0`/`v1.0.1`/`v2.0.0`/`v2.0.1`/`v2.1.1` are already tagged
and immutable with the old pattern baked in -- new patch tags are needed
before this fleet repo's `policy-versions.yaml` can point at genuinely
coexistence-safe releases. Until then, `verify-coexistence.sh` and
`verify-orphan-guard.sh`'s differential/cross-version checks are flaky by
construction (Kyverno's shared-webhook selector reflects whichever policy
it reconciled last), not because the ResourceSet/orphan-guard mechanisms
built here are wrong.

```
flux-instance.yaml            FluxInstance -- pinned Flux 2.9.2, upstream-alpine variant
infrastructure/kyverno/       Kyverno engine: Namespace + HelmRepository + HelmRelease
infrastructure/monitoring/    issue 14: kube-prometheus-stack + Policy Reporter (both pinned) --
                                PolicyReport results as Prometheus metrics, Policy Reporter's own
                                pre-built Grafana dashboards auto-discovered by the sidecar
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
```

## Run it

```sh
./up.sh                  # KiND -> Flux Operator -> Kyverno -> 3 policy versions -> guard -> 3 apps
./verify-live.sh         # admission verdicts against what's live
./verify-coexistence.sh  # multi-version coexistence claims against what's live
./verify-orphan-guard.sh # orphan guard claims against what's live
./verify-renovate.sh     # Renovate customManager against a fixture -- no cluster needed
./verify-monitoring.sh   # PolicyReport -> Prometheus claims against what's live
./down.sh                # tear down; ./up.sh again recreates cleanly
```

Grafana (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`,
`admin`/`admin`) ships three Policy Reporter dashboards out of the box: "PolicyReports"
(cluster-wide, filterable by the `policy` variable -- which carries the version suffix),
"PolicyReport Details", "ClusterPolicyReport Details".

Prereqs: docker, kind, kubectl, helm, flux, jq. Readiness is gated by native
`kubectl wait --for=condition=Ready` throughout, never a jsonpath polling
loop.
