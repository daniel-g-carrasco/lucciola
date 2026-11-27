#!/usr/bin/env python3
"""Rescan the signed inventories of published Lucciola images with Grype."""
import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO = "ghcr.io/daniel-g-carrasco/lucciola"
KEY = ROOT / "secrets/cosign.pub"
SPDX_ARTIFACT = "application/vnd.spdx+json"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
RETAINED_TAGS = 2  # per channel, plus the current channel pointer


def command(*args):
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=180).stdout
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {exc.stderr.strip()}") from exc


def read_json(*args):
    return json.loads(command(*args))


def published_digests(reserve):
    channels = ("stable", reserve)
    available = command("oras", "repo", "tags", REPO).splitlines()
    tags = list(channels)
    for channel in channels:
        dated = sorted((tag for tag in available if re.fullmatch(rf"{re.escape(channel)}\.[0-9]{{8}}", tag)),
                       reverse=True)
        tags.extend(dated[:RETAINED_TAGS])
    pinned = {}
    for tag in tags:
        try:
            digest = command("oras", "resolve", f"{REPO}:{tag}").strip()
            if not DIGEST.fullmatch(digest):
                raise ValueError("registry did not return a SHA-256 digest")
        except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            # Keep scanning the other images, but make incomplete coverage visible.
            print(f"- {tag}: could not resolve digest ({exc})", flush=True)
            pinned.setdefault(None, []).append(tag)
            continue
        pinned.setdefault(digest, []).append(tag)
    return pinned


def fetch_sbom(digest, dest):
    """Accept only an image signature and a signed, directly attached SPDX inventory."""
    ref = f"{REPO}@{digest}"
    command("cosign", "verify", "--key", str(KEY), "--new-bundle-format=false", ref)
    found = read_json("oras", "discover", "--artifact-type", SPDX_ARTIFACT, "--format", "json", "--depth", "1", ref)
    errors = []
    for descriptor in found["referrers"]:
        artifact_digest = descriptor["digest"]
        if descriptor.get("artifactType") != SPDX_ARTIFACT or not DIGEST.fullmatch(artifact_digest):
            continue
        artifact = f"{REPO}@{artifact_digest}"
        try:
            manifest = read_json("oras", "manifest", "fetch", artifact)
            layers = manifest.get("layers", [])
            if (manifest.get("subject", {}).get("digest") != digest
                    or manifest.get("artifactType") != SPDX_ARTIFACT
                    or len(layers) != 1 or layers[0].get("mediaType") != "application/spdx+json"
                    or not DIGEST.fullmatch(layers[0].get("digest", ""))):
                raise RuntimeError("SPDX manifest has the wrong subject or content")
            command("cosign", "verify", "--key", str(KEY), artifact)
            command("oras", "blob", "fetch", f"{REPO}@{layers[0]['digest']}", "--output", str(dest))
            return
        except (RuntimeError, subprocess.TimeoutExpired, ValueError) as exc:
            errors.append(str(exc))
    raise RuntimeError(f"no valid signed SPDX inventory for {ref}: {'; '.join(errors) or 'no referrer'}")


def high_advisories(data):
    found = set()
    for match in data["matches"]:
        vulnerability = match["vulnerability"]
        severity, advisory = vulnerability["severity"], vulnerability["id"]
        if severity in {"Critical", "High"}:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:+-]*", advisory):
                raise ValueError("invalid advisory identifier in Grype report")
            found.add((severity, advisory))
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--digest", help="scan one retained Lucciola manifest by SHA-256")
    args = parser.parse_args()
    if args.digest and not DIGEST.fullmatch(args.digest):
        parser.error("--digest must be sha256: followed by 64 lower-case hex characters")

    print("## Published Lucciola advisory scan", flush=True)
    try:
        reserve = (ROOT / "build_files/system_files/usr/share/margine/kernel-reserve-tag").read_text().splitlines()[0]
        refs = {args.digest: ["requested digest"]} if args.digest else published_digests(reserve)
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
        print(f"Could not list published images: {exc}")
        return 1
    failed = None in refs
    for digest, tags in refs.items():
        if digest is None:
            continue
        print(f"\n### {', '.join(tags)}\n\n{REPO}@{digest}\n", flush=True)
        try:
            with tempfile.TemporaryDirectory() as work:
                sbom = Path(work) / "sbom.spdx.json"
                fetch_sbom(digest, sbom)
                advisories = high_advisories(read_json("grype", f"sbom:{sbom}", "-o", "json"))
        except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
            print(f"No scan verdict: {exc}")
            failed = True
            continue
        if advisories:
            failed = True
            for severity, advisory in advisories:
                print(f"- {severity}: {advisory}")
        else:
            print("No High or Critical matches in Grype's database.")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
