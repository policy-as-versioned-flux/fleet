# fleet

The config repo Flux reconciles (PRD §5.1). A KiND cluster running the
ControlPlane Flux Operator (`FluxInstance`,
[ADR-0005](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0005-controlplane-flux-operator-resourceset.md)),
the Kyverno engine (`>=1.18`,
[ADR-0003](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0003-kyverno-validatingpolicy-cel.md)),
policy `v1.0.0` pinned as a versioned dependency (ADR-0001), and one
consumer app (issue 06) — all reconciling live from git, not one-shot
`kubectl apply`. The `ResourceSet` coexistence matrix for N versions lands
in a later issue; today `clusters/cluster1/` hand-wires a single version.

```
flux-instance.yaml            FluxInstance -- pinned Flux 2.9.2, upstream-alpine variant
infrastructure/kyverno/       Kyverno engine: Namespace + HelmRepository + HelmRelease
clusters/cluster1/
  bootstrap.yaml               self-referential GitRepository+Kustomization: this repo
                                syncs itself, so infrastructure/kyverno/ becomes a real
                                Kustomization ("kyverno") other Kustomizations dependsOn
  policy-v1.0.0.yaml            GitRepository pinned {tag: v1.0.0, commit: <sha>} (ADR-0001)
                                + one Kustomization per policy, both dependsOn kyverno
  apps.yaml                     the apps repo, branch-tracked, dependsOn the policy
                                Kustomizations so the demo is deterministic
up.sh / down.sh                one command sequence, idempotent, clean teardown+recreate
verify-live.sh                 proves the admission verdicts: compliant admits, gate
                                violation refused, lane-keeper violation admits+reported,
                                unlabelled workload untouched
```

## Run it

```sh
./up.sh            # KiND cluster 'cluster1' -> Flux Operator -> Kyverno -> policy v1.0.0 -> app1
./verify-live.sh   # prove the admission verdicts against what's live
./down.sh          # tear down; ./up.sh again recreates cleanly
```

Prereqs: docker, kind, kubectl, helm, flux, jq. Readiness is gated by native
`kubectl wait --for=condition=Ready` throughout, never a jsonpath polling
loop.
