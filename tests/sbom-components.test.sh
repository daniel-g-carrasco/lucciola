#!/usr/bin/env bash
# Components installed outside RPM reach the published SBOM (review N9,
# 2026-10-20), on a fake rootfs and a minimal syft-like SBOM:
#   - build_files/sbom-component.py records scrcpy (name, version, supplier,
#     download URL, the archive's sha256, licence, purl, CPE, every file
#     with sha1 and sha256);
#   - .github/scripts/sbom-add-components.py adds it to the SBOM: package
#     with all of that, CONTAINed by the described root, linked to syft's
#     entry for a file it already lists, adding the others;
#   - it refuses a record whose file no longer matches the image, and a
#     required component that is missing;
#   - the build records scrcpy and both workflows merge with --require scrcpy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRITE="$ROOT/build_files/sbom-component.py"
MERGE="$ROOT/.github/scripts/sbom-add-components.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 20 || true; fails=$((fails+1)); fi
}

R="$T/rootfs"
mkdir -p "$R/usr/lib/margine/scrcpy"
printf 'ELF stand-in' > "$R/usr/lib/margine/scrcpy/scrcpy"
printf 'server' > "$R/usr/lib/margine/scrcpy/scrcpy-server"
SHA="$(printf '9%.0s' {1..64})"
RC=0
python3 "$WRITE" --root "$R" --name scrcpy --version 5.0.1 --supplier "Organization: Genymobile" \
  --url https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-linux-x86_64-v5.0.1.tar.gz \
  --sha256 "$SHA" --license Apache-2.0 --purl pkg:github/Genymobile/scrcpy@v5.0.1 \
  --cpe "cpe:2.3:a:genymobile:scrcpy:5.0.1:*:*:*:*:*:*:*" /usr/lib/margine/scrcpy > "$T/out" 2>&1 || RC=$?
check "component recorded (rc $RC)" test -s "$R/usr/share/margine/sbom/scrcpy.spdx.json"

# A syft-like SBOM that already lists one of the two files.
cat > "$T/sbom.json" <<'JSON'
{"spdxVersion": "SPDX-2.3", "SPDXID": "SPDXRef-DOCUMENT", "name": "img",
 "packages": [{"name": "/rootfs", "SPDXID": "SPDXRef-DocumentRoot-Directory-rootfs"},
              {"name": "bash", "SPDXID": "SPDXRef-Package-rpm-bash", "versionInfo": "5.3"}],
 "files": [{"fileName": "/usr/lib/margine/scrcpy/scrcpy", "SPDXID": "SPDXRef-File-syft-1"}],
 "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                    "relatedSpdxElement": "SPDXRef-DocumentRoot-Directory-rootfs"}]}
JSON
cp "$T/sbom.json" "$T/s1.json"
RC=0; python3 "$MERGE" --rootfs "$R" --sbom "$T/s1.json" --require scrcpy > "$T/out" 2>&1 || RC=$?
check "merged (rc $RC)" [ "$RC" = 0 ]
python3 - "$T/s1.json" "$SHA" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import json, sys
d = json.load(open(sys.argv[1])); sha = sys.argv[2]
bad = []
pk = [p for p in d["packages"] if p["name"] == "scrcpy"]
if len(pk) != 1:
    sys.exit(f"{len(pk)} scrcpy packages")
p = pk[0]
want = {"versionInfo": "5.0.1", "supplier": "Organization: Genymobile", "licenseDeclared": "Apache-2.0",
        "downloadLocation": "https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-linux-x86_64-v5.0.1.tar.gz"}
bad += [f"{k}={p.get(k)!r}" for k, v in want.items() if p.get(k) != v]
if {"algorithm": "SHA256", "checksumValue": sha} not in p.get("checksums", []):
    bad.append("archive sha256 missing")
refs = {r["referenceType"]: r["referenceLocator"] for r in p.get("externalRefs", [])}
if refs.get("purl") != "pkg:github/Genymobile/scrcpy@v5.0.1" or not refs.get("cpe23Type", "").startswith("cpe:2.3:a:genymobile:scrcpy:5.0.1"):
    bad.append(f"refs {refs}")
rel = {(r["spdxElementId"], r["relationshipType"], r["relatedSpdxElement"]) for r in d["relationships"]}
if ("SPDXRef-DocumentRoot-Directory-rootfs", "CONTAINS", p["SPDXID"]) not in rel:
    bad.append("root does not CONTAIN the package")
if (p["SPDXID"], "CONTAINS", "SPDXRef-File-syft-1") not in rel:
    bad.append("package not linked to syft's entry for the binary")
server = [f for f in d["files"] if f["fileName"] == "/usr/lib/margine/scrcpy/scrcpy-server"]
if len(server) != 1 or (p["SPDXID"], "CONTAINS", server[0]["SPDXID"]) not in rel:
    bad.append("file syft did not list is not added and linked")
if len([f for f in d["files"] if f["fileName"] == "/usr/lib/margine/scrcpy/scrcpy"]) != 1:
    bad.append("the binary is listed twice")
ids = [x["SPDXID"] for x in d["packages"] + d["files"]]
if len(ids) != len(set(ids)):
    bad.append("duplicate SPDXIDs")
print("\n".join(bad) or "ok")
sys.exit(1 if bad else 0)
PY
check "SBOM: scrcpy with version, supplier, URL, sha256, licence, purl, CPE and its files" [ "$RC" = 0 ]

cp "$T/sbom.json" "$T/s2.json"
printf 'changed' > "$R/usr/lib/margine/scrcpy/scrcpy-server"
RC=0; python3 "$MERGE" --rootfs "$R" --sbom "$T/s2.json" > "$T/out" 2>&1 || RC=$?
check "a record that does not match the image is refused (rc $RC)" bash -c "[ '$RC' = 1 ] && cmp -s '$T/s2.json' '$T/sbom.json'"
rm -rf "$R/usr/share/margine/sbom"
cp "$T/sbom.json" "$T/s3.json"
RC=0; python3 "$MERGE" --rootfs "$R" --sbom "$T/s3.json" --require scrcpy > "$T/out" 2>&1 || RC=$?
check "a missing required component fails (rc $RC)" [ "$RC" = 1 ]
RC=0; python3 "$WRITE" --root "$R" --name scrcpy --version 1 --supplier x --url x --sha256 short \
  --license x --purl x /usr/lib/margine/scrcpy > "$T/out" 2>&1 || RC=$?
check "the writer refuses a checksum that is not a sha256 (rc $RC)" [ "$RC" != 0 ]

# The build and the workflows use them.
grep -q 'python3 /ctx/sbom-component.py --name scrcpy' "$ROOT/build_files/70-phone-cam/install.sh" > "$T/out" 2>&1 && RC=0 || RC=1
check "70-phone-cam records scrcpy" [ "$RC" = 0 ]
for wf in build.yml build-fedora-kernel.yml; do
  grep -q 'sbom-add-components.py --rootfs "$ROOTFS"' "$ROOT/.github/workflows/$wf" \
    && grep -q -- '--sbom sbom.spdx.json --require scrcpy' "$ROOT/.github/workflows/$wf" > "$T/out" 2>&1 && RC=0 || RC=1
  check "$wf merges the components (scrcpy required)" [ "$RC" = 0 ]
done

[ "$fails" = 0 ] && echo "sbom-components: all checks passed" || { echo "sbom-components: $fails failed"; exit 1; }
