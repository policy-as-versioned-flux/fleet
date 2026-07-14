#!/usr/bin/env bash
# Runnable check for issue 11: does the one customManager in renovate.json
# actually work against the REAL, multi-element {version, tag, commit,
# policies} array in clusters/cluster1/policy-versions.yaml -- not just the
# single-element shape the issue-01 spike proved? That's the risk the spike
# explicitly deferred here. Builds a local upstream fixture (tags mirroring
# what's really installed, plus one new tag), copies the real
# policy-versions.yaml, points the customManager's depName at the fixture
# instead of the real GitHub repo, and runs Renovate in dry-run mode
# (platform=local, writes nothing) against it.
#
# Prereqs: git, node/npx, python3. ~20s.
set -euo pipefail
cd "$(dirname "$0")"
WORK=./.work
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. Upstream fixture, tagged to mirror what's really installed (git TAGs -- 1.0.1/2.0.1 are the real CI-clean tags for internal policy versions 1.0.0/2.0.0, issue 08) =="
UPSTREAM="$(pwd)/$WORK/upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email test@example.com
git -C "$UPSTREAM" config user.name test
declare -A SHA
for v in 1.0.1 2.0.1 2.1.1; do
  echo "$v" > "$UPSTREAM/VERSION"
  git -C "$UPSTREAM" add . && git -C "$UPSTREAM" commit -q -m "$v"
  git -C "$UPSTREAM" tag -a "$v" -m "$v"
  SHA[$v]=$(git -C "$UPSTREAM" rev-parse "$v")
  echo "   $v = ${SHA[$v]}"
done

echo "== 2. Fleet fixture: the REAL policy-versions.yaml, three array elements =="
FLEET="$(pwd)/$WORK/fleet"
mkdir -p "$FLEET/clusters/cluster1"
git -C "$FLEET" init -q -b main
git -C "$FLEET" config user.email test@example.com
git -C "$FLEET" config user.name test
sed \
  -e "s/95a0576f04837b599b5cfbf1fae6908728197fc6/${SHA[1.0.1]}/" \
  -e "s/e505587b1f8ab674b6147a8c955f468b49fa9ab4/${SHA[2.0.1]}/" \
  -e "s/95579dd567b2c0e490ce56aeb0504290085651f6/${SHA[2.1.1]}/" \
  clusters/cluster1/policy-versions.yaml > "$FLEET/clusters/cluster1/policy-versions.yaml"
git -C "$FLEET" add . && git -C "$FLEET" commit -q -m "pin policy versions"

echo "== 3. A new upstream tag (2.1.2) lands -- the 2.1.1 element is now behind =="
echo "2.1.2" > "$UPSTREAM/VERSION"
git -C "$UPSTREAM" add . && git -C "$UPSTREAM" commit -q -m 2.1.2
git -C "$UPSTREAM" tag -a 2.1.2 -m 2.1.2
SHA_212=$(git -C "$UPSTREAM" rev-parse 2.1.2)
echo "   2.1.2 = $SHA_212"

echo "== 4. renovate.json, depName pointed at the local fixture =="
sed "s#https://github.com/policy-as-versioned-flux/policy#file://$UPSTREAM#" renovate.json > "$WORK/renovate-config.json"

echo "== 5. Renovate dry run (platform=local -- preview only, writes nothing) =="
(
  cd "$FLEET"
  RENOVATE_CONFIG_FILE="../renovate-config.json" RENOVATE_CACHE_DIR="../renovate-cache" LOG_LEVEL=debug \
    npx --yes -p renovate renovate --platform=local
) > "$WORK/renovate.log" 2>&1 || { echo "renovate run failed:"; tail -80 "$WORK/renovate.log"; exit 1; }

echo "== 6. Verdict: exactly 3 deps found (one per array element, each keeping its own current pin) =="
python3 - "$WORK/renovate.log" "${SHA[1.0.1]}" "${SHA[2.0.1]}" "${SHA[2.1.1]}" "$SHA_212" <<'PY'
import json, sys
log, sha_101, sha_201, sha_211, sha_212 = sys.argv[1:6]
text = open(log).read()
i = text.index("packageFiles with updates")
start = text.index("{", i)
depth, end = 0, start
for j in range(start, len(text)):
    depth += (text[j] == "{") - (text[j] == "}")
    if depth == 0:
        end = j + 1
        break
blob = json.loads(text[start:end])
deps = blob["regex"][0]["deps"]

ok = True
by_current = {d["currentValue"]: d for d in deps}
print(f"   found {len(deps)} deps (want 3): {sorted(by_current)}")
ok = ok and len(deps) == 3

# All three see the same new tag 2.1.2 is available -- Renovate's git-refs +
# semver versioning reports "a higher tag exists" per starting point, it has
# no notion of "stay within your own major/minor lineage" unless configured
# with a range constraint. That's the right behaviour for THIS design: the
# PR is the unit of debate (never automerged, ADR-0002) -- a human decides
# whether "1.0.1 has 2.1.2 available" means retire 1.0.x, add a new array
# element, or reject the PR outright. Renovate's job is only to surface it.
expect = {"1.0.1": sha_101, "2.0.1": sha_201, "2.1.1": sha_211}
for cur, want_digest in expect.items():
    d = by_current.get(cur)
    if d is None:
        print(f"   MISSING dep for currentValue={cur}"); ok = False; continue
    got_digest = d["currentDigest"]
    has_update = bool(d.get("updates"))
    new_value = d["updates"][0]["newValue"] if has_update else None
    good = got_digest == want_digest and has_update and new_value == "2.1.2"
    ok = ok and good
    print(f"   {cur}@{got_digest[:8]} -> {new_value}  {'OK' if good else 'FAIL'}")

sys.exit(0 if ok else 1)
PY
