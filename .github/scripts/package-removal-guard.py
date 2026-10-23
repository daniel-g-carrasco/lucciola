#!/usr/bin/env python3
"""No package leaves the image unnoticed: the new image against the published one.

    package-removal-guard.py --new FILE --published FILE --expected FILE
                             [--enforce] [--today YYYY-MM-DD] [--grace-days 14]
                             [--summary FILE]

FILE for --new and --published hold package names, one per line, as
`rpm -qa --qf '%{NAME}\\n'` prints them in the freshly built image and in
the :candidate the registry serves today. On 2026-10-11 a base-image change
made the base-trim step remove more than it was written for, and images
without Nautilus and Ptyxis were published with every check green: nothing
compared what shipped yesterday with what ships today. This does.

Every package added or removed goes to the summary. A kernel module package akmods built
(kmod-<module>-<kernel version>-<module version>) counts by its module:
kmod-<module>, whatever kernel it was built for. A removed package must
be listed in --expected (build_files/expected-removals.txt):

    <package name>  <YYYY-MM-DD, the day the removal was decided>  [why]

A line serves for --grace-days after its date (the removal ships, the
next builds see the package in neither image) and must then be deleted:
an older line fails the check, so the file never grows into a permanent
allowlist that would hide a later accident. Within the grace period a line
whose package is still in both images is a warning (the removal has not
happened), one whose package is in neither a notice (delete it when
convenient).

Exit 0 when nothing is wrong, or when not --enforce (then problems are
warnings: a pull request or a trial build); 1 on an unexpected removal or
a stale line with --enforce; 2 on a malformed expected-removals file,
whatever the mode.
"""
import argparse
import datetime
import re
import sys

NAME_RE = re.compile(r"^[A-Za-z0-9._+-]+$")


KMOD_RE = re.compile(r"^kmod-(.+?)-\d+\.\d+[^-]*-")


def family(name):
    """The name a package keeps across kernels. akmods names the module
    package after the kernel it was built for (kmod-v4l2loopback-7.3.0-
    4.cachyos1.fc45.x86_64), so every kernel bump read as a removal and an
    addition (main stopped on 2026-10-23, 7.3.0-cachyos1 to 7.3.0-4):
    kmod-<module> is what must not leave the image."""
    m = KMOD_RE.match(name)
    return f"kmod-{m.group(1)}" if m else name


def read_names(path):
    with open(path, encoding="utf-8") as f:
        return {family(ln.strip()) for ln in f if ln.strip() and not ln.startswith("#")}


def read_expected(path):
    """{name: (date, reason, line number)}"""
    out = {}
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split(None, 2)
            if len(parts) < 2 or not NAME_RE.match(parts[0]):
                raise ValueError(f"{path}:{n}: expected '<package> <YYYY-MM-DD> [why]', got: {raw.rstrip()}")
            try:
                date = datetime.date.fromisoformat(parts[1])
            except ValueError:
                raise ValueError(f"{path}:{n}: '{parts[1]}' is not a date (YYYY-MM-DD)") from None
            if parts[0] in out:
                raise ValueError(f"{path}:{n}: {parts[0]} is listed twice")
            out[parts[0]] = (date, parts[2] if len(parts) > 2 else "", n)
    return out


def judge(new, published, expected, today, grace, expected_path):
    """(problems, notes, added, removed)"""
    added = sorted(new - published)
    removed = sorted(published - new)
    problems, notes = [], []
    for name in removed:
        if name not in expected:
            problems.append(f"{name} is in the published image and not in this one, and {expected_path} does not "
                            f"list it: a package left the image. If that is intended, add the line "
                            f"'{name} {today.isoformat()} <why>' to {expected_path}")
    for name, (date, reason, n) in sorted(expected.items()):
        age = (today - date).days
        if age < 0:
            raise ValueError(f"{expected_path}:{n}: {name} is dated {date.isoformat()}, in the future")
        if age > grace:
            problems.append(f"{expected_path}:{n}: {name} is dated {date.isoformat()}, {age} days ago, past the "
                            f"{grace}-day window: delete the line (the removal shipped long ago, or never happened)")
        elif name in removed:
            notes.append(f"{name}: removed as expected ({expected_path}:{n}{', ' + reason if reason else ''})")
        elif name in new:
            notes.append(f"::warning::{expected_path}:{n} expects {name} to be removed, but it is still in the "
                         f"image; the line is {age} days old and fails after {grace}")
        else:
            notes.append(f"{name}: already gone from both images; delete the line {expected_path}:{n} "
                         f"before {(date + datetime.timedelta(days=grace)).isoformat()}")
    return problems, notes, added, removed


def summary(problems, notes, added, removed, enforce, new, published):
    lines = ["### Packages since the published image", ""]
    lines.append(f"{len(new)} packages in this image, {len(published)} in the published one: "
                 f"{len(added)} added, {len(removed)} removed.")
    if added:
        lines += ["", "Added:", "```", *added, "```"]
    if removed:
        lines += ["", "Removed:", "```", *removed, "```"]
    if problems:
        lines += ["", "**" + ("Failing" if enforce else "Would fail on a main build") + ":**", ""]
        lines += [f"- {p.replace('::error::', '')}" for p in problems]
    if notes:
        lines += ["", "Notes:", ""] + [f"- {n.replace('::warning::', 'warning: ')}" for n in notes]
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--new", required=True)
    ap.add_argument("--published", required=True)
    ap.add_argument("--expected", required=True)
    ap.add_argument("--enforce", action="store_true", help="exit 1 on a problem (main builds)")
    ap.add_argument("--today", default=datetime.date.today().isoformat())
    ap.add_argument("--grace-days", type=int, default=14)
    ap.add_argument("--summary", help="write the markdown summary here as well as to stdout")
    a = ap.parse_args(argv)
    try:
        new, published = read_names(a.new), read_names(a.published)
        expected = read_expected(a.expected)
        today = datetime.date.fromisoformat(a.today)
        problems, notes, added, removed = judge(new, published, expected, today, a.grace_days, a.expected)
    except (OSError, ValueError) as e:
        print(f"::error::{e}")
        return 2
    text = summary(problems, notes, added, removed, a.enforce, new, published)
    print(text)
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(text)
    for n in notes:
        if n.startswith("::warning::"):
            print(n)
    for p in problems:
        print(("::error::" if a.enforce else "::warning::") + p)
    if problems and a.enforce:
        print(f"package guard: {len(problems)} problem(s)")
        return 1
    print("package guard: " + ("no unexpected removal" if not problems else
                               f"{len(problems)} problem(s), reported only (not a main build)"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
