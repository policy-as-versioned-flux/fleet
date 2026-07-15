#!/usr/bin/env bash
# Issue 12: makes a Renovate bump PR trustworthy before merge (PRD §5 update
# lifecycle). Runs identically in CI (.github/workflows/pr-gate.yml, which
# just supplies BASE_REF/HEAD_REF from the pull_request event) and locally
# (pass any two refs -- a real PR isn't required to exercise this logic,
# only the {tag, commit} pairs it reads out of clusters/*.yaml).
#
# For every {version, tag, commit} entry in HEAD_REF's policy-versions.yaml:
#   1. gitsign verify-tag, identity-pinned, offline Rekor bundle.
#   2. the tag still resolves to the claimed commit (catches a force-moved
#      tag, or a PR that hand-edited commit without actually re-resolving
#      tag -- the exact drift ADR-0001 names).
#   3. kyverno test runs green against that commit's own fixtures.
#   4. flux build --dry-run renders the incoming manifests (no cluster
#      needed) -- diffed against BASE_REF's build of the same entry (or "new
#      entry" if BASE_REF doesn't have it) so a reviewer sees exactly what
#      merging adopts.
#
# Usage: ./pr-gate-check.sh <base-ref> <head-ref>
set -euo pipefail
cd "$(dirname "$0")"
BASE_REF="${1:?usage: pr-gate-check.sh <base-ref> <head-ref>}"
HEAD_REF="${2:?usage: pr-gate-check.sh <base-ref> <head-ref>}"
POLICY_URL="https://github.com/policy-as-versioned-flux/policy"
EXPECTED_IDENTITY="chris@cns.me.uk"
EXPECTED_ISSUER="https://accounts.google.com"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if git diff --quiet "$BASE_REF" "$HEAD_REF" -- clusters/ 2>/dev/null; then
  echo "== nothing under clusters/ changed between $BASE_REF and $HEAD_REF -- nothing to gate =="
  exit 0
fi

echo "== extract {version, tag, commit, policies} from $HEAD_REF =="
git show "$HEAD_REF:clusters/cluster1/policy-versions.yaml" > "$WORK/head.yaml"
git show "$BASE_REF:clusters/cluster1/policy-versions.yaml" > "$WORK/base.yaml" 2>/dev/null || echo "[]" > "$WORK/base.yaml"

entries=$(yq -o=json '.spec.inputs[0].versions' "$WORK/head.yaml")
count=$(jq 'length' <<<"$entries")
echo "OK: $count entries"

fail=0
for i in $(seq 0 $((count - 1))); do
  entry=$(jq ".[$i]" <<<"$entries")
  version=$(jq -r '.version' <<<"$entry")
  tag=$(jq -r '.tag' <<<"$entry")
  commit=$(jq -r '.commit' <<<"$entry")
  policies=$(jq -r '.policies[]' <<<"$entry")

  echo "############ $version (tag v$tag) ############"
  co="$WORK/policy-$version"
  git clone -q --branch "v$tag" "$POLICY_URL" "$co"
  # `git clone --branch <tag>` (like actions/checkout, issue 04) can leave
  # the local tag ref flattened to point straight at the commit instead of
  # the annotated tag object gitsign needs -- re-fetch it explicitly.
  git -C "$co" fetch -q origin "+refs/tags/v$tag:refs/tags/v$tag" --force

  echo "== gitsign verify-tag: identity-pinned, offline Rekor bundle =="
  gitsign_out=$(cd "$co" && GITSIGN_REKOR_MODE=offline GITSIGN_CREDENTIAL_CACHE="${GITSIGN_CREDENTIAL_CACHE:-}" gitsign verify-tag "v$tag" \
      --certificate-identity="$EXPECTED_IDENTITY" \
      --certificate-oidc-issuer="$EXPECTED_ISSUER" 2>&1) && gitsign_rc=0 || gitsign_rc=$?
  echo "$gitsign_out" | sed 's/^/  /'
  if [ "$gitsign_rc" -ne 0 ]; then
    echo "FAIL: gitsign verify-tag v$tag"; fail=1; continue
  fi

  echo "== tag still resolves to the pinned commit =="
  resolved=$(git -C "$co" rev-parse "v$tag^{commit}")
  if [ "$resolved" != "$commit" ]; then
    echo "FAIL: v$tag resolves to $resolved, PR claims $commit -- force-moved tag or bad PR"
    fail=1; continue
  fi
  echo "  OK: v$tag -> $resolved"

  echo "== kyverno test: incoming version's own fixtures =="
  if ! (cd "$co" && ./verify.sh) > "$WORK/kyverno-test-$version.log" 2>&1; then
    echo "FAIL: kyverno test fixtures for $version"; tail -20 "$WORK/kyverno-test-$version.log"; fail=1; continue
  fi
  echo "  OK: fixtures green"

  echo "== flux build --dry-run: what merging this PR adopts =="
  for p in $policies; do
    out="$WORK/build-$version-$p.yaml"
    flux build kustomization "policy-$version-$p" \
      --path="$co/workloads/kyverno/$p" \
      --kustomization-file=<(cat <<EOF
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: policy-$version-$p
  namespace: flux-system
spec:
  sourceRef: {kind: GitRepository, name: policy-$version}
  path: ./workloads/kyverno/$p
EOF
) --dry-run > "$out" 2>"$WORK/build-$version-$p.err" || { echo "FAIL: flux build $version/$p"; cat "$WORK/build-$version-$p.err"; fail=1; continue; }
    old_commit=$(jq -r --arg v "$version" '.[] | select(.version==$v) | .commit' <<<"$(yq -o=json '.spec.inputs[0].versions' "$WORK/base.yaml")")
    if [ -z "$old_commit" ] || [ "$old_commit" = "null" ]; then
      echo "  -- new array element ($version), nothing to diff against --"
    elif [ "$old_commit" = "$commit" ]; then
      echo "  -- $version unchanged --"
    else
      echo "  -- $version changed (base had $old_commit) --"
    fi
  done
done

[ "$fail" -eq 0 ] && echo "== PR gate: PASS ==" || { echo "== PR gate: FAIL =="; exit 1; }
