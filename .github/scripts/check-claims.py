#!/usr/bin/env python3
"""The security claims register names real proofs, and no test is an orphan.

    check-claims.py [--root DIR] [--register docs/SECURITY-CLAIMS.md]

docs/SECURITY-CLAIMS.md is a table of promises with a Proof column. A row
whose Status is `verified` or `partial` claims that a check fails when the
promise breaks; this lint makes that claim concrete: the Proof cell must
name at least one thing that exists in the tree (a path in `backticks`: a
test under tests/, a script, a policy file, a directory) or a workflow
step or job by its name: in "double quotes", and every path it names must
exist. A row that names only words ("the image scan", "smoke `mok-key`")
is not a proof. Rows with any other status (unverified, limitation,
pending merge) are listed by the monthly review instead.

And the other way round: every test file under tests/ (*.sh, *.py) must be
run by lint.yml or mutation.yml, directly or through a test they run; a
test nobody runs proves nothing.

Exit 0 when the register and the tests agree with the tree, 1 otherwise.
"""
import argparse
import glob
import os
import re
import sys

import yaml

PROOF_STATUSES = ("verified", "partial")
PATH_SUFFIXES = (".sh", ".py", ".yml", ".yaml", ".txt", ".toml", ".md", ".json", ".conf", ".service")


def tables(text):
    """{section title: [row dicts]} for every markdown table under a ## heading
    (the same reading as security-review-report.py)."""
    out, section, header = {}, None, None
    for line in text.splitlines():
        if line.startswith("## "):
            section, header = line[3:].strip(), None
            continue
        if not line.startswith("|"):
            header = None if not line.strip() else header
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if header is None:
            header = cells
        elif set(line.replace("|", "").strip()) <= set("-: "):
            continue
        else:
            out.setdefault(section, []).append(dict(zip(header, cells)))
    return out


def workflow_names(root):
    names = set()
    for path in glob.glob(os.path.join(root, ".github", "workflows", "*.yml")):
        with open(path, encoding="utf-8") as f:
            wf = yaml.safe_load(f) or {}
        for job_id, job in (wf.get("jobs") or {}).items():
            names.add(job_id)
            if job.get("name"):
                names.add(str(job["name"]))
            for step in job.get("steps") or []:
                if step.get("name"):
                    names.add(str(step["name"]))
    return names


HOST_RE = re.compile(r"^[a-z0-9-]+\.[a-z]{2,}/")


def is_pathlike(token):
    """A path in the tree, as opposed to an image reference (ghcr.io/...),
    an ellipsis (.../margine) or a plain word."""
    if HOST_RE.match(token) or token.startswith("..."):
        return False
    return "/" in token or token.endswith(PATH_SUFFIXES)


def exists(root, token):
    t = token.rstrip("/")
    if os.path.exists(os.path.join(root, t)):
        return True
    # A workflow by its file name alone (build.yml), as the register writes it.
    return "/" not in t and t.endswith((".yml", ".yaml")) and os.path.exists(
        os.path.join(root, ".github", "workflows", t))


def check_register(root, register):
    problems = []
    with open(register, encoding="utf-8") as f:
        text = f.read()
    names = workflow_names(root)
    rel = os.path.relpath(register, root)
    for section, rows in tables(text).items():
        for row in rows:
            status = row.get("Status", "").strip().lower()
            if "Proof" not in row or not status.startswith(PROOF_STATUSES):
                continue
            rid = row.get("ID", "?")
            proof = row["Proof"]
            paths = [t for t in re.findall(r"`([^`]+)`", proof) if is_pathlike(t)]
            quoted = re.findall(r'"([^"]+)"|“([^”]+)”', proof)
            quoted = [a or b for a, b in quoted]
            good = 0
            for t in paths:
                if exists(root, t):
                    good += 1
                else:
                    problems.append(f"{rel}: {rid} ({section}) names `{t}`, which is not in the tree")
            for q in quoted:
                if q in names:
                    good += 1
                else:
                    problems.append(f'{rel}: {rid} ({section}) names the step or job "{q}", '
                                    "which no workflow has")
            if not good:
                problems.append(f"{rel}: {rid} ({section}) is {status.split(',')[0]} but its proof names no path "
                                "in the tree and no workflow step: say which test, script or step proves it")
    return problems


def check_orphans(root):
    tests_dir = os.path.join(root, "tests")
    tests = sorted(
        os.path.relpath(p, root) for p in glob.glob(os.path.join(tests_dir, "**", "*"), recursive=True)
        if os.path.isfile(p) and p.endswith((".sh", ".py")))
    runners = []
    for name in ("lint.yml", "mutation.yml"):
        path = os.path.join(root, ".github", "workflows", name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as f:
                runners.append(f.read())
    runner_text = "\n".join(runners)
    wired = {t for t in tests if t in runner_text}
    # A test a wired test runs (staleness.test.sh runs staleness.test.py) is wired too.
    changed = True
    while changed:
        changed = False
        for t in wired.copy():
            with open(os.path.join(root, t), encoding="utf-8", errors="replace") as f:
                body = f.read()
            for other in tests:
                if other not in wired and (other in body or os.path.basename(other) in body):
                    wired.add(other)
                    changed = True
    return [f"{t} is run by neither lint.yml nor mutation.yml (nor by a test they run): wire it or remove it"
            for t in tests if t not in wired]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--register")
    a = ap.parse_args(argv)
    register = a.register or os.path.join(a.root, "docs", "SECURITY-CLAIMS.md")
    problems = check_register(a.root, register) + check_orphans(a.root)
    for p in problems:
        print(f"::error::{p}")
    if problems:
        print(f"claims register: {len(problems)} problem(s)")
        return 1
    print("claims register: every verified or partial claim names a proof in the tree; every test is run")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
