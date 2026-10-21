#!/usr/bin/env python3
"""Record a component the build installs outside RPM, for the image's SBOM.

The SBOM CI publishes is syft's view of the image: it knows every RPM, but
a release tarball unpacked by a build script is only a pile of files to it
(review N9, 2026-10-20: the signed SBOM listed /usr/lib/margine/scrcpy/scrcpy
and no scrcpy package, so no version, licence or advisory could be matched).
Each such install calls this right after verifying what it downloaded, and
it writes /usr/share/margine/sbom/<name>.spdx.json: an SPDX 2.3 document
with the package (version, supplier, download URL and its sha256, licence,
purl, CPE) and the files it installed (sha1 and sha256 of each), so the
image also says on the device what it carries. CI merges these documents
into the published SBOM (.github/scripts/sbom-add-components.py), checking
each file's checksum against the image it describes.

Usage: sbom-component.py --name N --version V --supplier S --url U
         --sha256 H --license L --purl P [--cpe C] [--note T]
         [--out-dir D] [--root R] PATH...
PATHs are installed files or directories (taken whole), absolute, as on the
image; --root prefixes them when reading (tests).
"""
import argparse
import hashlib
import json
import os
import re
import sys


def digests(path):
    sha1, sha256 = hashlib.sha1(), hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            sha1.update(block)
            sha256.update(block)
    return sha1.hexdigest(), sha256.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    for opt in ("name", "version", "supplier", "url", "sha256", "license", "purl"):
        ap.add_argument(f"--{opt}", required=True)
    ap.add_argument("--cpe")
    ap.add_argument("--note", default="")
    ap.add_argument("--out-dir", default="/usr/share/margine/sbom")
    ap.add_argument("--root", default="/")
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args()

    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", a.name):
        sys.exit(f"sbom-component: bad name {a.name!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", a.sha256):
        sys.exit(f"sbom-component: --sha256 is not a sha256: {a.sha256!r}")

    files = []
    for p in a.paths:
        if not p.startswith("/"):
            sys.exit(f"sbom-component: {p}: paths are absolute, as on the image")
        real = os.path.join(a.root, p.lstrip("/"))
        if os.path.isdir(real) and not os.path.islink(real):
            for dp, dns, fns in os.walk(real):
                dns.sort()
                for fn in sorted(fns):
                    full = os.path.join(dp, fn)
                    if os.path.isfile(full) and not os.path.islink(full):
                        files.append("/" + os.path.relpath(full, a.root))
        elif os.path.isfile(real) and not os.path.islink(real):
            files.append(p)
        else:
            sys.exit(f"sbom-component: {p}: not an installed file or directory")
    if not files:
        sys.exit("sbom-component: no files to record")

    pkg_id = f"SPDXRef-Package-{a.name}"
    package = {
        "name": a.name,
        "SPDXID": pkg_id,
        "versionInfo": a.version,
        "supplier": a.supplier,
        "downloadLocation": a.url,
        "filesAnalyzed": False,
        "checksums": [{"algorithm": "SHA256", "checksumValue": a.sha256}],
        "licenseConcluded": a.license,
        "licenseDeclared": a.license,
        "copyrightText": "NOASSERTION",
        "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": a.purl}],
        "comment": ("Installed outside RPM by the Lucciola image build; the checksum is the downloaded "
                    "archive's, verified by the build. " + a.note).strip(),
    }
    if a.cpe:
        package["externalRefs"].append({"referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": a.cpe})
    spdx_files, rels = [], [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": pkg_id}]
    for i, f in enumerate(sorted(set(files)), 1):
        sha1, sha256 = digests(os.path.join(a.root, f.lstrip("/")))
        fid = f"SPDXRef-File-{a.name}-{i}"
        spdx_files.append({"fileName": f, "SPDXID": fid, "checksums": [
            {"algorithm": "SHA1", "checksumValue": sha1}, {"algorithm": "SHA256", "checksumValue": sha256}],
            "licenseConcluded": "NOASSERTION", "copyrightText": "NOASSERTION"})
        rels.append({"spdxElementId": pkg_id, "relationshipType": "CONTAINS", "relatedSpdxElement": fid})
    doc = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"lucciola-component-{a.name}",
        "documentNamespace": f"https://github.com/daniel-g-carrasco/lucciola/sbom/component/{a.name}-{a.version}-{a.sha256[:16]}",
        # Fixed, so the file changes only with what it describes (it is part
        # of an image layer); the published SBOM carries the real date.
        "creationInfo": {"created": "1970-01-01T00:00:00Z", "creators": ["Tool: lucciola-build-sbom-component"]},
        "packages": [package],
        "files": spdx_files,
        "relationships": rels,
    }
    out_dir = os.path.join(a.root, a.out_dir.lstrip("/"))
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{a.name}.spdx.json")
    with open(out, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(out, 0o644)
    print(f"sbom-component: {a.name} {a.version}, {len(spdx_files)} files -> {a.out_dir}/{a.name}.spdx.json")


if __name__ == "__main__":
    main()
