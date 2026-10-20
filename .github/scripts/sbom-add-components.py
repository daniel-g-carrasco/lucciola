#!/usr/bin/env python3
"""Add the components the build installed outside RPM to syft's SBOM.

syft sees RPMs; a release tarball a build script unpacked is only files to
it (review N9, 2026-10-20: scrcpy shipped with no package in the signed
SBOM). The build records each such component in the image, as an SPDX
document under /usr/share/margine/sbom/ (build_files/sbom-component.py).
This merges them into the SBOM syft wrote for the same image:

  - each component package is added with everything the build recorded
    (version, supplier, download URL and the archive's sha256, licence,
    purl, CPE), CONTAINed by the document root syft describes;
  - each of its files is linked to syft's entry for the same path
    (package CONTAINS file), or added when syft has none;
  - every file's sha256 is checked against the image (--rootfs): a record
    that does not match what ships is refused, not published;
  - --require NAME fails when a component that must be there is missing.

Usage: sbom-add-components.py --rootfs DIR --sbom FILE [--require NAME]...
The SBOM is rewritten in place.
"""
import argparse
import glob
import hashlib
import json
import os
import sys

FRAGMENTS = "usr/share/margine/sbom"


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rootfs", required=True)
    ap.add_argument("--sbom", required=True)
    ap.add_argument("--require", action="append", default=[])
    a = ap.parse_args()

    sbom = json.load(open(a.sbom))
    packages = sbom.setdefault("packages", [])
    files = sbom.setdefault("files", [])
    rels = sbom.setdefault("relationships", [])
    ids = {p["SPDXID"] for p in packages} | {f["SPDXID"] for f in files}
    by_name = {}
    for f in files:
        by_name.setdefault("/" + f["fileName"].removeprefix("./").lstrip("/"), f["SPDXID"])
    roots = [r["relatedSpdxElement"] for r in rels
             if r.get("spdxElementId") == "SPDXRef-DOCUMENT" and r.get("relationshipType") == "DESCRIBES"]
    if len(roots) != 1:
        sys.exit(f"sbom-add-components: expected one element the SBOM describes, found {roots}")
    root = roots[0]

    errors, added = [], []
    for frag in sorted(glob.glob(os.path.join(a.rootfs, FRAGMENTS, "*.spdx.json"))):
        doc = json.load(open(frag))
        local = {}
        for f in doc.get("files", []):
            name = f["fileName"]
            real = os.path.join(a.rootfs, name.lstrip("/"))
            want = next((c["checksumValue"] for c in f.get("checksums", []) if c["algorithm"] == "SHA256"), None)
            if not os.path.isfile(real) or os.path.islink(real):
                errors.append(f"{os.path.basename(frag)}: {name} is not in the image")
                continue
            if sha256_of(real) != want:
                errors.append(f"{os.path.basename(frag)}: {name} in the image is not the file recorded")
                continue
            if name in by_name:
                local[f["SPDXID"]] = by_name[name]
            else:
                new = dict(f, SPDXID=f"SPDXRef-Lucciola-{f['SPDXID'].removeprefix('SPDXRef-')}")
                files.append(new)
                ids.add(new["SPDXID"])
                local[f["SPDXID"]] = new["SPDXID"]
        for p in doc.get("packages", []):
            if any(q.get("name") == p["name"] and q.get("versionInfo") == p.get("versionInfo") for q in packages):
                continue
            new_id = f"SPDXRef-Lucciola-{p['SPDXID'].removeprefix('SPDXRef-')}"
            if new_id in ids:
                errors.append(f"{os.path.basename(frag)}: SPDXID {new_id} already in the SBOM")
                continue
            packages.append(dict(p, SPDXID=new_id))
            ids.add(new_id)
            local[p["SPDXID"]] = new_id
            rels.append({"spdxElementId": root, "relationshipType": "CONTAINS", "relatedSpdxElement": new_id})
            added.append(f"{p['name']} {p.get('versionInfo', '')}")
        for r in doc.get("relationships", []):
            if r.get("relationshipType") != "CONTAINS":
                continue
            s, o = local.get(r["spdxElementId"]), local.get(r["relatedSpdxElement"])
            if s and o:
                rels.append({"spdxElementId": s, "relationshipType": "CONTAINS", "relatedSpdxElement": o})

    names = {p.get("name") for p in packages}
    for req in a.require:
        if req not in names:
            errors.append(f"required component {req} is not in the SBOM (no {FRAGMENTS}/{req}.spdx.json in the image?)")
    if errors:
        for e in errors:
            print(f"::error::{e}")
        return 1
    with open(a.sbom, "w") as f:
        json.dump(sbom, f, indent=1)
        f.write("\n")
    print(f"sbom-add-components: added {', '.join(added) or 'nothing'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
