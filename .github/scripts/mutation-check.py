#!/usr/bin/env python3
"""Break a guard on purpose and see its check fail.

    mutation-check.py [--check] [--list] [--only NAME ...] [--tag TAG]
                      [--exclude-tag TAG] [--timeout SECONDS] [--keep]
                      [FILE.toml ...]

A check that cannot fail gives assurance it does not provide: the two
reviews of 2026-10-20 found guards whose tests stayed green with the guard
removed (the content editor's key, the greeter's hand-over, the MOK secret
scope). Every file in tests/mutants/ describes one deliberate breakage of
one guard, and the check that must notice it:

    name = "scanner-prints-token"
    file = ".github/scripts/scan-image-security.py"
    old = 'return b"access token"'      # must occur exactly once in file
    new = 'return m.group(0)'
    must_fail = "bash tests/scan-image-security.test.sh"   # from the repo root
    tags = ["fedora"]                   # optional: where the check can run
    env = { FLATPAK_TEST_REQUIRED = "1" }   # optional, for must_fail

For each mutant the tracked tree is copied to a temporary directory (the
working tree, uncommitted edits included, so a developer tests what they
see), the check is run once unchanged, then the mutant is applied and the
check run again. Verdicts:

    killed    the check passes unmutated and fails on the mutant: the guard
              is tested;
    survived  the check passes on the mutant too: the guard is not tested,
              which is a real gap, so add the missing assertion (never drop
              the mutant);
    broken    `old` is not found exactly once, the file is not tracked, the
              check fails before the mutation, or it times out: the mutant
              needs an update (a guard moved), or the check is red anyway.

Exit 0 only when every selected mutant is killed. The check runs with the
system PATH first (/usr/bin:/bin): a virtualenv's python3 must not stand in
for the one CI uses. --check applies every mutant to the copy without
running anything (old found once, file tracked): lint runs that on every
pull request, so a mutant cannot rot unnoticed until the weekly run.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

import tomllib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MUTANTS_DIR = os.path.join(ROOT, "tests", "mutants")
REQUIRED = {"name": str, "file": str, "old": str, "new": str, "must_fail": str}
OPTIONAL = {"tags": list, "env": dict}


class Broken(Exception):
    pass


def load(path):
    with open(path, "rb") as f:
        data = tomllib.load(f)
    for key, kind in REQUIRED.items():
        # `new` may be empty: removing a line is a mutation like any other.
        if not isinstance(data.get(key), kind) or (kind is str and key != "new" and not data[key]):
            raise Broken(f"{path}: '{key}' must be a non-empty {kind.__name__}")
    for key, kind in OPTIONAL.items():
        if key in data and not isinstance(data[key], kind):
            raise Broken(f"{path}: '{key}' must be a {kind.__name__}")
    unknown = set(data) - set(REQUIRED) - set(OPTIONAL)
    if unknown:
        raise Broken(f"{path}: unknown key(s) {', '.join(sorted(unknown))}")
    if data["old"] == data["new"]:
        raise Broken(f"{path}: old and new are the same")
    data["path"] = path
    return data


def tracked_files():
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p.decode() for p in out.split(b"\0") if p]


def copy_tree(dest):
    """The tracked files as they are in the working tree, in a fresh git
    repository of their own (tests use git ls-files and git grep)."""
    for rel in tracked_files():
        src = os.path.join(ROOT, rel)
        dst = os.path.join(dest, rel)
        if not os.path.lexists(src):
            continue  # tracked but deleted in the working tree
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(src):
            os.symlink(os.readlink(src), dst)
        else:
            shutil.copy2(src, dst)
    git = ["git", "-C", dest, "-c", "user.name=mutation-check", "-c", "user.email=mutation-check@localhost",
           "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "copy of the working tree"], check=True)


def run_check(mutant, copy, timeout):
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin:" + env.get("PATH", "")
    env.update({str(k): str(v) for k, v in mutant.get("env", {}).items()})
    t0 = time.monotonic()
    try:
        r = subprocess.run(["bash", "-c", mutant["must_fail"]], cwd=copy, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        return None, (e.output or b"").decode(errors="replace"), time.monotonic() - t0
    return r.returncode, r.stdout.decode(errors="replace"), time.monotonic() - t0


def apply(mutant, copy, tracked):
    rel = mutant["file"]
    if rel not in tracked:
        raise Broken(f"{rel} is not a tracked file")
    path = os.path.join(copy, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    n = text.count(mutant["old"])
    if n != 1:
        raise Broken(f"'old' occurs {n} times in {rel}, not once")
    mutated = text.replace(mutant["old"], mutant["new"])
    with open(path, "w", encoding="utf-8") as f:
        f.write(mutated)
    return text


def restore(copy, rel, text):
    with open(os.path.join(copy, rel), "w", encoding="utf-8") as f:
        f.write(text)


def tail(text, n=15):
    lines = text.rstrip().splitlines()
    return "\n".join("      | " + ln for ln in lines[-n:])


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="mutant files (default: tests/mutants/*.toml)")
    ap.add_argument("--check", action="store_true", help="apply every mutant, run nothing")
    ap.add_argument("--list", action="store_true", help="list the selected mutants")
    ap.add_argument("--only", action="append", default=[], metavar="NAME")
    ap.add_argument("--tag", action="append", default=[], metavar="TAG", help="only mutants with this tag")
    ap.add_argument("--exclude-tag", action="append", default=[], metavar="TAG")
    ap.add_argument("--timeout", type=int, default=900, help="seconds per check run (default 900)")
    ap.add_argument("--keep", action="store_true", help="keep the temporary copy")
    a = ap.parse_args(argv)

    files = a.files or sorted(
        os.path.join(MUTANTS_DIR, f) for f in os.listdir(MUTANTS_DIR) if f.endswith(".toml"))
    mutants, broken = [], []
    for path in files:
        try:
            mutants.append(load(path))
        except (Broken, tomllib.TOMLDecodeError, OSError) as e:
            broken.append((os.path.basename(path), str(e)))
    names = [m["name"] for m in mutants]
    for name in set(names):
        if names.count(name) > 1:
            broken.append((name, "mutant name used twice"))
    if a.only:
        mutants = [m for m in mutants if m["name"] in a.only]
        missing = set(a.only) - {m["name"] for m in mutants}
        for name in sorted(missing):
            broken.append((name, "no such mutant"))
    if a.tag:
        mutants = [m for m in mutants if set(m.get("tags", [])) & set(a.tag)]
    if a.exclude_tag:
        mutants = [m for m in mutants if not set(m.get("tags", [])) & set(a.exclude_tag)]
    if a.list:
        for m in mutants:
            print(f"{m['name']:<40} {m['file']}  tags={','.join(m.get('tags', [])) or '-'}")
        return 0
    if not mutants and not broken:
        print("no mutants selected")
        return 1

    tracked = set(tracked_files())
    copy = tempfile.mkdtemp(prefix="mutation-check-")
    results = []  # (name, verdict, seconds, detail)
    try:
        copy_tree(copy)
        baseline = {}  # must_fail command -> (rc, output)
        for m in mutants:
            name = m["name"]
            try:
                original = apply(m, copy, tracked)
            except Broken as e:
                results.append((name, "broken", 0.0, str(e)))
                continue
            if a.check:
                restore(copy, m["file"], original)
                results.append((name, "applies", 0.0, ""))
                continue
            # The check must pass on the unmutated tree, or a failure proves
            # nothing. Restore first, run once per distinct command.
            restore(copy, m["file"], original)
            key = (m["must_fail"], tuple(sorted(m.get("env", {}).items())))
            if key not in baseline:
                print(f"baseline: {m['must_fail']}", flush=True)
                baseline[key] = run_check(m, copy, a.timeout)
            rc0, out0, _ = baseline[key]
            if rc0 is None:
                results.append((name, "broken", 0.0, "the check timed out on the unmutated tree"))
                continue
            if rc0 != 0:
                results.append((name, "broken", 0.0,
                                f"the check fails on the unmutated tree (exit {rc0})\n{tail(out0)}"))
                continue
            apply(m, copy, tracked)
            print(f"mutant {name}: {m['file']}", flush=True)
            rc, out, secs = run_check(m, copy, a.timeout)
            restore(copy, m["file"], original)
            if rc is None:
                results.append((name, "broken", secs, "the check timed out on the mutant"))
            elif rc == 0:
                results.append((name, "survived", secs, tail(out)))
            else:
                results.append((name, "killed", secs, ""))
    finally:
        if a.keep:
            print(f"copy kept at {copy}")
        else:
            shutil.rmtree(copy, ignore_errors=True)

    for name, err in broken:
        results.append((name, "broken", 0.0, err))
    width = max([len(r[0]) for r in results] + [6])
    lines = [f"{'mutant':<{width}}  verdict   seconds", f"{'-' * width}  --------  -------"]
    for name, verdict, secs, detail in results:
        lines.append(f"{name:<{width}}  {verdict:<8}  {secs:7.1f}")
        if detail:
            lines.append("    " + detail.replace("\n", "\n    "))
    counts = {v: sum(1 for r in results if r[1] == v) for v in ("killed", "survived", "broken", "applies")}
    summary = ", ".join(f"{n} {v}" for v, n in counts.items() if n)
    lines.append("")
    lines.append(f"mutation check: {summary}")
    report = "\n".join(lines)
    print(report)
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a", encoding="utf-8") as f:
            f.write("### Mutation check\n\n```\n" + report + "\n```\n")
    bad = counts["survived"] + counts["broken"]
    for name, verdict, _, detail in results:
        if verdict in ("survived", "broken"):
            first = detail.splitlines()[0] if detail else ""
            print(f"::error::mutant {name} {verdict}" + (f": {first}" if first else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
