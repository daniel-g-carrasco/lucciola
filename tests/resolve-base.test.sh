#!/usr/bin/env bash
# The base image is resolved once and the build uses the digest it records
# (review R9, 2026-10-20). Two parts:
#   - .github/scripts/resolve-base.sh against a fake skopeo: what it prints
#     for each kind of reference, and that a failed or odd lookup stops it;
#   - build.yml, read as YAML: the build's BASE_IMAGE, the base.digest and
#     base.name labels (before and after chunking) all come from that one
#     step, which cannot be skipped over on error, and nothing else looks
#     the base up again.
# PyYAML is needed for the second part (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/.github/scripts/resolve-base.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
D1="sha256:$(printf 'a%.0s' {1..64})"
D2="sha256:$(printf 'b%.0s' {1..64})"
mkdir -p "$T/bin"
# skopeo stub: prints $FAKE_DIGEST, or fails when FAKE_FAIL is set.
cat > "$T/bin/skopeo" <<'STUB'
#!/bin/sh
[ -n "${FAKE_FAIL:-}" ] && { echo "manifest unknown" >&2; exit 1; }
echo "$FAKE_DIGEST"
STUB
chmod +x "$T/bin/skopeo"
resolve() {  # resolve <ref> ; sets RC, output in $T/out
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE_DIGEST="${FAKE_DIGEST-$D1}" FAKE_FAIL="${FAKE_FAIL:-}" \
    bash "$SCRIPT" "$1" > "$T/out" 2>&1 || RC=$?
}
has() { grep -qxF "$1" "$T/out"; }

resolve ghcr.io/ublue-os/silverblue-main:45
check "tag: resolved"                     [ "$RC" = 0 ]
check "tag: name is the reference"        has "name=ghcr.io/ublue-os/silverblue-main:45"
check "tag: digest recorded"              has "digest=$D1"
check "tag: the build is FROM that digest" has "base=ghcr.io/ublue-os/silverblue-main@$D1"
resolve localhost:5000/lab/base:44
check "registry with a port: only the tag is dropped" has "base=localhost:5000/lab/base@$D1"
resolve quay.io/fedora/fedora-bootc
check "no tag: the repository as is"      has "base=quay.io/fedora/fedora-bootc@$D1"
FAKE_DIGEST="$D2" resolve "ghcr.io/x/base:45@$D1"
check "a reference with a digest keeps that digest" has "base=ghcr.io/x/base@$D1"
FAKE_FAIL=1 resolve ghcr.io/ublue-os/silverblue-main:45
check "registry error: no build (rc $RC)" [ "$RC" = 1 ]
check "registry error: nothing for GITHUB_OUTPUT" bash -c "! grep -q '^base=' '$T/out'"
FAKE_DIGEST="" resolve ghcr.io/ublue-os/silverblue-main:45
check "empty digest: no build (rc $RC)"   [ "$RC" = 1 ]
FAKE_DIGEST="sha256:abc" resolve ghcr.io/ublue-os/silverblue-main:45
check "malformed digest: no build (rc $RC)" [ "$RC" = 1 ]

# --- build.yml uses it, and only it
python3 - "$ROOT/.github/workflows/build.yml" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = wf["jobs"]["build_push"]["steps"]
byid = {s.get("id"): s for s in steps if s.get("id")}
bad = []
base = byid.get("base")
if not base or "resolve-base.sh" not in base.get("run", ""):
    bad.append("the base step does not run resolve-base.sh")
elif base.get("continue-on-error"):
    bad.append("the base step may fail without stopping the build")
build = byid.get("build_image", {}).get("run", "")
if 'BASE_IMAGE="${{ steps.base.outputs.base }}"' not in build:
    bad.append("buildah is not given steps.base.outputs.base")
meta = byid.get("metadata", {}).get("with", {}).get("labels", "")
for want in ("org.opencontainers.image.base.digest=${{ steps.base.outputs.digest }}",
             "org.opencontainers.image.base.name=${{ steps.base.outputs.name }}"):
    if want not in meta:
        bad.append(f"metadata label missing: {want}")
chunk = [s for s in steps if "org.opencontainers.image.base.digest=${BASE_DIGEST}" in s.get("run", "")]
if len(chunk) != 1:
    bad.append("no single chunking step that stamps base.digest")
else:
    env = chunk[0].get("env", {})
    if env.get("BASE_DIGEST") != "${{ steps.base.outputs.digest }}" or env.get("BASE_NAME") != "${{ steps.base.outputs.name }}":
        bad.append(f"chunking labels come from elsewhere: {env.get('BASE_DIGEST')} {env.get('BASE_NAME')}")
for s in steps:
    if s is not base and "skopeo inspect" in s.get("run", "") and "BASE" in s.get("run", "") and "base" in s.get("name", "").lower():
        bad.append(f"step '{s.get('name')}' looks the base up again")
print("\n".join(bad) or "build.yml: one resolution, used everywhere")
sys.exit(1 if bad else 0)
PY
check "build.yml: build and labels use the one resolved digest" [ "$RC" = 0 ]

if (( fails )); then echo "$fails resolve-base case(s) failed"; exit 1; fi
echo "all resolve-base cases passed"
