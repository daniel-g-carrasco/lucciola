#!/usr/bin/env bash
# The security scan and the SBOM describe the image that is pushed and
# signed, not the one before chunking (review N3, 2026-10-20). Read from
# build.yml and build-fedora-kernel.yml as YAML, for each build_push job:
#   - one step loads the chunker's output, after the chunk step, and checks
#     the loaded image's ID against the config digest of its manifest;
#   - the kernel signature check, the security scan and the SBOM come after
#     it and read that image (and nothing reads the pre-chunk image after
#     the chunk step);
#   - the push step gets the scanned config and refuses a registry manifest
#     with another one, and comes after the scan and the SBOM;
#   - the sign job still signs the pushed digest and still runs on main
#     (its condition is not the implicit success()).
# PyYAML is needed (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc=0
python3 - "$ROOT/.github/workflows/build.yml" "$ROOT/.github/workflows/build-fedora-kernel.yml" > "$T/out" 2>&1 <<'PY' || rc=$?
import re, sys, yaml
bad = []
for path in sys.argv[1:]:
    wf = yaml.safe_load(open(path))
    name = path.rsplit("/", 1)[-1]
    steps = wf["jobs"]["build_push"]["steps"]
    def idx(pred, what):
        hits = [i for i, s in enumerate(steps) if pred(s)]
        if len(hits) != 1:
            bad.append(f"{name}: {len(hits)} steps for {what}")
            return None
        return hits[0]
    text = lambda s: (s.get("run") or "") + "\n" + "\n".join(f"{k}={v}" for k, v in (s.get("env") or {}).items())
    chunk = idx(lambda s: s.get("id") == "rechunk", "the chunk step")
    load = idx(lambda s: s.get("id") == "chunked", "loading the chunked image")
    kern = idx(lambda s: "sbverify" in (s.get("run") or "") and "steps.chunked.outputs.image" in (s.get("run") or ""), "the kernel check on the chunked image")
    scan = idx(lambda s: "scan-image-security.py" in (s.get("run") or ""), "the security scan")
    sbom = idx(lambda s: "syft" in (s.get("run") or "") and "spdx-json" in (s.get("run") or ""), "the SBOM")
    push = idx(lambda s: s.get("id") == "push", "the push")
    if None in (chunk, load, kern, scan, sbom, push):
        continue
    if not chunk < load < kern < push:
        bad.append(f"{name}: order chunk {chunk} < load {load} < kernel check {kern} < push {push} broken")
    for what, i in (("security scan", scan), ("SBOM", sbom)):
        if not load < i < push:
            bad.append(f"{name}: the {what} (step {i}) is not between loading the chunked image ({load}) and the push ({push})")
        if "steps.chunked.outputs.image" not in text(steps[i]):
            bad.append(f"{name}: the {what} does not read steps.chunked.outputs.image")
    lt = steps[load].get("run") or ""
    for needle in (".config.digest", "podman image inspect", '"$ID" = "$CONFIG"'):
        if needle not in lt:
            bad.append(f"{name}: loading the chunked image lacks {needle!r}")
    # After chunking, nothing reads the pre-chunk image.
    for s in steps[chunk + 1:]:
        t = text(s)
        if re.search(r'"\$SRC"|localhost/\$\{\{ env\.IMAGE_NAME \}\}:\$\{\{ steps\.metadata', t) and "podman rmi" not in t:
            bad.append(f"{name}: step '{s.get('name')}' reads the pre-chunk image after chunking")
    pt = text(steps[push])
    if "SCANNED_CONFIG=${{ steps.chunked.outputs.config }}" not in pt or '.config.digest' not in pt:
        bad.append(f"{name}: the push does not compare the pushed config with the scanned one")
    sign = wf["jobs"]["sign"]
    if "needs.build_push.outputs.image_ref" not in yaml.safe_dump(sign["steps"]):
        bad.append(f"{name}: the sign job does not sign build_push's pushed digest")
    if "!cancelled()" not in str(sign.get("if", "")):
        bad.append(f"{name}: the sign job lost its explicit condition (main would skip it)")
    io = wf["jobs"]["build_push"].get("outputs", {})
    if "steps.push.outputs.image_ref" not in str(io.get("image_ref", "")):
        bad.append(f"{name}: image_ref no longer comes from the push step")
print("\n".join(bad) or "scan and SBOM read what ships")
sys.exit(1 if bad else 0)
PY
cat "$T/out"
[ "$rc" = 0 ] && echo "scan-what-ships: all checks passed" || { echo "scan-what-ships: failed"; exit 1; }
