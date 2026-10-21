#!/usr/bin/env python3
"""Every shell script runs in strict mode, or the allowlist says why not.

    check-strict-mode.py [--root DIR] [--allowlist FILE] [--dirs DIR ...] [FILE ...]

A shell script without `set -e` goes on after a failed command and reports
whatever its last line reports; without `-u` a typo in a variable name is
an empty string; without `pipefail` a pipeline is as healthy as its last
command (review R6: `cmd | tail` passed with cmd failing). Every script
found by its shebang under build_files/, lucciola/, .github/scripts/,
.github/smoke/ and tests/ (tracked, symlinks skipped) must set all three
within its first 30 lines that are not comments or blank: `set -euo
pipefail`, `set -eou pipefail`, `set -eu` then `set -o pipefail`, long
options, or `source`/`.` of build_files/00-common.sh, which sets them and
is checked itself.

A script that legitimately cannot (a validator that must run every check
and count the failures, a probe that prints a marker per check, a one-line
exec wrapper) is listed in tests/policy/strict-mode-allowlist.txt with its
reason. An entry without a reason, for a file that is not there, or for a
script that is strict after all, fails: the allowlist stays as honest as
the scripts. Exit 0 when every script is strict or excused, 1 otherwise.
"""
import argparse
import os
import re
import shlex
import subprocess
import sys

DIRS = ("build_files", "lucciola", ".github/scripts", ".github/smoke", "tests")
SHEBANG = re.compile(r"^#!\s*(?:/usr/bin/env\s+|/usr/bin/|/bin/|/usr/local/bin/)?(ba)?sh\b")
COMMON = re.compile(r"^\s*(?:source|\.)\s+\S*00-common\.sh\b")
LINES = 30


def is_shell(path):
    try:
        with open(path, "rb") as f:
            first = f.readline(200).decode("utf-8", errors="replace")
    except OSError:
        return False
    return bool(SHEBANG.match(first))


def strictness(path):
    """(set of {'e','u','pipefail'} found, lines read) within the first LINES
    non-comment lines. A source of 00-common.sh counts as all three."""
    found, read = set(), 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or (s.startswith("#") and n > 1) or n == 1:
                continue
            read += 1
            if read > LINES:
                break
            if COMMON.match(line):
                return {"e", "u", "pipefail"}, read
            m = re.match(r"^\s*set\s+(.*)$", line)
            if not m:
                continue
            try:
                toks = shlex.split(m.group(1), comments=True)
            except ValueError:
                toks = m.group(1).split()
            i = 0
            while i < len(toks):
                t = toks[i]
                if t == "-o" and i + 1 < len(toks):
                    found.add({"errexit": "e", "nounset": "u", "pipefail": "pipefail"}.get(toks[i + 1], ""))
                    i += 2
                    continue
                if t.startswith("-") and not t.startswith("--") and t != "-":
                    letters = t[1:]
                    found |= {c for c in letters if c in "eu"}
                    if "o" in letters and i + 1 < len(toks):
                        found.add({"errexit": "e", "nounset": "u", "pipefail": "pipefail"}.get(toks[i + 1], ""))
                        i += 1
                i += 1
    found.discard("")
    return found, read


def tracked(root, dirs):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *dirs], check=True, capture_output=True).stdout
    return [p.decode() for p in out.split(b"\0") if p]


def read_allowlist(path):
    entries = {}
    problems = []
    if not os.path.isfile(path):
        return entries, problems
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) < 2 or len(parts[1].split()) < 3:
                problems.append(f"{path}:{n}: '{parts[0]}' needs a reason (a few words after the path)")
                continue
            if parts[0] in entries:
                problems.append(f"{path}:{n}: {parts[0]} is listed twice")
            entries[parts[0]] = parts[1].strip()
    return entries, problems


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="scripts to check (relative to --root); default: git-tracked under --dirs")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--allowlist")
    ap.add_argument("--dirs", nargs="+", default=list(DIRS))
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root)
    allowlist = a.allowlist or os.path.join(root, "tests", "policy", "strict-mode-allowlist.txt")
    candidates = a.files or tracked(root, a.dirs)
    scripts = []
    for rel in candidates:
        path = os.path.join(root, rel)
        if os.path.islink(path) or not os.path.isfile(path) or not is_shell(path):
            continue
        scripts.append(rel)
    excused, problems = read_allowlist(allowlist)
    strict = 0
    for rel in scripts:
        found, _ = strictness(os.path.join(root, rel))
        missing = {"e", "u", "pipefail"} - found
        if not missing:
            strict += 1
            if rel in excused:
                problems.append(f"{os.path.relpath(allowlist, root)}: {rel} is strict after all: remove its entry")
            continue
        if rel in excused:
            continue
        problems.append(f"{rel}: no strict mode in its first {LINES} lines (missing: "
                        f"{', '.join('-' + m if len(m) == 1 else '-o ' + m for m in sorted(missing))}); "
                        "add `set -euo pipefail`, or list it in tests/policy/strict-mode-allowlist.txt with the reason")
    for rel in excused:
        if rel not in scripts:
            problems.append(f"{os.path.relpath(allowlist, root)}: {rel} is not a tracked shell script in scope: "
                            "remove the entry")
    for p in problems:
        print(f"::error::{p}")
    used = sum(1 for rel in scripts if rel in excused)
    print(f"strict mode: {len(scripts)} shell scripts, {strict} strict, {used} excused with a reason"
          + (f", {len(problems)} problem(s)" if problems else ""))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
