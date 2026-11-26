#!/usr/bin/env python3
"""A pull request that changes what the image is built from needs the vm-test label.

    build-inputs-need-vm-test.py --repo OWNER/NAME --pr NUMBER   (CI, through gh)
    build-inputs-need-vm-test.py --files LIST --labels a,b        (offline, tests)

Image changes need a maintainer-reviewed lab build and boot test. The label
marks those PRs for review, and label events re-run the static check.
This job neither publishes a PR image nor checks the lab result.

Exit 0: no build input changed, or the label is there. Exit 1: build inputs
changed, no label. Exit 2: usage, or GitHub could not be read.
"""
import argparse
import fnmatch
import json
import subprocess
import sys

LABEL = "vm-test"
# What the image is built from. Kept in step with build.yml's paths-ignore
# (tests/vm-test-gate.test.sh checks that nothing here is ignored there) and
# with Renovate's vm-test rule (.github/renovate.json5).
BUILD_INPUTS = (
    "Containerfile",
    "build_files/**",
    "lucciola/**",
    "installer/**",
    "disk_config/**",
    ".github/workflows/build.yml",
    ".github/scripts/validate-image-rootfs.sh",
    ".github/scripts/scan-image-security.py",
    ".github/security-baseline/**",
)


def is_build_input(path):
    for pattern in BUILD_INPUTS:
        if pattern.endswith("/**"):
            if path.startswith(pattern[:-2]):
                return True
        elif path == pattern or fnmatch.fnmatchcase(path, pattern):
            return True
    return False


def gh(args):
    r = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"::error::gh api {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def from_github(repo, pr):
    files = gh([f"repos/{repo}/pulls/{pr}/files", "--paginate",
                "--jq", ".[] | .filename, (.previous_filename // empty)"]).split()
    labels = json.loads(gh([f"repos/{repo}/pulls/{pr}", "--jq", "[.labels[].name]"]))
    return files, labels


def verdict(files, labels):
    """(exit status, message)."""
    touched = sorted({f for f in files if is_build_input(f)})
    if not touched:
        return 0, "No build input changed: the image does not need to be built for this pull request."
    if LABEL in labels:
        return 0, (f"Build inputs changed and the `{LABEL}` label is there. "
                   "Record the lab build and boot test in the pull request.\n  " + "\n  ".join(touched))
    return 1, (
        "This pull request changes files the image is built from:\n  " + "\n  ".join(touched) + "\n"
        f"A change there must be built and boot-tested before it merges. Add the label `{LABEL}` "
        "to the pull request and record the lab build and boot test before merging."
    )


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="OWNER/NAME, read through gh together with --pr")
    ap.add_argument("--pr", type=int)
    ap.add_argument("--files", help="file with one changed path per line (offline)")
    ap.add_argument("--labels", default="", help="comma-separated labels (offline)")
    a = ap.parse_args(argv)
    if a.repo and a.pr:
        files, labels = from_github(a.repo, a.pr)
    elif a.files:
        with open(a.files, encoding="utf-8") as f:
            files = [ln.strip() for ln in f if ln.strip()]
        labels = [x.strip() for x in a.labels.split(",") if x.strip()]
    else:
        ap.error("--repo with --pr, or --files")
    rc, msg = verdict(files, labels)
    print(msg)
    if rc:
        print(f"::error::build inputs changed without the {LABEL} label (see the step log for what to do)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
