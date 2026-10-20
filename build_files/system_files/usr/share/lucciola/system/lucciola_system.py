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
        "booted_digest": "", "staged_digest": "", "booted_ref": "", "staged_ref": "", "image": IMAGE,
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
            state["staged_ref"] = dep.get("container-image-reference") or ""
        elif dep.get("booted"):
            state["booted"] = version
            state["booted_digest"] = digest
            state["booted_ref"] = dep.get("container-image-reference") or ""
            state["image"] = followed_image(state["booted_ref"])
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


# ── the pages' state, parsed from the helpers' own words ─────────────

STATUS_LINE = re.compile(r"^  (.{26}) (.*)$")


def parse_tpm_status(text):
    """`lucciola-tpm-unlock status` (as root) -> what the page needs. Each
    line is '  <label padded to 26> <value>'; the glyphs are the helper's:
    ✓ good, ✗ bad, — absent. error is set when there is no LUKS root."""
    st = {"device": None, "token": None, "wired": None, "fallback": None, "luks": "", "error": ""}
    if "Could not auto-detect a LUKS device" in (text or "") or "LUKS root detection failed" in (text or ""):
        st["error"] = "no encrypted disk behind the system"
        return st
    for line in (text or "").splitlines():
        m = STATUS_LINE.match(line)
        if not m:
            continue
        label, value = m.group(1).strip(), m.group(2).strip()
        good = value.startswith("✓")
        if label == "TPM2 device":
            st["device"] = good
        elif label == "TPM2 token":
            st["token"] = good
        elif label == "Boot path (crypttab)":
            st["wired"] = good
        elif label == "Fallback keyslot":
            st["fallback"] = good
        elif label == "LUKS device backing root":
            st["luks"] = value
    return st


def tpm_summary(st):
    """(state, sentence) for the Disk Unlock row: on, half (token without
    the boot path), off, unencrypted, unknown."""
    if st.get("error"):
        return "unencrypted", "The disk is not encrypted, or its encryption is not the one Lucciola sets up"
    if st.get("device") is False:
        return "no-tpm", "This machine has no TPM 2.0 chip; the passphrase is typed at every startup"
    if st.get("token") and st.get("wired"):
        return "on", "The TPM unlocks the disk at startup; only the login is asked"
    if st.get("token") and st.get("wired") is False:
        return "half", "A TPM key is enrolled but the startup does not use it yet"
    if st.get("token") is False:
        return "off", "The disk passphrase is typed at every startup"
    return "unknown", "Could not read how the disk is unlocked"


def parse_grub_lock(text):
    """`grub-lock status` -> 'on', 'off', 'unavailable' or None."""
    m = re.search(r"^GRUB menu lock: (ON|off|not available)", text or "", re.M)
    if not m:
        return None
    return {"ON": "on", "off": "off", "not available": "unavailable"}[m.group(1)]


def parse_autologin(text):
    """`lucciola-autologin status` -> (enabled, user)."""
    m = re.search(r'autologin: ENABLED for user "([^"]+)"', text or "")
    if m:
        return True, m.group(1)
    if re.search(r"autologin: disabled", text or ""):
        return False, None
    return None, None


def parse_keyring_status(text):
    """`lucciola-keyring status` -> {'unlocked': bool|None, 'at_login': ...}.
    at_login: 'tpm-used' (credential present and used at this login),
    'tpm-present' (present, this login used the password), 'tpm-wrong'
    (present but holds a wrong password), 'tpm-next' (just stored, applies
    at the next login), 'password' (no credential), or None."""
    st = {"unlocked": None, "at_login": None}
    for line in (text or "").splitlines():
        s = line.strip()
        if s.startswith("login keyring:"):
            if "unlocked" in s:
                st["unlocked"] = True
            elif "LOCKED" in s:
                st["unlocked"] = False
        elif s.startswith("unlock at login:"):
            v = s.partition(":")[2].strip()
            if "used at this login" in v:
                st["at_login"] = "tpm-used"
            elif "WRONG password" in v:
                st["at_login"] = "tpm-wrong"
            elif "this login used the login password" in v:
                st["at_login"] = "tpm-present"
            elif v.startswith("TPM credential present"):
                st["at_login"] = "tpm-next"
            elif v.startswith("password login only"):
                st["at_login"] = "password"
    return st


