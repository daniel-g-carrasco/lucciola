#!/usr/bin/env python3
"""Tests for the toolkit-free part of Lucciola System
(build_files/system_files/usr/share/lucciola/system/lucciola_system.py), run by
tests/system-logic.test.sh with python3 -I and no GTK: which image a machine
follows, what rpm-ostree's JSON says, when an update counts as available,
how pending apps and checks are worded."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build_files/system_files/usr/share/lucciola/system"))

import lucciola_system as ls  # noqa: E402

fails = 0


def check(name, cond, detail=""):
    global fails
    if cond:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}" + (f": {detail}" if detail else ""))
        fails += 1


# followed_image: tags of this repository count, digests and other images do not
check("stable tag followed", ls.followed_image("ostree-image-signed:docker://ghcr.io/daniel-g-carrasco/lucciola:stable") == ls.IMAGE)
check("candidate tag followed", ls.followed_image("ostree-unverified-registry:ghcr.io/daniel-g-carrasco/lucciola:candidate") == f"{ls.REPO}:candidate")
check("a dated tag is followed", ls.followed_image(f"ostree-unverified-registry:{ls.REPO}:stable.20261020").endswith(":stable.20261020"))
check("a digest pin falls back to :stable", ls.followed_image(f"ostree-unverified-registry:{ls.REPO}:candidate@sha256:abc") == ls.IMAGE)
check("another image falls back to :stable", ls.followed_image("ostree-unverified-registry:ghcr.io/daniel-g-carrasco/margine:lucciola") == ls.IMAGE)
check("an empty origin falls back", ls.followed_image("") == ls.IMAGE)

# parse_deployments
status = {
    "deployments": [
        {"staged": True, "version": "candidate.20261020", "base-commit-meta": {"ostree.manifest-digest": "sha256:new"}},
        {"booted": True, "version": "candidate.20261019", "container-image-reference": f"ostree-unverified-registry:{ls.REPO}:candidate",
         "base-commit-meta": {"ostree.manifest-digest": "sha256:old"}, "requested-packages": ["steam", "gamescope"], "packages": ["gamescope", "lutris"]},
        {"version": "candidate.20261018"},
        {"version": "candidate.20261017"},
    ]
}
st = ls.parse_deployments(json.dumps(status))
check("staged version and digest", st["staged"] == "candidate.20261020" and st["staged_digest"] == "sha256:new")
check("booted version and digest", st["booted"] == "candidate.20261019" and st["booted_digest"] == "sha256:old")
check("rollback is the first deployment after the booted one", st["rollback"] == "candidate.20261018")
check("layered packages: requested and installed, sorted, unique", st["layered"] == ["gamescope", "lutris", "steam"])
check("followed image from the booted origin", st["image"] == f"{ls.REPO}:candidate")
empty = ls.parse_deployments("")
check("no status: empty state, :stable", empty["booted"] is None and empty["image"] == ls.IMAGE)
check("broken json: empty state", ls.parse_deployments("{not json")["booted"] is None)
check("a checksum stands in for a missing version", ls.parse_deployments(json.dumps({"deployments": [{"booted": True, "checksum": "abcdef0123456789"}]}))["booted"] == "abcdef012345")

# update_available: digests decide, labels are the fallback
check("same digest: no update", not ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, "v1", "sha256:a"))
check("different digest, same label: update", ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, "v1", "sha256:b"))
check("no digests: labels decide", ls.update_available({"booted": "v1", "booted_digest": ""}, "v2", ""))
check("no digests, same label: no update", not ls.update_available({"booted": "v1", "booted_digest": ""}, "v1", ""))
check("nothing published known: no update", not ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, None, ""))

# parse_skopeo
check("skopeo digest and version", ls.parse_skopeo("sha256:abc candidate.20261020\n") == ("candidate.20261020", "sha256:abc"))
check("skopeo without a version label", ls.parse_skopeo("sha256:abc") == ("sha256:abc", ""))
check("skopeo empty", ls.parse_skopeo("") == (None, ""))

# app_updates and wording
apps = ls.app_updates("Discord\tcom.discordapp.Discord\nShowtime\torg.gnome.Showtime\n\nBlender\torg.blender.Blender\n")
check("app updates: names with ids", apps == [("Discord", "com.discordapp.Discord"), ("Showtime", "org.gnome.Showtime"), ("Blender", "org.blender.Blender")])
check("an id without a name keeps the id", ls.app_updates("org.example.App\n") == [("org.example.App", "org.example.App")])
check("waiting phrase names apps, not ids", ls.waiting_phrase(apps, "apps") == "3 waiting: Discord, Showtime and 1 more")
check("waiting phrase: none", ls.waiting_phrase([], "apps") == "All apps are up to date")
check("waiting phrase: unavailable", ls.waiting_phrase(None, "tools") == "Unavailable")
check("waiting phrase: plain strings", ls.waiting_phrase(["c-ares", "zstd"], "tools") == "2 waiting: c-ares, zstd")
check("layered phrase without a long dash", "—" not in ls.layered_phrase(["a", "b", "c", "d", "e"]) and "and 2 more" in ls.layered_phrase(["a", "b", "c", "d", "e"]))
check("layered phrase: none", ls.layered_phrase([]).startswith("None"))

# checks
check("check name from the validator path", ls.check_name("/usr/bin/lucciola-validate-margine-system") == "Margine system")
check("check name, margine prefix", ls.check_name("margine-validate-branding") == "Branding")
check("summary: all good", ls.check_summary([("A", True, ""), ("B", True, "")]) == "Everything matches how Lucciola ships")
check("summary: failures counted", ls.check_summary([("A", True, ""), ("B", False, "x")]) == "1 of 2 checks need attention")
check("summary: nothing installed", ls.check_summary([]).startswith("No checks"))
check("last line of a detail", ls.last_line("one\n\ntwo \n") == "two ")

# excluded apps
check("excluded apps parsed", ls.excluded_apps("com.foo.Bar 2026-10-01 hung\norg.x.Y 2026-10-05\n") == [("com.foo.Bar", "2026-10-01"), ("org.x.Y", "2026-10-05")])
check("excluded apps: empty", ls.excluded_apps("") == [])

# os-release version
check("os-release VERSION", ls.os_release_version('NAME="Lucciola"\nVERSION="candidate.20261020"\n') == "candidate.20261020")
check("os-release VERSION_ID fallback", ls.os_release_version("VERSION_ID=45\n") == "45")
check("os-release without a version", ls.os_release_version("NAME=x\n") == "")

# the UI strings this module owns carry no long dash and no terminal command
for text in (ls.layered_phrase(["a"]), ls.waiting_phrase(["x"], "apps"), ls.check_summary([]), ls.check_summary([("A", False, "")])):
    check(f"no long dash or command in: {text[:40]}", "—" not in text and "ujust" not in text and "rpm-ostree" not in text)

if fails:
    print(f"system-logic: {fails} failed")
    sys.exit(1)
print("system-logic: all checks passed")
