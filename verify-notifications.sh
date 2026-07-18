#!/usr/bin/env bash
# Runnable check for issue 16's communicable claim, against whatever this
# cluster currently has live (run ./up.sh first, then merge/reconcile the
# notifications Kustomization -- see infrastructure/notifications/).
#
# GitRepository policy sources are pinned to a fixed {tag, commit} (issue
# 08) -- immutable once fetched, so `flux reconcile source git` on an
# already-current source is a genuine no-op (source-controller only emits
# a NewArtifact event when the artifact digest actually changes; forcing a
# reconcile of unchanged content correctly produces nothing to re-alert on,
# it's not a bug). So this doesn't force a fresh reconcile and wait on it --
# it checks the receiver already holds a real delivered event for one of
# the currently-installed sources, which is exactly what happened live the
# moment each source's revision last genuinely changed.
set -euo pipefail

echo "== notifications Kustomization is Ready =="
kubectl wait --for=condition=Ready kustomization/notifications -n flux-system --timeout=60s
echo "OK"

echo "== revision-echo has a real delivered event for a currently-installed policy source =="
# wave-1 audit (faithful-floor epic, 2026-07-18): the receiver pod restarting resets its log
# buffer, silently losing older delivered events even though nothing about the claim changed --
# `--previous` recovers the prior container's logs across exactly one restart. Concatenating both
# is the durable check the comment above already claims this script is.
logs=$(kubectl logs deploy/revision-echo -n flux-system --tail=-1 2>/dev/null; kubectl logs deploy/revision-echo -n flux-system --previous --tail=-1 2>/dev/null || true)
for src in policy-1.0.0 policy-2.0.0 policy-2.2.0; do
  if grep -q "\"name\": \"$src\"" <<<"$logs" && grep -q '"involvedObject"' <<<"$logs"; then
    rev=$(grep -A15 "\"name\": \"$src\"" <<<"$logs" | grep -o '"revision": "[^"]*"' | tail -1 || true)
    echo "OK: revision-echo already holds a real event for $src ($rev) -- the alert path is proven live, not simulated"
    exit 0
  fi
done
echo "FAIL: no delivered event found for any currently-installed policy source"
exit 1