def secureboot_state(sb_state_text, mok_status_text):
    """`mokutil --sb-state` first line and `mok-enroll status` -> {'secure_boot':
    bool|None, 'key': enrolled|pending|absent|unsupported}."""
    first = (sb_state_text or "").strip().splitlines()[:1]
    sb = None
    if first:
        if "enabled" in first[0]:
            sb = True
        elif "disabled" in first[0]:
            sb = False
    key = (mok_status_text or "").strip()
    if key not in ("enrolled", "pending", "absent", "unsupported"):
        key = "unsupported"
    return {"secure_boot": sb, "key": key}


def ref_tag(ref):
    """The tag of a container image reference of this image's repository,
    or None (another image, a digest pin, no reference)."""
    rest = (ref or "").partition(":")[2].removeprefix("docker://")
    if rest.startswith(REPO + ":") and "@" not in rest:
        return rest[len(REPO) + 1:]
    return None


def kernel_flavour(tag, reserve_tag):
    """fedora for the reserve tag and its dated/-test forms, cachyos otherwise."""
    if not tag or not reserve_tag:
        return None
    if tag == reserve_tag or tag.startswith(reserve_tag + ".") or tag.startswith(reserve_tag + "-"):
        return "fedora"
    return "cachyos"


def kernel_state(state, flavour_text, reserve_tag_text):
    """What kernel runs and what is staged, from rpm-ostree's state (with
    booted_ref/staged_ref), /usr/share/margine/kernel-flavor and line 1 of
    /usr/share/margine/kernel-reserve-tag."""
    reserve = ""
    for line in (reserve_tag_text or "").splitlines():
        if line.strip() and not line.startswith("#"):
            reserve = line.strip()
            break
    running = (flavour_text or "").strip()
    if running not in ("cachyos", "fedora"):
        running = None
    booted_tag = ref_tag(state.get("booted_ref"))
    staged_tag = ref_tag(state.get("staged_ref"))
    return {
        "running": running,
        "reserve_tag": reserve,
        "follows": booted_tag,
        "follows_flavour": kernel_flavour(booted_tag, reserve),
        "staged": staged_tag,
        "staged_flavour": kernel_flavour(staged_tag, reserve) if staged_tag and staged_tag != booted_tag else None,
    }


SCHED_MODES = (("Auto", "auto"), ("Gaming", "gaming"), ("LowLatency", "lowlatency"), ("PowerSave", "powersave"), ("Server", "server"))
SCHED_MODE_LABELS = {"Auto": "Auto", "Gaming": "Gaming", "LowLatency": "Low latency", "PowerSave": "Power save", "Server": "Server"}


def scheduler_state(sysfs_state, ops, config_text, enabled, active):
    """The CPU scheduler, from /sys/kernel/sched_ext/state ('enabled' or
    'disabled'), /sys/kernel/sched_ext/root/ops (the scheduler loaded), the
    boot config /etc/scx_loader/config.toml and scx_loader.service's
    enabled/active words. Never from scxctl, which starts the daemon."""
    running = None
    if (sysfs_state or "").strip() == "enabled":
        running = (ops or "").strip().removeprefix("scx_") or "unknown"
    default_sched = default_mode = None
    for line in (config_text or "").splitlines():
        m = re.match(r'^\s*default_sched\s*=\s*"([^"]*)"', line)
        if m:
            default_sched = m.group(1).removeprefix("scx_")
        m = re.match(r'^\s*default_mode\s*=\s*"([^"]*)"', line)
        if m:
            default_mode = m.group(1)
    enabled_b = (enabled or "").strip() == "enabled"
    return {
        "running": running,
        "default_sched": default_sched if enabled_b else None,
        "default_mode": default_mode if enabled_b else None,
        "config_present": default_sched is not None,
        "enabled": enabled_b,
        "active": (active or "").strip() == "active",
    }


def grub_password_ok(password):
    return bool(re.match(r"^[A-Za-z0-9]{8,}$", password or ""))


def pcrs_ok(pcrs):
    return bool(re.match(r"^[0-9]{1,2}(\+[0-9]{1,2})*$", pcrs or ""))
