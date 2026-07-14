# fleet

The config repo Flux reconciles (PRD §5.1). A KiND cluster running the
ControlPlane Flux Operator (`FluxInstance`,
[ADR-0005](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0005-controlplane-flux-operator-resourceset.md)),
the Kyverno engine (`>=1.18`,
[ADR-0003](https://github.com/policy-as-versioned-flux/policy-as-versioned-flux/blob/main/docs/adr/0003-kyverno-validatingpolicy-cel.md)),
**three policy versions coexisting side by side** (`v1.0.1`, `v2.0.1`,
`v2.1.1`, ADR-0001 + ADR-0005's `ResourceSet` matrix, issue 08), and three
consumer apps (one per version) — all reconciling live from git, not
one-shot `kubectl apply`.

```
flux-instance.yaml            FluxInstance -- pinned Flux 2.9.2, upstream-alpine variant
infrastructure/kyverno/       Kyverno engine: Namespace + HelmRepository + HelmRelease
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
up.sh / down.sh                one command sequence, idempotent, clean teardown+recreate
verify-live.sh                 proves the admission verdicts: compliant admits, gate
                                violation refused, lane-keeper violation admits+reported,
                                unlabelled workload untouched
verify-coexistence.sh          proves issue 08: three versions live side by side,
                                collision-free, each judging only its own opted-in workloads
```

## Run it

```sh
./up.sh                 # KiND -> Flux Operator -> Kyverno -> 3 policy versions -> 3 apps
./verify-live.sh        # admission verdicts against what's live
./verify-coexistence.sh # multi-version coexistence claims against what's live
./down.sh               # tear down; ./up.sh again recreates cleanly
```

Prereqs: docker, kind, kubectl, helm, flux, jq. Readiness is gated by native
`kubectl wait --for=condition=Ready` throughout, never a jsonpath polling
loop.
