#!/usr/bin/env bash
# Which profile a screen gets (lucciola/system_files/usr/libexec/lucciola/
# color-calibration, profile_for): by the model the compositor sends, and,
# where it sends none (wlroots compositors send "Unknown" and put make, model
# and serial in the description), by the description, without letting a
# maker's name alone pick another screen's profile. No display needed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I - "$ROOT/lucciola/system_files/usr/libexec/lucciola/color-calibration" <<'PY'
import importlib.util
import sys
from importlib.machinery import SourceFileLoader

loader = SourceFileLoader("color_calibration", sys.argv[1])
cc = importlib.util.module_from_spec(importlib.util.spec_from_loader("color_calibration", loader))
loader.exec_module(cc)


def profile(text, created, path):
    return {"match": cc.squash(text), "created": created, "path": path}


PROFILES = [
    profile("BOE NE135A1M-NY1 2026-11-16 D65 i1d3", 3, "panel-new"),
    profile("BOE NE135A1M-NY1 (high) 2026-06-08", 1, "panel-old"),
    profile("Dell DELL P2415Q (high) 2026-06-08", 2, "dell-p2415q"),
    profile("Dell U2720Q factory", 9, "dell-u2720q"),
]


def screen(model, description, name="X-1", make="Unknown"):
    return {"name": name, "make": make, "model": model, "description": description}


def chosen(output, overrides=()):
    found, _reason = cc.profile_for(output, PROFILES, list(overrides))
    return found and found["path"]


fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
    fails += 0 if ok else 1


check("the model, where the compositor sends it: the newest profile for it",
      chosen(screen("NE135A1M-NY1", "BOE NE135A1M-NY1", make="BOE")), "panel-new")
check("no model, the description names the panel",
      chosen(screen("Unknown", "BOE NE135A1M-NY1 (eDP-1)")), "panel-new")
check("no model, the description has make, model and serial",
      chosen(screen("Unknown", "Dell Inc. DELL P2415Q D8VXF6731C6B (DP-3)")), "dell-p2415q")
check("another screen of the same maker gets no profile",
      chosen(screen("Unknown", "Dell Inc. DELL S2722QC ABC123 (DP-3)")), None)
check("a description without a model name gets no profile",
      chosen(screen("Unknown", "Red Hat, Inc. QEMU Monitor (Virtual-1)")), None)
check("nothing to go by gets no profile", chosen(screen("", "")), None)
check("the reason names the screen when nothing matches",
      "DELL S2722QC" in cc.profile_for(screen("Unknown", "Dell Inc. DELL S2722QC ABC123 (DP-3)"), PROFILES, [])[1], True)
check("an override of none still wins, matched on the description",
      cc.profile_for(screen("Unknown", "BOE NE135A1M-NY1 (eDP-1)", name="eDP-1"), PROFILES, [("ne135a1m", "none")])[0], None)
sys.exit(1 if fails else 0)
PY
