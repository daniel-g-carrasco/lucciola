#!/usr/bin/env python3
"""The cells of the upgrade smoke: the dispatch inputs, or the weekly matrix.

    upgrade-matrix.py --event workflow_dispatch --from REF --to REF
                      [--transport T] [--layer PKG] [--expect-id-like ID]
    upgrade-matrix.py --event schedule --promote-stable true|false

Prints a JSON list for `strategy.matrix.include` in upgrade-smoke.yml:
name, slug, from_ref, to_ref, transport, layer, expect_id_like. A dispatch
is one cell, the inputs as given. The weekly run (Sunday, after the weekly
build) walks every starting point the guide names, from the image people
run today to the stock desktops, one VM at a time:

  margine:lucciola with cowsay layered   the move real users make
  margine:lucciola with steam layered    only once :stable is promoted
                                         (vars.LUCCIOLA_PROMOTE_STABLE):
                                         before Fedora 45's release the
                                         layered Steam cannot resolve, a
                                         known pre-GA state, not a regression
  fedora-silverblue:45, fedora-kinoite:45, bluefin:stable
                                         the documented stock starts; the
                                         Kinoite cell is the one that meets
                                         a foreign display manager (N7)

All weekly cells rebase to :candidate over ostree-unverified-registry:
none of those systems' policies has a scope for this repository, so the
signed transport would verify nothing (the driver checks that the NEW
deployment's policy requires the signature). tests/upgrade-matrix.test.sh.
"""
import argparse
import json
import re
import sys

TARGET = "ghcr.io/daniel-g-carrasco/lucciola:candidate"
MARGINE = "ghcr.io/daniel-g-carrasco/margine:lucciola"
# (name, slug, from_ref, layer, only when :stable is promoted)
WEEKLY = (
    ("from margine:lucciola, cowsay layered", "margine-lucciola-cowsay", MARGINE, "cowsay", False),
    ("from margine:lucciola, steam layered", "margine-lucciola-steam", MARGINE, "steam", True),
    ("from fedora-silverblue:45", "silverblue-45", "quay.io/fedora/fedora-silverblue:45", "", False),
    ("from fedora-kinoite:45", "kinoite-45", "quay.io/fedora/fedora-kinoite:45", "", False),
    ("from bluefin:stable", "bluefin-stable", "ghcr.io/ublue-os/bluefin:stable", "", False),
)


def cell(name, slug, from_ref, to_ref, transport, layer, expect_id_like):
    assert re.fullmatch(r"[a-z0-9-]+", slug), slug
    return {"name": name, "slug": slug, "from_ref": from_ref, "to_ref": to_ref,
            "transport": transport, "layer": layer, "expect_id_like": expect_id_like}


def weekly(promote_stable):
    return [cell(name, slug, from_ref, TARGET, "ostree-unverified-registry", layer, "fedora")
            for name, slug, from_ref, layer, stable_only in WEEKLY
            if promote_stable or not stable_only]


def dispatch(a):
    if not a.from_ref or not a.to_ref:
        raise SystemExit("a dispatch needs --from and --to")
    short = lambda ref: ref.rsplit("/", 1)[-1].split("@")[0]  # noqa: E731
    name = f"from {short(a.from_ref)} to {short(a.to_ref)}" + (f", {a.layer} layered" if a.layer else "")
    return [cell(name, "dispatch", a.from_ref, a.to_ref, a.transport or "ostree-unverified-registry",
                 a.layer or "", a.expect_id_like or "fedora")]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--event", required=True, choices=["workflow_dispatch", "schedule"])
    ap.add_argument("--promote-stable", default="false")
    ap.add_argument("--from", dest="from_ref", default="")
    ap.add_argument("--to", dest="to_ref", default="")
    ap.add_argument("--transport", default="")
    ap.add_argument("--layer", default="")
    ap.add_argument("--expect-id-like", default="")
    a = ap.parse_args(argv)
    cells = dispatch(a) if a.event == "workflow_dispatch" else weekly(a.promote_stable.strip().lower() == "true")
    # JSON on stdout for the workflow, the same cells in words on stderr for
    # the person reading the log.
    for c in cells:
        print(f"- {c['name']}: {c['from_ref']} -> {c['to_ref']} ({c['transport']}, layer {c['layer'] or 'none'})",
              file=sys.stderr)
    print(json.dumps(cells))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
