"""Lucciola System: the parts of the app that need no toolkit.

The window (/usr/libexec/margine/system-gui) imports this module for every
decision that can be tested without a display: which published image this
machine follows, what rpm-ostree's JSON says about the deployments, how a
list of pending app updates is worded, how a validator's name reads. The
tests (tests/system-logic.test.py) run it with python3 -I and no GTK.
"""

import json
import re

REPO = "ghcr.io/daniel-g-carrasco/lucciola"
IMAGE = f"{REPO}:stable"
REPORT_PATH = "lucciola-report.txt"
ISSUES_URL = "https://github.com/daniel-g-carrasco/lucciola/issues/new/choose"


def followed_image(origin):
    """The published image to compare against: the tag this machine follows
    (:stable, :candidate, a dated tag...), read from the booted origin.
    Comparing every machine with :stable told every install on another tag
    that an update was available, forever. Same rule as lucciola-status:
    only tags of this image's repository count; a digest pin or another
    image keeps the :stable comparison."""
    ref = origin.partition(":")[2].removeprefix("docker://")
    if ref.startswith(REPO + ":") and "@" not in ref:
        return ref
    return IMAGE


def parse_deployments(status_json):
    """Booted / staged / rollback deployments out of `rpm-ostree status
    --json`. The manifest digest is the only identity that survives two
    builds published under the same version label (both stable builds of
    2026-08-30 were candidate.20260830), so it travels with the version."""
    state = {
        "booted": None, "staged": None, "rollback": None, "layered": [],
        "booted_digest": "", "staged_digest": "", "image": IMAGE,
    }
    try:
        deployments = json.loads(status_json or "{}").get("deployments", [])
    except (json.JSONDecodeError, AttributeError):
        return state
    seen_booted = False
    for dep in deployments:
        version = dep.get("version") or (dep.get("checksum") or "")[:12]
        digest = (dep.get("base-commit-meta") or {}).get("ostree.manifest-digest") or ""
        if dep.get("staged"):
            state["staged"] = version
            state["staged_digest"] = digest
        elif dep.get("booted"):
            state["booted"] = version
            state["booted_digest"] = digest
            state["image"] = followed_image(dep.get("container-image-reference") or "")
            seen_booted = True
            state["layered"] = sorted(
                set(dep.get("requested-packages") or []) | set(dep.get("packages") or [])
            )
        elif seen_booted and state["rollback"] is None:
            state["rollback"] = version
    return state


def update_available(state, latest, latest_digest):
    """Digests decide, labels are the fallback (#397): comparing labels
    alone made the button a no-op on the second build of a day."""
    booted_digest = state.get("booted_digest") or ""
    if booted_digest and latest_digest:
        return booted_digest != latest_digest
    return bool(latest) and state.get("booted") != latest


def parse_skopeo(output):
    """`skopeo inspect --format '{{.Digest}} {{version label}}'` -> (version, digest)."""
    digest, _, version = (output or "").strip().partition(" ")
    if not version:
        return (digest or None), ""
    return version, digest


def app_updates(remote_ls_output):
    """`flatpak remote-ls --updates --columns=name,application` -> [(name, id)].
    The name is what people know the app by; the id is what the tools take."""
    apps = []
    for line in (remote_ls_output or "").splitlines():
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0].strip():
            continue
        name = parts[0].strip()
        app_id = parts[1].strip() if len(parts) > 1 and parts[1].strip() else name
        apps.append((name, app_id))
    return apps


def waiting_phrase(items, noun, unavailable="Unavailable"):
    """One line for a row subtitle: 'All apps are up to date', '3 waiting:
    Discord, Showtime and 1 more'. items is None when the source could
    not be asked."""
    if items is None:
        return unavailable
    if not items:
        return f"All {noun} are up to date"
    names = [i[0] if isinstance(i, tuple) else i for i in items]
    preview = ", ".join(names[:2])
    if len(names) > 2:
        preview += f" and {len(names) - 2} more"
    return f"{len(names)} waiting: {preview}"


def layered_phrase(layered):
    if not layered:
        return "None: this is a stock Lucciola system"
    preview = ", ".join(layered[:3])
    if len(layered) > 3:
        preview += f" and {len(layered) - 3} more"
    return f"{preview}. Refreshed with every system update"


def check_name(path):
    """/usr/bin/lucciola-validate-margine-system -> 'Margine system'."""
    name = path.rsplit("/", 1)[-1]
    name = re.sub(r"^(lucciola|margine)-validate-", "", name)
    return name.replace("-", " ").capitalize()


def check_summary(results):
    """results: [(name, ok, detail)] -> the group description."""
    failed = [r for r in results if not r[1]]
    if not results:
        return "No checks are installed on this system"
    if not failed:
        return "Everything matches how Lucciola ships"
    return f"{len(failed)} of {len(results)} checks need attention"


def last_line(detail, limit=160):
    lines = [ln for ln in (detail or "").splitlines() if ln.strip()]
    return lines[-1][:limit] if lines else ""


def excluded_apps(blocked_text):
    """/var/lib/margine/update-watchdog/blocked: 'APP SINCE REASON...' per
    line -> [(app, since)]. Apps the update watchdog took out of unattended
    updates because their vendor download kept hanging."""
    out = []
    for line in (blocked_text or "").splitlines():
        parts = line.split()
        if parts:
            out.append((parts[0], parts[1] if len(parts) > 1 else ""))
    return out


def os_release_version(text):
    """VERSION= or VERSION_ID= from os-release, unquoted, or ''."""
    for key in ("VERSION", "VERSION_ID"):
        m = re.search(rf"^{key}=(.*)$", text or "", re.M)
        if m:
            return m.group(1).strip().strip('"')
    return ""
